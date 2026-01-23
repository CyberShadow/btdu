/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2025, 2026  Vladimir Panteleev <btdu@cy.md>
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

/// btdu entry point
module btdu.main;

import core.runtime : Runtime;
import core.time;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.conv : ConvException, to;
import std.exception;
import std.parallelism : totalCPUs;
import std.path;
import std.random;
import std.socket;
import std.stdio : stdin, stdout, stderr;
import std.string;
import std.typecons;

import ae.sys.file : getMounts, getPathMountInfo, MountInfo;
import ae.sys.shutdown;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.time.parsedur;
import ae.utils.typecons : require;

import btdu.ui.browser;
import btdu.common;
import btdu.impexp : ExportFormat, importData, importCompareData, exportData, guessExportFormat, exportExtensions;
import btdu.paths;
import btdu.sample.process;
import btdu.sample.subproc;
import btdu.state;

@(`Sampling disk usage profiler for btrfs.`)
@Version("btdu v" ~ btduVersion)
void program(
	Parameter!(string, "Path to the root of the filesystem to analyze") path,
	Option!(uint, "Number of sampling subprocesses\n (default is number of logical CPUs for this system)", "N", 'j') procs = 0,
	Option!(Seed, "Random seed used to choose samples") seed = 0,
	Option!(ProcessType, hiddenOption, "TYPE", '\0', "process-type") processType = ProcessType.main,
	Switch!("Measure physical space (instead of logical).", 'p') physical = false,
	Switch!("Expert mode: collect and show additional metrics.\nUses more memory.", 'x') expert = false,
	Switch!hiddenOption man = false,
	Option!(string, "Set UI refresh interval.\nSpecify 0 to refresh as fast as possible.", "DURATION", 'i', "interval") refreshIntervalStr = null,
	Switch!("Run without launching the result browser UI.") headless = false,
	Option!(string, "Stop after collecting N samples.", "N", 'n') maxSamples = null,
	Option!(string, "Stop after running for this duration.", "DURATION") maxTime = null,
	Option!(string, `Stop after achieving this resolution (e.g. "1MB" or "1%").`, "SIZE") minResolution = null,
	Switch!hiddenOption exitOnLimit = false,
	Switch!hiddenOption waitForSubprocesses = false,
	Option!(string, "On exit, export the collected results to the given file.", "PATH", 'o', "export") exportPath = null,
	Option!(string, "Export format (guessed from extension if not specified).", "FORMAT", 'F', "export-format") exportFormatStr = null,
	Switch!("When exporting, include 'seenAs' data showing shared paths.") exportSeenAs = false,
	Option!(string[], "Prioritize allocating representative samples in the given path.", "PATTERN") prefer = null,
	Option!(string[], "Deprioritize allocating representative samples in the given path.", "PATTERN") ignore = null,
	Switch!("On exit, export represented size estimates in 'du' format to standard output.") du = false,
	Switch!("Instead of analyzing a btrfs filesystem, read previously collected results saved with --export from PATH.", 'f', "import") doImport = false,
	Option!(string, "Compare against a baseline from a previously exported file.", "PATH", 'c', "compare") comparePath = null,
	Switch!("Auto-mount top-level subvolume if needed.", 'A', "auto-mount") autoMount = false,
	Switch!("Prefer older paths as representative.") chronological = false,
)
{
	if (exportFormatStr && !exportPath)
		throw new Exception("--export-format requires --export to be specified");

	if (autoMount && (prefer.length || ignore.length))
		throw new Exception("--prefer and --ignore options are not available with --auto-mount");

	if (man)
	{
		stdout.write(generateManPage!program(
			"btdu",
			".B btdu
is a sampling disk usage profiler for btrfs.

For a detailed description, please see the full documentation:

.I https://github.com/CyberShadow/btdu#readme",
			null,
			`.SH BUGS
Please report defects and enhancement requests to the GitHub issue tracker:

.I https://github.com/CyberShadow/btdu/issues

.SH AUTHORS

\fBbtdu\fR is written by Vladimir Panteleev <btdu@c\fRy.m\fRd> and contributors:

.I https://github.com/CyberShadow/btdu/graphs/contributors
`,
		));
		return;
	}

	if (doImport)
	{
		if (procs || seed || processType != ProcessType.main || physical || maxSamples || maxTime || minResolution || prefer || ignore)
			throw new Exception("Conflicting command-line options");

		// Set expert mode from CLI before import.
		// For binary format: CLI controls view mode (data is always complete).
		// For JSON format: importJson will override this based on data availability.
		.expert = expert;
		.chronological = chronological;

		stderr.writeln("Loading results from file...");
		importData(path);
	}
	else
	{
		rndGen = Random(seed);
		fsPath = path.buildNormalizedPath;

		.expert = expert;
		.physical = physical;
		.exportSeenAs = exportSeenAs;
		.chronological = chronological;

		// TODO: respect CLI order (needs std.getopt and ae.utils.funopt changes)
		PathRule[] rules;
		rules ~= prefer.map!(p => PathRule(PathRule.Type.prefer, parsePathPattern(p, fsPath))).array;
		rules ~= ignore.map!(p => PathRule(PathRule.Type.ignore, parsePathPattern(p, fsPath))).array;
		.pathRules = rules;

		final switch (processType)
		{
			case ProcessType.sample:
				return subprocessMain(path, physical);
			case ProcessType.main:
				break;
		}

		checkBtrfs(fsPath, autoMount);

		if (procs == 0)
			procs = totalCPUs;

		subprocesses = new Subprocess[procs];
		foreach (ref subproc; subprocesses)
			subproc.start();
	}

	// Load comparison baseline if requested
	if (comparePath)
	{
		if (processType != ProcessType.main)
			throw new Exception("Cannot use --compare with subprocess mode");

		stderr.writeln("Loading comparison baseline...");
		importCompareData(comparePath);

		// Warn on mode mismatches
		if (doImport)
		{
			if (compareExpert != expert)
				stderr.writeln("Warning: Expert mode mismatch between files");
			if (comparePhysical != physical)
				stderr.writeln("Warning: Physical mode mismatch between files");
		}

		// Warn if comparing exports from different filesystems
		if (fsid != typeof(fsid).init && compareFsid != typeof(compareFsid).init && fsid != compareFsid)
		{
			import std.uuid : UUID;
			stderr.writefln("Warning: Filesystem UUID mismatch - comparing different filesystems");
			stderr.writefln("  Current:  %s", UUID(fsid));
			stderr.writefln("  Baseline: %s", UUID(compareFsid));
		}
	}

	Duration parsedMaxTime;
	if (maxTime)
		parsedMaxTime = parseDuration(maxTime);

	ulong parsedMaxSamples = ulong.max;  // ulong.max means no limit
	if (maxSamples)
		parsedMaxSamples = maxSamples.to!ulong;

	foreach (ref subproc; subprocesses)
		subproc.sampleLimit = &parsedMaxSamples;

	@property real parsedMinResolution()
	{
		static Nullable!real value;
		assert(minResolution && totalSize, "minResolution or totalSize is not set");
		return value.require({
			if (minResolution.value.endsWith("%"))
				return minResolution[0 .. $-1].to!real / 100 * totalSize;
			return parseSize(minResolution);
		}());
	}

	Browser browser;
	if (!headless)
	{
		browser.start();
		browser.update();
	}

	auto startTime = MonoTime.currTime();
	auto refreshInterval = 500.msecs;
	if (refreshIntervalStr)
		refreshInterval = parseDuration(refreshIntervalStr);
	auto nextRefresh = startTime;

	enum totalMaxDuration = 1.seconds / 60; // 60 FPS

	auto readSet = new SocketSet;
	auto exceptSet = new SocketSet;

	bool run = true;
	if (headless)
	{
		// In non-headless mode, ncurses takes care of this
		addShutdownHandler((reason) {
			run = false;
		});

		if (doImport)
			run = false;
	}

	// Main event loop
	while (run)
	{
		readSet.reset();
		exceptSet.reset();
		if (browser.curses.stdinSocket)
		{
			readSet.add(browser.curses.stdinSocket);
			exceptSet.add(browser.curses.stdinSocket);
		}
		if (!paused && !rebuildInProgress())
			foreach (ref subproc; subprocesses)
				readSet.add(subproc.socket);

		// Need a refresh now?
		bool busy = rebuildInProgress();
		// Need a refresh periodically?
		bool idle = !headless && browser.needRefresh();

		if (busy)
			Socket.select(readSet, null, exceptSet, Duration.zero);
		else
		if (idle)
			Socket.select(readSet, null, exceptSet, refreshInterval);
		else
			Socket.select(readSet, null, exceptSet);

		auto now = MonoTime.currTime();

		if (browser.curses.stdinSocket && browser.handleInput())
		{
			do {} while (browser.handleInput()); // Process all input
			if (browser.done)
				break;
			browser.update();
			nextRefresh = now + refreshInterval;
		}

		// Check limits before processing new samples
		if ((maxSamples
				&& browserRoot.getSamples(SampleType.represented) >= parsedMaxSamples) ||
			(maxTime
				&& now >= startTime + parsedMaxTime) ||
			(minResolution
				&& browserRoot.getSamples(SampleType.represented)
				&& totalSize
				&& (totalSize / browserRoot.getSamples(SampleType.represented)) <= parsedMinResolution))
		{
			if (headless || exitOnLimit)
				break;
			else
			{
				if (!paused)
				{
					browser.togglePause();
					browser.curses.beep();
					browser.update();
				}
				// Only pause once
				maxSamples = maxTime = minResolution = null;
				parsedMaxSamples = ulong.max;
			}
		}

		if (!paused && !rebuildInProgress()) // note, we must check rebuildInProgress() again here
		{
			auto deadline = now + totalMaxDuration;
			size_t numReadable;
			foreach (i, ref subproc; subprocesses)
				if (readSet.isSet(subproc.socket))
					numReadable++;
			foreach (i, ref subproc; subprocesses)
				if (readSet.isSet(subproc.socket))
				{
					auto subprocDeadline = now + (deadline - now) / numReadable;
					while (now < subprocDeadline && subproc.handleInput())
						now = MonoTime.currTime();
					numReadable--;
				}
		}
		// Process incremental rebuild if in progress
		if (rebuildInProgress())
		{
			browser.rebuildProgress = rebuildProgress();
			if (!processRebuildStep())
			{
				// Rebuild complete
				browser.rebuildProgress = "Done.";
				browser.popup = Browser.Popup.none;
				browser.update();
			}
		}

		if (!headless && now > nextRefresh)
		{
			browser.update();
			nextRefresh = now + refreshInterval;
		}
	}

	if (headless)
	{
		if (!doImport)
		{
			auto totalSamples = browserRoot.getSamples(SampleType.represented);
			stderr.writefln(
				"Collected %s samples (achieving a resolution of ~%s) in %s.",
				totalSamples,
				totalSamples ? (totalSize / totalSamples).humanSize().to!string : "-",
				MonoTime.currTime() - startTime,
			);
		}

		// Print CLI tree output unless --du or --export mode is used
		if (!du && !exportPath)
			exportData(null, ExportFormat.human);
	}

	if (exportPath)
	{
		import std.traits : EnumMembers;

		auto exportFilePath = exportPath == "-" ? null : exportPath.value;

		// Determine export format: explicit option > guess from extension > error
		ExportFormat resolvedFormat;
		if (exportFormatStr)
		{
			try
				resolvedFormat = exportFormatStr.value.to!ExportFormat;
			catch (ConvException)
				throw new Exception("Unknown export format: '" ~ exportFormatStr.value ~ "'. " ~
					"Valid formats are: " ~ [EnumMembers!ExportFormat].map!(e => e.to!string).join(", "));
		}
		else if (exportFilePath)
		{
			auto guessed = guessExportFormat(exportFilePath);
			if (guessed.isNull)
				throw new Exception(
					"Cannot determine export format from extension of '" ~ exportFilePath ~ "'. " ~
					"Use --export-format to specify the format, or use a recognized extension: " ~
					exportExtensions.byKey.join(", ")
				);
			resolvedFormat = guessed.get;
		}
		else
		{
			// Writing to stdout, default to JSON
			resolvedFormat = ExportFormat.json;
		}

		stderr.writeln("Exporting results...");
		exportData(exportFilePath, resolvedFormat);
		if (exportFilePath)
			stderr.writeln("Exported results to: ", exportFilePath);
	}

	if (du)
		exportData(null, ExportFormat.du);

	// Wait for subprocesses to terminate (used by test suite to ensure clean unmount)
	if (waitForSubprocesses)
		foreach (ref subproc; subprocesses)
			subproc.terminate();
}

