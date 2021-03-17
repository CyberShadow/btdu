## Overview

btdu collects data using sub-processes. 
Each subprocess is started with its own random sub-seed, which then prints results to its standard output. 
The main process collects data from subprocesses, and arranges it into a tree.

## Source layout

- `browser.d` - The ncurses-based user interface.
- `common.d` - Small module with common definitions.
- `main.d` - Entry point and event loop.
- `paths.d` - Implements a trie for efficiently storing paths and associated hierarchical data.
- `proto.d` - Describes the protocol used between the main process and subprocesses.
- `sample.d` - The main loop for subprocesses. Performs sample acquisition.
- `state.d` - Global variables.
- `subproc.d` - Code to manage subprocesses from the main process.

## Design decisions

Here are a few potential questions about decisions made when writing btdu, which have possibly non-obvious answers.

### Why copy ncdu's UI?

Many users who would like to use btdu have probably already used ncdu. Mimicking a familiar user interface allows the users to be immediately productive in the new software. Since btdu aims to be a tool which solves problems, as opposed to creating them, removing the obstacle of learning a new user interface was seen as a non-negligible benefit.

### Why sub-processes and not threads?

To collect data, btdu issues ioctls to the kernel. These ioctls can take a very long time to execute, and are non-interruptible. The main reason why this becomes an issue is that D's garbage collector, which operates according to a stop-the-world model, needs to suspend all threads for it to scan reachable objects. Threads executing ioctls can only be "suspended" once the ioctl finishes - even though no userspace code is executed during the ioctl, the signal is still processed only after the ioctl returns. This means that a GC cycle will last for as long as the longest ioctl, which can take up to a few seconds. As the UI is not redrawn or can process keyboard input during this time, this would make it unpleasantly unresponsive.

There are some other, similar but less obvious reasons, such as allowing the user to instantly exit back to the shell even though an ioctl would otherwise need to take a few more seconds to finish.

### Why random samples and not some even / predictable order?

Given the use of multiple subprocesses which collect data in parallel, there's two general approaches that this could be done:

1. Divide the volume into some predefined sections, one per subprocess, and dedicate each section to a subprocess. The subprocess then autonomously picks samples within its section using whatever deterministic algorithm.

2. Have the main process decide on the order of samples to query, and dispatch these samples in order to subprocesses as they report that they are idle and ready to do more work.

The problem with the first approach is that the time it takes to resolve a sample varies. Consider the simple hypothetical scenario where the first half of the disk is twice as fast as the second half of the disk. Then, with two subprocesses, the subprocess responsible for the first half of the disk could collect 200 samples in the time that the other subprocess would collect only 100. If the samples were treated equally, this would thus create the false impression that the first half of the disk contains two thirds of the data, instead of just half.

Though btdu could do this and compensate by scaling the weight of the samples by the time it took to resolve them, this introduces two orders of inaccuracy and causes the results to be further skewed by temporary effects such as disk cache.

The second approach listed above does avoid this problem. However, its implementation requires more elaborate communication with subprocesses - currently, subprocesses do not read any data from the parent process at all.

### How does using a random uniform distribution avoid the problem caused by variable sample resolution duration above?

Let's consider a hypothetical extreme scenario where samples in the first half of the disk take 1 millisecond to resolve, but 10 milliseconds in the second half. For illustration, we'll use 1000 worker processes.

What will happen is that, even though the total number of samples collected in the first half will initially be higher, every time as workers assigned to the first half quickly finish their work, half of them will get assigned to the second half. Thus, all workers will quickly get "clammed up" and assigned to the slow second half. This process repeats as the workers in the second half finish resolving. Most importantly, the difference in the total number of samples remains the same, even as the total number of samples grows:

| Elapsed ms | Busy workers,<br>1st half | Busy workers,<br>2nd half | Total samples,<br>1st half | Total samples,<br>2nd half |
| ---------- | ------------------------- | ------------------------- | -------------------------- | -------------------------- |
| 0 | 500 | 500 | 0 | 0 |
| 1 | 250 | 750 | 500 | 0 |
| 2 | 125 | 875 | 750 | 0 |
| 3 | 63 | 938 | 875 | 0 |
| 4 | 31 | 969 | 938 | 0 |
| 5 | 16 | 984 | 969 | 0 |
| 6 | 8 | 992 | 984 | 0 |
| 7 | 4 | 996 | 992 | 0 |
| 8 | 2 | 998 | 996 | 0 |
| 9 | 1 | 999 | 998 | 0 |
| 10 | 250 | 750 | 999 | 500 |
| 11 | 250 | 750 | 1250 | 750 |
| 12 | 188 | 812 | 1500 | 875 |
| 13 | 125 | 875 | 1687 | 938 |
| 14 | 78 | 922 | 1812 | 969 |
| 15 | 47 | 953 | 1891 | 984 |
| 16 | 27 | 973 | 1937 | 992 |
| 17 | 16 | 984 | 1965 | 996 |
| 18 | 9 | 991 | 1980 | 998 |
| 19 | 5 | 995 | 1989 | 999 |
| 20 | 128 | 872 | 1994 | 1250 |
| 21 | 189 | 811 | 2122 | 1500 |
| 22 | 188 | 812 | 2311 | 1687 |
| 23 | 157 | 843 | 2499 | 1812 |
| 24 | 117 | 883 | 2656 | 1891 |
| 25 | 82 | 918 | 2773 | 1937 |
| ... | ... | ... | ... | ... |
| 100 | 94 | 906 | 9482 | 8671 |
| ... | ... | ... | ... | ... |
| 500 | 91 | 909 | 45826 | 45008 |
| ... | ... | ... | ... | ... |
| 1000 | 91 | 909 | 91281 | 90463 |

As you can see, the ratio for the total number of samples still converges towards 50%.

### Why use the same random seed by default?

Using a fixed seed instead of an unique (unpredictable) seed enables the following workflow:

- Run btdu to collect initial information about disk usage.
- Quit btdu, and delete the biggest space hog (e.g. a batch of old snapshots).
- Re-run btdu to acquire fresh results.

Because the metadata that btdu accessed will now be in the operating system's cache, the second invocation is likely to be much faster, and it will quickly "fast-forward" to the point where the first invocation stopped.
