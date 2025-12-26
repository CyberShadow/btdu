/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2025  Vladimir Panteleev <btdu@cy.md>
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

/// Global state definitions
module btdu.state;

import std.format : format;
import std.functional : memoize;
import std.traits : EnumMembers;

import ae.utils.appender : FastAppender;
import ae.utils.meta : enumLength;

import btrfs.c.ioctl : btrfs_ioctl_dev_info_args, btrfs_ioctl_fs_info_args;
import btrfs.c.kerncompat : u64;

import containers.hashset;
import containers.internal.hash : generateHash;

import btdu.alloc;
import btdu.paths;
import btdu.subproc : Subprocess;

/// Returns the appropriate allocator for a given type.
/// SubPath uses IndexedSlabAllocator for efficient reverse lookups,
/// other types use the general growAllocator.
template allocatorFor(T)
{
	static if (is(T == SubPath))
		alias allocatorFor = subPathAllocator;
	else
		alias allocatorFor = growAllocator;
}

// ============================================================
// SamplingState - per-dataset state
// ============================================================

struct RootInfo
{
	GlobalPath* path;
	bool isOrphan;  /// True if this is a TREE_%d (deleted subvolume)
}

/// Index for accessing different sampling states
enum DataSet
{
	main,    /// Primary state (for live sampling or --import)
	compare, /// Baseline state (for --compare)
}

/// Encapsulates the state for a single sampled dataset.
/// This allows having separate state instances for main data vs compare baseline.
struct SamplingState
{
	ulong totalSize;
	bool expert;
	bool physical;
	BrowserPath browserRoot;
	typeof(btrfs_ioctl_fs_info_args.fsid) fsid;
	RootInfo[u64] roots;

	/// Returns pointer to browserRoot
	BrowserPath* rootPtr() return { return &browserRoot; }
}

// ============================================================
// Global state
// ============================================================

__gshared: // btdu is single-threaded

// State instances indexed by DataSet
SamplingState[enumLength!DataSet] states;
bool compareMode;

// Allocators (shared across all state instances)
IndexedSlabAllocator!SubPath subPathAllocator;

// Other global state (not per-dataset)
bool imported;
bool exportSeenAs;
string fsPath;
btrfs_ioctl_dev_info_args[] devices;
SubPath subPathRoot;

/// Deduplicates sharing groups - multiple samples with the same set of paths
/// will reference the same SharingGroup and just increment its sample count.
HashSet!(SharingGroup.Paths, CasualAllocator, SharingGroup.Paths.hashOf, false, true) sharingGroups;

/// Slab allocator instance for SharingGroups - enables efficient iteration over all groups.
/// Note: In compare mode, both main and compare datasets share this allocator.
/// Each SharingGroup's `root` pointer indicates which tree it belongs to.
/// This shared usage means binary export is not supported in compare mode,
/// as we cannot distinguish which groups belong to which dataset during iteration.
SlabAllocator!SharingGroup sharingGroupAllocator;

/// Total number of created sharing groups
size_t numSharingGroups;
/// Number of sharing groups with exactly 1 sample
size_t numSingleSampleGroups;

// ============================================================
// Compatibility shims - forward to states[DataSet.xxx]
// ============================================================

// Main state shims
@property ref totalSize() { return states[DataSet.main].totalSize; }
@property ref expert() { return states[DataSet.main].expert; }
@property ref physical() { return states[DataSet.main].physical; }
@property ref browserRoot() { return states[DataSet.main].browserRoot; }
BrowserPath* browserRootPtr() { return states[DataSet.main].rootPtr; }
@property ref fsid() { return states[DataSet.main].fsid; }
@property ref globalRoots() { return states[DataSet.main].roots; }

// Compare state shims
@property ref compareTotalSize() { return states[DataSet.compare].totalSize; }
@property ref compareExpert() { return states[DataSet.compare].expert; }
@property ref comparePhysical() { return states[DataSet.compare].physical; }
@property ref compareRoot() { return states[DataSet.compare].browserRoot; }
BrowserPath* compareRootPtr() { return states[DataSet.compare].rootPtr; }
@property ref compareFsid() { return states[DataSet.compare].fsid; }
@property ref compareRoots() { return states[DataSet.compare].roots; }

