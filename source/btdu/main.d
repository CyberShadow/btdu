/*
 * Copyright (C) 2020  Vladimir Panteleev <btdu@cy.md>
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

import core.time;

import std.exception;
import std.parallelism;
import std.random;
import std.socket;
import std.stdio;

import ae.utils.funopt;
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
	Option!(string, hiddenOption) benchmark = null,
)
{
	rndGen = Random(seed);
	fsPath = path;

	if (subprocess)
		return subprocessMain(path);

	if (procs == 0)
		procs = totalCPUs;

	bool headless;
	Duration benchmarkTime;
	if (benchmark)
	{
		headless = true;
		benchmarkTime = parseDuration(benchmark);
	}

	auto subprocesses = new Subprocess[procs];
	foreach (ref subproc; subprocesses)
		subproc.start();

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
	enum refreshInterval = 500.msecs;
	auto nextRefresh = startTime + refreshInterval;

	auto readSet = new SocketSet;
	auto exceptSet = new SocketSet;

	// Main event loop
	while (true)
	{
		readSet.reset();
		exceptSet.reset();
		if (stdinSocket)
		{
			readSet.add(stdinSocket);
			exceptSet.add(stdinSocket);
		}
		foreach (ref subproc; subprocesses)
			readSet.add(subproc.socket);

		Socket.select(readSet, null, exceptSet);
		auto now = MonoTime.currTime();

		if (stdinSocket && (readSet.isSet(stdinSocket) || exceptSet.isSet(stdinSocket)))
		{
			browser.handleInput();
			if (browser.done)
				break;
			browser.update();
			nextRefresh = now + refreshInterval;
		}
		foreach (ref subproc; subprocesses)
			if (readSet.isSet(subproc.socket))
				subproc.handleInput();
		if (!headless && now > nextRefresh)
		{
			browser.update();
			nextRefresh = now + refreshInterval;
		}
		if (benchmark && now > startTime + benchmarkTime)
			break;
	}

	if (benchmark)
		writeln(browserRoot.samples);
}

void usageFun(string usage)
{
	stderr.writeln("btdu v" ~ btduVersion);
	stderr.writeln(usage);
}

mixin main!(funopt!(program, FunOptConfig.init, usageFun));
