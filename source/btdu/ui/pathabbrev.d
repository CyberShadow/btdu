/**
 * Smart path abbreviation algorithm.
 *
 * Abbreviates paths while preserving unique parts that differ from neighbors.
 * Uses Levenshtein distance to align path segments and identify common/unique runs.
 */
module btdu.ui.pathabbrev;

import std.algorithm;
import std.array : Appender;
import std.conv;
import std.functional : memoize;
import std.typecons;

/// Result of abbreviation - segments with unique/common flags
struct AbbreviatedPath {
    struct Segment {
        dstring text;
        bool isUnique;
    }
    Segment[] segments;

    /// Convert to plain string
    string toString() const {
        Appender!string result;
        foreach (seg; segments) {
            result.put(seg.text.to!string);
        }
        return result[];
    }

    /// Get display width in characters
    size_t width() const {
        size_t w = 0;
        foreach (seg; segments) {
            w += seg.text.length;
        }
        return w;
    }
}

/// Memoized abbreviation function
/// Takes current path, above neighbor, below neighbor, and available width
alias abbreviatePath = memoize!abbreviatePathImpl;

private:

// Main abbreviation function - tries different split levels
AbbreviatedPath abbreviatePathImpl(
    string currentPath,
    string abovePath,  // null if first in list
    string belowPath,  // null if last in list
    size_t availableWidth
) {
    dstring current = currentPath.to!dstring;
    dstring above = abovePath !is null ? abovePath.to!dstring : ""d;
    dstring below = belowPath !is null ? belowPath.to!dstring : ""d;

    if (current.length <= availableWidth) {
        // Fits without abbreviation - return as single segment
        // If we have neighbors, mark the differing parts
        if (above.length > 0 || below.length > 0) {
            auto result = tryAbbreviateAtLevel(current, above, below,
                                               availableWidth, SplitLevel.pathOnly,
                                               false, 1);
            if (!result.isNull) {
                return result.get;
            }
        }
        return AbbreviatedPath([AbbreviatedPath.Segment(current, false)]);
    }

    static immutable nonCharLevels = [
        SplitLevel.pathOnly,
        SplitLevel.withSpace,
        SplitLevel.withDash,
        SplitLevel.withUnderscore,
    ];

    // Skip if no neighbors (can't do smart abbreviation)
    if (above.length == 0 && below.length == 0) {
        return AbbreviatedPath([AbbreviatedPath.Segment(
            middleTruncate(current, availableWidth), false)]);
    }

    // Try non-char levels, first without forceFit, then with forceFit
    foreach (forceFit; [false, true]) {
        foreach (level; nonCharLevels) {
            auto result = tryAbbreviateAtLevel(
                current, above, below,
                availableWidth, level, forceFit, 1
            );
            if (!result.isNull) {
                return result.get;
            }
        }
    }

    // Try everyChar level with decreasing minUniqueRunLength thresholds
    // Start with larger thresholds (prefer fewer, larger unique runs)
    // and decrease towards 1 (accept any unique run)
    static immutable size_t[] defaultThresholds = [20, 10, 5, 3, 2, 1];

    foreach (forceFit; [false, true]) {
        // First try availableWidth as threshold
        auto result = tryAbbreviateAtLevel(
            current, above, below,
            availableWidth, SplitLevel.everyChar, forceFit, availableWidth
        );
        if (!result.isNull) {
            return result.get;
        }

        // Then try standard thresholds
        foreach (minLen; defaultThresholds) {
            if (minLen >= availableWidth) continue;
            result = tryAbbreviateAtLevel(
                current, above, below,
                availableWidth, SplitLevel.everyChar, forceFit, minLen
            );
            if (!result.isNull) {
                return result.get;
            }
        }
    }

    // Final fallback: simple middle truncation (all common)
    return AbbreviatedPath([AbbreviatedPath.Segment(
        middleTruncate(current, availableWidth), false)]);
}

private:

// Split levels - each level adds more separators
enum SplitLevel {
    pathOnly,      // Split by /
    withSpace,     // Split by / or space
    withDash,      // Split by / or space or -
    withUnderscore,// Split by / or space or - or _
    everyChar,     // Split by every character
}

