/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2024, 2025  Vladimir Panteleev <btdu@cy.md>
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
import std.math.algebraic : abs;
import std.math.rounding : round;
import std.range;
import std.string;
import std.traits;
import std.typecons : tuple;

import ae.utils.appender;
import ae.utils.functor.primitives : functor, valueFunctor;
import ae.utils.meta : I, enumLength;
import ae.utils.text;
import ae.utils.text.functor;
import ae.utils.time : stdDur, stdTime;

import btrfs;

import btdu.alloc : StaticAppender;
import btdu.common;
import btdu.impexp : exportData;
import btdu.paths;
import btdu.proto : logicalOffsetHole, logicalOffsetSlack;
import btdu.state;
import btdu.ui.curses;
import btdu.ui.deletion;
import btdu.ui.pathabbrev;

alias imported = btdu.state.imported;

struct Browser
{
	Curses curses;

	BrowserPath* currentPath;
	BrowserPath* previousPath; // when quitting from special BrowserPath pointers
	BrowserPath*[] items;
	bool done;

	struct ScrollContext
	{
		struct Axis
		{
			sizediff_t offset; // Scroll offset (row number, in the content, corresponding to the topmost displayed line)
			sizediff_t contentSize; // Number of total rows in the content
			sizediff_t contentAreaSize; // Number of rows where scrolling content is displayed
			sizediff_t cursor = -1; // The item view has a cursor; include it in upkeep calculations, to ensure it remains visible.

			/// Scrolling and cursor upkeep. Returns true if any changes were made.
			bool normalize()
			{
				auto oldOffset = offset;
				// Ensure there is no unnecessary space at the bottom
				if (offset + contentAreaSize > contentSize)
					offset = contentSize - contentAreaSize;
				// Ensure we are never scrolled "above" the first row
				if (offset < 0)
					offset = 0;
				// Ensure the selected item is visible
				if (cursor >= 0)
				{
					auto minOffset = cursor - contentAreaSize + 1;
					if (contentSize > offset + contentAreaSize) // Bottom overflow marker visible
						minOffset++;
					auto maxOffset = cursor;
					if (offset > 0) // Offset overflow marker visible
						maxOffset--;
					offset = offset.clamp(minOffset, maxOffset);
				}
				return oldOffset != offset;
			}
		}
		Axis x, y;

		bool normalize()
		{
			bool result; // avoid short-circuit evaluation
			result |= x.normalize();
			result |= y.normalize();
			return result;
		}
	}
	ScrollContext textScrollContext;

	struct DirectoryState
	{
		BrowserPath* selection;
		ScrollContext itemScrollContext;
	}
	DirectoryState[BrowserPath*] directoryState;

	@property ref BrowserPath* selection()
	{
		return directoryState.require(currentPath, DirectoryState.init).selection;
	}

	@property ref ScrollContext itemScrollContext()
	{
		return directoryState.require(currentPath, DirectoryState.init).itemScrollContext;
	}

	enum Mode
	{
		browser,
		info,
		help,
	}
	Mode mode;

	enum Popup
	{
		none,
		deleteConfirm,
		deleteProgress,
		rebuild,
	}
	Popup popup;
	string rebuildProgress; // Progress message for rebuild popup

	enum SortMode
	{
		name,
		size,
		delta, // Size change (compare mode)
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

	bool infoPanelsVisible = true;

	Deleter deleter;

	void start()
	{
		curses.start();

		currentPath = browserRootPtr;
	}

