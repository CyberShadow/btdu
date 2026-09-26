/// Live sampling run configuration and restart lifecycle.
module btdu.runstate;

import core.time;

import std.conv : to;
import std.process : Pid, tryWait;
import std.string : endsWith;
import std.random : Random, uniform;
import std.typecons : Nullable;
import ae.utils.time.parsedur : parseDuration;

import btdu.common : parseSize, Seed;
import btdu.state : resetSamplingState, paused;
import btdu.subproc : Subprocess, forceTerminate, configureSubprocesses;

struct SamplingRun
{
	// Limits as configured on the command line; never modified.
	Nullable!ulong maxSamples;
	Nullable!Duration maxTime;
	string minResolution;  // null = none; kept as string because "%" depends on totalSize

	/// False after the limit was reached once and sampling was auto-paused.
	bool limitsArmed = true;
	/// Read by subprocesses through a pointer; ulong.max means no limit.
	ulong sampleLimit = ulong.max;

	MonoTime startTime, nextRefresh;

	/// Killed workers not yet reaped; see reapRetiredWorkers.
	Pid[] retiredWorkers;
	Seed[] seeds; /// One per worker, fixed for the lifetime of the program.

	void initialize(string maxSamples, string maxTime, string minResolution, Seed seed, uint procs)
	{
		if (maxSamples)
			this.maxSamples = maxSamples.to!ulong;
		if (maxTime)
			this.maxTime = parseDuration(maxTime);
		this.minResolution = minResolution;
		sampleLimit = this.maxSamples.get(ulong.max);
		assert(procs > 0);
		auto random = Random(seed);
		seeds = new Seed[procs];
		foreach (ref s; seeds)
			s = random.uniform!Seed;
	}

	real parsedMinResolution(ulong totalSize)
	{
		assert(minResolution && totalSize, "minResolution or totalSize is not set");
		return minResolution.endsWith("%")
			? minResolution[0 .. $ - 1].to!real / 100 * totalSize
			: parseSize(minResolution);
	}

	void disarmLimits()
	{
		limitsArmed = false;
		sampleLimit = ulong.max;
	}

	void restart()
	{
		limitsArmed = true;
		sampleLimit = maxSamples.get(ulong.max);
		startTime = MonoTime.currTime();
		nextRefresh = startTime;
	}

	/// Reap retired workers that have exited, without blocking.
	void reapRetiredWorkers()
	{
		size_t kept;
		foreach (pid; retiredWorkers)
			if (!tryWait(pid).terminated)
				retiredWorkers[kept++] = pid;
		retiredWorkers = retiredWorkers[0 .. kept];
	}

	Subprocess[] createWorkers()
	{
		return configureSubprocesses(seeds, &sampleLimit);
	}

	/// Retire running workers, discard the dataset, re-arm limits, and
	/// configure a fresh batch with the run's seeds. The caller starts them.
	void replaceWorkers(ref Subprocess[] subprocesses)
	{
		retiredWorkers ~= forceTerminate(subprocesses);
		resetSamplingState();
		paused = false;
		restart();
		subprocesses = createWorkers();
	}
}

unittest
{
	import btdu.state : currentGeneration, imported, paused, subprocesses;

	SamplingRun run;
	run.initialize("7", "1s", "10%", cast(Seed) 1, 3);
	auto sampleLimit = &run.sampleLimit;
	assert(run.parsedMinResolution(1000) == 100);
	run.disarmLimits();
	assert(!run.limitsArmed);
	assert(run.sampleLimit == ulong.max);
	run.restart();
	assert(run.limitsArmed);
	assert(run.maxSamples.get == 7);
	assert(run.maxTime.get == 1.seconds);
	assert(run.minResolution == "10%");
	assert(run.sampleLimit == 7);
	assert(&run.sampleLimit is sampleLimit);
	assert(run.parsedMinResolution(2000) == 200);

	auto random = Random(cast(Seed) 1);
	assert(run.seeds.length == 3);
	foreach (seed; run.seeds)
		assert(seed == random.uniform!Seed);

	auto oldStartTime = run.startTime;
	currentGeneration = 9;
	imported = true;
	paused = true;
	subprocesses = null;
	run.replaceWorkers(subprocesses);
	assert(currentGeneration == 0);
	assert(!imported && !paused);
	assert(run.limitsArmed && run.sampleLimit == 7);
	assert(run.startTime >= oldStartTime);
	assert(subprocesses.length == run.seeds.length);
	foreach (i, ref worker; subprocesses)
	{
		assert(worker.seed == run.seeds[i]);
		assert(worker.sampleLimit is sampleLimit);
	}
	run.replaceWorkers(subprocesses);
	foreach (i, ref worker; subprocesses)
		assert(worker.seed == run.seeds[i]);
	assert(forceTerminate(subprocesses).length == 0);
	run.reapRetiredWorkers();
	assert(run.retiredWorkers.length == 0);
}
