/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2024, 2025, 2026  Vladimir Panteleev <btdu@cy.md>
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

/// Path manipulation and storage
module btdu.paths;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.array : array;
import std.bitmanip;
import std.exception : enforce;
import std.experimental.allocator : makeArray, make;
import std.range;
import std.range.primitives;
import std.string;
import std.traits : Unqual, EnumMembers;
import std.typecons : Nullable, nullable;

import containers.hashmap;
import containers.internal.hash : generateHash;

import ae.utils.appender;
import ae.utils.array : nonNull;
import ae.utils.json : JSONName, JSONOptional, JSONFragment;
import ae.utils.meta;
import ae.utils.path.glob;

import btdu.alloc;
import btdu.state : allocatorFor, RootInfo, getRootInfo;

public import btdu.proto : Offset;

alias PathPattern = CompiledGlob!char[];

struct PathRule
{
	enum Type
	{
		prefer,
		ignore,
	}

	Type type;
	PathPattern pattern;
}

private static doubleGlob = compileGlob("**");

/// Check if a PathPattern is literal (no wildcards except the trailing **)
bool isLiteral(PathPattern pattern) @nogc
{
	// PathPattern has doubleGlob at the beginning (after reverse), so check all but the first
	if (pattern.length <= 1)
		return true;
	foreach (glob; pattern[1 .. $])
		if (!glob.isLiteral())
			return false;
	return true;
}

PathPattern parsePathPattern(string p, string fsPath)
{
	import std.path : buildNormalizedPath, absolutePath, pathSplitter;

	// Normalize both paths for comparison
	auto normalizedPattern = p.absolutePath.buildNormalizedPath;
	auto normalizedFsPath = fsPath.absolutePath.buildNormalizedPath;

	// Split paths into segments for proper comparison
	string[] patternSegments = normalizedPattern.pathSplitter.array;
	string[] fsPathSegments = normalizedFsPath.pathSplitter.array;

	enforce(patternSegments.length, "Path pattern cannot be empty");
	enforce(patternSegments.startsWith("/"), "Path pattern must be an absolute path");

	auto relativePattern = {
		bool startsWithFsPath = equal(fsPathSegments, patternSegments.take(fsPathSegments.length));

		if (startsWithFsPath)
			return patternSegments[fsPathSegments.length .. $];
		else
		{
			import std.stdio : stderr;
			stderr.writefln("Warning: --prefer/--ignore path '%s' does not start with '%s', assuming you meant '%s%s'",
				normalizedPattern, normalizedFsPath, normalizedFsPath, normalizedPattern);
			return patternSegments[1 .. $]; // already relative to fsPath
		}
	}();

	auto parts = relativePattern.map!compileGlob.array;
	parts ~= doubleGlob; // Implied prefix match
	parts.reverse(); // Path nodes are stored as a tree and traversed leaf-to-root
	return parts;
}

/// Ordered prefer/ignore rules. First match wins.
__gshared PathRule[] pathRules;

/// Represents a group of paths that share the same extent
struct SharingGroup
{
	BrowserPath* root;     /// The root BrowserPath for all filesystem paths
	GlobalPath[] paths;    /// All filesystem paths that share this extent
	SampleData data;       /// Sampling statistics for this extent
	ulong[historySize] lastSeen; /// Counter snapshots of the last 3 times we've seen this extent

	/// Additional per-path data - one item per GlobalPath
	struct PathData
	{
		/// Direct pointer to the corresponding BrowserPath
		BrowserPath* path;
		/// Link to next SharingGroup for a specific BrowserPath
		SharingGroup* next;
	}
	PathData* pathData;    /// ditto
	size_t representativeIndex;  /// Index of the representative path in paths array

	/// Find the index of a path matching the given element range
	/// Returns size_t.max if not found
	size_t findIndex(R)(R elementRange) const
	{
		import std.algorithm.comparison : equal;
		foreach (i, ref path; this.paths)
		{
			auto sp = const SamplePath(root, path);
			if (equal(elementRange, sp.elementRange))
				return i;
		}
		return size_t.max;
	}

	/// Find the index of a path by BrowserPath pointer (O(n) but no string comparison)
	/// Returns size_t.max if not found
	size_t findIndex(const(BrowserPath)* browserPath) const
	{
		foreach (i; 0 .. this.paths.length)
			if (this.pathData[i].path is browserPath)
				return i;
		return size_t.max;
	}

	/// Find the next group pointer for a given element range
	/// Returns null if the element range doesn't match any path in this group
	inout(SharingGroup)* getNext(R)(R elementRange) inout
	{
		auto index = findIndex(elementRange);
		return index != size_t.max ? this.pathData[index].next : null;
	}

	/// Find the next group pointer by BrowserPath pointer (faster than elementRange version)
	inout(SharingGroup)* getNext(const(BrowserPath)* browserPath) inout
	{
		auto index = findIndex(browserPath);
		return index != size_t.max ? this.pathData[index].next : null;
	}

	/// Count how many times a BrowserPath appears in this sharing group's pathData.
	/// This handles the case where the same file uses the same extent multiple times.
	size_t countOccurrences(const(BrowserPath)* browserPath) const
	{
		size_t count = 0;
		foreach (i; 0 .. this.paths.length)
			if (this.pathData[i].path is browserPath)
				count++;
		return count;
	}

	/// Merge another group's sample data into this one.
	/// Offsets are merged based on lastSeen timestamps, keeping the most recent ones.
	void mergeFrom(const(SharingGroup)* other)
	{
		this.data.samples += other.data.samples;
		this.data.duration += other.data.duration;

		// Merge offsets based on lastSeen timestamps
		foreach (i; 0 .. historySize)
		{
			if (other.data.offsets[i] == Offset.init)
				continue;

			auto otherLastSeen = other.lastSeen[i];
			// Check if this is more recent than our oldest (index 0)
			if (otherLastSeen > this.lastSeen[0])
			{
				// Find insertion point (keep sorted ascending by lastSeen)
				size_t insertAt = 0;
				foreach (j; 1 .. historySize)
					if (otherLastSeen > this.lastSeen[j])
						insertAt = j;

				// Shift older entries down
				foreach_reverse (j; 0 .. insertAt)
				{
					this.data.offsets[j] = this.data.offsets[j + 1];
					this.lastSeen[j] = this.lastSeen[j + 1];
				}

				// Insert new entry
				this.data.offsets[insertAt] = other.data.offsets[i];
				this.lastSeen[insertAt] = otherLastSeen;
			}
		}
	}