	/// Returns true when the UI should be refreshed periodically
	/// even if there are no new samples or user input.
	@property bool needRefresh()
	{
		if (popup == Popup.deleteProgress)
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

	private static StaticAppender!char buf, buf2; // Reusable buffers

	// Returns full path as string, or null.
	private static char[] getFullPath(BrowserPath* path)
	{
		buf.clear();
		if (path.toFilesystemPath(&buf.put!(const(char)[])))
			return buf.peek();
		else
			return null;
	}

	/// Check if a path exactly matches a literal rule (not just a prefix match via **).
	/// A literal pattern starts with ** followed by literal path segments.
	/// Slicing off the ** and matching checks for exact path match.
	private static bool exactlyMatchesLiteralRule(BrowserPath* path, PathPattern pattern)
	{
		return pattern.isLiteral() && path.matchesExactly(pattern);
	}

	/// Returns the display character for path rules: 'P'/'p' for prefer, 'I'/'i' for ignore, ' ' for none
	/// Uppercase = exact literal match, lowercase = glob or prefix match
	private static char getRuleChar(BrowserPath* path)
	{
		foreach (rule; pathRules)
		{
			if (path.matches(rule.pattern))
			{
				bool exact = exactlyMatchesLiteralRule(path, rule.pattern);
				final switch (rule.type)
				{
					case PathRule.Type.prefer:
						return exact ? 'P' : 'p';
					case PathRule.Type.ignore:
						return exact ? 'I' : 'i';
				}
			}
		}
		return ' ';
	}

	/// Toggle a path rule for the selected path.
	/// If an exactly-matching literal rule of the same type exists, remove it.
	/// If an exactly-matching literal rule of the opposite type exists, flip it.
	/// Otherwise, add a new literal rule for this path.
	private void togglePathRule(PathRule.Type ruleType)
	{
		if (!selection)
		{
			showMessage("No item selected");
			return;
		}

		auto fullPath = getFullPath(selection);
		if (!fullPath)
		{
			showMessage("Cannot set rule for special path");
			return;
		}

		// Check if there's an exactly matching literal rule to remove or flip
		foreach (i, ref rule; pathRules)
		{
			if (exactlyMatchesLiteralRule(selection, rule.pattern))
			{
				if (rule.type == ruleType)
				{
					// Same type: remove this rule
					pathRules = pathRules.remove(i);
				}
				else
				{
					// Opposite type: flip it
					rule.type = ruleType;
				}
				doRebuild();
				return;
			}
		}

		// Prepend new rule so it takes precedence
		pathRules = PathRule(ruleType, parsePathPattern(fullPath.idup, fsPath)) ~ pathRules;
		doRebuild();
	}

	/// Start an incremental rebuild of the BrowserPath tree from SharingGroups.
	private void doRebuild()
	{
		assert(popup == Popup.none);
		popup = Popup.rebuild;
		rebuildProgress = "Starting...";
		startRebuild();
	}

	private static real getSamples(BrowserPath* path, SizeMetric metric)
	{
		final switch (metric)
		{
			case SizeMetric.represented:
			case SizeMetric.exclusive:
			case SizeMetric.shared_:
				return path.getSamples(sizeMetricSampleType(metric));
			case SizeMetric.distributed:
				return path.getDistributedSamples();
		}
	}

	private real getSamples(BrowserPath* path) { return getSamples(path, sizeDisplayMode); }

	private static real getDuration(BrowserPath* path, SizeMetric metric)
	{
		final switch (metric)
		{
			case SizeMetric.represented:
			case SizeMetric.exclusive:
			case SizeMetric.shared_:
				return path.getDuration(sizeMetricSampleType(metric));
			case SizeMetric.distributed:
				return path.getDistributedDuration();
		}
	}

	private real getDuration(BrowserPath* path) { return getDuration(path, sizeDisplayMode); }

	private real getAverageDuration(BrowserPath* path)
	{
		auto samples = getSamples(path);
		auto duration = getDuration(path);
		return samples ? duration / samples : -real.infinity;
	}

	private int compareItems(BrowserPath* a, BrowserPath* b)
	{
		static int cmp(T)(T a, T b) { return a < b ? -1 : a > b ? +1 : 0; }
		int firstNonZero(int a, lazy int b) { return a ? a : b; }
		int result;
		if (dirsFirst)
		{
			result = -cmp(!!a.firstChild, !!b.firstChild);
			if (result)
				return result;
		}
		result = {
			final switch (sortMode)
			{
				case SortMode.name:
					return cmp(a.name[], b.name[]);
				case SortMode.size:
					return firstNonZero(
						-cmp(a.I!getSamples(), b.I!getSamples()),
						cmp(a.name[], b.name[]),
					);
				case SortMode.delta:
					auto cmpA = getCompareResult(a, expert ? sizeMetricSampleType(sizeDisplayMode) : SampleType.represented);
					auto cmpB = getCompareResult(b, expert ? sizeMetricSampleType(sizeDisplayMode) : SampleType.represented);
					return firstNonZero(
						-cmp(cmpA.deltaSize, cmpB.deltaSize),
						cmp(a.name[], b.name[]),
					);
				case SortMode.time:
					return firstNonZero(
						-cmp(a.I!getAverageDuration(), b.I!getAverageDuration()),
						cmp(a.name[], b.name[]),
					);
			}
		}();
		if (reverseSort)
			result = -result;
		return result;
	}

	void update()
	{
		debug(check) checkState(); scope(success) debug(check) checkState();

		auto wand = curses.getWand();
		with (wand)
		{
			deleter.update();
			auto deleterState = deleter.getState();
			if (deleterState.status == Deleter.Status.success)
			{
				if (deleter.items.length == 1 && !deleter.items[0].obeyMarks)
					showMessage(format!"Deleted %s."(deleter.items[0].browserPath.humanName));
				else
					showMessage(format!"Deleted %d item%s."(deleter.items.length, deleter.items.length > 1 ? "s" : ""));
				foreach (item; deleter.items)
					item.browserPath.remove(item.obeyMarks);
				invalidateMark();
				popup = Popup.none;
				deleter.finish();
				selection = null;
			}

			static FastAppender!(BrowserPath*) itemsBuf;
			itemsBuf.clear();
			final switch (mode)
			{
				case Mode.browser:
					if (currentPath is &marked)
					{
						struct Node { BrowserPath* path; Node[] children; }
						Node root;
						Node* current = &root;
						browserRoot.enumerateMarks((BrowserPath* path, bool marked, scope void delegate() recurse) {
							auto old = current;
							old.children ~= Node(path);
							current = &old.children[$-1];
							recurse();
							current = old;
						});
						void visit(ref Node n)
						{
							if (n.path)
								itemsBuf.put(n.path);
							n.children.sort!((a, b) => compareItems(a.path, b.path) < 0);
							foreach (ref child; n.children)
								visit(child);
						}
						visit(root);
					}
					else
					{
						for (auto child = currentPath.firstChild; child; child = child.nextSibling)
							itemsBuf.put(child);

						// In compare mode, add deleted items from the compare tree
						if (compareMode)
						{
							auto compareCurrentPath = findInCompareTree(currentPath);
							if (compareCurrentPath)
							{
								// Build a set of names from current path for O(1) lookups
								bool[const(char)[]] existingNames;
								for (auto child = currentPath.firstChild; child; child = child.nextSibling)
									existingNames[child.name[]] = true;

								for (auto compareChild = compareCurrentPath.firstChild; compareChild; compareChild = compareChild.nextSibling)
								{
									// Check if this child exists in the main tree
									auto name = compareChild.name[];
									if (name !in existingNames)
									{
										// Create a placeholder node in the main tree for navigation
										auto placeholder = currentPath.appendName(name);
										itemsBuf.put(placeholder);
									}
								}
							}
						}

						itemsBuf.peek().sort!((a, b) => compareItems(a, b) < 0);
					}
					break;
				case Mode.help:
				case Mode.info:
					break;
			}
			items = itemsBuf.peek();

			if (!selection && items.length)
				selection = items[0];

			if (!items.length)
			{
				if (mode == Mode.browser && currentPath is &marked)
				{
					assert(previousPath);
					currentPath = previousPath;
					previousPath = null;
					showMessage("No more marks");
					return update();
				}
				else
				if (mode == Mode.browser && currentPath !is browserRootPtr)
				{
					mode = Mode.info;
					textScrollContext = ScrollContext.init;
				}
			}

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
					size_t numMarked, numUnmarked;
					browserRoot.enumerateMarks((_, bool marked) { (marked ? numMarked : numUnmarked)++; });
					if (numMarked)
					{
						at(0, 0, {
							if (expert)
							{
								if (markTotalSamples == 0)
									write(" ? in");
								else
								{
									auto estimate = estimateError(markTotalSamples, marked.getSamples(SampleType.exclusive));
									write(formatted!" ~%s (±%s) in"(
										humanSize(estimate.center * real(totalSize) / markTotalSamples),
										humanSize(estimate.halfWidth * totalSize / markTotalSamples),
									));
								}
							}
							write(" ", numMarked);
							if (numUnmarked)
								write(" (-", numUnmarked, ")");
							write(" marked item", numMarked + numUnmarked == 1 ? "" : "s");
							write(endl);
						});
					}
					else
						at(0, 0, { write(" btdu v" ~ btduVersion ~ " @ ", fsPath, endl); });
					// Status indicators on the right side of top bar
					auto indicatorPos = width;
					if (imported)
					{
						indicatorPos -= 10;
						at(indicatorPos, 0, { write(" [IMPORT] "); });
					}
					else if (paused)
					{
						indicatorPos -= 10;
						at(indicatorPos, 0, { write(" [PAUSED] "); });
					}
					if (compareMode)
					{
						indicatorPos -= 11;
						at(indicatorPos, 0, { write(" [COMPARE] "); });
					}

					// Bottom bar
					at(0, height - 1, {
						auto totalSamples = getTotalUniqueSamplesFor(browserRootPtr);
						write(" Samples: ", bold(totalSamples));

						write("  Resolution: ");
						if (totalSamples)
							write("~", bold((totalSize / totalSamples).humanSize()));
						else
							write(bold("-"));

						if (expert)
							write("  Size metric: ", bold(sizeDisplayMode.to!string.chomp("_")));

						write("  Sharing groups: ", bold(numSharingGroups));

						// Good-Turing coverage estimate
						write("  Coverage: ");
						if (totalSamples > 0)
						{
							auto coverage = 1.0 - (cast(double)numSingleSampleGroups / cast(double)totalSamples);
							write("~", bold(formatted!"%.1f%%"(coverage * 100)));
						}
						else
							write(bold("-"));
						write(endl);
					});
				});
			});

			alias button = (text) => reversed("[", bold(text), "]");

