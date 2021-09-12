/*
 * Copyright (C) 2020, 2021  Vladimir Panteleev <btdu@cy.md>
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

/// Main process / subprocess communication protocol
module btdu.proto;

import ae.utils.appender;
import ae.utils.array;

import core.sys.posix.unistd;

import std.exception;
import std.meta;
import std.traits;

import btrfs.c.kerncompat : u64, __u64;

struct Error
{
	const(char)[] msg;
}

struct StartMessage
{
	ulong totalSize;
}

struct NewRootMessage
{
	__u64 rootID, parentRootID;
	const(char)[] name;
}

struct ResultStartMessage
{
	ulong chunkFlags;
	ulong logicalOffset;
}

struct ResultInodeStartMessage
{
	u64 rootID;
	bool ignoringOffset;
}

struct ResultInodeErrorMessage
{
	Error error;
}

struct ResultInodeEndMessage
{
}

struct ResultMessage
{
	const(char)[] path;
}

struct ResultErrorMessage
{
	Error error;
}

struct ResultEndMessage
{
	ulong duration;
}

struct FatalErrorMessage
{
	const(char)[] msg;
}

alias AllMessages = AliasSeq!(
	StartMessage,
	NewRootMessage,
	ResultStartMessage,
	ResultInodeStartMessage,
	ResultInodeErrorMessage,
	ResultInodeEndMessage,
	ResultMessage,
	ResultErrorMessage,
	ResultEndMessage,
	FatalErrorMessage,
);

struct Header
{
	/// Even when the length is redundant (fixed-size messages),
	/// putting it up front allows simplifying deserialization and
	/// process entire messages in one go
	size_t length;
	/// Index into AllMessages
	size_t type;
}

FastAppender!ubyte sendBuf;

private void serialize(T)(ref T value)
{
	static if (!hasIndirections!T)
		sendBuf.put(value.bytes);
	else
	static if (is(T U : U[]))
	{
		size_t length = value.length;
		serialize(length);
		static if (!hasIndirections!U)
			sendBuf.put(value.bytes);
		else
			foreach (ref e; value)
				serialize(value);
	}
	else
	static if (is(T == struct))
	{
		foreach (ref f; value.tupleof)
			serialize(f);
	}
	else
		static assert(false, "Can't serialize" ~ T.stringof);
}

private void sendRaw(const(void)[] data)
{
	auto written = write(STDOUT_FILENO, data.ptr, data.length);
	errnoEnforce(written > 0, "write");
	data.shift(written);
	if (!data.length)
		return;
	sendRaw(data);
}

/// Send a message from a subprocess to the main process.
void send(T)(auto ref T message)
if (staticIndexOf!(T, AllMessages) >= 0)
{
	Header header;
	header.type = staticIndexOf!(T, AllMessages);
	sendBuf.clear();
	serialize(message);
	header.length = Header.sizeof + sendBuf.length;
	sendRaw(header.bytes);
	sendRaw(sendBuf.peek());
}

private T deserialize(T)(ref ubyte[] buf)
{
	static if (!hasIndirections!T)
		return (cast(T[])buf.shift(T.sizeof))[0];
	else
	static if (is(T U : U[]))
	{
		size_t length = deserialize!size_t(buf);
		static if (!hasIndirections!U)
			return cast(U[])buf.shift(U.sizeof * length);
		else
			static assert(false, "Can't deserialize arrays of types with indirections without allocating");
	}
	else
	static if (is(T == struct))
	{
		T value;
		foreach (ref f; value.tupleof)
			f = deserialize!(typeof(f))(buf);
		return value;
	}
	else
		static assert(false, "Can't deserialize" ~ T.stringof);
}

/// Decode received data.
/// Returns how many bytes should be read before calling this function again.
/// H should implement handleMessage(M) overloads for every M in AllMessages.
size_t parse(H)(ref ubyte[] buf, ref H handler)
{
	while (true)
	{
		if (buf.length < Header.sizeof)
			return Header.sizeof - buf.length;

		auto header = (cast(Header*)buf.ptr);
		if (buf.length < header.length)
			return header.length - buf.length;

		buf.shift(Header.sizeof);

	typeSwitch:
		switch (header.type)
		{
			foreach (i, Message; AllMessages)
			{
				case i:
					handler.handleMessage(deserialize!Message(buf));
					break typeSwitch;
			}
			default:
				assert(false, "Unknown message");
		}
	}
	assert(false, "Unreachable");
}
