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
		marked.resetSamples(SampleType.exclusive);
}

/// Update stats in `marked` for a redisplay.
void updateMark()
{
	static foreach (sampleType; EnumMembers!SampleType)
		if (sampleType != SampleType.exclusive)
			marked.resetSamples(sampleType);
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
