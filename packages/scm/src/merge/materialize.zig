//! Conflict materialization: a conflicted file, given as merge hunks
//! (resolved text and conflicted regions, from the content merge in
//! F04.S01.T02), becomes text with conflict markers that a user or an
//! agent can edit; `parse_markers.zig` reads the edited text back.
//!
//! Styles:
//! - `diff3`, `zdiff3`, `merge`: exactly git's (two sides only; more sides
//!   fall back to `zg`). `zdiff3` moves lines common to every side at the
//!   start and end of a region out of it; `merge` does the same and leaves
//!   out the base (git's default "zealous" style, without its splitting
//!   of regions at common lines in the middle).
//! - `zg` (after Jujutsu): a diff from each base to its side, then a
//!   snapshot of the last side:
//!   ```
//!   <<<<<<< conflict 1 of 1
//!   %%%%%%% diff from base to side #1
//!    unchanged
//!   -removed
//!   +added
//!   +++++++ side #2
//!   side two's text
//!   >>>>>>> conflict 1 of 1 ends
//!   ```

const std = @import("std");
const merge_mod = @import("merge.zig");
const Merge = merge_mod.Merge;
const Allocator = std.mem.Allocator;

pub const ConflictStyle = enum { zg, diff3, zdiff3, merge };

pub const MaterializeOptions = struct {
    style: ConflictStyle = .diff3,
    /// The minimum marker length; `markerLen` raises it when the text
    /// itself has lines that would look like markers.
    marker_len: u8 = 7,
    /// One per term of the merge, in `values` order (side, base, side,
    /// ...). Empty: "side #N" and "base" (or "base #N").
    labels: []const []const u8 = &.{},
};

/// A piece of a merged file.
pub const MergeHunk = union(enum) {
    /// Text every side agrees on.
    resolved: []const u8,
    /// One region's text per term (side, base, side, ...).
    conflict: Merge([]const u8),
};

/// Characters that start marker lines.
const marker_chars = "<|=>%+";

/// The marker length to use for `hunks`: `min`, or one more than the
/// longest run of a marker character starting a line, if that is longer
/// (as git's `conflict-marker-size`). A `+` run counts one extra, since
/// `zg` diff sections prefix added lines with `+`.
pub fn markerLen(hunks: []const MergeHunk, min: u8) u8 {
    var longest: usize = 0;
    for (hunks) |h| switch (h) {
        .resolved => |text| longest = @max(longest, longestRun(text)),
        .conflict => |m| for (m.values) |text| {
            longest = @max(longest, longestRun(text));
        },
    };
    return @intCast(@min(255, @max(min, longest + 1)));
}

fn longestRun(text: []const u8) usize {
    var best: usize = 0;
    var it = LineIter{ .text = text };
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const c = line[0];
        if (std.mem.indexOfScalar(u8, marker_chars, c) == null) continue;
        var n: usize = 0;
        while (n < line.len and line[n] == c) n += 1;
        if (c == '+') n += 1;
        best = @max(best, n);
    }
    return best;
}

/// Lines including their `\n` (the last may lack one).
pub const LineIter = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(it: *LineIter) ?[]const u8 {
        if (it.pos >= it.text.len) return null;
        const end = if (std.mem.indexOfScalarPos(u8, it.text, it.pos, '\n')) |nl| nl + 1 else it.text.len;
        const line = it.text[it.pos..end];
        it.pos = end;
        return line;
    }
};

/// Writes `hunks` with conflict markers. `file` gives the number of terms
/// (a null term is an absent file and is shown as empty). Allocates only
/// for `zg` diff sections, proportional to one region.
pub fn materialize(gpa: Allocator, file: Merge(?[]const u8), hunks: []const MergeHunk, o: MaterializeOptions, w: *std.Io.Writer) !void {
    const style: ConflictStyle = if (file.sides() > 2 and o.style != .zg) .zg else o.style;
    const len = markerLen(hunks, o.marker_len);
    var total: usize = 0;
    for (hunks) |h| {
        if (h == .conflict) total += 1;
    }
    var n: usize = 0;
    for (hunks) |h| switch (h) {
        .resolved => |text| try w.writeAll(text),
        .conflict => |m| {
            if (m.values.len != file.values.len) return error.InvalidMerge;
            n += 1;
            switch (style) {
                .zg => try writeZg(gpa, m, o, len, n, total, w),
                .diff3 => try writeGit(m.values, o, len, true, w),
                .zdiff3, .merge => {
                    const trim = commonEnds(m);
                    try w.writeAll(m.values[0][0..trim.prefix]);
                    var trimmed: [3][]const u8 = undefined;
                    for (m.values, 0..) |v, i| {
                        trimmed[i] = if (i % 2 == 0) v[trim.prefix .. v.len - trim.suffix] else v;
                    }
                    try writeGit(&trimmed, o, len, style == .zdiff3, w);
                    const s = m.values[0];
                    try w.writeAll(s[s.len - trim.suffix ..]);
                },
            }
        },
    };
}