// Get separators for a given split level
dstring getSeparators(SplitLevel level) {
    final switch (level) {
        case SplitLevel.pathOnly:       return "/"d;
        case SplitLevel.withSpace:      return "/ "d;
        case SplitLevel.withDash:       return "/ -"d;
        case SplitLevel.withUnderscore: return "/ -_"d;
        case SplitLevel.everyChar:      return ""d; // Special case
    }
}

// Segment-level representation of a path
struct SegmentedPath {
    dstring[] segments;
    dstring[] separators; // Separator after each segment (last is empty)

    this(dstring path, SplitLevel level) {
        if (level == SplitLevel.everyChar) {
            // Split into individual characters
            foreach (c; path) {
                segments ~= [c];
            }
            // No separators between characters
            separators = new dstring[segments.length];
            separators[] = ""d;
        } else {
            auto seps = getSeparators(level);
            splitBySeparators(path, seps);
        }
    }

    private void splitBySeparators(dstring path, dstring seps) {
        dstring current;
        foreach (c; path) {
            if (seps.canFind(c)) {
                segments ~= current;
                separators ~= [c];
                current = ""d;
            } else {
                current ~= c;
            }
        }
        segments ~= current;
        separators ~= ""d; // No separator after last segment
    }
}

// A run of segments that are either all common or all unique
struct SegmentRun {
    size_t start;
    size_t count;
    bool isCommon;
}

// Result of Levenshtein alignment - which segments in 'a' match segments in 'b'
bool[] findMatchingSegments(const dstring[] a, const dstring[] b) {
    import std.algorithm : levenshteinDistanceAndPath, EditOp;

    if (a.length == 0) return [];

    auto result = levenshteinDistanceAndPath(a, b);
    auto path = result[1];

    bool[] matches = new bool[a.length];
    matches[] = false;

    size_t aIdx = 0;
    foreach (op; path) {
        final switch (op) {
            case EditOp.none:
                assert(aIdx < a.length);
                matches[aIdx] = true;
                aIdx++;
                break;
            case EditOp.substitute:
                aIdx++;
                break;
            case EditOp.insert:
                break;
            case EditOp.remove:
                aIdx++;
                break;
        }
    }

    return matches;
}

// Find runs of common/unique segments
SegmentRun[] findRuns(const dstring[] segments, const bool[] isCommon) {
    if (segments.length == 0) return [];

    SegmentRun[] runs;
    size_t runStart = 0;
    bool currentCommon = isCommon[0];

    foreach (i; 1 .. segments.length) {
        if (isCommon[i] != currentCommon) {
            runs ~= SegmentRun(runStart, i - runStart, currentCommon);
            runStart = i;
            currentCommon = isCommon[i];
        }
    }
    runs ~= SegmentRun(runStart, segments.length - runStart, currentCommon);

    return runs;
}

// Calculate minimum display width for a segment
// Minimum is 5: 2 chars + ellipsis + 2 chars (e.g., "ba…up")
size_t minAbbrevWidth(dstring segment) {
    if (segment.length <= 5) return segment.length;
    return 5;
}

// Middle-truncate a dstring to fit within width
dstring middleTruncate(dstring s, size_t width) {
    if (s.length <= width) return s;
    if (width < 3) {
        return s[0 .. width];
    }

    size_t leftLen = (width - 1) / 2;
    size_t rightLen = width - 1 - leftLen;

    return s[0 .. leftLen] ~ "…"d ~ s[$ - rightLen .. $];
}

