/*
 * Copyright (C) 2026  Vladimir Panteleev <btdu@cy.md>
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

/// Stat subprocess management from main process side.
module btdu.stat.subproc;

import core.sys.posix.signal : SIGTERM;
import core.sys.posix.unistd : dup;

import std.algorithm.searching : countUntil;
import std.file : thisExePath;
import std.process : Pid, Pipe, pipe, spawnProcess, kill, wait;
import std.socket : AddressFamily, Socket, socket_t;

import btdu.proto : ProtocolMixin;
import btdu.paths : GlobalPath, SharingGroup, selectRepresentativePath;
import btdu.state : birthtimeCache, clearRequestedPaths, fsPath, getRequestedUncachedPaths,
	hasRequestedUncachedPaths, pendingGroups, populateBrowserPathsFromSharingGroup,
	sharingGroupAllocator;
import btdu.stat.proto;

/// Manages the stat subprocess for async birthtime resolution.
struct StatSubprocess
{
	Pipe toSubproc;    /// Main -> Subprocess (requests)
	Pipe fromSubproc;  /// Subprocess -> Main (responses)
	Socket readSocket; /// Socket wrapper for select()
	Pid pid;

	/// Paths for the current in-flight request (null if idle).
	GlobalPath[] inFlightPaths;

	// Response handler with buffer management
	mixin ProtocolMixin!ResponseMessages;
	bool wantData() { return !responseReceived; }  // Stop after receiving one response

	/// Received response (set by handleMessage)
	private StatResponse lastResponse;
	private bool responseReceived;

	void start()
	{
		toSubproc = pipe();
		fromSubproc = pipe();

		readSocket = new Socket(cast(socket_t)dup(fromSubproc.readEnd.fileno), AddressFamily.UNSPEC);
		readSocket.blocking = false;

		pid = spawnProcess(
			[
				thisExePath,
				"--process-type=stat",
				"--",
				fsPath,
			],
			toSubproc.readEnd,  // Subprocess stdin
			fromSubproc.writeEnd, // Subprocess stdout
		);

		initialize();
	}

	void terminate()
	{
		// Send graceful shutdown request
		if (toSubproc.writeEnd.isOpen)
			sendRequest(toSubproc.writeEnd.fileno, ShutdownRequest());

		if (readSocket)
		{
			readSocket.close();
			readSocket = null;
		}
		toSubproc.readEnd.close();
		toSubproc.writeEnd.close();
		fromSubproc.readEnd.close();
		fromSubproc.writeEnd.close();

		if (pid !is Pid.init)
		{
			wait(pid);
			pid = Pid.init;
		}
	}

	/// Returns true if we're waiting for a response.
	bool isBusy() const
	{
		return inFlightPaths !is null;
	}

	/// Send a request to the stat subprocess. Only call when not busy!
	void sendStatRequest(GlobalPath[] paths, const(char[])[] pathStrings)
	{
		assert(!isBusy(), "Cannot send request while busy");
		sendRequest(toSubproc.writeEnd.fileno, StatRequest(pathStrings));
		inFlightPaths = paths;
	}

	/// Check for and process responses from stat subprocess.
	/// Returns true if a complete response was received.
	bool handleInput()
	{
		responseReceived = false;
		handleReadable(fromSubproc.readEnd.fileno);

		if (!responseReceived)
			return false;

		// Got a complete response - update cache
		if (inFlightPaths !is null)
		{
			foreach (i, bt; lastResponse.birthtimes)
			{
				if (i < inFlightPaths.length)
					birthtimeCache[inFlightPaths[i]] = bt;
			}
			inFlightPaths = null; // Now idle
		}

		return true;
	}

	void handleMessage(StatResponse resp)
	{
		lastResponse = resp;
		responseReceived = true;
	}

	/// Process pending sharing groups that may now be resolvable.
	/// Only sends a stat request if idle. Call after receiving a response
	/// to continue processing the queue.
	void processPendingGroups()
	{
		// If we're waiting for a response, don't do anything
		if (isBusy())
			return;

		while (!pendingGroups.empty)
		{
			SharingGroup* group = pendingGroups.frontPtr;

			// Skip if already resolved (shouldn't happen, but be safe)
			if (!group.isPending())
			{
				pendingGroups.popFront();
				continue;
			}

			// On-demand birthtime resolution:
			// 1. Clear the requested paths buffer
			// 2. Run selectRepresentativePath - this may record cache misses
			// 3. If any paths were requested, send stat request and retry later
			clearRequestedPaths();

			// Resolve the representative (may request uncached birthtimes)
			// Don't store the result yet - we'll retry if birthtimes are needed
			ptrdiff_t representativeIndex;
			if (group.paths.length > 0)
			{
				auto representativePath = selectRepresentativePath(group.paths);
				representativeIndex = group.paths.countUntil!(p => p is representativePath);
			}
			else
			{
				representativeIndex = 0;
			}

			// Check if any birthtimes were needed but not cached
			if (hasRequestedUncachedPaths())
			{
				auto statInfo = getRequestedUncachedPaths();
				// Need to stat some paths - send request and wait
				sendStatRequest(statInfo.uncachedPaths, statInfo.pathStrings);
				// Don't advance the queue or update representativeIndex - we'll retry
				return;
			}

			// All birthtimes were available (or not needed)
			// Now safe to mark as resolved and populate the tree
			group.representativeIndex = representativeIndex;
			populateBrowserPathsFromSharingGroup(
				group,
				true,  // isNew for initial population
				group.data.samples,
				group.data.offsets[],
				group.data.duration
			);

			pendingGroups.popFront();
		}
	}
}

/// Global stat subprocess manager instance.
StatSubprocess* statSubproc;
