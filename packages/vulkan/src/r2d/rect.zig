//! `PxRect` helpers shared by damage tracking, culling and readback
//! (E02.F04.S03.T02). Rects are half-open: `[x, x + w) × [y, y + h)`.

const std = @import("std");
const types = @import("types.zig");

pub const PxRect = types.PxRect;
pub const Size = types.Size;

pub fn isEmpty(r: PxRect) bool {
    return r.w == 0 or r.h == 0;
}

pub fn right(r: PxRect) i64 {
    return @as(i64, r.x) + r.w;
}

pub fn bottom(r: PxRect) i64 {
    return @as(i64, r.y) + r.h;
}

pub fn area(r: PxRect) u64 {
    return @as(u64, r.w) * r.h;
}

fn fromEdges(x0: i64, y0: i64, x1: i64, y1: i64) PxRect {
    if (x1 <= x0 or y1 <= y0) return .{ .x = @intCast(x0), .y = @intCast(y0), .w = 0, .h = 0 };
    return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

/// The overlap of `a` and `b` (empty when they do not overlap).
pub fn intersect(a: PxRect, b: PxRect) PxRect {
    return fromEdges(@max(a.x, b.x), @max(a.y, b.y), @min(right(a), right(b)), @min(bottom(a), bottom(b)));
}

pub fn overlaps(a: PxRect, b: PxRect) bool {
    return !isEmpty(intersect(a, b));
}

/// The bounding box of `a` and `b` (an empty rect is ignored).
pub fn unionBox(a: PxRect, b: PxRect) PxRect {
    if (isEmpty(a)) return b;
    if (isEmpty(b)) return a;
    return fromEdges(@min(a.x, b.x), @min(a.y, b.y), @max(right(a), right(b)), @max(bottom(a), bottom(b)));
}

/// True when `outer` contains all of `inner`.
pub fn contains(outer: PxRect, inner: PxRect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and right(inner) <= right(outer) and bottom(inner) <= bottom(outer);
}

/// The full rect of `extent`.
pub fn full(extent: Size) PxRect {
    return .{ .x = 0, .y = 0, .w = extent.w, .h = extent.h };
}

/// `r` clamped to `extent`.
pub fn clamp(r: PxRect, extent: Size) PxRect {
    return intersect(r, full(extent));
}

test "rect: intersect, union, contains" {
    const a: PxRect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: PxRect = .{ .x = 5, .y = -5, .w = 10, .h = 10 };
    try std.testing.expectEqual(PxRect{ .x = 5, .y = 0, .w = 5, .h = 5 }, intersect(a, b));
    try std.testing.expectEqual(PxRect{ .x = 0, .y = -5, .w = 15, .h = 15 }, unionBox(a, b));
    try std.testing.expect(isEmpty(intersect(a, .{ .x = 10, .y = 0, .w = 3, .h = 3 })));
    try std.testing.expect(contains(a, .{ .x = 2, .y = 2, .w = 8, .h = 8 }) and !contains(a, b));
    try std.testing.expectEqual(PxRect{ .x = 0, .y = 0, .w = 4, .h = 3 }, clamp(.{ .x = -2, .y = -1, .w = 6, .h = 9 }, .{ .w = 4, .h = 3 }));
    try std.testing.expectEqual(@as(u64, 100), area(a));
}
