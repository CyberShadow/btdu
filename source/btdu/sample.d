/*
 * Copyright (C) 2020, 2021, 2022  Vladimir Panteleev <btdu@cy.md>
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

/// Sampling subprocess implementation
module btdu.sample;

import core.stdc.errno;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;

import std.algorithm.iteration;
import std.datetime.stopwatch;
import std.exception;
import std.random;
import std.string;

import ae.sys.shutdown;
import ae.utils.appender;
import ae.utils.time : stdTime;

import btrfs;
import btrfs.c.kerncompat;
import btrfs.c.kernel_shared.ctree;

import btdu.proto;

void subprocessMain(string fsPath)
{
	try
	{
		// Ignore SIGINT/SIGTERM, because the main process will handle it for us.
		// We want the main process to receive and process the signal before any child
		// processes do, otherwise the main process doesn't know if the child exited due to an
		// abrupt failure or simply because it received and processed the signal before it did.
		addShutdownHandler((reason) {});

		// if (!quiet) stderr.writeln("Opening filesystem...");
		int fd = open(fsPath.toStringz, O_RDONLY);
		errnoEnforce(fd >= 0, "open");

		// if (!quiet) stderr.writeln("Reading chunks...");
		static struct ChunkInfo
		{
			u64 offset;
			btrfs_chunk chunk; /// No stripes
		}
		ChunkInfo[] chunks;
		enumerateChunks(fd, (u64 offset, const ref btrfs_chunk chunk) {
			chunks ~= ChunkInfo(offset, chunk);
		});

		ulong totalSize = chunks.map!((ref chunk) => chunk.chunk.length).sum;
		// if (!quiet) stderr.writefln("Found %d chunks with a total size of %d.", globalParams.chunks.length, globalParams.totalSize);
		send(StartMessage(totalSize));

		while (true)
		{
			auto targetPos = uniform(0, totalSize);
			u64 pos = 0;
			foreach (ref chunk; chunks)
			{
				auto end = pos + chunk.chunk.length;
				if (end > targetPos)
				{
					auto offset = chunk.offset + (targetPos - pos);
					send(ResultStartMessage(chunk.chunk.type, offset));
					auto sw = StopWatch(AutoStart.yes);

					if (chunk.chunk.type & BTRFS_BLOCK_GROUP_DATA)
					{
						foreach (ignoringOffset; [false, true])
						{
							try
							{
								bool called;
								logicalIno(fd, offset,
									(u64 inode, u64 offset, u64 rootID)
									{
										called = true;

										// writeln("- ", inode, " ", offset, " ", root);
										cast(void) offset; // unused

										// Send new roots before the inode start
										cast(void)getRoot(fd, rootID);

										send(ResultInodeStartMessage(rootID));

										try
										{
											static FastAppender!char pathBuf;
											pathBuf.clear();
											pathBuf.put(fsPath);

											void putRoot(u64 rootID)
											{
												auto root = getRoot(fd, rootID);
												if (root is Root.init)
													enforce(rootID == BTRFS_FS_TREE_OBJECTID, "Unresolvable root");
												else
													putRoot(root.parent);
												if (root.path)
												{
													pathBuf.put('/');
													pathBuf.put(root.path);
												}
											}
											putRoot(rootID);
											pathBuf.put('\0');

											int rootFD = open(pathBuf.get().ptr, O_RDONLY);
											if (rootFD < 0)
											{
												send(ResultInodeErrorMessage(btdu.proto.Error("open", errno, pathBuf.get()[0 .. $-1])));
												return;
											}
											scope(exit) close(rootFD);

											inoPaths(rootFD, inode, (char[] fn) {
												send(ResultMessage(fn));
											});
											send(ResultInodeEndMessage());
										}
										catch (Exception e)
											send(ResultInodeErrorMessage(e.toError));
									},
									ignoringOffset,
								);
								if (!called && !ignoringOffset)
								{
									// Retry with BTRFS_LOGICAL_INO_ARGS_IGNORE_OFFSET
									send(ResultIgnoringOffsetMessage());
									continue;
								}
							}
							catch (Exception e)
								send(ResultErrorMessage(e.toError));
							break;
						}
					}
					send(ResultEndMessage(sw.peek.stdTime));
					break;
				}
				pos = end;
			}
		}
	}
	catch (Throwable e)
	{
		debug
			send(FatalErrorMessage(e.toString()));
		else
			send(FatalErrorMessage(e.msg));
	}
}

private:

struct Root
{
	u64 parent;
	string path;
}
Root[u64] roots;

/// Performs memoized resolution of the path for a btrfs root object.
Root getRoot(int fd, __u64 rootID)
{
	return roots.require(rootID, {
		Root result;
		findRootBackRef(
			fd,
			rootID,
			(
				__u64 parentRootID,
				__u64 dirID,
				__u64 sequence,
				char[] name,
			) {
				cast(void) sequence; // unused

				inoLookup(
					fd,
					parentRootID,
					dirID,
					(char[] dirPath)
					{
						if (result !is Root.init)
							throw new Exception("Multiple root locations");
						result.path = cast(string)(dirPath ~ name);
						result.parent = parentRootID;
					}
				);
			}
		);

		// Ensure parents are written first
		if (result !is Root.init)
			cast(void)getRoot(fd, result.parent);

		send(NewRootMessage(rootID, result.parent, result.path));

		return result;
	}());
}

btdu.proto.Error toError(Exception e)
{
	btdu.proto.Error error;
	error.msg = e.msg;
	if (auto ex = cast(ErrnoException) e)
	{
		// Convert to errno + string
		import core.stdc.string : strlen, strerror_r;
		char[1024] buf = void;
		auto s = strerror_r(errno, buf.ptr, buf.length);

		import std.range : chain;
		auto suffix = chain(" (".representation, s[0 .. s.strlen].representation, ")".representation);
		if (error.msg.endsWith(suffix))
		{
			error.msg = error.msg[0 .. $ - suffix.length];
			error.errno = ex.errno;
		}
		else
			debug assert(false, "Unexpected ErrnoException message: " ~ error.msg);
	}
	return error;
}