// System call bindings for mount namespace operations
private extern (C) nothrow @nogc
{
	int unshare(int flags);
	int mount(const(char)* source, const(char)* target,
	          const(char)* filesystemtype, ulong mountflags, const(void)* data);
}
private enum CLONE_NEWNS = 0x00020000;
private enum MS_REC = 0x4000;
private enum MS_PRIVATE = 1 << 18;

/// Check if path is a block device
private bool isBlockDevice(string path)
{
	import core.sys.posix.sys.stat : stat_t, stat, S_IFMT, S_IFBLK;
	import std.string : toStringz;

	stat_t st;
	if (stat(path.toStringz, &st) != 0)
		return false;
	return (st.st_mode & S_IFMT) == S_IFBLK;
}

/// Result of checking btrfs filesystem
private struct BtrfsCheckResult
{
	bool needsAutoMount;   /// True if path is btrfs but not top-level subvolume
	string device;         /// Block device path
}

/// Check if path is btrfs and return info about whether auto-mount is needed
private BtrfsCheckResult checkBtrfsStatus(string fsPath, MountInfo[] mounts)
{
	import core.sys.posix.fcntl : open, O_RDONLY;
	import core.sys.posix.unistd : close;
	import std.string : toStringz;
	import btrfs : isBTRFS, isSubvolume, getSubvolumeID;
	import btrfs.c.kernel_shared.ctree : BTRFS_FS_TREE_OBJECTID;

	BtrfsCheckResult result;

	int fd = open(fsPath.toStringz, O_RDONLY);
	errnoEnforce(fd >= 0, "open");
	scope(exit) close(fd);

	enforce(fd.isBTRFS,
		fsPath ~ " is not a btrfs filesystem");

	enforce(fd.isSubvolume, {
		auto rootPath = mounts.getPathMountInfo(fsPath).file;
		if (!rootPath)
			rootPath = "/";
		return format(
			"%s is not the root of a btrfs subvolume - " ~
			"please specify the path to the subvolume root" ~
			"\n" ~
			"E.g.: %s",
			fsPath,
			[Runtime.args[0], rootPath].escapeShellCommand,
		);
	}());

	if (fd.getSubvolumeID() != BTRFS_FS_TREE_OBJECTID)
	{
		result.needsAutoMount = true;
		auto mountInfo = mounts.getPathMountInfo(fsPath);
		result.device = mountInfo.spec;
	}

	return result;
}