// Unit tests
unittest {
    import std.stdio : writeln;

    // Helper to run abbreviation and check width constraint
    void testAbbrev(string current, string above, string below, size_t width,
                    string expectedContains = null, string testName = __FILE__) {
        auto result = abbreviatePath(current, above, below, width);
        auto resultWidth = result.width();

        // Width constraint: result should never exceed available width
        assert(resultWidth <= width,
            "Width exceeded: got " ~ resultWidth.to!string ~ " > " ~ width.to!string);

        // Should not over-abbreviate (unless original is shorter)
        auto minExpected = current.to!dstring.length < width ? current.to!dstring.length : width;
        assert(resultWidth >= minExpected || current.to!dstring.length <= width,
            "Over-abbreviated: got " ~ resultWidth.to!string ~ " < " ~ minExpected.to!string);

        // Check expected substring if provided
        if (expectedContains !is null) {
            auto str = result.toString();
            assert(str.canFind(expectedContains),
                "Expected '" ~ expectedContains ~ "' in '" ~ str ~ "'");
        }
    }

    // Test 1: No abbreviation needed (path fits)
    {
        auto result = abbreviatePath("/short/path", null, null, 50);
        assert(result.toString() == "/short/path");
        assert(result.width() == 11);
    }

    // Test 2: Simple middle truncation (no neighbors)
    {
        auto result = abbreviatePath("/very/long/path/that/needs/truncation", null, null, 20);
        assert(result.width() <= 20);
        assert(result.toString().canFind("…"));
    }

    // Test 3: Smart abbreviation with neighbors - common prefix
    {
        auto result = abbreviatePath(
            "/home/user/project/src/main.rs",
            "/home/user/project/src/lib.rs",
            "/home/user/project/src/utils.rs",
            30
        );
        // Should preserve unique part (main.rs) and abbreviate common parts
        assert(result.toString().canFind("main.rs"));
        assert(result.width() <= 30);
    }

    // Test 4: Unique segment marking
    {
        auto result = abbreviatePath(
            "/a/b/unique/d",
            "/a/b/common/d",
            "/a/b/common/d",
            50
        );
        // Find the unique segment
        bool foundUnique = false;
        foreach (seg; result.segments) {
            if (seg.text.canFind("unique"d)) {
                assert(seg.isUnique, "Segment containing 'unique' should be marked as unique");
                foundUnique = true;
            }
        }
        assert(foundUnique, "Should have found 'unique' segment");
    }

    // Test 5: Width constraint with long paths
    {
        testAbbrev(
            "/very/long/path/with/many/segments/that/definitely/needs/abbreviation",
            "/very/long/path/with/many/segments/that/definitely/needs/other",
            "/very/long/path/with/many/segments/that/definitely/needs/another",
            40
        );
    }

    // Test 6: Edge case - single character available
    {
        auto result = abbreviatePath("/test", null, null, 3);
        assert(result.width() <= 3);
    }

    // Test 7: Different split levels (paths with spaces, dashes, underscores)
    {
        auto result = abbreviatePath(
            "/path/file-with-dashes_and_underscores here.txt",
            "/path/file-with-dashes_and_underscores there.txt",
            null,
            35
        );
        assert(result.width() <= 35);
        // Should preserve unique parts
        assert(result.toString().canFind("here"));
    }

    // Test 8: Unicode handling
    {
        auto result = abbreviatePath(
            "/путь/к/файлу.txt",
            "/путь/к/другому.txt",
            null,
            15
        );
        assert(result.width() <= 15);
    }

    // Test 9: Path with only above neighbor
    {
        auto result = abbreviatePath(
            "/a/b/c/unique_file.txt",
            "/a/b/c/other_file.txt",
            null,
            25
        );
        assert(result.width() <= 25);
    }

    // Test 10: Path with only below neighbor
    {
        auto result = abbreviatePath(
            "/a/b/c/first_file.txt",
            null,
            "/a/b/c/second_file.txt",
            25
        );
        assert(result.width() <= 25);
    }
}

