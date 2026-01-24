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

/// Stat subprocess implementation.
/// Performs blocking statx() calls to get birthtimes without blocking the main UI.
module btdu.stat.process;

import core.sys.posix.unistd : STDIN_FILENO, read;

import ae.sys.shutdown;

import btdu.proto : ProtocolMixin;
import btdu.stat.proto;
import btdu.statx;

/// Entry point for the stat subprocess.
/// Reads requests from stdin, performs statx() calls, sends responses to stdout.
void statSubprocessMain()
{
	// Ignore SIGINT/SIGTERM, because the main process will handle it for us.
	addShutdownHandler((reason) {});

	RequestHandler handler;
	handler.initialize();

	while (handler.running)
	{
		handler.handleReadable(STDIN_FILENO);
	}
}

/// Handler for incoming stat requests.
private struct RequestHandler
{
	bool running = true;

	mixin ProtocolMixin!RequestMessages;

	bool wantData()
	{
		return running;
	}

	void handleMessage(StatRequest req)
	{
		long[] birthtimes = new long[req.paths.length];
		foreach (i, pathStr; req.paths)
			birthtimes[i] = doStatx(pathStr);
		sendResponse(StatResponse(birthtimes));
	}

	void handleMessage(ShutdownRequest)
	{
		running = false;
	}
}

/// Perform statx() syscall to get birthtime.
/// Returns birthtime in nanoseconds since epoch, or 0 if unknown.
private long doStatx(const(char)[] pathStr)
{
	// Need null-terminated string for statx
	char[] nullTerminated = new char[pathStr.length + 1];
	nullTerminated[0 .. pathStr.length] = pathStr[];
	nullTerminated[pathStr.length] = '\0';

	statx_t stx;
	int ret = statx(AT_FDCWD, nullTerminated.ptr, AT_SYMLINK_NOFOLLOW, STATX_BTIME, &stx);

	if (ret == 0 && (stx.stx_mask & STATX_BTIME))
		return stx.stx_btime.tv_sec * 1_000_000_000L + stx.stx_btime.tv_nsec;

	return 0; // Unknown
}
