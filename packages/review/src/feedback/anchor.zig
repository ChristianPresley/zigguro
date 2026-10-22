//! Comment anchors (E12.F03.S03.T01): where a review thread sits in a file
//! and how it follows the text across rebases and revisions. Pure.
//!
//! - The content hash of an anchor is XxHash3 over the per-line hashes of
//!   its lines, each line XxHash3 of its text with whitespace normalised
//!   (trimmed, runs collapsed to one space, terminators dropped). Hashing
//!   lines once makes a window search a pass over `u64`s.
//! - `relocate` finds an anchor in a new text:
//!   1. through a line mapping (the hunks of the old-to-new edit) when
//!      there is one, kept when the mapped lines hash the same;
//!   2. else the same lines, when they hash the same;
//!   3. else the nearest window of the same size within `search_radius`
//!      lines with the same hash (ties go up);
//!   4. else nothing: the caller marks the thread outdated.
//! - An empty range (`count` 0) anchors between lines and has no text; it
//!   moves with the mapping and never goes outdated.

const std = @import("std");
const zg_core = @import("zg_core");
const changeset = @import("../model/changeset.zig");

const Allocator = std.mem.Allocator;
const LineRange = changeset.LineRange;
const Hunk = changeset.Hunk;
const XxHash3 = std.hash.XxHash3;

pub const search_radius = 50;

/// The side of a diff a thread is on: base lines change only when the
/// base is rebased.
pub const Side = enum { base, new };

/// One line's hash, whitespace normalised.
pub fn lineHash(line: []const u8) u64 {
    var h: XxHash3 = .init(0);
    var words = std.mem.tokenizeAny(u8, line, " \t\r\n\x0b\x0c");
    var first = true;
    while (words.next()) |word| {
        if (!first) h.update(" ");
        first = false;
        h.update(word);
    }
    return h.final();
}

/// The hash of a window of line hashes.
pub fn windowHash(lines: []const u64) u64 {
    return XxHash3.hash(0, std.mem.sliceAsBytes(lines));
}

/// Per-line hashes of a text, for hashing and searching windows.
pub const LineHashes = struct {
    hashes: []u64,

    pub fn init(gpa: Allocator, text: []const u8) Allocator.Error!LineHashes {
        var idx = try zg_core.LineIndex.build(gpa, text);
        defer idx.deinit(gpa);
        const n = idx.lineCount();
        const hs = try gpa.alloc(u64, n);
        for (hs, 0..) |*h, i| h.* = lineHash(lineText(text, &idx, @intCast(i)));
        return .{ .hashes = hs };
    }

    pub fn deinit(lh: *LineHashes, gpa: Allocator) void {
        gpa.free(lh.hashes);
    }

    pub fn count(lh: *const LineHashes) u32 {
        return @intCast(lh.hashes.len);
    }

    /// The hash of `r`, or null when it runs past the end.
    pub fn hashOf(lh: *const LineHashes, r: LineRange) ?u64 {
        if (r.end() > lh.hashes.len) return null;
        return windowHash(lh.hashes[r.start..r.end()]);
    }
};

/// The text of line `l` without its terminator.
pub fn lineText(text: []const u8, idx: *const zg_core.LineIndex, l: u32) []const u8 {
    const s: usize = @intCast(idx.lineStart(l));
    const e: usize = if (l + 1 < idx.lineCount()) @intCast(idx.lineStart(l + 1)) else text.len;
    return std.mem.trimEnd(u8, text[s..e], "\r\n");
}

/// The bytes of lines `r` of `text`, terminators included (the last
/// known text an outdated thread shows).
pub fn rangeText(gpa: Allocator, text: []const u8, r: LineRange) Allocator.Error![]const u8 {
    var idx = try zg_core.LineIndex.build(gpa, text);
    defer idx.deinit(gpa);
    if (r.count == 0 or r.start >= idx.lineCount()) return "";
    const s: usize = @intCast(idx.lineStart(r.start));
    const e: usize = if (r.end() < idx.lineCount()) @intCast(idx.lineStart(r.end())) else text.len;
    return text[s..e];
}

