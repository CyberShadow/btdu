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

import btrfs;
import btrfs.c.kerncompat;
import btrfs.c.kernel_shared.ctree;

import btdu.paths;
import btdu.sample;
import btdu.state;

void main(string[] args)
{
	rndGen = Random(2);

	stderr.writeln("Opening filesystem...");
	enforce(args.length == 2, "Usage: " ~ args[0] ~ " PATH");
	globalParams.fsPath = args[1];
	globalParams.fd = open(globalParams.fsPath.toStringz, O_RDONLY);
	errnoEnforce(globalParams.fd >= 0, "open");

	stderr.writeln("Reading chunks...");
	enumerateChunks(globalParams.fd, (u64 offset, const ref btrfs_chunk chunk) {
		globalParams.chunks ~= GlobalParams.ChunkInfo(offset, chunk);
	});

	globalParams.totalSize = globalParams.chunks.map!((ref chunk) => chunk.chunk.length).sum;
	stderr.writefln("Found %d chunks with a total size of %d.", globalParams.chunks.length, globalParams.totalSize);

	Sampler[] samplers;
	foreach (n; 0 .. totalCPUs)
		samplers ~= new Sampler(rndGen.uniform!Seed);
	
	Thread.sleep(1.seconds);
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
