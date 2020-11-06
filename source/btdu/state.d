/*  Copyright (C) 2020  Vladimir Panteleev <btdu@cy.md>
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License as
 *  published by the Free Software Foundation, either version 3 of the
 *  License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/// Global state definitions
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

/// Perform an operation while holding the global state.
T withGlobalState(T)(scope T delegate(ref GlobalState) dg)
{
	synchronized(mutex) return dg(*cast(GlobalState*)&theGlobalState);
}

/// Performs memoized recursive resolution of the path for a btrfs
/// root object.
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
