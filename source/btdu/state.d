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

import std.traits : EnumMembers;

import ae.utils.appender : FastAppender;
import ae.utils.meta : enumLength;

import btrfs.c.ioctl : btrfs_ioctl_dev_info_args;
import btrfs.c.kerncompat : u64;

import containers.hashset;
import containers.internal.hash : generateHash;

import btdu.alloc;
import btdu.paths;
import btdu.subproc : Subprocess;

// Global variables

__gshared: // btdu is single-threaded

bool imported;
bool expert;
bool physical;
bool exportSeenAs;
string fsPath;
ulong totalSize;
btrfs_ioctl_dev_info_args[] devices;

SubPath subPathRoot;
GlobalPath*[u64] globalRoots;
BrowserPath browserRoot;

/// Deduplicates sharing groups - multiple samples with the same set of paths
/// will reference the same SharingGroup and just increment its sample count.
HashSet!(SharingGroup.Paths, CasualAllocator, SharingGroup.Paths.hashOf, false, true) sharingGroups;

/// Slab allocator instance for SharingGroups - enables efficient iteration over all groups.
SlabAllocator!SharingGroup sharingGroupAllocator;

/// Total number of created sharing groups
size_t numSharingGroups;
/// Number of sharing groups with exactly 1 sample
size_t numSingleSampleGroups;

BrowserPath marked;  /// A fake `BrowserPath` used to represent all marked nodes.
ulong markTotalSamples; /// Number of seen samples since the mark was invalidated.

/// Called when something is marked or unmarked.
void invalidateMark()
{
	markTotalSamples = 0;
	if (expert)
		marked.resetNodeSamples(SampleType.exclusive);
}

/// Update stats in `marked` for a redisplay.
void updateMark()
{
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
		auto reference = &browserRoot;

		// We use `SampleType.represented` because
		// 1. It is always going to be collected
		//    (it's the only sample type collected in non-expert mode);
		// 2. At the root level, it will exactly correspond to the total number
		//    of samples collected.
		enum type = SampleType.represented;

		return reference.getSamples(type);
	}
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
void populateBrowserPathsFromSharingGroup(
	SharingGroup* group,
	bool needsLinking,
	ulong samples,
	const(Offset)[] offsets,
	ulong duration
)
{
	bool allMarked = true;
	auto root = group.root;
	auto paths = group.paths;

	// Handle empty paths case (root-only, no sharing)
	if (paths.length == 0)
	{
		root.addSamples(SampleType.represented, samples, offsets, duration);
		if (expert)
		{
			root.addSamples(SampleType.shared_, samples, offsets, duration);
			root.addSamples(SampleType.exclusive, samples, offsets, duration);
			root.addDistributedSample(samples, duration);
		}
		allMarked = root.getEffectiveMark();
		// Update global marked state
		markTotalSamples += samples;
		if (allMarked && expert)
			marked.addSamples(SampleType.exclusive, samples, offsets, duration);
		return;
	}

	// Link sharing groups to BrowserPaths' firstSharingGroup list
	auto representativeIndex = group.representativeIndex;
	if (needsLinking)
	{
		// In expert mode, link this group to all BrowserPaths
		// In non-expert mode, only link to the representative
		if (expert)
		{
			// Link to all BrowserPaths
			foreach (i, ref path; paths)
			{
				auto pathBrowserPath = root.appendPath(&path);
				group.pathData[i].path = pathBrowserPath;
				group.pathData[i].next = pathBrowserPath.firstSharingGroup;
				pathBrowserPath.firstSharingGroup = group;
			}
		}
		else
		{
			// Only link to representative path
			auto representativeBrowserPath = root.appendPath(&paths[representativeIndex]);
			group.pathData[representativeIndex].path = representativeBrowserPath;
			group.pathData[representativeIndex].next = representativeBrowserPath.firstSharingGroup;
			representativeBrowserPath.firstSharingGroup = group;
		}
	}

	// Add represented samples to the representative path (using cached path)
	group.pathData[representativeIndex].path.addSamples(SampleType.represented, samples, offsets, duration);

	if (expert)
	{
		auto distributedSamples = double(samples) / paths.length;
		auto distributedDuration = double(duration) / paths.length;

		static FastAppender!(BrowserPath*) browserPaths;
		browserPaths.clear();
		foreach (i, ref path; paths)
		{
			auto browserPath = group.pathData[i].path;
			browserPaths.put(browserPath);

			browserPath.addSamples(SampleType.shared_, samples, offsets, duration);
			browserPath.addDistributedSample(distributedSamples, distributedDuration);
		}

		auto exclusiveBrowserPath = BrowserPath.commonPrefix(browserPaths.peek());
		exclusiveBrowserPath.addSamples(SampleType.exclusive, samples, offsets, duration);

		foreach (ref path; browserPaths.get())
			if (!path.getEffectiveMark())
			{
				allMarked = false;
				break;
			}
	}
	else
	{
		if (false) // `allMarked` result will not be used in non-expert mode anyway...
		foreach (ref path; paths)
		{
			auto browserPath = root.appendPath!true(&path);
			if (browserPath && !browserPath.getEffectiveMark())
			{
				allMarked = false;
				break;
			}
		}
	}

	// Update global marked state
	markTotalSamples += samples;
	if (allMarked && expert)
		marked.addSamples(SampleType.exclusive, samples, offsets, duration);
}

/// Rebuild the BrowserPath tree from all SharingGroups.
/// Call this after changing pathRules to recompute representative paths.
void rebuildFromSharingGroups()
{
	// Reset all BrowserPath sample data and sharing group links
	browserRoot.reset();
	markTotalSamples = 0;

	// Rebuild from all sharing groups
	foreach (ref group; sharingGroupAllocator)
	{
		// Recalculate which path is the representative under current rules
		group.representativeIndex = selectRepresentativeIndex(group.paths);

		// Repopulate BrowserPath tree from this group's stored data
		populateBrowserPathsFromSharingGroup(
			&group,
			true,  // needsLinking - always true for rebuild
			group.data.samples,
			group.data.offsets[],
			group.data.duration
		);
	}
}
