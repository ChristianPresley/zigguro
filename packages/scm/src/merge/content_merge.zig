//! File content merge (E09.F04.S01.T02): three-way line merge, and N-way
//! by folding pairwise over the `Merge` terms.
//!
//! Three sides: diff base→left and base→right by lines (raw lines with
//! their EOL bytes, so an EOL-only change is a change), then walk both
//! edit scripts in base order. A change on one side applies. Changes on
//! both sides that overlap or touch (as in git: adjacent edits conflict)
//! form one region; it resolves when both sides made the same edit (under
//! `same_change = .accept`) or one side left it as the base, and is a
//! conflict otherwise. Regions are kept whole; zdiff3 trimming happens at
//! materialization.
//!
//! More sides: merge (side 0, base 0, side 1), then (that, base 1,
//! side 2), and so on. If any step conflicts the whole file is one N-way
//! conflict region, so conflicts never nest.
//!
//! Binary content (`isBinary`) is not merged here: callers keep the
//! conflict at the value level.

const std = @import("std");
const merge_mod = @import("merge.zig");
const mat = @import("materialize.zig");
const Merge = merge_mod.Merge;
const SameChange = merge_mod.SameChange;
const MergeHunk = mat.MergeHunk;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    same_change: SameChange = .accept,
};

pub const Result = struct {
    /// Resolved text and conflict regions, in file order; adjacent
    /// resolved pieces are joined.
    hunks: []const MergeHunk,
    /// The merged text when nothing conflicts.
    clean: ?[]const u8,

    pub fn conflictCount(r: Result) usize {
        var n: usize = 0;
        for (r.hunks) |h| n += @intFromBool(h == .conflict);
        return n;
    }
};

/// Whether `bytes` looks binary: a NUL in the first 8 KiB (as git).
pub fn isBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8 << 10)], 0) != null;
}

/// Merges the file texts `m` (side, base, side, ...). Everything is
/// allocated in `arena`; hunk texts may point into the inputs.
pub fn mergeContent(arena: Allocator, m: Merge([]const u8), o: Options) !Result {
    const v = m.values;
    if (v.len == 1) return .{ .hunks = &.{.{ .resolved = v[0] }}, .clean = v[0] };
    var cur = v[0];
    var i: usize = 1;
    while (i < v.len) : (i += 2) {
        const r = try merge3(arena, v[i], cur, v[i + 1], o);
        if (v.len == 3) return r;
        cur = r.clean orelse return .{ .hunks = try arena.dupe(MergeHunk, &.{.{ .conflict = m }}), .clean = null };
    }
    return .{ .hunks = try arena.dupe(MergeHunk, &.{.{ .resolved = cur }}), .clean = cur };
}

/// A run of non-equal edits: base lines [b0, b1) became side lines
/// [x0, x1).
const Edit = struct { b0: usize, b1: usize, x0: usize, x1: usize };

fn edits(arena: Allocator, base: []const []const u8, side: []const []const u8) ![]const Edit {
    const ops = try mat.diffLines(arena, base, side);
    var out: std.ArrayList(Edit) = .empty;
    var bi: usize = 0;
    var xi: usize = 0;
    var open: ?Edit = null;
    for (ops) |op| switch (op.kind) {
        .equal => {
            if (open) |e| {
                try out.append(arena, .{ .b0 = e.b0, .b1 = bi, .x0 = e.x0, .x1 = xi });
                open = null;
            }
            bi += 1;
            xi += 1;
        },
        .delete => {
            if (open == null) open = .{ .b0 = bi, .b1 = bi, .x0 = xi, .x1 = xi };
            bi += 1;
        },
        .insert => {
            if (open == null) open = .{ .b0 = bi, .b1 = bi, .x0 = xi, .x1 = xi };
            xi += 1;
        },
    };
    if (open) |e| try out.append(arena, .{ .b0 = e.b0, .b1 = bi, .x0 = e.x0, .x1 = xi });
    return out.items;
}