/// The hash of lines `r` of `text`.
pub fn hashRange(gpa: Allocator, text: []const u8, r: LineRange) Allocator.Error!u64 {
    var lh: LineHashes = try .init(gpa, text);
    defer lh.deinit(gpa);
    return lh.hashOf(r) orelse 0;
}

/// Maps old line `l` through `map` (the hunks of the old-to-new edit, in
/// order, base lines = old): null inside a replaced block.
pub fn mapLine(map: []const Hunk, l: u32) ?u32 {
    var delta: i64 = 0;
    for (map) |h| {
        if (l < h.base_lines.start) break;
        if (l < h.base_lines.end()) return null;
        delta += @as(i64, h.new_lines.count) - @as(i64, h.base_lines.count);
    }
    return @intCast(@as(i64, l) + delta);
}

/// Maps a range: both ends must map and keep the size.
pub fn mapRange(map: []const Hunk, r: LineRange) ?LineRange {
    if (r.count == 0) {
        // An insertion point moves with the line after it, or after the
        // block that replaced it.
        var delta: i64 = 0;
        for (map) |h| {
            if (r.start <= h.base_lines.start) break;
            if (r.start < h.base_lines.end()) return .{ .start = h.new_lines.end(), .count = 0 };
            delta += @as(i64, h.new_lines.count) - @as(i64, h.base_lines.count);
        }
        return .{ .start = @intCast(@as(i64, r.start) + delta), .count = 0 };
    }
    const s = mapLine(map, r.start) orelse return null;
    const e = mapLine(map, r.end() - 1) orelse return null;
    if (e - s + 1 != r.count) return null;
    return .{ .start = s, .count = r.count };
}

/// Where the anchor `r` with `hash` is in the text `lh` hashes; null when
/// it is gone. See the file comment.
pub fn relocate(lh: *const LineHashes, r: LineRange, hash: u64, map: ?[]const Hunk) ?LineRange {
    var center = r.start;
    if (map) |m| {
        if (mapRange(m, r)) |mr| {
            if (mr.count == 0) return if (mr.start <= lh.count()) mr else null;
            if (lh.hashOf(mr) == hash) return mr;
            center = mr.start;
        } else if (mapLine(m, r.start)) |s| center = s;
    }
    if (r.count == 0) return if (r.start <= lh.count()) r else null;
    if (lh.hashOf(.{ .start = center, .count = r.count }) == hash) return .{ .start = center, .count = r.count };
    var d: u32 = 1;
    while (d <= search_radius) : (d += 1) {
        if (center >= d) {
            const up: LineRange = .{ .start = center - d, .count = r.count };
            if (lh.hashOf(up) == hash) return up;
        }
        const down: LineRange = .{ .start = center + d, .count = r.count };
        if (lh.hashOf(down) == hash) return down;
    }
    return null;
}

test "anchor: hash ignores whitespace differences" {
    try std.testing.expectEqual(lineHash("  foo(a,  b);\r\n"), lineHash("foo(a, b);"));
    try std.testing.expect(lineHash("foo(a,b);") != lineHash("foo(a, b);"));
    try std.testing.expectEqual(lineHash(""), lineHash(" \t "));
}

test "anchor: map through hunks" {
    // Two lines inserted before old line 3; old line 6 replaced.
    const map = [_]Hunk{
        .{ .id = 0, .base_lines = .{ .start = 3, .count = 0 }, .new_lines = .{ .start = 3, .count = 2 }, .replace_span = .{ 0, 1 } },
        .{ .id = 1, .base_lines = .{ .start = 6, .count = 1 }, .new_lines = .{ .start = 8, .count = 1 }, .replace_span = .{ 1, 2 } },
    };
    try std.testing.expectEqual(@as(?u32, 2), mapLine(&map, 2));
    try std.testing.expectEqual(@as(?u32, 5), mapLine(&map, 3));
    try std.testing.expectEqual(@as(?u32, null), mapLine(&map, 6));
    try std.testing.expectEqual(@as(?u32, 9), mapLine(&map, 7));
    try std.testing.expectEqual(@as(?LineRange, .{ .start = 5, .count = 2 }), mapRange(&map, .{ .start = 3, .count = 2 }));
    try std.testing.expectEqual(@as(?LineRange, null), mapRange(&map, .{ .start = 5, .count = 2 }));
}
