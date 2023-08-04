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

/// Global state definitions
module btdu.state;

import std.traits : EnumMembers;

import ae.utils.meta : enumLength;

import btrfs.c.ioctl : btrfs_ioctl_dev_info_args;
import btrfs.c.kerncompat : u64;

import btdu.paths;
import btdu.subproc : Subprocess;

// Global variables

__gshared: // btdu is single-threaded

bool imported;
bool expert;
bool physical;
string fsPath;
ulong totalSize;
btrfs_ioctl_dev_info_args[] devices;

SubPath subPathRoot;
GlobalPath*[u64] globalRoots;
BrowserPath browserRoot;

BrowserPath marked;  /// A fake `BrowserPath` used to represent all marked nodes.
ulong markTotalSamples; /// Number of seen samples since the mark was invalidated.

/// Called when something is marked or unmarked.
void invalidateMark()
{
	markTotalSamples = 0;
	if (expert)
		marked.data[SampleType.exclusive] = BrowserPath.Data.init;
}

/// Update stats in `marked` for a redisplay.
void updateMark()
{
	static foreach (sampleType; EnumMembers!SampleType)
		if (sampleType != SampleType.exclusive)
			marked.data[sampleType] = BrowserPath.Data.init;
	marked.distributedSamples = marked.distributedDuration = 0;

	browserRoot.enumerateMarks(
		(const BrowserPath* path, bool isMarked)
		{
			if (isMarked)
			{
				static foreach (sampleType; EnumMembers!SampleType)
					if (sampleType != SampleType.exclusive)
						marked.addSamples(sampleType, path.data[sampleType].samples, path.data[sampleType].offsets[], path.data[sampleType].duration);
				marked.addDistributedSample(path.distributedSamples, path.distributedDuration);
			}
			else
			{
				static foreach (sampleType; EnumMembers!SampleType)
					if (sampleType != SampleType.exclusive)
						marked.removeSamples(sampleType, path.data[sampleType].samples, path.data[sampleType].offsets[], path.data[sampleType].duration);
				marked.removeDistributedSample(path.distributedSamples, path.distributedDuration);
			}
		}
	);
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
