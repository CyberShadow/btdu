/*
 * Copyright (C) 2020, 2021, 2022  Vladimir Panteleev <btdu@cy.md>
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

import std.conv : to;
import std.exception;
import std.parallelism : totalCPUs;
import std.path;
import std.random;
import std.socket;
import std.stdio;
import std.string;

import ae.sys.file : getPathMountInfo;
import ae.sys.shutdown;
import ae.utils.funopt;
import ae.utils.json;
import ae.utils.main;
import ae.utils.time.parsedur;

import btdu.browser;
import btdu.common;
import btdu.paths;
import btdu.sample;
import btdu.subproc;
import btdu.state;

@(`Sampling disk usage profiler for btrfs.`)
void program(
	Parameter!(string, "Path to the root of the filesystem to analyze") path,
	Option!(uint, "Number of sampling subprocesses\n (default is number of logical CPUs for this system)", "N", 'j') procs = 0,
	Option!(Seed, "Random seed used to choose samples") seed = 0,
	Switch!hiddenOption subprocess = false,
	Switch!("Expert mode: collect and show additional metrics.\nUses more memory.") expert = false,
	Switch!hiddenOption man = false,
	Switch!("Run without launching the result browser UI.") headless = false,
	Option!(ulong, "Stop after collecting N samples.", "N", 'n') maxSamples = 0,
	Option!(string, "Stop after running for this duration.", "DURATION") maxTime = null,
	Option!(string, "Stop after achieving this resolution.", "SIZE") minResolution = null,
	Option!(string, "On exit, export the collected results to the given file.", "PATH", 'o', "export") exportPath = null,
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

	rndGen = Random(seed);
	fsPath = path.buildNormalizedPath;

	if (subprocess)
		return subprocessMain(path);

	checkBtrfs(fsPath);

	if (procs == 0)
		procs = totalCPUs;

	Duration parsedMaxTime;
	if (maxTime)
		parsedMaxTime = parseDuration(maxTime);

	real parsedMinResolution;
	if (minResolution)
		parsedMinResolution = parseSize(minResolution);

	subprocesses = new Subprocess[procs];
	foreach (ref subproc; subprocesses)
		subproc.start();

	Socket stdinSocket;
	if (!headless)
	{
		stdinSocket = new Socket(cast(socket_t)stdin.fileno, AddressFamily.UNSPEC);
		stdinSocket.blocking = false;
	}

	.expert = expert;

	Browser browser;
	if (!headless)
	{
		browser.start();
		browser.update();
	}

	auto startTime = MonoTime.currTime();
	enum refreshInterval = 500.msecs;
	auto nextRefresh = startTime;

	auto readSet = new SocketSet;
	auto exceptSet = new SocketSet;

	bool run = true;
	if (headless) // In non-headless mode, ncurses takes care of this
		addShutdownHandler((reason) {
			run = false;
		});

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
			foreach (ref subproc; subprocesses)
				if (readSet.isSet(subproc.socket))
					subproc.handleInput();
		if (!headless && now > nextRefresh)
		{
			browser.update();
			nextRefresh = now + refreshInterval;
		}

		if ((maxSamples && browserRoot.data[SampleType.represented].samples >= maxSamples) ||
			(maxTime && now > startTime + parsedMaxTime) ||
			(minResolution && (totalSize / browserRoot.data[SampleType.represented].samples) <= parsedMinResolution))
		{
			if (headless)
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
			(totalSize / totalSamples).humanSize(),
			MonoTime.currTime() - startTime,
		);
	}

	if (exportPath)
	{
		stderr.writeln("Exporting results...");

		SerializedState s;
		s.expert = expert;
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
}

/// Serialized
struct SerializedState
{
	bool expert;
	string fsPath;
	ulong totalSize;
	BrowserPath* root;
}

void checkBtrfs(string fsPath)
{
	import core.sys.posix.fcntl : open, O_RDONLY;
	import std.string : toStringz;
	import btrfs : isBTRFS, isSubvolume, getSubvolumeID;
	import btrfs.c.kernel_shared.ctree : BTRFS_FS_TREE_OBJECTID;

	int fd = open(fsPath.toStringz, O_RDONLY);
	errnoEnforce(fd >= 0, "open");

	enforce(fd.isBTRFS,
		fsPath ~ " is not a btrfs filesystem");

	enforce(fd.isSubvolume, {
		auto rootPath = getPathMountInfo(fsPath).file;
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
		auto device = getPathMountInfo(fsPath).spec;
		if (!device)
			device = "/dev/sda1"; // placeholder
		auto tmpName = "/tmp/" ~ device.baseName;
		return format(
			"%s is not the root btrfs subvolume - " ~
			"please specify the path to a mountpoint mounted with subvol=/ or subvolid=5" ~
			"\n" ~
			"E.g.: %s && %s && %s",
			fsPath,
			["mkdir", tmpName].escapeShellCommand,
			["mount", "-o", "subvol=/", device, tmpName].escapeShellCommand,
			[Runtime.args[0], tmpName].escapeShellCommand,
		);
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
