//! Horizontal tab stops: one bit per column, defaulting to every 8th column.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Tabstops = @This();

/// Default interval between stops.
pub const interval = 8;

bits: std.DynamicBitSetUnmanaged = .{},

/// Stops for `cols` columns at the default interval.
pub fn init(gpa: Allocator, cols: u16) Allocator.Error!Tabstops {
    var t: Tabstops = .{ .bits = try .initEmpty(gpa, cols) };
    t.reset();
    return t;
}

/// Frees the bit set.
pub fn deinit(t: *Tabstops, gpa: Allocator) void {
    t.bits.deinit(gpa);
}

/// Restores the default stops (every 8 columns, not column 0).
pub fn reset(t: *Tabstops) void {
    t.bits.unsetAll();
    var x: usize = interval;
    while (x < t.bits.bit_length) : (x += interval) t.bits.set(x);
}

/// Resizes to `cols`; new columns get default stops.
pub fn resize(t: *Tabstops, gpa: Allocator, cols: u16) Allocator.Error!void {
    const old = t.bits.bit_length;
    try t.bits.resize(gpa, cols, false);
    var x: usize = old;
    while (x < cols) : (x += 1) if (x % interval == 0 and x != 0) t.bits.set(x);
}

/// HTS: sets a stop at `x`.
pub fn set(t: *Tabstops, x: u16) void {
    if (x < t.bits.bit_length) t.bits.set(x);
}

/// TBC 0: clears the stop at `x`.
pub fn clear(t: *Tabstops, x: u16) void {
    if (x < t.bits.bit_length) t.bits.unset(x);
}

/// TBC 3: clears every stop.
pub fn clearAll(t: *Tabstops) void {
    t.bits.unsetAll();
}

/// The first stop after `x`, or `limit` when there is none before it.
pub fn next(t: *const Tabstops, x: u16, limit: u16) u16 {
    var i: usize = @as(usize, x) + 1;
    while (i < limit) : (i += 1) if (t.bits.isSet(i)) return @intCast(i);
    return limit;
}

/// The last stop before `x`, or `limit` when there is none after it.
pub fn prev(t: *const Tabstops, x: u16, limit: u16) u16 {
    var i: usize = x;
    while (i > limit) {
        i -= 1;
        if (t.bits.isSet(i)) return @intCast(i);
    }
    return limit;
}

test "default stops, set, clear, resize" {
    const gpa = std.testing.allocator;
    var t = try init(gpa, 20);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 8), t.next(0, 19));
    try std.testing.expectEqual(@as(u16, 16), t.next(8, 19));
    try std.testing.expectEqual(@as(u16, 19), t.next(16, 19));
    try std.testing.expectEqual(@as(u16, 8), t.prev(16, 0));
    try std.testing.expectEqual(@as(u16, 0), t.prev(8, 0));
    t.set(3);
    try std.testing.expectEqual(@as(u16, 3), t.next(0, 19));
    t.clear(3);
    t.clearAll();
    try std.testing.expectEqual(@as(u16, 19), t.next(0, 19));
    try t.resize(gpa, 40);
    try std.testing.expectEqual(@as(u16, 24), t.next(20, 39));
}
