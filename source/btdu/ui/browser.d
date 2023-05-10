/*
 * Copyright (C) 2020, 2021, 2022, 2023  Vladimir Panteleev <btdu@cy.md>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License v2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 021110-1307, USA.
 */

/// ncurses interface for browsing results
module btdu.ui.browser;

import core.time;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.conv;
import std.encoding : sanitize;
import std.exception : errnoEnforce, enforce;
import std.format;
import std.range;
import std.string;
import std.traits;

import ae.utils.appender;
import ae.utils.functor.primitives : valueFunctor;
import ae.utils.meta;
import ae.utils.text;
import ae.utils.text.functor;
import ae.utils.time : stdDur, stdTime;

import btrfs;

import btdu.ui.curses;
import btdu.ui.deletion;
import btdu.common;
import btdu.state;
import btdu.paths;
import btdu.proto : logicalOffsetHole, logicalOffsetSlack;

alias imported = btdu.state.imported;

struct Browser
{
	Curses curses;

	BrowserPath* currentPath;
	BrowserPath* selection;
	BrowserPath*[] items;
	bool done;

	struct ScrollContext
	{
		sizediff_t top; // Scroll offset (row number, in the content, corresponding to the topmost displayed line)
		sizediff_t contentHeight; // Number of total rows in the content
		sizediff_t contentAreaHeight; // Number of rows where scrolling content is displayed
		sizediff_t cursor = -1; // The item view has a cursor; include it in upkeep calculations, to ensure it remains visible.

		/// Scrolling and cursor upkeep. Returns true if any changes were made.
		bool normalize()
		{
			auto oldTop = top;
			// Ensure there is no unnecessary space at the bottom
			if (top + contentAreaHeight > contentHeight)
				top = contentHeight - contentAreaHeight;
			// Ensure we are never scrolled "above" the first row
			if (top < 0)
				top = 0;
			// Ensure the selected item is visible
			if (cursor >= 0)
			{
				auto minTop = cursor - contentAreaHeight + 1;
				if (contentHeight > top + contentAreaHeight) // Bottom overflow marker visible
					minTop++;
				auto maxTop = cursor;
				if (top > 0) // Top overflow marker visible
					maxTop--;
				top = top.clamp(minTop, maxTop);
			}
			return oldTop != top;
		}
	}
	ScrollContext itemScrollContext, textScrollContext;

	enum Mode
	{
		browser,
		info,
		help,
		deleteConfirm,
		deleteProgress,
	}
	Mode mode;

	enum SortMode
	{
		name,
		size,
		time, // Average query duration
	}
	SortMode sortMode;
	bool reverseSort, dirsFirst;

	enum SizeMetric
	{
		represented,
		distributed,
		exclusive,
		shared_,
	}
	SizeMetric sizeDisplayMode = SizeMetric.represented;
	static SampleType sizeMetricSampleType(SizeMetric metric)
	{
		final switch (metric)
		{
			case SizeMetric.represented: return SampleType.represented;
			case SizeMetric.distributed: assert(false);
			case SizeMetric.exclusive: return SampleType.exclusive;
			case SizeMetric.shared_: return SampleType.shared_;
		}
	}

	enum RatioDisplayMode
	{
		none,
		graph,
		percentage,
		both,
	}
	RatioDisplayMode ratioDisplayMode = RatioDisplayMode.graph;

	Deleter deleter;

	void start()
	{
		curses.start();

		currentPath = &browserRoot;
	}

	@property bool needRefresh()
	{
		if (mode == Mode.deleteProgress)
			return deleter.needRefresh;
		return false;
	}

	@disable this(this);

	string message; MonoTime showMessageUntil;
	void showMessage(string s)
	{
		message = s;
		showMessageUntil = MonoTime.currTime() + (100.msecs * s.length);
	}

	private static FastAppender!char buf; // Reusable buffer

	// Returns full path as string, or null.
	private static char[] getFullPath(BrowserPath* path)
	{
		buf.clear();
		buf.put(fsPath);
		bool recurse(BrowserPath *path)
		{
			string name = path.name[];
			if (name.skipOverNul())
				switch (name)
				{
					case "DATA":
					case "UNREACHABLE":
						return true;
					default:
						return false;
				}
			if (path.parent)
				if (!recurse(path.parent))
					return false;
			buf.put('/');
			buf.put(name);
			return true;
		}
		if (recurse(path))
			return buf.get();
		else
			return null;
	}

	private real getSamples(BrowserPath* path)
	{
		final switch (sizeDisplayMode)
		{
			case SizeMetric.represented:
			case SizeMetric.exclusive:
			case SizeMetric.shared_:
				return path.data[sizeMetricSampleType(sizeDisplayMode)].samples;
			case SizeMetric.distributed:
				return path.distributedSamples;
		}
	}

	private real getDuration(BrowserPath* path)
	{
		final switch (sizeDisplayMode)
		{
			case SizeMetric.represented:
			case SizeMetric.exclusive:
			case SizeMetric.shared_:
				return path.data[sizeMetricSampleType(sizeDisplayMode)].duration;
			case SizeMetric.distributed:
				return path.distributedDuration;
		}
	}

	private real getAverageDuration(BrowserPath* path)
	{
		auto samples = getSamples(path);
		auto duration = getDuration(path);
		return samples ? duration / samples : -real.infinity;
	}

