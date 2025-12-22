module btdu.impexp;

import std.algorithm.comparison : max;
import std.algorithm.iteration : filter, map;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.math : abs, ceil;
import std.process : environment;
import std.stdio : File, stdout;

import core.lifetime : move;

import ae.sys.data;
import ae.sys.datamm;
import ae.utils.json;

import btdu.common : humanSize, humanRelSize, pointerWriter;
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

/// Load and parse an exported JSON file.
/// Returns the parsed state structure.
/// The memory-mapped file is stored in the output parameter to keep it alive.
private SerializedState loadExportFile(string path, out Data mmapData)
{
	mmapData = mapFile(path, MmMode.read);
	auto json = cast(string)mmapData.unsafeContents;

	debug importing = true;
	scope(exit) debug importing = false;
	return json.jsonParse!SerializedState();
}

/// Keep memory-mapped files alive, as directory names may reference them
private __gshared Data importMmapData;
private __gshared Data compareMmapData;

void importData(string path)
{
	auto s = loadExportFile(path, importMmapData);

	expert = s.expert;
	physical = s.physical;
	fsPath = s.fsPath;
	totalSize = s.totalSize;
	move(*s.root, browserRoot);

	browserRoot.resetParents();
	imported = true;
}

void importCompareData(string path)
{
	auto s = loadExportFile(path, compareMmapData);

	compareExpert = s.expert;
	comparePhysical = s.physical;
	compareTotalSize = s.totalSize;
	// Note: we don't set fsPath from compare - keep current fsPath
	move(*s.root, compareRoot);

	compareRoot.resetParents();
	compareMode = true;
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
		if (compareMode)
		{
			// Compare mode: show delta
			auto cmp = getCompareResult(path, SampleType.represented);
			auto delta = cmp.deltaSize;
			stdout.writefln!" %s   %s%s"(humanRelSize(delta, true), prefix, label);
		}
		else if (expert)
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

		// In compare mode, also include deleted items from compare tree
		if (compareMode)
		{
			auto compareCurrentPath = findInCompareTree(path);
			if (compareCurrentPath)
			{
				for (auto compareChild = compareCurrentPath.firstChild; compareChild; compareChild = compareChild.nextSibling)
				{
					auto name = compareChild.name[];
					if (!(name in *path))
					{
						// Create placeholder node for deleted item
						auto placeholder = path.appendName(name);
						// Check if it passes threshold (based on delta)
						auto cmp = getCompareResult(placeholder, SampleType.represented);
						if (abs(cmp.deltaSize) >= sizeFromSamples(threshold))
							children ~= placeholder;
					}
				}
			}
		}

		// Sort children by size (largest first)
		if (compareMode)
		{
			// In compare mode, sort by absolute delta
			children.sort!((a, b) {
				auto cmpA = getCompareResult(a, SampleType.represented);
				auto cmpB = getCompareResult(b, SampleType.represented);
				return abs(cmpA.deltaSize) > abs(cmpB.deltaSize);
			});
		}
		else
		{
			children.sort!((a, b) => a.getSamples(SampleType.represented) > b.getSamples(SampleType.represented));
		}

		// Visit children
		foreach (i, child; children)
			visit(child, childIndent, i + 1 == children.length);
	}

	// Print header
	if (compareMode)
	{
		stdout.writeln("     Delta     Path");
	}
	else if (expert)
	{
		stdout.writeln(" Represented  Distributed   Exclusive     Shared     Path");
	}

	visit(&browserRoot, "", true);
}
