/*  Copyright (C) 2020  Vladimir Panteleev <btdu@cy.md>
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License as
 *  published by the Free Software Foundation, either version 3 of the
 *  License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
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

import btdu.paths;
import btdu.sample;
import btdu.state;

void program(
	Parameter!(string, "Path to the root of the filesystem to analyze") path,
	Option!(uint, "Number of sampling threads\n (default is number of logical CPUs for this system)", "N", 'j') threads = 0,
)
{
	rndGen = Random(2);

	stderr.writeln("Opening filesystem...");
	globalParams.fsPath = path;
	globalParams.fd = open(globalParams.fsPath.toStringz, O_RDONLY);
	errnoEnforce(globalParams.fd >= 0, "open");

	stderr.writeln("Reading chunks...");
	enumerateChunks(globalParams.fd, (u64 offset, const ref btrfs_chunk chunk) {
		globalParams.chunks ~= GlobalParams.ChunkInfo(offset, chunk);
	});

	globalParams.totalSize = globalParams.chunks.map!((ref chunk) => chunk.chunk.length).sum;
	stderr.writefln("Found %d chunks with a total size of %d.", globalParams.chunks.length, globalParams.totalSize);

	if (threads == 0)
		threads = totalCPUs;

	Sampler[] samplers;
	foreach (n; 0 .. threads)
		samplers ~= new Sampler(rndGen.uniform!Seed);

	Thread.sleep(10.seconds);
	withGlobalState((ref g) { g.stop = true; });
	foreach (sampler; samplers)
		sampler.join();

	withGlobalState((ref g) {
		void dump(BrowserPath* p, size_t indent)
		{
			writefln("%*s%s [%d]", indent * 2, "", p.name, p.samples);
			auto children = p.getChildren(g);
			foreach (childName; children.keys.sort)
				dump(children[childName], indent + 1);
		}
		dump(&g.browserRoot, 0);
	});
}

mixin main!(funopt!program);
