btdu - sampling disk usage profiler for btrfs
=============================================

<img align="right" src="https://dump.cy.md/785891939a5d3d004c0e9e5e7ded5acd/19%3A02%3A24-upload.png">

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


License
-------

`btdu` is available under the [GNU GPL v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html). (The license is inherited from btrfs-progs.)


See Also
--------

* [btsdu](https://github.com/rkapl/btsdu), the Btrfs Snapshot Disk Usage Analyzer
