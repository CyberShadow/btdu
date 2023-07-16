/*
 * Copyright (C) 2020, 2021, 2022, 2023  Vladimir Panteleev <btdu@cy.md>
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

import core.lifetime : move;
import core.runtime : Runtime;
import core.time;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.conv : to;
import std.exception;
import std.math : ceil;
import std.parallelism : totalCPUs;
import std.path;
import std.process : environment;
import std.random;
import std.socket;
import std.stdio;
import std.string;
import std.typecons;

import ae.sys.data;
import ae.sys.datamm;
import ae.sys.file : getMounts, getPathMountInfo;
import ae.sys.shutdown;
import ae.utils.funopt;
import ae.utils.json;
import ae.utils.main;
import ae.utils.time.parsedur;
import ae.utils.typecons : require;

import btdu.ui.browser;
import btdu.common;
import btdu.paths;
import btdu.sample;
import btdu.subproc;
import btdu.state;

alias imported = btdu.state.imported;

@(`Sampling disk usage profiler for btrfs.`)
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
	Option!(ulong, "Stop after collecting N samples.", "N", 'n') maxSamples = 0,
	Option!(string, "Stop after running for this duration.", "DURATION") maxTime = null,
	Option!(string, `Stop after achieving this resolution (e.g. "1MB" or "1%").`, "SIZE") minResolution = null,
	Switch!hiddenOption exitOnLimit = false,
	Option!(string, "On exit, export the collected results to the given file.", "PATH", 'o', "export") exportPath = null,
	Switch!("On exit, export represented size estimates in 'du' format to standard output.") du = false,
	Switch!("Instead of analyzing a btrfs filesystem, read previously collected results saved with --export from PATH.", 'f', "import") doImport = false,
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

	static Data importData; // Keep memory-mapped file alive, as directory names may reference it
	if (doImport)
	{
		if (procs || seed || subprocess || expert || physical || maxSamples || maxTime || minResolution || exportPath)
			throw new Exception("Conflicting command-line options");

		stderr.writeln("Loading results from file...");
		importData = mapFile(path, MmMode.read);
		auto json = cast(string)importData.unsafeContents; // Pinned by importData, which has static lifetime

		debug importing = true;
		auto s = json.jsonParse!SerializedState();

		expert = s.expert;
		physical = s.physical;
		fsPath = s.fsPath;
		totalSize = s.totalSize;
		move(*s.root, browserRoot);

		browserRoot.resetParents();
		debug importing = false;
		imported = true;
	}

	.expert = expert;
	.physical = physical;

	if (!doImport)
	{
		rndGen = Random(seed);
		fsPath = path.buildNormalizedPath;

		if (subprocess)
			return subprocessMain(path, physical);

		checkBtrfs(fsPath);

		if (procs == 0)
			procs = totalCPUs;

		subprocesses = new Subprocess[procs];
		foreach (ref subproc; subprocesses)
			subproc.start();
	}

	Duration parsedMaxTime;
	if (maxTime)
		parsedMaxTime = parseDuration(maxTime);

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

	Socket stdinSocket;
	if (!headless)
	{
		stdinSocket = new Socket(cast(socket_t)stdin.fileno, AddressFamily.UNSPEC);
		stdinSocket.blocking = false;
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
		if (stdinSocket)
		{
			readSet.add(stdinSocket);
			exceptSet.add(stdinSocket);
		}
		if (!paused)
			foreach (ref subproc; subprocesses)
				readSet.add(subproc.socket);

		if (!headless && browser.needRefresh())
			Socket.select(readSet, null, exceptSet, refreshInterval);
		else
			Socket.select(readSet, null, exceptSet);
		auto now = MonoTime.currTime();

		if (stdinSocket && browser.handleInput())
		{
			do {} while (browser.handleInput()); // Process all input
			if (browser.done)
				break;
			browser.update();
			nextRefresh = now + refreshInterval;
		}
		if (!paused)
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
		if (!headless && now > nextRefresh)
		{
			browser.update();
			nextRefresh = now + refreshInterval;
		}

		if ((maxSamples
				&& browserRoot.data[SampleType.represented].samples >= maxSamples) ||
			(maxTime
				&& now > startTime + parsedMaxTime) ||
			(minResolution
				&& browserRoot.data[SampleType.represented].samples
				&& totalSize
				&& (totalSize / browserRoot.data[SampleType.represented].samples) <= parsedMinResolution))
		{
			if (headless || exitOnLimit)
				break;
			else
			{
				if (!paused)
				{
					browser.togglePause();
					browser.update();
				}
				// Only pause once
				maxSamples = 0;
				maxTime = minResolution = null;
			}
		}
	}

	if (headless)
	{
		auto totalSamples = browserRoot.data[SampleType.represented].samples;
		stderr.writefln(
			"Collected %s samples (achieving a resolution of ~%s) in %s.",
			totalSamples,
			totalSamples ? (totalSize / totalSamples).humanSize().to!string : "-",
			MonoTime.currTime() - startTime,
		);
	}

	if (exportPath)
	{
		stderr.writeln("Exporting results...");

		SerializedState s;
		s.expert = expert;
		s.physical = physical;
		s.fsPath = fsPath;
		s.totalSize = totalSize;
		s.root = &browserRoot;

		alias LockingBinaryWriter = typeof(File.lockingBinaryWriter());
		alias JsonFileSerializer = CustomJsonSerializer!(JsonWriter!LockingBinaryWriter);

		{
			JsonFileSerializer j;
			auto file = exportPath == "-" ? stdout : File(exportPath, "wb");
			j.writer.output = file.lockingBinaryWriter;
			j.put(s);
		}
		stderr.writeln("Exported results to: ", exportPath);
	}

	if (du)
	{
		ulong blockSize = {
			// As in du(1)
			if ("POSIXLY_CORRECT" in environment)
				return 512;
			foreach (name; ["BTDU_BLOCK_SIZE", "DU_BLOCK_SIZE", "BLOCK_SIZE", "BLOCKSIZE"])
				if (auto value = environment.get(name))
					return value.to!ulong;
			return 1024;
		}();

		auto totalSamples = browserRoot.data[SampleType.represented].samples;

		void visit(BrowserPath* path)
		{
			for (auto child = path.firstChild; child; child = child.nextSibling)
				visit(child);

			auto samples = path.data[SampleType.represented].samples;
			auto size = ceil(samples * real(totalSize) / totalSamples / blockSize).to!ulong;
			writefln("%d\t%s%s", size, fsPath, path.pointerWriter);
		}

		if (totalSamples)
			visit(&browserRoot);
	}
}

/// Serialized
struct SerializedState
{
	bool expert;
	@JSONOptional bool physical;
	string fsPath;
	ulong totalSize;
	BrowserPath* root;
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

	auto mounts = getMounts().array;
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

void usageFun(string usage)
{
	stderr.writeln("btdu v" ~ btduVersion);
	stderr.writeln(usage);
}

mixin main!(funopt!(program, FunOptConfig.init, usageFun));
