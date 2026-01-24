/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2024, 2026  Vladimir Panteleev <btdu@cy.md>
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

/// Shared protocol infrastructure for subprocess communication.
/// Provides serialization, message framing, and parsing for both
/// sample and stat subprocess protocols.
module btdu.proto;

import core.sys.posix.unistd;

import std.exception;
import std.meta;
import std.traits : hasIndirections, Unqual;

import ae.utils.array;

import btdu.alloc : StaticAppender;

// ============================================================================
// Incremental Parser Buffer Management
// ============================================================================

/// Result status from handleReadable.
enum ReadStatus
{
	hasMore,    /// More data may be available to read
	wouldBlock, /// No more data currently available (non-blocking)
	eof,        /// End of file reached (pipe closed)
}

/// Combined protocol handler mixin providing buffer management, parsing, and I/O.
/// The mixing-in struct must implement:
///   - `bool wantData()` - return false to stop processing
///   - `void handleMessage(M)` - for each message type M in AllMessages
mixin template ProtocolMixin(AllMessages...)
{
	// Re-export ReadStatus so it's accessible in the mixin context
	static import btdu.proto;
	alias ReadStatus = btdu.proto.ReadStatus;

	private ubyte[] buf;
	private size_t bufStart, bufEnd;

	void initialize()
	{
		buf.length = 4096;
		bufStart = bufEnd = 0;
	}

	/// Called when fd is readable. Reads data and parses messages.
	/// Returns ReadStatus indicating whether more data is available or EOF was reached.
	ReadStatus handleReadable(int fd)
	{
		import core.sys.posix.unistd : read;
		import std.algorithm.mutation : copy;
		import std.exception : errnoEnforce;
		import std.socket : wouldHaveBlocked;

		// Read available data
		auto received = read(fd, buf.ptr + bufEnd, buf.length - bufEnd);
		if (received == 0)
			return ReadStatus.eof;
		if (received < 0)
		{
			errnoEnforce(wouldHaveBlocked, "Subprocess read error");
			return ReadStatus.wouldBlock;
		}
		bufEnd += received;

		// Parse messages
		auto dataSlice = buf[bufStart .. bufEnd];
		auto bytesNeeded = parseMessages(dataSlice);
		bufStart = bufEnd - dataSlice.length;
		if (bufStart == bufEnd)
			bufStart = bufEnd = 0;

		// Ensure capacity for next read/message
		if (buf.length - bufEnd < bytesNeeded)
		{
			if (bufStart > 0)
			{
				copy(buf[bufStart .. bufEnd], buf[0 .. bufEnd - bufStart]);
				bufEnd -= bufStart;
				bufStart = 0;
			}
			if (buf.length - bufEnd < bytesNeeded)
			{
				buf.length = bufEnd + bytesNeeded;
				buf.length = buf.capacity;
			}
		}

		return bytesNeeded > 0 ? ReadStatus.hasMore : ReadStatus.wouldBlock;
	}

	/// Parse messages from buffer. Returns bytes needed for next message, 0 if done.
	private size_t parseMessages(ref ubyte[] data)
	{
		import ae.utils.array : shift;
		import btdu.proto : Header, deserialize;

		while (true)
		{
			if (!wantData())
				return 0;

			if (data.length < Header.sizeof)
				return Header.sizeof - data.length;

			auto header = (cast(Header*) data.ptr);
			if (data.length < header.length)
				return header.length - data.length;

			auto initialLen = data.length;
			data.shift(Header.sizeof);

		typeSwitch:
			switch (header.type)
			{
				foreach (i, Message; AllMessages)
				{
					case i:
						handleMessage(deserialize!Message(data));
						break typeSwitch;
				}
				default:
					assert(false, "Unknown message type");
			}

			auto consumed = initialLen - data.length;
			assert(consumed == header.length, "Deserialization size mismatch");
		}
		assert(false); // Unreachable
	}
}


// ============================================================================
// Message Framing
// ============================================================================

struct Header
{
	/// Total message size including Header.
	/// Putting length up front allows processing entire messages in one go.
	size_t length;
	/// Index into the protocol's AllMessages tuple
	size_t type;
}

// ============================================================================
// Serialization
// ============================================================================

/// Thread-local send buffer shared across all protocols
StaticAppender!ubyte sendBuf;

void serialize(T)(ref T value)
{
	static if (!hasIndirections!T)
		sendBuf.put(value.asBytes);
	else
	static if (is(T U : U[]))
	{
		size_t length = value.length;
		serialize(length);
		static if (!hasIndirections!U)
			sendBuf.put(value.asBytes);
		else
			foreach (ref e; value)
				serialize(e);
	}
	else
	static if (is(T == struct))
	{
		foreach (ref f; value.tupleof)
			serialize(f);
	}
	else
		static assert(false, "Can't serialize " ~ T.stringof);
}

void sendRaw(int fd, const(void)[] data)
{
	import core.stdc.errno : errno, EINTR;
	while (data.length)
	{
		auto written = write(fd, data.ptr, data.length);
		if (written > 0)
			data.shift(written);
		else if (errno != EINTR)
			errnoEnforce(false, "write");
		// On EINTR, retry the write
	}
}


// ============================================================================
// Deserialization
// ============================================================================

T deserialize(T)(ref ubyte[] buf)
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
		{
			// Array of types with indirections - need to allocate
			// Use Unqual to handle const element types
			alias MutableU = Unqual!U;
			auto result = new MutableU[length];
			foreach (ref e; result)
				e = deserialize!MutableU(buf);
			return cast(T) result;
		}
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
		static assert(false, "Can't deserialize " ~ T.stringof);
}
