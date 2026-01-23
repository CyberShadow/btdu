/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2024  Vladimir Panteleev <btdu@cy.md>
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

/// Sample subprocess protocol messages.
/// Communication is subprocess -> main process only.
module btdu.sample.proto;

import core.sys.posix.unistd;

import std.meta;

import ae.utils.array : asBytes;

import btrfs.c.ioctl : btrfs_ioctl_dev_info_args, btrfs_ioctl_fs_info_args;
import btrfs.c.kerncompat : u64, __u64;

import btdu.proto : Header, sendBuf, serialize, sendRaw;

struct Error
{
	const(char)[] msg;
	int errno;
	const(char)[] path;
}

struct StartMessage
{
	ulong totalSize;
	typeof(btrfs_ioctl_fs_info_args.fsid) fsid;
	btrfs_ioctl_dev_info_args[] devices;
}

struct NewRootMessage
{
	__u64 rootID, parentRootID;
	const(char)[] name;
	uint generation;
	/// Creation time (seconds since epoch), or 0 if unknown
	long otime;
	/// True if subvolume is read-only (typically a snapshot)
	bool isReadOnly;
}

struct Offset
{
	ulong logical = -1;
	ulong devID = -1, physical = -1;
}

/// Used for Offset.logical to represent unallocated space in physical mode.
enum u64 logicalOffsetHole = -1;

/// Used for Offset.logical to represent device slack.
enum u64 logicalOffsetSlack = -2;

struct ResultStartMessage
{
	ulong chunkFlags;
	Offset offset;
	ulong sampleIndex;  /// 0-based index in [0, totalSize), uniformly sampled
	uint generation;    /// Generation counter for cache invalidation
}

// Retrying with BTRFS_LOGICAL_INO_ARGS_IGNORE_OFFSET
struct ResultIgnoringOffsetMessage
{
}

struct ResultInodeStartMessage
{
	u64 rootID;
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
	ResultIgnoringOffsetMessage,
	ResultInodeStartMessage,
	ResultInodeErrorMessage,
	ResultInodeEndMessage,
	ResultMessage,
	ResultErrorMessage,
	ResultEndMessage,
	FatalErrorMessage,
);


/// Send a message from subprocess to main process via stdout.
void send(T)(auto ref T message)
if (staticIndexOf!(T, AllMessages) >= 0)
{
	Header header;
	header.type = staticIndexOf!(T, AllMessages);
	sendBuf.clear();
	serialize(message);
	header.length = Header.sizeof + sendBuf.length;
	sendRaw(STDOUT_FILENO, header.asBytes);
	sendRaw(STDOUT_FILENO, sendBuf.peek());
}
