//! The high-level IR: the AST with flags resolved, Unicode classes expanded
//! to code point sets, case-insensitivity applied and literals coalesced.
//! The NFA compiler consumes it. Nodes live in the translator's arena.

const std = @import("std");
const class = @import("class.zig");

pub const RangeSet = class.RangeSet;
pub const ByteSet = class.ByteSet;

/// Zero-width assertions after flag resolution.
pub const Look = enum(u8) {
    start_text,
    end_text,
    start_line,
    end_line,
    start_line_crlf,
    end_line_crlf,
    word_unicode,
    word_unicode_negate,
    word_ascii,
    word_ascii_negate,
    word_start_unicode,
    word_end_unicode,
    word_start_half_unicode,
    word_end_half_unicode,
    word_start_ascii,
    word_end_ascii,
    word_start_half_ascii,
    word_end_half_ascii,

    /// Whether the assertion depends on the word-ness of neighbouring
    /// characters.
    pub fn isWord(l: Look) bool {
        return @intFromEnum(l) >= @intFromEnum(Look.word_unicode);
    }

    /// Whether the assertion needs Unicode word data (non-ASCII words).
    pub fn isUnicodeWord(l: Look) bool {
        return switch (l) {
            .word_unicode, .word_unicode_negate, .word_start_unicode, .word_end_unicode, .word_start_half_unicode, .word_end_half_unicode => true,
            else => false,
        };
    }
};

/// A HIR node.
pub const Hir = union(enum) {
    /// Matches the empty string.
    empty,
    /// Matches these bytes exactly (UTF-8 for Unicode literals).
    literal: []const u8,
    /// Matches one code point of the set (UTF-8 encoded in the haystack).
    class_unicode: RangeSet,
    /// Matches one byte of the set.
    class_bytes: ByteSet,
    /// A zero-width assertion.
    look: Look,
    /// `sub{min,max}`; `max == null` is unbounded.
    repetition: struct { min: u32, max: ?u32, greedy: bool, sub: *Hir },
    /// A capture group; index 0 is the implicit whole-match group.
    capture: struct { index: u32, name: ?[]const u8, sub: *Hir },
    /// A sequence.
    concat: []*Hir,
    /// An ordered choice (leftmost-first).
    alternation: []*Hir,

    /// Whether the node can only match the empty string at a fixed point
    /// (looks and empty).
    pub fn isZeroWidth(h: *const Hir) bool {
        return switch (h.*) {
            .empty, .look => true,
            .capture => |c| c.sub.isZeroWidth(),
            .concat => |items| for (items) |it| {
                if (!it.isZeroWidth()) break false;
            } else true,
            else => false,
        };
    }
};

/// Writes a compact, deterministic description of `h` (used in tests).
pub fn dump(h: *const Hir, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (h.*) {
        .empty => try w.writeAll("ε"),
        .literal => |b| try w.print("lit(\"{f}\")", .{std.zig.fmtString(b)}),
        .class_unicode => |s| {
            try w.writeAll("cls[");
            for (s.ranges, 0..) |r, i| {
                if (i == 8) {
                    try w.print("…+{d}", .{s.ranges.len - 8});
                    break;
                }
                if (i > 0) try w.writeByte(' ');
                if (r[0] == r[1]) try w.print("{X}", .{r[0]}) else try w.print("{X}-{X}", .{ r[0], r[1] });
            }
            try w.writeByte(']');
        },
        .class_bytes => |s| {
            var buf: [128][2]u8 = undefined;
            try w.writeAll("bytes[");
            for (s.ranges(&buf), 0..) |r, i| {
                if (i > 0) try w.writeByte(' ');
                if (r[0] == r[1]) try w.print("{X}", .{r[0]}) else try w.print("{X}-{X}", .{ r[0], r[1] });
            }
            try w.writeByte(']');
        },
        .look => |l| try w.print("look({s})", .{@tagName(l)}),
        .repetition => |r| {
            try w.writeAll("rep(");
            try dump(r.sub, w);
            if (r.max) |m| try w.print("){{{d},{d}}}", .{ r.min, m }) else try w.print("){{{d},}}", .{r.min});
            if (!r.greedy) try w.writeByte('?');
        },
        .capture => |c| {
            try w.print("cap{d}", .{c.index});
            if (c.name) |n| try w.print("<{s}>", .{n});
            try w.writeByte('(');
            try dump(c.sub, w);
            try w.writeByte(')');
        },
        .concat => |items| {
            try w.writeAll("cat(");
            for (items, 0..) |it, i| {
                if (i > 0) try w.writeByte(' ');
                try dump(it, w);
            }
            try w.writeByte(')');
        },
        .alternation => |items| {
            try w.writeAll("alt(");
            for (items, 0..) |it, i| {
                if (i > 0) try w.writeByte('|');
                try dump(it, w);
            }
            try w.writeByte(')');
        },
    }
}