	/// Wrapper type for hashing/equality based on root and paths
	/// Used as key in HashSet for deduplication
	static struct Paths
	{
		SharingGroup* group;

		bool opEquals(const ref Paths other) const
		{
			import std.algorithm.comparison : equal;
			return group.root is other.group.root
				&& equal(group.paths, other.group.paths);
		}

		static size_t hashOf(const ref Paths key)
		{
			import containers.internal.hash : generateHash;
			// Combine root pointer and paths array hashes
			size_t h = cast(size_t)key.group.root;
			h ^= generateHash(key.group.paths);
			return h;
		}
	}
}

/// Common definitions for a deduplicated trie for paths.
mixin template SimplePath()
{
	// Size selected empirically
	alias NameString = InlineString!23;

	/// Parent directory
	typeof(this)* parent;
	/// Directory items, if any
	typeof(this)* firstChild;
	/// Next item in the parent directory, if any
	typeof(this)* nextSibling;
	/// Base name
	/// Names prefixed with a NUL character indicate "special" nodes,
	/// which do not correspond to a filesystem path.
	immutable NameString name;

	/*private*/ this(typeof(this)* parent, NameString name)
	{
		this.parent = parent;
		this.name = name;
	}

	// Returns pointer to pointer to child, or pointer to where it should be added.
	private inout(typeof(this)*)* find(in char[] name) inout
	{
		inout(typeof(this)*)* child;
		for (child = &firstChild; *child; child = &(*child).nextSibling)
			if ((*child).name[] == name)
				break;
		return child;
	}

	inout(typeof(this)*) opBinaryRight(string op : "in")(in char[] name) inout { return *find(name); }
	ref inout(typeof(this)) opIndex(in char[] name) inout { return *(name in this); }

	debug invariant
	{
		import btdu.state : importing;
		if (importing)
			return;
		if (name)
		{
			assert(parent !is null, "Named node without parent");
			// assert((*parent)[name.toString()] is &this, "Child/parent mismatch");
		}
		else // root
			assert(!parent, "Unnamed node with parent");
	}

	/// Append a single path segment to this one.
	typeof(this)* appendName(bool existingOnly = false)(in char[] name)
	{
		assert(name.length, "Empty path segment");
		assert(name.indexOf('/') < 0, "Path segment contains /: " ~ name);
		auto ppnext = find(name);
		if (auto pnext = *ppnext)
			return pnext;
		else
			static if (existingOnly)
				return null;
			else
				return *ppnext = allocatorFor!(typeof(this)).make!(typeof(this))(&this, NameString(name));
	}

	/// ditto
	private typeof(this)* appendName(bool existingOnly = false)(NameString name)
	{
		auto ppnext = find(name[]);
		if (auto pnext = *ppnext)
			return pnext;
		else
			static if (existingOnly)
				return null;
			else
				return *ppnext = allocatorFor!(typeof(this)).make!(typeof(this))(&this, name);
	}

	/// Append a normalized relative string path to this one.
	typeof(this)* appendPath(bool existingOnly = false)(in char[] path)
	{
		auto p = path.indexOf('/');
		auto nextName = p < 0 ? path : path[0 .. p];
		auto next = appendName!existingOnly(nextName);
		if (p < 0)
			return next;
		else
			return next.appendPath!existingOnly(path[p + 1 .. $]);
	}

	/// ditto
	typeof(this)* appendPath(bool existingOnly = false)(in SubPath* path)
	{
		typeof(this)* recurse(typeof(this)* base, in SubPath* path)
		{
			if (!path.parent) // root
				return base;
			base = recurse(base, path.parent);
			static if (existingOnly)
				if (base is null)
					return null;
			return base.appendName!existingOnly(path.name);
		}

		return recurse(&this, path);
	}

	/// ditto
	typeof(this)* appendPath(bool existingOnly = false)(in GlobalPath* path)
	{
		typeof(this)* recurse(typeof(this)* base, in GlobalPath* path)
		{
			if (path.parent)
				base = recurse(base, path.parent);
			static if (existingOnly)
				if (base is null)
					return null;
			return base.appendPath!existingOnly(path.subPath);
		}

		return recurse(&this, path);
	}

	/// Perform the reverse operation, returning a parent path,
	/// or `null` if `path` is not a suffix of `this`.
	typeof(this)* unappendPath(in SubPath* path)
	{
		typeof(this)* recurse(typeof(this)* base, in SubPath* path)
		{
			if (!path.parent) // root
				return base;
			if (!base.parent)
				return null;
			if (path.name[] != base.name[])
				return null;
			return recurse(base.parent, path.parent);
		}

		return recurse(&this, path);
	}

	/// ditto
	typeof(this)* unappendPath(in GlobalPath* path)
	{
		typeof(this)* recurse(typeof(this)* base, in GlobalPath* path)
		{
			if (!path) // root
				return base;
			base = base.unappendPath(path.subPath);
			if (!base)
				return null;
			return recurse(base, path.parent);
		}

		return recurse(&this, path);
	}

	/// Return an iterator for path fragments.
	/// Iterates from inner-most to top level.
	auto range() const
	{
		alias This = typeof(this)*;
		static struct Range
		{
		@nogc:
			This p;
			bool empty() const { return !p; }
			string front() { return p.name[]; }
			void popFront() { p = p.parent; }
		}
		return Range(&this);
	}

	/// Return an iterator for path element strings.
	/// For SimplePath types, this is the same as range().
	auto elementRange() const { return this.range; }

	void toString(scope void delegate(const(char)[]) sink) const
	{
		if (parent)
		{
			parent.toString(sink);
			sink("/");
		}
		humanName.toString(sink);
	}

	auto humanName() const
	{
		struct HumanName
		{
			string name;
			void toString(scope void delegate(const(char)[]) sink) const
			{
				if (name.startsWith("\0"))
				{
					sink("<");
					sink(name[1 .. $]);
					sink(">");
				}
				else
					sink(name);
			}
		}
		return HumanName(name[]);
	}
}

