//! Queries over a finished `Structure` that views and LSP merging use:
//! folds by line, the innermost fold or symbol at a position, and a
//! symbol's children.

const std = @import("std");
const structure = @import("structure.zig");

const Structure = structure.Structure;
const FoldRange = structure.FoldRange;
const Symbol = structure.Symbol;

/// Folds starting on lines `[first, last]`, in order.
pub fn foldsStartingIn(s: *const Structure, first: u32, last: u32) []const FoldRange {
    const a = lowerBound(s.folds, first);
    const b = lowerBound(s.folds, last +| 1);
    return s.folds[a..b];
}

fn lowerBound(folds: []const FoldRange, line: u32) usize {
    var lo: usize = 0;
    var hi: usize = folds.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (folds[mid].start_line < line) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The innermost fold whose range holds `line` (its start line counts).
pub fn foldAt(s: *const Structure, line: u32) ?FoldRange {
    var i = lowerBound(s.folds, line +| 1);
    // Folds nest, so the closest start at or before `line` that still
    // covers it is the innermost; scan back past folds that ended.
    while (i > 0) {
        i -= 1;
        const f = s.folds[i];
        if (f.end_line >= line) return f;
    }
    return null;
}

/// The innermost symbol whose range contains `pos`.
pub fn symbolAt(s: *const Structure, pos: u32) ?u32 {
    var best: ?u32 = null;
    for (s.symbols, 0..) |sym, i| {
        if (sym.range.start > pos) break;
        if (sym.range.touches(pos)) best = @intCast(i);
    }
    return best;
}

/// Iterates the children of a symbol (or the top-level symbols).
pub const ChildIterator = struct {
    symbols: []const Symbol,
    parent: ?u32,
    i: u32 = 0,

    pub fn next(it: *ChildIterator) ?u32 {
        while (it.i < it.symbols.len) {
            const i = it.i;
            it.i += 1;
            if (it.symbols[i].parent == it.parent) return i;
        }
        return null;
    }
};

pub fn children(s: *const Structure, parent: ?u32) ChildIterator {
    return .{ .symbols = s.symbols, .parent = parent, .i = if (parent) |p| p + 1 else 0 };
}

test "query: folds by line and innermost" {
    const gpa = std.testing.allocator;
    var b: structure.Builder = .init(gpa);
    try b.fold(0, 10, .block);
    try b.fold(2, 4, .block);
    try b.fold(6, 9, .comment);
    const outer = try b.symbol(.{ .name = "a", .kind = .function, .range = .{ .start = 0, .end = 100 }, .selection = .{ .start = 3, .end = 4 } });
    _ = try b.symbol(.{ .name = "b", .kind = .function, .range = .{ .start = 10, .end = 20 }, .selection = .{ .start = 13, .end = 14 }, .parent = outer });
    _ = try b.symbol(.{ .name = "c", .kind = .function, .range = .{ .start = 30, .end = 40 }, .selection = .{ .start = 33, .end = 34 }, .parent = outer });
    var s = try b.finish(1);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 2), foldsStartingIn(&s, 1, 6).len);
    try std.testing.expectEqual(@as(u32, 2), foldAt(&s, 3).?.start_line);
    try std.testing.expectEqual(@as(u32, 0), foldAt(&s, 5).?.start_line);
    try std.testing.expectEqual(@as(u32, 6), foldAt(&s, 9).?.start_line);
    try std.testing.expect(foldAt(&s, 11) == null);
    try std.testing.expectEqual(@as(?u32, 1), symbolAt(&s, 15));
    try std.testing.expectEqual(@as(?u32, 0), symbolAt(&s, 25));
    var it = children(&s, outer);
    try std.testing.expectEqual(@as(?u32, 1), it.next());
    try std.testing.expectEqual(@as(?u32, 2), it.next());
    try std.testing.expectEqual(@as(?u32, null), it.next());
}
