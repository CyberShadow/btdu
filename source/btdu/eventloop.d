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

import std.exception : errnoEnforce;

/// Event loop member.
class Receiver
{
	abstract int getFD();
	abstract ubyte[] getReadBuffer();
	abstract void handleRead(size_t received);
	bool active() { return true; }
}

/// Event loop abstraction.
class EventLoop
{
	abstract void add(Receiver receiver);
	abstract void step();
}

EventLoop makeEventLoop()
{
	// TODO
	return new SelectLoop();
}

private:

/// select()-based main event loop.
class SelectLoop : EventLoop
{
	import std.socket : Socket, socket_t, AddressFamily, SocketSet, wouldHaveBlocked;
	import core.sys.posix.unistd : read;

	struct Item
	{
		Socket socket;
		Receiver receiver;
	}
	Item[] items;

	SocketSet readSet, exceptSet;

	this()
	{
		readSet = new SocketSet;
		exceptSet = new SocketSet; // TODO needed?
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
		exceptSet.reset();
		foreach (ref item; items)
			if (item.receiver.active)
			{
				readSet.add(item.socket);
				exceptSet.add(item.socket);
			}
		Socket.select(readSet, null, exceptSet);
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
