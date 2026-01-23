/*
 * Copyright (C) 2020, 2021, 2023, 2025  Vladimir Panteleev <btdu@cy.md>
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
import std.traits;

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

/// Reusable appender.
template StaticAppender(T)
if (!hasIndirections!T)
{
	import ae.utils.appender : FastAppender;
	alias StaticAppender = FastAppender!(T, Mallocator);
}

/// Slab allocator for efficient allocation of many small objects.
/// Allocates objects in large contiguous slabs linked together.
/// Overhead: one pointer per slab (~4MB), plus fixed global state.
/// When indexed=true, supports reverse lookup (pointer -> index) via binary search.
struct SlabAllocator(T, size_t slabSize = 4 * 1024 * 1024, bool indexed = false)
{
	enum itemsPerSlab = (slabSize - (Slab*).sizeof) / T.sizeof;
	static assert(itemsPerSlab > 0, "Type too large for slab allocator");

	struct Slab
	{
		T[itemsPerSlab] items;
		Slab* next;
	}

	static assert(Slab.sizeof <= slabSize);

	Slab* firstSlab;
	Slab* currentSlab;
	size_t currentIndex;

	// Array of slab base pointers in allocation order (for reverse lookup)
	static if (indexed)
		Slab*[] slabIndex;

	/// Standard allocator interface for compatibility with std.experimental.allocator.make
	enum alignment = T.alignof;

	/// Deallocate is a no-op (slab allocator doesn't support individual deallocation)
	bool deallocate(void[] b) { return false; }

	/// Allocate a new item, returns a slice to uninitialized memory.
	void[] allocate(size_t n)
	{
		assert(n == T.sizeof, "SlabAllocator only supports fixed-size allocations");
		if (!currentSlab || currentIndex >= itemsPerSlab)
		{
			auto mem = MmapAllocator.instance.allocate(Slab.sizeof);
			if (!mem)
				onOutOfMemoryError();
			auto newSlab = cast(Slab*) mem.ptr;
			newSlab.next = null;
			if (currentSlab)
				currentSlab.next = newSlab;
			else
				firstSlab = newSlab;
			currentSlab = newSlab;
			currentIndex = 0;
			// Add to index for reverse lookup (in allocation order)
			static if (indexed)
				slabIndex ~= newSlab;
		}
		return (cast(void*) &currentSlab.items[currentIndex++])[0 .. T.sizeof];
	}

	/// Iterate over all allocated items.
	int opApply(scope int delegate(ref T) dg)
	{
		foreach (ref item; opSlice())
			if (auto r = dg(item))
				return r;
		return 0;
	}

	/// Range over allocated items. Captures a snapshot of the current end position,
	/// so new allocations during iteration won't affect the range.
	Range opSlice()
	{
		return Range(firstSlab, 0, currentSlab, currentIndex);
	}

	struct Range
	{
		Slab* slab;
		size_t index;
		Slab* endSlab;
		size_t endIndex;

		bool empty() const
		{
			return slab is null || (slab is endSlab && index >= endIndex);
		}

		ref T front()
		{
			return slab.items[index];
		}

		void popFront()
		{
			index++;
			if (index >= itemsPerSlab && slab !is endSlab)
			{
				slab = slab.next;
				index = 0;
			}
		}

		size_t length() const
		{
			if (empty)
				return 0;
			size_t count = 0;
			for (const(Slab)* s = slab; s !is endSlab; s = s.next)
				count += itemsPerSlab;
			count += endIndex;
			count -= index;
			return count;
		}
	}

	/// Range with implicit end - always iterates to current allocator position.
	/// New allocations automatically appear in this range.
	/// Useful for tracking "pending" items that need processing.
	struct OpenRange
	{
		SlabAllocator* allocator;
		Slab* slab;
		size_t index;

		bool empty()
		{
			// If slab is null, we started before any allocations - check if any exist now
			if (slab is null)
			{
				if (allocator.firstSlab is null)
					return true; // Still no allocations
				// Allocations started - begin from first slab
				slab = allocator.firstSlab;
				index = 0;
			}
			// Empty if we've caught up to the allocator's current position
			return slab is allocator.currentSlab && index >= allocator.currentIndex;
		}

		ref T front()
		{
			return slab.items[index];
		}

		/// Get a pointer to the front element.
		T* frontPtr()
		{
			return &slab.items[index];
		}

		void popFront()
		{
			index++;
			// Move to next slab if we've exhausted this one and there are more
			if (index >= itemsPerSlab && slab.next !is null)
			{
				slab = slab.next;
				index = 0;
			}
		}

		/// Number of items remaining (from current position to allocator's current position)
		size_t length()
		{
			if (empty)
				return 0;
			size_t count = 0;
			for (const(Slab)* s = slab; s !is allocator.currentSlab; s = s.next)
				count += itemsPerSlab;
			count += allocator.currentIndex;
			count -= index;
			return count;
		}
	}

	/// Create an open-ended range starting from current position.
	/// The range will be empty initially, but will include items as they are allocated.
	OpenRange openRange()
	{
		return OpenRange(&this, currentSlab, currentIndex);
	}

	/// Number of allocated items.
	static if (indexed)
	{
		size_t length() const
		{
			if (!firstSlab)
				return 0;
			return (slabIndex.length - 1) * itemsPerSlab + currentIndex;
		}
	}
	else
	{
		size_t length() const
		{
			if (!firstSlab)
				return 0;
			size_t count = currentIndex;
			for (const(Slab)* slab = firstSlab; slab !is currentSlab; slab = slab.next)
				count += itemsPerSlab;
			return count;
		}
	}

	// Indexed-only methods
	static if (indexed)
	{
		/// Reverse lookup: given a pointer to an item, return its allocation-order index.
		/// Returns -1 if the pointer is not found (not allocated by this allocator).
		long indexOf(const(T)* ptr) const
		{
			if (ptr is null || slabIndex.length == 0)
				return -1;

			auto ptrAddr = cast(size_t) ptr;

			// Linear search through slabs (in allocation order)
			foreach (slabNum, slab; slabIndex)
			{
				auto slabStart = cast(size_t) &slab.items[0];
				auto slabEnd = slabStart + itemsPerSlab * T.sizeof;

				if (ptrAddr >= slabStart && ptrAddr < slabEnd)
				{
					// Found the slab, calculate offset
					size_t offset = (ptrAddr - slabStart) / T.sizeof;
					// Verify it's aligned properly
					if ((ptrAddr - slabStart) % T.sizeof != 0)
						return -1;
					// Check if within allocated range for last slab
					if (slabNum == slabIndex.length - 1 && offset >= currentIndex)
						return -1;
					return cast(long)(slabNum * itemsPerSlab + offset);
				}
			}
			return -1;
		}

		/// Check if a pointer was allocated by this allocator.
		bool contains(const(T)* ptr) const
		{
			return indexOf(ptr) >= 0;
		}
	}
}

/// Alias for indexed slab allocator
alias IndexedSlabAllocator(T, size_t slabSize = 4 * 1024 * 1024) = SlabAllocator!(T, slabSize, true);
