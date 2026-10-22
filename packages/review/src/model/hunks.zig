//! Line hunks of a text change (E12.F01.S01.T01): groups an E05
//! `ChangeSet`'s replaces into whole-line hunks against the base text.
//!
//! - A replace touches the lines from the one holding its start through
//!   the one holding its end. When it ends exactly at a line start and the
//!   text before that point ends with a line terminator on both sides,
//!   that line is unchanged and not part of the hunk (so replacing or
//!   inserting whole lines does not drag the next line in).
//! - Replaces whose line spans overlap, touch, or are at most
//!   `merge_gap_lines` unchanged lines apart form one hunk.
//! - Line counts follow `zg_core.LineIndex`: `\n`, `\r\n` and a lone `\r`
//!   end lines; a non-empty block without a final terminator has one more
//!   line. An append at the end of a file without a final newline touches
//!   the last line.
//! - Hunks are never split: `replace_span` must cover whole replaces.
//! - `previous` hunks with the same key (XxHash3 of base and new text)
//!   pass their decision on; the rest start `undecided`.

const std = @import("std");
const zg_core = @import("zg_core");
const changeset = @import("changeset.zig");

const Allocator = std.mem.Allocator;
const ChangeSet = changeset.ChangeSet;
const Hunk = changeset.Hunk;
const LineIndex = zg_core.LineIndex;

pub const HunkOptions = struct {
    /// Replaces at most this many unchanged lines apart share a hunk.
    merge_gap_lines: u32 = 0,
    /// Hunks above this are kept whole (the UI paginates); informational.
    max_hunk_lines: u32 = 400,
    /// Hunks of the previous derivation whose decisions carry over.
    previous: []const Hunk = &.{},
};

