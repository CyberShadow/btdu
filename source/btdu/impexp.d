module btdu.impexp;

import std.conv : to;
import std.math : ceil;
import std.process : environment;
import std.stdio : File, stdout;

import core.lifetime : move;

import ae.sys.data;
import ae.sys.datamm;
import ae.utils.json;

import btdu.paths;
import btdu.state;

alias imported = btdu.state.imported;

/// Serialized
struct SerializedState
{
	bool expert;
	@JSONOptional bool physical;
	@JSONOptional bool lowMem;
	string fsPath;
	ulong totalSize;
	BrowserPathPtr root;
}

void importData(string path)
{
	__gshared Data importData; // Keep memory-mapped file alive, as directory names may reference it

	importData = mapFile(path, MmMode.read);
	auto json = cast(string)importData.unsafeContents;

	debug importing = true;
	auto s = json.jsonParse!SerializedState();

	samplingConfiguration = cast(SamplingConfiguration)(
		(s.expert ? SamplingConfiguration.expert : 0) |
		(s.physical ? SamplingConfiguration.physical : 0) |
		(s.lowMem ? 0 : SamplingConfiguration.extras)
	);

	fsPath = s.fsPath;
	totalSize = s.totalSize;
	move(s.root, browserRoot);

	browserRoot.resetParents();
	debug importing = false;
	imported = true;
}

void exportData(string path)
{
	SerializedState s;
	s.expert = samplingConfiguration.has.expert;
	s.physical = samplingConfiguration.has.physical;
	s.lowMem = !samplingConfiguration.has.extras;
	s.fsPath = fsPath;
	s.totalSize = totalSize;
	s.root = browserRoot;

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

	auto totalSamples = browserRoot.getSampleCount(SampleType.represented);

	void visit(BrowserPathPtr path)
	{
		for (auto child = path.firstChild; child; child = child.nextSibling)
			visit(child);

		auto samples = path.getSampleCount(SampleType.represented);
		auto size = ceil(samples * real(totalSize) / totalSamples / blockSize).to!ulong;
		stdout.writefln("%d\t%s%s", size, fsPath, path);
	}
	if (totalSamples)
		visit(browserRoot);
}