fn label(o: MaterializeOptions, i: usize, buf: []u8, nterms: usize) []const u8 {
    if (i < o.labels.len) return o.labels[i];
    if (i % 2 == 0) return std.fmt.bufPrint(buf, "side #{d}", .{i / 2 + 1}) catch unreachable;
    if (nterms == 3) return "base";
    return std.fmt.bufPrint(buf, "base #{d}", .{i / 2 + 1}) catch unreachable;
}

fn writeMarker(w: *std.Io.Writer, c: u8, len: u8, text: []const u8) !void {
    try w.splatByteAll(c, len);
    if (text.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(text);
    }
    try w.writeByte('\n');
}

/// Section text, newline-terminated (git adds the missing newline too).
fn writeSection(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll(text);
    if (text.len > 0 and text[text.len - 1] != '\n') try w.writeByte('\n');
}

fn writeGit(v: []const []const u8, o: MaterializeOptions, len: u8, with_base: bool, w: *std.Io.Writer) !void {
    var b: [32]u8 = undefined;
    try writeMarker(w, '<', len, label(o, 0, &b, 3));
    try writeSection(w, v[0]);
    if (with_base) {
        try writeMarker(w, '|', len, label(o, 1, &b, 3));
        try writeSection(w, v[1]);
    }
    try writeMarker(w, '=', len, "");
    try writeSection(w, v[2]);
    try writeMarker(w, '>', len, label(o, 2, &b, 3));
}

/// Bytes of whole lines shared by every side at the start and the end of a
/// region (not overlapping).
fn commonEnds(m: Merge([]const u8)) struct { prefix: usize, suffix: usize } {
    const first = m.values[0];
    var prefix: usize = 0;
    var it = LineIter{ .text = first };
    outer: while (it.next()) |line| {
        if (line[line.len - 1] != '\n') break;
        var i: usize = 2;
        while (i < m.values.len) : (i += 2) {
            const v = m.values[i];
            if (v.len < prefix + line.len or !std.mem.eql(u8, v[prefix..][0..line.len], line)) break :outer;
        }
        prefix += line.len;
    }
    var min_rest: usize = std.math.maxInt(usize);
    var i: usize = 0;
    while (i < m.values.len) : (i += 2) min_rest = @min(min_rest, m.values[i].len - prefix);
    var suffix: usize = 0;
    while (true) {
        // The last line of `first` before the current suffix.
        const end = first.len - suffix;
        if (end <= prefix) break;
        if (first[end - 1] != '\n') break;
        const start = if (std.mem.lastIndexOfScalar(u8, first[prefix .. end - 1], '\n')) |nl| prefix + nl + 1 else prefix;
        const line = first[start..end];
        if (suffix + line.len > min_rest) break;
        var k: usize = 2;
        const ok = while (k < m.values.len) : (k += 2) {
            const v = m.values[k];
            if (!std.mem.eql(u8, v[v.len - suffix - line.len .. v.len - suffix], line)) break false;
        } else true;
        if (!ok) break;
        suffix += line.len;
    }
    return .{ .prefix = prefix, .suffix = suffix };
}

fn writeZg(gpa: Allocator, m: Merge([]const u8), o: MaterializeOptions, len: u8, n: usize, total: usize, w: *std.Io.Writer) !void {
    var head: [64]u8 = undefined;
    try writeMarker(w, '<', len, try std.fmt.bufPrint(&head, "conflict {d} of {d}", .{ n, total }));
    const sides = m.sides();
    var lb: [32]u8 = undefined;
    var la: [32]u8 = undefined;
    for (0..sides - 1) |i| {
        var title: [160]u8 = undefined;
        const from = label(o, 2 * i + 1, &lb, m.values.len);
        const to = label(o, 2 * i, &la, m.values.len);
        try writeMarker(w, '%', len, std.fmt.bufPrint(&title, "diff from {s} to {s}", .{ from, to }) catch "diff");
        try writeDiff(gpa, m.remove(i), m.add(i), w);
    }
    try writeMarker(w, '+', len, label(o, 2 * (sides - 1), &la, m.values.len));
    try writeSection(w, m.add(sides - 1));
    try writeMarker(w, '>', len, try std.fmt.bufPrint(&head, "conflict {d} of {d} ends", .{ n, total }));
}

