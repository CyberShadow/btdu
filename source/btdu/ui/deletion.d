/*
 * Copyright (C) 2023, 2024, 2026  Vladimir Panteleev <btdu@cy.md>
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
	enum Status
	{
		none,
		ready, // confirmation
		progress,
		success,
		error,
		subvolumeConfirm,
		subvolumeProgress,
	}

	struct State
	{
		Status status;
		string current, error;
		bool stopping;
	}
	private State state;

	Thread thread;
	Event subvolumeResume;

	State getState()
	{
		if (thread)
			synchronized (this.thread)
				return state;
		else
			return state;
	}

	@property bool needRefresh()
	{
		return this.state.status.among(Status.progress, Status.subvolumeProgress, Status.subvolumeConfirm) != 0;
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
		assert(this.state.status == Status.none);

		this.items = items;
		this.state.current = items.length ? items[0].browserPath.toFilesystemPath.to!string : null;
		this.state.status = Status.ready;
	}

	void cancel()
	{
		assert(this.state.status == Status.ready);
		this.state.status = Status.none;
	}

	void start()
	{
		assert(this.state.status == Status.ready);
		this.state.stopping = false;
		this.state.status = Status.progress;
		this.subvolumeResume.initialize(false, false);
		this.thread = new Thread(&threadFunc);
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
					this.state.current = e.fullName;

				if (this.state.stopping)
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
							this.state.status = Status.subvolumeConfirm;
							this.subvolumeResume.wait();
							if (this.state.stopping)
								throw new Exception("User abort");

							auto fd = openat(e.dirFD, e.baseNameFSPtr, O_RDONLY);
							errnoEnforce(fd >= 0, "openat");
							auto subvolumeID = getSubvolumeID(fd);
							deleteSubvolume(fd, subvolumeID);

							this.state.status = Status.progress;
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
		assert(this.state.status == Status.subvolumeConfirm);
		if (proceed)
			this.state.status = Status.subvolumeProgress;
		else
		{
			this.state.stopping = true;
			this.state.status = Status.progress;
		}
		this.subvolumeResume.set();
	}

	void stop()
	{
		this.state.stopping = true;
	}

	void finish()
	{
		assert(this.state.status.among(Status.success, Status.error));
		this.state.status = Status.none;
	}

	void update()
	{
		if (this.state.status.among(Status.progress, Status.subvolumeProgress) && !this.thread.isRunning())
		{
			try
			{
				this.thread.join();

				// Success:
				this.state.status = Status.success;
			}
			catch (Exception e)
			{
				// Failure:
				this.state.error = e.msg;
				this.state.status = Status.error;
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