/// One side's view of the walk: its edits and the next one not yet
/// taken.
const Side = struct {
    lines: []const []const u8,
    edits: []const Edit,
    next: usize = 0,
    /// Side index minus base index after the edits taken so far.
    delta: isize = 0,

    fn peek(s: *const Side) ?Edit {
        return if (s.next < s.edits.len) s.edits[s.next] else null;
    }

    /// Takes edits starting at or before `hi` (touching counts) and
    /// returns the furthest base end among them, or null if none.
    fn take(s: *Side, lo: usize, hi: usize) ?usize {
        var end: ?usize = null;
        while (s.peek()) |e| {
            if (e.b0 > hi or e.b1 < lo) break;
            end = @max(end orelse 0, e.b1);
            s.delta += @as(isize, @intCast(e.x1 - e.x0)) - @as(isize, @intCast(e.b1 - e.b0));
            s.next += 1;
        }
        return end;
    }

    fn at(b: usize, delta: isize) usize {
        return @intCast(@as(isize, @intCast(b)) + delta);
    }
};

fn merge3(arena: Allocator, base_text: []const u8, left_text: []const u8, right_text: []const u8, o: Options) !Result {
    if (std.mem.eql(u8, left_text, right_text) and o.same_change == .accept) return clean(arena, left_text);
    if (std.mem.eql(u8, base_text, left_text)) return clean(arena, right_text);
    if (std.mem.eql(u8, base_text, right_text)) return clean(arena, left_text);

    const base = try mat.splitLines(arena, base_text);
    var l: Side = .{ .lines = try mat.splitLines(arena, left_text), .edits = undefined };
    var r: Side = .{ .lines = try mat.splitLines(arena, right_text), .edits = undefined };
    l.edits = try edits(arena, base, l.lines);
    r.edits = try edits(arena, base, r.lines);

    var hunks: std.ArrayList(MergeHunk) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var conflicted = false;
    var pos: usize = 0;
    while (l.peek() != null or r.peek() != null) {
        const lo = @min(if (l.peek()) |e| e.b0 else std.math.maxInt(usize), if (r.peek()) |e| e.b0 else std.math.maxInt(usize));
        try appendLines(arena, &text, base[pos..lo]);
        const l_delta0 = l.delta;
        const r_delta0 = r.delta;
        // Grow the region until neither side has an edit touching it.
        var hi = lo;
        var l_any = false;
        var r_any = false;
        while (true) {
            var grew = false;
            if (l.take(lo, hi)) |e| {
                l_any = true;
                if (e > hi) hi = e;
                grew = true;
            }
            if (r.take(lo, hi)) |e| {
                r_any = true;
                if (e > hi) hi = e;
                grew = true;
            }
            if (!grew) break;
        }
        const lt = l.lines[Side.at(lo, l_delta0)..Side.at(hi, l.delta)];
        const rt = r.lines[Side.at(lo, r_delta0)..Side.at(hi, r.delta)];
        if (!r_any) {
            try appendLines(arena, &text, lt);
        } else if (!l_any) {
            try appendLines(arena, &text, rt);
        } else if (o.same_change == .accept and sameLines(lt, rt)) {
            try appendLines(arena, &text, lt);
        } else {
            if (text.items.len > 0) try hunks.append(arena, .{ .resolved = text.items });
            text = .empty;
            const vals = try arena.alloc([]const u8, 3);
            vals[0] = try joinLines(arena, lt);
            vals[1] = try joinLines(arena, base[lo..hi]);
            vals[2] = try joinLines(arena, rt);
            try hunks.append(arena, .{ .conflict = .{ .values = vals } });
            conflicted = true;
        }
        pos = hi;
    }
    try appendLines(arena, &text, base[pos..]);
    if (!conflicted) return clean(arena, text.items);
    if (text.items.len > 0) try hunks.append(arena, .{ .resolved = text.items });
    return .{ .hunks = hunks.items, .clean = null };
}

fn clean(arena: Allocator, text: []const u8) !Result {
    return .{ .hunks = try arena.dupe(MergeHunk, &.{.{ .resolved = text }}), .clean = text };
}

fn appendLines(arena: Allocator, out: *std.ArrayList(u8), lines: []const []const u8) !void {
    for (lines) |ln| try out.appendSlice(arena, ln);
}

fn joinLines(arena: Allocator, lines: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendLines(arena, &out, lines);
    return out.items;
}

fn sameLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

// ---------------------------------------------------------------- tests

const t = std.testing;

fn run(arena: Allocator, base: []const u8, left: []const u8, right: []const u8, o: Options) !Result {
    const vals = try arena.dupe([]const u8, &.{ left, base, right });
    return mergeContent(arena, .{ .values = vals }, o);
}

