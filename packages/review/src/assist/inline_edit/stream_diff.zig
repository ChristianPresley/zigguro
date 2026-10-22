//! The stable streaming diff (E12.F06.S01.T01): the edits from the
//! original region to a rewrite that is still arriving, in region
//! coordinates, shown as a pending change while it streams.
//!
//! Each update diffs the original lines against the complete lines
//! received so far (histogram). Original lines after the last one the
//! partial text matched are not reached yet: they stay as they are, and
//! lines the partial text adds past that point are insertions there. A
//! line once shown equal stays equal until the final diff (no flicker
//! from equal to deleted while the model is mid-line). The final update
//! diffs the whole text.

const std = @import("std");
const zg_editor = @import("zg_editor");

const Allocator = std.mem.Allocator;
const diff = zg_editor.model.diff;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const Replace = zg_editor.model.edit.change_set.Replace;

pub const StreamDiff = struct {
    gpa: Allocator,
    /// The original region (borrowed).
    original: []const u8,
    /// Its lines with their line ends.
    lines: []const []const u8,
    /// Original lines an update showed as equal.
    was_equal: []bool,
    /// Original lines `[0, reached)` were reached by the stream.
    reached: u32 = 0,

    pub fn init(gpa: Allocator, original: []const u8) Allocator.Error!StreamDiff {
        const lines = try splitLines(gpa, original);
        errdefer gpa.free(lines);
        const eq = try gpa.alloc(bool, lines.len);
        @memset(eq, false);
        return .{ .gpa = gpa, .original = original, .lines = lines, .was_equal = eq };
    }

    pub fn deinit(d: *StreamDiff) void {
        d.gpa.free(d.lines);
        d.gpa.free(d.was_equal);
    }

    /// The edits from the original region to `partial` (the rewrite so
    /// far; `final` when it is complete), in region coordinates. Owned by
    /// the caller (`gpa`).
    pub fn update(d: *StreamDiff, partial: []const u8, final: bool, gpa: Allocator) Allocator.Error!ChangeSet {
        // Only complete lines, unless the text is complete.
        const upto = if (final) partial.len else if (std.mem.lastIndexOfScalar(u8, partial, '\n')) |i| i + 1 else 0;
        const text = partial[0..upto];
        const plines = try splitLines(gpa, text);
        defer gpa.free(plines);

        var ia: std.ArrayList(u32) = .empty;
        defer ia.deinit(gpa);
        var ib: std.ArrayList(u32) = .empty;
        defer ib.deinit(gpa);
        try intern(gpa, d.lines, plines, &ia, &ib);
        const es = try diff.diffTokens(gpa, ia.items, ib.items, .histogram, null);
        defer gpa.free(es);

        // Per original line: deleted or kept; per position: the partial
        // lines inserted before it.
        const n = d.lines.len;
        const del = try gpa.alloc(bool, n);
        defer gpa.free(del);
        @memset(del, false);
        const ins = try gpa.alloc(?[2]u32, n + 1);
        defer gpa.free(ins);
        @memset(ins, null);

        var frontier: u32 = 0;
        if (!final) for (es) |e| {
            if (e.kind == .equal and e.len > 0) frontier = e.a_start + e.len;
        };
        if (final) frontier = @intCast(n);
        frontier = @max(frontier, @min(d.reached, @as(u32, @intCast(n))));
        for (es) |e| switch (e.kind) {
            .equal => for (e.a_start..e.a_start + e.len) |i| {
                d.was_equal[i] = true;
            },
            .delete => for (e.a_start..e.a_start + e.len) |i| {
                // Not reached yet, or shown equal before: kept for now.
                if (i >= frontier) continue;
                if (!final and d.was_equal[i]) continue;
                del[i] = true;
            },
            .insert => {
                const at = @min(e.a_start, frontier);
                if (ins[at]) |r| {
                    ins[at] = .{ r[0], e.b_start + e.len };
                } else ins[at] = .{ e.b_start, e.b_start + e.len };
            },
        };
        d.reached = frontier;

        var reps: std.ArrayList(Replace) = .empty;
        defer reps.deinit(gpa);
        var off: usize = 0;
        var boffs = try gpa.alloc(usize, plines.len + 1);
        defer gpa.free(boffs);
        boffs[0] = 0;
        for (plines, 0..) |l, k| boffs[k + 1] = boffs[k] + l.len;
        for (0..n + 1) |i| {
            if (ins[i]) |r| try reps.append(gpa, .{ .range = .{ .start = off, .end = off }, .text = text[boffs[r[0]]..boffs[r[1]]] });
            if (i == n) break;
            const len = d.lines[i].len;
            if (del[i]) try reps.append(gpa, .{ .range = .{ .start = off, .end = off + len }, .text = "" });
            off += len;
        }
        return ChangeSet.fromEdits(gpa, d.original.len, reps.items) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Overlap, error.OutOfBounds => unreachable,
        };
    }
};

