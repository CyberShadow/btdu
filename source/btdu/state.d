/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2025, 2026  Vladimir Panteleev <btdu@cy.md>
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
import btdu.sample.subproc : Subprocess;

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
	bool isOrphan;   /// True if this is a TREE_%d (deleted subvolume)
	long otime;      /// Creation time (seconds since epoch), or 0 if unknown
	bool isReadOnly; /// True if subvolume is read-only (typically a snapshot)
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

	/// Deduplicates sharing groups - multiple samples with the same set of paths
	/// will reference the same SharingGroup and just increment its sample count.
	HashSet!(SharingGroup.Paths, CasualAllocator, SharingGroup.Paths.hashOf, false, true) sharingGroups;

	/// Slab allocator instance for SharingGroups - enables efficient iteration over all groups.
	SlabAllocator!SharingGroup sharingGroupAllocator;

	/// Total number of created sharing groups
	size_t numSharingGroups;
	/// Number of sharing groups with exactly 1 sample
	size_t numSingleSampleGroups;

	/// State for incremental rebuild from sharing groups
	RebuildState rebuildState;

	/// Returns pointer to browserRoot
	BrowserPath* rootPtr() return { return &browserRoot; }
}

/// State for incremental rebuild from sharing groups
struct RebuildState
{
	alias Range = SlabAllocator!SharingGroup.Range;

	Range range;          /// Range over sharing groups to process
	size_t processed;     /// Number of groups processed so far
	size_t total;         /// Total number of groups to process
	size_t step;          /// Number of groups to process per step (1% of total)

	bool inProgress() const { return !range.empty; }
	int progressPercent() const { return total > 0 ? cast(int)(processed * 100 / total) : 0; }
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

// Reverse lookup: root-level GlobalPath* -> RootInfo*
RootInfo*[GlobalPath*] rootInfoByRootPath;

// Other global state (not per-dataset)
bool imported;
bool exportSeenAs;
bool autoMountMode; /// True when using --auto-mount with a temporary mount point
bool chronological; /// If true, prefer older paths; if false (default), prefer newer paths
string fsPath;
btrfs_ioctl_dev_info_args[] devices;
SubPath subPathRoot;
uint currentGeneration; /// Incremented on deletion; samples with older generation are discarded

// ============================================================
// Stat subprocess state
// ============================================================

/// Range over pending sharing groups that need stat resolution.
/// New groups are automatically included as they are allocated.
SlabAllocator!SharingGroup.OpenRange pendingGroups;

/// Returns a range over resolved (non-pending) sharing groups.
/// Since groups are resolved sequentially, this is all groups before the pendingGroups position.
SlabAllocator!SharingGroup.Range getResolvedSharingGroups()
{
	alias Range = SlabAllocator!SharingGroup.Range;

	// Return range from start to pendingGroups position
	return Range(
		sharingGroupAllocator.firstSlab,
		0,
		pendingGroups.slab,
		pendingGroups.index
	);
}

// ============================================================
// Compatibility shims - forward to states[DataSet.xxx]
// ============================================================

/// Get RootInfo for a GlobalPath.
/// For file paths, returns the RootInfo of the containing subvolume.
/// For subvolume paths (in globalRoots), returns their own RootInfo.
/// Returns null if the path has no associated RootInfo.
const(RootInfo)* getRootInfo(const(GlobalPath)* path)
{
	if (path is null)
		return null;
	// Check if this path itself is a root (subvolume) path
	if (auto info = cast(GlobalPath*) path in rootInfoByRootPath)
		return *info;
	// Otherwise check the parent (containing subvolume for file paths)
	if (auto info = cast(GlobalPath*) path.parent in rootInfoByRootPath)
		return *info;
	return null;
}

// Main state shims
@property ref totalSize() { return states[DataSet.main].totalSize; }
@property ref expert() { return states[DataSet.main].expert; }
@property ref physical() { return states[DataSet.main].physical; }
@property ref browserRoot() { return states[DataSet.main].browserRoot; }
BrowserPath* browserRootPtr() { return states[DataSet.main].rootPtr; }
@property ref fsid() { return states[DataSet.main].fsid; }
@property ref globalRoots() { return states[DataSet.main].roots; }
@property ref sharingGroups() { return states[DataSet.main].sharingGroups; }
@property ref sharingGroupAllocator() { return states[DataSet.main].sharingGroupAllocator; }
@property ref numSharingGroups() { return states[DataSet.main].numSharingGroups; }
@property ref numSingleSampleGroups() { return states[DataSet.main].numSingleSampleGroups; }

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

// ============================================================
// Birthtime lookup for path-based creation time comparison
// ============================================================

// Birthtime cache: GlobalPath -> birthtime (nanoseconds since epoch)
// GlobalPath is a lightweight struct (two pointers), so we use it directly as key.
// Public for binary import/export.
long[GlobalPath] birthtimeCache;

/// Creation time and read-only status for a path component.
/// For subvolume roots, uses RootInfo (otime, isReadOnly).
/// For regular directories/files, uses birthtime and assumes writable.
struct CreationInfo
{
	long time;       /// Creation time (nanoseconds since epoch), 0 if unknown
	bool isReadOnly; /// True if read-only (snapshots), false for regular dirs