// Try to abbreviate at a specific split level
Nullable!AbbreviatedPath tryAbbreviateAtLevel(
    dstring currentPath,
    dstring abovePath,
    dstring belowPath,
    size_t availableWidth,
    SplitLevel level,
    bool forceFit,
    size_t minUniqueRunLength
) {
    auto current = SegmentedPath(currentPath, level);

    // If no neighbors, nothing is common - can't use smart abbreviation
    if (abovePath.length == 0 && belowPath.length == 0) {
        return Nullable!AbbreviatedPath.init;
    }

    // Find which segments are common with neighbors
    bool[] isCommon = new bool[current.segments.length];

    if (abovePath.length > 0 && belowPath.length > 0) {
        auto above = SegmentedPath(abovePath, level);
        auto below = SegmentedPath(belowPath, level);
        auto matchesAbove = findMatchingSegments(current.segments, above.segments);
        auto matchesBelow = findMatchingSegments(current.segments, below.segments);
        foreach (i; 0 .. current.segments.length) {
            isCommon[i] = matchesAbove[i] && matchesBelow[i];
        }
    } else if (abovePath.length > 0) {
        auto above = SegmentedPath(abovePath, level);
        isCommon = findMatchingSegments(current.segments, above.segments);
    } else {
        auto below = SegmentedPath(belowPath, level);
        isCommon = findMatchingSegments(current.segments, below.segments);
    }

    // Find runs of common/unique segments
    auto runs = findRuns(current.segments, isCommon);

    // Apply minimum unique run length - treat short unique runs as common
    if (minUniqueRunLength > 1) {
        foreach (ref run; runs) {
            if (!run.isCommon && run.count < minUniqueRunLength) {
                run.isCommon = true;
            }
        }
        // Merge adjacent common runs
        SegmentRun[] mergedRuns;
        foreach (run; runs) {
            if (mergedRuns.length > 0 && mergedRuns[$ - 1].isCommon && run.isCommon) {
                mergedRuns[$ - 1].count += run.count;
            } else {
                mergedRuns ~= run;
            }
        }
        runs = mergedRuns;
    }

    // Build run texts with proper separators
    struct RunInfo {
        dstring text;
        size_t allocated;
        bool isCommon;
        dstring leadingSep;
    }
    RunInfo[] runInfos;

    foreach (ri, ref run; runs) {
        Appender!dstring runText;
        foreach (i; run.start .. run.start + run.count) {
            runText.put(current.segments[i]);
            if (i < run.start + run.count - 1) {
                runText.put(current.separators[i]);
            }
        }

        dstring leadingSep = ""d;
        if (run.start > 0) {
            leadingSep = current.separators[run.start - 1];
        }

        runInfos ~= RunInfo(runText[], 0, run.isCommon, leadingSep);
    }

    // Calculate minimum width (abbreviating only common segments)
    size_t minWidthCommonOnly = 0;
    foreach (ri, ref info; runInfos) {
        minWidthCommonOnly += info.leadingSep.length;
        if (info.isCommon) {
            minWidthCommonOnly += minAbbrevWidth(info.text);
        } else {
            minWidthCommonOnly += info.text.length;
        }
    }

    // Calculate absolute minimum width (abbreviating ALL segments)
    size_t minWidthAll = 0;
    foreach (ri, ref info; runInfos) {
        minWidthAll += info.leadingSep.length;
        minWidthAll += minAbbrevWidth(info.text);
    }

    // If even minimum with all abbreviation doesn't fit, signal failure
    if (minWidthAll > availableWidth) {
        return Nullable!AbbreviatedPath.init;
    }

    // If common-only minimum doesn't fit, we need forceFit mode
    if (minWidthCommonOnly > availableWidth && !forceFit) {
        return Nullable!AbbreviatedPath.init;
    }

    // Calculate separator width
    size_t separatorWidth = 0;
    foreach (ref info; runInfos) {
        separatorWidth += info.leadingSep.length;
    }

    size_t spaceForRuns = availableWidth - separatorWidth;

    // Initialize all allocations to minimum
    foreach (ref info; runInfos) {
        info.allocated = minAbbrevWidth(info.text);
    }

    // Distribute remaining space
    size_t usedByMin = 0;
    foreach (ref info; runInfos) {
        usedByMin += info.allocated;
    }

    size_t remaining = spaceForRuns - usedByMin;

    // First priority: grow unique segments to full size
    foreach (ref info; runInfos) {
        if (!info.isCommon && info.allocated < info.text.length) {
            size_t canGrow = info.text.length - info.allocated;
            size_t give = min(canGrow, remaining);
            info.allocated += give;
            remaining -= give;
        }
    }

    // Second priority: distribute remaining space to common segments evenly
    while (remaining > 0) {
        size_t growableCount = 0;
        foreach (ref info; runInfos) {
            if (info.isCommon && info.allocated < info.text.length) {
                growableCount++;
            }
        }

        if (growableCount == 0) break;

        size_t perRun = (remaining + growableCount - 1) / growableCount;

        size_t distributed = 0;
        foreach (ref info; runInfos) {
            if (info.isCommon && info.allocated < info.text.length) {
                size_t canGrow = info.text.length - info.allocated;
                size_t budget = remaining - distributed;
                size_t give = min(perRun, canGrow, budget);
                info.allocated += give;
                distributed += give;
            }
        }

        remaining -= distributed;
        if (distributed == 0) break;
    }

    // Build result with segment info
    AbbreviatedPath result;

    foreach (ref info; runInfos) {
        if (info.leadingSep.length > 0) {
            result.segments ~= AbbreviatedPath.Segment(info.leadingSep, false);
        }

        result.segments ~= AbbreviatedPath.Segment(
            middleTruncate(info.text, info.allocated), !info.isCommon);
    }

    return nullable(result);
}
