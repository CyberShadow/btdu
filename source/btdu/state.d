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
	auto pcachedRoot = withGlobalState((ref g) => rootID in g.globalRoots);
	if (pcachedRoot)
		return *pcachedRoot;
	// Intentional cache race so that we don't do I/O with the lock held
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
					SubPath* subPath = withGlobalState((ref g) {
						SubPath* subPath = &g.subPathRoot;
						if (dirPath.length)
						{
							enforce(dirPath[$ - 1] == '/',
								"ino lookup ioctl returned path without trailing /");
							subPath = subPath.appendPath(g, dirPath[0 .. $-1]);
						}
						subPath = subPath.appendName(g, name);
						return subPath;
					});
					// Recursive locking is OK too, D's synchronized blocks are reentrant.
					auto parentPath = getRoot(parentRootID);
					assert(result is null, "Multiple root locations");
					result = new GlobalPath(parentPath, subPath);
				}
			);
		}
	);
	assert(result, "Root not found");
	withGlobalState((ref g) {
		g.globalRoots.update(rootID,
			// We are the first
			{ return result; },
			// Another thread beat us to it
			(ref GlobalPath* old) { result = old; },
		);
	});
	return result;
}