	/// Compare in chronological order. Writable paths are always considered
	/// to be newer than read-only paths.
	/// Returns -1 if `this` is older, +1 if `other` is older, 0 if equal.
	int opCmp(ref const CreationInfo other) const
	{
		// Prefer read-only (snapshot) over read-write
		if (isReadOnly != other.isReadOnly)
			return isReadOnly ? -1 : 1;

		// Prefer older (smaller time), but 0 means unknown (least preferred)
		if (time != other.time && time != 0 && other.time != 0)
			return time < other.time ? -1 : 1;

		return 0; // Equal or both unknown
	}
}

/// Result of finding where two paths diverge.
struct DivergenceResult
{
	bool diverged;     /// True if paths diverge, false if identical or one is prefix of other
	CreationInfo aInfo; /// Creation info for path A at divergence point
	CreationInfo bInfo; /// Creation info for path B at divergence point
}

/// Find where two GlobalPaths diverge and return creation info at that point.
/// Complexity: O(N) where N is the shorter path's depth.
DivergenceResult findDivergenceCreationInfo(const(GlobalPath)* a, const(GlobalPath)* b)
{
	if (a is b)
		return DivergenceResult(false, CreationInfo.init, CreationInfo.init);

	DivergenceResult result;

	// Get creation info for a path at divergence point.
	// If the diverging GlobalPath is a registered subvolume, use RootInfo.
	// Otherwise, use birthtime of the diverging directory.
	CreationInfo getCreationInfo(const(GlobalPath)* gp, const(SubPath)* sp)
	{
		// Check if gp itself is a registered subvolume
		if (auto rootInfo = cast(GlobalPath*) gp in rootInfoByRootPath)
			// Convert otime from seconds to nanoseconds for consistent comparison
			return CreationInfo((*rootInfo).otime * 1_000_000_000L, (*rootInfo).isReadOnly);
		// Regular directory: construct path to diverging dir and get birthtime
		return CreationInfo(getBirthtime(GlobalPath(cast(GlobalPath*) gp.parent, cast(SubPath*) sp)), false);
	}

	// Compare SubPath components in root-to-leaf order using synchronized recursion.
	// Returns true to stop early (found divergence or one path ended).
	bool compareSubPaths(const(SubPath)* spA, const(SubPath)* spB,
		const(GlobalPath)* gpA, const(GlobalPath)* gpB)
	{
		bool aEnd = (spA is null || spA.parent is null);
		bool bEnd = (spB is null || spB.parent is null);

		if (aEnd && bEnd)
			return false; // Both ended, continue to next GlobalPath

		if (aEnd || bEnd)
			return true; // One ended before the other - one is prefix of other

		// Recurse to parents first (root-to-leaf order)
		if (compareSubPaths(spA.parent, spB.parent, gpA, gpB))
			return true;

		// Compare this component on the way back
		auto nameA = spA.name[];
		auto nameB = spB.name[];

		// Skip special components
		bool specialA = nameA.length == 0 || nameA[0] == '\0';
		bool specialB = nameB.length == 0 || nameB[0] == '\0';

		if (specialA && specialB)
			return false; // Both special, continue
		if (specialA || specialB)
			return true; // One special, one not - treat as prefix

		// Both are regular components - check for divergence
		if (nameA != nameB)
		{
			result.diverged = true;
			result.aInfo = getCreationInfo(gpA, spA);
			result.bInfo = getCreationInfo(gpB, spB);
			return true;
		}

		// Components match, continue
		return false;
	}

	// Compare GlobalPath chains in root-to-leaf order using synchronized recursion.
	bool compareGlobalPaths(const(GlobalPath)* gpA, const(GlobalPath)* gpB)
	{
		bool aEnd = (gpA is null);
		bool bEnd = (gpB is null);

		if (aEnd && bEnd)
			return false; // Both ended

		if (aEnd || bEnd)
			return true; // One ended - one is prefix of other

		// Recurse to parents first (root-to-leaf order)
		if (compareGlobalPaths(gpA.parent, gpB.parent))
			return true;

		// Compare this GlobalPath's SubPaths
		return compareSubPaths(gpA.subPath, gpB.subPath, gpA, gpB);
	}

	compareGlobalPaths(a, b);
	return result;
}

/// Check if a birthtime is cached for the given path.
bool isBirthtimeCached(GlobalPath path)
{
	if (path.subPath is null)
		return true; // null paths always have birthtime 0
	return (path in birthtimeCache) !is null;
}

/// Get the birthtime of a GlobalPath from cache.
/// Returns 0 (unknown) for uncached paths. The caller should check
/// isBirthtimeCached first if it needs to know whether the value is definitive.
long getBirthtime(GlobalPath path)
{
	if (path.subPath is null)
		return 0;

	if (auto cached = path in birthtimeCache)
		return *cached;

	return 0;
}

// ============================================================
// Pending group stat resolution
// ============================================================

import btdu.paths : SharingGroup;

/// Info about paths that need stat resolution for a pending group.
/// Uses static buffers to avoid GC allocations on the hot path.
/// Only valid until the next call to findUncachedDivergencePaths.
struct PendingStatInfo
{
	/// Paths that need birthtime lookup (not yet cached).
	/// These are GlobalPaths at divergence points between paths in the sharing group.
	GlobalPath[] uncachedPaths;