/// Disk visualization map - tracks statistics per visual sector
struct DiskMap
{
	enum sectorBits = 13;
	enum numSectors = 1 << sectorBits;  // 8192

	enum SectorCategory : ubyte
	{
		empty,
		data,
		unallocated,
		slack,
		unused,
		system,
		metadata,
		unreachable,
		error,
		orphan,
	}

	struct SectorStats
	{
		uint totalSamples;
		uint[enumLength!SectorCategory] categoryCounts;
		uint uniqueGroupCount;
	}

	/// Return type for getSectorState - separates logic from presentation
	struct SectorState
	{
		bool hasData;           /// true if any samples
		SectorCategory dominant; /// if special type >50%, that type; else data
		uint groupDensity;      /// uniqueGroupCount (for adaptive scaling in renderer)
	}

	SectorStats[numSectors] sectors;

	size_t sampleIndexToSector(ulong sampleIndex) const
	{
		// sampleIndex is 0-based in [0, totalSize), map to [0, numSectors)
		assert(totalSize > 0, "totalSize not initialized");

		// Maximum totalSize for fast path: 2^(64 - sectorBits) = 2^51 (~2 petabytes)
		enum maxFastPathSize = 1UL << (64 - sectorBits);

		if (totalSize < maxFastPathSize)
			return cast(size_t)((sampleIndex << sectorBits) / totalSize);
		else
			return cast(size_t)((cast(real) sampleIndex / totalSize) * numSectors);
	}

	void recordSample(ulong sampleIndex, SectorCategory category)
	{
		if (totalSize == 0)
			return;
		auto sector = sampleIndexToSector(sampleIndex);
		sectors[sector].totalSamples++;
		sectors[sector].categoryCounts[category]++;
	}

	void incrementSectorGroupCount(ulong sampleIndex)
	{
		if (totalSize == 0)
			return;
		auto sector = sampleIndexToSector(sampleIndex);
		sectors[sector].uniqueGroupCount++;
	}

	SectorState getSectorState(size_t startSector, size_t endSector) const
	{
		// Aggregate stats across the range
		uint totalSamples = 0;
		uint[enumLength!SectorCategory] categoryCounts;
		uint totalGroupCount = 0;

		foreach (i; startSector .. endSector)
		{
			auto stats = sectors[i];
			totalSamples += stats.totalSamples;
			totalGroupCount += stats.uniqueGroupCount;
			static foreach (cat; EnumMembers!SectorCategory)
				categoryCounts[cat] += stats.categoryCounts[cat];
		}

		if (totalSamples == 0)
			return SectorState(false, SectorCategory.empty, 0);

		// Check if >50% of samples are in a special category
		uint specialCount = 0;
		SectorCategory dominantSpecial = SectorCategory.data;
		uint maxSpecialCount = 0;

		static foreach (cat; [
			SectorCategory.unallocated,
			SectorCategory.slack,
			SectorCategory.unused,
			SectorCategory.system,
			SectorCategory.metadata,
			SectorCategory.unreachable,
			SectorCategory.error,
			SectorCategory.orphan,
		])
		{
			specialCount += categoryCounts[cat];
			if (categoryCounts[cat] > maxSpecialCount)
			{
				maxSpecialCount = categoryCounts[cat];
				dominantSpecial = cat;
			}
		}

		if (specialCount * 2 > totalSamples)
			return SectorState(true, dominantSpecial, totalGroupCount);

		return SectorState(true, SectorCategory.data, totalGroupCount);
	}
}
DiskMap diskMap;

BrowserPath marked;  /// A fake `BrowserPath` used to represent all marked nodes.
ulong markTotalSamples; /// Number of seen samples since the mark was invalidated.

/// Initialize the `marked` BrowserPath structure.
/// Since it has no children or sharing groups, we force aggregateData allocation.
static this()
{
	marked.forceAggregateData();
}

debug(check) void checkState()
{
	browserRoot.checkState();
	// Check compare tree if in compare mode
	if (compareMode)
		compareRoot.checkState();
	// Note: `marked` is not checked - it's a virtual node that aggregates from
	// marked paths across the tree, not from its own children.
}

/// Called when something is marked or unmarked.
void invalidateMark()
{
	debug(check) checkState();
	scope(success) debug(check) checkState();

	markTotalSamples = 0;
	if (expert)
		marked.resetNodeSamples(SampleType.exclusive);
}