/// Common operations for linked-list-like path structures
mixin template PathCommon()
{
	/// Returns the total length of this path chain,
	/// including this instance.
	private size_t chainLength() const
	{
		return 1 + (parent ? parent.chainLength() : 0);
	}

	/// Returns the common prefix of `paths`.
	/// Assumes that if two pointers are different, they point at different paths.
	/// Destructively mutates `paths` as scratch space.
	static typeof(this)* commonPrefix(typeof(this)*[] paths)
	{
		// First, calculate the lengths
		static StaticAppender!size_t lengths;
		lengths.clear();
		foreach (ref path; paths)
			lengths.put(path.chainLength);

		// Rewind all paths to the minimal path's length
		auto minLength = lengths.peek().reduce!min;
		foreach (i, ref path; paths)
			while (lengths.peek()[i] > minLength)
			{
				lengths.peek()[i]--;
				path = path.parent;
			}

		// Rewind all paths until the tip points at the same thing
		while (paths.any!(path => path !is paths[0]))
			foreach (ref path; paths)
				path = path.parent;

		// All paths now point at the same thing.
		return paths[0];
	}

	/// Get the path length in characters
	size_t length() const
	{
		size_t len = 0;
		toString((const(char)[] s) { len += s.length; });
		return len;
	}

	/// Check if this path matches a pattern (for preferred/ignored paths)
	bool matches(PathPattern pattern) const @nogc
	{
		return pathMatches(this.elementRange, pattern);
	}

	/// Check if a path exactly matches a pattern (not just a prefix match via **).
	/// Patterns always start with ** followed by path segment compiled globs.
	/// Slicing off the ** and matching checks for exact path match.
	bool matchesExactly(PathPattern pattern) const @nogc
	{
		assert(pattern.length > 0 && pattern[0] is doubleGlob, "Pattern is empty or does not start with double glob");
		return pattern.isLiteral() && this.matches(pattern[1 .. $]);
	}

	/// Check if this path has resolved roots (no TREE_ markers)
	private bool isResolved() const
	{
		import std.algorithm.searching : canFind, startsWith;
		return !this.elementRange.canFind!(n => n.startsWith("\0TREE_"));
	}
}

/// Implements comparison for linked-list-like path structures.
/// Requires `PathCommon` and a `compareContents` definition.
mixin template PathCmp()
{
	int opCmp(const ref typeof(this) b) const
	{
		if (this is b)
			return 0;

		// Because the lengths may be uneven, query them first
		auto aLength = this.chainLength();
		auto bLength = b   .chainLength();
		auto maxLength = max(aLength, bLength);

		// We are starting from the tail end of two
		// linked lists with possibly different length
		int recurse(
			// The tail so far
			in typeof(this)*[2] paths,
			// How many nodes this side is "shorter" by
			size_t[2] rem,
		)
		{
			if (paths[0] is paths[1])
				return 0; // Also covers the [null, null] case which stops recursion

			// What we will recurse with
			const(typeof(this))*[2] recPaths;
			size_t[2] recRem;
			// What we will compare in this step (if recursion returns 0)
			const(typeof(this))*[2] thisPaths;

			foreach (n; 0 .. 2)
			{
				if (rem[n])
				{
					thisPaths[n] = null;
					recPaths[n] = paths[n];
					recRem[n] = rem[n] - 1;
				}
				else
				{
					thisPaths[n] = paths[n];
					recPaths[n] = paths[n].parent;
					recRem[n] = 0;
				}
			}

			int res = recurse(recPaths, recRem);
			if (res)
				return res;

			if ((thisPaths[0] is null) != (thisPaths[1] is null))
				return thisPaths[0] is null ? -1 : 1;
			return thisPaths[0].compareContents(*thisPaths[1]);
		}
		return recurse([&this, &b], [
			maxLength - aLength,
			maxLength - bLength,
		]);
	}
}

/// Path within a tree (subvolume)
struct SubPath
{
	mixin SimplePath;
	mixin PathCommon;
	mixin PathCmp;

	/// PathCmp implementation
	private int compareContents(const ref typeof(this) b) const
	{
		return cmp(name[], b.name[]);
	}
}

/// Global path (spanning multiple trees)
/// This is to allow efficiently representing paths where the prefix
/// (subvolume path) varies, e.g.:
/// - /@root/usr/lib/libfoo.so.1.0.0
/// - /backups/@root-20200101000000/usr/lib/libfoo.so.1.0.0
/// - /backups/@root-20200102000000/usr/lib/libfoo.so.1.0.0
/// etc.
/// Here we can store /backups/@root-20200102000000 etc. as one
/// SubPath and /usr/lib/libfoo.so.1.0.0 as another, with the
/// GlobalPath representing a concatenation of the two.
struct GlobalPath
{
	GlobalPath* parent; /// Parent tree (or null if none)
	SubPath* subPath;   /// Path within this filesystem

	void toString(scope void delegate(const(char)[]) sink) const
	{
		if (parent)
			parent.toString(sink);
		subPath.toString(sink);
	}

	size_t length() const
	{
		size_t length = 0;
		toString((const(char)[] s) { length += s.length; });
		return length;
	}

	/// PathCmp implementation
	private int compareContents(const ref typeof(this) b) const
	{
		return subPath.opCmp(*b.subPath);
	}

	/// Return an iterator for subpaths.
	/// Iterates from inner-most to top level.
	auto range() const
	{
		static struct Range
		{
		@nogc:
			const(GlobalPath)* p;
			bool empty() const { return !p; }
			const(SubPath)* front() { return p.subPath; }
			void popFront() { p = p.parent; }
		}
		return Range(&this);
	}

