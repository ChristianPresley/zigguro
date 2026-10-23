//! Fractional ranks (E13.F03.S01.T02): the order of cards within a board
//! column, kept in each task's `rank` property so moving a card rewrites
//! one file. A rank is a base-62 fraction written without the leading
//! "0." (digits `0-9A-Za-z`, which sort in byte order), never empty and
//! never ending in `0`, so there is always room before any rank and
//! between any two. Comparing ranks is comparing bytes.

const std = @import("std");

/// Longest rank `between` hands out before the column is rebalanced.
pub const max_len = 31;

pub const digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const base = digits.len;

fn digitOf(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'Z' => c - 'A' + 10,
        'a'...'z' => c - 'a' + 36,
        else => null,
    };
}

/// A rank this module could have written.
pub fn isValid(r: []const u8) bool {
    if (r.len == 0 or r.len > 64 or r[r.len - 1] == '0') return false;
    for (r) |c| if (digitOf(c) == null) return false;
    return true;
}

pub fn order(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

pub const Error = error{ InvalidRank, RankTooLong };

/// A rank strictly between `lo` and `hi` (null: no bound on that side),
/// as short as possible. `lo` must sort before `hi`.
pub fn between(out: *[64]u8, lo: ?[]const u8, hi: ?[]const u8) Error![]const u8 {
    const a = lo orelse "";
    if (lo != null and !isValid(a)) return error.InvalidRank;
    if (hi) |h| {
        if (!isValid(h) or std.mem.order(u8, a, h) != .lt) return error.InvalidRank;
    }
    var n: usize = 0;
    try mid(out, &n, a, hi);
    return out[0..n];
}

fn push(out: *[64]u8, n: *usize, d: usize) Error!void {
    if (n.* == out.len) return error.RankTooLong;
    out[n.*] = digits[d];
    n.* += 1;
}

/// Appends the digits of a fraction strictly between `a` and `b` (as
/// fractions; `a` may be empty, `b` null means 1).
fn mid(out: *[64]u8, n: *usize, a_in: []const u8, b_in: ?[]const u8) Error!void {
    var a = a_in;
    var b = b_in;
    // Shared leading digits (with `a` padded by zeros) are kept.
    if (b) |bb| {
        var i: usize = 0;
        while (i < bb.len and (if (i < a.len) a[i] else '0') == bb[i]) i += 1;
        for (bb[0..i]) |c| try push(out, n, digitOf(c).?);
        a = if (i < a.len) a[i..] else "";
        b = bb[i..];
    }
    const da: usize = if (a.len > 0) digitOf(a[0]).? else 0;
    const db: usize = if (b) |bb| digitOf(bb[0]).? else base;
    if (db - da > 1) {
        return push(out, n, (da + db) / 2);
    }
    // Adjacent digits: `b`'s first digit alone fits when `b` goes on.
    if (b) |bb| if (bb.len > 1) return push(out, n, db);
    try push(out, n, da);
    return mid(out, n, if (a.len > 0) a[1..] else "", null);
}

/// `count` evenly spaced ranks, all of the same short length (for a
/// rebalanced column). Calls `f(ctx, i, rank)` for each in order.
pub fn spread(count: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize, []const u8) void) void {
    if (count == 0) return;
    var width: usize = 1;
    var span: u128 = base;
    while (span <= count + 1) {
        width += 1;
        span *= base;
    }
    // One more digit leaves room to insert between neighbours.
    width += 1;
    span *= base;
    var buf: [64]u8 = undefined;
    for (0..count) |i| {
        var v: u128 = span * (i + 1) / (count + 1);
        var k = width;
        while (k > 0) {
            k -= 1;
            buf[k] = digits[@intCast(v % base)];
            v /= base;
        }
        var len = width;
        while (len > 1 and buf[len - 1] == '0') len -= 1;
        f(ctx, i, buf[0..len]);
    }
}

test "between" {
    const t = std.testing;
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("V", try between(&b, null, null));
    try t.expectEqualStrings("F", try between(&b, null, "V"));
    try t.expectEqualStrings("k", try between(&b, "V", null));
    try t.expectEqualStrings("a0U", try between(&b, "a0F", "a0k"));
    // Adjacent digits go one level deeper.
    try t.expectEqualStrings("aV", try between(&b, "a", "b"));
    try t.expectEqualStrings("b", try between(&b, "a", "b5"));
    try t.expectEqualStrings("0V", try between(&b, null, "1"));
    try t.expectEqualStrings("01", try between(&b, null, "02"));
    try t.expectEqualStrings("00V", try between(&b, null, "01"));
    try t.expectError(error.InvalidRank, between(&b, "b", "a"));
    try t.expectError(error.InvalidRank, between(&b, "a", "a"));
    try t.expectError(error.InvalidRank, between(&b, "a0", null));
    try t.expectError(error.InvalidRank, between(&b, "a!", null));
}

test "spread" {
    const t = std.testing;
    var got: [100][8]u8 = undefined;
    var lens: [100]usize = undefined;
    const Ctx = struct { got: *[100][8]u8, lens: *[100]usize };
    spread(100, Ctx{ .got = &got, .lens = &lens }, struct {
        fn f(c: Ctx, i: usize, r: []const u8) void {
            @memcpy(c.got[i][0..r.len], r);
            c.lens[i] = r.len;
        }
    }.f);
    for (0..100) |i| {
        try t.expect(isValid(got[i][0..lens[i]]));
        try t.expect(lens[i] <= 3);
        if (i > 0) try t.expectEqual(std.math.Order.lt, order(got[i - 1][0..lens[i - 1]], got[i][0..lens[i]]));
    }
}
