Concepts
========

Sample size
-----------

One sample is one logical offset chosen at random by btdu. Because we know the total size of the filesystem, we can divide this size by the total number of samples to obtain the approximate size of how much data one sample represents. (This size is also shown at the bottom as "Resolution".)

Representative location
-----------------------

After picking a logical offset to sample, btdu asks btrfs what is located at that offset. btrfs replies with zero or more locations.
Out of these locations, btdu picks one location where it should place the sample within its tree, to *represent* the space occupied by this data. We call this location the *representative* location.

The way in which btdu selects the representative location aims to prefer better visualization of what the data is used for, i.e., the simplest explanation for what is using this disk space. For instance, if one location's filesystem path is longer than the other, then the shorter is chosen, as the longer is more likely to point at a snapshot or other redundant clone of the shorter one.

Examples:

- For data which is used exactly once, the representative location will be the path to the file which references that data.
- For data which is used in `/@root/file.txt` and `/@root-20210203/file.txt`, the representative location will be `/@root/file.txt`, because it is shorter.
- For data which is used in `/@root/file1.txt` and `/@root/file2.txt`, the representative location will be `/@root/file1.txt`, because it is lexicographically smaller.

Size metrics
------------

btdu shows three size metrics for tree nodes:

- **Represented** size
  - The represented size of a node is the amount of disk space that this path is *representing*.
    - For every logical offset, btdu picks one [representative location](#representative-location) out of all locations that reference that logical offset, and assigns the sample's respective disk space usage to that location. 
    - This location is thus chosen to *represent* this disk space. So, if a directory's represented size is 1MiB, we can say that this directory is the simplest explanation for what is using that 1MiB of space.
  - This metric is most useful in understanding what is using up disk space on a btrfs filesystem, and is what's shown in the btdu directory listings.
  - Adding up the represented size for all filesystem objects (btdu tree leaves) adds up to the total size of the filesystem.

- **Exclusive** size
  - The exclusive size represents the samples which are used *only* by the file at this location.
  - Two files which are perfect clones of each other will thus both have an exclusive size of zero. The same applies to two identical snapshots.

- **Shared** size
  - The shared size is the total size including all references of a single logical offset at this location.
  - This size generally correlates with the "visible" size, i.e. the size reported by classic space usage analysis tools, such as `du`. (However, if compression is used, the shown size will still be after compression.)
  - The total shared size will likely exceed the total size of the filesystem, if snapshots or reflinking is used.

As an illustration, consider a file consisting of unique data (`dd if=/dev/urandom of=a bs=1M count=1`):

![](https://raw.githubusercontent.com/gist/CyberShadow/6b6ecfde854ec7d991f8774bc35bbce5/raw/64ba6d41fb637f03e6aabfe849f5f2689385652c/single.svg)

Here is what happens if we clone the file (`cp --reflink=always a b`):

![](https://raw.githubusercontent.com/gist/CyberShadow/6b6ecfde854ec7d991f8774bc35bbce5/raw/64ba6d41fb637f03e6aabfe849f5f2689385652c/clone.svg)

Finally, here is what the sizes would look like for two 2M files which share 1M. Note how the represented size adds up to 3M, the total size of the underlying data.

![](https://raw.githubusercontent.com/gist/CyberShadow/6b6ecfde854ec7d991f8774bc35bbce5/raw/64ba6d41fb637f03e6aabfe849f5f2689385652c/overlap.svg)

The sizes for directories are the sum of sizes of their children.

