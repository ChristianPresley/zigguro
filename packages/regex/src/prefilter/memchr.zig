//! SIMD byte search: `memchr` for one, two or three needle bytes, and
//! `memrchr`. Vectors of 32 bytes compare all lanes at once and the first
//! set lane is found with a count-trailing-zeros on the lane mask; the tail
//! falls back to a scalar loop.

const std = @import("std");

const V = 32;
const Vec = @Vector(V, u8);
const Mask = std.meta.Int(.unsigned, V);

inline fn load(s: []const u8, i: usize) Vec {
    return s[i..][0..V].*;
}

inline fn maskOf(b: @Vector(V, bool)) Mask {
    return @bitCast(b);
}

/// The first index `>= from` of `a` in `hay`, or null.
pub fn memchr(a: u8, hay: []const u8, from: usize) ?usize {
    var i = from;
    const va: Vec = @splat(a);
    while (i + V <= hay.len) : (i += V) {
        const m = maskOf(load(hay, i) == va);
        if (m != 0) return i + @ctz(m);
    }
    while (i < hay.len) : (i += 1) if (hay[i] == a) return i;
    return null;
}

/// The first index `>= from` of `a` or `b` in `hay`, or null.
pub fn memchr2(a: u8, b: u8, hay: []const u8, from: usize) ?usize {
    var i = from;
    const va: Vec = @splat(a);
    const vb: Vec = @splat(b);
    while (i + V <= hay.len) : (i += V) {
        const x = load(hay, i);
        const m = maskOf(x == va) | maskOf(x == vb);
        if (m != 0) return i + @ctz(m);
    }
    while (i < hay.len) : (i += 1) if (hay[i] == a or hay[i] == b) return i;
    return null;
}

/// The first index `>= from` of `a`, `b` or `c` in `hay`, or null.
pub fn memchr3(a: u8, b: u8, c: u8, hay: []const u8, from: usize) ?usize {
    var i = from;
    const va: Vec = @splat(a);
    const vb: Vec = @splat(b);
    const vc: Vec = @splat(c);
    while (i + V <= hay.len) : (i += V) {
        const x = load(hay, i);
        const m = maskOf(x == va) | maskOf(x == vb) | maskOf(x == vc);
        if (m != 0) return i + @ctz(m);
    }
    while (i < hay.len) : (i += 1) if (hay[i] == a or hay[i] == b or hay[i] == c) return i;
    return null;
}

/// The last index `< to` of `a` in `hay`, or null.
pub fn memrchr(a: u8, hay: []const u8, to: usize) ?usize {
    var i = to;
    const va: Vec = @splat(a);
    while (i >= V) {
        const m = maskOf(load(hay, i - V) == va);
        if (m != 0) return i - 1 - @clz(m);
        i -= V;
    }
    while (i > 0) {
        i -= 1;
        if (hay[i] == a) return i;
    }
    return null;
}

test "memchr: agrees with a scalar scan" {
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    var buf: [300]u8 = undefined;
    for (0..500) |_| {
        const n = rnd.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.intRangeAtMost(u8, 'a', 'h');
        const hay = buf[0..n];
        const from = rnd.intRangeAtMost(usize, 0, n);
        const a = rnd.intRangeAtMost(u8, 'a', 'i');
        const b = rnd.intRangeAtMost(u8, 'a', 'i');
        const c = rnd.intRangeAtMost(u8, 'a', 'i');
        try std.testing.expectEqual(std.mem.indexOfScalarPos(u8, hay, from, a), memchr(a, hay, from));
        try std.testing.expectEqual(std.mem.indexOfAnyPos(u8, hay, from, &.{ a, b }), memchr2(a, b, hay, from));
        try std.testing.expectEqual(std.mem.indexOfAnyPos(u8, hay, from, &.{ a, b, c }), memchr3(a, b, c, hay, from));
        try std.testing.expectEqual(std.mem.lastIndexOfScalar(u8, hay[0..from], a), memrchr(a, hay, from));
    }
}
