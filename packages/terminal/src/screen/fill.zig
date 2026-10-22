//! Fast fills for page memory.
//!
//! Zig 0.16's compiler_rt `memset` stores one byte per iteration, and LLVM
//! turns any constant fill (`@memset`, or a loop storing zero) into a call to
//! it. On the scroll path that made blanking a 200-column row cost about
//! 2,200 instructions. These helpers store 32-byte vectors whose value is
//! hidden from the optimiser, so they stay vector loops.

const std = @import("std");

const V = @Vector(4, u64);

/// Fills `dst` with `value`.
pub fn fill64(dst: []u64, value: u64) void {
    var v: V = @splat(value);
    // Make the value opaque so the loop is not rewritten into memset.
    std.mem.doNotOptimizeAway(&v);
    const vv = v;
    var i: usize = 0;
    while (i + 4 <= dst.len) : (i += 4) {
        dst[i..][0..4].* = vv;
    }
    while (i < dst.len) : (i += 1) dst[i] = value;
}

/// Fills `dst` with copies of the 8-byte value `value`.
pub fn fill(comptime T: type, dst: []T, value: T) void {
    comptime std.debug.assert(@sizeOf(T) == 8 and @alignOf(T) == 8);
    const words: [*]u64 = @ptrCast(dst.ptr);
    fill64(words[0..dst.len], @bitCast(value));
}

/// Sets every byte of `dst` to `b` (any alignment).
pub fn bytes(dst: []u8, b: u8) void {
    var i: usize = 0;
    while (i < dst.len and (@intFromPtr(dst.ptr) + i) % 8 != 0) : (i += 1) dst[i] = b;
    const nwords = (dst.len - i) / 8;
    const words: [*]u64 = @ptrCast(@alignCast(dst.ptr + i));
    fill64(words[0..nwords], @as(u64, b) * 0x0101_0101_0101_0101);
    i += nwords * 8;
    while (i < dst.len) : (i += 1) dst[i] = b;
}

/// Fills `dst` with `value` for 2-byte elements.
pub fn fill16(dst: []u16, value: u16) void {
    const pattern: u64 = @as(u64, value) * 0x0001_0001_0001_0001;
    const mis = @intFromPtr(dst.ptr) % 8;
    const head = if (mis == 0) 0 else (8 - mis) / 2;
    var i: usize = 0;
    while (i < dst.len and i < head) : (i += 1) dst[i] = value;
    const rest = dst[i..];
    const nwords = rest.len / 4;
    const words: [*]u64 = @ptrCast(@alignCast(rest.ptr));
    fill64(words[0..nwords], pattern);
    for (rest[nwords * 4 ..]) |*x| x.* = value;
}

test "fills" {
    var a: [37]u64 = undefined;
    fill64(&a, 7);
    for (a) |x| try std.testing.expectEqual(@as(u64, 7), x);
    var b: [21]u16 align(8) = undefined;
    fill16(b[1..], 0xABCD);
    for (b[1..]) |x| try std.testing.expectEqual(@as(u16, 0xABCD), x);
    var c: [43]u8 = @splat(1);
    bytes(c[3..], 0);
    for (c[3..]) |x| try std.testing.expectEqual(@as(u8, 0), x);
    try std.testing.expectEqual(@as(u8, 1), c[2]);
}