/// A line diff as ' '/'-'/'+' prefixed lines.
fn writeDiff(gpa: Allocator, from: []const u8, to: []const u8, w: *std.Io.Writer) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try splitLines(arena, from);
    const b = try splitLines(arena, to);
    const ops = try diffLines(arena, a, b);
    for (ops) |op| {
        const line = switch (op.kind) {
            .equal, .delete => a[op.index],
            .insert => b[op.index],
        };
        try w.writeByte(switch (op.kind) {
            .equal => ' ',
            .delete => '-',
            .insert => '+',
        });
        try writeSection(w, line);
    }
}

pub fn splitLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = LineIter{ .text = text };
    while (it.next()) |l| try lines.append(arena, l);
    return lines.items;
}

pub const DiffOp = struct { kind: enum { equal, delete, insert }, index: usize };

/// Myers' O((N+M)D) shortest edit script over lines. `index` is into `a`
/// for equal/delete and into `b` for insert.
pub fn diffLines(arena: Allocator, a: []const []const u8, b: []const []const u8) ![]DiffOp {
    // Trim the common prefix and suffix first; regions are usually small.
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and std.mem.eql(u8, a[pre], b[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and std.mem.eql(u8, a[a.len - 1 - suf], b[b.len - 1 - suf])) suf += 1;
    const n: isize = @intCast(a.len - pre - suf);
    const m: isize = @intCast(b.len - pre - suf);
    const max: isize = n + m;
    const off: isize = max + 1;
    var trace: std.ArrayList([]isize) = .empty;
    var v = try arena.alloc(isize, @intCast(2 * max + 3));
    @memset(v, 0);
    var d: isize = 0;
    const final_d: isize = outer: while (d <= max) : (d += 1) {
        try trace.append(arena, try arena.dupe(isize, v));
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const ki: usize = @intCast(k + off);
            var x: isize = if (k == -d or (k != d and v[ki - 1] < v[ki + 1])) v[ki + 1] else v[ki - 1] + 1;
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[pre + @as(usize, @intCast(x))], b[pre + @as(usize, @intCast(y))])) {
                x += 1;
                y += 1;
            }
            v[ki] = x;
            if (x >= n and y >= m) break :outer d;
        }
    } else unreachable;

    // Walk back through the trace.
    var rev: std.ArrayList(DiffOp) = .empty;
    var x = n;
    var y = m;
    d = final_d;
    while (d > 0) : (d -= 1) {
        const vd = trace.items[@intCast(d)];
        const k = x - y;
        const ki: usize = @intCast(k + off);
        const prev_k = if (k == -d or (k != d and vd[ki - 1] < vd[ki + 1])) k + 1 else k - 1;
        const prev_x = vd[@intCast(prev_k + off)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
            try rev.append(arena, .{ .kind = .equal, .index = pre + @as(usize, @intCast(x)) });
        }
        if (x == prev_x) {
            y -= 1;
            try rev.append(arena, .{ .kind = .insert, .index = pre + @as(usize, @intCast(y)) });
        } else {
            x -= 1;
            try rev.append(arena, .{ .kind = .delete, .index = pre + @as(usize, @intCast(x)) });
        }
    }
    while (x > 0) {
        x -= 1;
        try rev.append(arena, .{ .kind = .equal, .index = pre + @as(usize, @intCast(x)) });
    }
    const ops = try arena.alloc(DiffOp, pre + rev.items.len + suf);
    for (0..pre) |i| ops[i] = .{ .kind = .equal, .index = i };
    for (rev.items, 0..) |op, i| ops[pre + rev.items.len - 1 - i] = op;
    for (0..suf) |i| ops[pre + rev.items.len + i] = .{ .kind = .equal, .index = a.len - suf + i };
    return ops;
}

