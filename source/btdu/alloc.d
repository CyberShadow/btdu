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

import std.algorithm.comparison : max;
import std.experimental.allocator.building_blocks.allocator_list;
import std.experimental.allocator.building_blocks.null_allocator;
import std.experimental.allocator.building_blocks.region;
import std.experimental.allocator.mmap_allocator;
import std.experimental.allocator;

alias GrowAllocator = AllocatorList!((n) => Region!MmapAllocator(max(n, 1024 * 4096)), NullAllocator);
GrowAllocator growAllocator;