/// Update stats in `marked` for a redisplay.
void updateMark()
{
	debug(check) checkState();
	scope(success) debug(check) checkState();

	static foreach (sampleType; EnumMembers!SampleType)
		if (sampleType != SampleType.exclusive)
			marked.resetNodeSamples(sampleType);
	marked.resetDistributedSamples();

	browserRoot.enumerateMarks(
		(const BrowserPath* path, bool isMarked)
		{
			if (isMarked)
			{
				static foreach (sampleType; EnumMembers!SampleType)
					if (sampleType != SampleType.exclusive)
						marked.addSamples(sampleType, path.getSamples(sampleType), path.getOffsets(sampleType)[], path.getDuration(sampleType));
				marked.addDistributedSample(path.getDistributedSamples(), path.getDistributedDuration());
			}
			else
			{
				static foreach (sampleType; EnumMembers!SampleType)
					if (sampleType != SampleType.exclusive)
						marked.removeSamples(sampleType, path.getSamples(sampleType), path.getOffsets(sampleType)[], path.getDuration(sampleType));
				marked.removeDistributedSample(path.getDistributedSamples(), path.getDistributedDuration());
			}
		}
	);
}

/// Returns the total number of unique samples collected by btdu since `p` was born.
/// Comparing the returned number with the number of samples recorded in `p` itself
/// can give us a proportion of how much disk space `p` is using.
ulong getTotalUniqueSamplesFor(BrowserPath* p)
{
	if (p is &marked)
	{
		// The `marked` node is special in that, unlike every real `BrowserPath`,
		// it exists for some fraction of the time since when btdu started running
		// (since the point it was last "invalidated").
		return markTotalSamples;
	}
	else
	{
		// We assume that all seen paths equally existed since btdu was started.

		// We use `browserRoot` because we add samples to all nodes going up in the hierarchy,
		// so we will always include `browserRoot`.
		auto reference = browserRootPtr;

		// We use `SampleType.represented` because
		// 1. It is always going to be collected
		//    (it's the only sample type collected in non-expert mode);
		// 2. At the root level, it will exactly correspond to the total number
		//    of samples collected.
		enum type = SampleType.represented;

		return reference.getSamples(type);
	}
}

// ============================================================
// Compare mode utilities
// ============================================================

/// Result of comparing a path between current and baseline data
struct CompareResult
{
	bool hasOldData;     /// True if path existed in comparison baseline
	bool hasNewData;     /// True if path exists in current data
	real oldSize = 0;    /// Size from comparison baseline (bytes)
	real newSize = 0;    /// Size from current data (bytes)

	real deltaSize() const { return newSize - oldSize; }
}

/// Find the corresponding node in the comparison tree.
/// Returns null if the path doesn't exist in comparison or if not in compare mode.
/// Memoized to avoid repeated expensive lookups during sorting.
alias findInCompareTree = memoize!findInCompareTreeImpl;

private BrowserPath* findInCompareTreeImpl(BrowserPath* path)
{
	if (!compareMode)
		return null;
	if (path is null)
		return null;
	if (path is browserRootPtr)
		return compareRootPtr;
	if (path is &marked)
		return null; // Marks don't translate

	// Build path from root to this node
	static BrowserPath*[] pathStack;
	pathStack.length = 0;
	for (auto p = path; p && p !is browserRootPtr; p = p.parent)
		pathStack ~= p;

	// Walk down comparison tree
	BrowserPath* comparePath = compareRootPtr;
	foreach_reverse (node; pathStack)
	{
		BrowserPath* found = null;
		for (auto child = comparePath.firstChild; child; child = child.nextSibling)
		{
			if (child.name[] == node.name[])
			{
				found = child;
				break;
			}
		}
		if (found is null)
			return null;
		comparePath = found;
	}
	return comparePath;
}