			void drawInfo(BrowserPath* p, bool fullScreen)
			{
				void writeExplanation()
				{
					if (p is browserRootPtr)
					{
						if (mode == Mode.browser)
							return write(
								"Welcome to btdu. You are in the hierarchy root; ",
								"results will be arranged according to their block group and profile, and then by path.",
								endl, endl,
								"Use ", button("↑"), " ", button("↓"), " ", button("←"), " ", button("→"), " to navigate, press ", button("?"), " for help."
							);
						else
							return write("The hierarchy root (all samples).");
					}

					if (p is &marked)
						return write(
							"Summary of all marked nodes:"
						);

					string name = p.name[];
					if (name.skipOverNul())
					{
						switch (name)
						{
							case "DATA":
								return write(
									"This node holds samples from chunks in the ", bold("DATA block group"), ", ",
									"which mostly contains file data.",
									fmtIf(p == currentPath,
										"".valueFunctor,
										fmtSeq(
											endl, endl,
											"Press ", button("→"), " to descend into it and view its contents."
										).valueFunctor,
									),
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
									"This node holds samples from chunks in the ", bold(name, " profile"), ".",
									fmtIf(p == currentPath,
										"".valueFunctor,
										fmtSeq(
											endl, endl,
											"Press ", button("→"), " to descend into it and view its contents."
										).valueFunctor,
									),
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
									"Due to a bug, under Linux versions 6.2.0 to 6.2.15 and 6.3.0 to 6.3.2, ",
									"samples which would otherwise be classified as <UNREACHABLE> will appear here instead. ",
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
									"Despite not being directly used, these blocks are kept (and cannot be reused) because another part of the extent they belong to is actually used by files.",
									endl, endl,
									"This can happen if a large file is written in one go, and then later one block is overwritten - ",
									"btrfs may keep the old extent which still contains the old copy of the overwritten block.",
									endl, endl,
									"Children of this node indicate the path of files using the extent containing the unreachable samples. ",
									"Rewriting these files (e.g. with \"cp --reflink=never\") will create new extents without unreachable blocks; ",
									"defragmentation may also reduce the amount of such unreachable blocks.",
									endl, endl,
									"More precisely, this node represents samples for which BTRFS_IOC_LOGICAL_INO returned zero results, ",
									"but BTRFS_IOC_LOGICAL_INO_V2 with BTRFS_LOGICAL_INO_ARGS_IGNORE_OFFSET returned something else.", endl,
									"This effect is also referred to as \"bookend extents\".",
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

				void drawDiskVisualization()
				{
					enum numSectors = DiskMap.numSectors;

					// Calculate grid dimensions: largest that fits, max 128 wide, height = width/2
					int availWidth = width - 2;  // Leave margin

					int cols = 128;
					while (cols > availWidth && cols > 8)
						cols /= 2;
					int rows = cols / 2;

					int numCells = cols * rows;
					int sectorsPerCell = numSectors / numCells;

					// Compute min/max group density for adaptive scaling
					uint minDensity = uint.max;
					uint maxDensity = 0;
					foreach (cell; 0 .. numCells)
					{
						auto state = diskMap.getSectorState(cell * sectorsPerCell, (cell + 1) * sectorsPerCell);
						if (state.hasData && state.dominant == DiskMap.SectorCategory.data && state.groupDensity > 0)
						{
							if (state.groupDensity < minDensity)
								minDensity = state.groupDensity;
							if (state.groupDensity > maxDensity)
								maxDensity = state.groupDensity;
						}
					}
					if (minDensity == uint.max)
						minDensity = 0;

					// Helper to get character for a cell
					dchar getCellChar(size_t cellIndex)
					{
						size_t startSector = cellIndex * sectorsPerCell;
						size_t endSector = startSector + sectorsPerCell;
						auto state = diskMap.getSectorState(startSector, endSector);

						if (!state.hasData)
							return '?';

						final switch (state.dominant) with (DiskMap.SectorCategory)
						{
							case empty: return '?';
							case data:
								// Use density scale
								if (maxDensity == 0 || maxDensity == minDensity)
									return '█';
								auto normalized = cast(float)(state.groupDensity - minDensity) / (maxDensity - minDensity);
								if (normalized < 0.25)
									return '░';
								else if (normalized < 0.5)
									return '▒';
								else if (normalized < 0.75)
									return '▓';
								else
									return '█';
							case unallocated: return 'U';
							case slack: return 'S';
							case metadata: return 'M';
							case system: return 'Y';
							case unreachable: return 'R';
							case unused: return 'X';
							case error: return 'E';
							case orphan: return 'O';
						}
					}

					write("Disk map:", endl);

					// Draw the grid
					foreach (row; 0 .. rows)
					{
						foreach (col; 0 .. cols)
						{
							auto cellIndex = row * cols + col;
							write(getCellChar(cellIndex));
						}
						write(endl);
					}

					// Draw legend
					write(endl, "█▓▒░=density ?=unknown U=unallocated S=slack M=metadata Y=system R=unreachable X=unused E=error O=orphan", endl, endl);
				}

				xOverflowWords({
					auto topY = y;
					writeExplanation();
					if (x != xMargin || y != topY)
						write(endl, endl);

					// Draw disk visualization for root node (only for live sampling)
					if (p is browserRootPtr && !imported)
						drawDiskVisualization();

					if (p.deleted)
						write("(This item was deleted from within btdu.)", endl, endl);

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
						}, const(Offset));
					alias physicalOffsetStr = offset => formatted!"%d:%d"(offset.devID, offset.physical);

					auto sampleCountWidth = getTextWidth(browserRoot.getSamples(expert ? SampleType.shared_ : SampleType.represented));

					if (expert)
					{
						void writeSamples(double numSamples, double totalSamples, bool showError, bool isRoot)
						{
							if (totalSamples == 0)
								write("-");
							else
							{
								auto estimate = estimateError(totalSamples, numSamples, z_975, isRoot);
								write("~", bold(humanSize(estimate.center * real(totalSize) / totalSamples, true)));
								if (showError)
									write(" ±", humanSize(estimate.halfWidth * totalSize / totalSamples));
								else
									write("           ");
							}
						}

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
										auto samples = p.I!getSamples(metric);
										auto totalSamples = getTotalUniqueSamplesFor(p);
										auto showError = !!metric.among(SizeMetric.represented, SizeMetric.exclusive);
										writeSamples(samples, totalSamples, showError, p is browserRootPtr);
									}
									else // samples
									{
										if (metric == SizeMetric.distributed)
											write(formatted!"%*.3f"(sampleCountWidth + 4, p.getDistributedSamples()));
										else
											write(formatted!"%*d"(sampleCountWidth, p.getSamples(sizeMetricSampleType(metric))));
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

						write("Represented size: ");
						auto totalSamples = getTotalUniqueSamplesFor(p);
						if (totalSamples > 0)
						{
							auto estimate = estimateError(totalSamples, p.getSamples(type), z_975, p is browserRootPtr);
							write("~", bold(humanSize(estimate.center * real(totalSize) / totalSamples)));
							if (showError) write(" ±", humanSize(estimate.halfWidth * totalSize / totalSamples));
							write(formatted!" (%d sample%s)"(
								p.getSamples(type),
								p.getSamples(type) == 1 ? "" : "s",
							));
						}
						else
							write("-");
						write(endl);
					}

					// Compare mode: show old size, new size, and delta
					if (compareMode)
					{
						auto cmp = getCompareResult(p, expert ? sizeMetricSampleType(sizeDisplayMode) : SampleType.represented);
						write(endl);

						write("Old size:     ");
						if (cmp.hasOldData)
							write("~", bold(humanSize(cmp.oldSize)));
						else
							write("(new)");
						write(endl);

						write("New size:     ");
						if (cmp.hasNewData)
							write("~", bold(humanSize(cmp.newSize)));
						else
							write("(deleted)");
						write(endl);

						write("Delta:        ");
						auto delta = cmp.deltaSize;
						write(bold(humanRelSize(delta)));
						if (cmp.hasOldData && cmp.oldSize > 0)
							write(formatted!" (%+.1f%%)"(delta / cmp.oldSize * 100));
						write(endl);
					}

					write(endl);

					auto fullPath = getFullPath(p);
					if (fullPath) xOverflowChars({ write("Full path: ", fullPath, endl); });

					write("Average query duration: ");
					if (p.getSamples(SampleType.represented) > 0)
						write(stdDur(p.getDuration(SampleType.represented) / p.getSamples(SampleType.represented)).durationAsDecimalString, endl);
					else
						write("-", endl);

					// Unique sharing groups
					{
						size_t count = 0;
						for (auto group = p.firstSharingGroup; group !is null; group = group.getNext(p.elementRange))
							count++;
						if (count > 0)
						{
							write("Unique sharing groups: ");
							write(count, endl);
						}
					}

					{
						auto seenAsData = p.collectSeenAs();
						bool showSeenAs;
						if (seenAsData.paths.length == 0)
							showSeenAs = false;
						else
						if (fullPath is null && seenAsData.paths.length == 1)
							showSeenAs = false; // Not a real file
						else
							showSeenAs = true;

						if (showSeenAs)
						{
							write(endl, "Shares data with: ", endl, endl);
							auto seenAs = seenAsData.paths
								.byKeyValue
								.map!(kv => tuple!(q{key}, q{value})(kv.key.to!string, kv.value))
								.array
								.sort!((ref a, ref b) => a.key < b.key)
								.release;

							auto maxPathWidth = max(5, width - 30);
							writeTable(4, 1 + seenAs.length.to!int,
								(int column, int row)
								{
									if (row == 0)
										return write(only("Path", "%", "Shared", "Samples")[column]);
									auto pair = seenAs[row - 1];
									final switch (column)
									{
										case 0:
											auto path = pair.key;
											path.skipOver("/"); // Not a true absolute path - relative to FS root
											if (fullScreen)
												return write(path);
											else
											{
												maxX = max(maxX, maxPathWidth);
												// Get neighbor paths for smart abbreviation
												string abovePath = row > 1 ? seenAs[row - 2].key : null;
												string belowPath = row < seenAs.length ? seenAs[row].key : null;
												if (abovePath !is null) abovePath.skipOver("/");
												if (belowPath !is null) belowPath.skipOver("/");

												auto abbreviated = abbreviatePath(path, abovePath, belowPath, maxPathWidth);
												return withWindow(0, 0, maxPathWidth, 1, {
													foreach (seg; abbreviated.segments) {
														if (seg.isUnique)
															write(bold(seg.text));
														else
															write(seg.text);
													}
												});
											}
										case 1:
											if (!seenAsData.total)
												return write("- ");
											return write(pair.value * 100 / seenAsData.total, "%");
										case 2:
											auto totalSamples = getTotalUniqueSamplesFor(p);
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

					if (sizeDisplayMode != SizeMetric.distributed && p.getSamples(sizeMetricSampleType(sizeDisplayMode)) > 0)
					{
						write(endl, "Latest offsets (", bold(sizeDisplayMode.to!string.chomp("_")), " samples):", endl, endl);
						auto sampleType = sizeMetricSampleType(sizeDisplayMode);
						auto samples = p.getSamples(sampleType);
						auto offsets = p.getOffsets(sampleType);

						xOverflowEllipsis({
							writeTable(3, 1 + min(samples, 4),
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
													return write(formatted!"#%*d"(sampleCountWidth, samples - row));
												case 1:
													if (!physical)
														return write("-");
													return writeOffset(physicalOffsetStr(offsets[index]));
												case 2:
													return writeOffset(logicalOffsetStr(offsets[index]));
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

					auto leftX = (-c.x.offset).to!xy_t;
					// leftOverflow = leftX < 0;
					x = maxX = xMargin = leftX;

					auto topY = (-c.y.offset).to!xy_t;
					topOverflow = topY < 0;
					y = topY;

					yOverflowHidden({
						drawContents();
						if (x != xMargin)
							write(endl);
					});

					c.x.contentSize = maxX - leftX;
					c.x.contentAreaSize = width;
					// rightOverflow = x > width;

					c.y.contentSize = y - topY;
					c.y.contentAreaSize = height;
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

			string undiscoveredEst;

			void drawItems()
			{
				auto totalUniqueSamples = getTotalUniqueSamplesFor(currentPath);
				auto totalRootSamples = (browserRootPtr).I!getSamples(); // in the current mode

				struct UnitValue
				{
					real units, unitsLow, unitsHigh;
				}

				UnitValue getUnits(BrowserPath* path)
				{
					final switch (sortMode)
					{
						case SortMode.name:
						case SortMode.size:
							auto samples = path.I!getSamples();
							auto estimate = estimateError(totalRootSamples, samples, z_975, path is browserRootPtr);
							return UnitValue(
								estimate.center,
								estimate.lower,
								estimate.upper,
							);
						case SortMode.delta:
							auto cmp = getCompareResult(path, expert ? sizeMetricSampleType(sizeDisplayMode) : SampleType.represented);
							auto delta = cmp.deltaSize;
							return UnitValue(delta, delta, delta);
						case SortMode.time:
							auto duration = getAverageDuration(path);
							return UnitValue(duration, duration, duration);
					}
				}

				void writeUnits(real units)
				{
					final switch (sortMode)
					{
						case SortMode.name:
						case SortMode.size:
							auto samples = units;
							if (!totalUniqueSamples)
								return write("?");
							return write("~", humanSize(samples * real(totalSize) / totalUniqueSamples, true));

						case SortMode.delta:
							return write(humanRelSize(units, true));

						case SortMode.time:
							auto hnsecs = units;
							if (hnsecs == -real.infinity)
								return write("?");
							return write(humanDuration(hnsecs));
					}
				}

				auto currentPathUnits = currentPath.I!getUnits();
				auto mostUnits = items.fold!((a, b) => max(a, b.I!getUnits().unitsHigh))(0.0L);

				// Whether to show delta values/bars instead of absolute sizes
				auto showDeltaDisplay = compareMode && (sortMode == SortMode.delta || sortMode == SortMode.name);

				// Calculate max absolute delta for bar scaling
				real maxAbsDelta = 0;
				if (showDeltaDisplay)
				{
					foreach (child; items)
					{
						auto cmp = getCompareResult(child, expert ? sizeMetricSampleType(sizeDisplayMode) : SampleType.represented);
						maxAbsDelta = max(maxAbsDelta, abs(cmp.deltaSize));
					}
				}

				auto ratioDisplayMode = this.ratioDisplayMode;
				if (currentPath is &marked)
					ratioDisplayMode = RatioDisplayMode.none;

				alias minWidth = (ratioDisplayMode) =>
					"  100.0 KiB ".length +
					only(
						""                    .length,
						"[##########] "       .length,
						"[100.0%] "           .length,
						"[100.0% ##########] ".length,
					)[ratioDisplayMode] +
					"/".length +
					6;

				typeof(x) fileNameX;  // Captured from loop for undiscovered estimate alignment

				foreach (i, child; items)
				{
					auto childY = cast(int)(i - itemScrollContext.y.offset);
					if (childY < 0 || childY >= itemScrollContext.y.contentAreaSize)
					{
						// Skip rendering off-screen items
						y++;
						continue;
					}

					auto childUnits = child.I!getUnits();

					attrSet(Attribute.reverse, child is selection, {
						xOverflowEllipsis({
							write(
								child.getEffectiveMark() ? '+' :
								currentPath is &marked ? '-' :
								getRuleChar(child)
							);

							// In compare mode, show delta; otherwise show absolute size
							if (showDeltaDisplay)
							{
								auto cmp = getCompareResult(child, expert ? sizeMetricSampleType(sizeDisplayMode) : SampleType.represented);
								auto delta = cmp.deltaSize;

								void writeDelta()
								{
									write(humanRelSize(delta, true));
								}

								auto textWidth = measure({ writeDelta(); })[0];
								write(formatted!"%*s"(max(0, 12 - textWidth), "")); writeDelta(); write(" ");
							}
							else
							{
								auto textWidth = measure({ writeUnits(childUnits.units); })[0];
								write(formatted!"%*s"(max(0, 11 - textWidth), "")); writeUnits(childUnits.units); write(" ");
							}

							auto effectiveRatioDisplayMode = ratioDisplayMode;
							while (effectiveRatioDisplayMode && width < minWidth(effectiveRatioDisplayMode))
								effectiveRatioDisplayMode = RatioDisplayMode.none;

							if (effectiveRatioDisplayMode)
							{
								auto barWidth = max(10, (width - x - 4) / 5);
								// In compare mode, ensure odd width so center '|' is properly centered
								if (showDeltaDisplay && barWidth % 2 == 0)
									barWidth--;

								write('[');
								if (effectiveRatioDisplayMode & RatioDisplayMode.percentage)
								{
									if (currentPathUnits.units)
										write(formatted!"%5.1f%%"(100.0 * childUnits.units / currentPathUnits.units));
									else
										write("    -%");
								}
								if (effectiveRatioDisplayMode == RatioDisplayMode.both)
									write(' ');
								if (effectiveRatioDisplayMode & RatioDisplayMode.graph)
								{
									// Show centered delta bar in compare mode
									if (showDeltaDisplay)
									{
										auto cmp = getCompareResult(child, expert ? sizeMetricSampleType(sizeDisplayMode) : SampleType.represented);
										auto delta = cmp.deltaSize;
										auto center = barWidth / 2;

										if (maxAbsDelta == 0)
										{
											// No changes - show empty bar with center
											foreach (i; 0 .. barWidth)
												write(i == center ? '|' : ' ');
										}
										else
										{
											// Normalize delta to bar position
											auto normalizedDelta = delta / maxAbsDelta;
											auto barPos = cast(int)round(normalizedDelta * center);

											foreach (i; 0 .. barWidth)
											{
												if (i == center)
													write('|');
												else if (barPos < 0 && i >= center + barPos && i < center)
													write('<');
												else if (barPos > 0 && i > center && i <= center + barPos)
													write('>');
												else
													write(' ');
											}
										}
									}
									else if (mostUnits && childUnits.units != -real.infinity)
									{
										auto barPosLow  = cast(size_t)round(barWidth * childUnits.unitsLow  / mostUnits);
										auto barPosHigh = cast(size_t)round(barWidth * childUnits.unitsHigh / mostUnits);
										foreach (_; 0 .. barPosLow)
											write('#');
										foreach (_; barPosLow .. barPosHigh)
											write('?');
										foreach (_; barPosHigh .. barWidth)
											write(' ');
									}
									else
										foreach (_; 0 .. barWidth)
											write('-');
								}
								write("] ");
							}

							auto maxItemWidth = width - (minWidth(effectiveRatioDisplayMode) - 5);

							if (currentPath is &marked)
							{
								withWindow(x, y, maxItemWidth.to!xy_t, 1, {
									middleTruncate({
										if (child is browserRootPtr)
											write("/", endl);
										else
											write(child.pointerWriter, endl);
									});
								});
								x += maxItemWidth;
							}
							else
							{
								fileNameX = x;
								write(child.firstChild is null ? ' ' : '/');

								withWindow(x, y, maxItemWidth.to!xy_t, 1, {
									middleTruncate({
										write(child.humanName, endl);
									});
								});
								x += maxItemWidth;
							}
							write(endl);
						});
					});
				}

				// Render undiscovered estimate below file list
				if (undiscoveredEst !is null)
				{
					auto undiscoveredY = cast(int)(items.length - itemScrollContext.y.offset);
					if (undiscoveredY >= 0 && undiscoveredY < itemScrollContext.y.contentAreaSize)
					{
						dim({
							xOverflowEllipsis({
								write(formatted!"%*s"(fileNameX, ""), "[", undiscoveredEst, "]", endl);
							});
						});
					}
					else
						y++;  // Advance y even if not visible for content size tracking
				}
			}

			alias drawInfoPanel = (titlePrefix, overflowKeyText, bool fullScreen, auto ref ScrollContext scrollContext, BrowserPath* p)
			{
				auto leftMargin = fullScreen ? 0 : 1;
				auto rightMargin = 0;
				static if (is(typeof(overflowKeyText) == typeof(null)))
					enum bottomOverflowText = null;
				else
					auto bottomOverflowText = fmtSeq(" more - press ", overflowKeyText, " to view ");

				drawPanel(
					fmtSeq(titlePrefix, bold(fmtIf(p is browserRootPtr, () => "/", functor!(p => p.humanName)(p)))),
					null,
					bottomOverflowText,
					scrollContext,
					leftMargin, rightMargin,
					{
						drawInfo(p, fullScreen);
					},
				);
			};

			// Render contents
			withWindow(0, 1, width, height - 2, {
				final switch (mode)
				{
					case Mode.browser:

						// Items
						auto infoWidth = infoPanelsVisible ? (width > 240 ? width / 4 : min(60, (width - 1) / 2)) : 0;
						auto itemsWidth = infoPanelsVisible ? width - infoWidth - 1 : width;
						withWindow(infoPanelsVisible ? infoWidth + 1 : 0, 0, itemsWidth, height, {
							undiscoveredEst = currentPath is &marked ? null : estimateUndiscoveredStr(currentPath);
							auto hasUndiscoveredRow = undiscoveredEst !is null;
							itemScrollContext.y.contentSize = items.length + (hasUndiscoveredRow ? 1 : 0);
							itemScrollContext.y.contentAreaSize = height - 1;
							itemScrollContext.y.cursor = selection && items ? items.countUntil(selection) : 0;
							itemScrollContext.y.normalize();

							if (currentPath is &marked)
								drawPanel("Marks", null, null, itemScrollContext, 0, 1, &drawItems);
							else
							{
								auto displayedPath = currentPath is browserRootPtr ? "/" : buf.stringify(currentPath.pointerWriter);
								auto maxPathWidth = width - 8 /*- prefix.length*/;
								if (displayedPath.length > maxPathWidth) // TODO: this slice is wrong
									displayedPath = buf2.stringify!"…%s"(displayedPath[$ - (maxPathWidth - 1) .. $]);
								drawPanel(bold(displayedPath), null, null, itemScrollContext, 0, 1, &drawItems);
							}
						});

						if (infoPanelsVisible)
						{
							// "Viewing:"
							auto currentInfoHeight = selection ? height / 2 : height;
							withWindow(0, 0, infoWidth, currentInfoHeight, {
								if (currentPath is &marked)
								{
									updateMark();
									drawInfoPanel("Summary", button("i"), false, ScrollContext.init, &marked);
								}
								else
									drawInfoPanel("Viewing: ", button("i"), false, ScrollContext.init, currentPath);
							});

							// "Selected:"
							if (selection)
								withWindow(0, currentInfoHeight, infoWidth, height - currentInfoHeight, {
									auto moreButton = fmtIf(
										selection.firstChild !is null,
										fmtSeq(button("→"), " ", button("i")).valueFunctor,
										       button("→")                   .valueFunctor,
									);
									drawInfoPanel("Selected: ", moreButton, false, ScrollContext.init, selection);
								});

							// Vertical separator
							foreach (y; 0 .. height)
								at(infoWidth, y, {
									write(
										y == 0                 ? '╦' :
										y == currentInfoHeight ? '╣' :
										                         '║'
									);
								});
						}

						break;


					case Mode.info:
						drawInfoPanel("Details: ", null, true, textScrollContext, currentPath);
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
										auto buttonsX = xMargin + title.length.to!xy_t - getTextWidth(buttons).to!xy_t - 1;
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
									printKey("Sort by delta [compare mode]", button("c"));
									printKey("Show / sort by avg. query duration", button("⇧ Shift"), "+", button("T"));
									printKey("Cycle size metric [expert mode]", button("m"));
									printKey("Toggle dirs before files when sorting", button("t"));
									printKey("Show percentage and/or graph", button("g"));
									printKey("Expand/collapse information panel", button("i"));
									printKey("Toggle information panels", button("Tab ↹"));
									printKey("Delete the selected file or directory", button("d"));
									printKey("Copy selected path to clipboard", button("y"));
									printKey("Prefer selected path (toggle)", button("⇧ Shift"), "+", button("P"));
									printKey("Ignore selected path (toggle)", button("⇧ Shift"), "+", button("I"));
									printKey("Mark / unmark selected item", button("    "));
									printKey("Invert marks", button("*"));
									printKey("View all marks", button("⇧ Shift"), "+", button("M"));
									printKey("Delete all marked items", button("⇧ Shift"), "+", button("D"));
									printKey("Export results to file", button("⇧ Shift"), "+", button("O"));
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
				if (!popup)
					return;

				string title;
				void drawPopup()
				{
					xOverflowWords({
						final switch (popup)
						{
							case Popup.none:
								assert(false);

							case Popup.deleteConfirm:
								assert(deleterState.status == Deleter.Status.ready);
								title = "Confirm deletion";
								bool single = deleter.items.length == 1 && !deleter.items[0].obeyMarks;
								write("Are you sure you want to delete:", endl, endl);
								xOverflowPath({
									if (single)
										write(bold(deleter.items[0].browserPath.toFilesystemPath), endl);
									else
									{
										foreach (i, item; deleter.items)
										{
											if (i == 10 && deleter.items.length > 11)
											{
												write(bold(formatted!"- (and %d more)"(deleter.items.length - 10)), endl);
												break;
											}
											write("- ", bold(item.browserPath.toFilesystemPath), endl);
											if (item.obeyMarks)
											{
												item.browserPath.enumerateMarks((BrowserPath* path, bool isMarked, scope void delegate() recurse)
													{
														if (!isMarked)
															write("  - except ", bold((path).toFilesystemPath), endl);
														else
														{
															assert(path is item.browserPath);
															recurse();
														}
													});
											}
										}
									}
									write(endl);
								});

								if (deleter.items.any!(item => item.browserPath.firstChild !is null))
								{
									write(bold("Warning: "), "This will delete all files in the directories above,", endl,
										"including those not yet discovered by btdu.", endl, endl);
								}

								if (expert)
								{
									auto p = single
										? selection
										// Assume that we are deleting marked items
										: &marked;
									auto delTotalSamples = getTotalUniqueSamplesFor(p);
									auto delExclusiveSamples = p.getSamples(SampleType.exclusive);
									auto estimate = estimateError(delTotalSamples, delExclusiveSamples);
									write(
										"This will free ~", bold(humanSize(estimate.center * real(totalSize) / delTotalSamples)),
										" (±", humanSize(estimate.halfWidth * totalSize / delTotalSamples), ").", endl,
										endl,
									);
								}
								write("Press ", button("⇧ Shift"), "+", button("Y"), " to confirm,", endl,
									"any other key to cancel.", endl,
								);
								break;

							case Popup.deleteProgress:
								final switch (deleterState.status)
								{
									case Deleter.Status.none:
									case Deleter.Status.ready:
									case Deleter.Status.success:
										assert(false);
									case Deleter.Status.subvolumeConfirm:
										title = "Confirm subvolume deletion";
										write("Are you sure you want to delete the subvolume:", endl, endl);
										xOverflowPath({ write(bold(deleterState.current), endl, endl); });
										write("Press ", button("⇧ Shift"), "+", button("Y"), " to confirm,", endl,
											"any other key to cancel.", endl,
										);
										break;

									case Deleter.Status.progress:
									case Deleter.Status.subvolumeProgress:
										title = "Deletion in progress";
										if (deleterState.stopping)
											write("Stopping deletion:", endl, endl);
										else
											write("Deleting", (deleterState.status == Deleter.Status.subvolumeProgress ? " the subvolume" : ""), ":", endl, endl);
										xOverflowPath({ write(bold(deleterState.current), endl); });
										if (!deleterState.stopping)
											write(endl, "Press ", button("q"), " to stop.");
										break;

									case Deleter.Status.error:
										title = "Deletion error";
										write("Error deleting:", endl, endl);
										xOverflowPath({ write(bold(deleterState.current), endl, endl); });
										write(deleterState.error, endl, endl);
										write(
											"Displayed usage may be inaccurate;", endl,
											"please restart btdu.", endl,
										);
										break;
								}
								break;

							case Popup.rebuild:
								title = "Recalculating";
								write(rebuildProgress, endl);
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
						at((width - title.length.to!int - 2) / 2, 0, {
							write(reversed(" ", title, " "));
						});

					withWindow(3, 2, width - 6, height - 4, {
						drawPopup();
					});
				});
			}();

			// Render toast message popup in bottom-right corner
			if (message && MonoTime.currTime < showMessageUntil)
			{
				void drawToast()
				{
					xOverflowWords({
						write(message);
					});
				}

				// Measure content size within max width constraint
				auto maxContentW = min(60, width - 6);
				typeof(x)[2] size;
				withWindow(0, 0, maxContentW, height - 3, {
					size = measure(&drawToast);
				});

				auto toastW = min((size[0] + 4).to!int, width - 2);   // content + padding + border, clamped
				auto toastH = min((size[1] + 2).to!int, height - 2);  // content + border, clamped
				auto toastX = width - toastW - 1;
				auto toastY = height - toastH - 1;

				withWindow(toastX, toastY, toastW, toastH, {
					eraseWindow();
					// Draw border
					at(0, 0, { write('╭'); });
					foreach (i; 1 .. toastW - 1)
						at(i, 0, { write('─'); });
					at(toastW - 1, 0, { write('╮'); });

					foreach (row; 1 .. toastH - 1)
					{
						at(0, row, { write('│'); });
						at(toastW - 1, row, { write('│'); });
					}

					at(0, toastH - 1, { write('╰'); });
					foreach (i; 1 .. toastW - 1)
						at(i, toastH - 1, { write('─'); });
					at(toastW - 1, toastH - 1, { write('╯'); });

					// Draw message with word wrapping
					withWindow(2, 1, toastW - 4, toastH - 2, {
						drawToast();
					});
				});
			}
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
			case SortMode.name:  ascending = !reverseSort; break;
			case SortMode.size:  ascending =  reverseSort; break;
			case SortMode.delta: ascending =  reverseSort; break;
			case SortMode.time:  ascending =  reverseSort; break;
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
			default:
				// Proceed according to mode
		}

		final switch (popup)
		{
			case Popup.none:
				break;

			case Popup.deleteConfirm:
				switch (ch)
				{
					case 'Y':
						popup = Popup.deleteProgress;
						deleter.start();
						break;

					default:
						popup = Popup.none;
						deleter.cancel();
						showMessage("Delete operation cancelled.");
						break;
				}
				return true;

			case Popup.deleteProgress:
				final switch (deleter.getState().status)
				{
					case Deleter.Status.none:
					case Deleter.Status.ready:
					case Deleter.Status.success:
						assert(false);

					case Deleter.Status.subvolumeConfirm:
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

					case Deleter.Status.progress:
					case Deleter.Status.subvolumeProgress:
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

					case Deleter.Status.error:
						switch (ch)
						{
							case 'q':
							case 27: // ESC
								deleter.finish();
								invalidateMark();
								popup = Popup.none;
								break;

							default:
								// TODO: show message
								break;
						}
						break;
				}
				return true;

			case Popup.rebuild:
				// No input handling during rebuild - it's a blocking operation
				return true;
		}

		final switch (mode)
		{
			case Mode.browser:
				switch (ch)
				{
					case '?':
					case Curses.Key.f1:
						mode = Mode.help;
						textScrollContext = ScrollContext.init;
						break;
					case Curses.Key.left:
					case 'h':
					case '<':
						if (previousPath)
							goto exitSpecialPath;
						if (currentPath.parent)
						{
							auto child = currentPath;
							currentPath = currentPath.parent;
							selection = child;
						}
						else
							showMessage("Already at top-level");
						break;
					case '\n':
						if (selection && selection.parent && currentPath != selection.parent)
						{
							currentPath = selection.parent;
							previousPath = null;
							break;
						}
						goto case Curses.Key.right;
					case Curses.Key.right:
					case 'l':
						if (selection)
						{
							currentPath = selection;
							previousPath = null;
							textScrollContext = ScrollContext.init;
						}
						else
							showMessage("Nowhere to descend into");
						break;
					case 'i':
						mode = Mode.info;
						textScrollContext = ScrollContext.init;
						break;
					case '\t':
						infoPanelsVisible = !infoPanelsVisible;
						break;
					case 'q':
						if (previousPath)
							goto exitSpecialPath;
						done = true;
						break;
					case 27: // ESC
						if (previousPath)
							goto exitSpecialPath;
						break;
					exitSpecialPath:
						assert(previousPath);
						currentPath = previousPath;
						previousPath = null;
						break;
					case ' ':
						if (selection)
						{
							if (currentPath is &marked)
							{
								auto pos = items.countUntil(selection);
								selection.setMark(!selection.getEffectiveMark());
								invalidateMark();
								items = items.remove(pos);
								selection =
									pos >= 0 && pos < items.length ? items[pos] :
									items.length ? items[$-1] :
									null;
							}
							else
							{
								selection.setMark(!selection.getEffectiveMark());
								invalidateMark();
								moveCursor(+1);
							}
						}
						break;
					case '*':
						foreach (item; items)
							item.setMark(!item.getEffectiveMark());
						invalidateMark();
						break;
					case 'M':
						if (currentPath is &marked)
							break;
						bool haveMarked;
						browserRoot.enumerateMarks((_, bool isMarked) { if (isMarked) haveMarked = true; });
						if (haveMarked)
						{
							if (!previousPath)
								previousPath = currentPath;
							currentPath = &marked;
							selection = null;
						}
						else
							showMessage("No marks");
						break;
					case 'P':
						togglePathRule(PathRule.Type.prefer);
						break;
					case 'I':
						togglePathRule(PathRule.Type.ignore);
						break;
					default:
						goto itemScroll;
				}
				break;

			case Mode.info:
				switch (ch)
				{
					case '?':
					case Curses.Key.f1:
						mode = Mode.help;
						textScrollContext = ScrollContext.init;
						break;
					case '<':
						mode = Mode.browser;
						if (currentPath.parent)
						{
							auto child = currentPath;
							currentPath = currentPath.parent;
							selection = child;
						}
						break;
					case Curses.Key.left:
					case 'h':
						if (textScrollContext.x.offset)
							goto textScroll;
						else
							goto case '<';
					case 'q':
					case 27: // ESC
						if (currentPath.firstChild)
							goto case 'i';
						else
							goto case '<';
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

			itemScroll:
				switch (ch)
				{
					case Curses.Key.up:
					case 'k':
						moveCursor(-1);
						break;
					case Curses.Key.down:
					case 'j':
						moveCursor(+1);
						break;
					case Curses.Key.pageUp:
						moveCursor(-itemScrollContext.y.contentAreaSize);
						break;
					case Curses.Key.pageDown:
						moveCursor(+itemScrollContext.y.contentAreaSize);
						break;
					case Curses.Key.home:
						moveCursor(-itemScrollContext.y.contentSize);
						break;
					case Curses.Key.end:
						moveCursor(+itemScrollContext.y.contentSize);
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
					case 'c':
						if (compareMode)
							setSort(SortMode.delta);
						else
							showMessage("Not in compare mode - re-run with --compare");
						break;
					case 'm':
						if (expert)
						{
							sizeDisplayMode = cast(SizeMetric)((sizeDisplayMode + 1) % enumLength!SizeMetric);
							showMessage(format!"Showing %s size"(sizeDisplayMode.to!string.chomp("_")));
						}
						else
							showMessage("Not in expert mode - re-run with --expert");
						break;
					case 't':
						dirsFirst = !dirsFirst;
						showMessage(format!"%s directories before files"(
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
							showMessage(format!"Cannot delete special node %s."(selection.humanName));
							break;
						}
						deleter.prepare([Deleter.Item(selection, false)]);
						popup = Popup.deleteConfirm;
						break;
					case 'D':
						bool haveMarked;
						BrowserPath* anySpecialNode = null;
						browserRoot.enumerateMarks((path, bool isMarked)
						{
							if (isMarked)
								haveMarked = true;
							if (!anySpecialNode && isMarked && !getFullPath(path))
								anySpecialNode = path;
						});
						if (!haveMarked)
						{
							showMessage("No marks");
							break;
						}
						if (anySpecialNode)
						{
							showMessage(format!"Cannot delete special node %s."(anySpecialNode.humanName));
							break;
						}
						if (mode == Mode.browser)
						{
							// Switch to marks screen now
							if (!previousPath)
								previousPath = currentPath;
							currentPath = &marked;
							selection = null;
						}
						Deleter.Item[] items;
						browserRoot.enumerateMarks((BrowserPath* path, bool isMarked) {
							if (isMarked)
								items ~= Deleter.Item(path, true);
						});
						deleter.prepare(items);
						popup = Popup.deleteConfirm;
						break;
					case 'O':
						curses.suspend((inputFile, outputFile) {
							import std.process : pipe, spawnProcess, wait;
							import ae.sys.file : readFile;
							auto p = pipe();
							auto pid = spawnProcess(
								["/bin/sh", "-c", `printf 'Saving results.\nFile name: ' >&2 && read -r fn && printf -- %s "$fn"`],
								inputFile,
								p.writeEnd,
								outputFile,
							);
							auto output = p.readEnd.readFile();
							auto status = wait(pid);
							if (status == 0 && output.length)
							{
								auto path = cast(string)output;
								outputFile.writeln("Exporting..."); outputFile.flush();
								exportData(path);
								showMessage("Exported to " ~ path);
							}
							else
								showMessage("Export canceled");
						});
						break;
					case 'y':
						if (!selection)
						{
							showMessage("Nothing selected to copy.");
							break;
						}
						auto fullPath = getFullPath(selection);
						if (fullPath)
						{
							curses.copyToClipboard(fullPath);
							showMessage("Path copied to clipboard");
						}
						else
							showMessage("Cannot copy special node path");
						break;
					default:
						// TODO: show message
						break;
				}
				break;

			textScroll:
				switch (ch)
				{
					case Curses.Key.up:
					case 'k':
						textScrollContext.y.offset += -1;
						break;
					case Curses.Key.down:
					case 'j':
						textScrollContext.y.offset += +1;
						break;
					case Curses.Key.left:
					case 'h':
						textScrollContext.x.offset += -1;
						break;
					case Curses.Key.right:
					case 'l':
						textScrollContext.x.offset += +1;
						break;
					case Curses.Key.pageUp:
						textScrollContext.y.offset += -textScrollContext.y.contentAreaSize;
						break;
					case Curses.Key.pageDown:
						textScrollContext.y.offset += +textScrollContext.y.contentAreaSize;
						break;
					case Curses.Key.home:
						textScrollContext.y.offset -= textScrollContext.y.contentSize;
						break;
					case Curses.Key.end:
						textScrollContext.y.offset += textScrollContext.y.contentSize;
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

/// Represents a size estimate with confidence bounds (in sample space)
struct SizeEstimate
{
	/// Lower bound of confidence interval (number of samples)
	double lower;
	/// Best estimate / center point (number of samples)
	double center;
	/// Upper bound of confidence interval (number of samples)
	double upper;

	/// Confidence interval half-width (for ± display)
	double halfWidth() const { return (upper - lower) / 2; }
}

// Wilson score confidence interval for binomial proportions
// https://en.wikipedia.org/wiki/Binomial_proportion_confidence_interval#Wilson_score_interval
// https://stackoverflow.com/q/69420422/21501
// https://stats.stackexchange.com/q/546878/234615
SizeEstimate estimateError(
	/// Total samples
	double n,
	/// Samples within the item
	double m,
	/// Standard score for desired confidence
	/// (default is for 95% confidence)
	double z = z_975,
	/// Whether this is an exact value (not an estimate)
	/// Use true for root node or other cases where size is known exactly
	bool isExact = false,
)
{
	import std.math.algebraic : sqrt;
	import std.algorithm : max, min, clamp;

	// Cases with exact knowledge - no estimation needed
	if (isExact || n == 0 || m == 0)
		return SizeEstimate(m, m, m);

	auto p = m / n;
	auto z2 = z * z;

	// Wilson score interval
	auto denominator = 1 + z2 / n;
	auto centerAdjustment = z2 / (2 * n);
	auto centerProportion = (p + centerAdjustment) / denominator;

	auto spreadTerm = z * sqrt(p * (1 - p) / n + z2 / (4 * n * n));
	auto spread = spreadTerm / denominator;

	// Convert from proportions to sample space, ensuring bounds stay in [0, n]
	auto lowerProportion = clamp(centerProportion - spread, 0.0, 1.0);
	auto upperProportion = clamp(centerProportion + spread, 0.0, 1.0);

	return SizeEstimate(
		lowerProportion * n,      // Lower bound
		centerProportion * n,      // Center (Wilson center, not raw samples)
		upperProportion * n,       // Upper bound
	);
}

/// Include explanations in the displayed undiscovered estimate.
// debug debug = btdu_undiscovered;

/// Estimate undiscovered children using Chao1 estimator with confidence indicators.
/// Returns a string like "and ~500 more items" or "and likely more items",
/// or null if complete.
///
/// Decision categories (in order):
/// 1. complete:      n1=0 AND global_C≥30% AND (obs≥10 OR samples≥50×obs) → null (no display)
/// 2. early:         global_coverage < 30%             → "and likely more"
/// 3. near-complete: obs≥20 AND (n1<10 OR n1/obs<5% OR f0<5) → "and about X more"
/// 4. unknown:       n2 < 5                            → "and likely more"
/// 5. biased:        iChao1 > 1.5×Chao1                → "and likely more"
/// 6. lower-bound:   H > 0.5                           → "and roughly at least X more"
/// 7. ballpark:      0.25 < H ≤ 0.5                    → "and roughly X more"
/// 8. strong:        H ≤ 0.25                          → "and ~X more"
string estimateUndiscoveredStr(BrowserPath* path)
{
	import std.math : sqrt, ceil;
	import std.algorithm : max;

	// Helper: in debug builds, append explanation to display string
	static string withExplanation(string display, lazy string explanation)
	{
		debug (btdu_undiscovered)
			return (display is null ? "and no more items" : display) ~ " " ~ explanation;
		else
			return display;
	}

	// Count frequency statistics among children
	size_t observed = 0;    // Total observed children
	size_t n1 = 0;          // Singletons: children with exactly 1 sample
	size_t n2 = 0;          // Doubletons: children with exactly 2 samples
	size_t n3 = 0;          // Tripletons: children with exactly 3 samples
	size_t n4 = 0;          // Children with exactly 4 samples

	for (auto child = path.firstChild; child; child = child.nextSibling)
	{
		auto samples = child.getSamples(SampleType.represented);
		if (samples == 0) continue;
		if (samples == 1) n1++;
		else if (samples == 2) n2++;
		else if (samples == 3) n3++;
		else if (samples == 4) n4++;
		observed++;
	}

	// Global coverage from numSingleSampleGroups (sharing groups sampled exactly once)
	auto totalSamples = getTotalUniqueSamplesFor(browserRootPtr);
	double globalC = totalSamples > 0 ? 1.0 - cast(double)numSingleSampleGroups / totalSamples : 0.0;

	// Samples hitting this directory (for saturation check)
	auto pathSamples = path.getSamples(SampleType.represented);

	// === Decision logic ===

	// In expert mode, paths may only have non-representative samples
	if (pathSamples == 0)
		return withExplanation(null, "(no representative samples)");

	// Use softer language when only one item discovered
	string likelyMore = observed == 1 ? "and possibly more items" : "and likely more items";

	// Complete: no singletons, but only if good global coverage and sufficient obs
	// Three ways to claim complete:
	// 1. We have substantial observations (obs >= 10)
	// 2. We're saturated: many samples but few unique items (50x for obs >= 2)
	// 3. Single item with very high saturation (100x for obs == 1)
	//    Be more conservative for single item since we can't know if tiny items exist
	if (n1 == 0)
	{
		if (globalC < 0.3)
			return withExplanation(likelyMore,
				format!"(n1=0 but C=%.0f%%)"(globalC * 100));
		bool hasEnoughObs = observed >= 10;
		bool isSaturated = observed >= 2 && pathSamples >= 50 * observed;
		bool isSingleSaturated = observed == 1 && pathSamples >= 100 * observed;
		if (!hasEnoughObs && !isSaturated && !isSingleSaturated)
			return withExplanation(likelyMore,
				format!"(n1=0 but obs=%d, samples=%d)"(observed, cast(size_t)pathSamples));
		return withExplanation(null,
			format!"(n1=0, obs=%d, samples=%d)"(observed, cast(size_t)pathSamples));  // Truly complete
	}

	// Early: global coverage < 30%
	if (globalC < 0.3)
		return withExplanation(likelyMore,
			format!"(early: C=%.0f%%, n1=%d, n2=%d)"(globalC * 100, n1, n2));

	// Compute Chao1 estimate
	double f0_est;
	if (n2 == 0)
		f0_est = n1 * (n1 - 1) / 2.0;
	else
		f0_est = cast(double)(n1 * n1) / (2.0 * n2);

	// Helper: format "and <qualifier> N more item(s)"
	static string moreItemsStr(string qualifier)(double n)
	{
		auto count = ceil(n);
		return format!"and %s%.0f more %s"(qualifier, count, count == 1 ? "item" : "items");
	}

	// Near-complete: few singletons relative to observed (but need enough obs to trust it)
	if (observed >= 20)
	{
		double singletonRatio = cast(double)n1 / observed;
		if (n1 < 10 || singletonRatio < 0.05 || f0_est < 5)
			return withExplanation(moreItemsStr!"about "(f0_est),
				format!"(near-complete: obs=%d, n1=%d, n2=%d, f0=%.1f)"(observed, n1, n2, f0_est));
	}

	// Unknown: can't compute reliable SE
	if (n2 < 5)
		return withExplanation(likelyMore,
			format!"(unknown: n2=%d<5, obs=%d, n1=%d)"(n2, observed, n1));

	// Bias check using iChao1
	double f0_ichao1 = f0_est;
	if (n4 > 0 && n3 > 0)
	{
		double correction = (cast(double)n3 / (4 * n4)) * max(0.0, n1 - cast(double)n2 * n3 / (2 * n4));
		f0_ichao1 = f0_est + correction;
	}
	else if (n3 > 0 && n2 > 0)
	{
		f0_ichao1 = f0_est * (1 + cast(double)n3 / (2 * n2));
	}
	if (f0_ichao1 > 1.5 * f0_est)
		return withExplanation(likelyMore,
			format!"(biased: iChao1=%.0f >> Chao1=%.0f)"(f0_ichao1, f0_est));

	// Compute SE and reliability score H
	double a = cast(double)n1 / n2;
	double var_s = n2 * (a * a * a * a / 4.0 + a * a * a + a * a / 2.0);
	double se = sqrt(var_s);
	double H = 1.96 * se / max(f0_est, 1.0);

	if (H > 0.5)
		return withExplanation(moreItemsStr!"roughly at least "(f0_est),
			format!"(lower-bound: H=%.2f, n1=%d, n2=%d)"(H, n1, n2));
	else if (H > 0.25)
		return withExplanation(moreItemsStr!"roughly "(f0_est),
			format!"(ballpark: H=%.2f, n1=%d, n2=%d)"(H, n1, n2));
	else
		return withExplanation(moreItemsStr!"~"(f0_est),
			format!"(strong: H=%.2f, n1=%d, n2=%d)"(H, n1, n2));
}

auto durationAsDecimalString(Duration d) @nogc
{
	assert(d >= Duration.zero);
	auto ticks = d.stdTime;
	enum secondsPerTick = 1.seconds / 1.stdDur;
	static assert(secondsPerTick == 10L ^^ 7);
	return formatted!"%d.%07d seconds"(ticks / secondsPerTick, ticks % secondsPerTick);
}

char[] stringify(string fmt = "%s", Args...)(ref StaticAppender!char buf, auto ref Args args)
{
	buf.clear();
	buf.formattedWrite!fmt(args);
	return buf.peek();
}
