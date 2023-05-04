/*
 * Copyright (C) 2023  Vladimir Panteleev <btdu@cy.md>
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

/// Interactive deletion logic
module btdu.ui.deletion;

import std.algorithm.comparison;
import std.algorithm.searching;
import std.exception;
import std.typecons;

import core.sync.event;
import core.sys.posix.fcntl : O_RDONLY;
import core.thread : Thread;

import ae.sys.file : listDir, getMounts;

import btrfs : getSubvolumeID, deleteSubvolume;

struct Deleter
{
	enum State
	{
		none,
		progress,
		success,
		error,
		subvolumeConfirm,
		subvolumeProgress,
	}
	State state;

	Thread thread;
	string current, error;
	bool stopping;
	Event subvolumeResume;

	@property bool needRefresh()
	{
		return this.state == Deleter.State.progress;
	}

	void start(string path)
	{
		assert(this.state == State.none);
		this.current = path;
		this.stopping = false;
		this.subvolumeResume.initialize(false, false);
		this.thread = new Thread(&threadFunc);
		this.state = State.progress;
		this.thread.start();
	}

	private void threadFunc()
	{
		ulong initialDeviceID;
		listDir!((e) {
			synchronized(this.thread)
				this.current = e.fullName;

			if (this.stopping)
			{
				// e.stop();
				// return;
				throw new Exception("User abort");
			}

			if (!initialDeviceID)
				initialDeviceID = e.needStat!(e.StatTarget.dirEntry)().st_dev;

			if (e.entryIsDir)
			{
				auto stat = e.needStat!(e.StatTarget.dirEntry)();

				// A subvolume root, or a different btrfs filesystem is mounted here
				auto isTreeRoot = stat.st_ino.among(2, 256);

				if (stat.st_dev != initialDeviceID || isTreeRoot)
				{
					if (getMounts().canFind!(mount => mount.file == e.fullNameFS))
						throw new Exception("Path resides in another filesystem, stopping");
					enforce(isTreeRoot, "Unexpected st_dev change");
					// Can only be a subvolume going forward.

					this.state = State.subvolumeConfirm;
					this.subvolumeResume.wait();
					if (this.stopping)
						throw new Exception("User abort");

					auto fd = openat(e.dirFD, e.baseNameFSPtr, O_RDONLY);
					errnoEnforce(fd >= 0, "openat");
					auto subvolumeID = getSubvolumeID(fd);
					deleteSubvolume(fd, subvolumeID);

					this.state = State.progress;
					return; // The ioctl will also unlink the directory entry
				}

				e.recurse();
			}

			int ret = unlinkat(e.dirFD, e.baseNameFSPtr,
				e.entryIsDir ? AT_REMOVEDIR : 0);
			errnoEnforce(ret == 0, "unlinkat failed");
		}, Yes.includeRoot)(this.current);
	}

	void confirm(Flag!"proceed" proceed)
	{
		assert(this.state == State.subvolumeConfirm);
		if (proceed)
			this.state = State.subvolumeProgress;
		else
		{
			this.stopping = true;
			this.state = State.progress;
		}
		this.subvolumeResume.set();
	}

	void stop()
	{
		this.stopping = true;
	}

	void finish()
	{
		assert(this.state.among(State.success, State.error));
		this.state = State.none;
	}

	void update()
	{
		if (this.state == State.progress && !this.thread.isRunning())
		{
			try
			{
				this.thread.join();

				// Success:
				this.state = State.success;
			}
			catch (Exception e)
			{
				// Failure:
				this.error = e.msg;
				this.state = State.error;
			}
			this.thread = null;
			this.subvolumeResume.terminate();
		}
	}
}

private:

// TODO: upstream into Druntime
extern (C) int openat(int fd, const char *path, int oflag, ...) nothrow @nogc;
extern (C) int unlinkat(int fd, const(char)* pathname, int flags);
enum AT_REMOVEDIR = 0x200;
