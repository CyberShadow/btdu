/*
 * Copyright (C) 2020, 2021  Vladimir Panteleev <btdu@cy.md>
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

import ae.utils.aa;
import ae.utils.meta;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.array : Appender;
import std.range.primitives;
import std.string;

/// Common definitions for a deduplicated trie for paths.
mixin template SimplePath()
{
	/// Parent directory name
	typeof(this)* parent;
	/// Base name
	/// Names prefixed with a NUL character indicate "special" nodes,
	/// which do not correspond to a filesystem path.
	immutable string name;
	/// Directory items, if any
	typeof(this)*[string] children;

	private this(typeof(this)* parent, string name)
	{
		this.parent = parent;
		this.name = name;
		parent.children[name] = &this;
	}

	invariant
	{
		if (name)
		{
			assert(parent !is null, "Named node without parent");
			assert(parent.children[name] is &this, "Child/parent mismatch");
		}
		else // root
			assert(!parent, "Unnamed node with parent");
	}

	/// Append a single path segment to this one.
	typeof(this)* appendName(in char[] name)
	{
		assert(name.length, "Empty path segment");
		assert(name.indexOf('/') < 0, "Path segment contains /: " ~ name);
		if (auto pnext = name in children)
			return *pnext;
		else
			return new typeof(this)(&this, name.idup);
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

	/// Return an iterator for path fragments.
	/// Iterates from inner-most to top level.
	auto range() const
	{
		alias This = typeof(this)*;
		static struct Range
		{
			This p;
			bool empty() const { return !p; }
			string front() { return p.name; }
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
		string humanName = name;
		humanName.skipOverNul();
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
		static Appender!(size_t[]) lengths;
		lengths.clear();
		foreach (ref path; paths)
			lengths.put(path.chainLength);

		// Rewind all paths to the minimal path's length
		auto minLength = lengths.data.reduce!min;
		foreach (i, ref path; paths)
			while (lengths.data[i] > minLength)
			{
				lengths.data[i]--;
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
		return cmp(name, b.name);
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

	void addSample(SampleType type, ulong logicalOffset, ulong duration)
	{
		data[type].samples++;
		data[type].duration += duration;
		if (logicalOffset != data[type].logicalOffsets[$-1])
			foreach (i, ref l0; data[type].logicalOffsets)
				l0 = i + 1 == Data.logicalOffsets.length ? logicalOffset : data[type].logicalOffsets[i + 1];
		if (parent)
			parent.addSample(type, logicalOffset, duration);
	}

	void addDistributedSample(double share)
	{
		distributedSamples += share;
		if (parent)
			parent.addDistributedSample(share);
	}

	/// Other paths this address is reachable via
	HashSet!GlobalPath seenAs;
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