	/// Full filesystem path strings for uncachedPaths (for stat subprocess).
	/// Slices into a contiguous buffer.
	const(char[])[] pathStrings;

	/// Whether all needed birthtimes are already cached.
	bool allCached() const { return uncachedPaths.length == 0; }
}

/// Find all uncached divergence paths for a pending sharing group.
/// Returns info about which paths need stat resolution.
/// The returned slices are valid until the next call to this function.
PendingStatInfo findUncachedDivergencePaths(SharingGroup* group)
{
	import std.algorithm.searching : canFind;

	// Static buffers - reused across calls to avoid repeated GC allocations.
	// Safe because only one stat request is in flight at a time.
	// Using .length = 0 preserves capacity for reuse.
	static GlobalPath[] uncachedPathsBuf;
	static char[] pathStringsBuf;
	static const(char)[][] pathSlicesBuf;

	uncachedPathsBuf.length = 0;
	pathStringsBuf.length = 0;
	pathSlicesBuf.length = 0;

	if (group.paths.length <= 1)
		return PendingStatInfo.init; // No divergence points for single-path groups

	void checkPath(GlobalPath path)
	{
		if (path.subPath is null)
			return;

		// Skip if already checked
		if (uncachedPathsBuf.canFind(path))
			return;

		// Skip if already cached
		if (isBirthtimeCached(path))
			return;

		// Check if this is a registered subvolume (uses otime, not birthtime)
		if ((cast(GlobalPath*) &path) in rootInfoByRootPath)
			return;

		// Need to stat this path - append to static buffers
		uncachedPathsBuf ~= path;

		// Build path string directly into buffer
		auto startPos = pathStringsBuf.length;
		pathStringsBuf ~= fsPath;
		path.toFilesystemPath((const(char)[] s) { pathStringsBuf ~= s; });
		pathSlicesBuf ~= pathStringsBuf[startPos .. $];
	}

	// Find all divergence points by comparing adjacent pairs.
	// Since paths are sorted lexicographically, paths with common prefixes are
	// contiguous. This means every divergence point appears in exactly one
	// adjacent pair, making O(n) comparison sufficient instead of O(n²).
	for (size_t i = 0; i + 1 < group.paths.length; i++)
	{
		auto divergence = findDivergenceCreationInfo(&group.paths[i], &group.paths[i + 1]);
		if (divergence.diverged)
		{
			// Check if birthtimes at divergence points are cached.
			// The divergence point is the directory where the paths differ.
			// We need to check the SubPath that diverged.

			// Extract the GlobalPath to the diverging directory for each path.
			// This is complex because findDivergenceCreationInfo doesn't return
			// the actual GlobalPaths at the divergence point.

			// For simplicity, we'll check all intermediate paths along the chain.
			// This may check more paths than strictly necessary, but is correct.
			void checkAllPaths(ref GlobalPath gp)
			{
				for (auto subPath = gp.subPath; subPath !is null && subPath.parent !is null; subPath = subPath.parent)
				{
					GlobalPath intermediate;
					intermediate.parent = gp.parent;
					intermediate.subPath = subPath;
					checkPath(intermediate);
				}
			}
			checkAllPaths(group.paths[i]);
			checkAllPaths(group.paths[i + 1]);
		}
	}

	PendingStatInfo result;
	result.uncachedPaths = uncachedPathsBuf;
	result.pathStrings = pathSlicesBuf;
	return result;
}

// ============================================================
// Marks upkeep
// ============================================================

BrowserPath marked;  /// A fake `BrowserPath` used to represent all marked nodes.
ulong markTotalSamples; /// Number of seen samples since the mark was invalidated.

/// Initialize the `marked` BrowserPath structure.
/// Since it has no children or sharing groups, we force aggregateData allocation.
static this()
{
	marked.forceAggregateData();
}

/// Set to true when a deletion has occurred, relaxing certain invariant checks.
/// Guarded by debug(check) since it's only used for assertions.
debug(check) bool deletionOccurred;

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

/// Increment generation counter and signal subprocesses.
/// Samples from before this generation will be discarded.
void incrementGeneration()
{
	import core.sys.posix.signal : kill, SIGUSR1;
	currentGeneration++;
	foreach (ref subproc; subprocesses)
		if (subproc.pid !is typeof(subproc.pid).init)
			kill(subproc.pid.processID, SIGUSR1);
}

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

/// Remove a path at the given index from a sharing group.
/// Shifts remaining paths and pathData down to fill the gap.
/// The paths slice is shrunk by 1; pathData length is tracked via paths.length.
private void removePathFromGroup(SharingGroup* group, size_t index)
{
	auto len = group.paths.length;
	assert(index < len, "Index out of bounds");

	// Shift paths down
	foreach (i; index .. len - 1)
		group.paths[i] = group.paths[i + 1];
	group.paths = group.paths[0 .. len - 1];

	// Shift pathData down
	// Note: pathData[i].path and pathData[i].next pointers remain valid
	// (they point to BrowserPaths/groups, not indices)
	foreach (i; index .. len - 1)
		group.pathData[i] = group.pathData[i + 1];
}

/// Evict a path from all its sharing groups using un-ingest/edit/re-ingest.
/// This modifies sharing groups in-place to remove this path, redistributing
/// samples to remaining paths or to a <DELETED> node if the group becomes empty.
void evictPathFromSharingGroups(BrowserPath* path)
{
	import std.traits : EnumMembers;

	if (path.firstSharingGroup is null)
		return;  // Directory node - children already handled

	// Process each sharing group that contains this path
	for (auto group = path.firstSharingGroup; group !is null; )
	{
		// Find ALL occurrences of this path (may appear multiple times if same extent used multiple times)
		auto ourIndex = group.findIndex(path);
		assert(ourIndex != size_t.max, "Could not find path in sharing group");
		if (ourIndex == size_t.max)
			break;

		// Save next pointer before modifying group (use the first occurrence's next pointer)
		auto nextGroup = group.pathData[ourIndex].next;

		// 1. Un-ingest: Remove this group's sample contribution
		unpopulateBrowserPathsFromSharingGroup(
			group,
			false,  // needsLinking = false
			group.data.samples,
			group.data.offsets[],
			group.data.duration
		);

		// 2. Unhash: Remove from the sharingGroups global HashMap before modifying paths
		sharingGroups.remove(SharingGroup.Paths(group));

		// 3. In-place delete ALL occurrences of this path
		// (occurrences are adjacent, so keep removing at the same index)
		while (ourIndex < group.paths.length &&
		       group.pathData[ourIndex].path is path)
		{
			removePathFromGroup(group, ourIndex);
		}

		// 4. Handle empty group or recalculate representative
		bool needsLinking = false;
		if (group.paths.length == 0)
		{
			// The group is now empty.
			// Replace the path list with a <DELETED> GlobalPath.
			// Follow the same pattern as other special nodes (see subproc.d).
			group.paths = group.paths.ptr[0 .. 1];  // Reuse array memory
			group.paths[0] = GlobalPath(null, subPathRoot.appendName("\0DELETED"));
			group.pathData[0].path = null;  // Will be created by Phase 1 of re-ingestion
			group.pathData[0].next = null;
			group.representativeIndex = 0;
			needsLinking = true;  // New path needs to be linked and created
		}
		else
		{
			// Recalculate representative
			group.representativeIndex = selectRepresentativeIndex(group.paths);

			// In non-expert mode, only the representative has a path pointer set.
			// If the new representative doesn't have one, re-ingestion will create it.
			// Note: when the representative changes, the group remains linked in the
			// old representative's firstSharingGroup chain (we don't unlink it because
			// that would require traversing the singly-linked list). This is harmless:
			// relevantOccurrences() returns 0 for the old representative since it checks
			// group.pathData[group.representativeIndex].path, which no longer matches.
			// Similar to tombstones, it's dead weight in the chain but not incorrect.
			if (!expert && group.pathData[group.representativeIndex].path is null)
				needsLinking = true;
		}

		// 5. Check for merge with existing group
		auto existingGroupPtr = SharingGroup.Paths(group) in sharingGroups;
		if (existingGroupPtr)
		{
			// Merge into existing group (including offsets based on lastSeen)
			auto existingGroup = existingGroupPtr.group;
			existingGroup.mergeFrom(group);
			// Re-ingest existing group with additional samples
			populateBrowserPathsFromSharingGroup(
				existingGroup,
				false,  // needsLinking = false (existingGroup is already linked)
				group.data.samples,
				group.data.offsets[],
				group.data.duration
			);
			// Leave the original group in place as a tombstone.
			// It remains in paths' firstSharingGroup chains (via pathData[i].next),
			// but setting data to SampleData.init makes it inert: getSamples() etc.
			// multiply by group.data.samples which is now 0, so tombstones contribute
			// nothing. See BrowserPath.relevantOccurrences for details.
			// The reason for using a tombstone is that properly unlinking the sharing
			// group is expensive: sharing group linkage for browser paths is a
			// singly-linked list, so we would need to iterate over the full chain of
			// every path in the sharing group in order to unlink it.
			group.data = SampleData.init;
		}
		else
		{
			// 6. Rehash and re-ingest
			sharingGroups.insert(SharingGroup.Paths(group));
			// Need linking if we created a new representative path that isn't in any chain yet
			populateBrowserPathsFromSharingGroup(
				group,
				needsLinking,
				group.data.samples,
				group.data.offsets[],
				group.data.duration
			);
		}

		group = nextGroup;
	}

	// After processing all sharing groups, this node should have zero samples
	// because each group's un-ingest removed its contribution.
	debug
	{
		static foreach (sampleType; EnumMembers!SampleType)
			assert(path.getSamples(sampleType) == 0,
				"Node still has samples after eviction");
	}
}

/// Direction for populating/unpopulating BrowserPaths from sharing groups.
enum IngestDirection
{
	ingest,    /// Add samples to BrowserPaths
	uningest,  /// Remove samples from BrowserPaths
}

/// Populate or unpopulate BrowserPath tree from a sharing group.
/// Params:
///   direction = Whether to add (ingest) or remove (uningest) samples
///   group = The sharing group to process
///   needsLinking = Whether to link the group to BrowserPaths' firstSharingGroup lists
///                  (true for new groups and for rebuild after reset)
///   samples = Number of samples to add or remove
///   offsets = Sample offsets to record
///   duration = Total duration for these samples
///   target = Which dataset to populate (main or compare)
void populateOrUnpopulateBrowserPathsFromSharingGroup(IngestDirection direction)(
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
		// Skip paths where pathData[i].path is already set (e.g., eviction already set it)
		if (expert)
		{
			foreach (i, ref path; paths)
			{
				if (group.pathData[i].path is null)
				{
					auto pathBrowserPath = root.appendPath(&path);
					group.pathData[i].path = pathBrowserPath;
				}
			}
		}
		else
		{
			if (group.pathData[representativeIndex].path is null)
			{
				auto representativeBrowserPath = root.appendPath(&paths[representativeIndex]);
				group.pathData[representativeIndex].path = representativeBrowserPath;
			}
		}
	}