	/// Return an iterator for path element strings (flattened).
	/// Iterates from inner-most to top level.
	auto elementRange() const
	{
		import std.algorithm.iteration : map, joiner;
		return this.range
			.map!(g => g
				.range
				.filter!(s => s.length)
			)
			.joiner;
	}

	mixin PathCommon;
	mixin PathCmp;
}

/// Sample path (BrowserPath root + GlobalPath)
/// Combines a BrowserPath prefix (containing special flags like \0DATA)
/// with a GlobalPath (filesystem path) to provide the same path semantics
/// as BrowserPath, but as a non-materialized rvalue.
struct SamplePath
{
	BrowserPath* root;      /// Root BrowserPath containing special flags
	GlobalPath globalPath;  /// Filesystem path

	void toString(scope void delegate(const(char)[]) sink) const
	{
		if (root)
			root.toString(sink);
		globalPath.toString(sink);
	}

	size_t length() const
	{
		size_t length = 0;
		toString((const(char)[] s) { length += s.length; });
		return length;
	}

	/// Return an iterator for path element strings (flattened).
	/// Matches BrowserPath.elementRange semantics by including special flags from root.
	auto elementRange() const
	{
		return chain(globalPath.elementRange, root.elementRange);
	}

	/// Comparison operator
	int opCmp(const ref typeof(this) b) const
	{
		// First compare roots
		if (root !is b.root)
		{
			if (!root) return -1;
			if (!b.root) return 1;
			auto rootCmp = root.opCmp(*b.root);
			if (rootCmp != 0) return rootCmp;
		}
		// Then compare GlobalPaths
		return globalPath.opCmp(b.globalPath);
	}

	/// Check if this path matches a pattern (for preferred/ignored paths)
	bool matches(PathPattern pattern) const @nogc
	{
		return pathMatches(this.elementRange, pattern);
	}

	/// Check if this path has resolved roots (no TREE_ markers)
	private bool isResolved() const
	{
		import std.algorithm.searching : canFind, startsWith;
		return !this.elementRange.canFind!(n => n.startsWith("\0TREE_"));
	}
}

enum SampleType
{
	represented,
	exclusive,
	shared_,
}

enum Mark : ubyte
{
	parent,    /// Default state - see parent
	marked,    /// Positive mark
	unmarked,  /// Negative mark (cancels out a positive mark in an ancestor)
}

/// How many of the most recent samples we track
enum historySize = 3;

/// Aggregated sampling statistics for an extent or path
struct SampleData
{
	ulong samples; /// Number of samples
	ulong duration; /// Total hnsecs
	Offset[historySize] offsets; /// Examples (the last 3 seen) of sample offsets

	/// Add samples to this data
	void add(ulong samples, const(Offset)[] offsets, ulong duration)
	{
		this.samples += samples;
		this.duration += duration;
		foreach (offset; offsets)
			if (offset != Offset.init)
				// Add new offsets at the end, pushing existing ones towards 0
				foreach (i; 0 .. this.offsets.length)
					this.offsets[i] = i + 1 == SampleData.offsets.length
						? offset
						: this.offsets[i + 1];
	}

	/// Remove samples from this data
	void remove(ulong samples, const(Offset)[] offsets, ulong duration)
	{
		import std.algorithm.searching : canFind;
		assert(samples <= this.samples && duration <= this.duration,
			format!"Removing more samples/duration than present: %d/%d samples, %d/%d duration"(
				samples, this.samples, duration, this.duration));
		this.samples -= samples;
		this.duration -= duration;
		foreach (i; 0 .. this.offsets.length)
			if (this.offsets[i] != Offset.init && offsets.canFind(this.offsets[i]))
				// Delete matching offsets, pushing existing ones from the start towards the end
				foreach_reverse (j; 0 .. i + 1)
					this.offsets[j] = j == 0
						? Offset.init
						: this.offsets[j - 1];
	}
}

/// Aggregate sampling data for a BrowserPath
struct AggregateData
{
	SampleData[enumLength!SampleType] data;
	double distributedSamples = 0;
	double distributedDuration = 0;
}

/// Browser path (GUI hierarchy)
struct BrowserPath
{
	mixin SimplePath;
	mixin PathCommon;

	mixin PathCmp;

	/// PathCmp implementation
	private int compareContents(const ref typeof(this) b) const
	{
		return cmp(name[], b.name[]);
	}

	private AggregateData* aggregateData;
	private bool deleting;

	/// Ensure aggregateData is allocated, allocating if needed.
	/// When first allocated, migrates dynamically-computed values into it.
	private AggregateData* ensureAggregateData()
	{
		if (!aggregateData)
		{
			// Allocate to a local first, so getSamples/etc still see this.aggregateData
			// as null and return values from children/sharing groups.
			auto aggregateData = growAllocator.make!AggregateData();

			// Capture current dynamically-computed values before allocation
			static foreach (type; EnumMembers!SampleType)
			{
				aggregateData.data[type].samples = getSamples(type);
				aggregateData.data[type].duration = getDuration(type);
				aggregateData.data[type].offsets = getOffsets(type);
			}
			aggregateData.distributedSamples = getDistributedSamples();
			aggregateData.distributedDuration = getDistributedDuration();

			this.aggregateData = aggregateData;
		}
		return aggregateData;
	}

	/// Returns the number of relevant occurrences for a given sample type.
	/// Returns 0 if the group is not relevant for this sample type.
	/// Note: Tombstone sharing groups (with data.samples == 0, created by deletion/eviction)
	/// are automatically handled because callers either multiply by group.data.samples
	/// (making the result 0), or check truthiness (making tombstone sharing groups
	/// synonymous with irrelevant groups).
	private size_t relevantOccurrences(const(SharingGroup)* group, SampleType type) const
	{
		// Count how many times this path appears in the sharing group
		// (same file may use same extent multiple times)
		auto occurrences = group.countOccurrences(&this);

		final switch (type)
		{
			case SampleType.shared_:
				// All samples that touch this path
				return occurrences;
			case SampleType.represented:
				// Samples where this path is the representative
				return group.pathData[group.representativeIndex].path is &this ? occurrences : 0;
			case SampleType.exclusive:
				// Samples exclusive to this path: ALL entries in the group must be this path
				return occurrences == group.paths.length ? occurrences : 0;
		}
	}