/// Set up auto-mount: create mount namespace, temporary directory, and mount top-level subvolume
private string setupAutoMount(string device)
{
	import core.stdc.errno : errno, EPERM, EINVAL;
	import std.file : mkdirRecurse, tempDir;
	import std.string : toStringz;

	// Create mount namespace
	if (unshare(CLONE_NEWNS) != 0)
	{
		if (errno == EPERM)
			throw new Exception(
				"Cannot create mount namespace: permission denied.\n" ~
				"Try running with sudo.");
		errnoEnforce(false, "unshare(CLONE_NEWNS)");
	}

	// Make all mounts private so they don't propagate to parent namespace
	errnoEnforce(mount(null, "/".toStringz, null, MS_REC | MS_PRIVATE, null) == 0,
		"mount(MS_PRIVATE)");

	// Create mount point directory. We share the same path across
	// instances since the mount is private to each instance.
	auto mountPoint = tempDir.buildPath("btdu-auto-mount");
	mkdirRecurse(mountPoint);

	// Mount top-level subvolume
	if (mount(device.toStringz, mountPoint.toStringz,
	          "btrfs".toStringz, 0, "subvol=/".toStringz) != 0)
	{
		auto mountErrno = errno;

		import std.file : rmdir;
		try rmdir(mountPoint); catch (Exception) {}

		if (mountErrno == EPERM)
			throw new Exception("Cannot mount " ~ device ~ ": permission denied.");
		if (mountErrno == EINVAL)
			throw new Exception(device ~ " does not appear to be a valid btrfs filesystem.");

		errno = mountErrno;
		errnoEnforce(false, "mount(top-level subvolume at " ~ mountPoint ~ ")");
	}

	return mountPoint;
}

