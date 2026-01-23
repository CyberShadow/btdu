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

/// Stat subprocess protocol messages.
/// Bidirectional: main process <-> stat subprocess.
module btdu.stat.proto;

import core.sys.posix.unistd;

import std.meta;

import ae.utils.array : asBytes;

import btdu.proto : Header, sendBuf, serialize, sendRaw;

// ============================================================================
// Request Messages (main -> subprocess)
// ============================================================================

/// Request birthtimes for paths.
struct StatRequest
{
	const(char[])[] paths;
}

alias RequestMessages = AliasSeq!(
	StatRequest,
);


/// Send a request to stat subprocess via its stdin fd.
void sendRequest(T)(int fd, auto ref T message)
if (staticIndexOf!(T, RequestMessages) >= 0)
{
	Header header;
	header.type = staticIndexOf!(T, RequestMessages);
	sendBuf.clear();
	serialize(message);
	header.length = Header.sizeof + sendBuf.length;
	sendRaw(fd, header.asBytes);
	sendRaw(fd, sendBuf.peek());
}

// ============================================================================
// Response Messages (subprocess -> main)
// ============================================================================

/// Birthtimes for requested paths (nanoseconds since epoch, 0 = unknown).
struct StatResponse
{
	long[] birthtimes;
}

alias ResponseMessages = AliasSeq!(
	StatResponse,
);


/// Send a response from stat subprocess to main via stdout.
void sendResponse(T)(auto ref T message)
if (staticIndexOf!(T, ResponseMessages) >= 0)
{
	Header header;
	header.type = staticIndexOf!(T, ResponseMessages);
	sendBuf.clear();
	serialize(message);
	header.length = Header.sizeof + sendBuf.length;
	sendRaw(STDOUT_FILENO, header.asBytes);
	sendRaw(STDOUT_FILENO, sendBuf.peek());
}