/// Get comparison result for a path using the specified sample type.
CompareResult getCompareResult(BrowserPath* newPath, SampleType sampleType)
{
	CompareResult result;

	result.hasNewData = newPath !is null;

	auto oldPath = findInCompareTree(newPath);
	result.hasOldData = oldPath !is null;

	auto newTotalSamples = getTotalUniqueSamplesFor(browserRootPtr);
	auto oldTotalSamples = compareTotalSize > 0 ?
		compareRoot.getSamples(SampleType.represented) : 0;

	if (result.hasNewData && newTotalSamples > 0)
	{
		auto samples = newPath.getSamples(sampleType);
		result.newSize = samples * real(totalSize) / newTotalSamples;
	}

	if (result.hasOldData && oldTotalSamples > 0)
	{
		auto samples = oldPath.getSamples(sampleType);
		result.oldSize = samples * real(compareTotalSize) / oldTotalSamples;
	}

	return result;
}

Subprocess[] subprocesses;
bool paused;
debug bool importing;

bool toFilesystemPath(BrowserPath* path, void delegate(const(char)[]) sink)
{
	sink(fsPath);
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
		{
			if (!recurse(path.parent))
				return false;
		}
		else
		{
			if (path is &marked)
				return false;
		}
		sink("/");
		sink(name);
		return true;
	}
	return recurse(path);
}

auto toFilesystemPath(BrowserPath* path)
{
	import ae.utils.functor.primitives : functor;
	import ae.utils.text.functor : stringifiable;
	return path
		.functor!((path, writer) => path.toFilesystemPath(writer))
		.stringifiable;
}

/// Populate BrowserPath tree from a sharing group.
/// Params:
///   group = The sharing group to process
///   needsLinking = Whether to link the group to BrowserPaths' firstSharingGroup lists
///                  (true for new groups and for rebuild after reset)
///   samples = Number of samples to add
///   offsets = Sample offsets to record
///   duration = Total duration for these samples
///   target = Which dataset to populate (main or compare)
void populateBrowserPathsFromSharingGroup(
	SharingGroup* group,
	bool needsLinking,
	ulong samples,
	const(Offset)[] offsets,
	ulong duration,
	DataSet target = DataSet.main
)
{
	bool allMarked = true;
	auto root = group.root;
	auto paths = group.paths;

	assert(paths.length > 0, "Sharing groups must have at least one path");

	debug (check)
		foreach (i, ref path; paths)
			if (group.pathData[i].path)
				group.pathData[i].path.checkState();

	auto representativeIndex = group.representativeIndex;

	// ============================================================
	// Phase 1: Create BrowserPath nodes (but don't link sharing groups yet)
	// ============================================================

	if (needsLinking)
	{
		// Create BrowserPath nodes and store path pointers
		// We don't link sharing groups yet - that happens after updateStructure
		if (expert)
		{
			foreach (i, ref path; paths)
			{
				auto pathBrowserPath = root.appendPath(&path);
				group.pathData[i].path = pathBrowserPath;
			}
		}
		else
		{
			auto representativeBrowserPath = root.appendPath(&paths[representativeIndex]);
			group.pathData[representativeIndex].path = representativeBrowserPath;
		}
	}

	// ============================================================
	// Phase 2: Update structure (before linking sharing groups)
	// This ensures aggregateData is allocated where needed.
	// Non-root leaves don't need aggregateData (needsAggregateData returns false for them)
	// because they'll get sharing groups in Phase 3.
	// If new aggregateData is allocated, it captures current values from children
	// (which may already have samples from earlier groups during rebuild).
	// ============================================================
	if (expert)
	{
		foreach (i, ref path; paths)
			group.pathData[i].path.updateStructure();
	}
	else
	{
		group.pathData[representativeIndex].path.updateStructure();
	}

	// ============================================================
	// Phase 3: Link sharing groups to BrowserPaths
	// This must happen AFTER updateStructure so that newly allocated
	// aggregateData captures 0 from children (not from group.data).
	// ============================================================
	if (needsLinking)
	{
		if (expert)
		{
			foreach (i, ref path; paths)
			{
				auto browserPath = group.pathData[i].path;
				// Set next pointer to the current head of the list.
				// This must be done for ALL pathData entries, even duplicates,
				// because getNext uses findIndex which may return any matching index.
				group.pathData[i].next = browserPath.firstSharingGroup;
			}
			// Now update firstSharingGroup for each unique browserPath
			foreach (i, ref path; paths)
			{
				auto browserPath = group.pathData[i].path;
				if (browserPath.firstSharingGroup != group)
					browserPath.firstSharingGroup = group;
			}
		}
		else
		{
			auto browserPath = group.pathData[representativeIndex].path;
			group.pathData[representativeIndex].next = browserPath.firstSharingGroup;
			browserPath.firstSharingGroup = group;
		}
	}

	// ============================================================
	// Phase 4: Add samples to aggregateData
	// ============================================================

	// Add represented samples to the representative path
	group.pathData[representativeIndex].path.addSamples(SampleType.represented, samples, offsets, duration);

	if (expert)
	{
		auto distributedSamples = double(samples) / paths.length;
		auto distributedDuration = double(duration) / paths.length;

		foreach (i, ref path; paths)
		{
			auto browserPath = group.pathData[i].path;
			browserPath.addSamples(SampleType.shared_, samples, offsets, duration);
			browserPath.addDistributedSample(distributedSamples, distributedDuration);
		}

		static FastAppender!(BrowserPath*) browserPaths;
		browserPaths.clear();
		foreach (i, ref path; paths)
			browserPaths.put(group.pathData[i].path);

		auto exclusiveBrowserPath = BrowserPath.commonPrefix(browserPaths.peek());
		exclusiveBrowserPath.addSamples(SampleType.exclusive, samples, offsets, duration);
	}

	// Update global marked state (only for main dataset)
	if (target == DataSet.main)
	{
		markTotalSamples += samples;

		// Check marks and update marked node
		if (expert)
		{
			foreach (i, ref path; paths)
				if (!group.pathData[i].path.getEffectiveMark())
				{
					allMarked = false;
					break;
				}

			if (allMarked)
				marked.addSamples(SampleType.exclusive, samples, offsets, duration);
		}
	}

	debug (check)
		foreach (i, ref path; paths)
			if (group.pathData[i].path)
				group.pathData[i].path.checkState();
}

