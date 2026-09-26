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

import core.time;

import std.algorithm.iteration;
import std.array;
import std.conv : ConvException, to;
import std.parallelism : totalCPUs;
import std.path;
import std.socket;
import std.stdio : stdin, stdout, stderr;
import std.string;
import std.typecons;

import ae.sys.shutdown;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.time.parsedur;
import ae.utils.typecons : require;

import btdu.ui.browser;
import btdu.common;
import btdu.impexp : ExportFormat, importData, importCompareData, exportData, guessExportFormat, exportExtensions;
import btdu.paths;
import btdu.sample;
import btdu.runstate;
import btdu.mount : checkBtrfs;
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
)
{
	if (exportFormatStr && !exportPath)
		throw new Exception("--export-format requires --export to be specified");

	if (autoMount && (prefer.length || ignore.length))
		throw new Exception("--prefer and --ignore options are not available with --auto-mount");

	if (procs == 0)
		procs = totalCPUs;

	SamplingRun samplingRun;
	samplingRun.initialize(
		maxSamples ? maxSamples.value : null,
		maxTime ? maxTime.value : null,
		minResolution ? minResolution.value : null,
		seed, procs,
	);

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

	.exportSeenAs = exportSeenAs;

	if (doImport)
	{
		if (subprocess || physical || maxSamples || maxTime || minResolution || prefer || ignore)
			throw new Exception("Conflicting command-line options");

		// Set expert mode from CLI before import.
		// For binary format: CLI controls view mode (data is always complete).
		// For JSON format: importJson will override this based on data availability.
		.expert = expert;

		stderr.writeln("Loading results from file...");
		importData(path);
	}
	else
	{
		fsPath = path.buildNormalizedPath;

		.expert = expert;
		.physical = physical;

		// TODO: respect CLI order (needs std.getopt and ae.utils.funopt changes)
		PathRule[] rules;
		rules ~= prefer.map!(p => PathRule(PathRule.Type.prefer, parsePathPattern(p, fsPath))).array;
		rules ~= ignore.map!(p => PathRule(PathRule.Type.ignore, parsePathPattern(p, fsPath))).array;
		.pathRules = rules;

		if (subprocess)
			return subprocessMain(path, physical, seed);

		checkBtrfs(fsPath, autoMount);

		subprocesses = samplingRun.createWorkers();
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

		// Warn if comparing exports from different filesystems
		if (fsid != typeof(fsid).init && compareFsid != typeof(compareFsid).init && fsid != compareFsid)
		{
			import std.uuid : UUID;
			stderr.writefln("Warning: Filesystem UUID mismatch - comparing different filesystems");
			stderr.writefln("  Current:  %s", UUID(fsid));
			stderr.writefln("  Baseline: %s", UUID(compareFsid));
		}
	}

	Browser browser;
	if (!headless)
	{
		browser.start();
		browser.update();
	}

	samplingRun.startTime = MonoTime.currTime();
	auto refreshInterval = 500.msecs;
	if (refreshIntervalStr)
		refreshInterval = parseDuration(refreshIntervalStr);
	samplingRun.nextRefresh = samplingRun.startTime;

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
	mainLoop: while (run)
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
		samplingRun.reapRetiredWorkers();

		if (browser.curses.stdinSocket && browser.handleInput())
		{
			do
			{
				if (browser.consumeRestartRequest())
				{
					samplingRun.replaceWorkers(subprocesses);
					foreach (i, ref worker; subprocesses)
						worker.start();
					browser.update();
					continue mainLoop;
				}
			}
			while (browser.handleInput()); // Process all input
			if (browser.done)
				break;
			browser.update();
			samplingRun.nextRefresh = now + refreshInterval;
		}

		// Check limits before processing new samples
		if (samplingRun.limitsArmed && (
			(!samplingRun.maxSamples.isNull
				&& browserRoot.getSamples(SampleType.represented) >= samplingRun.maxSamples.get) ||
			(!samplingRun.maxTime.isNull
				&& now >= samplingRun.startTime + samplingRun.maxTime.get) ||
			(samplingRun.minResolution
				&& browserRoot.getSamples(SampleType.represented)
				&& totalSize
				&& (totalSize / browserRoot.getSamples(SampleType.represented)) <= samplingRun.parsedMinResolution(totalSize))))
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
				samplingRun.disarmLimits();
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

		if (!headless && now > samplingRun.nextRefresh)
		{
			browser.update();
			samplingRun.nextRefresh = now + refreshInterval;
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
				MonoTime.currTime() - samplingRun.startTime,
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

mixin main!(funopt!program);