	void update()
	{
		auto wand = curses.getWand();
		with (wand)
		{
			deleter.update();
			if (deleter.state == Deleter.State.success)
			{
				showMessage("Deleted " ~ selection.humanName ~ ".");
				mode = Mode.browser;
				deleter.state = Deleter.State.none;
				selection.remove();
				selection = null;
			}

			static FastAppender!(BrowserPath*) itemsBuf;
			itemsBuf.clear;
			for (auto child = currentPath.firstChild; child; child = child.nextSibling)
				itemsBuf.put(child);
			items = itemsBuf.get();

			final switch (sortMode)
			{
				case SortMode.name:
					items.sort!((a, b) => a.name[] < b.name[]);
					break;
				case SortMode.size:
					items.multiSort!(
						(a, b) => a.I!getSamples() > b.I!getSamples(),
						(a, b) => a.name[] < b.name[],
					);
					break;
				case SortMode.time:
					items.multiSort!(
						(a, b) => a.I!getAverageDuration() > b.I!getAverageDuration(),
						(a, b) => a.name[] < b.name[],
					);
					break;
			}
			if (reverseSort)
				items.reverse();
			if (dirsFirst)
				items.sort!(
					(a, b) => !!a.firstChild > !!b.firstChild,
					SwapStrategy.stable,
				);

			if (!selection && items.length)
				selection = items[0];

			if (!items.length && mode == Mode.browser && currentPath !is &browserRoot)
			{
				mode = Mode.info;
				textScrollContext = ScrollContext.init;
			}

			auto totalSamples = browserRoot.data[SampleType.represented].samples;

			eraseWindow();
			enum minHeight =
				1 + // Top status bar
				1 + // Frame title
				1 + // Top overflow marker
				1 + // Content
				1 + // Bottom overflow marker
				1;  // Bottom status bar
			if (height < minHeight || width < 40)
			{
				xOverflowWords({ yOverflowHidden({
					write("Window too small");
				}); });
				return;
			}

			// Render outer frame
			reverse({
				xOverflowEllipsis({
					// Top bar
					at(0, 0, { write(" btdu v" ~ btduVersion ~ " @ ", fsPath, endl); });
					if (imported)
						at(width - 10, 0, { write(" [IMPORT] "); });
					else
					if (paused)
						at(width - 10, 0, { write(" [PAUSED] "); });

					// Bottom bar
					at(0, height - 1, {
						if (message && MonoTime.currTime < showMessageUntil)
							xOverflowEllipsis({
								write(" ", message);
							});
						else
						{
							write(" Samples: ", bold(totalSamples));

							write("  Resolution: ");
							if (totalSamples)
								write("~", bold((totalSize / totalSamples).humanSize()));
							else
								write(bold("-"));

							if (expert)
								write("  Size metric: ", bold(sizeDisplayMode.to!string.chomp("_")));
						}
						write(endl);
					});
				});
			});

			alias button = (text) => reversed("[", bold(text), "]");

			void drawInfo(BrowserPath* p)
			{
				void writeExplanation()
				{
					if (p is &browserRoot)
						return write(
							"Welcome to btdu. You are in the hierarchy root; ",
							"results will be arranged according to their block group and profile, and then by path.",
							endl, endl,
							"Use ", button("↑"), " ", button("↓"), " ", button("←"), " ", button("→"), " to navigate, press ", button("?"), " for help."
						);

					string name = p.name[];
					if (name.skipOverNul())
					{
						switch (name)
						{
							case "DATA":
								return write(
									"This node holds samples from chunks in the ", bold("DATA block group"), ", ",
									"which mostly contains file data."
								);
							case "METADATA":
								return write(
									"This node holds samples from chunks in the ", bold("METADATA block group"), ", ",
									"which contains btrfs internal metadata arranged in b-trees.",
									endl, endl,
									"The contents of small files may be stored here, in line with their metadata.",
									endl, endl,
									"The contents of METADATA chunks is opaque to btdu, so this node does not have children."
								);
							case "SYSTEM":
								return write(
									"This node holds samples from chunks in the ", bold("SYSTEM block group"), ", ",
									"which contains some core btrfs information, such as how to map physical device space to linear logical space or vice-versa.",
									endl, endl,
									"The contents of SYSTEM chunks is opaque to btdu, so this node does not have children."
								);
							case "SINGLE":
							case "RAID0":
							case "RAID1":
							case "DUP":
							case "RAID10":
							case "RAID5":
							case "RAID6":
							case "RAID1C3":
							case "RAID1C4":
								return write(
									"This node holds samples from chunks in the ", bold(name, " profile"), "."
								);
							case "ERROR":
								return write(
									"This node represents sample points for which btdu encountered an error when attempting to query them.",
									endl, endl,
									"Children of this node indicate the encountered error, and may have a more detailed explanation attached."
								);
							case "ROOT_TREE":
								return write(
									"This node holds samples with inodes contained in the BTRFS_ROOT_TREE_OBJECTID object.",
									endl, endl,
									"These samples are not resolvable to paths, and most likely indicate some kind of metadata. ",
									"(If you know, please tell me!)"
								);
							case "NO_INODE":
								return write(
									"This node represents sample points for which btrfs successfully completed our request ",
									"to look up inodes at the given logical offset, but did not actually return any inodes.",
									endl, endl,
									"One possible cause is data which was deleted recently.",
									endl, endl,
									"Due to a bug, under Linux versions 6.2 and 6.3, samples which would otherwise be classified as <UNREACHABLE> will appear here instead. ",
									"If your kernel is affected by this bug, try a different version to obtain more information about how this space is used."
								);
							case "NO_PATH":
								return write(
									"This node represents sample points for which btrfs successfully completed our request ",
									"to look up filesystem paths for the given inode, but did not actually return any paths."
								);
							case "UNREACHABLE":
								return write(
									"This node represents sample points in extents which are not used by any files.", endl,
									"Despite not being directly used, these blocks are kept because another part of the extent they belong to is actually used by files.",
									endl, endl,
									"This can happen if a large file is written in one go, and then later one block is overwritten - ",
									"btrfs may keep the old extent which still contains the old copy of the overwritten block.",
									endl, endl,
									"Children of this node indicate the path of files using the extent containing the unreachable samples. ",
									"Defragmentation of these files may reduce the amount of such unreachable blocks.",
									endl, endl,
									"More precisely, this node represents samples for which BTRFS_IOC_LOGICAL_INO returned zero results, ",
									"but BTRFS_IOC_LOGICAL_INO_V2 with BTRFS_LOGICAL_INO_ARGS_IGNORE_OFFSET returned something else."
								);
							case "UNUSED":
								return write(
									"btrfs reports that there is nothing at the random sample location that btdu picked.",
									endl, endl,
									"This most likely represents allocated but unused space, ",
									"which could be reduced by running a balance on the DATA block group.",
									endl, endl,
									"More precisely, this node represents samples for which BTRFS_IOC_LOGICAL_INO returned ENOENT."
								);
							case "UNALLOCATED":
								return write(
									"This node represents sample points in physical device space which are not allocated to any block group.", endl,
									"As such, these samples do not have corresponding logical offsets.",
									endl, endl,
									"A healthy btrfs filesystem should have at least some unallocated space, in order to allow the metadata block group to grow.", endl,
									"If you have too little unallocated space, consider running a balance on the DATA block group, to convert unused DATA space to unallocated space.", endl,
									"(You will find unused DATA space in btdu under a <UNUSED> node.)",
									endl, endl,
									"More precisely, this node represents samples which are not covered by BTRFS_DEV_EXTENT_KEY entries in BTRFS_DEV_TREE_OBJECTID."
								);
							case "SLACK":
								return write(
									"This node represents sample points in physical device space which are beyond the end of the btrfs filesystem.", endl,
									"As such, these samples do not have corresponding logical offsets.",
									endl, endl,
									"The presence of this node indicates that the space allocated for the btrfs filesystem ",
									"is smaller than the underlying block device (usually a disk partition).",
									endl, endl,
									"To make this space available to the filesystem, the btrfs device can be resized to fill the entire block device ",
									"with `btrfs filesystem resize`, specifying `max` for the size parameter.",
									endl, endl,
									"More precisely, this node represents samples in physical device space which are greater than btrfs_ioctl_dev_info_args::total_bytes ",
									"but less than the size of the file or block device at btrfs_ioctl_dev_info_args::path."
								);
							default:
								if (name.skipOver("TREE_"))
									return write(
										"This node holds samples with inodes contained in the tree #", bold(name), ", ",
										"but btdu failed to resolve this tree number to an absolute path.",
										endl, endl,
										"One possible cause is subvolumes which were deleted recently.",
										endl, endl,
										"Another possible cause is \"ghost subvolumes\", a form of corruption which causes some orphan subvolumes to not get cleaned up."
									);
								debug assert(false, "Unknown special node: " ~ name);
						}
					}

					if (p.parent && p.parent.name[] == "\0ERROR")
					{
						switch (name)
						{
							case "Unresolvable root":
								return write(
									"btdu failed to resolve this tree number to an absolute path."
								);
							case "logical ino":
								return write(
									"An error occurred while trying to look up which inodes use a particular logical offset.",
									endl, endl,
									"Children of this node indicate the encountered error code, and may have a more detailed explanation attached."
								);
							case "open":
								return write(
									"btdu failed to open the filesystem root containing an inode.",
									endl, endl,
									"Children of this node indicate the encountered error code, and may have a more detailed explanation attached."
								);
							default:
						}
					}

					if (p.parent && p.parent.parent && p.parent.parent.name[] == "\0ERROR")
					{
						switch (p.parent.name[])
						{
							case "logical ino":
								switch (name)
								{
									case "ENOENT":
										assert(false); // Should have been rewritten into UNUSED
									case "ENOTTY":
										return write(
											"An ENOTTY (\"Inappropriate ioctl for device\" error means that btdu issued an ioctl which the kernel btrfs code does not understand.",
											endl, endl,
											"The most likely cause is that you are running an old kernel version. ",
											"If you update your kernel, btdu might be able to show more information instead of this error."
										);
									default:
								}
								break;
							case "ino paths":
								switch (name)
								{
									case "ENOENT":
										// Reproducible with e.g.: ( dd if=/dev/zero bs=1M count=512 ; rm a ; sleep infinity ) > a
										// on 5.17.9
										// https://gist.github.com/CyberShadow/10c1c1f66ba3808fdaf9497b22f5896c#file-ino-paths-enoent-sh
										return write(
											"This node represents samples in files for which btrfs provided an inode, ",
											"but responded with \"not found\" when attempting to look up filesystem paths for the given inode.",
											endl, endl,
											"One likely explanation is files which are awaiting deletion, ",
											"but are still kept alive by an open file descriptor held by some process. ",
											"This space could be reclaimed by killing the respective tasks or restarting the system.",
											endl, endl,
											fmtIf(p.parent.parent.parent && p.parent.parent.parent.name[] == "\0UNREACHABLE",
												() => fmtSeq(
													// Reproducible on 5.17.9 with e.g.:
													// https://gist.github.com/CyberShadow/10c1c1f66ba3808fdaf9497b22f5896c#file-unreachable-ino-paths-enoent-sh
													// Was also seen on 5.10.115 in weird (leaky?) circumstances.
													"Because this node is under <UNREACHABLE>, the space represented by this node is actually in extents which are not used by any file (deleted or not), ",
													"but are kept because another part of the extent they belong to is actually used by a deleted-but-still-open file.",
													endl, endl,
													"More precisely, this node represents samples for which BTRFS_IOC_LOGICAL_INO returned zero results, ",
													"then BTRFS_IOC_LOGICAL_INO_V2 with BTRFS_LOGICAL_INO_ARGS_IGNORE_OFFSET returned one or more inodes, ",
													"then attempting to resolve these inodes with BTRFS_IOC_INO_PATHS returned ENOENT."
												),
												() => fmtSeq(
													"More precisely, this node represents samples for which BTRFS_IOC_INO_PATHS returned ENOENT."
												),
											));
									default:
								}
								break;
							case "open":
								switch (name)
								{
									case "ENOENT":
										return write(
											"btdu failed to open the filesystem root containing an inode.",
											endl, endl,
											"The most likely reason for this is that the subvolume containing this inode has been deleted since btdu was started. ",
											"You can restart btdu to see accurate results.",
											endl, endl,
											"You can descend into this node to see the path that btdu failed to open."
										);
									default:
								}
								break;
							default:
						}
					}
				}

				xOverflowWords({
					auto topY = y;
					writeExplanation();
					if (x != 0 || y != topY)
						write(endl, endl);

					if (p.parent && p.parent.parent && p.parent.parent.name[] == "\0ERROR")
					{
						auto errno = p.name[] in errnoLookup;
						if (errno)
						{
							write("Error code: ", *errno, endl);
							auto description = getErrno(*errno).description;
							if (description)
								write("Error message: ", description, endl);
							write(endl);
						}
					}

					alias logicalOffsetStr = stringifiable!(
						(offset, sink)
						{
							switch (offset.logical)
							{
								case logicalOffsetHole : sink("<UNALLOCATED>"); return;
								case logicalOffsetSlack: sink("<SLACK>"); return;
								default: sink.formattedWrite!"%s"(offset.logical);
							}
						}, Offset);
					alias physicalOffsetStr = offset => formatted!"%d:%d"(offset.devID, offset.physical);

					auto sampleCountWidth = getTextWidth(browserRoot.data[expert ? SampleType.shared_ : SampleType.represented].samples);

					if (expert)
					{
						void writeSizeColumn(int column, SizeMetric metric)
						{
							final switch (column)
							{
								case 0:
									auto name = metric.to!string.chomp("_");
									attrSet(Attribute.bold, metric == sizeDisplayMode, {
										write(name[0].toUpper(), name[1..$]);
									});
									break;
								case 1: // size
								case 2: // samples
									if (column == 1) // size
									{
										if (totalSamples == 0)
											write("-");
										else
										{
											auto numSamples = metric == SizeMetric.distributed
												? p.distributedSamples
												: p.data[sizeMetricSampleType(metric)].samples;
											write("~", bold(humanSize(numSamples * real(totalSize) / totalSamples, true)));
											auto showError = metric.among(SizeMetric.represented, SizeMetric.exclusive);
											if (showError)
												write(" ±", humanSize(estimateError(totalSamples, numSamples) * totalSize));
											else
												write("           ");
										}
									}
									else // samples
									{
										if (metric == SizeMetric.distributed)
											write(formatted!"%*.3f"(sampleCountWidth + 4, p.distributedSamples));
										else
											write(formatted!"%*d"(sampleCountWidth, p.data[sizeMetricSampleType(metric)].samples));
									}
									break;
							}
						}

						xOverflowEllipsis({
							writeTable(3, 5,
								(int column, int row)
								{
									final switch (row)
									{
										case 0: return write(only(null, "Size", "Samples")[column]);
										case 1: return writeSizeColumn(column, SizeMetric.represented);
										case 2: return writeSizeColumn(column, SizeMetric.distributed);
										case 3: return writeSizeColumn(column, SizeMetric.exclusive);
										case 4: return writeSizeColumn(column, SizeMetric.shared_);
									}
								},
								(int /*column*/, int row) => row == 0 ? Alignment.center : Alignment.left,
							);
						});
					}
					else
					{
						enum type = SampleType.represented;
						enum showError = true;

						write("Represented size: ", fmtIf(totalSamples > 0,
							() => fmtSeq(
								"~", bold(humanSize(p.data[type].samples * real(totalSize) / totalSamples)),
								fmtIf(showError,
									() => formatted!" ±%s"(humanSize(estimateError(totalSamples, p.data[type].samples) * totalSize)),
									() => "",
								),
								formatted!" (%d sample%s)"(
									p.data[type].samples,
									p.data[type].samples == 1 ? "" : "s",
								),
							),
							() => "-",
						), endl);
					}
					write(endl);

					auto fullPath = getFullPath(p);
					if (fullPath) xOverflowChars({ write("Full path: ", fullPath, endl); });

					write("Average query duration: ", fmtIf(p.data[SampleType.represented].samples > 0,
						() => stdDur(p.data[SampleType.represented].duration / p.data[SampleType.represented].samples).durationAsDecimalString,
						() => "-",
					), endl);

					{
						bool showSeenAs;
						if (p.seenAs.empty)
							showSeenAs = false;
						else
						if (fullPath is null && p.seenAs.length == 1)
							showSeenAs = false; // Not a real file
						else
							showSeenAs = true;

						if (showSeenAs)
						{
							auto representedSamples = p.data[SampleType.represented].samples;
							write(endl, "Shares data with: ", endl, endl);
							auto seenAs = p.seenAs
								.byKeyValue
								.array
								.sort!((ref a, ref b) => a.key < b.key)
								.release;

							auto maxPathWidth = max(5, width - 30);
							writeTable(4, 1 + seenAs.length.to!int,
								(int column, int row)
								{
									if (row == 0)
										return write(only("Path", "%", "Size", "Samples")[column]);
									auto pair = seenAs[row - 1];
									final switch (column)
									{
										case 0:
											return withWindow(0, 0, maxPathWidth, 1, {
												xOverflowEllipsis({
													write(pair.key);
												});
											});
										case 1:
											if (!representedSamples)
												return write("- ");
											return write(pair.value * 100 / representedSamples, "%");
										case 2:
											if (!totalSamples)
												return write("-");
											return write(
												"~", humanSize(pair.value * real(totalSize) / totalSamples),
												// " ±", humanSize(estimateError(totalSamples, pair.value) * totalSize),
											);
										case 3:
											return write(pair.value);
									}
								},
								(int column, int row) => (
									row == 0 ? Alignment.center :
									column == 1 || column == 3 ? Alignment.right :
									Alignment.left
								),
							);
						}
					}

					if (sizeDisplayMode != SizeMetric.distributed && p.data[sizeMetricSampleType(sizeDisplayMode)].samples > 0)
					{
						write(endl, "Latest offsets (", bold(sizeDisplayMode.to!string.chomp("_")), " samples):", endl, endl);
						auto data = p.data[sizeMetricSampleType(sizeDisplayMode)];

						xOverflowEllipsis({
							writeTable(3, 1 + min(data.samples, 4),
								(int column, int row)
								{
									final switch (row)
									{
										case 0: return write(only("n", "Physical", "Logical")[column]);
										case 1: case 2: case 3:
											auto index = 3 - row;
											alias writeOffset = (s)
											{
												static size_t maxWidth = 0;
												auto width = getTextWidth(s);
												maxWidth = max(maxWidth, width);
												return write(formatted!"%*s"(maxWidth - width, ""), s);
											};
											
											final switch (column)
											{
												case 0:
													return write(formatted!"#%*d"(sampleCountWidth, data.samples - row));
												case 1:
													if (!physical)
														return write("-");
													return writeOffset(physicalOffsetStr(data.offsets[index]));
												case 2:
													return writeOffset(logicalOffsetStr(data.offsets[index]));
											}
										case 4: return write(
											column == 0 ? "" :
											column == 1 && !physical ? "" :
											"• • •"
										);
									}
								},
								(int column, int row) => (
									row == 0 || row == 4 ? Alignment.center :
									column == 1 && !physical ? Alignment.center :
									column == 0 ? Alignment.left :
									Alignment.right
								),
							);
						});
					}
				});
			}

			alias drawOverflowMarker = (text)
			{
				static if (is(typeof(text) == typeof(null)))
					enum textWidth = 0;
				else
					auto textWidth = getTextWidth(text);
				if (textWidth == 0 || textWidth + 4 > width)
					while (x < width)
						write("• "d[x % 2]);
				else
				{
					auto textStart = (width - textWidth) / 2;
					auto textEnd = textStart + textWidth;
					while (x < textStart)
						write("• "d[x % 2]);
					write(text);
					assert(x == textEnd);
					while (x < width)
						write("• "d[(width - x - 1) % 2]);
				}
				assert(x == width);
			};

			// Draws a panel with some content, including top frame / title, margins, and overflow text.
			alias drawPanel = (title, topOverflowText, bottomOverflowText, ref ScrollContext c, leftMargin, rightMargin, drawContents)
			{
				assert(x == 0 && y == 0); // Should be done in a fresh window

				// Frame and title
				write("═══"); // TODO: use WACS_... instead?
				reverse({
					write(" ");
					typeof(x) endX;
					withWindow(x, y, width - 4 - x, 1, {
						xOverflowEllipsis({
							write(title);
						});
						endX = min(x, width);
					});
					x += endX;
					write(" ");
				});
				write(endl('═'));

				bool topOverflow, bottomOverflow;

				// Draw contents
				withWindow(leftMargin, 1, width - leftMargin - rightMargin, height - 1, {
				retry:
					eraseWindow();
					auto topY = (-c.top).to!int;
					topOverflow = topY < 0;
					y = topY;
					yOverflowHidden({
						drawContents();
						if (x != 0)
							write(endl);
					});

					c.contentHeight = y - topY;
					c.contentAreaHeight = height;
					bottomOverflow = y > height;
					// Ideally we would want to 1) measure the content 2) perform this upkeep 3) render the content,
					// but as we are rendering info directly to the screen, steps 1 and 3 are one and the same.
					if (c.normalize())
						goto retry; // Our rendering was off, but we now know how to fix it, so do so
				});

				if (topOverflow)
					at(0, 1, { drawOverflowMarker(topOverflowText); });
				if (bottomOverflow)
					at(0, height - 1, { drawOverflowMarker(bottomOverflowText); });
			};

			void drawItems()
			{
				real getUnits(BrowserPath* path)
				{
					final switch (sortMode)
					{
						case SortMode.name:
						case SortMode.size:
							return getSamples(path);
						case SortMode.time:
							return getAverageDuration(path);
					}
				}

				string getUnitsStr(real units)
				{
					final switch (sortMode)
					{
						case SortMode.name:
						case SortMode.size:
							auto samples = units;
							return totalSamples
								? "~" ~ humanSize(samples * real(totalSize) / totalSamples, true).text
								: "?";

						case SortMode.time:
							auto hnsecs = units;
							if (hnsecs == -real.infinity)
								return "?";
							return humanDuration(hnsecs).text;
					}
				}

				auto currentPathUnits = currentPath.I!getUnits();
				auto mostUnits = items.fold!((a, b) => max(a, b.I!getUnits()))(0.0L);

				alias minWidth = (ratioDisplayMode) =>
					"  100.0 KiB ".length +
					[
						""                    .length,
						"[##########] "       .length,
						"[100.0%] "           .length,
						"[100.0% ##########] ".length,
					][ratioDisplayMode] +
					"/".length +
					6;

				foreach (i, child; items)
				{
					auto childY = cast(int)(i - itemScrollContext.top);
					if (childY < 0 || childY >= itemScrollContext.contentAreaHeight)
					{
						// Skip rendering off-screen items
						y++;
						continue;
					}

					auto childUnits = child.I!getUnits();

					attrSet(Attribute.reverse, child is selection, {
						xOverflowEllipsis({
							write(formatted!"%12s "(getUnitsStr(childUnits)));

							auto effectiveRatioDisplayMode = ratioDisplayMode;
							while (effectiveRatioDisplayMode && width < minWidth(effectiveRatioDisplayMode))
								effectiveRatioDisplayMode = RatioDisplayMode.none;

							if (effectiveRatioDisplayMode)
							{
								write('[');
								if (effectiveRatioDisplayMode & RatioDisplayMode.percentage)
								{
									if (currentPathUnits)
										write(formatted!"%5.1f%%"(100.0 * childUnits / currentPathUnits));
									else
										write("    -%");
								}
								if (effectiveRatioDisplayMode == RatioDisplayMode.both)
									write(' ');
								if (effectiveRatioDisplayMode & RatioDisplayMode.graph)
								{
									char[10] bar;
									if (mostUnits && childUnits != -real.infinity)
									{
										auto barPos = cast(size_t)(10 * childUnits / mostUnits);
										bar[0 .. barPos] = '#';
										bar[barPos .. $] = ' ';
									}
									else
										bar[] = '-';
									write(bar[]);
								}
								write("] ");
							}
							write(child.firstChild is null ? ' ' : '/');

							{
								auto displayedItem = child.humanName.to!dstring;
								auto maxItemWidth = width - (minWidth(effectiveRatioDisplayMode) - 5);
								if (maxItemWidth >= 3 && displayedItem.length > maxItemWidth)
								{
									auto ellipsis = maxItemWidth >= 9 ? "..."d : "…"d;
									auto leftLength = (maxItemWidth - ellipsis.length) / 2;
									auto rightLength = maxItemWidth - ellipsis.length - leftLength;
									displayedItem =
										displayedItem[0 .. leftLength] ~ ellipsis ~
										displayedItem[$ - rightLength .. $];
								}
								write(displayedItem);
							}

							write(endl);
						});
					});
				}
			}

			alias drawInfoPanel = (titlePrefix, overflowKeyText, leftMargin, rightMargin, auto ref ScrollContext scrollContext, BrowserPath* p)
			{
				static if (is(typeof(overflowKeyText) == typeof(null)))
					enum bottomOverflowText = null;
				else
					auto bottomOverflowText = fmtSeq(" more - press ", overflowKeyText, " to view ");

				drawPanel(
					fmtSeq(titlePrefix, bold(p is &browserRoot ? "/" : p.humanName)),
					null,
					bottomOverflowText,
					scrollContext,
					leftMargin, rightMargin,
					{
						drawInfo(p);
					},
				);
			};

			// Render contents
			withWindow(0, 1, width, height - 2, {
				final switch (mode)
				{
					case Mode.browser:
					case Mode.deleteConfirm:
					case Mode.deleteProgress:

						// Items
						auto infoWidth = min(60, (width - 1) / 2);
						auto itemsWidth = width - infoWidth - 1;
						withWindow(0, 0, itemsWidth, height, {
							itemScrollContext.contentHeight = items.length;
							itemScrollContext.contentAreaHeight = height - 1;
							itemScrollContext.cursor = selection && items ? items.countUntil(selection) : 0;
							itemScrollContext.normalize();

							auto displayedPath = currentPath is &browserRoot ? "/" : currentPath.pointerWriter.text;
							auto maxPathWidth = width - 8 /*- prefix.length*/;
							if (displayedPath.length > maxPathWidth)
								displayedPath = "…" ~ displayedPath[$ - (maxPathWidth - 1) .. $];
							drawPanel(bold(displayedPath), null, null, itemScrollContext, 0, 1, &drawItems);

							assert(itemScrollContext.contentHeight == items.length);
						});

						// "Viewing:"
						auto currentInfoHeight = selection ? height / 2 : height;
						withWindow(itemsWidth + 1, 0, infoWidth, currentInfoHeight, {
							drawInfoPanel("Viewing: ", button("i"), 1, 0, ScrollContext.init, currentPath);
						});

						// "Selected:"
						if (selection)
							withWindow(itemsWidth + 1, currentInfoHeight, infoWidth, height - currentInfoHeight, {
								auto moreButton = fmtIf(
									selection.firstChild !is null,
									fmtSeq(button("→"), " ", button("i")).valueFunctor,
									       button("→")                   .valueFunctor,
								);
								drawInfoPanel("Selected: ", moreButton, 1, 0, ScrollContext.init, selection);
							});

						// Vertical separator
						foreach (y; 0 .. height)
							at(itemsWidth, y, {
								write(
									y == 0                 ? '╦' :
									y == currentInfoHeight ? '╠' :
									                         '║'
								);
							});

						break;

					case Mode.info:
						drawInfoPanel("Details: ", null, 0, 0, textScrollContext, currentPath);
						break;

					case Mode.help:
						drawPanel(
							"Help",
							fmtSeq(" more - press ", button("↑"), " to view "),
							fmtSeq(" more - press ", button("↓"), " to view "),
							textScrollContext,
							1, 1,
							{
								xOverflowEllipsis({
									static immutable title = "btdu - the sampling disk usage profiler for btrfs";
									write(
										title, endl,
										'─'.repeat(title.length), endl,
										endl,
										"Keys:", endl,
										endl,
									);
									void printKey(Buttons...)(string text, auto ref Buttons buttons)
									{
										write(text, " ");
										auto buttonsX = title.length - getTextWidth(buttons) - 1;
										while (x < buttonsX)
											write("·");
										write(" ", buttons, endl);
									}
									printKey("Show this help screen", button("F1"), " ", button("?"));
									printKey("Move cursor up", button("↑"), " ", button("k"));
									printKey("Move cursor down", button("↓"), " ", button("j"));
									printKey("Open selected node", button("↵ Enter"), " ", button("→"), " ", button("l"));
									printKey("Return to parent node", button("←"), " ", button("h"));
									printKey("Pause/resume", button("p"));
									printKey("Sort by name (ascending/descending)", button("n"));
									printKey("Sort by size (ascending/descending)", button("s"));
									printKey("Show / sort by avg. query duration", button("⇧ Shift"), "+", button("T"));
									printKey("Cycle size metric [expert mode]", button("m"));
									printKey("Toggle dirs before files when sorting", button("t"));
									printKey("Show percentage and/or graph", button("g"));
									printKey("Expand/collapse information panel", button("i"));
									printKey("Delete the selected file or directory", button("d"));
									printKey("Close information panel or quit btdu", button("q"));
									write(
										endl,
										"Press ", button("q"), " to exit this help screen and return to btdu.", endl,
										endl,
										"For terminology explanations, see:", endl,
										"https://github.com/CyberShadow/btdu/blob/master/CONCEPTS.md", endl,
										endl,
										"https://github.com/CyberShadow/btdu", endl,
										"Created by: Vladimir Panteleev <https://cy.md/>", endl,
										endl,
									);
								});
							});
						break;
				}
			});

			// Render pop-up
			(){
				final switch (mode)
				{
					case Mode.browser:
					case Mode.info:
					case Mode.help:
						return;

					case Mode.deleteConfirm:
					case Mode.deleteProgress:
				}

				string title;
				void drawPopup()
				{
					xOverflowWords({
						final switch (mode)
						{
							case Mode.browser:
							case Mode.info:
							case Mode.help:
								assert(false);

							case Mode.deleteConfirm:
								title = "Confirm deletion";
								write("Are you sure you want to delete:", endl, endl);
								xOverflowPath({ write(bold(getFullPath(selection)), endl, endl); });
								if (expert && totalSamples)
									write(
										"This will free ~", bold(humanSize(selection.data[SampleType.exclusive].samples * real(totalSize) / totalSamples)),
										" (±", humanSize(estimateError(totalSamples, selection.data[SampleType.exclusive].samples) * totalSize), ").", endl,
										endl,
									);
								write("Press ", button("⇧ Shift"), "+", button("Y"), " to confirm,", endl,
									"any other key to cancel.", endl,
								);
								break;

							case Mode.deleteProgress:
								final switch (deleter.state)
								{
									case Deleter.State.none:
									case Deleter.State.success:
										assert(false);
									case Deleter.State.subvolumeConfirm:
										title = "Confirm subvolume deletion";
										write("Are you sure you want to delete the subvolume:", endl, endl);
										xOverflowPath({ write(bold(deleter.current), endl, endl); });
										write("Press ", button("⇧ Shift"), "+", button("Y"), " to confirm,", endl,
											"any other key to cancel.", endl,
										);
										break;

									case Deleter.State.progress:
									case Deleter.State.subvolumeProgress:
										title = "Deletion in progress";
										synchronized(deleter.thread)
										{
											if (deleter.stopping)
												write("Stopping deletion:", endl, endl);
											else
												write("Deleting", (deleter.state == Deleter.State.subvolumeProgress ? " the subvolume" : ""), ":", endl, endl);
											xOverflowPath({ write(bold(deleter.current), endl); });
											if (!deleter.stopping)
												write(endl, "Press ", button("q"), " to stop.");
										}
										break;

									case Deleter.State.error:
										title = "Deletion error";
										write("Error deleting:", endl, endl);
										xOverflowPath({ write(bold(deleter.current), endl, endl); });
										write(deleter.error, endl, endl);
										write(
											"Displayed usage may be inaccurate;", endl,
											"please restart btdu.", endl,
										);
										break;
								}
								break;
						}
					});
				}

				typeof(x)[2] size;
				withWindow(0, 0, width - 6, height, {
					size = measure(&drawPopup);
				});

				auto winW = (size[0] + 6).to!int;
				auto winH = (size[1] + 4).to!int;
				auto winX = (width - winW) / 2;
				auto winY = (height - winH) / 2;
				withWindow(winX, winY, winW, winH, {
					eraseWindow();

					foreach (y; 0 .. height)
						foreach (x; iota(0, width, y.among(0, height - 1) ? 1 : width - 1))
							at(x, y, { write(
								y == 0 ? (
									x == 0         ? '╔' :
									x == width - 1 ? '╗' :
									                 '═'
								) :
								y == height - 1 ? (
									x == 0         ? '╚' :
									x == width - 1 ? '╝' :
									                 '═'
								) : '║'
							); });
					if (width - 6 > title.length)
						at((width - title.length).to!int / 2, 0, {
							write(reversed(" ", title, " "));
						});

					withWindow(3, 2, width - 6, height - 4, {
						drawPopup();
					});
				});
			}();
		}
	}