	debug(check) void checkState() const
	{
		import btdu.state : rebuildInProgress, compareMode, deletionOccurred;

		// Check children first (because our validity depends on theirs)
		for (const(BrowserPath)* p = firstChild; p; p = p.nextSibling)
			p.checkState();

		// A node cannot have both sharing groups and children
		assert(!(firstSharingGroup && firstChild),
			"%s: Node has both sharing groups and children".format(this));

		// Root and special nodes may be temporarily inconsistent
		// while we are in the middle of processing a message
		auto isRoot = !parent;
		auto isSpecial = name[].startsWith("\0");
		if (!isRoot && !isSpecial)
		{
			// During rebuild, sharing groups are cleared then re-linked one by one,
			// so leaf nodes temporarily have neither children nor sharing groups.
			// Skip this check during rebuild.
			// In compare mode, placeholder nodes (created by the browser to enforce
			// tree symmetry) may exist for items only in the compare baseline -
			// these legitimately have no sharing groups.
			// After deletion, empty directories may remain with no children and no
			// sharing groups - skip this check if deletion has occurred.
			if (!rebuildInProgress() && !compareMode && !deletionOccurred)
			{
				// Non-root nodes must have either children or sharing groups
				assert(firstChild || firstSharingGroup,
					"%s: Non-root non-special node has neither children nor sharing groups".format(this));
			}

			// aggregateData check: tree structure doesn't change during rebuild,
			// so multi-child nodes should always have aggregateData.
			assert(hasCorrectAggregateDataState,
				"%s: aggregateData state mismatch: needsAggregateData = %s, but aggregateData %s null. Node has %s and %s"
					.format(
						this, needsAggregateData, aggregateData ? "is not" : "is",
						!firstChild ? "no children" : !firstChild.nextSibling ? "one child" : "multiple children",
						firstSharingGroup ? "sharing groups" : "no sharing groups"
					));
		}

		// For nodes with aggregateData, verify it matches children's samples
		// Skip during rebuild since samples are being recomputed
		if (aggregateData && !rebuildInProgress())
		{
			ulong total = 0;
			for (const(BrowserPath)* p = firstChild; p; p = p.nextSibling)
				total += p.getSamples(SampleType.represented);
			assert(total == aggregateData.data[SampleType.represented].samples,
				"%s: Represented samples mismatch: aggregate data has %d, but children have %d (node has %s)"
					.format(
						this, aggregateData.data[SampleType.represented].samples, total,
						!firstChild ? "no children" : !firstChild.nextSibling ? "one child" : "multiple children"
					));
		}

		// Check sharing group linkage
		{
			size_t numGroups;
			const(SharingGroup)* previouslySeenGroup;
			for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(&this))
			{
				numGroups++;
				if ((numGroups & (numGroups - 1)) == 0) // at every power of 2
					previouslySeenGroup = group;
				else
				if (previouslySeenGroup && previouslySeenGroup is group)
					assert(false, "%s: Sharing group %s appears twice".format(this, group));
			}
		}
	}

	private R getData(R)(
		scope R delegate() fromAggregate,
		scope R delegate() fromSharingGroups,
		scope R delegate() fromChildren,
	) const {
		// Use aggregate data if available
		if (aggregateData)
			return fromAggregate();

		// Leaf nodes compute from sharing groups
		if (firstSharingGroup)
			return fromSharingGroups();

		// Sum children when:
		// - There is only one child (no need to aggregate)
		// - There are multiple children while we are migrating to aggregateData
		// - The tree is brand new, so there is only one node,
		//   and no samples, sharing groups, or children
		return fromChildren();
	}

	/// Get the number of samples for a given sample type
	ulong getSamples(SampleType type) const
	{
		return getData!ulong(
			fromAggregate: () => aggregateData.data[type].samples,
			fromSharingGroups: {
				ulong sum = 0;
				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(&this))
					sum += group.data.samples * relevantOccurrences(group, type);
				return sum;
			},
			fromChildren: {
				ulong sum = 0;
				for (const(BrowserPath)* child = firstChild; child; child = child.nextSibling)
					sum += child.getSamples(type);
				return sum;
			},
		);
	}

	/// Get the duration for a given sample type
	ulong getDuration(SampleType type) const
	{
		return getData!ulong(
			fromAggregate: () => aggregateData.data[type].duration,
			fromSharingGroups: {
				ulong sum = 0;
				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(&this))
					sum += group.data.duration * relevantOccurrences(group, type);
				return sum;
			},
			fromChildren: {
				ulong sum = 0;
				for (const(BrowserPath)* child = firstChild; child; child = child.nextSibling)
					sum += child.getDuration(type);
				return sum;
			},
		);
	}

	/// Get the offsets for a given sample type
	const(Offset[historySize]) getOffsets(SampleType type) const
	{
		return getData!(Offset[historySize])(
			fromAggregate: () => aggregateData.data[type].offsets,
			fromSharingGroups: {
				// Keep track of the most recent offsets (sorted by lastSeen ascending)
				Offset[historySize] result;
				ulong[historySize] resultLastSeen;

				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(&this))
				{
					if (relevantOccurrences(group, type))
					{
						foreach (i; 0 .. historySize)
						{
							if (group.data.offsets[i] == Offset.init)
								continue;

							auto lastSeen = group.lastSeen[i];
							// Check if this is more recent than our oldest (index 0)
							if (lastSeen > resultLastSeen[0])
							{
								// Find insertion point (keep sorted ascending by lastSeen)
								size_t insertAt = 0;
								foreach (j; 1 .. historySize)
									if (lastSeen > resultLastSeen[j])
										insertAt = j;

								// Shift older entries down
								foreach_reverse (j; 0 .. insertAt)
								{
									result[j] = result[j + 1];
									resultLastSeen[j] = resultLastSeen[j + 1];
								}

								// Insert new entry
								result[insertAt] = group.data.offsets[i];
								resultLastSeen[insertAt] = lastSeen;
							}
						}
					}
				}

				return result;
			},
			fromChildren: {
				// Merge offsets from all children
				Offset[historySize] result;
				foreach (i; 0 .. historySize)
					result[i] = Offset.init;

				for (const(BrowserPath)* child = firstChild; child; child = child.nextSibling)
				{
					auto childOffsets = child.getOffsets(type);
					foreach (i; 0 .. historySize)
					{
						if (childOffsets[i] != Offset.init && result[i] == Offset.init)
							result[i] = childOffsets[i];
					}
				}

				return result;
			},
		);
	}

	/// Get the distributed samples
	double getDistributedSamples() const
	{
		return getData!double(
			fromAggregate: () => aggregateData.distributedSamples,
			fromSharingGroups: {
				double sum = 0;
				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(&this))
				{
					// Count how many times this path appears in the sharing group
					// (same file may use same extent multiple times)
					auto occurrences = group.countOccurrences(&this);
					sum += cast(double) group.data.samples * occurrences / group.paths.length;
				}
				return sum;
			},
			fromChildren: {
				double sum = 0;
				for (const(BrowserPath)* child = firstChild; child; child = child.nextSibling)
					sum += child.getDistributedSamples();
				return sum;
			},
		);
	}

	/// Get the distributed duration
	double getDistributedDuration() const
	{
		return getData!double(
			fromAggregate: () => aggregateData.distributedDuration,
			fromSharingGroups: {
				double sum = 0;
				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(&this))
				{
					// Count how many times this path appears in the sharing group
					// (same file may use same extent multiple times)
					auto occurrences = group.countOccurrences(&this);
					sum += cast(double) group.data.duration * occurrences / group.paths.length;
				}
				return sum;
			},
			fromChildren: {
				double sum = 0;
				for (const(BrowserPath)* child = firstChild; child; child = child.nextSibling)
					sum += child.getDistributedDuration();
				return sum;
			},
		);
	}

	/// Reset distributed samples and duration
	void resetDistributedSamples()
	{
		if (aggregateData)
		{
			aggregateData.distributedSamples = 0;
			aggregateData.distributedDuration = 0;
		}
	}

	/// Returns true if this node should store samples in aggregateData.
	private bool needsAggregateData() const
	{
		// Leaf nodes with sharing groups compute samples on-the-fly from those groups
		if (firstSharingGroup)
		{
			assert(!firstChild, "Node has both sharing groups and children");
			return false;
		}

		// Childless nodes (root before first sample, or leaves awaiting sharing groups)
		if (!firstChild)
			return false;

		// Single-child nodes delegate to their only child
		if (!firstChild.nextSibling)
			return false;

		// Nodes with multiple children need aggregateData to aggregate them
		return true;
	}

	/// Returns true if this node's aggregateData state is consistent with its structure.
	/// Allows having aggregateData even when not strictly needed (for special nodes like `marked`).
	private bool hasCorrectAggregateDataState() const
	{
		// If you need aggregateData, you must have it.
		// Having it when not needed is OK (e.g., `marked`).
		return !needsAggregateData || aggregateData;
	}

	/// Update BrowserPath structure after tree modifications (appendPath, linking sharing groups).
	/// This ensures aggregateData is allocated where needed, capturing current state from children.
	/// Must be called before addSamples/addDistributedSample to ensure structure is finalized.
	void updateStructure()
	{
		if (needsAggregateData)
			ensureAggregateData();
		if (parent)
			parent.updateStructure();
	}

	/// Force allocation of aggregateData for special nodes like `marked` that need to store
	/// samples but don't have children or sharing groups.
	void forceAggregateData()
	{
		ensureAggregateData();
	}

	void addSamples(SampleType type, ulong samples, const(Offset)[] offsets, ulong duration)
	{
		assert(hasCorrectAggregateDataState, "updateStructure must be called before addSamples");
		if (aggregateData)
			aggregateData.data[type].add(samples, offsets, duration);
		if (parent)
			parent.addSamples(type, samples, offsets, duration);
	}

	void removeSamples(SampleType type, ulong samples, const(Offset)[] offsets, ulong duration)
	{
		if (aggregateData)
			aggregateData.data[type].remove(samples, offsets, duration);
		if (parent)
			parent.removeSamples(type, samples, offsets, duration);
	}

	void addDistributedSample(double sampleShare, double durationShare)
	{
		assert(hasCorrectAggregateDataState, "updateStructure must be called before addDistributedSample");
		if (aggregateData)
		{
			aggregateData.distributedSamples += sampleShare;
			aggregateData.distributedDuration += durationShare;
		}
		if (parent)
			parent.addDistributedSample(sampleShare, durationShare);
	}

	void removeDistributedSample(double sampleShare, double durationShare)
	{
		addDistributedSample(-sampleShare, -durationShare);
	}

	/// Linked list head pointing to the first sharing group containing this path
	/// Each group represents one extent/sample where multiple paths share data
	SharingGroup* firstSharingGroup;

	struct SeenAs
	{
		size_t[GlobalPath] paths;
		size_t total;
	}

	/// Collect seenAs data from all sharing groups
	/// Returns a map of path string -> sample count
	SeenAs collectSeenAs()
	{
		import std.conv : to;
		SeenAs result;

		// Traverse the linked list of sharing groups
		// Each group represents one extent where multiple paths share data
		for (auto group = firstSharingGroup; group !is null; group = group.getNext(&this))
		{
			// Add all paths in this group to the result
			foreach (ref path; group.paths)
				result.paths[path] += group.data.samples;
			result.total += group.data.samples;
		}

		return result;
	}

	/// Serialized representation
	struct SerializedForm
	{
		string name;

		struct SerializedData
		{
			// Same order as SampleType
			@JSONOptional SampleData represented;
			@JSONOptional SampleData exclusive;
			@JSONName("shared")
			@JSONOptional SampleData shared_;
			@JSONOptional JSONFragment distributedSamples = JSONFragment("0");
			@JSONOptional JSONFragment distributedDuration = JSONFragment("0");
		}
		SerializedData data;
		@JSONOptional Nullable!bool mark;
		@JSONOptional ulong[string] seenAs; // Map: path -> sample count

		BrowserPath*[] children;
	}

	SerializedForm toJSON()
	{
		import std.conv : to;
		import btdu.state : exportSeenAs;

		SerializedForm s;
		s.name = this.name[];
		for (auto p = firstChild; p; p = p.nextSibling)
			s.children ~= p;
		static foreach (sampleType; EnumMembers!SampleType)
		{
			s.data.tupleof[sampleType].samples = getSamples(sampleType);
			s.data.tupleof[sampleType].duration = getDuration(sampleType);
			s.data.tupleof[sampleType].offsets = getOffsets(sampleType);
		}
		if (getDistributedSamples() !is 0.)
			s.data.distributedSamples.json = getDistributedSamples().format!"%17e";
		if (getDistributedDuration() !is 0.)
			s.data.distributedDuration.json = getDistributedDuration().format!"%17e";
		s.mark =
			this.mark == Mark.parent ? Nullable!bool.init :
			this.mark == Mark.marked ? true.nullable :
			false.nullable;
		if (exportSeenAs)
			foreach (path, samples; this.collectSeenAs().paths)
				s.seenAs[path.to!string.nonNull] = samples;
		return s;
	}

	static BrowserPath fromJSON(ref SerializedForm s)
	{
		import std.conv : to;

		auto p = BrowserPath(null, NameString(s.name));
		foreach_reverse (child; s.children)
		{
			child.nextSibling = p.firstChild;
			p.firstChild = child;
		}
		auto aggData = p.ensureAggregateData();
		static foreach (sampleType; EnumMembers!SampleType)
			aggData.data[sampleType] = s.data.tupleof[sampleType];
		aggData.distributedSamples = s.data.distributedSamples.json.strip.to!double;
		aggData.distributedDuration = s.data.distributedDuration.json.strip.to!double;
		p.mark =
			s.mark.isNull() ? Mark.parent :
			s.mark.get() ? Mark.marked :
			Mark.unmarked;
		return p;
	}

	void resetParents()
	{
		for (auto p = firstChild; p; p = p.nextSibling)
		{
			p.parent = &this;
			p.resetParents();
		}
	}

	/// Approximate the effect of deleting the filesystem object represented by the path.
	void remove(bool obeyMarks)
	{
		if (deleting)
			return; // already deleted

		assert(parent, "Cannot remove root node");

		// Mark this subtree for deletion, to aid the rebalancing below.
		markForDeletion(obeyMarks);

		// Delete the subtree recursively.
		doDelete();

		// Mark that deletion has occurred, relaxing certain invariant checks
		debug(check)
		{
			import btdu.state : deletionOccurred;
			deletionOccurred = true;
		}

		// Increment generation so in-flight samples are discarded
		import btdu.state : incrementGeneration;
		incrementGeneration();
	}

	// Mark this subtree for deletion, to aid the rebalancing below.
	private bool markForDeletion(bool obeyMarks)
	{
		if (obeyMarks && mark == Mark.unmarked)
			return false;
		deleting = true;
		for (auto p = firstChild; p; p = p.nextSibling)
			if (!p.markForDeletion(obeyMarks))
				deleting = false;
		return deleting;
	}

	private void doDelete()
	{
		// Evict children first
		for (auto p = firstChild; p; p = p.nextSibling)
			p.doDelete();

		if (!deleting)
			return;

		// Rebalance the hierarchy's statistics by updating and moving sample data as needed.
		evict();

		// Unlink this node, removing it from the tree.
		{
			auto pp = parent.find(this.name[]);
			assert(*pp == &this, "Child/parent mismatch during unlink");
			*pp = this.nextSibling;
		}
	}

	/// Clear all samples or move them elsewhere using un-ingest/edit/re-ingest.
	/// This modifies sharing groups in-place to remove this path.
	private void evict()
	{
		assert(parent, "Cannot evict root node");
		import btdu.state : evictPathFromSharingGroups;
		evictPathFromSharingGroups(&this);
	}

	/// Reset samples for a specific sample type on this node only
	void resetNodeSamples(SampleType type)
	{
		if (aggregateData)
			aggregateData.data[type] = SampleData.init;
	}

	/// Reset all sample data on this node only
	void resetNodeSamples()
	{
		static foreach (sampleType; EnumMembers!SampleType)
			resetNodeSamples(sampleType);
		resetDistributedSamples();
	}

	/// Recursively reset all sample data for this path and its children
	void resetTreeSamples()
	{
		// Recursively reset all children first (depth-first traversal)
		for (auto child = firstChild; child; child = child.nextSibling)
			child.resetTreeSamples();

		// Reset this node
		resetNodeSamples();
	}

	/// Recursively clear all sharing group links for this path and its children
	private void clearSharingGroupLinks()
	{
		firstSharingGroup = null;
		for (auto child = firstChild; child; child = child.nextSibling)
			child.clearSharingGroupLinks();
	}

	/// Reset this path tree for rebuild: clears all sample data and sharing group links
	void reset()
	{
		resetTreeSamples();
		clearSharingGroupLinks();
	}

	@property bool deleted() { return deleting; }

	// Marks

	mixin(bitfields!(
		Mark , q{mark}            , 2,
		ubyte, null               , 5,
		bool , q{childrenHaveMark}, 1,
	));

	/// Returns the mark as it is inherited from the parent, if any.
	private bool getParentMark() const
	{
		return parent ? parent.getEffectiveMark() : false;
	}

	/// Returns true for marked, false for unmarked.
	bool getEffectiveMark() const
	{
		final switch (mark)
		{
			case Mark.parent:
				return getParentMark();
			case Mark.marked:
				return true;
			case Mark.unmarked:
				return false;
		}
	}

	private void clearMark()
	{
		mark = Mark.parent;
		if (childrenHaveMark)
		{
			for (auto p = firstChild; p; p = p.nextSibling)
				p.clearMark();
			childrenHaveMark = false;
		}
	}

	private void setMarkWithoutChildren(bool marked)
	{
		if (getParentMark() == marked)
		{
			mark = Mark.parent;
			return;
		}
		mark = marked ? Mark.marked : Mark.unmarked;
		for (auto p = parent; p && !p.childrenHaveMark; p = p.parent)
			p.childrenHaveMark = true;
	}

	void setMark(bool marked)
	{
		clearMark();
		assert(mark == Mark.parent, "clearMark did not reset mark to parent");
		setMarkWithoutChildren(marked);
	}

	void enumerateMarks(scope void delegate(BrowserPath*, bool marked, scope void delegate() recurse) callback)
	{
		void recurse()
		{
			if (childrenHaveMark)
				for (auto p = firstChild; p; p = p.nextSibling)
					p.enumerateMarks(callback);
		}

		if (mark != Mark.parent)
			callback(&this, mark == Mark.marked, &recurse);
		else
			recurse();
	}

	void enumerateMarks(scope void delegate(BrowserPath*, bool marked) callback)
	{
		enumerateMarks((BrowserPath* path, bool marked, scope void delegate() recurse) { callback(path, marked); recurse(); });
	}
}

