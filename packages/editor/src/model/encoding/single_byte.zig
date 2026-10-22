//! Legacy single-byte encodings from the WHATWG Encoding Standard. The
//! 128-entry index tables for bytes 0x80..0xFF are parsed at compile time
//! from the vendored `whatwg/index-*.txt` files (CC BY 4.0, see
//! whatwg/LICENSE). Bytes the index leaves undefined decode to the private
//! sentinel U+F700 + byte (outside every WHATWG output) and encode back,
//! so any file round-trips byte-exactly.

const std = @import("std");

/// First code point of the sentinel range; byte b (0x80..0xFF) maps to
/// `sentinel_base + b`.
pub const sentinel_base: u21 = 0xF700;

/// Encodings with a WHATWG single-byte index, by index file name.
pub const Index = enum {
    ibm866,
    iso_8859_2,
    iso_8859_3,
    iso_8859_4,
    iso_8859_5,
    iso_8859_6,
    iso_8859_7,
    iso_8859_8,
    iso_8859_10,
    iso_8859_13,
    iso_8859_14,
    iso_8859_15,
    iso_8859_16,
    koi8_r,
    koi8_u,
    macintosh,
    windows_874,
    windows_1250,
    windows_1251,
    windows_1252,
    windows_1253,
    windows_1254,
    windows_1255,
    windows_1256,
    windows_1257,
    windows_1258,

    fn fileName(comptime i: Index) []const u8 {
        comptime var name: [@tagName(i).len]u8 = @tagName(i)[0..].*;
        inline for (&name) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const final = name;
        return "whatwg/index-" ++ &final ++ ".txt";
    }
};

/// One encoding's tables: `decode[b - 0x80]` (0 when undefined) and the
/// defined entries sorted by code point for encoding.
pub const Table = struct {
    decode: [128]u16,
    rev_cp: []const u16,
    rev_byte: []const u8,

    /// The code point byte `b` (>= 0x80) decodes to.
    pub fn toCp(t: *const Table, b: u8) u21 {
        const cp = t.decode[b - 0x80];
        return if (cp == 0) sentinel_base + b else cp;
    }

    /// The byte for code point `cp` (>= 0x80), if any.
    pub fn toByte(t: *const Table, cp: u21) ?u8 {
        if (cp >= sentinel_base + 0x80 and cp <= sentinel_base + 0xFF) {
            const b: u8 = @intCast(cp - sentinel_base);
            return if (t.decode[b - 0x80] == 0) b else null;
        }
        if (cp > 0xFFFF) return null;
        const c: u16 = @intCast(cp);
        var lo: usize = 0;
        var hi: usize = t.rev_cp.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (t.rev_cp[mid] < c) lo = mid + 1 else hi = mid;
        }
        return if (lo < t.rev_cp.len and t.rev_cp[lo] == c) t.rev_byte[lo] else null;
    }
};

fn parse(comptime text: []const u8) [128]u16 {
    @setEvalBranchQuota(200_000);
    var out = [_]u16{0} ** 128;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const ptr = std.fmt.parseInt(u8, f.next().?, 10) catch unreachable;
        const cp = std.fmt.parseInt(u16, f.next().?, 0) catch unreachable;
        out[ptr] = cp;
    }
    return out;
}

fn build(comptime i: Index) Table {
    @setEvalBranchQuota(200_000);
    const dec = parse(@embedFile(i.fileName()));
    comptime var n: usize = 0;
    inline for (dec) |cp| {
        if (cp != 0) n += 1;
    }
    comptime var cps: [n]u16 = undefined;
    comptime var bytes: [n]u8 = undefined;
    comptime var k: usize = 0;
    inline for (dec, 0..) |cp, b| {
        if (cp != 0) {
            cps[k] = cp;
            bytes[k] = 0x80 + b;
            k += 1;
        }
    }
    // Insertion sort by code point.
    comptime var x: usize = 1;
    inline while (x < n) : (x += 1) {
        comptime var y = x;
        inline while (y > 0 and cps[y - 1] > cps[y]) : (y -= 1) {
            const tc = cps[y];
            cps[y] = cps[y - 1];
            cps[y - 1] = tc;
            const tb = bytes[y];
            bytes[y] = bytes[y - 1];
            bytes[y - 1] = tb;
        }
    }
    const fc = cps;
    const fb = bytes;
    return .{ .decode = dec, .rev_cp = &fc, .rev_byte = &fb };
}

/// Every table, by index.
pub const tables = blk: {
    @setEvalBranchQuota(10_000_000);
    var t: std.enums.EnumArray(Index, Table) = undefined;
    for (std.enums.values(Index)) |i| t.set(i, build(i));
    break :blk t;
};

/// The table for `i`.
pub fn table(i: Index) *const Table {
    return tables.getPtrConst(i);
}

/// Appends the UTF-8 of `in` decoded with `t`.
pub fn decode(t: *const Table, in: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try out.ensureUnusedCapacity(gpa, in.len);
    var i: usize = 0;
    while (i < in.len) {
        const run = asciiLen(in[i..]);
        try out.appendSlice(gpa, in[i..][0..run]);
        i += run;
        if (i == in.len) break;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(t.toCp(in[i]), &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..n]);
        i += 1;
    }
}

/// Length of the leading ASCII run of `s`, 32 bytes at a time.
pub fn asciiLen(s: []const u8) usize {
    const V = @Vector(32, u8);
    var i: usize = 0;
    while (i + 32 <= s.len) : (i += 32) {
        const v: V = s[i..][0..32].*;
        if (@reduce(.Max, v) >= 0x80) break;
    }
    while (i < s.len and s[i] < 0x80) i += 1;
    return i;
}

test "single_byte: tables parse" {
    const w = table(.windows_1252);
    try std.testing.expectEqual(@as(u21, 0x20AC), w.toCp(0x80));
    try std.testing.expectEqual(@as(?u8, 0x80), w.toByte(0x20AC));
    try std.testing.expectEqual(@as(u21, 0xFF), w.toCp(0xFF));
    // windows-874 leaves 0xDB undefined: sentinel both ways.
    const t = table(.windows_874);
    try std.testing.expectEqual(sentinel_base + 0xDB, t.toCp(0xDB));
    try std.testing.expectEqual(@as(?u8, 0xDB), t.toByte(sentinel_base + 0xDB));
    try std.testing.expectEqual(@as(?u8, null), w.toByte(sentinel_base + 0x80));
    try std.testing.expectEqual(@as(?u8, null), w.toByte(0x4E00));
}