test "content_merge: clean non-overlapping" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const r = try run(a.allocator(), "1\n2\n3\n4\n5\n", "one\n2\n3\n4\n5\n", "1\n2\n3\n4\nfive\n", .{});
    try t.expectEqualStrings("one\n2\n3\n4\nfive\n", r.clean.?);
}

test "content_merge: overlap conflict" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const r = try run(a.allocator(), "a\nb\nc\n", "a\nB1\nc\n", "a\nB2\nc\n", .{});
    try t.expectEqual(@as(?[]const u8, null), r.clean);
    try t.expectEqual(@as(usize, 3), r.hunks.len);
    try t.expectEqualStrings("a\n", r.hunks[0].resolved);
    const c = r.hunks[1].conflict.values;
    try t.expectEqualStrings("B1\n", c[0]);
    try t.expectEqualStrings("b\n", c[1]);
    try t.expectEqualStrings("B2\n", c[2]);
    try t.expectEqualStrings("c\n", r.hunks[2].resolved);
    // Adjacent edits conflict, as in git.
    const adj = try run(a.allocator(), "a\nb\nc\n", "A\nb\nc\n", "a\nB\nc\n", .{});
    try t.expectEqual(@as(usize, 1), adj.conflictCount());
}

test "content_merge: same change accepted / kept" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const base = "x\ny\nz\n";
    const both = "x\nY\nz\n";
    const extra = "x\nY\nz\nw\n";
    try t.expectEqualStrings(extra, (try run(a.allocator(), base, both, extra, .{})).clean orelse return error.TestUnexpectedResult);
    try t.expectEqualStrings(both, (try run(a.allocator(), base, both, both, .{})).clean.?);
    try t.expectEqual(@as(?[]const u8, null), (try run(a.allocator(), base, both, both, .{ .same_change = .reject })).clean);
}

test "content_merge: add/add" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const r = try run(a.allocator(), "", "new left\n", "new right\n", .{});
    try t.expectEqual(@as(usize, 1), r.conflictCount());
    const same = try run(a.allocator(), "", "same\n", "same\n", .{});
    try t.expectEqualStrings("same\n", same.clean.?);
}

test "content_merge: delete vs modify" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const r = try run(a.allocator(), "a\nb\nc\n", "a\nc\n", "a\nB\nc\n", .{});
    try t.expectEqual(@as(usize, 1), r.conflictCount());
    try t.expectEqualStrings("", r.hunks[1].conflict.values[0]);
    // A deletion next to an untouched region merges.
    const ok = try run(a.allocator(), "a\nb\nc\nd\ne\n", "a\nc\nd\ne\n", "a\nb\nc\nd\nE\n", .{});
    try t.expectEqualStrings("a\nc\nd\nE\n", ok.clean.?);
}

test "content_merge: missing final newline and EOL changes" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const r = try run(a.allocator(), "a\nx\nb", "A\nx\nb", "a\nx\nb\n", .{});
    try t.expectEqualStrings("A\nx\nb\n", r.clean.?);
    const crlf = try run(a.allocator(), "a\nb\n", "a\r\nb\n", "a\nb\nc\n", .{});
    try t.expectEqualStrings("a\r\nb\nc\n", crlf.clean.?);
}

test "content_merge: N-way fold" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const vals = [_][]const u8{ "1\n2\n3\n", "1\n2\n3\n", "one\n2\n3\n", "1\n2\n3\n", "1\n2\nthree\n" };
    const r = try mergeContent(a.allocator(), .{ .values = &vals }, .{});
    try t.expectEqualStrings("one\n2\nthree\n", r.clean.?);
    const bad = [_][]const u8{ "1\nX\n3\n", "1\n2\n3\n", "1\nY\n3\n", "1\n2\n3\n", "1\n2\nthree\n" };
    const rb = try mergeContent(a.allocator(), .{ .values = &bad }, .{});
    try t.expectEqual(@as(usize, 1), rb.hunks.len);
    try t.expectEqual(@as(usize, 5), rb.hunks[0].conflict.values.len);
}

test "content_merge: binary detection" {
    try t.expect(isBinary("ab\x00c"));
    try t.expect(!isBinary("plain text\n"));
}
