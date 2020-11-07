/*
 * Copyright (C) 2020  Vladimir Panteleev <btdu@cy.md>
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

import std.string;

import btdu.state : GlobalState;

/// Common definitions for a deduplicated trie for paths.
mixin template SimplePath()
{
	/// Parent directory name
	typeof(this)* parent;
	/// Base name
	immutable string name;
	/// Children - must hold the lock to access
	private typeof(this)*[string] children;

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
	/// globalState is used only as proof that we hold the lock.
	typeof(this)* appendName(ref GlobalState globalState, in char[] name)
	{
		assert(name.length, "Empty path segment");
		assert(name.indexOf('/') < 0, "Path segment contains /");
		if (auto pnext = name in children)
			return *pnext;
		else
			return new typeof(this)(&this, name.idup);
	}

	/// Append a normalized relative string path to this one.
	typeof(this)* appendPath(ref GlobalState globalState, in char[] path)
	{
		auto p = path.indexOf('/');
		auto nextName = p < 0 ? path : path[0 .. p];
		auto next = appendName(globalState, nextName);
		if (p < 0)
			return next;
		else
			return next.appendPath(globalState, path[p + 1 .. $]);
	}

	/// ditto
	typeof(this)* appendPath(ref GlobalState globalState, in SubPath* path)
	{
		typeof(this)* recurse(typeof(this)* base, in SubPath* path)
		{
			if (!path.parent) // root
				return base;
			base = recurse(base, path.parent);
			return base.appendName(globalState, path.name);
		}

		return recurse(&this, path);
	}

	/// ditto
	typeof(this)* appendPath(ref GlobalState globalState, in GlobalPath* path)
	{
		typeof(this)* recurse(typeof(this)* base, in GlobalPath* path)
		{
			if (path.parent)
				base = recurse(base, path.parent);
			return base.appendPath(globalState, path.subPath);
		}

		return recurse(&this, path);
	}

	typeof(this)*[string] getChildren(ref GlobalState globalState)
	{
		return children;
	}

	void toString(scope void delegate(const(char)[]) sink) const
	{
		if (parent)
			parent.toString(sink);
		sink("/");
		sink(name);
	}
}

/// Path within a tree (subvolume)
struct SubPath
{
	mixin SimplePath;
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
}

/// Browser path (GUI hierarchy)
struct BrowserPath
{
	mixin SimplePath;

	ulong samples; /// For non-leaves, sum of leaves

	void addSample()
	{
		samples++;
		if (parent)
			parent.addSample();
	}

	/// Other paths this address is reachable via
	HashSet!GlobalPath seenAs;
}
