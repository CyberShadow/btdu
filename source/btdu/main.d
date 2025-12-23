/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2025  Vladimir Panteleev <btdu@cy.md>
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
import std.conv : to;
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
import btdu.impexp : ExportFormat, importData, importCompareData, exportData;
import btdu.paths;
import btdu.sample;
import btdu.subproc;
import btdu.state;

@(`Sampling disk usage profiler for btrfs.`)
@Version("btdu v" ~ btduVersion)
void program(
	Parameter!(string, "Path to the root of the filesystem to analyze") path,
	Option!(uint, "Number of sampling subprocesses\n (default is number of logical CPUs for this system)", "N", 'j') procs = 0,
	Option!(Seed, "Random seed used to choose samples") seed = 0,
	Switch!hiddenOption subprocess = false,
	Switch!("Measure physical space (instead of logical).", 'p') physical = false,
	Switch!("Expert mode: collect and show additional metrics.\nUses more memory.", 'x') expert = false,
	Switch!hiddenOption man = false,
	Option!(string, "Set UI refresh interval.\nSpecify 0 to refresh as fast as possible.", "DURATION", 'i', "interval") refreshIntervalStr = null,
	Switch!("Run without launching the result browser UI.") headless = false,
	Option!(string, "Stop after collecting N samples.", "N", 'n') maxSamples = null,
	Option!(string, "Stop after running for this duration.", "DURATION") maxTime = null,
	Option!(string, `Stop after achieving this resolution (e.g. "1MB" or "1%").`, "SIZE") minResolution = null,
	Switch!hiddenOption exitOnLimit = false,
	Option!(string, "On exit, export the collected results to the given file.", "PATH", 'o', "export") exportPath = null,
	Switch!("When exporting, include 'seenAs' data showing shared paths.") exportSeenAs = false,
	Option!(string[], "Prioritize allocating representative samples in the given path.", "PATTERN") prefer = null,
	Option!(string[], "Deprioritize allocating representative samples in the given path.", "PATTERN") ignore = null,
	Switch!("On exit, export represented size estimates in 'du' format to standard output.") du = false,
	Switch!("Instead of analyzing a btrfs filesystem, read previously collected results saved with --export from PATH.", 'f', "import") doImport = false,
	Option!(string, "Compare against a baseline from a previously exported file.", "PATH", 'c', "compare") comparePath = null,
)
{
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
		if (procs || seed || subprocess || expert || physical || maxSamples || maxTime || minResolution || exportPath || prefer || ignore)
			throw new Exception("Conflicting command-line options");

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

		// TODO: respect CLI order (needs std.getopt and ae.utils.funopt changes)
		PathRule[] rules;
		rules ~= prefer.map!(p => PathRule(PathRule.Type.prefer, parsePathPattern(p, fsPath))).array;
		rules ~= ignore.map!(p => PathRule(PathRule.Type.ignore, parsePathPattern(p, fsPath))).array;
		.pathRules = rules;

		if (subprocess)
			return subprocessMain(path, physical);

		checkBtrfs(fsPath);

		if (procs == 0)
			procs = totalCPUs;

		subprocesses = new Subprocess[procs];
		foreach (ref subproc; subprocesses)
			subproc.start();
	}

	// Load comparison baseline if requested
	if (comparePath)
	{
		if (subprocess)
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
		assert(minResolution && totalSize);
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
		if (!paused && !rebuildState.inProgress)
			foreach (ref subproc; subprocesses)
				readSet.add(subproc.socket);

		// Need a refresh now?
		bool busy = rebuildState.inProgress;
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

		if (!paused && !rebuildState.inProgress) // note, we must check rebuildState.inProgress again here
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
		if (rebuildState.inProgress)
		{
			browser.rebuildProgress = format!"Rebuilding... %d%%"(rebuildState.progressPercent);
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
		auto totalSamples = browserRoot.getSamples(SampleType.represented);
		stderr.writefln(
			"Collected %s samples (achieving a resolution of ~%s) in %s.",
			totalSamples,
			totalSamples ? (totalSize / totalSamples).humanSize().to!string : "-",
			MonoTime.currTime() - startTime,
		);

		// Print CLI tree output unless --du mode is used
		if (!du)
			exportData(null, ExportFormat.human);
	}

	if (exportPath)
	{
		auto exportFilePath = exportPath == "-" ? null : exportPath.value;
		stderr.writeln("Exporting results...");
		exportData(exportFilePath);
		if (exportFilePath)
			stderr.writeln("Exported results to: ", exportFilePath);
	}

	if (du)
		exportData(null, ExportFormat.du);
}

void checkBtrfs(string fsPath)
{
	import core.sys.posix.fcntl : open, O_RDONLY;
	import std.file : exists;
	import std.string : toStringz;
	import std.algorithm.searching : canFind;
	import btrfs : isBTRFS, isSubvolume, getSubvolumeID;
	import btrfs.c.kernel_shared.ctree : BTRFS_FS_TREE_OBJECTID;

	int fd = open(fsPath.toStringz, O_RDONLY);
	errnoEnforce(fd >= 0, "open");

	enforce(fd.isBTRFS,
		fsPath ~ " is not a btrfs filesystem");

	MountInfo[] mounts;
	try
		mounts = getMounts().array;
	catch (Exception e) {}
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

	enforce(fd.getSubvolumeID() == BTRFS_FS_TREE_OBJECTID, {
		string msg = format(
			"The mount point you specified, \"%s\", " ~
			"is not the top-level btrfs subvolume (\"subvolid=%d,subvol=/\").\n",
			fsPath, BTRFS_FS_TREE_OBJECTID);

		auto mountInfo = mounts.getPathMountInfo(fsPath);
		auto options = mountInfo.mntops
			.split(",")
			.map!(o => o.findSplit("="))
			.map!(p => tuple(p[0], p[2]))
			.assocArray;
		if ("subvol" in options && "subvolid" in options)
			msg ~= format(
				"It is the btrfs subvolume \"subvolid=%s,subvol=%s\".\n",
				options["subvolid"], options["subvol"],
			);

		auto device = mountInfo.spec;
		if (!device)
			device = "/dev/sda1"; // placeholder
		auto mountRoot =
			"/mnt".exists && !mounts.canFind!(m => m.file == "/mnt") ? "/mnt" :
			"/media".exists ? "/media" :
			"..."
		;
		auto tmpName = mountRoot ~ "/" ~ device.baseName;
		msg ~= format(
			"Please specify the path to a mountpoint mounted with subvol=/ or subvolid=%d." ~
			"\n" ~
			"E.g.: %s && %s && %s",
			BTRFS_FS_TREE_OBJECTID,
			["mkdir", tmpName].escapeShellCommand,
			["mount", "-o", "subvol=/", device, tmpName].escapeShellCommand,
			[Runtime.args[0], tmpName].escapeShellCommand,
		);
		if (fsPath == "/")
			msg ~= format(
				"\n\nNote that the top-level btrfs subvolume (\"subvolid=%d,subvol=/\") " ~
				"is not the same as the root of the filesystem (\"/\").",
				BTRFS_FS_TREE_OBJECTID);
		return msg;
	}());
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
