/*
 * Copyright (C) 2020, 2021  Vladimir Panteleev <btdu@cy.md>
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
import std.stdio;
import std.string;

import ae.utils.array;

import btrfs.c.kernel_shared.ctree;

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
	void handleInput()
	{
		while (true)
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
				return;
			}
			bufEnd += received;
		}
	}

	void handleMessage(StartMessage m)
	{
		if (!totalSize)
			totalSize = m.totalSize;
	}

	void handleMessage(NewRootMessage m)
	{
		globalRoots.require(m.rootID, {
			if (m.parentRootID || m.name.length)
				return new GlobalPath(
					*(m.parentRootID in globalRoots).enforce("Unknown parent root"),
					subPathRoot.appendPath(m.name),
				);
			else
			if (m.rootID == BTRFS_FS_TREE_OBJECTID)
				return new GlobalPath(null, &subPathRoot);
			else
			if (m.rootID == BTRFS_ROOT_TREE_OBJECTID)
				return new GlobalPath(null, subPathRoot.appendName("\0ROOT_TREE"));
			else
				return new GlobalPath(null, subPathRoot.appendName(format!"\0TREE_%d"(m.rootID)));
		}());
	}

	private struct Result
	{
		ulong logicalOffset;
		BrowserPath* browserPath;
		GlobalPath* inodeRoot;
		bool haveInode, havePath;
		bool ignoringOffset;
	}
	private Result result;
	private FastAppender!GlobalPath allPaths;

	void handleMessage(ResultStartMessage m)
	{
		result.logicalOffset = m.logicalOffset;
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
		if ((m.chunkFlags & BTRFS_BLOCK_GROUP_PROFILE_MASK) == 0)
			result.browserPath = result.browserPath.appendName("\0SINGLE");
		foreach_reverse (b; 0 .. flagNames.length)
			if (m.chunkFlags & (1UL << b))
				result.browserPath = result.browserPath.appendName(flagNames[b]);
		if ((m.chunkFlags & BTRFS_BLOCK_GROUP_DATA) == 0)
			result.haveInode = true; // Sampler won't even try
	}

	void handleMessage(ResultInodeStartMessage m)
	{
		result.haveInode = true;
		result.havePath = false;
		result.inodeRoot = *(m.rootID in globalRoots).enforce("Unknown inode root");
		result.ignoringOffset = m.ignoringOffset; // Will be the same for all inodes
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
			result.browserPath = result.browserPath.appendName("\0UNREACHABLE");
		if (!result.haveInode)
			result.browserPath = result.browserPath.appendName("\0NO_INODE");
		auto representativeBrowserPath = result.browserPath;
		if (allPaths.get().length)
		{
			auto representativePath = allPaths.get().fold!((a, b) {
				// Prefer paths with resolved roots
				auto aResolved = a.isResolved();
				auto bResolved = b.isResolved();
				if (aResolved != bResolved)
					return aResolved ? a : b;
				// Shortest path always wins
				auto aLength = a.length;
				auto bLength = b.length;
				if (aLength != bLength)
					return aLength < bLength ? a : b;
				// If the length is the same, pick the lexicographically smallest one
				return a < b ? a : b;
			})();
			representativeBrowserPath = result.browserPath.appendPath(&representativePath);
		}
		representativeBrowserPath.addSample(SampleType.represented, result.logicalOffset, m.duration);

		if (allPaths.get().length)
		{
			foreach (ref path; allPaths.get())
				(*representativeBrowserPath.seenAs.getOrAdd(path, 0UL))++;

			if (expert)
			{
				auto distributedShare = 1.0 / allPaths.get().length;

				static FastAppender!(BrowserPath*) browserPaths;
				browserPaths.clear();
				foreach (ref path; allPaths.get())
				{
					auto browserPath = result.browserPath.appendPath(&path);
					browserPaths.put(browserPath);

					browserPath.addSample(SampleType.shared_, result.logicalOffset, m.duration);
					browserPath.addDistributedSample(distributedShare);
				}

				auto exclusiveBrowserPath = BrowserPath.commonPrefix(browserPaths.get());
				exclusiveBrowserPath.addSample(SampleType.exclusive, result.logicalOffset, m.duration);
			}
		}
		else
		{
			if (expert)
			{
				representativeBrowserPath.addSample(SampleType.shared_, result.logicalOffset, m.duration);
				representativeBrowserPath.addSample(SampleType.exclusive, result.logicalOffset, m.duration);
				representativeBrowserPath.addDistributedSample(1);
			}
		}

		result = Result.init;
		allPaths.clear();
	}

	void handleMessage(FatalErrorMessage m)
	{
		throw new Exception("Subprocess encountered a fatal error:\n" ~ cast(string)m.msg);
	}
}

private bool isResolved(ref GlobalPath p)
{
	return !p.range
		.map!(g => g.range)
		.joiner
		.canFind!(n => n.startsWith("\0TREE_"));
}

private SubPath* appendError(ref SubPath path, ref btdu.proto.Error error)
{
	auto result = &path;
	result = result.appendName("\0ERROR");
	result = result.appendName(error.msg);
	if (error.errno | error.path.length)
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