/// State for incremental rebuild from sharing groups
struct RebuildState
{
	alias Range = typeof(sharingGroupAllocator).Range;

	Range range;          /// Range over sharing groups to process
	size_t processed;     /// Number of groups processed so far
	size_t total;         /// Total number of groups to process
	size_t step;          /// Number of groups to process per step (1% of total)

	bool inProgress() const { return !range.empty; }
	int progressPercent() const { return total > 0 ? cast(int)(processed * 100 / total) : 0; }
}
RebuildState rebuildState;

/// Start an incremental rebuild of the BrowserPath tree from all SharingGroups.
/// Call processRebuildStep() repeatedly until rebuildState.inProgress is false.
void startRebuild()
{
	debug(check) checkState();
	scope(success) debug(check) checkState();

	// Reset all BrowserPath sample data and sharing group links
	browserRoot.reset();
	if (compareMode)
		compareRoot.reset();
	markTotalSamples = 0;

	// Clear all pathData[i].next pointers to avoid stale values causing cycles
	foreach (ref group; sharingGroupAllocator[])
		foreach (i; 0 .. group.paths.length)
			group.pathData[i].next = null;

	// Initialize rebuild state with a range over all current sharing groups
	rebuildState.range = sharingGroupAllocator[];
	rebuildState.total = rebuildState.range.length;
	rebuildState.processed = 0;
	rebuildState.step = rebuildState.total / 100;
	if (rebuildState.step == 0)
		rebuildState.step = 1;
}

/// Process one step of the incremental rebuild (1% of total sharing groups).
/// Returns: true if there is more work to do, false if rebuild is complete.
bool processRebuildStep()
{
	debug(check) checkState();
	scope(success) debug(check) checkState();

	if (rebuildState.range.empty)
		return false;

	size_t count = 0;
	while (!rebuildState.range.empty && count < rebuildState.step)
	{
		SharingGroup* group = &rebuildState.range.front();

		// Recalculate which path is the representative under current rules
		group.representativeIndex = selectRepresentativeIndex(group.paths);

		// Repopulate BrowserPath tree from this group's stored data
		// During rebuild, aggregateData already exists (just zeroed by reset),
		// so updateStructure won't trigger ensureAggregateData capture.
		// addSamples simply increments the zeroed values.
		populateBrowserPathsFromSharingGroup(
			group,
			true,  // needsLinking - always true for rebuild
			group.data.samples,
			group.data.offsets[],
			group.data.duration
		);

		rebuildState.range.popFront();
		rebuildState.processed++;
		count++;
	}

	return !rebuildState.range.empty;
}
