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

- **Understand btrfs space usage**

  btdu shows explanations for hierarchy objects and common errors, which can help understand how btrfs uses disk space. The `--expert` mode enables collection and display of [additional size metrics](CONCEPTS.md#size-metrics), providing more insight into allocation of objects with non-trivial sharing.


Installation
------------

<a href="https://repology.org/project/btdu/versions"><img align="right" src="https://repology.org/badge/vertical-allrepos/btdu.svg" alt="Packaging status" title="Packaging status"></a>

btdu can be installed in one of the following ways:

- Via package manager, if it is packaged by your distribution (see on the right).
- Download a static binary from [the releases page](https://github.com/CyberShadow/btdu/releases)
  or [the latest CI run](https://github.com/CyberShadow/btdu/actions?query=branch%3Amaster).
- Clone this repository and build from source (see below).


Building
--------

- Install [a D compiler](https://dlang.org/download.html).  
  Note that you will need a compiler supporting D v2.097 or newer - the compiler in your distribution's repositories might be too old.
- Install [Dub](https://github.com/dlang/dub), if it wasn't included with your D compiler.
- Install libncursesw5-dev, or your distribution's equivalent.
- Run `dub build -b release`


Usage
-----

    # btdu /path/to/filesystem/root

Note that the indicated path must be to the root subvolume (otherwise btdu will be unable to open other subvolumes for inode resolution). If in doubt, mount the filesystem to a new mountpoint with `-o subvol=/,subvolid=5`.

You can start browsing the results instantly; btdu will keep collecting samples to improve accuracy until it is stopped by quitting or pausing (which you can do by pressing <kbd>p</kbd>).

Run `btdu --help` for more usage information.

See [CONCEPTS.md](CONCEPTS.md) for information about some btdu / btrfs concepts, such as represented / exclusive / shared size.

### Headless mode

With the `--headless` switch, btdu will run without the user interface. This is useful together with the `--export` option, which saves results to a file that can later be viewed in the UI using the `--import` option. For automated invocations, don't forget to specify a stop condition such as `--max-time`.

### Deleting

You can delete the selected file or directory from the filesystem by pressing <kbd>d</kbd> <kbd>Y</kbd>. This will recursively delete the file or directory shown as "Full path".

Deleting files during a btdu run (whether via btdu or not) skews the results, though when deleting files from btdu, it will make a best-effort attempt to adjust the results to match. Statistics such as exclusive size may be inaccurate. Re-run btdu to obtain fresh results.

License
-------

`btdu` is available under the [GNU GPL v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html). (The license is inherited from btrfs-progs.)


See Also
--------

* [btsdu](https://github.com/rkapl/btsdu), the Btrfs Snapshot Disk Usage Analyzer