	void moveCursor(sizediff_t delta)
	{
		if (!items.length)
			return;
		auto pos = items.countUntil(selection);
		if (pos < 0)
			return;
		pos += delta;
		if (pos < 0)
			pos = 0;
		if (pos > items.length - 1)
			pos = items.length - 1;
		selection = items[pos];
	}

	/// Pausing has the following effects:
	/// 1. We send a SIGSTOP to subprocesses, so that they stop working ASAP.
	/// 2. We immediately stop reading subprocess output, so that the UI stops updating.
	/// 3. We display the paused state in the UI.
	void togglePause()
	{
		if (imported)
		{
			showMessage("Viewing an imported file, cannot pause / unpause");
			return;
		}

		paused = !paused;
		foreach (ref subprocess; subprocesses)
			subprocess.pause(paused);
	}

	void setSort(SortMode mode)
	{
		if (sortMode == mode)
			reverseSort = !reverseSort;
		else
		{
			sortMode = mode;
			reverseSort = false;
		}

		bool ascending;
		final switch (sortMode)
		{
			case SortMode.name: ascending = !reverseSort; break;
			case SortMode.size: ascending =  reverseSort; break;
			case SortMode.time: ascending =  reverseSort; break;
		}

		showMessage(format("Sorting by %s (%s)", mode, ["descending", "ascending"][ascending]));
	}

