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

/// Sampling subprocess implementation
module btdu.sample;

import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import core.thread;

import std.algorithm.iteration;
import std.array;
import std.exception;
import std.format;
import std.random;
import std.string;

import btrfs;
import btrfs.c.kerncompat;
import btrfs.c.kernel_shared.ctree;
import btrfs.c.ioctl;

import btdu.proto;

void subprocessMain(string fsPath)
{
	try
	{
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
					send(ResultStartMessage(chunk.chunk.type));

					if (chunk.chunk.type & BTRFS_BLOCK_GROUP_DATA)
					{
						auto offset = chunk.offset + (targetPos - pos);
						try
						{
							logicalIno(fd, offset,
								(u64 inode, u64 offset, u64 rootID)
								{
									// writeln("- ", inode, " ", offset, " ", root);
									cast(void) offset; // unused

									// Send new roots before the inode start
									cast(void)getRoot(fd, rootID);

									send(ResultInodeStartMessage(rootID));

									try
									{
										static Appender!(char[]) pathBuf;
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

										int rootFD = open(pathBuf.data.ptr, O_RDONLY);
										if (rootFD < 0)
											throw new Exception(new ErrnoException("open").msg ~ cast(string)pathBuf.data[0 .. $-1]);
										scope(exit) close(rootFD);

										inoPaths(rootFD, inode, (char[] fn) {
											send(ResultMessage(fn));
										});
									}
									catch (Exception e)
										send(ResultInodeErrorMessage(e.msg));
								});
						}
						catch (Exception e)
						{
							send(ResultErrorMessage(e.msg));
						}
					}
					send(ResultEndMessage());
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