test "materialize: diff3, merge and zg on one region" {
    const t = std.testing;
    const vals = [_]?[]const u8{ "", "", "" };
    const file: Merge(?[]const u8) = .{ .values = &vals };
    const region = [_][]const u8{ "B\nX\n", "b\n", "B\nY\n" };
    const hunks = [_]MergeHunk{ .{ .resolved = "a\n" }, .{ .conflict = .{ .values = &region } }, .{ .resolved = "c\n" } };
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    const labels = [_][]const u8{ "ours", "base", "theirs" };
    try materialize(t.allocator, file, &hunks, .{ .style = .diff3, .labels = &labels }, &aw.writer);
    try t.expectEqualStrings("a\n<<<<<<< ours\nB\nX\n||||||| base\nb\n=======\nB\nY\n>>>>>>> theirs\nc\n", aw.written());
    aw.clearRetainingCapacity();
    try materialize(t.allocator, file, &hunks, .{ .style = .zdiff3, .labels = &labels }, &aw.writer);
    try t.expectEqualStrings("a\nB\n<<<<<<< ours\nX\n||||||| base\nb\n=======\nY\n>>>>>>> theirs\nc\n", aw.written());
    aw.clearRetainingCapacity();
    try materialize(t.allocator, file, &hunks, .{ .style = .merge }, &aw.writer);
    try t.expectEqualStrings("a\nB\n<<<<<<< side #1\nX\n=======\nY\n>>>>>>> side #2\nc\n", aw.written());
    aw.clearRetainingCapacity();
    try materialize(t.allocator, file, &hunks, .{ .style = .zg }, &aw.writer);
    try t.expectEqualStrings(
        \\a
        \\<<<<<<< conflict 1 of 1
        \\%%%%%%% diff from base to side #1
        \\-b
        \\+B
        \\+X
        \\+++++++ side #2
        \\B
        \\Y
        \\>>>>>>> conflict 1 of 1 ends
        \\c
        \\
    , aw.written());
}

test "diffLines: matches a brute-force LCS length" {
    const t = std.testing;
    var prng: std.Random.DefaultPrng = .init(2);
    const rng = prng.random();
    const pool = [_][]const u8{ "a\n", "b\n", "c\n", "d\n" };
    for (0..500) |_| {
        var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const a = try arena.alloc([]const u8, rng.uintLessThan(usize, 12));
        const b = try arena.alloc([]const u8, rng.uintLessThan(usize, 12));
        for (a) |*l| l.* = pool[rng.uintLessThan(usize, 4)];
        for (b) |*l| l.* = pool[rng.uintLessThan(usize, 4)];
        const ops = try diffLines(arena, a, b);
        // Replaying the script turns a into b, with a minimal edit count.
        var ai: usize = 0;
        var bi: usize = 0;
        var edits: usize = 0;
        for (ops) |op| switch (op.kind) {
            .equal => {
                try t.expectEqual(ai, op.index);
                try t.expectEqualStrings(a[ai], b[bi]);
                ai += 1;
                bi += 1;
            },
            .delete => {
                try t.expectEqual(ai, op.index);
                ai += 1;
                edits += 1;
            },
            .insert => {
                try t.expectEqual(bi, op.index);
                bi += 1;
                edits += 1;
            },
        };
        try t.expectEqual(a.len, ai);
        try t.expectEqual(b.len, bi);
        // LCS by dynamic programming.
        var dp: [13][13]usize = @splat(@splat(0));
        for (0..a.len) |i| for (0..b.len) |j| {
            dp[i + 1][j + 1] = if (std.mem.eql(u8, a[i], b[j])) dp[i][j] + 1 else @max(dp[i][j + 1], dp[i + 1][j]);
        };
        try t.expectEqual(a.len + b.len - 2 * dp[a.len][b.len], edits);
    }
}

test "markerLen: grows past marker-like lines" {
    const t = std.testing;
    const h1 = [_]MergeHunk{.{ .resolved = "x\n=======\n" }};
    try t.expectEqual(@as(u8, 8), markerLen(&h1, 7));
    const h2 = [_]MergeHunk{.{ .resolved = "x\n======\n" }};
    try t.expectEqual(@as(u8, 7), markerLen(&h2, 7));
    const h3 = [_]MergeHunk{.{ .resolved = "++++++\n" }};
    try t.expectEqual(@as(u8, 8), markerLen(&h3, 7));
}
