//! Grapheme storage for a page: the extra code points of multi-code-point
//! clusters (the base code point stays in `Cell.content`). Blocks of 2, 4, 8
//! or 16 code points come from a bump arena with one free list per size
//! class. A `CellMap` maps cell index → (block offset, length | class << 8).

const std = @import("std");

/// Maximum extra code points kept per cluster; longer clusters are truncated
/// (they do not occur in real text).
pub const max_extra = 16;

/// Size classes in code points.
pub const classes = [_]u8{ 2, 4, 8, 16 };

/// The size class index for `n` extra code points.
pub fn classFor(n: usize) u2 {
    for (classes, 0..) |c, i| if (n <= c) return @intCast(i);
    return 3;
}

/// The arena's location in a page buffer.
pub const Arena = struct {
    off: u32,
    /// Capacity in code points.
    cap: u32,

    /// Mutable counters kept in the page header.
    pub const State = extern struct {
        used: u32 = 0,
        /// Free-list heads per class (block offset + 1, 0 = empty).
        free: [4]u32 = @splat(0),
    };

    /// The code-point storage.
    pub fn data(a: Arena, base: [*]u8) []u21 {
        const p: [*]u21 = @ptrCast(@alignCast(base + a.off));
        return p[0..a.cap];
    }

    /// Allocates a block of class `c`; returns its offset in code points.
    pub fn alloc(a: Arena, base: [*]u8, st: *State, c: u2) error{GraphemeArenaFull}!u32 {
        const d = a.data(base);
        if (st.free[c] != 0) {
            const off = st.free[c] - 1;
            st.free[c] = d[off];
            return off;
        }
        const n = classes[c];
        if (st.used + n > a.cap) return error.GraphemeArenaFull;
        const off = st.used;
        st.used += n;
        return off;
    }

    /// Returns a block to its class's free list.
    pub fn free(a: Arena, base: [*]u8, st: *State, off: u32, c: u2) void {
        a.data(base)[off] = @intCast(st.free[c]);
        st.free[c] = off + 1;
    }

    /// Empties the arena.
    pub fn clear(st: *State) void {
        st.* = .{};
    }
};

test "classFor" {
    try std.testing.expectEqual(@as(u2, 0), classFor(1));
    try std.testing.expectEqual(@as(u2, 1), classFor(3));
    try std.testing.expectEqual(@as(u2, 3), classFor(16));
}
