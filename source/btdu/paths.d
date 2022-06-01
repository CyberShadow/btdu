/*
 * Copyright (C) 2020, 2021, 2022  Vladimir Panteleev <btdu@cy.md>
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
import std.algorithm.searching;
import std.array : array;
import std.experimental.allocator : makeArray, make;
import std.string;
import std.traits : Unqual, EnumMembers;

import ae.utils.appender;
import ae.utils.json : JSONName, JSONOptional, JSONFragment;
import ae.utils.meta;

import btdu.alloc;

import containers.hashmap;
import containers.internal.hash : generateHash;

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
	typeof(this)* appendName(in char[] name)
	{
		assert(name.length, "Empty path segment");
		assert(name.indexOf('/') < 0, "Path segment contains /: " ~ name);
		auto ppnext = find(name);
		if (auto pnext = *ppnext)
			return pnext;
		else
			return *ppnext = growAllocator.make!(typeof(this))(&this, NameString(name));
	}

	/// ditto
	private typeof(this)* appendName(NameString name)
	{
		auto ppnext = find(name[]);
		if (auto pnext = *ppnext)
			return pnext;
		else
			return *ppnext = growAllocator.make!(typeof(this))(&this, name);
	}

	/// Append a normalized relative string path to this one.
	typeof(this)* appendPath(in char[] path)
	{
		auto p = path.indexOf('/');
		auto nextName = p < 0 ? path : path[0 .. p];
		auto next = appendName(nextName);
		if (p < 0)
			return next;
		else
			return next.appendPath(path[p + 1 .. $]);
	}

	/// ditto
	typeof(this)* appendPath(in SubPath* path)
	{
		typeof(this)* recurse(typeof(this)* base, in SubPath* path)
		{
			if (!path.parent) // root
				return base;
			base = recurse(base, path.parent);
			return base.appendName(path.name);
		}

		return recurse(&this, path);
	}

	/// ditto
	typeof(this)* appendPath(in GlobalPath* path)
	{
		typeof(this)* recurse(typeof(this)* base, in GlobalPath* path)
		{
			if (path.parent)
				base = recurse(base, path.parent);
			return base.appendPath(path.subPath);
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
			This p;
			bool empty() const { return !p; }
			string front() { return p.name[]; }
			void popFront() { p = p.parent; }
		}
		return Range(&this);
	}

	void toString(scope void delegate(const(char)[]) sink) const
	{
		if (parent)
		{
			parent.toString(sink);
			sink("/");
		}
		sink(humanName);
	}

	string humanName() const
	{
		string humanName = name[];
		if (humanName.skipOverNul())
			humanName = "<" ~ humanName ~ ">";
		return humanName;
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
		static FastAppender!size_t lengths;
		lengths.clear();
		foreach (ref path; paths)
			lengths.put(path.chainLength);

		// Rewind all paths to the minimal path's length
		auto minLength = lengths.get().reduce!min;
		foreach (i, ref path; paths)
			while (lengths.get()[i] > minLength)
			{
				lengths.get()[i]--;
				path = path.parent;
			}

		// Rewind all paths until the tip points at the same thing
		while (paths.any!(path => path !is paths[0]))
			foreach (ref path; paths)
				path = path.parent;

		// All paths now point at the same thing.
		return paths[0];
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
			const(GlobalPath)* p;
			bool empty() const { return !p; }
			const(SubPath)* front() { return p.subPath; }
			void popFront() { p = p.parent; }
		}
		return Range(&this);
	}

	mixin PathCommon;
	mixin PathCmp;
}

enum SampleType
{
	represented,
	exclusive,
	shared_,
}

/// Browser path (GUI hierarchy)
struct BrowserPath
{
	mixin SimplePath;
	mixin PathCommon;

	struct Data
	{
		ulong samples; /// For non-leaves, sum of leaves
		ulong duration; /// Total hnsecs
		ulong[3] logicalOffsets = -1; /// Examples (the last 3 seen) of logical offsets
	}
	Data[enumLength!SampleType] data;
	double distributedSamples = 0;
	bool deleting;

	void addSample(SampleType type, ulong logicalOffset, ulong duration)
	{
		addSamples(type, 1, (&logicalOffset)[0..1], duration);
	}

	void addSamples(SampleType type, ulong samples, ulong[] logicalOffsets, ulong duration)
	{
		data[type].samples += samples;
		data[type].duration += duration;
		foreach (logicalOffset; logicalOffsets)
			if (logicalOffset != data[type].logicalOffsets[$-1])
				foreach (i, ref l0; data[type].logicalOffsets)
					l0 = i + 1 == Data.logicalOffsets.length ? logicalOffset : data[type].logicalOffsets[i + 1];
		if (parent)
			parent.addSamples(type, samples, logicalOffsets, duration);
	}

	void removeSamples(SampleType type, ulong samples, ulong[] logicalOffsets, ulong duration)
	{
		assert(samples <= data[type].samples && duration <= data[type].duration);
		data[type].samples -= samples;
		data[type].duration -= duration;
		foreach (i, lMy; data[type].logicalOffsets)
			if (logicalOffsets.canFind(lMy))
				foreach_reverse (j; 0 .. i + 1)
					data[type].logicalOffsets = j == 0 ? -1 : data[type].logicalOffsets[j + 1];
		if (parent)
			parent.removeSamples(type, samples, logicalOffsets, duration);
	}

	void addDistributedSample(double share)
	{
		distributedSamples += share;
		if (parent)
			parent.addDistributedSample(share);
	}

	void removeDistributedSample(double share)
	{
		addDistributedSample(-share);
	}

	/// Other paths this address is reachable via,
	/// and samples seen from those addresses
	HashMap!(GlobalPath, size_t, CasualAllocator, generateHash!GlobalPath, false, false) seenAs;

	/// Serialized representation
	struct SerializedForm
	{
		string name;

		struct SampleData
		{
			// Same order as SampleType
			@JSONOptional Data represented;
			@JSONOptional Data exclusive;
			@JSONName("shared")
			@JSONOptional Data shared_;
			@JSONOptional JSONFragment distributedSamples = JSONFragment("0");
		}
		SampleData data;

		BrowserPath*[] children;
	}

	SerializedForm toJSON()
	{
		SerializedForm s;
		s.name = this.name[];
		for (auto p = firstChild; p; p = p.nextSibling)
			s.children ~= p;
		static foreach (sampleType; EnumMembers!SampleType)
			s.data.tupleof[sampleType] = data[sampleType];
		if (this.distributedSamples !is 0.)
			s.data.distributedSamples.json = this.distributedSamples.format!"%17e";
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
		static foreach (sampleType; EnumMembers!SampleType)
			p.data[sampleType] = s.data.tupleof[sampleType];
		p.distributedSamples = s.data.distributedSamples.json.strip.to!double;
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
	void remove()
	{
		assert(parent);

		// Mark this subtree for deletion, to aid the rebalancing below.
		markForDeletion();

		// Rebalance the hierarchy's statistics by updating and moving sample data as needed.
		evict();

		// Unlink this node, removing it from the tree.
		{
			auto pp = parent.find(this.name[]);
			assert(*pp == &this);
			*pp = this.nextSibling;
		}
	}

	// Mark this subtree for deletion, to aid the rebalancing below.
	private void markForDeletion()
	{
		deleting = true;
		for (auto p = firstChild; p; p = p.nextSibling)
			p.markForDeletion();
	}

	/// Clear all samples or move them elsewhere.
	private void evict()
	{
		assert(parent);

		// Evict children first
		for (auto p = firstChild; p; p = p.nextSibling)
			p.evict();

		// Save this node's remaining stats before we remove them.
		auto data = this.data;
		auto distributedSamples = this.distributedSamples;

		// Remove sample data from this node and its parents.
		// After recursion, for non-leaf nodes, most of these should now be at zero (as far as we can estimate).
		static foreach (sampleType; EnumMembers!SampleType)
			if (data[sampleType].samples) // avoid quadratic complexity
				removeSamples(sampleType, data[sampleType].samples, data[sampleType].logicalOffsets[], data[sampleType].duration);
		if (distributedSamples) // avoid quadratic complexity
			removeDistributedSample(distributedSamples);

		if (seenAs.empty)
			return;  // Directory (non-leaf) node - nothing else to do here.

		// For leaf nodes, some stats can be redistributed to other references.
		// We need to do some path calculations first,
		// such as inferring the GlobalPath from the BrowserPath and seenAs.
		BrowserPath* root;
		foreach (ref otherPath; seenAs.byKey)
		{
			root = this.unappendPath(&otherPath);
			if (root)
				break;
		}
		debug assert(root);
		if (!root)
			return;

		// These paths will inherit the remains.
		auto remainingPaths = seenAs.byKey
			.filter!(otherPath => !root.appendPath(&otherPath).deleting)
			.array;

		// Redistribute to siblings
		if (!remainingPaths.empty)
		{
			auto newRepresentativePath = selectRepresentativePath(remainingPaths);
			foreach (ref remainingPath; remainingPaths)
			{
				// Redistribute samples
				if (remainingPath == newRepresentativePath)
					root.appendPath(&remainingPath).addSamples(
						SampleType.represented,
						data[SampleType.represented].samples,
						data[SampleType.represented].logicalOffsets[],
						data[SampleType.represented].duration,
					);
				if (distributedSamples)
					root.appendPath(&remainingPath).addDistributedSample(distributedSamples / remainingPaths.length);
			}
		}
	}
}

GlobalPath selectRepresentativePath(GlobalPath[] paths)
{
	return paths.fold!((a, b) {
		// Prefer paths with resolved roots
		auto aResolved = a.isResolved();
		auto bResolved = b.isResolved();
		if (aResolved != bResolved)
			return aResolved ? a : b;
		// Shortest path always wins
		auto aLength = a.length;
		auto bLength = b.length;
		if (aLength != bLength)
			return aLength < bLength ? a : b;
		// If the length is the same, pick the lexicographically smallest one
		return a < b ? a : b;
	})();
}

private bool isResolved(ref GlobalPath p)
{
	return !p.range
		.map!(g => g.range)
		.joiner
		.canFind!(n => n.startsWith("\0TREE_"));
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
