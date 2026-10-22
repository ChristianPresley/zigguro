//! The compiled Thompson NFA over bytes that every engine runs.
//!
//! States are a flat array indexed by `StateId`. Byte-consuming states are
//! `byte_range` and `sparse`; everything else is an epsilon transition.
//! `union_` alternatives are in priority order, which is what gives
//! leftmost-first (Perl) semantics. A forward program has capture states
//! (slots `2g` and `2g+1` for group `g`); a reverse program has none.

const std = @import("std");
const Look = @import("../syntax/hir.zig").Look;

/// Index of a state.
pub const StateId = u32;
/// Index of a pattern in a multi-pattern program.
pub const PatternId = u32;

/// A byte-range transition.
pub const Transition = struct {
    lo: u8,
    hi: u8,
    next: StateId,

    /// Whether `b` is in the range.
    pub inline fn contains(t: Transition, b: u8) bool {
        return b >= t.lo and b <= t.hi;
    }
};

/// One NFA state.
pub const State = union(enum) {
    /// Consume one byte in `[lo, hi]`.
    byte_range: Transition,
    /// Consume one byte in any listed range (sorted, disjoint).
    sparse: []const Transition,
    /// Zero-width assertion.
    look: struct { look: Look, next: StateId },
    /// Ordered alternatives.
    union_: []const StateId,
    /// Two ordered alternatives.
    binary_union: struct { alt1: StateId, alt2: StateId },
    /// Record the current position in `slot`.
    capture: struct { slot: u32, next: StateId },
    /// Epsilon.
    empty: StateId,
    /// Never matches.
    fail,
    /// A match of pattern `id`.
    match: PatternId,
};

/// A bitmask of `Look` values.
pub const LookSet = packed struct(u32) {
    bits: u32 = 0,

    /// Adds `l`.
    pub fn insert(s: *LookSet, l: Look) void {
        s.bits |= @as(u32, 1) << @intCast(@intFromEnum(l));
    }

    /// Whether `l` is in the set.
    pub fn contains(s: LookSet, l: Look) bool {
        return s.bits & (@as(u32, 1) << @intCast(@intFromEnum(l))) != 0;
    }

    /// Whether the set is empty.
    pub fn isEmpty(s: LookSet) bool {
        return s.bits == 0;
    }

    /// The union.
    pub fn unionWith(a: LookSet, b: LookSet) LookSet {
        return .{ .bits = a.bits | b.bits };
    }

    /// Whether the set has a Unicode word assertion.
    pub fn hasUnicodeWord(s: LookSet) bool {
        inline for (.{ .word_unicode, .word_unicode_negate, .word_start_unicode, .word_end_unicode, .word_start_half_unicode, .word_end_half_unicode }) |l| {
            if (s.contains(l)) return true;
        }
        return false;
    }

    /// Whether the set has any word assertion.
    pub fn hasWord(s: LookSet) bool {
        return s.bits >> @intCast(@intFromEnum(Look.word_unicode)) != 0;
    }
};

/// Byte equivalence classes: bytes in one class are indistinguishable to
/// the program (and to its assertions).
pub const ByteClasses = struct {
    map: [256]u8,
    /// Number of classes (1..256).
    len: u16,

    /// The class of `b`.
    pub inline fn get(c: *const ByteClasses, b: u8) u8 {
        return c.map[b];
    }

    /// Computes classes from boundary marks: `bound[b]` means `b` and
    /// `b + 1` fall in different classes.
    pub fn fromBoundaries(bound: *const std.StaticBitSet(256)) ByteClasses {
        var c: ByteClasses = .{ .map = undefined, .len = 0 };
        var id: u16 = 0;
        for (0..256) |b| {
            c.map[b] = @intCast(id);
            if (bound.isSet(b) and b < 255) id += 1;
        }
        c.len = id + 1;
        return c;
    }

    /// One representative byte per class, in class order.
    pub fn representatives(c: *const ByteClasses, out: *[256]u8) []u8 {
        var n: usize = 0;
        var prev: i32 = -1;
        for (0..256) |b| {
            if (@as(i32, c.map[b]) != prev) {
                out[n] = @intCast(b);
                n += 1;
                prev = c.map[b];
            }
        }
        return out[0..n];
    }
};

/// A compiled program.
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    states: []const State,
    /// Anchored start: union of every pattern's start.
    start_anchored: StateId,
    /// Unanchored start: `(?s-u:.)*?` followed by `start_anchored`.
    start_unanchored: StateId,
    /// Anchored start of each pattern.
    pattern_starts: []const StateId,
    /// Number of capture slots per match (2 per group, group 0 included);
    /// 0 for reverse and multi-pattern programs.
    slot_count: u32,
    /// Capture group names, indexed by group.
    group_names: []const ?[]const u8,
    /// Every assertion used.
    looks: LookSet,
    /// Byte equivalence classes.
    classes: ByteClasses,
    /// Whether this is a reverse program.
    reverse: bool,
    /// Approximate heap size in bytes.
    memory_bytes: usize,

    /// Frees the program.
    pub fn deinit(p: *Program) void {
        p.arena.deinit();
    }

    /// Number of patterns.
    pub fn patternCount(p: *const Program) usize {
        return p.pattern_starts.len;
    }

    /// Writes one line per state (for tests and debugging).
    pub fn dump(p: *const Program, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (p.states, 0..) |s, i| {
            try w.print("{d:>4}: ", .{i});
            switch (s) {
                .byte_range => |t| try w.print("{X:0>2}-{X:0>2} => {d}\n", .{ t.lo, t.hi, t.next }),
                .sparse => |ts| {
                    for (ts, 0..) |t, k| {
                        if (k > 0) try w.writeAll(", ");
                        try w.print("{X:0>2}-{X:0>2} => {d}", .{ t.lo, t.hi, t.next });
                    }
                    try w.writeByte('\n');
                },
                .look => |l| try w.print("look {s} => {d}\n", .{ @tagName(l.look), l.next }),
                .union_ => |alts| {
                    try w.writeAll("union(");
                    for (alts, 0..) |a, k| {
                        if (k > 0) try w.writeAll(", ");
                        try w.print("{d}", .{a});
                    }
                    try w.writeAll(")\n");
                },
                .binary_union => |u| try w.print("binary_union({d}, {d})\n", .{ u.alt1, u.alt2 }),
                .capture => |c| try w.print("capture slot {d} => {d}\n", .{ c.slot, c.next }),
                .empty => |n| try w.print("empty => {d}\n", .{n}),
                .fail => try w.writeAll("fail\n"),
                .match => |pid| try w.print("match {d}\n", .{pid}),
            }
        }
    }
};

test "program: byte classes from boundaries" {
    var bound: std.StaticBitSet(256) = .initEmpty();
    bound.set('a' - 1);
    bound.set('z');
    const c = ByteClasses.fromBoundaries(&bound);
    try std.testing.expectEqual(@as(u16, 3), c.len);
    try std.testing.expectEqual(c.get('a'), c.get('m'));
    try std.testing.expect(c.get('a') != c.get('A'));
    var reps: [256]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0, 'a', '{' }, c.representatives(&reps));
}
