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

/// Subprocess management
module btdu.subproc;

import core.sys.posix.signal;
import core.sys.posix.unistd;

import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.conv;
import std.exception;
import std.file;
import std.process;
import std.random;
import std.socket;
import std.stdio : stdin;
import std.string;

import ae.utils.array;

import btrfs.c.kernel_shared.ctree;

import btdu.alloc;
import btdu.common;
import btdu.paths;
import btdu.proto;
import btdu.state;

/// Represents one managed subprocess
struct Subprocess
{
	Pipe pipe;
	Socket socket;
	Pid pid;

	void start()
	{
		pipe = .pipe();
		socket = new Socket(cast(socket_t)pipe.readEnd.fileno.dup, AddressFamily.UNSPEC);
		socket.blocking = false;

		pid = spawnProcess(
			[
				thisExePath,
				"--subprocess",
				"--seed", rndGen.uniform!Seed.text,
				"--physical=" ~ physical.text,
				"--",
				fsPath,
			],
			stdin,
			pipe.writeEnd,
		);
	}

	void pause(bool doPause)
	{
		pid.kill(doPause ? SIGSTOP : SIGCONT);
	}

	/// Receive buffer
	private ubyte[] buf;
	/// Section of buffer containing received and unparsed data
	private size_t bufStart, bufEnd;

	/// Called when select() identifies that the process wrote something.
	/// Reads one datum; returns `true` if there is more to read.
	bool handleInput()
	{
		assert(!rebuildState.inProgress, "handleInput() called during rebuild");

		auto data = buf[bufStart .. bufEnd];
		auto bytesNeeded = parse(data, this);
		bufStart = bufEnd - data.length;
		if (bufStart == bufEnd)
			bufStart = bufEnd = 0;
		if (buf.length < bufEnd + bytesNeeded)
		{
			// Moving remaining data to the start of the buffer
			// may allow us to avoid an allocation.
			if (bufStart > 0)
			{
				copy(buf[bufStart .. bufEnd], buf[0 .. bufEnd - bufStart]);
				bufEnd -= bufStart;
				bufStart -= bufStart;
			}
			if (buf.length < bufEnd + bytesNeeded)
			{
				buf.length = bufEnd + bytesNeeded;
				buf.length = buf.capacity;
			}
		}
		auto received = read(pipe.readEnd.fileno, buf.ptr + bufEnd, buf.length - bufEnd);
		enforce(received != 0, "Unexpected subprocess termination");
		if (received == Socket.ERROR)
		{
			errnoEnforce(wouldHaveBlocked, "Subprocess read error");
			return false; // Done
		}
		bufEnd += received;
		return true; // Not done
	}

	void handleMessage(StartMessage m)
	{
		if (!totalSize)
		{
			totalSize = m.totalSize;
			devices = m.devices;
		}
	}

	void handleMessage(NewRootMessage m)
	{
		if (m.rootID in globalRoots)
			return;

		RootInfo info;
		if (m.parentRootID || m.name.length)
			info.path = new GlobalPath(
				(m.parentRootID in globalRoots).enforce("Unknown parent root").path,
				subPathRoot.appendPath(m.name),
			);
		else
		if (m.rootID == BTRFS_FS_TREE_OBJECTID)
			info.path = new GlobalPath(null, &subPathRoot);
		else
		if (m.rootID == BTRFS_ROOT_TREE_OBJECTID)
			info.path = new GlobalPath(null, subPathRoot.appendName("\0ROOT_TREE"));
		else
			info.path = new GlobalPath(null, subPathRoot.appendName(format!"\0TREE_%d"(m.rootID)));

		globalRoots[m.rootID] = info;
	}

	private struct Result
	{
		Offset offset;
		BrowserPath* browserPath;
		RootInfo* inodeRoot;
		bool haveInode, havePath;
		bool ignoringOffset;
	}
	private Result result;
	private FastAppender!GlobalPath allPaths;

	void handleMessage(ResultStartMessage m)
	{
		result.offset = m.offset;
		result.browserPath = &browserRoot;
		static immutable flagNames = [
			"DATA",
			"SYSTEM",
			"METADATA",
			"RAID0",
			"RAID1",
			"DUP",
			"RAID10",
			"RAID5",
			"RAID6",
			"RAID1C3",
			"RAID1C4",
		].amap!(s => "\0" ~ s);
		if (result.offset.logical == logicalOffsetHole)
			result.browserPath = result.browserPath.appendName("\0UNALLOCATED");
		else if (result.offset.logical == logicalOffsetSlack)
			result.browserPath = result.browserPath.appendName("\0SLACK");
		else if ((m.chunkFlags & BTRFS_BLOCK_GROUP_PROFILE_MASK) == 0)
			result.browserPath = result.browserPath.appendName("\0SINGLE");
		foreach_reverse (b; 0 .. flagNames.length)
			if (m.chunkFlags & (1UL << b))
				result.browserPath = result.browserPath.appendName(flagNames[b]);
		if ((m.chunkFlags & BTRFS_BLOCK_GROUP_DATA) == 0)
			result.haveInode = true; // Sampler won't even try
	}

	void handleMessage(ResultIgnoringOffsetMessage m)
	{
		cast(void) m; // empty message
		result.ignoringOffset = true;
	}

	void handleMessage(ResultInodeStartMessage m)
	{
		result.haveInode = true;
		result.havePath = false;
		result.inodeRoot = (m.rootID in globalRoots).enforce("Unknown inode root");
	}

