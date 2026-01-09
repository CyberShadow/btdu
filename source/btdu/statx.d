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

/// Bindings for the Linux statx syscall (available since kernel 4.11)
module btdu.statx;

extern(C) int statx(int dirfd, const char* pathname, int flags, uint mask, statx_t* statxbuf) nothrow @nogc;

enum AT_FDCWD = -100;
enum AT_SYMLINK_NOFOLLOW = 0x100;
enum STATX_BTIME = 0x00000800;

struct statx_timestamp_t
{
    long tv_sec;
    uint tv_nsec;
    int __reserved;
}

struct statx_t
{
    uint stx_mask;
    uint stx_blksize;
    ulong stx_attributes;
    uint stx_nlink;
    uint stx_uid;
    uint stx_gid;
    ushort stx_mode;
    ushort __spare0;
    ulong stx_ino;
    ulong stx_size;
    ulong stx_blocks;
    ulong stx_attributes_mask;
    statx_timestamp_t stx_atime;
    statx_timestamp_t stx_btime;
    statx_timestamp_t stx_ctime;
    statx_timestamp_t stx_mtime;
    uint stx_rdev_major;
    uint stx_rdev_minor;
    uint stx_dev_major;
    uint stx_dev_minor;
    ulong stx_mnt_id;
    ulong __spare2;
    ulong[12] __spare3;
}
