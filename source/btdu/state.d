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

shared static this() { browserRoot.setMark(false); }

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
	marked.data[] = (BrowserPath.Data[enumLength!SampleType]).init;
	marked.distributedSamples = marked.distributedDuration = 0;

	browserRoot.enumerateMarks(
		(ref const BrowserPath path, bool isMarked)
		{
			if (&path is &browserRoot)
				return;
			if (isMarked)
			{
				static foreach (sampleType; EnumMembers!SampleType)
					marked.addSamples(sampleType, path.data[sampleType].samples, path.data[sampleType].offsets[], path.data[sampleType].duration);
				marked.addDistributedSample(path.distributedSamples, path.distributedDuration);
			}
			else
			{
				static foreach (sampleType; EnumMembers!SampleType)
					marked.removeSamples(sampleType, path.data[sampleType].samples, path.data[sampleType].offsets[], path.data[sampleType].duration);
				marked.removeDistributedSample(path.distributedSamples, path.distributedDuration);
			}
		}
	);
}

Subprocess[] subprocesses;
bool paused;
debug bool importing;