/// The hunks of `edits` over `base` (`lines` indexes `base`), allocated
/// with `gpa`.
pub fn deriveHunks(gpa: Allocator, base: []const u8, lines: *const LineIndex, edits: *const ChangeSet, o: HunkOptions) Allocator.Error![]Hunk {
    std.debug.assert(edits.base_len == base.len);
    var out: std.ArrayList(Hunk) = .empty;
    errdefer out.deinit(gpa);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);

    const reps = edits.replaces;
    var delta: i64 = 0;
    var i: usize = 0;
    while (i < reps.len) {
        // Grow the group while the next replace starts within the gap.
        const first_line = startLine(base, lines, reps[i]);
        var j = i + 1;
        var end_line = spanEnd(base, lines, reps[i .. i + 1], first_line, &scratch, gpa) catch |e| return e;
        while (j < reps.len) {
            const l = startLine(base, lines, reps[j]);
            if (l > end_line + o.merge_gap_lines) break;
            j += 1;
            end_line = try spanEnd(base, lines, reps[i..j], first_line, &scratch, gpa);
        }
        // `scratch` holds the new block of reps[i..j]; count both sides.
        const bs: usize = @intCast(lines.lineStart(first_line));
        const be: usize = if (end_line >= lines.lineCount()) base.len else @intCast(lines.lineStart(end_line));
        const base_block = base[bs..be];
        const new_block = scratch.items;
        const base_count = countLines(base_block);
        const new_count = countLines(new_block);
        const new_start: u32 = @intCast(@as(i64, first_line) + delta);
        var h: Hunk = .{
            .id = @intCast(out.items.len),
            .base_lines = .{ .start = first_line, .count = base_count },
            .new_lines = .{ .start = new_start, .count = new_count },
            .replace_span = .{ @intCast(i), @intCast(j) },
            .key = hunkKey(base_block, new_block),
        };
        for (o.previous) |p| if (p.key == h.key) {
            h.decision = p.decision;
            break;
        };
        try out.append(gpa, h);
        delta += @as(i64, new_count) - @as(i64, base_count);
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

/// The first line `r` touches. A `\n` landing right after a line's
/// final `\r` turns its terminator into `\r\n`, so that line is touched
/// too.
fn startLine(base: []const u8, lines: *const LineIndex, r: changeset.Replace) u32 {
    const s = r.range.start;
    const l = lines.lineOf(s);
    if (l == 0 or lines.lineStart(l) != s or base[@intCast(s - 1)] != '\r') return l;
    const next: ?u8 = if (r.text.len > 0) r.text[0] else if (r.range.end < base.len) base[@intCast(r.range.end)] else null;
    return if (next == '\n') l - 1 else l;
}

/// Builds the new text of the whole lines touched by `group` into
/// `scratch` and returns the exclusive end line of the hunk.
fn spanEnd(base: []const u8, lines: *const LineIndex, group: []const changeset.Replace, first_line: u32, scratch: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!u32 {
    const last = group[group.len - 1];
    const e = last.range.end;
    const end_line = lines.lineOf(e);
    const bs: usize = @intCast(lines.lineStart(first_line));
    scratch.clearRetainingCapacity();
    var pos: usize = bs;
    for (group) |r| {
        try scratch.appendSlice(gpa, base[pos..@intCast(r.range.start)]);
        try scratch.appendSlice(gpa, r.text);
        pos = @intCast(r.range.end);
    }
    const at_line_start = lines.lineStart(end_line) == e;
    // The line holding `e` is unchanged when the change ends right before
    // it on both sides.
    // ...unless a new final `\r` would join its leading `\n`.
    const joins = scratch.items.len > 0 and scratch.items[scratch.items.len - 1] == '\r' and e < base.len and base[@intCast(e)] == '\n';
    if (at_line_start and !joins and (scratch.items.len == 0 or endsWithTerminator(scratch.items)) and (e == bs or endsWithTerminator(base[bs..@intCast(e)]))) {
        return end_line;
    }
    const line_end: usize = if (end_line + 1 >= lines.lineCount()) base.len else @intCast(lines.lineStart(end_line + 1));
    try scratch.appendSlice(gpa, base[pos..line_end]);
    return end_line + 1;
}

fn endsWithTerminator(s: []const u8) bool {
    return s.len > 0 and (s[s.len - 1] == '\n' or s[s.len - 1] == '\r');
}

/// Lines in `s`: one per terminator, plus one for an unterminated tail.
pub fn countLines(s: []const u8) u32 {
    var n: u32 = 0;
    var k: usize = 0;
    while (k < s.len) : (k += 1) switch (s[k]) {
        '\n' => n += 1,
        '\r' => {
            n += 1;
            if (k + 1 < s.len and s[k + 1] == '\n') k += 1;
        },
        else => {},
    };
    if (s.len > 0 and !endsWithTerminator(s)) n += 1;
    return n;
}

fn hunkKey(base_block: []const u8, new_block: []const u8) u64 {
    var h: std.hash.XxHash3 = .init(0);
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, base_block.len, .little);
    h.update(&len);
    h.update(base_block);
    h.update(new_block);
    return h.final();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Replace = changeset.Replace;

const Fx = struct {
    base: []const u8,
    lines: LineIndex,
    cs: ChangeSet,

    fn init(base: []const u8, edits: []const Replace) !Fx {
        return .{ .base = base, .lines = try .build(testing.allocator, base), .cs = try .fromEdits(testing.allocator, base.len, edits) };
    }
    fn deinit(f: *Fx) void {
        f.lines.deinit(testing.allocator);
        f.cs.deinit();
    }
    fn hunks(f: *Fx, o: HunkOptions) ![]Hunk {
        return deriveHunks(testing.allocator, f.base, &f.lines, &f.cs, o);
    }
};

fn rep(s: u64, e: u64, t: []const u8) Replace {
    return .{ .range = .{ .start = s, .end = e }, .text = t };
}

fn expectHunk(h: Hunk, bs: u32, bc: u32, ns: u32, nc: u32, span: [2]u32) !void {
    try testing.expectEqual(changeset.LineRange{ .start = bs, .count = bc }, h.base_lines);
    try testing.expectEqual(changeset.LineRange{ .start = ns, .count = nc }, h.new_lines);
    try testing.expectEqual(span, h.replace_span);
}

test "hunks: single replace mid-line → one hunk covering that line" {
    var f = try Fx.init("aaa\nbbb\nccc\n", &.{rep(5, 6, "XY")});
    defer f.deinit();
    const hs = try f.hunks(.{});
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try expectHunk(hs[0], 1, 1, 1, 1, .{ 0, 1 });
}

test "hunks: two replaces 1 line apart, merge_gap=0 → 2 hunks; merge_gap=1 → 1" {
    var f = try Fx.init("l0\nl1\nl2\nl3\n", &.{ rep(3, 4, "X"), rep(9, 10, "Y") });
    defer f.deinit();
    const two = try f.hunks(.{});
    defer testing.allocator.free(two);
    try testing.expectEqual(@as(usize, 2), two.len);
    try expectHunk(two[0], 1, 1, 1, 1, .{ 0, 1 });
    try expectHunk(two[1], 3, 1, 3, 1, .{ 1, 2 });
    const one = try f.hunks(.{ .merge_gap_lines = 1 });
    defer testing.allocator.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try expectHunk(one[0], 1, 3, 1, 3, .{ 0, 2 });
}

test "hunks: whole-line insert and delete do not touch the next line" {
    // Insert a line before l1, delete l3.
    var f = try Fx.init("l0\nl1\nl2\nl3\nl4\n", &.{ rep(3, 3, "new\n"), rep(9, 12, "") });
    defer f.deinit();
    const hs = try f.hunks(.{});
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 2), hs.len);
    try expectHunk(hs[0], 1, 0, 1, 1, .{ 0, 1 });
    try expectHunk(hs[1], 3, 1, 4, 0, .{ 1, 2 });
}

