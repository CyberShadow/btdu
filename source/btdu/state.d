module btdu.state;

import std.exception;
import std.string;

import btrfs;
import btrfs.c.kerncompat;
import btrfs.c.kernel_shared.ctree;

import btdu.paths;

/// Non-mutable global state
struct GlobalParams
{
	string fsPath;
	int fd;

	struct ChunkInfo
	{
		u64 offset;
		btrfs_chunk chunk; /// No stripes
	}
	ChunkInfo[] chunks;
	ulong totalSize;
}
__gshared GlobalParams globalParams;

/// Mutable global state
struct GlobalState
{
	SubPath subPathRoot;
	GlobalPath*[u64] globalRoots;
	BrowserPath browserRoot;
	bool stop;
}

shared Object mutex = new Object;

private shared GlobalState theGlobalState;

T withGlobalState(T)(scope T delegate(ref GlobalState) dg)
{
	synchronized(mutex) return dg(*cast(GlobalState*)&theGlobalState);
}

GlobalPath* getRoot(__u64 rootID)
{
	if (rootID == BTRFS_FS_TREE_OBJECTID)
		return null;
	return withGlobalState(
		(ref GlobalState g)
		{
			return g.globalRoots.require(
				rootID,
				{
					// This keeps the global mutex locked while we do I/O,
					// but that's OK because the number of roots should be
					// relatively small, and we only need to query them once.
					GlobalPath* result;
					findRootBackRef(
						globalParams.fd,
						rootID,
						(
							__u64 parentRootID,
							__u64 dirID,
							__u64 sequence,
							char[] name,
						) {
							inoLookup(
								globalParams.fd,
								parentRootID,
								dirID,
								(char[] dirPath)
								{
									SubPath* subPath = &g.subPathRoot;
									if (dirPath.length)
									{
										enforce(dirPath[$ - 1] == '/',
											"ino lookup ioctl returned path without trailing /");
										subPath = subPath.appendPath(g, dirPath[0 .. $-1]);
									}
									subPath = subPath.appendName(g, name);
									// Recursive locking is OK too, D's synchronized blocks are reentrant.
									auto parentPath = getRoot(parentRootID);
									assert(result is null, "Multiple root locations");
									result = new GlobalPath(parentPath, subPath);
								}
							);
						}
					);
					assert(result, "Root not found");
					return result;
				}(),
			);
		}
	);
}
