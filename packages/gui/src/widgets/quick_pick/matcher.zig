//! QuickPick matchers (E04.F05.S04.T01): the `Matcher` interface and
//! `SubsequenceMatcher`, the default.
//!
//! `SubsequenceMatcher` is an intentionally simple baseline (fzf "v1"
//! style): the query must appear in order, case-insensitively; the match
//! window is tightened from the right, then scored:
//!
//! - every matched character scores `score_match`;
//! - a match at the start of the candidate, after a word separator
//!   (space, `_`, `-`, `.`, `:`), after a path separator, or on a camelCase
//!   hump gets a bonus, and matches in a row get `bonus_consecutive`;
//! - a gap costs `penalty_gap_start` plus `penalty_gap_extension` per
//!   skipped character; an exact-case match scores one more;
//! - shorter candidates win ties.
//!
//! E08 supplies a better fuzzy matcher for file paths.

const std = @import("std");

/// Scores candidates against a query; null when the candidate does not
/// match. Must be thread-safe (async providers score on workers).
pub const Matcher = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable,

    /// The operations.
    pub const VTable = struct {
        /// Appends highlighted byte ranges `[start, end)` of `candidate`
        /// to `out_hl`.
        score: *const fn (ptr: ?*anyopaque, query: []const u8, candidate: []const u8, out_hl: *std.ArrayList([2]u32), gpa: std.mem.Allocator) ?i32,
    };

    /// Scores `candidate`; see `VTable.score`.
    pub fn score(m: Matcher, query: []const u8, candidate: []const u8, out_hl: *std.ArrayList([2]u32), gpa: std.mem.Allocator) ?i32 {
        return m.vtable.score(m.ptr, query, candidate, out_hl, gpa);
    }
};

pub const score_match: i32 = 16;
pub const bonus_first: i32 = 10;
pub const bonus_boundary: i32 = 8;
pub const bonus_path: i32 = 9;
pub const bonus_camel: i32 = 7;
pub const bonus_consecutive: i32 = 5;
pub const penalty_gap_start: i32 = 3;
pub const penalty_gap_extension: i32 = 1;

/// The default matcher (stateless).
pub const SubsequenceMatcher = struct {
    /// The `Matcher` interface.
    pub fn matcher() Matcher {
        return .{ .vtable = &vtable };
    }

    const vtable: Matcher.VTable = .{ .score = scoreFn };

    fn scoreFn(_: ?*anyopaque, query: []const u8, candidate: []const u8, out_hl: *std.ArrayList([2]u32), gpa: std.mem.Allocator) ?i32 {
        return scoreOf(query, candidate, out_hl, gpa);
    }
};

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn isWordSep(c: u8) bool {
    return c == ' ' or c == '_' or c == '-' or c == '.' or c == ':' or c == '\t';
}

/// The bonus for a match at `i` of `s`.
fn bonusAt(s: []const u8, i: usize) i32 {
    if (i == 0) return bonus_first;
    const p = s[i - 1];
    const c = s[i];
    if (p == '/' or p == '\\') return bonus_path;
    if (isWordSep(p)) return bonus_boundary;
    if (std.ascii.isLower(p) and std.ascii.isUpper(c)) return bonus_camel;
    if (!std.ascii.isDigit(p) and std.ascii.isDigit(c)) return bonus_camel;
    return 0;
}

