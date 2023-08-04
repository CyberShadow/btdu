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
import std.conv : to;
import std.exception;
import std.path;
import std.typecons;

import core.sync.event;
import core.sys.posix.fcntl : O_RDONLY;
import core.thread : Thread;

import ae.sys.file : listDir, getMounts;

import btrfs : getSubvolumeID, deleteSubvolume;

import btdu.paths : BrowserPath, Mark;
import btdu.state : toFilesystemPath;

struct Deleter
{
	enum State
	{
		none,
		ready, // confirmation
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

	/// One item to delete.
	struct Item
	{
		/// The `BrowserPath` of the item to delete.
		BrowserPath* browserPath;
		/// If set, deletion will stop if the corresponding node has a negative mark.
		bool obeyMarks;
	}
	Item[] items;

	void prepare(Item[] items)
	{
		assert(this.state == State.none);
		this.items = items;
		this.current = items.length ? items[0].browserPath.toFilesystemPath.to!string : null;
		this.state = State.ready;
	}

	void cancel()
	{
		assert(this.state == State.ready);
		this.state = State.none;
	}

	void start()
	{
		assert(this.state == State.ready);
		this.stopping = false;
		this.subvolumeResume.initialize(false, false);
		this.thread = new Thread(&threadFunc);
		this.state = State.progress;
		this.thread.start();
	}

	private void threadFunc()
	{
		foreach (item; items)
		{
			auto fsPath = item.browserPath.toFilesystemPath.to!string;
			assert(fsPath && fsPath.isAbsolute);

			ulong initialDeviceID;
			listDir!((
				// The directory entry
				e,
				// Only true when `e` is the root (`item.fsPath`)
				bool root,
				// The corresponding parent `BrowserPath`, if we are to obey marks
				BrowserPath* parentBrowserPath,
				// We will set this to false if we don't fully clear out this directory
				bool* unlinkOK,
			) {
				auto entryBrowserPath =
					root ? parentBrowserPath :
					parentBrowserPath ? parentBrowserPath.appendName!true(e.baseNameFS)
					: null;
				if (entryBrowserPath && entryBrowserPath.mark == Mark.unmarked)
				{
					if (unlinkOK) *unlinkOK = false;
					return;
				}

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

				bool entryUnlinkOK = true;
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

						bool haveNegativeMarks = false;
						if (entryBrowserPath)
							entryBrowserPath.enumerateMarks((_, bool isMarked) { if (!isMarked) haveNegativeMarks = true; });
						if (!haveNegativeMarks) // Can't delete subvolume if the user excluded some items inside it.
						{
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
					}

					e.recurse(false, entryBrowserPath, &entryUnlinkOK);
				}

				if (entryUnlinkOK)
				{
					int ret = unlinkat(e.dirFD, e.baseNameFSPtr,
						e.entryIsDir ? AT_REMOVEDIR : 0);
					errnoEnforce(ret == 0, "unlinkat failed");
				}
				if (unlinkOK) *unlinkOK &= entryUnlinkOK;
			}, Yes.includeRoot)(
				fsPath,
				true,
				item.obeyMarks ? item.browserPath : null,
				null,
			);
		}
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
