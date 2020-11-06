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

import btdu.state;
import btdu.paths;

alias Seed = typeof(Random.defaultSeed);

class Sampler : Thread
{
	Random rndGen;

	this(Seed seed)
	{
		super(&run);
		rndGen = Random(seed);
		start();
	}

private:
	void run()
	{
		while (!withGlobalState((ref g) => g.stop))
		{
			auto targetPos = uniform(0, globalParams.totalSize, rndGen);
			u64 pos = 0;
			foreach (ref chunk; globalParams.chunks)
			{
				auto end = pos + chunk.chunk.length;
				if (end > targetPos)
				{
					auto browserPath = withGlobalState((ref g) {
						auto path = &g.browserRoot;

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
						];
						foreach_reverse (b; 0 .. flagNames.length)
							if (chunk.chunk.type & (1UL << b))
								path = path.appendName(g, flagNames[b]);
						return path;
					});
					GlobalPath[] allPaths;
					if (chunk.chunk.type & BTRFS_BLOCK_GROUP_DATA)
					{
						auto offset = chunk.offset + (targetPos - pos);
						// writeln(offset);
						try
						{
							logicalIno(globalParams.fd, offset,
								(u64 inode, u64 offset, u64 root)
								{
									// writeln("- ", inode, " ", offset, " ", root);
									if (root == BTRFS_ROOT_TREE_OBJECTID)
									{
										withGlobalState((ref g) {
											auto subPath = g.subPathRoot.appendPath(g, "ROOT_TREE");
											allPaths ~= GlobalPath(null, subPath);
										});
										return;
									}

									static GlobalPath*[u64] rootCache; // Thread-local cache
									auto rootGlobalPath = rootCache.require(root, getRoot(root));

									static Appender!(char[]) pathBuf;
									pathBuf.clear();
									pathBuf.formattedWrite!"%s%s\0"(globalParams.fsPath, *rootGlobalPath);
									int rootFD = open(pathBuf.data.ptr, O_RDONLY);
									errnoEnforce(rootFD >= 0, "open:" ~ pathBuf.data[0 .. $-1]);
									scope(exit) close(rootFD);

									inoPaths(rootFD, inode,
										(char[] fn)
										{
											auto subPath = withGlobalState((ref g) => g.subPathRoot.appendPath(g, fn));
											auto path = GlobalPath(rootGlobalPath, subPath);
											allPaths ~= path;
										});
								});
						}
						catch (Exception e)
						{
							browserPath = withGlobalState((ref g) => browserPath
								.appendName(g, "ERROR")
								.appendPath(g, e.msg)
							);
							allPaths = null;
						}
					}
					withGlobalState((ref g) {
						if (allPaths)
						{
							auto shortestPath = allPaths.fold!((a, b) => a.length < b.length ? a : b)();
							browserPath = browserPath.appendPath(g, &shortestPath);
						}
						browserPath.addSample();
						foreach (path; allPaths)
							browserPath.seenAs.add(path);
					});
					break;
				}
				pos = end;
			}
		}
	}
}