/// `text`'s lines, each with its line end (the last may have none).
fn splitLines(gpa: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    while (at < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, at, '\n')) |i| i + 1 else text.len;
        try out.append(gpa, text[at..end]);
        at = end;
    }
    return out.toOwnedSlice(gpa);
}

/// Line ids shared by both sides; a line without its end equals the
/// same line with one.
fn intern(gpa: Allocator, a: []const []const u8, b: []const []const u8, ia: *std.ArrayList(u32), ib: *std.ArrayList(u32)) Allocator.Error!void {
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    defer ids.deinit(gpa);
    inline for (.{ .{ a, ia }, .{ b, ib } }) |side| {
        try side[1].ensureTotalCapacity(gpa, side[0].len);
        for (side[0]) |l| {
            const key = std.mem.trimEnd(u8, l, "\r\n");
            const g = try ids.getOrPut(gpa, key);
            if (!g.found_existing) g.value_ptr.* = ids.count() - 1;
            side[1].appendAssumeCapacity(g.value_ptr.*);
        }
    }
}

const testing = std.testing;

fn render(cs: *const ChangeSet, original: []const u8) ![]u8 {
    return cs.applyToSlice(testing.allocator, original);
}

test "inline: stream diff frontier keeps unreached lines untouched" {
    const original = "a\nb\nc\nd\n";
    var d: StreamDiff = try .init(testing.allocator, original);
    defer d.deinit();
    const rows = [_]struct { partial: []const u8, final: bool, want: []const u8 }{
        // Nothing complete yet: nothing changes.
        .{ .partial = "A", .final = false, .want = "a\nb\nc\nd\n" },
        // "A" replaces nothing yet: unreached lines stay.
        .{ .partial = "A\n", .final = false, .want = "A\na\nb\nc\nd\n" },
        // "b" matched: "a" (before it) is deleted, c and d not reached.
        .{ .partial = "A\nb\n", .final = false, .want = "A\nb\nc\nd\n" },
        .{ .partial = "A\nb\nC\n", .final = false, .want = "A\nb\nC\nc\nd\n" },
        // Final: the whole diff; d is gone.
        .{ .partial = "A\nb\nC\n", .final = true, .want = "A\nb\nC\n" },
    };
    for (rows) |r| {
        var cs = try d.update(r.partial, r.final, testing.allocator);
        defer cs.deinit();
        const got = try render(&cs, original);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(r.want, got);
    }
}

test "inline: hysteresis prevents equal→deleted flicker" {
    const original = "x\ny\nz\n";
    var d: StreamDiff = try .init(testing.allocator, original);
    defer d.deinit();
    {
        var cs = try d.update("x\ny\n", false, testing.allocator);
        defer cs.deinit();
        const got = try render(&cs, original);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(original, got);
    }
    // The next lines would make "x" a delete; it stays while streaming.
    {
        var cs = try d.update("y\nz\nw\n", false, testing.allocator);
        defer cs.deinit();
        const got = try render(&cs, original);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("x\ny\nz\nw\n", got);
    }
    // The final diff decides.
    {
        var cs = try d.update("y\nz\nw\n", true, testing.allocator);
        defer cs.deinit();
        const got = try render(&cs, original);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("y\nz\nw\n", got);
    }
}

test "inline: follow-up diffs against original" {
    // A second round's output is diffed against the same original region.
    const original = "let x = 1;\n";
    var d: StreamDiff = try .init(testing.allocator, original);
    defer d.deinit();
    var first = try d.update("let count = 1;\n", true, testing.allocator);
    first.deinit();
    var d2: StreamDiff = try .init(testing.allocator, original);
    defer d2.deinit();
    var cs = try d2.update("const count: number = 1;\n", true, testing.allocator);
    defer cs.deinit();
    const got = try render(&cs, original);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("const count: number = 1;\n", got);
}

test "inline: final text without a trailing newline" {
    const original = "a\nb";
    var d: StreamDiff = try .init(testing.allocator, original);
    defer d.deinit();
    var cs = try d.update("a\nB", true, testing.allocator);
    defer cs.deinit();
    const got = try render(&cs, original);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a\nB", got);
}
