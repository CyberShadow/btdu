module btdu.impexp;

import std.algorithm.comparison : max;
import std.algorithm.iteration : filter, map;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.math : abs, ceil;
import std.process : environment;
import std.stdio : File, stdout;
import std.typecons : Nullable, nullable;

import core.lifetime : move;

import ae.sys.data;
import ae.sys.datamm;
import ae.utils.json;

import btdu.binexp : isBinaryFormat, importBinary, exportBinary;
import btdu.common : humanSize, humanRelSize, pointerWriter;
import btdu.paths;
import btdu.state;

/// Export format types
enum ExportFormat
{
	json,   /// Full JSON export with all metadata
	du,     /// du(1) compatible format
	human,  /// Human-readable tree output
	binary, /// Lossless binary format
}

alias imported = btdu.state.imported;

/// Auto-detect import format by inspecting file contents
Nullable!ExportFormat detectFormat(string path)
{
	if (isBinaryFormat(path))
		return ExportFormat.binary.nullable;
	if (isJsonFormat(path))
		return ExportFormat.json.nullable;
	return Nullable!ExportFormat();
}

/// Extension to format mapping for export
enum exportExtensions = [
	".json": ExportFormat.json,
	".du": ExportFormat.du,
	".txt": ExportFormat.human,
	".btdu": ExportFormat.binary,
	".bin": ExportFormat.binary,
];

/// Guess export format from file extension
Nullable!ExportFormat guessExportFormat(string path)
{
	import std.path : extension;
	import std.uni : toLower;

	if (path is null)
		return Nullable!ExportFormat();

	if (auto fmt = path.extension.toLower in exportExtensions)
		return (*fmt).nullable;
	return Nullable!ExportFormat();
}

/// Import data, auto-detecting format
void importData(string path)
{
	auto format = detectFormat(path);
	enforce(!format.isNull,
		"Failed to detect format of file '" ~ path ~ "'. " ~
		"Is this a valid btdu export?"
	);
	switch (format.get)
	{
		case ExportFormat.json:
			return importJson(path);
		case ExportFormat.binary:
			return importBinary(path);
		default:
			assert(false, "Detected an un-importable format");
	}
}

// ============================================================================
// JSON format
// ============================================================================

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

bool isJsonFormat(string path)
{
	import std.file : read;
	auto firstByte = read(path, 1);
	return firstByte == "{";
}

void importJson(string path)
{
	auto s = loadExportFile(path, importMmapData);

	// Check for expert mode mismatch (global expert is set from CLI before import)
	if (expert && !s.expert)
		throw new Exception(
			"--expert was specified but the JSON export was created without expert mode. " ~
			"Expert metrics are not available in this file."
		);

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
	auto format = detectFormat(path);
	enforce(!format.isNull,
		"Failed to detect format of file '" ~ path ~ "'. " ~
		"Is this a valid btdu export?"
	);

	switch (format.get)
	{
		case ExportFormat.json:
			importCompareJson(path);
			break;
		case ExportFormat.binary:
			importBinary(path, DataSet.compare);
			break;
		default:
			assert(false, "Detected an un-importable format");
	}
}

private void importCompareJson(string path)
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

void exportData(string path, ExportFormat fmt = ExportFormat.json)
{
	final switch (fmt)
	{
		case ExportFormat.json:
			exportJson(path);
			break;
		case ExportFormat.du:
			exportDu(path);
			break;
		case ExportFormat.human:
			exportHuman(path);
			break;
		case ExportFormat.binary:
			exportBinary(path);
			break;
	}
}

private void exportJson(string path)
{
	SerializedState s;
	s.expert = expert;
	s.physical = physical;
	s.fsPath = fsPath;
	s.totalSize = totalSize;
	s.root = browserRootPtr;

	alias LockingBinaryWriter = typeof(File.lockingBinaryWriter());
	alias JsonFileSerializer = CustomJsonSerializer!(JsonWriter!LockingBinaryWriter);

	{
		JsonFileSerializer j;
		auto file = path is null ? stdout : File(path, "wb");
		j.writer.output = file.lockingBinaryWriter;
		j.put(s);
	}
}

// ============================================================================
// du format
// ============================================================================

private void exportDu(string path)
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
	auto file = path is null ? stdout : File(path, "w");

	void visit(BrowserPath* p)
	{
		for (auto child = p.firstChild; child; child = child.nextSibling)
			visit(child);

		auto samples = p.getSamples(SampleType.represented);
		auto size = ceil(samples * real(totalSize) / totalSamples / blockSize).to!ulong;
		file.writefln("%d\t%s%s", size, fsPath, p.pointerWriter);
	}
	if (totalSamples)
		visit(browserRootPtr);
}

// ============================================================================
// Human-readable format
// ============================================================================

/// Print a pretty tree of the biggest nodes.
/// In non-expert mode: size and path columns.
/// In expert mode: represented, distributed, exclusive, shared size columns.
private void exportHuman(string path)
{
	auto totalSamples = browserRoot.getSamples(SampleType.represented);
	if (totalSamples == 0)
		return;

	auto file = path is null ? stdout : File(path, "w");

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
	void visit(BrowserPath* p, string indent, bool isLast)
	{
		// Get samples for represented size (primary sort/filter)
		auto samples = p.getSamples(SampleType.represented);

		// Skip nodes below threshold (but always show root)
		if (p !is browserRootPtr && samples < threshold)
			return;

		string prefix, childIndent, label;
		if (p is browserRootPtr)
		{
			prefix = "";
			childIndent = "";
			label = fsPath;
		}
		else
		{
			prefix = indent ~ (isLast ? "└── " : "├── ");
			childIndent = indent ~ (isLast ? "    " : "│   ");
			label = p.humanName.to!string;
		}

		// Format and print the line
		if (compareMode)
		{
			// Compare mode: show delta
			auto cmp = getCompareResult(p, SampleType.represented);
			auto delta = cmp.deltaSize;
			file.writefln!" %s   %s%s"(humanRelSize(delta, true), prefix, label);
		}
		else if (expert)
		{
			// Expert mode: four size columns
			auto represented = sizeFromSamples(samples);
			auto distributed = sizeFromSamples(p.getDistributedSamples());
			auto exclusive = sizeFromSamples(p.getSamples(SampleType.exclusive));
			auto shared_ = sizeFromSamples(p.getSamples(SampleType.shared_));

			file.writefln(" ~%s   ~%s   ~%s   ~%s   %s%s",
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
			file.writefln("%s%s (~%s)", prefix, label, humanSize(size, false));
		}

		// Collect children that pass threshold
		BrowserPath*[] children;
		for (auto child = p.firstChild; child; child = child.nextSibling)
			if (child.getSamples(SampleType.represented) >= threshold)
				children ~= child;

		// In compare mode, also include deleted items from compare tree
		if (compareMode)
		{
			auto compareCurrentPath = findInCompareTree(p);
			if (compareCurrentPath)
			{
				for (auto compareChild = compareCurrentPath.firstChild; compareChild; compareChild = compareChild.nextSibling)
				{
					auto name = compareChild.name[];
					if (!(name in *p))
					{
						// Create placeholder node for deleted item
						auto placeholder = p.appendName(name);
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
		file.writeln("     Delta     Path");
	}
	else if (expert)
	{
		file.writeln(" Represented  Distributed   Exclusive     Shared     Path");
	}

	visit(browserRootPtr, "", true);
}
