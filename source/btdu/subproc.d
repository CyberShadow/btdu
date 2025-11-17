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

		GlobalPath* path;
		if (m.parentRootID || m.name.length)
			path = new GlobalPath(
				*(m.parentRootID in globalRoots).enforce("Unknown parent root"),
				subPathRoot.appendPath(m.name),
			);
		else
		if (m.rootID == BTRFS_FS_TREE_OBJECTID)
			path = new GlobalPath(null, &subPathRoot);
		else
		if (m.rootID == BTRFS_ROOT_TREE_OBJECTID)
			path = new GlobalPath(null, subPathRoot.appendName("\0ROOT_TREE"));
		else
			path = new GlobalPath(null, subPathRoot.appendName(format!"\0TREE_%d"(m.rootID)));

		globalRoots[m.rootID] = path;
	}

	private struct Result
	{
		Offset offset;
		BrowserPath* browserPath;
		GlobalPath* inodeRoot;
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
		result.inodeRoot = *(m.rootID in globalRoots).enforce("Unknown inode root");
	}

	void handleMessage(ResultInodeErrorMessage m)
	{
		allPaths ~= GlobalPath(result.inodeRoot, subPathRoot.appendError(m.error));
	}

	void handleMessage(ResultMessage m)
	{
		result.havePath = true;
		allPaths ~= GlobalPath(result.inodeRoot, subPathRoot.appendPath(m.path));
	}

	void handleMessage(ResultInodeEndMessage m)
	{
		cast(void) m; // empty message
		if (!result.havePath)
			allPaths ~= GlobalPath(result.inodeRoot, subPathRoot.appendPath("\0NO_PATH"));
	}

	void handleMessage(ResultErrorMessage m)
	{
		allPaths ~= GlobalPath(null, subPathRoot.appendError(m.error));
		result.haveInode = true;
	}

	void handleMessage(ResultEndMessage m)
	{
		if (result.ignoringOffset)
		{
			if (!result.haveInode)
			{} // Same with or without BTRFS_LOGICAL_INO_ARGS_IGNORE_OFFSET
			else
				result.browserPath = result.browserPath.appendName("\0UNREACHABLE");
		}

		if (!result.haveInode)
			result.browserPath = result.browserPath.appendName("\0NO_INODE");
		auto representativeBrowserPath = result.browserPath;
		GlobalPath representativePath;
		if (allPaths.peek().length)
		{
			representativePath = selectRepresentativePath(allPaths.peek());
			representativeBrowserPath = result.browserPath.appendPath(&representativePath);
		}
		representativeBrowserPath.addSample(SampleType.represented, result.offset, m.duration);

		bool allMarked = true;
		if (allPaths.peek().length)
		{
			import std.experimental.allocator : makeArray, make;

			// Check if we've seen this exact set of paths before
			auto pathsSlice = allPaths.peek();

			// Convert GlobalPath[] to SamplePath[] for lookup
			static FastAppender!SamplePath samplePaths;
			samplePaths.clear();
			foreach (ref globalPath; pathsSlice)
				samplePaths.put(SamplePath(result.browserPath, globalPath));
			auto paths = samplePaths.peek();

			auto existingGroup = paths in sharingGroups;
			SharingGroup* group;

			if (existingGroup)
			{
				// Reuse existing group, just increment sample count
				group = *existingGroup;
				group.samples++;
			}
			else
			{
				// New set of paths - allocate and create new group
				// Need to make a persistent copy since the SharingGroup will hold onto it
				// TODO: store the GlobalPath[] instead since all SamplePath roots are the same
				auto persistentPaths = growAllocator.makeArray!SamplePath(paths.length);
				persistentPaths[] = paths[];
				auto nextPointers = growAllocator.makeArray!(SharingGroup*)(paths.length);
				nextPointers[] = null;

				// Create the sharing group
				group = growAllocator.make!SharingGroup(
					SharingGroup(1, persistentPaths, nextPointers.ptr)
				);

				// Add to HashMap for future deduplication
				sharingGroups[persistentPaths] = group;
			}

			// Find which path is the representative
			size_t representativeIndex = {
				foreach (i, ref path; pathsSlice)
					if (path is representativePath)
						return i;
				assert(false, "Representative path not found");
			}();

			// Link new sharing groups to BrowserPaths' firstSharingGroup list
			if (!existingGroup)
			{
				// In expert mode, link this group to all BrowserPaths
				// In non-expert mode, only link to the representative
				if (expert)
				{
					// Link to all BrowserPaths
					foreach (i, ref path; pathsSlice)
					{
						auto pathBrowserPath = result.browserPath.appendPath(&path);
						group.next[i] = pathBrowserPath.firstSharingGroup;
						pathBrowserPath.firstSharingGroup = group;
					}
				}
				else
				{
					// Only link to representative path
					group.next[representativeIndex] = representativeBrowserPath.firstSharingGroup;
					representativeBrowserPath.firstSharingGroup = group;
				}
			}

			if (expert)
			{
				auto distributedSamples = 1.0 / pathsSlice.length;
				auto distributedDuration = double(m.duration) / pathsSlice.length;

				static FastAppender!(BrowserPath*) browserPaths;
				browserPaths.clear();
				foreach (ref path; pathsSlice)
				{
					auto browserPath = result.browserPath.appendPath(&path);
					browserPaths.put(browserPath);

					browserPath.addSample(SampleType.shared_, result.offset, m.duration);
					browserPath.addDistributedSample(distributedSamples, distributedDuration);
				}

				auto exclusiveBrowserPath = BrowserPath.commonPrefix(browserPaths.peek());
				exclusiveBrowserPath.addSample(SampleType.exclusive, result.offset, m.duration);

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
				foreach (ref path; pathsSlice)
				{
					auto browserPath = result.browserPath.appendPath!true(&path);
					if (browserPath && !browserPath.getEffectiveMark())
					{
						allMarked = false;
						break;
					}
				}
			}
		}
		else
		{
			if (expert)
			{
				representativeBrowserPath.addSample(SampleType.shared_, result.offset, m.duration);
				representativeBrowserPath.addSample(SampleType.exclusive, result.offset, m.duration);
				representativeBrowserPath.addDistributedSample(1, m.duration);
			}
			allMarked = representativeBrowserPath.getEffectiveMark();
		}

		markTotalSamples++;
		if (allMarked)
		{
			if (expert)
				marked.addSample(SampleType.exclusive, result.offset, m.duration);
		}

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
