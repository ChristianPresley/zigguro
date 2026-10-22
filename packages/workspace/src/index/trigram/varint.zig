//! Unsigned LEB128 for posting lists: a slice encoder and a branch-light
//! slice decoder. std only, so other packages (E09's history index) can
//! reuse it.

const std = @import("std");

/// Most bytes one u32 takes.
pub const max_len_u32 = 5;

/// Appends `v` to `out`.
pub fn put(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var buf: [max_len_u32]u8 = undefined;
    try out.appendSlice(gpa, encode(&buf, v));
}

/// Encodes `v` into `buf`, returning the used prefix.
pub fn encode(buf: *[max_len_u32]u8, v: u32) []const u8 {
    var x = v;
    var n: usize = 0;
    while (x >= 0x80) : (n += 1) {
        buf[n] = @as(u8, @truncate(x)) | 0x80;
        x >>= 7;
    }
    buf[n] = @truncate(x);
    return buf[0 .. n + 1];
}

/// Errors of `decode`.
pub const DecodeError = error{ Truncated, Overflow };

/// Decodes one value from `bytes[pos.*..]` and advances `pos`.
pub inline fn decode(bytes: []const u8, pos: *usize) DecodeError!u32 {
    const i = pos.*;
    if (i >= bytes.len) return error.Truncated;
    // One-byte values dominate delta-coded postings.
    const b0 = bytes[i];
    if (b0 < 0x80) {
        pos.* = i + 1;
        return b0;
    }
    var v: u32 = b0 & 0x7F;
    var shift: u5 = 7;
    var j = i + 1;
    while (true) : (j += 1) {
        if (j >= bytes.len) return error.Truncated;
        const b = bytes[j];
        if (shift == 28 and b > 0x0F) return error.Overflow;
        v |= @as(u32, b & 0x7F) << shift;
        if (b < 0x80) break;
        if (shift == 28) return error.Overflow;
        shift += 7;
    }
    pos.* = j + 1;
    return v;
}

/// Appends a sorted id list as deltas.
pub fn putDeltas(out: *std.ArrayList(u8), gpa: std.mem.Allocator, sorted: []const u32) !void {
    var prev: u32 = 0;
    for (sorted, 0..) |d, k| {
        std.debug.assert(k == 0 or d > prev);
        try put(out, gpa, d - prev);
        prev = d;
    }
}

/// Decodes `count` delta-coded ids from `bytes`, appending to `out`, each
/// plus `base`.
pub fn getDeltas(bytes: []const u8, count: u32, base: u32, out: *std.ArrayList(u32), gpa: std.mem.Allocator) !void {
    try out.ensureUnusedCapacity(gpa, count);
    var pos: usize = 0;
    var cur: u32 = 0;
    for (0..count) |_| {
        cur += try decode(bytes, &pos);
        out.appendAssumeCapacity(base + cur);
    }
}

test "varint: roundtrip against std LEB128" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var vals: [2000]u32 = undefined;
    for (&vals, 0..) |*v, i| v.* = switch (i % 4) {
        0 => @as(u32, r.int(u8) & 0x7F),
        1 => r.int(u16),
        2 => r.int(u32),
        else => std.math.maxInt(u32) - @as(u32, r.int(u8)),
    };
    for (vals) |v| try put(&out, gpa, v);
    // std's streaming reader is the oracle.
    var rd: std.Io.Reader = .fixed(out.items);
    for (vals) |v| try std.testing.expectEqual(v, try rd.takeLeb128(u32));
    var pos: usize = 0;
    for (vals) |v| try std.testing.expectEqual(v, try decode(out.items, &pos));
    try std.testing.expectEqual(out.items.len, pos);
    pos = 0;
    try std.testing.expectError(error.Truncated, decode(&.{ 0x80, 0x80 }, &pos));
    pos = 0;
    try std.testing.expectError(error.Overflow, decode(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F }, &pos));
}

test "varint: deltas" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const ids = [_]u32{ 0, 1, 5, 200, 70000, 70001 };
    try putDeltas(&out, gpa, &ids);
    var back: std.ArrayList(u32) = .empty;
    defer back.deinit(gpa);
    try getDeltas(out.items, ids.len, 10, &back, gpa);
    for (ids, back.items) |a, b| try std.testing.expectEqual(a + 10, b);
}