	bool handleInput()
	{
		auto ch = curses.readKey();

		if (ch == Curses.Key.none)
			return false; // no events - would have blocked
		else
			message = null;

		switch (ch)
		{
			case 'p':
				togglePause();
				return true;
			case '?':
			case Curses.Key.f1:
				mode = Mode.help;
				textScrollContext = ScrollContext.init;
				break;
			default:
				// Proceed according to mode
		}

		final switch (mode)
		{
			case Mode.browser:
				switch (ch)
				{
					case Curses.Key.left:
					case 'h':
					case '<':
						if (currentPath.parent)
						{
							selection = currentPath;
							currentPath = currentPath.parent;
							itemScrollContext = ScrollContext.init;
						}
						else
							showMessage("Already at top-level");
						break;
					case Curses.Key.right:
					case '\n':
						if (selection)
						{
							currentPath = selection;
							selection = null;
							itemScrollContext = textScrollContext = ScrollContext.init;
						}
						else
							showMessage("Nowhere to descend into");
						break;
					case Curses.Key.up:
					case 'k':
						moveCursor(-1);
						break;
					case Curses.Key.down:
					case 'j':
						moveCursor(+1);
						break;
					case Curses.Key.pageUp:
						moveCursor(-itemScrollContext.contentAreaHeight);
						break;
					case Curses.Key.pageDown:
						moveCursor(+itemScrollContext.contentAreaHeight);
						break;
					case Curses.Key.home:
						moveCursor(-itemScrollContext.contentHeight);
						break;
					case Curses.Key.end:
						moveCursor(+itemScrollContext.contentHeight);
						break;
					case 'i':
						mode = Mode.info;
						textScrollContext = ScrollContext.init;
						break;
					case 'q':
						done = true;
						break;
					case 'n':
						setSort(SortMode.name);
						break;
					case 's':
						setSort(SortMode.size);
						break;
					case 'T':
						setSort(SortMode.time);
						break;
					case 'm':
						if (expert)
						{
							sizeDisplayMode = cast(SizeMetric)((sizeDisplayMode + 1) % enumLength!SizeMetric);
							showMessage("Showing %s size".format(sizeDisplayMode.to!string.chomp("_")));
						}
						else
							showMessage("Not in expert mode - re-run with --expert");
						break;
					case 't':
						dirsFirst = !dirsFirst;
						showMessage(format("%s directories before files",
								dirsFirst ? "Sorting" : "Not sorting"));
						break;
					case 'g':
						ratioDisplayMode++;
						ratioDisplayMode %= enumLength!RatioDisplayMode;
						showMessage(format("Showing %s", ratioDisplayMode));
						break;
					case 'd':
						if (!selection)
						{
							showMessage("Nothing to delete.");
							break;
						}
						if (!getFullPath(selection))
						{
							showMessage("Cannot delete special node " ~ selection.humanName ~ ".");
							break;
						}
						mode = Mode.deleteConfirm;
						break;
					default:
						// TODO: show message
						break;
				}
				break;

			case Mode.info:
				switch (ch)
				{
					case Curses.Key.left:
					case 'h':
					case '<':
						mode = Mode.browser;
						if (currentPath.parent)
						{
							selection = currentPath;
							currentPath = currentPath.parent;
						}
						break;
					case 'q':
					case 27: // ESC
						if (items.length)
							goto case 'i';
						else
							goto case Curses.Key.left;
					case 'i':
						mode = Mode.browser;
						break;

					default:
						goto textScroll;
				}
				break;

			case Mode.help:
				switch (ch)
				{
					case 'q':
					case 27: // ESC
						mode = Mode.browser;
						break;

					default:
						goto textScroll;
				}
				break;

			case Mode.deleteConfirm:
				switch (ch)
				{
					case 'Y':
						mode = Mode.deleteProgress;
						deleter.start(getFullPath(selection).idup);
						break;

					default:
						mode = Mode.browser;
						showMessage("Delete operation cancelled.");
						break;
				}
				break;

			case Mode.deleteProgress:
				final switch (deleter.state)
				{
					case Deleter.State.none:
					case Deleter.State.success:
						assert(false);

					case Deleter.State.subvolumeConfirm:
						switch (ch)
						{
							case 'Y':
								deleter.confirm(Yes.proceed);
								break;

							default:
								deleter.confirm(No.proceed);
								break;
						}
						break;

					case Deleter.State.progress:
					case Deleter.State.subvolumeProgress:
						switch (ch)
						{
							case 'q':
							case 27: // ESC
								deleter.stop();
								break;

							default:
								// TODO: show message
								break;
						}
						break;

					case Deleter.State.error:
						switch (ch)
						{
							case 'q':
							case 27: // ESC
								deleter.finish();
								mode = Mode.browser;
								break;

							default:
								// TODO: show message
								break;
						}
						break;
				}
				break;

			textScroll:
				switch (ch)
				{
					case Curses.Key.up:
					case 'k':
						textScrollContext.top += -1;
						break;
					case Curses.Key.down:
					case 'j':
						textScrollContext.top += +1;
						break;
					case Curses.Key.pageUp:
						textScrollContext.top += -textScrollContext.contentAreaHeight;
						break;
					case Curses.Key.pageDown:
						textScrollContext.top += +textScrollContext.contentAreaHeight;
						break;
					case Curses.Key.home:
						textScrollContext.top -= textScrollContext.contentHeight;
						break;
					case Curses.Key.end:
						textScrollContext.top += textScrollContext.contentHeight;
						break;
					default:
						// TODO: show message
						break;
				}
				textScrollContext.normalize();
				break;
		}

		return true;
	}
}

private:

/// https://en.wikipedia.org/wiki/1.96
// enum z_975 = normalDistributionInverse(0.975);
enum z_975 = 1.96;

// https://stackoverflow.com/q/69420422/21501
// https://stats.stackexchange.com/q/546878/234615
double estimateError(
	/// Total samples
	double n,
	/// Samples within the item
	double m,
	/// Standard score for desired confidence
	/// (default is for 95% confidence)
	double z = z_975,
)
{
	import std.math.algebraic : sqrt;

	auto p = m / n;
	auto q = 1 - p;

	auto error = sqrt((p * q) / n);
	return z * error;
}

auto durationAsDecimalString(Duration d) @nogc
{
	assert(d >= Duration.zero);
	auto ticks = d.stdTime;
	enum secondsPerTick = 1.seconds / 1.stdDur;
	static assert(secondsPerTick == 10L ^^ 7);
	return formatted!"%d.%07d seconds"(ticks / secondsPerTick, ticks % secondsPerTick);
}