	// ============================================================
	// Phase 2: Update structure (before linking sharing groups)
	// This ensures aggregateData is allocated where needed.
	// Non-root leaves don't need aggregateData (needsAggregateData returns false for them)
	// because they'll get sharing groups in Phase 3.
	// If new aggregateData is allocated, it captures current values from children
	// (which may already have samples from earlier groups during rebuild).
	// Skip this phase during uningest - nodes already have correct structure.
	// ============================================================
	static if (direction == IngestDirection.ingest)
	{
		if (expert)
		{
			foreach (i, ref path; paths)
				group.pathData[i].path.updateStructure();
		}
		else
		{
			group.pathData[representativeIndex].path.updateStructure();
		}
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
	// Phase 4: Add/remove samples to/from aggregateData
	// ============================================================

	// Helper to add or remove samples based on direction
	void applySamples(BrowserPath* bp, SampleType type)
	{
		static if (direction == IngestDirection.ingest)
			bp.addSamples(type, samples, offsets, duration);
		else
			bp.removeSamples(type, samples, offsets, duration);
	}

	// Add/remove represented samples to/from the representative path
	applySamples(group.pathData[representativeIndex].path, SampleType.represented);

	if (expert)
	{
		auto distributedSamples = double(samples) / paths.length;
		auto distributedDuration = double(duration) / paths.length;

		foreach (i, ref path; paths)
		{
			auto browserPath = group.pathData[i].path;
			applySamples(browserPath, SampleType.shared_);
			static if (direction == IngestDirection.ingest)
				browserPath.addDistributedSample(distributedSamples, distributedDuration);
			else
				browserPath.addDistributedSample(-distributedSamples, -distributedDuration);
		}

		static FastAppender!(BrowserPath*) browserPaths;
		browserPaths.clear();
		foreach (i, ref path; paths)
			browserPaths.put(group.pathData[i].path);

		auto exclusiveBrowserPath = BrowserPath.commonPrefix(browserPaths.peek());
		applySamples(exclusiveBrowserPath, SampleType.exclusive);
	}

	// Update global marked state (only for main dataset)
	if (target == DataSet.main)
	{
		static if (direction == IngestDirection.ingest)
			markTotalSamples += samples;
		else
			markTotalSamples -= samples;

		// Check marks and update marked node (expert mode only)
		// Only during ingest - uningest skips this because invalidateMark() is called
		// after deletion which resets marked.exclusive to 0. This avoids needing to
		// track whether allMarked was true at ingest time.
		static if (direction == IngestDirection.ingest)
		{
			if (expert)
			{
				foreach (i, ref path; paths)
					if (!group.pathData[i].path.getEffectiveMark())
					{
						allMarked = false;
						break;
					}

				if (allMarked)
					applySamples(&marked, SampleType.exclusive);
			}
		}
	}

	debug (check)
		foreach (i, ref path; paths)
			if (group.pathData[i].path)
				group.pathData[i].path.checkState();
}

/// Convenience alias for ingesting samples into BrowserPaths
alias populateBrowserPathsFromSharingGroup = populateOrUnpopulateBrowserPathsFromSharingGroup!(IngestDirection.ingest);

/// Convenience alias for removing samples from BrowserPaths
alias unpopulateBrowserPathsFromSharingGroup = populateOrUnpopulateBrowserPathsFromSharingGroup!(IngestDirection.uningest);

/// Check if any rebuild is in progress
bool rebuildInProgress()
{
	return states[DataSet.main].rebuildState.inProgress ||
	       (compareMode && states[DataSet.compare].rebuildState.inProgress);
}

/// Get overall rebuild progress as a string
string rebuildProgress()
{
	if (states[DataSet.main].rebuildState.inProgress)
		return format!"Rebuilding... %d%%"(states[DataSet.main].rebuildState.progressPercent);
	else if (compareMode && states[DataSet.compare].rebuildState.inProgress)
		return format!"Rebuilding baseline... %d%%"(states[DataSet.compare].rebuildState.progressPercent);
	else
		return "Done";
}

/// Start an incremental rebuild of the BrowserPath tree from all SharingGroups.
/// Call processRebuildStep() repeatedly until rebuildInProgress() is false.
void startRebuild()
{
	debug(check) checkState();
	scope(success) debug(check) checkState();

	// Reset all BrowserPath sample data and sharing group links
	browserRoot.reset();
	if (compareMode)
		compareRoot.reset();
	markTotalSamples = 0;

	// Initialize rebuild for main dataset
	initRebuildForDataset(DataSet.main);

	// Initialize rebuild for compare dataset if in compare mode
	if (compareMode)
		initRebuildForDataset(DataSet.compare);
}

/// Initialize rebuild state for a specific dataset
private void initRebuildForDataset(DataSet dataset)
{
	auto state = &states[dataset];

	// Clear all pathData[i].next pointers to avoid stale values causing cycles
	foreach (ref group; state.sharingGroupAllocator[])
		foreach (i; 0 .. group.paths.length)
			group.pathData[i].next = null;

	// Initialize rebuild state with a range over all current sharing groups
	state.rebuildState.range = state.sharingGroupAllocator[];
	state.rebuildState.total = state.rebuildState.range.length;
	state.rebuildState.processed = 0;
	state.rebuildState.step = state.rebuildState.total / 100;
	if (state.rebuildState.step == 0)
		state.rebuildState.step = 1;
}

/// Process one step of the incremental rebuild (1% of total sharing groups).
/// Returns: true if there is more work to do, false if rebuild is complete.
bool processRebuildStep()
{
	debug(check) checkState();
	scope(success) debug(check) checkState();

	// Process main dataset first, then compare
	foreach (dataset; [DataSet.main, DataSet.compare])
	{
		if (dataset == DataSet.compare && !compareMode)
			continue;

		auto state = &states[dataset];
		if (state.rebuildState.range.empty)
			continue;

		size_t count = 0;
		while (!state.rebuildState.range.empty && count < state.rebuildState.step)
		{
			SharingGroup* group = &state.rebuildState.range.front();

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
				group.data.duration,
				dataset
			);

			state.rebuildState.range.popFront();
			state.rebuildState.processed++;
			count++;
		}

		// Check if there's actually more work (this dataset or next)
		return rebuildInProgress();
	}

	return false;  // All done
}