/// Core pattern matching logic for path ranges
/// Works with any range of strings representing path components
bool pathMatches(R)(R r, PathPattern pattern) @nogc
{
	if (pattern.empty && r.empty)
		return true;
	if (r.empty)
		return false;
	if (r.front.length == 0 || r.front.startsWith("\0"))
		return pathMatches(r.dropOne, pattern); // Skip special nodes
	if (pattern.empty)
		return false;
	if (pattern.front == doubleGlob)
	{
		pattern.popFront();
		while (!r.empty)
		{
			if (pathMatches(r, pattern))
				return true;
			r.popFront();
		}
		return false;
	}
	if (pattern.front.match(r.front))
		return pathMatches(r.dropOne, pattern.dropOne);
	return false;
}

/// Returns true if path 'a' is more representative than path 'b'
/// This is the full comparison logic for representativeness ordering
/// Works with both GlobalPath and BrowserPath
bool isMoreRepresentative(ref GlobalPath a, ref GlobalPath b)
{
	// Process path rules sequentially in order
	foreach (rule; pathRules)
	{
		bool aMatches = a.matches(rule.pattern);
		bool bMatches = b.matches(rule.pattern);

		if (aMatches != bMatches)
		{
			// One matches, the other doesn't
			if (rule.type == PathRule.Type.prefer)
				return aMatches; // Prefer the matching path
			else // rule.type == PathRule.Type.ignore
				return bMatches; // Prefer the non-matching path (i.e., not ignored)
		}
		// Both match or neither matches - continue to next rule
	}
	// Prefer paths with resolved roots
	auto aResolved = a.isResolved();
	auto bResolved = b.isResolved();
	if (aResolved != bResolved)
		return aResolved;

	// Snapshot-aware selection (for GlobalPath with rootInfo)
	{
		// Get root info via state module's lookup table
		auto aRootInfo = getRootInfo(&a);
		auto bRootInfo = getRootInfo(&b);

		// Prefer read-only (snapshot) over read-write (original)
		// This puts data under snapshots, showing chronological usage
		auto aReadOnly = aRootInfo ? aRootInfo.isReadOnly : false;
		auto bReadOnly = bRootInfo ? bRootInfo.isReadOnly : false;
		if (aReadOnly != bReadOnly)
			return aReadOnly;

		// If both have same read-only status, prefer older (smaller otime)
		// This shows data under the earliest snapshot containing it
		auto aOtime = aRootInfo ? aRootInfo.otime : 0;
		auto bOtime = bRootInfo ? bRootInfo.otime : 0;
		if (aOtime != bOtime && aOtime != 0 && bOtime != 0)
			return aOtime < bOtime;
	}

	// Shortest path wins
	auto aLength = a.length;
	auto bLength = b.length;
	if (aLength != bLength)
		return aLength < bLength;

	// If the length is the same, pick the lexicographically smallest one
	return a < b;
}