test "hunks: joining two lines touches both" {
    var f = try Fx.init("ab\ncd\nef\n", &.{rep(2, 3, " ")});
    defer f.deinit();
    const hs = try f.hunks(.{});
    defer testing.allocator.free(hs);
    try expectHunk(hs[0], 0, 2, 0, 1, .{ 0, 1 });
}

test "hunks: insertion at EOF without trailing newline" {
    var f = try Fx.init("a\nb", &.{rep(3, 3, "c\nd")});
    defer f.deinit();
    const hs = try f.hunks(.{});
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try expectHunk(hs[0], 1, 1, 1, 2, .{ 0, 1 });
    // After a final newline the append is a pure insertion.
    var g = try Fx.init("a\n", &.{rep(2, 2, "x")});
    defer g.deinit();
    const gs = try g.hunks(.{});
    defer testing.allocator.free(gs);
    try expectHunk(gs[0], 1, 0, 1, 1, .{ 0, 1 });
}

test "hunks: create file → one hunk; delete → zero hunks" {
    var f = try Fx.init("", &.{rep(0, 0, "x\ny\nz\n")});
    defer f.deinit();
    const hs = try f.hunks(.{});
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try expectHunk(hs[0], 0, 0, 0, 3, .{ 0, 1 });
    // A delete has no text content, so no ChangeSet and no hunks; an
    // identity ChangeSet has none either.
    var g = try Fx.init("abc\n", &.{});
    defer g.deinit();
    const gs = try g.hunks(.{});
    defer testing.allocator.free(gs);
    try testing.expectEqual(@as(usize, 0), gs.len);
}

test "hunks: CRLF base line indexing" {
    // "x\r\ny\r\nz\r\n": change y (bytes 3..4), and insert a line before z.
    var f = try Fx.init("x\r\ny\r\nz\r\n", &.{ rep(3, 4, "Y"), rep(6, 6, "w\r\n") });
    defer f.deinit();
    const hs = try f.hunks(.{});
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try expectHunk(hs[0], 1, 1, 1, 2, .{ 0, 2 });
}

test "hunks: new line numbers follow earlier hunks" {
    var f = try Fx.init("a\nb\nc\nd\ne\n", &.{ rep(0, 0, "1\n2\n"), rep(8, 10, "") });
    defer f.deinit();
    const hs = try f.hunks(.{});
    defer testing.allocator.free(hs);
    try expectHunk(hs[0], 0, 0, 0, 2, .{ 0, 1 });
    try expectHunk(hs[1], 4, 1, 6, 0, .{ 1, 2 });
}

test "hunks: re-derive keeps decisions for identical hunks, resets changed" {
    var f = try Fx.init("a\nb\nc\nd\n", &.{ rep(0, 1, "A"), rep(6, 7, "D") });
    defer f.deinit();
    const old = try f.hunks(.{});
    defer testing.allocator.free(old);
    old[0].decision = .accepted;
    old[1].decision = .rejected;
    // The second hunk changes; the first is the same text.
    var g = try Fx.init("a\nb\nc\nd\n", &.{ rep(0, 1, "A"), rep(6, 7, "DD") });
    defer g.deinit();
    const new = try g.hunks(.{ .previous = old });
    defer testing.allocator.free(new);
    try testing.expectEqual(changeset.Decision.accepted, new[0].decision);
    try testing.expectEqual(changeset.Decision.undecided, new[1].decision);
}