	void handleMessage(ResultInodeErrorMessage m)
	{
		allPaths ~= GlobalPath(result.inodeRoot.path, subPathRoot.appendError(m.error));
	}

	void handleMessage(ResultMessage m)
	{
		result.havePath = true;
		allPaths ~= GlobalPath(result.inodeRoot.path, subPathRoot.appendPath(m.path));
	}

	void handleMessage(ResultInodeEndMessage m)
	{
		cast(void) m; // empty message
		if (!result.havePath)
			allPaths ~= GlobalPath(result.inodeRoot.path, subPathRoot.appendPath("\0NO_PATH"));
	}

	void handleMessage(ResultErrorMessage m)
	{
		allPaths ~= GlobalPath(null, subPathRoot.appendError(m.error));
		result.haveInode = true;
	}

	/// Get or create a sharing group for the given paths
	private static SharingGroup* saveSharingGroup(BrowserPath* root, GlobalPath[] paths, out bool isNew)
	{
		import std.experimental.allocator : makeArray, make;

		// Create a temporary group for lookup
		SharingGroup lookupGroup;
		lookupGroup.root = root;
		lookupGroup.paths = paths;
		auto groupKey = SharingGroup.Paths(&lookupGroup);

		auto existingGroupPtr = groupKey in sharingGroups;
		SharingGroup* group;

		if (existingGroupPtr)
		{
			// Reuse existing group
			group = existingGroupPtr.group;
			if (group.data.samples == 1)
				numSingleSampleGroups--;
			isNew = false;
		}
		else
		{
			// New set of paths - allocate and create new group
			auto persistentPaths = growAllocator.makeArray!GlobalPath(paths.length);
			persistentPaths[] = paths[];
			auto pathData = growAllocator.makeArray!(SharingGroup.PathData)(paths.length);
			pathData[] = SharingGroup.PathData.init;

			// Find the representative index
			size_t representativeIndex = size_t.max;
			if (persistentPaths.length > 0)
			{
				auto representativePath = selectRepresentativePath(persistentPaths);
				representativeIndex = persistentPaths.countUntil!(p => p is representativePath);
			}

			// Create the sharing group
			SharingGroup newGroupData;
			newGroupData.root = root;
			newGroupData.paths = persistentPaths;
			newGroupData.pathData = pathData.ptr;
			newGroupData.representativeIndex = representativeIndex;
			group = sharingGroupAllocator.allocate();
			*group = newGroupData;

			// Add to HashSet for future deduplication
			sharingGroups.insert(SharingGroup.Paths(group));

			numSharingGroups++;
			numSingleSampleGroups++;

			isNew = true;
		}

		return group;
	}

	void handleMessage(ResultEndMessage m)
	{
		debug(check) checkState(); scope(success) debug(check) checkState();

		if (result.ignoringOffset)
		{
			if (!result.haveInode)
			{} // Same with or without BTRFS_LOGICAL_INO_ARGS_IGNORE_OFFSET
			else
				result.browserPath = result.browserPath.appendName("\0UNREACHABLE");
		}

		if (!result.haveInode)
			result.browserPath = result.browserPath.appendName("\0NO_INODE");

		// For special nodes (METADATA, SYSTEM, etc.) with no filesystem paths,
		// construct a single artificial GlobalPath to represent the ownership.
		if (allPaths.peek().length == 0)
			allPaths ~= GlobalPath(null, &subPathRoot);

		auto pathsSlice = allPaths.peek();

		// Sort paths for consistent hashing/deduplication
		{
			import std.algorithm.sorting : sort;
			import std.typecons : tuple;
			pathsSlice.sort!((ref a, ref b) =>
				tuple(a.parent, a.subPath) < tuple(b.parent, b.subPath)
			);
		}

		// Get or create sharing group
		bool isNewGroup;
		auto group = saveSharingGroup(result.browserPath, pathsSlice, isNewGroup);

		// Populate BrowserPath tree from sharing group
		populateBrowserPathsFromSharingGroup(
			group,
			isNewGroup,
			1,  // Adding 1 sample
			(&result.offset)[0..1],
			m.duration
		);

		// Update sharing group's own sample counter.
		// This happens after populateBrowserPathsFromSharingGroup so that
		// group.data reflects the final state when the function returns.
		group.data.add(1, (&result.offset)[0..1], m.duration);

		// Track when this extent was last seen (shift existing values, add new at end)
		auto currentCounter = browserRoot.getSamples(SampleType.represented);
		foreach (i; 0 .. group.lastSeen.length)
			group.lastSeen[i] = i + 1 == group.lastSeen.length
				? currentCounter
				: group.lastSeen[i + 1];

		result = Result.init;
		allPaths.clear();
	}

	void handleMessage(FatalErrorMessage m)
	{
		throw new Exception("Subprocess encountered a fatal error:\n" ~ cast(string)m.msg);
	}
}

private SubPath* appendError(ref SubPath path, ref btdu.proto.Error error)
{
	auto result = &path;

	import core.stdc.errno : ENOENT;
	if (&path == &subPathRoot && error.errno == ENOENT && error.msg == "logical ino")
		return result.appendName("\0UNUSED");

	result = result.appendName("\0ERROR");
	result = result.appendName(error.msg);
	if (error.errno || error.path.length)
	{
		result = result.appendName(getErrno(error.errno).name);
		if (error.path.length)
		{
			auto errorPath = error.path;
			if (!errorPath.skipOver("/"))
				debug assert(false, "Non-absolute path: " ~ errorPath);
			result = result.appendPath(errorPath);
		}
	}
	return result;
}