GlobalPath selectRepresentativePath(GlobalPath[] paths)
{
	return paths.fold!((a, b) {
		return isMoreRepresentative(a, b) ? a : b;
	})();
}

/// Find the index of the most representative path in an array.
/// Returns size_t.max if the array is empty.
size_t selectRepresentativeIndex(GlobalPath[] paths)
{
	if (paths.length == 0)
		return size_t.max;

	size_t bestIndex = 0;
	foreach (i; 1 .. paths.length)
		if (isMoreRepresentative(paths[i], paths[bestIndex]))
			bestIndex = i;
	return bestIndex;
}

// We prefix "special" names with one NUL character to
// distinguish them from filesystem entries.
bool skipOverNul(C)(ref C[] str)
{
	// Workaround for https://issues.dlang.org/show_bug.cgi?id=22302
	if (str.startsWith("\0"))
	{
		str = str[1 .. $];
		return true;
	}
	return false;
}

/// Inline string type.
alias InlineString(size_t size) = InlineArr!(immutable(char), size);

union InlineArr(T, size_t size)
{
private:
	static assert(size * T.sizeof > T[].sizeof);
	alias InlineSize = ubyte;
	static assert(size < InlineSize.max);

	T[] str;
	struct
	{
		T[size] inlineBuf;
		InlineSize inlineLength;
	}

public:
	this(in Unqual!T[] s)
	{
		if (s.length > size)
			str = growAllocator.makeArray!T(s[]);
		else
		{
			inlineBuf[0 .. s.length] = s;
			inlineLength = cast(InlineSize)s.length;
		}
	}

	inout(T)[] opSlice() inout
	{
		if (inlineLength)
			return inlineBuf[0 .. inlineLength];
		else
			return str;
	}

	bool opCast(T : bool)() const { return this !is typeof(this).init; }

	bool opEquals(ref const InlineArr other) const
	{
		return this[] == other[];
	}
}
