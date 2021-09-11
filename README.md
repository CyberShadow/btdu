btdu - sampling disk usage profiler for btrfs
=============================================

<img align="right" src="https://dump.cy.md/a8e2054ffc05bc120b390e48c6d4e43d/19%3A02%3A24-upload.png">

Some [btrfs](https://btrfs.wiki.kernel.org/) features may make it difficult to estimate what disk space is being used for:

- **Subvolumes** allow cheap copy-on-write snapshots of entire filesystem trees, with data that hasn't been modified being shared among snapshots
- **File and extent cloning** allow creating cheap copies of files or parts thereof, with extents being stored only once
- **Compression** transparently allows further reducing disk usage

For these reasons, classic disk usage analyzers such as [ncdu](https://dev.yorhel.nl/ncdu) cannot provide an accurate depiction of actual disk usage. (btrfs compression in particular is challenging to classic analyzers, and [special tools](https://github.com/kilobyte/compsize) must be used to query compressed usage.)

**btdu** is a sampling disk usage profiler for btrfs. It works according to the following algorithm:

1. Pick a random point on the disk in use
2. Find what is located at that point
3. Add the path to the results
4. Repeat the above steps indefinitely

Though it works by taking random samples, it is "eventually" accurate.

It differs from classic analyzers through the following properties:

- btdu starts showing results instantly. Though wildly inaccurate at first, they become progressively more accurate the longer btdu is allowed to run.
- btdu analyzes entire filesystems only. There is no way to analyze only a particular subdirectory or subvolume.
- btdu counts extents used by multiple files only once. (The shortest path is used when placing the sample in the tree for visualization.)
- By nature of its algorithm, btdu works correctly with compression and other btrfs filesystem features.
- Because it queries raw filesystem metadata, btdu requires root privileges to run.


Use cases
---------

- **Quickly summarize space usage**

  btdu needs to collect only 100 samples to achieve a ~1% resolution, which means it can identify space hogs very quickly. This is useful if the disk is full and some space must be freed ASAP to get things back up and running.

- **Estimate snapshot size**

  When an extent is in use by multiple files or snapshots, to decide where to place it in the browsable tree, btdu picks the path with the shortest length, or the lexicographically smaller path if the length is the same. An emergent effect of this property is that it can be used to estimate snapshot size, if your snapshots use a fixed-length lexicographically-ordered naming scheme (such as e.g. YYYY-MM-DD-HH-MM-SS): the size of snapshots displayed in btdu will thus indicate data that occurs in that snapshot or any later one, i.e. the amount of "new" data in that snapshot.

- **Estimate compressed data size**

  If you use btrfs data compression (whether to save space / improve performance / conserve flash writes), btdu can be used to estimate how much real disk space compressed data uses.

- **Estimate unreachable extent size**

  A feature unique to btdu is the ability to estimate the amount of space used by unreachable parts of extents, i.e. data in extents containing older versions of file content which has since been overwritten. This btrfs "dark matter" can be an easy to overlook space hog, which could be eliminated by rewriting or defragmentating affected files.


Installation
------------

btdu can be installed in one of the following ways:

- An [AUR package is available](https://aur.archlinux.org/packages/btdu) for Arch Linux and derivatives.
- Download a static binary from [the releases page](https://github.com/CyberShadow/btdu/releases).
- Clone this repository and build from source (see below).


Building
--------

- Install [a D compiler](https://dlang.org/download.html)
- Install [Dub](https://github.com/dlang/dub), if it wasn't included with your D compiler
- Run `dub build -b release`


Usage
-----

    # btdu /path/to/filesystem/root

Note that the indicated path must be to the root subvolume (otherwise btdu will be unable to open other subvolumes for inode resolution). If in doubt, mount the filesystem to a new mountpoint with `-o subvol=/,subvolid=5`.

Run `btdu --help` for more usage information.


### Size metrics

btdu shows three size metrics for items:

- **Canonical** size
  - After picking a logical offset to sample, btdu asks btrfs what is located at that offset. btrfs replies with zero or more locations.
    Out of these locations, btdu must pick one location where it should place the sample within its tree. (It does so by generally picking the shortest path.)
  - The canonical size is thus the size of samples whose canonical location matches the currently viewed item.
  - This metric is most useful in understanding what is using up disk space on a btrfs filesystem.
  - Adding up the canonical size for all filesystem objects (btdu tree leaves) adds up to the total size of the filesystem.

- **Exclusive** size
  - The exclusive size represents the samples which are used *only* by the file at this location.
  - Two files which are perfect clones of each other will thus both have an exclusive size of zero. The same applies to two identical snapshots.

- **Shared** size
  - The shared size is the total size including all occurrences of a single logical offset at this location.
  - This size generally correlates with the "visible" size, i.e. the size reported by classic space usage analysis tools, such as `du`.
  - The total shared size will likely exceed the total size of the filesystem, if snapshots or reflinking is used.

As an illustration, consider a file consisting of unique data (`dd if=/dev/urandom of=a bs=1M count=1`):

| File | Canonical | Exclusive | Shared |
|------|----------:|----------:|-------:|
| a    |        1M |        1M |     1M |

Here is what happens if we clone the file (`cp --reflink=always a b`):

| File | Canonical | Exclusive | Shared |
|------|----------:|----------:|-------:|
| a    |        1M |         0 |     1M |
| b    |        0  |         0 |     1M |

License
-------

`btdu` is available under the [GNU GPL v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html). (The license is inherited from btrfs-progs.)


See Also
--------

* [btsdu](https://github.com/rkapl/btsdu), the Btrfs Snapshot Disk Usage Analyzer