/// Scores `candidate` against `query` (see the file comment) and appends
/// the matched ranges to `out_hl`. An empty query matches with score 0.
pub fn scoreOf(query: []const u8, candidate: []const u8, out_hl: *std.ArrayList([2]u32), gpa: std.mem.Allocator) ?i32 {
    if (query.len == 0) return 0;
    if (query.len > candidate.len) return null;
    // Forward: the first window end.
    var qi: usize = 0;
    var end: usize = 0;
    for (candidate, 0..) |c, i| {
        if (lower(c) == lower(query[qi])) {
            qi += 1;
            if (qi == query.len) {
                end = i + 1;
                break;
            }
        }
    }
    if (qi < query.len) return null;
    // Backward: the tightest start for that end.
    var start: usize = end;
    qi = query.len;
    while (start > 0 and qi > 0) {
        start -= 1;
        if (lower(candidate[start]) == lower(query[qi - 1])) qi -= 1;
    }
    // Forward within the window, preferring a boundary when the next
    // query character also appears at one before the window runs out.
    var total: i32 = 0;
    var prev: ?usize = null;
    var run_start: usize = 0;
    var i = start;
    qi = 0;
    while (qi < query.len) : (qi += 1) {
        const q = lower(query[qi]);
        // Earliest position for this character.
        while (lower(candidate[i]) != q) i += 1;
        // A later boundary match that still leaves room for the rest.
        if (bonusAt(candidate, i) == 0 and (prev == null or prev.? + 1 != i)) {
            var j = i + 1;
            const limit = end - (query.len - qi - 1);
            while (j < limit) : (j += 1) {
                if (lower(candidate[j]) == q and bonusAt(candidate, j) > 0 and fits(query[qi + 1 ..], candidate[j + 1 .. end])) {
                    i = j;
                    break;
                }
            }
        }
        total += score_match + bonusAt(candidate, i);
        if (candidate[i] == query[qi]) total += 1;
        if (prev) |p| {
            if (p + 1 == i) {
                total += bonus_consecutive;
            } else {
                total -= penalty_gap_start + penalty_gap_extension * @as(i32, @intCast(i - p - 2));
                out_hl.append(gpa, .{ @intCast(run_start), @intCast(p + 1) }) catch {};
                run_start = i;
            }
        } else run_start = i;
        prev = i;
        i += 1;
    }
    out_hl.append(gpa, .{ @intCast(run_start), @intCast(prev.? + 1) }) catch {};
    // Shorter candidates win ties.
    total -= @intCast(@min(candidate.len / 16, 15));
    return total;
}

/// True when `q` is a case-insensitive subsequence of `s`.
fn fits(q: []const u8, s: []const u8) bool {
    var k: usize = 0;
    for (s) |c| {
        if (k == q.len) break;
        if (lower(c) == lower(q[k])) k += 1;
    }
    return k == q.len;
}

const Case = struct { q: []const u8, c: []const u8, hl: []const [2]u32 };

test "subsequence matcher highlights and bonuses" {
    const gpa = std.testing.allocator;
    var hl: std.ArrayList([2]u32) = .empty;
    defer hl.deinit(gpa);
    const cases = [_]Case{
        .{ .q = "of", .c = "Open File", .hl = &.{ .{ 0, 1 }, .{ 5, 6 } } },
        .{ .q = "gtd", .c = "Go to Definition", .hl = &.{ .{ 0, 1 }, .{ 3, 4 }, .{ 6, 7 } } },
        .{ .q = "fb", .c = "src/foo/bar.zig", .hl = &.{ .{ 4, 5 }, .{ 8, 9 } } },
        .{ .q = "qp", .c = "QuickPick", .hl = &.{ .{ 0, 1 }, .{ 5, 6 } } },
        .{ .q = "pick", .c = "QuickPick", .hl = &.{.{ 5, 9 }} },
        .{ .q = "", .c = "anything", .hl = &.{} },
    };
    for (cases) |cs| {
        hl.clearRetainingCapacity();
        try std.testing.expect(scoreOf(cs.q, cs.c, &hl, gpa) != null);
        try std.testing.expectEqualSlices([2]u32, cs.hl, hl.items);
    }
    hl.clearRetainingCapacity();
    try std.testing.expect(scoreOf("xyz", "Open File", &hl, gpa) == null);
    try std.testing.expect(scoreOf("toolong", "short", &hl, gpa) == null);
}

test "subsequence matcher ranks word starts, runs and short candidates first" {
    const gpa = std.testing.allocator;
    var hl: std.ArrayList([2]u32) = .empty;
    defer hl.deinit(gpa);
    const s = struct {
        fn of(q: []const u8, c: []const u8, h: *std.ArrayList([2]u32)) i32 {
            h.clearRetainingCapacity();
            return scoreOf(q, c, h, std.testing.allocator).?;
        }
    };
    // Word starts beat mid-word letters.
    try std.testing.expect(s.of("of", "Open File", &hl) > s.of("of", "proof", &hl));
    // A consecutive run beats a scattered match.
    try std.testing.expect(s.of("save", "File: Save", &hl) > s.of("save", "Show All Views Everywhere", &hl));
    // camelCase humps count as word starts.
    try std.testing.expect(s.of("gs", "getSymbol", &hl) > s.of("gs", "gauss", &hl));
    // Ties go to the shorter candidate.
    try std.testing.expect(s.of("main", "main.zig", &hl) > s.of("main", "main.zig.orig.backup.old.txt", &hl));
}
