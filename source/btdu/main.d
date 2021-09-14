/*
 * Copyright (C) 2020, 2021  Vladimir Panteleev <btdu@cy.md>
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

import core.sys.posix.unistd : STDIN_FILENO;
import core.time;

import std.exception;
import std.parallelism;
import std.path;
import std.random;
import std.stdio;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.time.parsedur;

import btdu.browser;
import btdu.common;
import btdu.eventloop;
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
	Option!(string, hiddenOption) benchmark = null,
	Switch!("Expert mode: collect and show additional metrics.\nUses more memory.") expert = false,
)
{
	rndGen = Random(seed);
	fsPath = path.buildNormalizedPath;

	if (subprocess)
		return subprocessMain(path);

	checkBtrfs(fsPath);

	if (procs == 0)
		procs = totalCPUs;

	bool headless;
	Duration benchmarkTime;
	if (benchmark)
	{
		headless = true;
		benchmarkTime = parseDuration(benchmark);
	}

	subprocesses = new Subprocess[procs];
	foreach (ref subproc; subprocesses)
		subproc.start();

	auto eventLoop = makeEventLoop(procs + headless);

	.expert = expert;

	auto startTime = MonoTime.currTime();
	enum refreshInterval = 500.msecs;
	auto nextRefresh = startTime;
	bool done;

	Browser browser;
	if (!headless)
	{
		browser.start();
		browser.update();
		eventLoop.add(new class Receiver {
			override int getFD() { return STDIN_FILENO; }
			override ubyte[] getReadBuffer() { return null; }
			override void handleRead(size_t received) {}
		});
	}

	foreach (ref p; subprocesses)
		eventLoop.add(
			new class (&p) Receiver {
				Subprocess* subprocess;
				this(Subprocess* p) { subprocess = p; }
				override int getFD() { return subprocess.fd; }
				override ubyte[] getReadBuffer() { return subprocess.getReadBuffer(); }
				override void handleRead(size_t received) {
					enforce(received != 0, "Unexpected subprocess termination");
					subprocess.handleInput(received);
				}
				override bool active() { return !paused; }
			}
		);

	// Main event loop
	while (!done)
	{
		eventLoop.step();

		auto now = MonoTime.currTime();

		if (!headless && browser.handleInput())
		{
			do {} while (browser.handleInput()); // Process all input
			if (browser.done)
				break;
			browser.update();
			nextRefresh = now + refreshInterval;
		}

		if (!headless && now > nextRefresh)
		{
			browser.update();
			nextRefresh = now + refreshInterval;
		}
		if (benchmark && now > startTime + benchmarkTime)
			break;
	}

	if (benchmark)
		writeln(browserRoot.data[SampleType.represented].samples);
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

	enforce(fd.isSubvolume,
		fsPath ~ " is not the root of a btrfs subvolume - please specify the path to the subvolume root");

	enforce(fd.getSubvolumeID() == BTRFS_FS_TREE_OBJECTID,
		fsPath ~ " is not the root btrfs subvolume - please specify the path to a mountpoint mounted with subvol=/ or subvolid=5");
}

void usageFun(string usage)
{
	stderr.writeln("btdu v" ~ btduVersion);
	stderr.writeln(usage);
}

mixin main!(funopt!(program, FunOptConfig.init, usageFun));
