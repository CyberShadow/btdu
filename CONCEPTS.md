Concepts
========

Sample size
-----------

One sample is one logical offset chosen at random by btdu. Because we know the total size of the filesystem, we can divide this size by the total number of samples to obtain the approximate size of how much data one sample represents. (This size is also shown at the bottom as "Resolution".)

Confidence
----------

For the represented and exclusive size, btdu displays a confidence range, e.g.:

    - Represented size: ~763.0 GiB (6006 samples), ±16.9 GiB

This should be interpreted as: given the data btdu collected so far, it is [confident with 95% certainty](https://en.wikipedia.org/wiki/Confidence_interval) that the object size is within 16.9 GiB of 763.0 GiB.

In the file browser, the confidence range is visually represented in the size graph using question marks.

Logical vs. physical space
--------------------------

Quoting [On-disk format](https://btrfs.wiki.kernel.org/index.php/On-disk_Format):

> Btrfs makes a distinction between logical and physical addresses. Logical addresses are used in the filesystem structures, while physical addresses are simply byte offsets on a disk. One logical address may correspond to physical addresses on any number of disks, depending on RAID settings.

In this regard, btdu has two modes of operation:

- In logical space mode, btdu samples the logical offset space. As such, a 1GB file (containing unique uncompressed unshared data) will show up with a size of 1GB, regardless of whether it is stored in a SINGLE, DUP, or RAID1 profile block group.
- In physical space mode, btdu samples offsets from the underlying block devices, translating each to a logical offset first. The file in the example above will thus show up with a size of 2GB if it is stored on a block group using the RAID1 or DUP profiles.

In physical space mode, btdu will also show unallocated space (represented as an `<UNALLOCATED>` node in the hierarchy root) and any device slack (represented as a `<SLACK>` node).

Logical space mode is the default. To use physical space mode, run btdu with `--physical` (`-p`).

Representative location
-----------------------

After picking a logical offset to sample, btdu asks btrfs what is located at that offset. btrfs replies with zero or more locations.
Out of these locations, btdu picks one location where it should place the sample within its tree, to *represent* the space occupied by this data. We call this location the *representative* location.

The way in which btdu selects the representative location aims to prefer better visualization of what the data is used for, i.e., the simplest explanation for what is using this disk space.
For this purpose, when a sample is shared by multiple locations, their creation time is queried and the sample is allocated to the youngest location.

The full order in which the selection criteria are applied is as follows:

1. **Subvolume type**: Read-write subvolumes are preferred over read-only subvolumes (snapshots) by default.

2. **Creation time**: Among paths with the same read-only status, the newer one (later creation time) is preferred by default. This shows data under the most recent location that references it.

3. **Path length**: Shorter paths are preferred over longer ones, as they are more likely to be the simplest explanation for what is using this disk space.

4. **Lexicographic order**: When paths have equal length, the lexicographically smaller path is chosen.

The subvolume type and creation time criteria are evaluated at the first point where two paths diverge. For subvolumes at the divergence point, btdu uses the subvolume's creation time (otime) and read-only status. For regular directories, btdu uses the directory's birthtime (if available).

Examples:

- For data which is used exactly once, the representative location will be the path to the file which references that data.
- For data shared between `/@root/file.txt` (read-write) and `/@root-20210203/file.txt` (read-only snapshot), the representative location will be `/@root/file.txt`, because read-write subvolumes are preferred.
- For data shared between two read-only snapshots `/@snap-2021/file.txt` and `/@snap-2022/file.txt`, the representative location will be `/@snap-2022/file.txt`, because it is newer.
- For data which is used in `/@root/file1.txt` and `/@root/file2.txt` (same subvolume), the representative location will be `/@root/file1.txt`, because it is lexicographically smaller.
- For data shared between `/@subvol/dir-2023/file.txt` and `/@subvol/dir-2024/file.txt` (same subvolume, different directories), the representative location will be `/@subvol/dir-2024/file.txt` if `dir-2024` was created after `dir-2023`.

These rules can be overridden by selecting a node and pressing <kbd>⇧ Shift</kbd><kbd>P</kbd> to prefer this node when selecting a representative location, or <kbd>⇧ Shift</kbd><kbd>I</kbd> to avoid it. On the command line, you can use the `--prefer` and `--ignore` options, which accept absolute filesystem paths with shell-like pattern syntax (understanding `?`, `*`, `**`, `[a-z]`, `{this,that}`).

The temporal criteria can be reversed using `--chronological` on the command line, or by pressing <kbd>⇧ Shift</kbd><kbd>C</kbd> interactively. This changes how snapshot sizes are interpreted:

- **Reverse-chronological** (default): Each snapshot's size represents data which was last referenced by that snapshot, i.e. data that would be freed if you deleted that snapshot, after also deleting all older snapshots.

- **Chronological**: Each snapshot's size represents the "new" data that first appeared in that snapshot. This gives a chronological view of when disk space was consumed, useful for tracking down where data originally came from.

Size metrics
------------

In `--expert` mode, btdu shows four size metrics for tree nodes:

- **Represented** size
  - The represented size of a node is the amount of disk space that this path is *representing*.
    - For every logical offset, btdu picks one [representative location](#representative-location) out of all locations that reference that logical offset, and assigns the sample's respective disk space usage to that location. 
    - This location is thus chosen to *represent* this disk space. So, if a directory's represented size is 1MiB, we can say that this directory is the simplest explanation for what is using that 1MiB of space.
  - This metric is most useful in understanding what is using up disk space on a btrfs filesystem, and is what's shown in the btdu directory listings.
  - The represented size of a directory is the sum of represented sizes of its children.
  - Adding up the represented size for all filesystem objects (btdu tree leaves) adds up to the total size of the filesystem.

- **Distributed** size
  - To calculate the distributed size, btdu evenly *distributes* a sample's respective disk space usage across all locations which reference data from that logical offset.
  - Thus, two 1MiB files which share the same 1MiB of data will each have a distributed size of 512KiB.
  - The distributed size of a directory is the sum of distributed sizes of its children.
  - Adding up the distributed size for all filesystem objects (btdu tree leaves) also adds up to the total size of the filesystem.

- **Exclusive** size
  - The exclusive size represents the samples which are used *only* by this file or directory.
    - Specifically, btdu awards exclusive size to the *common prefix* of all paths which reference data from a given logical offset.
  - Two files which are perfect clones of each other will thus both have an exclusive size of zero. The same applies to two identical snapshots.
  - However, if the two clones are in the same directory, and the data is not used anywhere else, then that data will be represented in the directory's exclusive size.
  - The exclusive size can also be described as the amount of space which would be freed if the corresponding object were to be deleted.
  - Unlike other size metrics, adding up the exclusive size of all items in a directory may not necessarily add up to the exclusive size of the directory.

- **Shared** size
  - The shared size is the total size including all references of a single logical offset at this location.
  - This size generally correlates with the "visible" size, i.e. the size reported by classic space usage analysis tools, such as `du`. (However, if compression is used, the shown size will still be after compression.)
  - The shared size of a directory is the sum of shared sizes of its children.
  - The total shared size will likely exceed the total size of the filesystem, if snapshots or reflinking is used.

As an illustration, consider a file consisting of unique data (`dd if=/dev/urandom of=a bs=1M count=1`):

![](https://raw.githubusercontent.com/gist/CyberShadow/6b6ecfde854ec7d991f8774bc35bbce5/raw/2246dafb074b466c89f9cf3f7a62cd88a44b74e4/single.svg)

Here is what happens if we clone the file (`cp --reflink=always a b`):

![](https://raw.githubusercontent.com/gist/CyberShadow/6b6ecfde854ec7d991f8774bc35bbce5/raw/2246dafb074b466c89f9cf3f7a62cd88a44b74e4/clone.svg)

Finally, here is what the sizes would look like for two 2M files which share 1M. Note how the represented size adds up to 3M, the total size of the underlying data.

![](https://raw.githubusercontent.com/gist/CyberShadow/6b6ecfde854ec7d991f8774bc35bbce5/raw/2246dafb074b466c89f9cf3f7a62cd88a44b74e4/overlap.svg)