test "hunks: count lines" {
    try testing.expectEqual(@as(u32, 0), countLines(""));
    try testing.expectEqual(@as(u32, 1), countLines("a"));
    try testing.expectEqual(@as(u32, 1), countLines("a\r\n"));
    try testing.expectEqual(@as(u32, 2), countLines("a\rb"));
    try testing.expectEqual(@as(u32, 2), countLines("\n\n"));
}

test "fuzz: review hunks" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, sm: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            try fuzzOne(buf[0..sm.slice(&buf)]);
        }
    }.one, .{});
}

test "hunks: random invariants" {
    var prng: std.Random.DefaultPrng = .init(0x12e);
    var buf: [96]u8 = undefined;
    for (0..3000) |_| {
        prng.random().bytes(&buf);
        try fuzzOne(buf[0 .. 2 + prng.random().uintLessThan(usize, buf.len - 2)]);
    }
}

/// Every replace in exactly one hunk, hunks sorted and disjoint, new line
/// numbers following earlier hunks, and line counts that add up to the
/// applied text's.
fn fuzzOne(input: []const u8) !void {
    const gpa = testing.allocator;
    if (input.len < 2) return;
    // First half: base text over a small alphabet; second half: edits.
    const alphabet = "ab\n\r";
    const n = input.len / 2;
    const base = try gpa.alloc(u8, n);
    defer gpa.free(base);
    for (base, input[0..n]) |*b, x| b.* = alphabet[x % alphabet.len];
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    var k: usize = n;
    var pos: u64 = 0;
    while (k + 3 <= input.len) : (k += 3) {
        const start = pos + input[k] % 4;
        if (start > base.len) break;
        const end = @min(base.len, start + input[k + 1] % 3);
        const t = [_][]const u8{ "", "x", "\n", "y\r\n", "\r" };
        try edits.append(gpa, rep(start, end, t[input[k + 2] % t.len]));
        pos = end;
    }
    var f = try Fx.init(base, edits.items);
    defer f.deinit();
    const hs = try f.hunks(.{ .merge_gap_lines = input[0] % 3 });
    defer gpa.free(hs);

    var next: u32 = 0;
    var base_line_end: u32 = 0;
    var added: i64 = 0;
    for (hs, 0..) |h, idx| {
        try testing.expectEqual(@as(u32, @intCast(idx)), h.id);
        try testing.expectEqual(next, h.replace_span[0]);
        try testing.expect(h.replace_span[1] > h.replace_span[0]);
        next = h.replace_span[1];
        try testing.expect(h.base_lines.start >= base_line_end);
        base_line_end = h.base_lines.end();
        try testing.expectEqual(@as(i64, h.base_lines.start) + added, @as(i64, h.new_lines.start));
        added += @as(i64, h.new_lines.count) - @as(i64, h.base_lines.count);
    }
    try testing.expectEqual(@as(u32, @intCast(f.cs.replaces.len)), next);
    const applied = try f.cs.applyToSlice(gpa, base);
    defer gpa.free(applied);
    try testing.expectEqual(@as(i64, countLines(base)) + added, @as(i64, countLines(applied)));

    // Lines outside the hunks are unchanged.
    var new_lines: LineIndex = try .build(gpa, applied);
    defer new_lines.deinit(gpa);
    var b0: u32 = 0;
    var n0: u32 = 0;
    for (hs) |h| {
        try expectSameLines(base, &f.lines, b0, h.base_lines.start, applied, &new_lines, n0, h.new_lines.start);
        b0 = h.base_lines.end();
        n0 = h.new_lines.end();
    }
    try expectSameLines(base, &f.lines, b0, countLines(base), applied, &new_lines, n0, countLines(applied));
}

fn lineBytes(text: []const u8, idx: *const LineIndex, from: u32, to: u32) []const u8 {
    const a: usize = if (from >= idx.lineCount()) text.len else @intCast(idx.lineStart(from));
    const b: usize = if (to >= idx.lineCount()) text.len else @intCast(idx.lineStart(to));
    return text[a..b];
}

fn expectSameLines(base: []const u8, bl: *const LineIndex, b0: u32, b1: u32, new: []const u8, nl: *const LineIndex, n0: u32, n1: u32) !void {
    try testing.expectEqual(b1 - b0, n1 - n0);
    try testing.expectEqualStrings(lineBytes(base, bl, b0, b1), lineBytes(new, nl, n0, n1));
}
