module btdu.impexp;

import std.conv : to;
import std.math : ceil;
import std.process : environment;
import std.stdio : File, stdout;

import core.lifetime : move;

import ae.sys.data;
import ae.sys.datamm;
import ae.utils.json;

import btdu.common : pointerWriter;
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