void checkBtrfs(string fsPath, bool autoMount)
{
	// Get mount info early so it's available for both code paths
	MountInfo[] mounts;
	try
		mounts = getMounts().array;
	catch (Exception) {}

	// Check if the path is a block device
	if (isBlockDevice(fsPath))
	{
		if (autoMount)
		{
			.autoMountMode = true;
			.fsPath = setupAutoMount(fsPath);
		}
		else
		{
			throw new Exception(formatBlockDeviceError(fsPath, mounts));
		}
		return;
	}

	auto status = checkBtrfsStatus(fsPath, mounts);

	if (status.needsAutoMount)
	{
		if (autoMount)
		{
			.autoMountMode = true;
			.fsPath = setupAutoMount(status.device);
		}
		else
		{
			throw new Exception(formatSubvolumeError(fsPath, mounts));
		}
	}
}

/// Pick a suitable mount root directory
private string pickMountRoot(MountInfo[] mounts = null)
{
	import std.file : exists;
	import std.algorithm.searching : canFind;

	return
		"/mnt".exists && (mounts is null || !mounts.canFind!(m => m.file == "/mnt")) ? "/mnt" :
		"/media".exists ? "/media" :
		"/mnt";
}

private string formatBlockDeviceError(string device, MountInfo[] mounts)
{
	import std.format : format;

	string msg = format("'%s' is a block device, not a mounted filesystem.\n\n", device);

	auto tmpName = pickMountRoot(mounts) ~ "/btrfs-root";

	msg ~= "To analyze this device, either:\n\n" ~
		"  1. Mount it first and run btdu on the mount point:\n\n" ~
		format("     sudo %s\n", ["mkdir", "-p", tmpName].escapeShellCommand) ~
		format("     sudo %s\n", ["mount", "-o", "subvol=/", device, tmpName].escapeShellCommand) ~
		format("     sudo %s\n\n", [Runtime.args[0], tmpName].escapeShellCommand) ~
		"  2. Or use --auto-mount to let btdu mount it temporarily\n" ~
		"     (some features will be disabled):\n\n" ~
		format("     sudo %s\n",
			[Runtime.args[0], "--auto-mount", device].escapeShellCommand);

	return msg;
}

