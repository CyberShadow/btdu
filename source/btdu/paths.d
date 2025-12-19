/*
 * Copyright (C) 2020, 2021, 2022, 2023, 2024, 2025  Vladimir Panteleev <btdu@cy.md>
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

	/// Find the next group pointer for a given element range
	/// Returns null if the element range doesn't match any path in this group
	inout(SharingGroup)* getNext(R)(R elementRange) inout
	{
		auto index = findIndex(elementRange);
		return index != size_t.max ? this.pathData[index].next : null;
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
				return *ppnext = growAllocator.make!(typeof(this))(&this, NameString(name));
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
				return *ppnext = growAllocator.make!(typeof(this))(&this, name);
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
		assert(pattern.length > 0 && pattern[0] is doubleGlob);
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
		assert(samples <= this.samples && duration <= this.duration);
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

	/// Check if a sharing group is relevant for a given sample type
	private bool groupIsRelevant(const(SharingGroup)* group, SampleType type) const
	{
		final switch (type)
		{
			case SampleType.shared_:
				// All samples that touch this path
				return true;
			case SampleType.represented:
				// Samples where this path is the representative
				auto ourIndex = group.findIndex(this.elementRange);
				return ourIndex == group.representativeIndex;
			case SampleType.exclusive:
				// Samples exclusive to this path (only path in group)
				return group.paths.length == 1;
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
				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(this.elementRange))
					if (groupIsRelevant(group, type))
						sum += group.data.samples;
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
				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(this.elementRange))
					if (groupIsRelevant(group, type))
						sum += group.data.duration;
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

				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(this.elementRange))
				{
					if (groupIsRelevant(group, type))
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
				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(this.elementRange))
					sum += cast(double) group.data.samples / group.paths.length;
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
				for (const(SharingGroup)* group = firstSharingGroup; group !is null; group = group.getNext(this.elementRange))
					sum += cast(double) group.data.duration / group.paths.length;
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

		// Single-child nodes delegate to their only child
		if (firstChild && !firstChild.nextSibling)
			return false;

		// All other nodes (no children, or multiple children) store in aggregateData
		return true;
	}

	void addSamples(SampleType type, ulong samples, const(Offset)[] offsets, ulong duration)
	{
		if (needsAggregateData)
			ensureAggregateData().data[type].add(samples, offsets, duration);
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
		if (needsAggregateData)
		{
			auto data = ensureAggregateData();
			data.distributedSamples += sampleShare;
			data.distributedDuration += durationShare;
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
		for (auto group = firstSharingGroup; group !is null; group = group.getNext(this.elementRange))
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

		assert(parent);

		// Mark this subtree for deletion, to aid the rebalancing below.
		markForDeletion(obeyMarks);

		// Delete the subtree recursively.
		doDelete();
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
			assert(*pp == &this);
			*pp = this.nextSibling;
		}
	}

	/// Clear all samples or move them elsewhere.
	private void evict()
	{
		assert(parent);

		// Save this node's remaining stats before we remove them.
		auto aggData = aggregateData ? *aggregateData : AggregateData.init;

		// Remove sample data from this node and its parents.
		// After recursion, for non-leaf nodes, most of these should now be at zero (as far as we can estimate).
		static foreach (sampleType; EnumMembers!SampleType)
			if (aggData.data[sampleType].samples) // avoid quadratic complexity
				removeSamples(sampleType, aggData.data[sampleType].samples, aggData.data[sampleType].offsets[], aggData.data[sampleType].duration);
		if (aggData.distributedSamples) // avoid quadratic complexity
			removeDistributedSample(aggData.distributedSamples, aggData.distributedDuration);

		if (firstSharingGroup is null)
			return;  // Directory (non-leaf) node - nothing else to do here.

		// Determine if we are the representative path (have represented samples)
		// in at least one situation
		bool isRepresentative = aggData.data[SampleType.represented].samples > 0;

		// Get the root BrowserPath from one of our sharing groups
		// (This is always the same as `btdu.state.browserRoot`.)
		BrowserPath* root = firstSharingGroup.root;
		debug assert(root);
		if (!root)
			return;

		// Process each sharing group separately
		for (auto group = firstSharingGroup; group !is null; )
		{
			// Find our index in this group
			auto ourIndex = group.findIndex(this.elementRange);
			assert(ourIndex != size_t.max, "Could not find self in sharing group");
			if (ourIndex == size_t.max)
				break;

			// Collect remaining (non-deleted) paths in this group
			SamplePath[] remainingPathsInGroup;
			foreach (i, ref path; group.paths)
			{
				if (i != ourIndex)
				{
					auto bp = root.appendPath!true(&path);
					if (bp && !bp.deleting)
						remainingPathsInGroup ~= SamplePath(group.root, path);
				}
			}

			// Check if we are the representative for this specific group
			bool isRepresentativeForThisGroup = {
				if (!isRepresentative)
					return false; // We have never been representative.

				// Check if we would be selected as representative from this group's paths
				auto groupRepresentative = selectRepresentativePath(group.paths);
				import std.algorithm.comparison : equal;
				return equal(this.elementRange, groupRepresentative.elementRange);
			}();

			// Handle all redistributions for this group
			if (remainingPathsInGroup.length > 0)
			{
				// Select the most representative path from this group's remaining members
				auto newRepresentative = selectRepresentativePath(remainingPathsInGroup);
				auto newRepBrowserPath = root.appendPath(&newRepresentative.globalPath);

				// Represented samples: if we're representative for this group, transfer to new representative
				if (isRepresentativeForThisGroup)
				{
					// Calculate this group's weighted share of duration from represented samples
					auto groupDuration = (group.data.samples * aggData.data[SampleType.represented].duration) / aggData.data[SampleType.represented].samples;

					// Transfer represented samples (without per-group offsets)
					newRepBrowserPath.addSamples(
						SampleType.represented,
						group.data.samples,
						[], // Skip offsets - we don't have them per-group
						groupDuration,
					);
				}

				// Distributed samples: redistribute our share in this group
				// Our share in this group is: group.data.samples / group.paths.length
				// We distribute this among the remaining members
				auto ourShareSamples = group.data.samples / group.paths.length;
				auto perPathSamples = ourShareSamples / remainingPathsInGroup.length;

				// Calculate duration using shared samples as basis (sum of all group.data.samples = shared samples)
				auto sharedSamples = aggData.data[SampleType.shared_].samples;
				auto sharedDuration = aggData.data[SampleType.shared_].duration;
				auto groupTotalDuration = sharedSamples > 0
					? (group.data.samples * sharedDuration) / sharedSamples
					: 0;
				auto ourShareDuration = groupTotalDuration / group.paths.length;
				auto perPathDuration = ourShareDuration / remainingPathsInGroup.length;

				foreach (ref path; remainingPathsInGroup)
					root.appendPath(&path.globalPath).addDistributedSample(perPathSamples, perPathDuration);

				// Exclusive samples: if group drops to 1 member, that member becomes exclusive
				if (remainingPathsInGroup.length == 1)
				{
					// Calculate this group's weighted share of duration from shared samples
					auto groupDuration = sharedSamples > 0
						? (group.data.samples * sharedDuration) / sharedSamples
						: 0;

					// Add exclusive samples (without per-group offsets)
					newRepBrowserPath.addSamples(
						SampleType.exclusive,
						group.data.samples,
						[], // Skip offsets - we don't have them per-group
						groupDuration,
					);
				}
			}

			// Shared samples: no action needed (correct!)

			// Move to next group following our chain
			group = group.pathData[ourIndex].next;
		}
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
		assert(mark == Mark.parent);
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
bool isMoreRepresentative(A, B)(ref A a, ref B b)
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
	// Shortest path always wins
	auto aLength = a.length;
	auto bLength = b.length;
	if (aLength != bLength)
		return aLength < bLength;
	// If the length is the same, pick the lexicographically smallest one
	return a < b;
}

Path selectRepresentativePath(Path)(Path[] paths)
{
	return paths.fold!((a, b) {
		return isMoreRepresentative(a, b) ? a : b;
	})();
}

/// Find the index of the most representative path in an array.
/// Returns size_t.max if the array is empty.
size_t selectRepresentativeIndex(Path)(Path[] paths)
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
