/*
 * Copyright (C) 2020  Vladimir Panteleev <btdu@cy.md>
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

import ae.utils.array;

import core.sys.posix.unistd;

import std.algorithm.iteration;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.process;
import std.random;
import std.socket;
import std.stdio;
import std.string;

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
		socket = new Socket(cast(socket_t)pipe.readEnd.fileno, AddressFamily.UNSPEC);
		socket.blocking = false;

		pid = spawnProcess(
			[
				thisExePath,
				"--subprocess",
				"--seed", rndGen.uniform!Seed.text,
				fsPath,
			],
			stdin,
			pipe.writeEnd,
		);
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
				buf.length = bufEnd + bytesNeeded;
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
		BrowserPath* browserPath;
		GlobalPath* inodeRoot;
		GlobalPath[] allPaths;
	}
	private Result result;

	void handleMessage(ResultStartMessage m)
	{
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
		foreach_reverse (b; 0 .. flagNames.length)
			if (m.chunkFlags & (1UL << b))
				result.browserPath = result.browserPath.appendName(flagNames[b]);
	}

	void handleMessage(ResultInodeStartMessage m)
	{
		result.inodeRoot = *(m.rootID in globalRoots).enforce("Unknown inode root");
	}

	void handleMessage(ResultInodeErrorMessage m)
	{
		result.allPaths ~= GlobalPath(result.inodeRoot, subPathRoot.appendName("\0ERROR").appendPath(m.msg));
	}

	void handleMessage(ResultMessage m)
	{
		result.allPaths ~= GlobalPath(result.inodeRoot, subPathRoot.appendPath(m.path));
	}

	void handleMessage(ResultErrorMessage m)
	{
		result.allPaths ~= GlobalPath(null, subPathRoot.appendName("\0ERROR").appendPath(m.msg));
	}

	void handleMessage(ResultEndMessage m)
	{
		if (result.allPaths)
		{
			auto canonicalPath = result.allPaths.fold!((a, b) {
				// Shortest path always wins
				auto aLength = a.length;
				auto bLength = b.length;
				if (aLength != bLength)
					return aLength < bLength ? a : b;
				// If the length is the same, pick the lexicographically smallest one
				return a < b ? a : b;
			})();
			result.browserPath = result.browserPath.appendPath(&canonicalPath);
		}
		result.browserPath.addSample(m.duration);
		foreach (path; result.allPaths)
			result.browserPath.seenAs.add(path);
		result = Result.init;
	}

	void handleMessage(FatalErrorMessage m)
	{
		throw new Exception("Subprocess encountered a fatal error:\n" ~ cast(string)m.msg);
	}
}