private string formatSubvolumeError(string fsPath, MountInfo[] mounts)
{
	import std.algorithm.searching : canFind;

	string msg = "The specified path is not mounted from the btrfs top-level subvolume.\n\n";

	// Get mount info and detect common layouts
	auto mountInfo = mounts.getPathMountInfo(fsPath);
	auto options = mountInfo.mntops
		.split(",")
		.map!(o => o.findSplit("="))
		.map!(p => tuple(p[0], p[2]))
		.assocArray;

	string currentSubvol;
	if ("subvol" in options)
		currentSubvol = options["subvol"];

	msg ~= "> WHAT WENT WRONG:\n\n";
	if (fsPath == "/")
		msg ~= "  Your root filesystem \"/\" is a btrfs subvolume, but not the top-level one.\n";
	else
		msg ~= "  The path you specified (\"" ~ fsPath ~ "\") is a btrfs subvolume, but not the top-level one.\n";
	if (currentSubvol.length > 0)
		msg ~= format("  It is mounted from the \"%s\" subvolume (subvol=%s), but\n", currentSubvol, currentSubvol);
	msg ~= "  btdu requires the top-level subvolume (subvol=/).\n\n";

	msg ~= "> WHY THIS MATTERS:\n\n" ~
		"  btdu needs access to the top-level subvolume to analyze all subvolumes\n" ~
		"  and snapshots. Your current path only shows part of the filesystem.\n\n";

	msg ~= "> HOW THIS HAPPENED:\n\n";
	if (currentSubvol.canFind("@"))
		msg ~=
			"  Your system uses the common \"@\" subvolume layout (Ubuntu, Fedora, etc.).\n" ~
			"  This layout was probably created automatically during installation.\n";
	else
		msg ~=
			"  Your system was configured to mount a subvolume rather than the\n" ~
			"  top-level filesystem. This is common for systems using btrfs snapshots.\n";

	// Check if this is configured in /etc/fstab
	bool inFstab = {
		try
		{
			import std.stdio : File;
			foreach (line; File("/etc/fstab").byLine)
			{
				auto l = line.idup.strip;
				if (l.length == 0 || l[0] == '#')
					continue;
				auto fields = l.split;
				if (fields.length >= 2 && fields[1] == fsPath)
					return true;
			}
		}
		catch (Exception) {}
		return false;
	}();

	if (inFstab)
		msg ~= "  This configuration is set in /etc/fstab.\n";
	msg ~= "\n";

	// Provide step-by-step fix
	auto device = mountInfo.spec;
	if (!device)
		device = "<your-btrfs-device>"; // More descriptive placeholder
	auto tmpName = pickMountRoot(mounts) ~ "/btrfs-root";

	msg ~= "> WHAT TO DO:\n\n" ~
		"  Mount the top-level subvolume and run btdu there:\n\n" ~
		format("  1. Create a mount point:\n     sudo %s\n\n",
			["mkdir", "-p", tmpName].escapeShellCommand) ~
		format("  2. Mount the top-level subvolume:\n     sudo %s\n\n",
			["mount", "-o", "subvol=/", device, tmpName].escapeShellCommand) ~
		format("  3. Run btdu:\n     sudo %s\n\n",
			[Runtime.args[0], tmpName].escapeShellCommand) ~
		"  This is safe: mounting the same filesystem at a second location is a normal\n" ~
		"  operation and won't affect your existing mounts or data.\n\n";

	// Add hint about what they'll see
	if (currentSubvol.canFind("@"))
		msg ~= "  From there, you'll see all subvolumes such as @, @home, snapshots, etc.\n\n";
	else
		msg ~= "  From there, you'll see all subvolumes and snapshots on this filesystem.\n\n";

	msg ~= "  Alternatively, use --auto-mount to let btdu handle this automatically\n" ~
		"  (some features will be disabled):\n\n" ~
		format("     sudo %s",
			[Runtime.args[0], "--auto-mount", fsPath].escapeShellCommand);

	return msg;
}

private string escapeShellCommand(string[] args)
{
	import std.process : escapeShellFileName;
	import std.algorithm.searching : all;
	import ae.utils.array : isOneOf;

	foreach (ref arg; args)
		if (!arg.representation.all!(c => c.isOneOf("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.=:@%")))
			arg = arg.escapeShellFileName;
	return args.join(" ");
}

mixin main!(funopt!program);
