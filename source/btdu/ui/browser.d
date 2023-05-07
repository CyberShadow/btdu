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
	sizediff_t top; // Scroll offset (row number, in the content, corresponding to the topmost displayed line)
	sizediff_t contentHeight; // Number of total rows in the content
	sizediff_t contentAreaHeight; // Number of rows where scrolling content is displayed
	BrowserPath* selection;
	BrowserPath*[] items;
	bool done;

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

	enum SizeDisplayMode : OriginalType!SampleType
	{
		represented = SampleType.represented,
		exclusive = SampleType.exclusive,
		shared_ = SampleType.shared_,
		distributed,
	}
	SizeDisplayMode sizeDisplayMode = SizeDisplayMode.represented;

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
			case SizeDisplayMode.represented:
			case SizeDisplayMode.exclusive:
			case SizeDisplayMode.shared_:
				return path.data[cast(SampleType)sizeDisplayMode].samples;
			case SizeDisplayMode.distributed:
				return path.distributedSamples;
		}
	}

	private real getDuration(BrowserPath* path)
	{
		final switch (sizeDisplayMode)
		{
			case SizeDisplayMode.represented:
			case SizeDisplayMode.exclusive:
			case SizeDisplayMode.shared_:
				return path.data[cast(SampleType)sizeDisplayMode].duration;
			case SizeDisplayMode.distributed:
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
				mode = Mode.info;

			auto totalSamples = browserRoot.data[SampleType.represented].samples;

			// Render outer frame
			sizediff_t minWidth;
			{
				minWidth =
					"  100.0 KiB ".length +
					[
						""                    .length,
						"[##########] "       .length,
						"[100.0%] "           .length,
						"[100.0% ##########] ".length,
					][ratioDisplayMode] +
					"/".length +
					6;

				if (height < 10 || width < minWidth)
				{
					xOverflowWords({ yOverflowHidden({
						write("Window too small");
					}); });
					return;
				}

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

				string prefix = "";
				final switch (mode)
				{
					case Mode.info:
						prefix = "INFO: ";
						goto case;
					case Mode.browser:
					case Mode.deleteConfirm:
					case Mode.deleteProgress:
						auto displayedPath = currentPath is &browserRoot ? "/" : currentPath.pointerWriter.text;
						auto maxPathWidth = width - 8 - prefix.length;
						if (displayedPath.length > maxPathWidth)
							displayedPath = "..." ~ displayedPath[$ - (maxPathWidth - 3) .. $];

						at(0, 1, { write("--- ", prefix, displayedPath, " ", endl('-')); });
						break;
					case Mode.help:
						break;
				}
			}

			void drawInfo(BrowserPath* p, bool inline)
			{
				auto fullPath = getFullPath(p);

				void showSampleType(SampleType type, string name, bool showError)
				{
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

					return write(
						endl,

						"- ", name, ": ", fmtIf(totalSamples > 0,
							() => formatted!"~%s (%d sample%s)%s"(
								humanSize(currentPath.data[type].samples * real(totalSize) / totalSamples),
								currentPath.data[type].samples,
								currentPath.data[type].samples == 1 ? "" : "s",
								fmtIf(showError,
									() => formatted!", ±%s"(humanSize(estimateError(totalSamples, currentPath.data[type].samples) * totalSize)),
									() => "",
								),
							),
							() => "-",
						), endl,

						// put("  - Average query duration: "), currentPath.data[type].samples
						// 	? format!"%s"(stdDur(currentPath.data[type].duration / currentPath.data[type].samples))
						// 	: put("-"),
						// newLine(),

						expert ? "  " : "", "- Logical offsets: ", fmtIf(currentPath.data[type].samples > 0,
							() => formatted!"%s%-(%s, %)"(
								currentPath.data[type].samples > currentPath.data[type].offsets.length ? "..., " : "",
								currentPath.data[type].offsets[].filter!(o => o != Offset.init).map!logicalOffsetStr,
							),
							() => "-",
						), endl,

						fmtIf(physical,
							() => fmtSeq(
								expert ? "  " : "", "- Physical offsets: ", fmtIf(currentPath.data[type].samples > 0,
									() => formatted!"%s%(%s, %)"(
										currentPath.data[type].samples > currentPath.data[type].offsets.length ? "..., " : "",
										currentPath.data[type].offsets[].filter!(o => o != Offset.init).map!physicalOffsetStr,
									),
									() => "-",
								), endl,
							),
							() => "",
						),
					);
				}

				xOverflowWords({
					if (!inline)
						write(endl);
					write("--- Details: ", inline ? endl('-') : endl);

					if (fullPath) xOverflowChars({ write("- Full path: ", fullPath, endl); });

					if (currentPath.parent && currentPath.parent.parent && currentPath.parent.parent.name[] == "\0ERROR")
					{
						auto errno = currentPath.name[] in errnoLookup;
						if (errno)
						{
							write("- Error code: ", *errno, endl);
							auto description = getErrno(*errno).description;
							if (description)
								write("- Error message: ", description);
						}
					}

					write("- Average query duration: ", fmtIf(currentPath.data[SampleType.represented].samples > 0,
							() => stdDur(currentPath.data[SampleType.represented].duration / currentPath.data[SampleType.represented].samples).durationAsDecimalString,
							() => "-",
						), endl);

					if (expert)
					{
						showSampleType(SampleType.represented, "Represented size", true);

						write(endl,
							"- Distributed size: ", fmtIf(totalSamples > 0,
								() => formatted!"~%s (%1.3f sample%s)"(
									humanSize(currentPath.distributedSamples * real(totalSize) / totalSamples),
									currentPath.distributedSamples,
									currentPath.distributedSamples == 1 ? "" : "s",
								),
								() => "-",
							), endl);

						showSampleType(SampleType.exclusive, "Exclusive size", true);
						showSampleType(SampleType.shared_, "Shared size", false);
					}
					else
						showSampleType(SampleType.represented, "Represented size", true);

					{
						auto explanation = delegate void delegate(Curses.Wand*)() /*@nogc TODO*/ {
							if (currentPath is &browserRoot)
								return w => w.write(
									"Welcome to btdu. You are in the hierarchy root; ",
									"results will be arranged according to their block group and profile, and then by path.",
									endl, endl,
									"Use the arrow keys to navigate, press ? for help."
								);

							string name = currentPath.name[];
							if (name.skipOverNul())
							{
								switch (name)
								{
									case "DATA":
										return w => w.write(
											"This node holds samples from chunks in the DATA block group, ",
											"which mostly contains file data."
										);
									case "METADATA":
										return w => w.write(
											"This node holds samples from chunks in the METADATA block group, ",
											"which contains btrfs internal metadata arranged in b-trees.",
											endl, endl,
											"The contents of small files may be stored here, in line with their metadata.",
											endl, endl,
											"The contents of METADATA chunks is opaque to btdu, so this node does not have children."
										);
									case "SYSTEM":
										return w => w.write(
											"This node holds samples from chunks in the SYSTEM block group, ",
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
										return w => w.write(
											"This node holds samples from chunks in the ", name, " profile."
										);
									case "ERROR":
										return w => w.write(
											"This node represents sample points for which btdu encountered an error when attempting to query them.",
											endl, endl,
											"Children of this node indicate the encountered error, and may have a more detailed explanation attached."
										);
									case "ROOT_TREE":
										return w => w.write(
											"This node holds samples with inodes contained in the BTRFS_ROOT_TREE_OBJECTID object.",
											endl, endl,
											"These samples are not resolvable to paths, and most likely indicate some kind of metadata. ",
											"(If you know, please tell me!)"
										);
									case "NO_INODE":
										return w => w.write(
											"This node represents sample points for which btrfs successfully completed our request ",
											"to look up inodes at the given logical offset, but did not actually return any inodes.",
											endl, endl,
											"One possible cause is data which was deleted recently.",
											endl, endl,
											"Due to a bug, under Linux versions 6.2 and 6.3, samples which would otherwise be classified as <UNREACHABLE> will appear here instead. ",
											"If your kernel is affected by this bug, try a different version to obtain more information about how this space is used."
										);
									case "NO_PATH":
										return w => w.write(
											"This node represents sample points for which btrfs successfully completed our request ",
											"to look up filesystem paths for the given inode, but did not actually return any paths."
										);
									case "UNREACHABLE":
										return w => w.write(
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
										return w => w.write(
											"btrfs reports that there is nothing at the random sample location that btdu picked.",
											endl, endl,
											"This most likely represents allocated but unused space, ",
											"which could be reduced by running a balance on the DATA block group.",
											endl, endl,
											"More precisely, this node represents samples for which BTRFS_IOC_LOGICAL_INO returned ENOENT."
										);
									case "UNALLOCATED":
										return w => w.write(
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
										return w => w.write(
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
											return w => w.write(
												"This node holds samples with inodes contained in the tree #" ~ name ~ ", ",
												"but btdu failed to resolve this tree number to an absolute path.",
												endl, endl,
												"One possible cause is subvolumes which were deleted recently.",
												endl, endl,
												"Another possible cause is \"ghost subvolumes\", a form of corruption which causes some orphan subvolumes to not get cleaned up."
											);
										debug assert(false, "Unknown special node: " ~ name);
								}
							}

							if (currentPath.parent && currentPath.parent.name[] == "\0ERROR")
							{
								switch (name)
								{
									case "Unresolvable root":
										return w => w.write(
											"btdu failed to resolve this tree number to an absolute path."
										);
									case "logical ino":
										return w => w.write(
											"An error occurred while trying to look up which inodes use a particular logical offset.",
											endl, endl,
											"Children of this node indicate the encountered error code, and may have a more detailed explanation attached."
										);
									case "open":
										return w => w.write(
											"btdu failed to open the filesystem root containing an inode.",
											endl, endl,
											"Children of this node indicate the encountered error code, and may have a more detailed explanation attached."
										);
									default:
								}
							}

							if (currentPath.parent && currentPath.parent.parent && currentPath.parent.parent.name[] == "\0ERROR")
							{
								switch (currentPath.parent.name[])
								{
									case "logical ino":
										switch (name)
										{
											case "ENOENT":
												assert(false); // Should have been rewritten into UNUSED
											case "ENOTTY":
												return w => w.write(
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
												return w => w.write(
													"This node represents samples in files for which btrfs provided an inode, ",
													"but responded with \"not found\" when attempting to look up filesystem paths for the given inode.",
													endl, endl,
													"One likely explanation is files which are awaiting deletion, ",
													"but are still kept alive by an open file descriptor held by some process. ",
													"This space could be reclaimed by killing the respective tasks or restarting the system.",
													endl, endl,
													fmtIf(currentPath.parent.parent.parent && currentPath.parent.parent.parent.name[] == "\0UNREACHABLE",
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
												return w => w.write(
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

							return null;
						}();

						if (explanation)
						{
							write(endl, "--- Explanation: ", endl);
							explanation(&wand); write(endl);
						}
					}

					bool showSeenAs;
					if (currentPath.seenAs.empty)
						showSeenAs = false;
					else
					if (fullPath is null && currentPath.seenAs.length == 1)
						showSeenAs = false; // Not a real file
					else
						showSeenAs = true;

					if (showSeenAs)
					{
						auto representedSamples = currentPath.data[SampleType.represented].samples;
						write(endl, "--- Shares data with: ", endl);
						currentPath.seenAs
							.byKeyValue
							.array
							.sort!((ref a, ref b) => a.key < b.key)
							.each!(pair => representedSamples
								? write(formatted!"- %s (%d%%)"(pair.key, pair.value * 100 / representedSamples))
								: write(formatted!"- %s (-%%)"(pair.key))
							)
						;
					}
				});
			}

			// Scrolling and cursor upkeep
			void fixTop()
			{
				// Ensure there is no unnecessary space at the bottom
				if (top + contentAreaHeight > contentHeight)
					top = contentHeight - contentAreaHeight;
				// Ensure we are never scrolled "above" the first row
				if (top < 0)
					top = 0;
			}

			// Used to draw full-screen text content (info and help screens).
			void drawTextScreen(scope void delegate() fn)
			{
				withWindow(0, 2, width, height - 3, {
					auto topY = (-top).to!int;
					y = topY;
					yOverflowHidden({
						fn();
					});
					// TODO: draw overflow markers on top and bottom

					contentHeight = y - topY;
					contentAreaHeight = height;
					// Ideally we would want to 1) measure the content 2) perform this upkeep 3) render the content,
					// but as we are rendering info directly to the screen, steps 1 and 3 are one and the same.
					fixTop();
				});
			}

			contentAreaHeight = (height - 4) / 2; // TODO!

			final switch (mode)
			{
				case Mode.browser:
				case Mode.deleteConfirm:
				case Mode.deleteProgress:
				{
					contentHeight = items.length;
					contentAreaHeight = height - 3;
					contentAreaHeight -= min(/*textLines.length TODO*/10, contentAreaHeight / 2);
					contentAreaHeight = min(contentAreaHeight, contentHeight + 1);
					fixTop();
					{
						// Ensure the selected item is visible
						auto pos = selection && items ? items.countUntil(selection) : 0;
						top = top.clamp(
							pos - contentAreaHeight + 1,
							pos,
						);
					}

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

					foreach (i, child; items)
					{
						auto childY = cast(int)(i - top);
						if (childY < 0 || childY >= contentAreaHeight)
							continue;
						childY += 2;

						auto childUnits = child.I!getUnits();

						attrSet(Attribute.reverse, child is selection, {
							at(0, childY, {
								buf.clear();
								buf.formattedWrite!"%12s "(getUnitsStr(childUnits));

								if (ratioDisplayMode)
								{
									buf.put('[');
									if (ratioDisplayMode & RatioDisplayMode.percentage)
									{
										if (currentPathUnits)
											buf.formattedWrite!"%5.1f%%"(100.0 * childUnits / currentPathUnits);
										else
											buf.put("    -%");
									}
									if (ratioDisplayMode == RatioDisplayMode.both)
										buf.put(' ');
									if (ratioDisplayMode & RatioDisplayMode.graph)
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
										buf.put(bar[]);
									}
									buf.put("] ");
								}
								buf.put(child.firstChild is null ? ' ' : '/');

								{
									auto displayedItem = child.humanName;
									auto maxItemWidth = width - (minWidth - 5);
									if (displayedItem.length > maxItemWidth)
									{
										auto leftLength = (maxItemWidth - "...".length) / 2;
										auto rightLength = maxItemWidth - "...".length - leftLength;
										displayedItem =
											displayedItem[0 .. leftLength] ~ "..." ~
											displayedItem[$ - rightLength .. $];
									}
									buf.put(displayedItem);
								}

								write(buf.get(), endl);
							});
						});
					}

					auto infoY = contentAreaHeight + 2;
					withWindow(0, infoY.to!int, width, (height - infoY - 1).to!int, {
						yOverflowHidden({
							drawInfo(currentPath, true);
						});
						if (y > height)
							at(0, height - 1, { write(" --- more - press i to view --- ", endl); });
					});
					break;
				}

				case Mode.info:
					drawTextScreen({
						drawInfo(currentPath, false);
					});
					break;

				case Mode.help:
					drawTextScreen({
						foreach (line; help)
							write(line, endl);
					});
					break;
			}

			// Pop-up
			(){
				dstring[] lines;

				final switch (mode)
				{
					case Mode.browser:
					case Mode.info:
					case Mode.help:
						return;

					case Mode.deleteConfirm:
						lines = [
							"Are you sure you want to delete:"d,
							null,
							getFullPath(selection).to!dstring,
							null,
						] ~ (expert && totalSamples ? [
							"This will free ~%s (±%s)."d.format(
								humanSize(selection.data[SampleType.exclusive].samples * real(totalSize) / totalSamples),
								humanSize(estimateError(totalSamples, selection.data[SampleType.exclusive].samples) * totalSize),
							),
							null,
						] : null) ~ [
							"Press Shift+Y to confirm,"d,
							"any other key to cancel.",
						];
						break;

					case Mode.deleteProgress:
						final switch (deleter.state)
						{
							case Deleter.State.none:
							case Deleter.State.success:
								assert(false);
							case Deleter.State.subvolumeConfirm:
								lines = [
									"Are you sure you want to delete the subvolume:"d,
									null,
									deleter.current.to!dstring,
									null,
									"Press Shift+Y to confirm,"d,
									"any other key to cancel.",
								];
								break;

							case Deleter.State.progress:
							case Deleter.State.subvolumeProgress:
								synchronized(deleter.thread) lines = [
									deleter.stopping
									? "Stopping deletion:"d
									: "Deleting" ~ (deleter.state == Deleter.State.subvolumeProgress ? " the subvolume"d : "") ~ ":"d,
									null,
									deleter.current.to!dstring,
									null,
									"Press Esc or q to cancel.",
								];
								break;

							case Deleter.State.error:
								lines = [
									"Error deleting:"d,
									null,
									deleter.current.to!dstring,
									null,
									deleter.error.to!dstring,
									null,
									"Displayed usage may be inaccurate;"d,
									"please restart btdu."d,
								];
								break;
						}
						break;
				}

				auto maxW = width - 6;
				for (size_t i = 0; i < lines.length; i++)
				{
					auto line = lines[i];
					if (line.length > maxW)
					{
						auto p = line[0 .. maxW].lastIndexOf('/');
						if (p < 0)
							p = line[0 .. maxW].lastIndexOf(' ');
						if (p < 0)
							p = maxW;
						lines = lines[0 .. i] ~ line[0 .. p] ~ line[p .. $] ~ lines[i + 1 .. $];
					}
				}

				auto winW = (lines.map!(line => line.length).reduce!max + 6).to!int;
				auto winH = (lines.length + 4).to!int;
				auto winX = (width - winW) / 2;
				auto winY = (height - winH) / 2;
				withWindow(winX, winY, winW, winH, {
					box();
					foreach (i, line; lines)
					{
						auto s = line.to!string;
						at(3, (2 + i).to!int, { write(s); });
					}
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
				top = 0;
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
							top = 0;
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
							top = 0;
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
						moveCursor(-contentAreaHeight);
						break;
					case Curses.Key.pageDown:
						moveCursor(+contentAreaHeight);
						break;
					case Curses.Key.home:
						moveCursor(-items.length);
						break;
					case Curses.Key.end:
						moveCursor(+items.length);
						break;
					case 'i':
						mode = Mode.info;
						top = 0;
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
							sizeDisplayMode = cast(SizeDisplayMode)((sizeDisplayMode + 1) % enumLength!SizeDisplayMode);
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
							top = 0;
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
						top = 0;
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
						top = 0;
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
						top += -1;
						break;
					case Curses.Key.down:
					case 'j':
						top += +1;
						break;
					case Curses.Key.pageUp:
						top += -contentAreaHeight;
						break;
					case Curses.Key.pageDown:
						top += +contentAreaHeight;
						break;
					case Curses.Key.home:
						top -= contentHeight;
						break;
					case Curses.Key.end:
						top += contentHeight;
						break;
					default:
						// TODO: show message
						break;
				}
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

static immutable string[] help = q"EOF
btdu - the sampling disk usage profiler for btrfs
-------------------------------------------------

Keys:

      F1, ? - Show this help screen
      Up, k - Move cursor up
    Down, j - Move cursor down
Right/Enter - Open selected node
 Left, <, h - Return to parent node
          p - Pause/resume
          n - Sort by name (ascending/descending)
          s - Sort by size (ascending/descending)
          T - Show and sort by avg. query duration
          m - Cycle size metric [expert mode]
          t - Toggle dirs before files when sorting
          g - Show percentage and/or graph
          i - Expand/collapse information panel
          d - Delete the selected file or directory
          q - Close information panel or quit btdu

Press q to exit this help screen and return to btdu.

For terminology explanations, see:
https://github.com/CyberShadow/btdu/blob/master/CONCEPTS.md

https://github.com/CyberShadow/btdu
Created by: Vladimir Panteleev <https://cy.md/>
EOF".splitLines;
