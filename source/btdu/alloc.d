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

/// Memory allocation
module btdu.alloc;

import core.exception : onOutOfMemoryError;

import std.algorithm.comparison : max;
import std.experimental.allocator.building_blocks.allocator_list;
import std.experimental.allocator.building_blocks.null_allocator;
import std.experimental.allocator.building_blocks.region;
import std.experimental.allocator.mallocator;
import std.experimental.allocator.mmap_allocator;
import std.experimental.allocator;

/// Allocator to use for objects with infinite lifetime, which will never be freed.
alias GrowAllocator = AllocatorList!((n) => Region!MmapAllocator(max(n, 1024 * 4096)), NullAllocator);
CheckedAllocator!GrowAllocator growAllocator;

/// Casual allocator which supports deallocation.
alias CasualAllocator = CheckedAllocator!Mallocator;

/// Wrapper allocator which calls a function when memory allocation fails.
/// Because downstream code doesn't check for nulls, this allows better error messages
/// should btdu run out of memory. (Mainly this is useful for testing and profiling.)
struct CheckedAllocator(ParentAllocator, alias onFail = onOutOfMemoryError)
{
	import std.traits : hasMember;
	import std.typecons : Ternary;

	static if (stateSize!ParentAllocator)
		ParentAllocator parent;
	else
	{
		alias parent = ParentAllocator.instance;
		static CheckedAllocator instance;
	}

	private T check(T)(T value) { if (!value) onFail(); return value; }

	void[] allocate(size_t n) { return check(parent.allocate(n)); }
	bool reallocate(ref void[] b, size_t s) { return check(parent.reallocate(b, s)); }

	// Note: we can't use `alias this` because we need to intercept allocateZeroed,
	// but we can't do that because it's package(std).

	enum alignment = ParentAllocator.alignment;

	size_t goodAllocSize(size_t n) { return parent.goodAllocSize(n); }

	static if (hasMember!(ParentAllocator, "expand"))
	bool expand(ref void[] b, size_t delta) { return parent.expand(b, delta); }

	static if (hasMember!(ParentAllocator, "owns"))
	Ternary owns(void[] b) { return parent.owns(b); }

	static if (hasMember!(ParentAllocator, "deallocate"))
	bool deallocate(void[] b) { return parent.deallocate(b); }

	static if (hasMember!(ParentAllocator, "deallocateAll"))
	bool deallocateAll() { return parent.deallocateAll(); }

	static if (hasMember!(ParentAllocator, "empty"))
	pure nothrow @safe @nogc Ternary empty() const { return parent.empty; }
}
