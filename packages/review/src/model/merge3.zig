//! Three-way line merge (E12.F02.S03.T02, E12.F04.S01.T02): combines the
//! changes `ours` and `theirs` made to `base`, line by line, byte-exact.
//!
//! Each side's changes are found with E05's histogram line diff. Changes
//! that do not overlap are both taken. Overlapping changes (and two
//! insertions at one point, or an insertion touching a change) that are
//! not identical are a conflict: the result keeps the side named by
//! `prefer` there and reports the region.
//!
//! zg_scm has no content merge yet (E09.F04 `mergeContent`); this one
//! moves there when it does.

const std = @import("std");
const zg_editor = @import("zg_editor");

const Allocator = std.mem.Allocator;
const diff = zg_editor.model.diff;

pub const Side = enum { ours, theirs };

pub const Options = struct {
    /// What a conflicting region becomes.
    prefer: Side = .ours,
};

/// Lines `[start, end)` of each text.
pub const Conflict = struct {
    base: [2]u32,
    ours: [2]u32,
    theirs: [2]u32,
};

pub const Result = struct {
    text: []u8,
    conflicts: []Conflict,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.text);
        gpa.free(r.conflicts);
    }
};

/// The lines of `text`, each with its terminator (`\n`, `\r\n`, or a lone
/// `\r`); the last may have none.
pub fn splitLines(gpa: Allocator, text: []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\n' or c == '\r') {
            if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
            try out.append(gpa, text[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < text.len) try out.append(gpa, text[start..]);
    return out.toOwnedSlice(gpa);
}

/// One side's change: base lines `[b0, b1)` became side lines `[s0, s1)`.
const Region = struct { b0: u32, b1: u32, s0: u32, s1: u32 };

fn regionsOf(gpa: Allocator, edits: []const diff.Edit) Allocator.Error![]Region {
    var out: std.ArrayList(Region) = .empty;
    errdefer out.deinit(gpa);
    var a: u32 = 0;
    var b: u32 = 0;
    var open: ?Region = null;
    for (edits) |e| switch (e.kind) {
        .equal => {
            if (open) |r| try out.append(gpa, r);
            open = null;
            a += e.len;
            b += e.len;
        },
        .delete, .insert => {
            var r = open orelse Region{ .b0 = a, .b1 = a, .s0 = b, .s1 = b };
            if (e.kind == .delete) a += e.len else b += e.len;
            r.b1 = a;
            r.s1 = b;
            open = r;
        },
    };
    if (open) |r| try out.append(gpa, r);
    return out.toOwnedSlice(gpa);
}

/// Line ids shared by the three texts (exact bytes, terminators included).
fn intern(gpa: Allocator, sides: [3][]const []const u8, out: *[3][]u32) Allocator.Error!void {
    var map: std.StringHashMapUnmanaged(u32) = .empty;
    defer map.deinit(gpa);
    var made: usize = 0;
    errdefer for (out[0..made]) |o| gpa.free(o);
    for (sides, out) |lines, *o| {
        o.* = try gpa.alloc(u32, lines.len);
        made += 1;
        for (lines, o.*) |l, *id| {
            const g = try map.getOrPut(gpa, l);
            if (!g.found_existing) g.value_ptr.* = map.count() - 1;
            id.* = g.value_ptr.*;
        }
    }
}

/// Merges `ours` and `theirs`, both derived from `base`.
pub fn merge(gpa: Allocator, base: []const u8, ours: []const u8, theirs: []const u8, o: Options) Allocator.Error!Result {
    const bl = try splitLines(gpa, base);
    defer gpa.free(bl);
    const ol = try splitLines(gpa, ours);
    defer gpa.free(ol);
    const tl = try splitLines(gpa, theirs);
    defer gpa.free(tl);
    var ids: [3][]u32 = undefined;
    try intern(gpa, .{ bl, ol, tl }, &ids);
    defer for (ids) |x| gpa.free(x);
    const eo = try diff.diffTokens(gpa, ids[0], ids[1], .histogram, null);
    defer gpa.free(eo);
    const et = try diff.diffTokens(gpa, ids[0], ids[2], .histogram, null);
    defer gpa.free(et);
    const ro = try regionsOf(gpa, eo);
    defer gpa.free(ro);
    const rt = try regionsOf(gpa, et);
    defer gpa.free(rt);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var conflicts: std.ArrayList(Conflict) = .empty;
    errdefer conflicts.deinit(gpa);

    var i: usize = 0;
    var j: usize = 0;
    var pos: u32 = 0; // base lines copied so far
    var d_o: i64 = 0; // side line = base line + delta, outside regions
    var d_t: i64 = 0;
    while (i < ro.len or j < rt.len) {
        const take_o = j >= rt.len or (i < ro.len and ro[i].b0 <= rt[j].b0);
        const first = if (take_o) ro[i] else rt[j];
        const lo = first.b0;
        try appendLines(gpa, &out, bl[pos..lo]);
        // Grow the group with every region that overlaps or touches it
        // ambiguously.
        var hi = first.b1;
        const oi0 = i;
        const tj0 = j;
        if (take_o) i += 1 else j += 1;
        while (true) {
            if (i < ro.len and joins(ro[i], lo, hi)) {
                hi = @max(hi, ro[i].b1);
                i += 1;
            } else if (j < rt.len and joins(rt[j], lo, hi)) {
                hi = @max(hi, rt[j].b1);
                j += 1;
            } else break;
        }
        const o_lo: u32 = @intCast(@as(i64, lo) + d_o);
        const t_lo: u32 = @intCast(@as(i64, lo) + d_t);
        for (ro[oi0..i]) |r| d_o += @as(i64, r.s1 - r.s0) - @as(i64, r.b1 - r.b0);
        for (rt[tj0..j]) |r| d_t += @as(i64, r.s1 - r.s0) - @as(i64, r.b1 - r.b0);
        const o_hi: u32 = @intCast(@as(i64, hi) + d_o);
        const t_hi: u32 = @intCast(@as(i64, hi) + d_t);
        const o_changed = i > oi0;
        const t_changed = j > tj0;
        const os = ol[o_lo..o_hi];
        const ts = tl[t_lo..t_hi];
        if (o_changed and !t_changed) {
            try appendLines(gpa, &out, os);
        } else if (t_changed and !o_changed) {
            try appendLines(gpa, &out, ts);
        } else if (sameLines(os, ts)) {
            try appendLines(gpa, &out, os);
        } else {
            try conflicts.append(gpa, .{ .base = .{ lo, hi }, .ours = .{ o_lo, o_hi }, .theirs = .{ t_lo, t_hi } });
            try appendLines(gpa, &out, if (o.prefer == .ours) os else ts);
        }
        pos = hi;
    }
    try appendLines(gpa, &out, bl[pos..]);
    return .{ .text = try out.toOwnedSlice(gpa), .conflicts = try conflicts.toOwnedSlice(gpa) };
}

/// Whether region `r` (starting at or after `lo`) belongs to the group
/// `[lo, hi)`: it overlaps it, or an insertion meets it at an edge.
fn joins(r: Region, lo: u32, hi: u32) bool {
    if (r.b0 < hi) return true;
    if (r.b0 > hi) return false;
    return r.b0 == r.b1 or lo == hi;
}

fn appendLines(gpa: Allocator, out: *std.ArrayList(u8), lines: []const []const u8) Allocator.Error!void {
    for (lines) |l| try out.appendSlice(gpa, l);
}

fn sameLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectMerge(base: []const u8, ours: []const u8, theirs: []const u8, want: []const u8, n_conflicts: usize) !void {
    var r = try merge(testing.allocator, base, ours, theirs, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(want, r.text);
    try testing.expectEqual(n_conflicts, r.conflicts.len);
}

test "merge3: disjoint changes from both sides" {
    try expectMerge("a\nb\nc\nd\ne\n", "A\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n", "A\nb\nc\nd\nE\n", 0);
    // Adjacent but distinct line changes are both taken.
    try expectMerge("a\nb\nc\n", "A\nb\nc\n", "a\nB\nc\n", "A\nB\nc\n", 0);
    // Inserts and deletes.
    try expectMerge("a\nb\nc\n", "a\nc\n", "a\nb\nc\nd\n", "a\nc\nd\n", 0);
}

test "merge3: one side unchanged returns the other" {
    try expectMerge("x\ny\n", "x\ny\n", "p\nq\nr", "p\nq\nr", 0);
    try expectMerge("x\ny\n", "1\n", "x\ny\n", "1\n", 0);
    try expectMerge("", "", "new\n", "new\n", 0);
}

test "merge3: identical changes merge cleanly" {
    try expectMerge("a\nb\n", "a\nB\n", "a\nB\n", "a\nB\n", 0);
}

test "merge3: overlapping changes conflict" {
    try expectMerge("a\nb\nc\n", "a\nX\nc\n", "a\nY\nc\n", "a\nX\nc\n", 1);
    var r = try merge(testing.allocator, "a\nb\nc\n", "a\nX\nc\n", "a\nY\nc\n", .{ .prefer = .theirs });
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("a\nY\nc\n", r.text);
    try testing.expectEqual(Conflict{ .base = .{ 1, 2 }, .ours = .{ 1, 2 }, .theirs = .{ 1, 2 } }, r.conflicts[0]);
    // Two insertions at one point.
    try expectMerge("a\nb\n", "a\n1\nb\n", "a\n2\nb\n", "a\n1\nb\n", 1);
}

test "merge3: line terminators are part of the line" {
    try expectMerge("a\r\nb\r\n", "a\r\nB\r\n", "a\nb\r\n", "a\nB\r\n", 0);
    // A missing final newline is a change of the last line.
    try expectMerge("a\nb", "a\nb\n", "A\nb", "A\nb\n", 0);
}

test "merge3: restore keeps a later user edit" {
    // pre: before the agent; post: after the agent; cur: post plus a user
    // edit elsewhere. Reverting = merge(base = post, ours = cur, theirs = pre).
    const pre = "fn a() {}\nfn b() {}\nfn c() {}\n";
    const post = "fn a() { agent(); }\nfn b() {}\nfn c() {}\n";
    const cur = "fn a() { agent(); }\nfn b() {}\nfn c() { user(); }\n";
    try expectMerge(post, cur, pre, "fn a() {}\nfn b() {}\nfn c() { user(); }\n", 0);
}

test "merge3: random non-overlapping edits merge to both" {
    var prng: std.Random.DefaultPrng = .init(0xd1ff3);
    const r = prng.random();
    for (0..300) |_| {
        // Ten distinct lines; ours edits even lines, theirs odd lines, with
        // a one-line gap so changes never touch.
        var base: std.ArrayList(u8) = .empty;
        defer base.deinit(testing.allocator);
        var ours: std.ArrayList(u8) = .empty;
        defer ours.deinit(testing.allocator);
        var theirs: std.ArrayList(u8) = .empty;
        defer theirs.deinit(testing.allocator);
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(testing.allocator);
        for (0..30) |k| {
            const line = try std.fmt.allocPrint(testing.allocator, "line {d}\n", .{k});
            defer testing.allocator.free(line);
            try base.appendSlice(testing.allocator, line);
            const which = k % 4;
            const change = r.uintLessThan(u8, 3) == 0;
            const new = try std.fmt.allocPrint(testing.allocator, "changed {d}\n", .{k});
            defer testing.allocator.free(new);
            const o_line = if (which == 0 and change) new else line;
            const t_line = if (which == 2 and change) new else line;
            try ours.appendSlice(testing.allocator, o_line);
            try theirs.appendSlice(testing.allocator, t_line);
            try want.appendSlice(testing.allocator, if (which == 0) o_line else t_line);
        }
        try expectMerge(base.items, ours.items, theirs.items, want.items, 0);
    }
}
