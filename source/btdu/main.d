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

import core.sys.posix.fcntl;
import core.thread;

import std.algorithm.iteration;
import std.algorithm.sorting;
import std.exception;
import std.parallelism;
import std.random;
import std.stdio;
import std.string;

import ae.utils.funopt;
import ae.utils.main;

import btrfs;
import btrfs.c.kerncompat;
import btrfs.c.kernel_shared.ctree;

import btdu.browser;
import btdu.common;
import btdu.paths;
import btdu.sample;
import btdu.state;

@(`Sampling disk usage profiler for btrfs.`)
void program(
	Parameter!(string, "Path to the root of the filesystem to analyze") path,
	Option!(uint, "Number of sampling threads\n (default is number of logical CPUs for this system)", "N", 'j') threads = 0,
	Switch!("Print fewer messages") quiet = false,
	Option!(Seed, "Random seed used to choose samples") seed = 0,
)
{
	rndGen = Random(seed);

	if (!quiet) stderr.writeln("Opening filesystem...");
	globalParams.fsPath = path;
	globalParams.fd = open(globalParams.fsPath.toStringz, O_RDONLY);
	errnoEnforce(globalParams.fd >= 0, "open");

	if (!quiet) stderr.writeln("Reading chunks...");
	enumerateChunks(globalParams.fd, (u64 offset, const ref btrfs_chunk chunk) {
		globalParams.chunks ~= GlobalParams.ChunkInfo(offset, chunk);
	});

	globalParams.totalSize = globalParams.chunks.map!((ref chunk) => chunk.chunk.length).sum;
	if (!quiet) stderr.writefln("Found %d chunks with a total size of %d.", globalParams.chunks.length, globalParams.totalSize);

	if (threads == 0)
		threads = totalCPUs;

	Sampler[] samplers;
	foreach (n; 0 .. threads)
		samplers ~= new Sampler(rndGen.uniform!Seed);

	runBrowser();

	withGlobalState((ref g) { g.stop = true; });
	if (!quiet) stderr.writeln("Stopping sampling threads...");
	foreach (sampler; samplers)
		sampler.join();
}

void usageFun(string usage)
{
	stderr.writeln("btdu v" ~ btduVersion);
	stderr.writeln(usage);
}

mixin main!(funopt!(program, FunOptConfig.init, usageFun));
