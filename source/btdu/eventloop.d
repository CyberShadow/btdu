/*
 * Copyright (C) 2021  Vladimir Panteleev <btdu@cy.md>
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

/// Event loop implementations.
module btdu.eventloop;

import core.sys.posix.sys.uio;

import std.exception : errnoEnforce, ErrnoException;

/// Event loop member.
class Receiver
{
	/// Get file descriptor.
	abstract int getFD() nothrow @nogc;
	/// Where to place read data. `null` to only poll for read readiness.
	abstract ubyte[] getReadBuffer() nothrow @nogc;
	/// Called when data has been read.
	abstract void handleRead(size_t received);
	/// Active now?
	bool active() { return true; }
}

/// Event loop abstraction.
class EventLoop
{
	abstract void add(Receiver receiver);
	abstract void step();
}

EventLoop makeEventLoop(uint size)
{
	try
		return new IOUringLoop(size);
	catch (Exception e)
	{
		import std.stdio : stderr;
		stderr.writefln("io_uring initialization failed (%s), using select().", e.msg);
		return new SelectLoop();
	}
}

private:

/// select()-based main event loop.
final class SelectLoop : EventLoop
{
	import std.socket : Socket, socket_t, AddressFamily, SocketSet, wouldHaveBlocked;
	import core.sys.posix.unistd : read;

	struct Item
	{
		Socket socket;
		Receiver receiver;
	}
	Item[] items;

	SocketSet readSet;

	this()
	{
		readSet = new SocketSet;
	}

	override void add(Receiver receiver)
	{
		Item item;
		item.receiver = receiver;
		item.socket = new Socket(cast(socket_t)receiver.getFD(), AddressFamily.UNSPEC);
		item.socket.blocking = false;
		items ~= item;
	}

	override void step()
	{
		readSet.reset();
		foreach (ref item; items)
			if (item.receiver.active)
				readSet.add(item.socket);
		Socket.select(readSet, null, null);
		foreach (ref item; items)
			if (readSet.isSet(item.socket))
				while (true)
				{
					auto readBuf = item.receiver.getReadBuffer();
					if (readBuf is null)
					{
						item.receiver.handleRead(0);
						break;
					}

					auto received = read(item.socket.handle, readBuf.ptr, readBuf.length);
					if (received == Socket.ERROR)
					{
						errnoEnforce(wouldHaveBlocked, "Read error");
						break;
					}
					item.receiver.handleRead(received);
				}
	}
}

/// io_uring-based main event loop.
final class IOUringLoop : EventLoop
{
	import during : Uring, setup, SubmissionEntry, prepPollAdd, PollEvents, PollFlags, prepReadv, setUserData;

	Uring io;

	struct Item
	{
		Receiver receiver;
		iovec v;
	}
	Item[] items;

	this(uint size)
	{
		auto ret = io.setup(2 * size);
		if (ret < 0)
			throw new ErrnoException("I/O initialization error", -ret);
	}

	override void add(Receiver receiver)
	{
		auto index = items.length;
		items ~= Item(receiver);
		put(index);
	}

	void put(size_t index)
	{
		io.putWith!(
			(ref SubmissionEntry e, size_t index, ref Item item)
			{
				auto buf = item.receiver.getReadBuffer();
				if (buf is null)
					e.prepPollAdd(item.receiver.getFD(), PollEvents.IN);
				else
				{
					item.v = iovec(buf.ptr, buf.length);
					e.prepReadv(item.receiver.getFD(), item.v, 0);
				}

				e.user_data = index;
			})(index, items[index]);
	}

	override void step()
	{
		int ret = io.submit();
		if (ret < 0)
			throw new ErrnoException("I/O submission error", -ret);

        ret = io.wait();
		if (ret < 0)
			throw new ErrnoException("I/O error", -ret);

		while (!io.empty)
		{
			auto index = io.front.user_data;
			auto receiver = items[index].receiver;
			if (io.front.res < 0)
				throw new ErrnoException("Read error", -io.front.res);

			receiver.handleRead(io.front.res);
			io.popFront();

			put(index);
		}
		
		ret = io.submit();
		if (ret < 0)
			throw new ErrnoException("I/O submission error", -ret);

	}
}
