module btdu.impexp;

import std.algorithm.comparison : max;
import std.algorithm.iteration : filter, map;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.math : ceil;
import std.process : environment;
import std.stdio : File, stdout;

import core.lifetime : move;

import ae.sys.data;
import ae.sys.datamm;
import ae.utils.json;

import btdu.common : humanSize, pointerWriter;
import btdu.paths;
import btdu.state;

alias imported = btdu.state.imported;

/// Serialized
struct SerializedState
{
	bool expert;
	@JSONOptional bool physical;
	string fsPath;
	ulong totalSize;
	BrowserPath* root;
}

void importData(string path)
{
	__gshared Data importData; // Keep memory-mapped file alive, as directory names may reference it

	importData = mapFile(path, MmMode.read);
	auto json = cast(string)importData.unsafeContents;

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

void exportData(string path)
{
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
		auto file = path == "-" ? stdout : File(path, "wb");
		j.writer.output = file.lockingBinaryWriter;
		j.put(s);
	}
}

void exportDu()
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

	auto totalSamples = browserRoot.getSamples(SampleType.represented);

	void visit(BrowserPath* path)
	{
		for (auto child = path.firstChild; child; child = child.nextSibling)
			visit(child);

		auto samples = path.getSamples(SampleType.represented);
		auto size = ceil(samples * real(totalSize) / totalSamples / blockSize).to!ulong;
		stdout.writefln("%d\t%s%s", size, fsPath, path.pointerWriter);
	}
	if (totalSamples)
		visit(&browserRoot);
}

/// Print a pretty tree of the biggest nodes to stdout.
/// In non-expert mode: size and path columns.
/// In expert mode: represented, distributed, exclusive, shared size columns.
void exportHuman()
{
	auto totalSamples = browserRoot.getSamples(SampleType.represented);
	if (totalSamples == 0)
		return;

	// Threshold: 1% of total size
	auto threshold = totalSamples / 100;
	if (threshold == 0)
		threshold = 1;

	// Calculate size from samples
	real sizeFromSamples(double samples)
	{
		return samples * real(totalSize) / totalSamples;
	}

	// Collect and print nodes recursively
	void visit(BrowserPath* path, string indent, bool isLast)
	{
		// Get samples for represented size (primary sort/filter)
		auto samples = path.getSamples(SampleType.represented);

		// Skip nodes below threshold (but always show root)
		if (path !is &browserRoot && samples < threshold)
			return;

		string prefix, childIndent, label;
		if (path is &browserRoot)
		{
			prefix = "";
			childIndent = "";
			label = fsPath;
		}
		else
		{
			prefix = indent ~ (isLast ? "└── " : "├── ");
			childIndent = indent ~ (isLast ? "    " : "│   ");
			label = path.humanName.to!string;
		}

		// Format and print the line
		if (expert)
		{
			// Expert mode: four size columns
			auto represented = sizeFromSamples(samples);
			auto distributed = sizeFromSamples(path.getDistributedSamples());
			auto exclusive = sizeFromSamples(path.getSamples(SampleType.exclusive));
			auto shared_ = sizeFromSamples(path.getSamples(SampleType.shared_));

			stdout.writefln(" ~%s   ~%s   ~%s   ~%s   %s%s",
				humanSize(represented, true),
				humanSize(distributed, true),
				humanSize(exclusive, true),
				humanSize(shared_, true),
				prefix,
				label,
			);
		}
		else
		{
			// Non-expert mode: single size column
			auto size = sizeFromSamples(samples);
			stdout.writefln("%s%s (~%s)", prefix, label, humanSize(size, false));
		}

		// Collect children that pass threshold
		BrowserPath*[] children;
		for (auto child = path.firstChild; child; child = child.nextSibling)
			if (child.getSamples(SampleType.represented) >= threshold)
				children ~= child;

		// Sort children by size (largest first)
		children.sort!((a, b) => a.getSamples(SampleType.represented) > b.getSamples(SampleType.represented));

		// Visit children
		foreach (i, child; children)
			visit(child, childIndent, i + 1 == children.length);
	}

	// Print header in expert mode
	if (expert)
	{
		stdout.writeln(" Represented  Distributed   Exclusive     Shared     Path");
	}

	visit(&browserRoot, "", true);
}
