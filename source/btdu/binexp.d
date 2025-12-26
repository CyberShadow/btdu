/*
 * Copyright (C) 2025  Vladimir Panteleev <btdu@cy.md>
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

/// Binary import/export format
module btdu.binexp;

import std.conv : to;
import std.exception : enforce;
import std.stdio : File;
import std.traits : isIntegral, isSomeChar, EnumMembers, Unqual;
import std.typecons : Tuple;

import std.bitmanip : nativeToLittleEndian, littleEndianToNative;

import containers.hashmap : HashMap;

import btdu.alloc : CasualAllocator, growAllocator;
import btdu.paths : historySize, BrowserPath, SubPath, SharingGroup, Mark;
import btdu.proto : Offset;
import btrfs.c.ioctl : btrfs_ioctl_fs_info_args;

import btdu.state : DataSet, SamplingState, subPathAllocator, subPathRoot;

static import btdu.paths;
alias PathsGlobalPath = btdu.paths.GlobalPath;

enum BinaryFormatVersion : uint
{
    v1 = 1,
    v2 = 2,    /// Added fsid to header
}
enum latestBinaryFormatVersion = BinaryFormatVersion.max;

/// Binary format header, versioned for future evolution
struct BinaryHeader(BinaryFormatVersion ver = latestBinaryFormatVersion)
{
    ubyte[8] magic = ['B', 'T', 'D', 'U', 0, 'B', 'I', 'N'];
    BinaryFormatVersion formatVersion = ver;

    /// Flags stored in the binary format header.
    enum Flags : uint
    {
        none = 0, /// needed for .init
        /// Informational only: the binary format always contains complete
        /// data for all size metrics regardless of this flag. The user's
        /// command-line --expert flag controls the view mode at import time.
        expert = 1 << 0,
        /// Meaningful: indicates whether data was sampled in physical or
        /// logical addressing mode. This affects data interpretation.
        physical = 1 << 1,
    }
    Flags flags;

    static if (ver >= BinaryFormatVersion.v2)
        typeof(btrfs_ioctl_fs_info_args.fsid) fsid; /// Filesystem UUID (v2+)

    ulong totalSize; /// Total size of the sampled filesystem (not export file)
    // Array lengths are encoded inline with each array (length-prefixed format).
}

// ============================================================================
// Unified BinaryIO - combines I/O primitives with context tables
// ============================================================================

/// Unified I/O context for binary format serialization.
/// Combines the reader/writer with lookup tables for bidirectional visiting.
struct BinaryIO(BinaryFormatVersion ver, bool writing)
{
    enum isWriting = writing;
    enum formatVersion = ver;
    alias Index = ulong;

    // ========================================================================
    // I/O Primitives
    // ========================================================================

    static if (isWriting)
    {
        private File file;

        void put(T)(T[] data) if (isSomeChar!T || is(T == ubyte) || is(T == byte))
        {
            file.rawWrite(data);
        }
    }
    else
    {
        private const(ubyte)[] data;
        private size_t pos;

        pragma(inline, true)
        const(ubyte)[] take(size_t n)
        {
            enforce(pos + n <= data.length, "Insufficient data (file is truncated or corrupted)");
            auto result = data[pos .. pos + n];
            pos += n;
            return result;
        }

        @property size_t remaining() const
        {
            return data.length - pos;
        }
    }

    // ========================================================================
    // Lookup Tables
    // ========================================================================

    string[] strings;
    btdu.paths.SubPath*[] subPathPtrs;
    PathsGlobalPath*[] rootPtrs;
    BrowserPath*[] browserRootPtrs;

    static if (isWriting)
    {
        HashMap!(const(PathsGlobalPath)*, Index, CasualAllocator) rootToIndex;
        HashMap!(const(BrowserPath)*, Index, CasualAllocator) browserRootToIndex;
    }
    else
    {
        SamplingState* targetState;
        DataSet target;
    }

    // ========================================================================
    // Index Lookup Helpers (for writing)
    // ========================================================================

    Index getStringIndex(const(char)[] s)
    {
        static if (isWriting)
        {
            import std.range : assumeSorted;
            auto r = strings.assumeSorted.trisect(s);
            assert(r[1].length > 0, "String not found: " ~ s);
            return Index(r[0].length);
        }
        else
            assert(0, "getStringIndex called during reading");
    }

    Index getSubPathIndex(const(btdu.paths.SubPath)* sp)
    {
        static if (isWriting)
            return (sp == &subPathRoot) ? -1 : subPathAllocator.indexOf(sp);
        else
            assert(0, "getSubPathIndex called during reading");
    }

    Index getRootIndex(const(PathsGlobalPath)* gp)
    {
        static if (isWriting)
            return gp ? rootToIndex[gp] : -1;
        else
            assert(0, "getRootIndex called during reading");
    }

    Index getBrowserRootIndex(const(BrowserPath)* bp)
    {
        static if (isWriting)
            return bp ? browserRootToIndex[bp] : -1;
        else
            assert(0, "getBrowserRootIndex called during reading");
    }

    // ========================================================================
    // Index Resolution Helpers (for reading)
    // ========================================================================

    btdu.paths.SubPath* resolveSubPath(Index idx)
    {
        static if (!isWriting)
            return (idx == -1) ? &subPathRoot : subPathPtrs[idx.to!size_t];
        else
            assert(0, "resolveSubPath called during writing");
    }

    PathsGlobalPath* resolveRoot(Index idx)
    {
        static if (!isWriting)
            return (idx == -1) ? null : rootPtrs[idx.to!size_t];
        else
            assert(0, "resolveRoot called during writing");
    }

    BrowserPath* resolveBrowserRoot(Index idx)
    {
        static if (!isWriting)
            return browserRootPtrs[idx.to!size_t];
        else
            assert(0, "resolveBrowserRoot called during writing");
    }

    string resolveString(Index idx)
    {
        static if (!isWriting)
            return strings[idx.to!size_t];
        else
            assert(0, "resolveString called during writing");
    }
}

/// Trait to detect BinaryIO types (for excluding from struct visit)
enum isBinaryIO(T) = is(T == BinaryIO!(ver, w), BinaryFormatVersion ver, bool w);

/// Mark data for serialization
struct MarkData { const(BrowserPath)* path; bool marked; }

// ============================================================================
// Core visit primitives
// ============================================================================

/// Zigzag encode signed integer for efficient varint encoding of negative values
/// Maps: 0 → 0, -1 → 1, 1 → 2, -2 → 3, 2 → 4, ...
ulong zigzagEncode(long value)
{
    return cast(ulong)((value << 1) ^ (value >> 63));
}

/// Zigzag decode
long zigzagDecode(ulong value)
{
    return cast(long)((value >> 1) ^ -(value & 1));
}

/// Visit unsigned LEB128 varint
void visitVarint(IO)(ref IO io, ref ulong value)
{
    static if (IO.isWriting)
    {
        ulong v = value;
        ubyte[10] bytes;  // Max 10 bytes for 64-bit value
        size_t len = 0;
        do
        {
            ubyte b = v & 0x7F;
            v >>= 7;
            if (v != 0)
                b |= 0x80;  // More bytes follow
            bytes[len++] = b;
        }
        while (v != 0);
        io.put(bytes[0 .. len]);
    }
    else
    {
        ulong result = 0;
        uint shift = 0;
        while (true)
        {
            ubyte b = io.take(1)[0];
            result |= cast(ulong)(b & 0x7F) << shift;
            if ((b & 0x80) == 0)
                break;
            shift += 7;
            enforce(shift < 64, "Varint too long");
        }
        value = result;
    }
}

/// Visit zigzag-encoded signed varint
void visitSignedVarint(IO)(ref IO io, ref long value)
{
    static if (IO.isWriting)
    {
        ulong encoded = zigzagEncode(value);
        visitVarint(io, encoded);
    }
    else
    {
        ulong encoded;
        visitVarint(io, encoded);
        value = zigzagDecode(encoded);
    }
}

/// Smaller integer types (non-64-bit, non-byte): fixed-size little-endian
void visit(IO, T)(ref IO io, ref T value)
if (isIntegral!T && !is(T == ulong) && !is(T == long) && !is(T == ubyte) && !is(T == byte))
{
    static if (IO.isWriting)
    {
        io.put(nativeToLittleEndian(value)[]);
    }
    else
    {
        ubyte[T.sizeof] bytes = io.take(T.sizeof)[0 .. T.sizeof];
        value = littleEndianToNative!T(bytes);
    }
}

/// 64-bit integers: use varint encoding
void visit(IO)(ref IO io, ref ulong value)
{
    visitVarint(io, value);
}

/// 64-bit signed integers: use signed varint encoding
void visit(IO)(ref IO io, ref long value)
{
    visitSignedVarint(io, value);
}

/// Single byte types
void visit(IO, T)(ref IO io, ref T value)
if (is(Unqual!T == ubyte) || is(Unqual!T == byte) || is(Unqual!T == char))
{
    static if (IO.isWriting)
    {
        ubyte[1] b = [cast(ubyte) value];
        io.put(b[]);
    }
    else
    {
        value = cast(T) io.take(1)[0];
    }
}

/// Static arrays
void visit(IO, T : U[N], U, size_t N)(ref IO io, ref T value)
{
    static if (is(U == ubyte))
    {
        // Optimize: handle byte arrays directly
        static if (IO.isWriting)
        {
            io.put(value[]);
        }
        else
        {
            value[] = io.take(N)[0 .. N];
        }
    }
    else
    {
        foreach (ref e; value)
            visit(io, e);
    }
}

/// Dynamic arrays: length-prefixed (excludes static arrays)
void visit(IO, T : U[], U)(ref IO io, ref T value)
if (!is(T : V[N], V, size_t N))
{
    static if (IO.isWriting)
    {
        ulong len = value.length;
        visit(io, len);
        static if (is(Unqual!U == ubyte) || is(Unqual!U == byte) || is(Unqual!U == char))
        {
            // Optimize: write byte arrays directly
            io.put(cast(ubyte[]) value);
        }
        else
        {
            foreach (ref e; value)
                visit(io, e);
        }
    }
    else
    {
        ulong len;
        visit(io, len);
        // Always allocate and copy - never return slices (supports memory-mapped input)
        import std.experimental.allocator : makeArray;
        auto arr = growAllocator.makeArray!(Unqual!U)(len.to!size_t);
        static if (is(Unqual!U == ubyte) || is(Unqual!U == byte) || is(Unqual!U == char))
        {
            arr[] = cast(Unqual!U[]) io.take(len.to!size_t);
        }
        else
        {
            foreach (ref e; arr)
                visit(io, e);
        }
        value = cast(T) arr;
    }
}

/// Structs: visit each field (excludes IO types)
void visit(IO, T)(ref IO io, ref T value)
if (is(T == struct) && !isBinaryIO!T)
{
    foreach (ref f; value.tupleof)
        visit(io, f);
}

// ============================================================================
// Transformation patterns (from SERIALIZATION_PATTERNS.md)
// ============================================================================

/// Transform between wire format (Wire) and runtime type (T).
/// This is the fundamental pattern for type conversions.
void visitTransformed(IO, Wire, T)(ref IO io, ref T value,
    scope T delegate(Wire) fromWire, scope Wire delegate(ref T) toWire)
{
    Wire w;
    static if (IO.isWriting)
        w = toWire(value);
    visit(io, w);
    static if (!IO.isWriting)
        value = fromWire(w);
}

/// Visit a boolean value encoded as a single byte (0 = false, non-zero = true)
void visitBool(IO)(ref IO io, ref bool value)
{
    visitTransformed(io, value,
        (ubyte w) => w != 0,
        (ref bool v) => cast(ubyte)(v ? 1 : 0)
    );
}

// ============================================================================
// Delta encoding
// ============================================================================

/// Unified delta codec for arrays of structs with integer fields.
/// Encodes/decodes each value as the difference from the previous value,
/// using zigzag encoding for efficient varint representation.
/// Recursively handles nested structs.
struct DeltaCodec(T)
{
    T prev = T.init;

    void visit(IO)(ref IO io, ref T value)
    {
        visitValue(io, value, prev);
        prev = value;
    }

    /// Delta-encode/decode a value (integer, struct, or other)
    private static void visitValue(IO, S)(ref IO io, ref S value, ref S prevVal)
    {
        static if (is(S == long) || is(S == ulong))
        {
            // Delta-encode integers directly
            static if (IO.isWriting)
            {
                auto delta = cast(long) value - cast(long) prevVal;
                visitSignedVarint(io, delta);
            }
            else
            {
                long delta;
                visitSignedVarint(io, delta);
                value = cast(S)(cast(long) prevVal + delta);
            }
        }
        else static if (is(S == struct))
        {
            // Recursively visit struct fields
            static foreach (i, field; S.tupleof)
            {{
                visitValue(io, value.tupleof[i], prevVal.tupleof[i]);
            }}
        }
        else
        {
            // Non-integer, non-struct fields: visit normally (no delta)
            .visit(io, value);
        }
    }
}

// ============================================================================
// Array helpers
// ============================================================================

/// Visit array length prefix, allocating on read using GC.
/// Note: This only visits the length prefix, not the array elements.
void visitLength(IO, T)(ref IO io, ref T[] arr)
{
    visitTransformed(io, arr,
        (ulong len) => new T[len.to!size_t],
        (ref T[] a) => cast(ulong) a.length
    );
}

/// Visit a delta-encoded array with wire/runtime type conversion.
/// Each element is delta-encoded relative to the previous.
/// Parameter order matches visitTransformed: (fromWire, toWire).
void visitDeltaArray(IO, Wire, T)(
    ref IO io,
    T[] arr,
    scope void delegate(Wire, ref T) fromWire,
    scope Wire delegate(ref T) toWire)
{
    DeltaCodec!Wire codec;
    foreach (ref elem; arr)
    {
        Wire w;
        static if (IO.isWriting)
            w = toWire(elem);
        codec.visit(io, w);
        static if (!IO.isWriting)
            fromWire(w, elem);
    }
}

/// Visit a delta-encoded array where wire and runtime types are the same
void visitDeltaArray(IO, T)(ref IO io, T[] arr)
{
    DeltaCodec!T codec;
    foreach (ref elem; arr)
        codec.visit(io, elem);
}

/// Visit delta-encoded elements with bidirectional callbacks.
/// On write: calls toWire(i) for each index, delta-encodes and writes the result.
/// On read: delta-decodes each element, calls fromWire(i, w) with the decoded wire value.
/// Parameter order matches visitTransformed: (fromWire, toWire).
void visitDeltaElements(IO, Wire)(
    ref IO io,
    size_t count,
    scope void delegate(size_t i, Wire w) fromWire,
    scope Wire delegate(size_t i) toWire
) {
    DeltaCodec!Wire codec;
    foreach (i; 0 .. count)
    {
        Wire w;
        static if (IO.isWriting)
            w = toWire(i);
        codec.visit(io, w);
        static if (!IO.isWriting)
            fromWire(i, w);
    }
}

// ============================================================================
// Composition helpers for reducing static if branching
// ============================================================================

/// Visit a counted sequence of items without destination array.
/// On write: writes writeRange.length, then iterates range passing &elem to visitor.
/// On read: reads count, then calls visitor with null that many times.
/// Useful when items are allocated individually rather than into a pre-allocated array.
void visitCountedItems(Elem, IO, WriteRange)(
    ref IO io,
    WriteRange writeRange,
    scope void delegate(Elem*) visitor
) {
    ulong numItems;
    static if (IO.isWriting)
    {
        static if (is(WriteRange == typeof(null)))
            static assert(0, "Cannot use null range on write path");
        numItems = writeRange.length;
    }
    visit(io, numItems);

    static if (IO.isWriting)
    {
        foreach (ref elem; writeRange)
            visitor(&elem);
    }
    else
    {
        foreach (_; 0 .. numItems.to!size_t)
            visitor(null);
    }
}

/// Visit array length prefix where write length comes from a different source.
/// On write: encodes writeLength. On read: decodes length and allocates readDest.
/// Note: This only visits the length prefix, not the array elements.
void visitLengthPrefix(IO, R)(ref IO io, ref R[] readDest, size_t writeLength)
{
    visitTransformed(io, readDest,
        (ulong len) => new R[len.to!size_t],
        (ref R[] _) => cast(ulong) writeLength
    );
}

// ============================================================================
// Table visitor patterns
// ============================================================================

/// Delta-encode a table where write source is a range (not indexable).
/// On write: iterates writeSource range. On read: iterates readDest array by index.
/// Parameter order matches visitTransformed: (fromWire, toWire).
void visitDeltaTableRange(IO, Wire, ReadDest, WriteElem, WriteRange)(
    ref IO io,
    ref ReadDest[] readDest,
    size_t writeLen,
    WriteRange writeSource,
    scope void delegate(size_t idx, Wire, ref ReadDest) fromWire,
    scope Wire delegate(ref WriteElem) toWire
) {
    // Length prefix
    visitLengthPrefix(io, readDest, writeLen);

    // Delta-encoded elements
    DeltaCodec!Wire codec;
    static if (IO.isWriting)
    {
        foreach (ref item; writeSource)
        {
            Wire w = toWire(item);
            codec.visit(io, w);
        }
    }
    else
    {
        foreach (i, ref dest; readDest)
        {
            Wire w;
            codec.visit(io, w);
            fromWire(i, w, dest);
        }
    }
}

// ============================================================================
// Index visitors
// ============================================================================

/// Visit a BrowserRoot table index
void visitBrowserRootIndex(IO)(ref IO io, ref BrowserPath* value)
{
    visitTransformed(io, value,
        (IO.Index idx) {
            enforce(idx < io.browserRootPtrs.length, "Invalid BrowserRoot index");
            return io.resolveBrowserRoot(idx);
        },
        (ref BrowserPath* bp) => io.getBrowserRootIndex(bp)
    );
}

// ============================================================================
// Detection
// ============================================================================

/// Check if a file is in binary format by reading the magic bytes
bool isBinaryFormat(string path)
{
    import std.file : read;
    alias Header = BinaryHeader!(BinaryFormatVersion.v1);

    auto data = read(path, Header.sizeof);
    if (data.length < Header.sizeof)
        return false;

    return data[0 .. 8] == Header.init.magic;
}

// ============================================================================
// Unified format visitors
// ============================================================================

void visitHeader(IO, Header)(ref IO io, ref Header header)
if (is(Header == BinaryHeader!ver, BinaryFormatVersion ver))
{
    visit(io, header);
}

void visitFsPath(IO)(ref IO io, ref string fsPathValue)
{
    const(ubyte)[] fsPathBytes;
    static if (IO.isWriting)
        fsPathBytes = cast(const(ubyte)[]) fsPathValue;
    visit(io, fsPathBytes);
    static if (!IO.isWriting)
        fsPathValue = cast(string) fsPathBytes;
}

void visitStringTable(IO)(ref IO io)
{
    // Length prefix + allocate
    visitLength(io, io.strings);

    // Elements: strings as byte arrays
    foreach (ref s; io.strings)
    {
        visitTransformed(io, s,
            (const(ubyte)[] bytes) => cast(string) bytes,
            (ref string str) => cast(const(ubyte)[]) str
        );
    }
}

void visitSubPaths(IO)(ref IO io)
{
    import std.experimental.allocator : make;
    import std.typecons : Tuple;

    // Wire format: (nameIndex, parentIndex) - both as varints, delta-encoded
    alias Wire = Tuple!(ulong, "nameIndex", ulong, "parentIndex");

    visitDeltaTableRange!(IO, Wire, btdu.paths.SubPath*, btdu.paths.SubPath)(
        io,
        io.subPathPtrs,
        subPathAllocator.length,
        subPathAllocator[],
        // fromWire: convert wire format to SubPath and store
        (size_t i, Wire w, ref btdu.paths.SubPath* spPtr) {
            enforce(w.nameIndex < io.strings.length, "SubPath: invalid name index");
            enforce(w.parentIndex == -1 || w.parentIndex < i, "SubPath: invalid parent index");

            auto parent = (w.parentIndex == -1) ? &subPathRoot : io.subPathPtrs[w.parentIndex.to!size_t];
            spPtr = make!(btdu.paths.SubPath)(subPathAllocator, parent,
                btdu.paths.SubPath.NameString(io.resolveString(w.nameIndex)));
        },
        // toWire: convert SubPath to wire format
        (ref btdu.paths.SubPath sp) {
            return Wire(io.getStringIndex(sp.name[]), io.getSubPathIndex(sp.parent));
        }
    );
}

void visitRoots(IO, RootsList, RootIDsList)(ref IO io, RootsList rootsList, RootIDsList rootIDsList)
{
    import std.experimental.allocator : make;
    import std.typecons : Tuple;
    import btdu.state : globalRoots, RootInfo;

    // Wire format: (rootID, parentRootIndex, subPathIndex) - all as varints, delta-encoded
    alias Wire = Tuple!(ulong, "rootID", ulong, "parentRootIndex", ulong, "subPathIndex");

    // Get write length (0 on read path since rootsList is null)
    static if (IO.isWriting)
        immutable writeLen = rootsList.length;
    else
        immutable writeLen = size_t(0);

    // Length prefix + allocate
    visitLengthPrefix(io, io.rootPtrs, writeLen);

    // Iteration count: writeLen on write (io.rootPtrs not populated), io.rootPtrs.length on read
    immutable count = IO.isWriting ? writeLen : io.rootPtrs.length;

    // Elements: delta-encoded with bidirectional callbacks
    visitDeltaElements!(IO, Wire)(io, count,
        // fromWire: convert wire format to runtime data (read path)
        (size_t i, Wire w) {
            static if (!IO.isWriting)
            {
                enforce(w.parentRootIndex == -1 || w.parentRootIndex < i, "Root: invalid parent index");
                enforce(w.subPathIndex == -1 || w.subPathIndex < io.subPathPtrs.length, "Root: invalid subPath index");

                auto gp = growAllocator.make!PathsGlobalPath();
                gp.parent = io.resolveRoot(w.parentRootIndex);
                gp.subPath = io.resolveSubPath(w.subPathIndex);
                io.rootPtrs[i] = gp;

                if (io.target == DataSet.main)
                    globalRoots[w.rootID] = RootInfo(gp, false);
            }
        },
        // toWire: convert runtime data to wire format (write path)
        (size_t i) {
            static if (IO.isWriting)
                return Wire(rootIDsList[i], io.getRootIndex(rootsList[i].parent), io.getSubPathIndex(rootsList[i].subPath));
            else
                return Wire.init;
        }
    );
}

void visitBrowserRoots(IO, BrowserRootsList)(ref IO io, BrowserRootsList browserRootsList)
{
    import std.typecons : Tuple;

    // Wire format: (parentIndex, nameIndex) - both as varints, delta-encoded
    alias Wire = Tuple!(ulong, "parentIndex", ulong, "nameIndex");

    // Get write length (0 on read path since browserRootsList is null)
    static if (IO.isWriting)
        immutable writeLen = browserRootsList.length;
    else
        immutable writeLen = size_t(0);

    // Length prefix + allocate
    visitLengthPrefix(io, io.browserRootPtrs, writeLen);

    // Iteration count: writeLen on write (io.browserRootPtrs not populated), io.browserRootPtrs.length on read
    immutable count = IO.isWriting ? writeLen : io.browserRootPtrs.length;

    // Elements: delta-encoded with bidirectional callbacks
    visitDeltaElements!(IO, Wire)(io, count,
        // fromWire: convert wire format to runtime data (read path)
        (size_t i, Wire w) {
            static if (!IO.isWriting)
            {
                enforce(w.parentIndex == -1 || w.parentIndex < i, "BrowserRoot: invalid parent index");
                enforce(w.nameIndex < io.strings.length, "BrowserRoot: invalid name index");

                if (i == 0)
                    io.browserRootPtrs[i] = io.targetState.rootPtr;
                else
                {
                    auto parent = io.browserRootPtrs[w.parentIndex.to!size_t];
                    io.browserRootPtrs[i] = parent.appendName(io.resolveString(w.nameIndex));
                }
            }
        },
        // toWire: convert runtime data to wire format (write path)
        (size_t i) {
            static if (IO.isWriting)
                return Wire(io.getBrowserRootIndex(browserRootsList[i].parent), io.getStringIndex(browserRootsList[i].name[]));
            else
                return Wire.init;
        }
    );
}

void visitSharingGroup(IO)(ref IO io, SharingGroup* group)
{
    import std.experimental.allocator : make, makeArray;
    import std.typecons : Tuple;
    import btdu.state : sharingGroupAllocator,
        numSharingGroups, numSingleSampleGroups, populateBrowserPathsFromSharingGroup;

    alias Index = IO.Index;

    // Wire format for GlobalPath: (parentRootIndex, subPathIndex)
    alias GlobalPathWire = Tuple!(ulong, "parentRootIndex", ulong, "subPathIndex");

    // Wire format for Offset: signed longs for efficient zigzag encoding of -1
    alias OffsetWire = Tuple!(long, "logical", long, "devID", long, "physical");

    // For reading: allocate the group upfront
    static if (!IO.isWriting)
        group = make!SharingGroup(sharingGroupAllocator);

    // Browser root index
    visitBrowserRootIndex(io, group.root);

    // Paths array: length prefix + allocate
    visitTransformed(io, group.paths,
        (Index len) {
            enforce(len > 0, "SharingGroup must have at least one path");
            return growAllocator.makeArray!PathsGlobalPath(len.to!size_t);
        },
        (ref PathsGlobalPath[] arr) => Index(arr.length)
    );

    // Paths elements: delta-encoded with wire/runtime type conversion
    visitDeltaArray!(IO, GlobalPathWire)(io, group.paths,
        (GlobalPathWire w, ref PathsGlobalPath p) {
            enforce(w.subPathIndex == -1 || w.subPathIndex < io.subPathPtrs.length,
                "SharingGroup path: invalid subPath index");
            p.parent = io.resolveRoot(w.parentRootIndex);
            p.subPath = io.resolveSubPath(w.subPathIndex);
        },
        (ref PathsGlobalPath p) {
            return GlobalPathWire(io.getRootIndex(p.parent), io.getSubPathIndex(p.subPath));
        }
    );

    // Samples and duration
    visit(io, group.data.samples);
    visit(io, group.data.duration);

    // Offsets (delta-encoded with wire/runtime type conversion)
    visitDeltaArray!(IO, OffsetWire)(io, group.data.offsets[],
        (OffsetWire w, ref Offset off) {
            off.logical = w.logical;
            off.devID = w.devID;
            off.physical = w.physical;
        },
        (ref Offset off) => OffsetWire(off.logical, off.devID, off.physical)
    );

    // LastSeen (delta-encoded, same wire and runtime type)
    visitDeltaArray(io, group.lastSeen[]);

    // Representative index
    visitTransformed(io, group.representativeIndex,
        (Index idx) {
            enforce(idx < group.paths.length, "Invalid representativeIndex");
            return idx.to!size_t;
        },
        (ref size_t idx) => Index(idx)
    );

    // For reading: finalize the group
    static if (!IO.isWriting)
    {
        group.pathData = growAllocator.makeArray!(SharingGroup.PathData)(group.paths.length).ptr;

        // Only update global counters for main dataset
        if (io.target == DataSet.main)
        {
            numSharingGroups++;
            if (group.data.samples == 1)
                numSingleSampleGroups++;
        }

        populateBrowserPathsFromSharingGroup(
            group,
            true,
            group.data.samples,
            group.data.offsets[],
            group.data.duration,
            io.target
        );
    }
}

void visitSharingGroups(IO, GroupsList)(ref IO io, GroupsList groupsList)
{
    visitCountedItems!SharingGroup(io, groupsList, (SharingGroup* g) {
        visitSharingGroup(io, g);
    });
}

void visitMark(IO)(ref IO io, ref BrowserPath* markPath, ref bool marked)
{
    // Path stored as index into browserRootPtrs (all marked paths are interned there)
    visitBrowserRootIndex(io, markPath);

    // Mark value (bool as byte)
    visitBool(io, marked);

    // Apply mark on read
    static if (!IO.isWriting)
    {
        if (io.target == DataSet.main)
            markPath.setMark(marked);
    }
}

void visitMarks(IO, MarksList)(ref IO io, MarksList marksList)
{
    visitCountedItems!MarkData(io, marksList, (MarkData* mark) {
        BrowserPath* path;
        bool marked;
        if (mark)
        {
            path = cast(BrowserPath*) mark.path;
            marked = mark.marked;
        }
        visitMark(io, path, marked);
    });
}

// ============================================================================
// Export
// ============================================================================

import btdu.state : browserRoot, browserRootPtr, globalRoots, sharingGroupAllocator, expert, physical, totalSize, fsPath, fsid, imported;

void exportBinary(BinaryFormatVersion ver = latestBinaryFormatVersion)(string path)
{
    import std.exception : enforce;

    alias Header = BinaryHeader!ver;
    alias Index = ulong;

    // Binary format requires SharingGroups which only exist for live-sampled data.
    enforce(!imported || sharingGroupAllocator[].length > 0,
        "Cannot export to binary format: data was imported from JSON which lacks " ~
        "the detailed sampling information required by the binary format. " ~
        "Use JSON format instead (--export-format=json).");

    auto file = path is null
        ? File("/dev/stdout", "wb")
        : File(path, "wb");

    BinaryIO!(ver, true) io;
    io.file = file;

    // ========================================================================
    // Phase 1: Collect all data and assign indices
    // ========================================================================

    // String collection
    string[] allStringRefs;

    void collectString(string s)
    {
        allStringRefs ~= s;
    }

    void finalizeStrings()
    {
        import std.algorithm.sorting : sort;
        import std.algorithm.iteration : uniq;
        import std.array : array;

        sort(allStringRefs);
        io.strings = allStringRefs.uniq.array;
        allStringRefs = null;
    }

    // Roots collection
    const(PathsGlobalPath)*[] roots;
    Index[] rootIDs;

    void collectRoot(Index rootID, const(PathsGlobalPath)* gp)
    {
        if (gp is null) return;
        if (gp in io.rootToIndex) return;

        if (gp.parent)
            collectRoot(-1, gp.parent);

        auto idx = Index(roots.length);
        roots ~= gp;
        rootIDs ~= rootID;
        io.rootToIndex[gp] = idx;
    }

    // Collect roots from globalRoots
    {
        import std.algorithm.sorting : sort;
        alias RootEntry = Tuple!(Index, "id", const(PathsGlobalPath)*, "path");
        RootEntry[] entries;
        foreach (rootID, ref rootInfo; globalRoots)
            entries ~= RootEntry(rootID, rootInfo.path);
        entries.sort!((a, b) => a.id < b.id);
        foreach (entry; entries)
            collectRoot(entry.id, entry.path);
    }

    // Collect SubPath names
    foreach (ref sp; subPathAllocator[])
        collectString(cast(string) sp.name[]);

    // Collect roots from sharing groups
    foreach (ref group; sharingGroupAllocator[])
    {
        foreach (ref gp; group.paths)
        {
            for (auto p = gp.parent; p !is null; p = p.parent)
            {
                if (p !in io.rootToIndex)
                    collectRoot(-1, p);
            }
        }
    }

    // BrowserPath roots collection
    const(BrowserPath)*[] browserRoots;

    Index internBrowserRoot(const(BrowserPath)* bp)
    {
        if (bp is null) return -1;
        if (auto p = bp in io.browserRootToIndex) return *p;

        if (bp.parent)
            internBrowserRoot(bp.parent);

        collectString(cast(string) bp.name[]);

        auto idx = Index(browserRoots.length);
        browserRoots ~= bp;
        io.browserRootToIndex[bp] = idx;
        return idx;
    }

    internBrowserRoot(browserRootPtr);

    foreach (ref group; sharingGroupAllocator[])
        internBrowserRoot(group.root);

    // Collect marks - intern paths into browserRoots (marks use browserRoot indices)
    MarkData[] marks;

    browserRoot.enumerateMarks((const(BrowserPath)* path, bool marked) {
        marks ~= MarkData(path, marked);
        internBrowserRoot(path);  // Ensure marked paths are indexed
    });

    // Finalize strings
    finalizeStrings();

    // ========================================================================
    // Phase 2: Write using unified visitors
    // ========================================================================

    Header header;
    header.fsid = fsid;
    header.totalSize = totalSize;

    if (expert)
        header.flags |= Header.Flags.expert;
    if (physical)
        header.flags |= Header.Flags.physical;

    visitHeader(io, header);

    string fsPathCopy = fsPath;
    visitFsPath(io, fsPathCopy);

    visitStringTable(io);
    visitSubPaths(io);
    visitRoots(io, roots, rootIDs);
    visitBrowserRoots(io, browserRoots);
    visitSharingGroups(io, sharingGroupAllocator[]);
    visitMarks(io, marks);
}

// ============================================================================
// Import
// ============================================================================

void importBinary(string path, DataSet target = DataSet.main)
{
    import ae.sys.datamm : mapFile, MmMode;

    auto mmapped = mapFile(path, MmMode.read);
    auto data = mmapped.unsafeContents;

    // Read just the magic and version to determine format version
    // (these are fixed-size fields at known offsets)
    enforce(data.length >= 12, "File too small for header");
    ubyte[8] magic = data[0 .. 8][0 .. 8];
    auto formatVersion = *cast(BinaryFormatVersion*)&data[8];

    enforce(magic == BinaryHeader!().init.magic, "Invalid magic bytes");

    switch (formatVersion)
    {
        static foreach (ver; EnumMembers!BinaryFormatVersion)
            case ver:
                return importBinaryImpl!ver(data, target);
        default:
            throw new Exception("Unsupported format version: " ~ formatVersion.to!string);
    }
}

void importBinaryImpl(BinaryFormatVersion ver)(const(ubyte)[] data, DataSet target)
{
    import btdu.state : imported, states, compareMode, fsid;
    debug(check) import btdu.state : checkState;

    alias Header = BinaryHeader!ver;

    BinaryIO!(ver, false) io;
    io.data = data;
    io.pos = 0;
    io.targetState = &states[target];
    io.target = target;

    // Read header properly using visit (handles varint encoding for totalSize)
    Header header;
    visitHeader(io, header);

    io.targetState.totalSize = header.totalSize;
    // Expert flag: use CLI setting, not file. Binary format always contains
    // complete data for all metrics. Set compare to match main for consistency.
    io.targetState.expert = states[DataSet.main].expert;
    // Physical flag: always set from file - it indicates how data was sampled
    io.targetState.physical = (header.flags & Header.Flags.physical) != 0;

    // Read using unified visitors
    string fileFsPath;
    visitFsPath(io, fileFsPath);
    if (target == DataSet.main)
    {
        fsPath = fileFsPath;
        static if (ver >= BinaryFormatVersion.v2)
            fsid = header.fsid;
    }

    visitStringTable(io);
    visitSubPaths(io);
    visitRoots(io, null, null);
    visitBrowserRoots(io, null);
    visitSharingGroups(io, null);
    visitMarks(io, null);

    debug(check) checkState();

    if (target == DataSet.main)
        imported = true;
    else
        compareMode = true;
}
