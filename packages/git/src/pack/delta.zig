//! Git delta instructions (gitformat-pack "Deltified representation"):
//! base and result sizes as little-endian base-128 varints, then copy
//! (`1xxxxxxx`) and insert (`0xxxxxxx`, 1-127 bytes) instructions.

const std = @import("std");

/// Errors for malformed deltas.
pub const Error = error{CorruptDelta};

/// Sizes at the start of a delta.
pub const Header = struct {
    /// Expected base object size.
    base_size: u64,
    /// Size of the reconstructed object.
    result_size: u64,
    /// Offset of the first instruction.
    pos: usize,
};

/// Reads one size varint at `pos.*`.
pub fn readVarint(delta: []const u8, pos: *usize) Error!u64 {
    var v: u64 = 0;
    var shift: u7 = 0;
    while (true) {
        if (pos.* >= delta.len or shift > 63) return error.CorruptDelta;
        const b = delta[pos.*];
        pos.* += 1;
        v |= @as(u64, b & 0x7f) << @intCast(shift);
        if (b & 0x80 == 0) return v;
        shift += 7;
    }
}

/// Parses the two size varints.
pub fn parseHeader(delta: []const u8) Error!Header {
    var pos: usize = 0;
    const base_size = try readVarint(delta, &pos);
    const result_size = try readVarint(delta, &pos);
    return .{ .base_size = base_size, .result_size = result_size, .pos = pos };
}

/// Applies `delta` to `base`. `out.len` must equal the delta's result size.
/// Every copy is bounds-checked against `base` and `out`; the reserved
/// opcode 0x00 is an error.
pub fn applyDelta(base: []const u8, delta: []const u8, out: []u8) Error!void {
    const h = try parseHeader(delta);
    if (h.base_size != base.len or h.result_size != out.len) return error.CorruptDelta;
    var pos = h.pos;
    var o: usize = 0;
    while (pos < delta.len) {
        const op = delta[pos];
        pos += 1;
        if (op & 0x80 != 0) {
            var off: u32 = 0;
            var size: u32 = 0;
            inline for (0..4) |i| {
                if (op & (1 << i) != 0) {
                    if (pos >= delta.len) return error.CorruptDelta;
                    off |= @as(u32, delta[pos]) << (8 * i);
                    pos += 1;
                }
            }
            inline for (0..3) |i| {
                if (op & (0x10 << i) != 0) {
                    if (pos >= delta.len) return error.CorruptDelta;
                    size |= @as(u32, delta[pos]) << (8 * i);
                    pos += 1;
                }
            }
            if (size == 0) size = 0x10000;
            if (@as(u64, off) + size > base.len or o + size > out.len) return error.CorruptDelta;
            @memcpy(out[o..][0..size], base[off..][0..size]);
            o += size;
        } else if (op != 0) {
            const n: usize = op;
            if (pos + n > delta.len or o + n > out.len) return error.CorruptDelta;
            @memcpy(out[o..][0..n], delta[pos..][0..n]);
            pos += n;
            o += n;
        } else {
            return error.CorruptDelta;
        }
    }
    if (o != out.len) return error.CorruptDelta;
}

/// Appends a size varint.
pub fn writeVarint(w: *std.Io.Writer, v: u64) std.Io.Writer.Error!void {
    var x = v;
    while (x >= 0x80) {
        try w.writeByte(@as(u8, @truncate(x)) | 0x80);
        x >>= 7;
    }
    try w.writeByte(@truncate(x));
}

/// Appends a copy instruction for `base[off..][0..size]`, splitting sizes
/// above 0x10000 into several instructions.
pub fn writeCopy(w: *std.Io.Writer, off: u64, size: u64) std.Io.Writer.Error!void {
    var o = off;
    var left = size;
    while (left > 0) {
        const n: u32 = @intCast(@min(left, 0x10000));
        var buf: [8]u8 = undefined;
        var op: u8 = 0x80;
        var len: usize = 1;
        const oo: u32 = @intCast(o);
        inline for (0..4) |i| {
            const b: u8 = @truncate(oo >> (8 * i));
            if (b != 0) {
                op |= 1 << i;
                buf[len] = b;
                len += 1;
            }
        }
        const sz: u32 = if (n == 0x10000) 0 else n;
        inline for (0..3) |i| {
            const b: u8 = @truncate(sz >> (8 * i));
            if (b != 0) {
                op |= 0x10 << i;
                buf[len] = b;
                len += 1;
            }
        }
        buf[0] = op;
        try w.writeAll(buf[0..len]);
        o += n;
        left -= n;
    }
}

/// Appends insert instructions for `data` (chunks of at most 127 bytes).
pub fn writeInsert(w: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void {
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, 127);
        try w.writeByte(@intCast(n));
        try w.writeAll(rest[0..n]);
        rest = rest[n..];
    }
}

test "delta: spec examples incl size 0 -> 0x10000 and reserved 0x00" {
    const t = std.testing;
    const base = try t.allocator.alloc(u8, 0x20000);
    defer t.allocator.free(base);
    for (base, 0..) |*b, i| b.* = @truncate(i *% 31);

    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try writeVarint(w, base.len);
    try writeVarint(w, 0x10000 + 3 + 5);
    // Copy with all offset bytes zero and size bytes zero: offset 0, size 0x10000.
    try w.writeByte(0x80);
    try writeInsert(w, "abc");
    try writeCopy(w, 0x10001, 5);
    var out: [0x10000 + 8]u8 = undefined;
    try applyDelta(base, aw.written(), &out);
    try t.expectEqualSlices(u8, base[0..0x10000], out[0..0x10000]);
    try t.expectEqualStrings("abc", out[0x10000..][0..3]);
    try t.expectEqualSlices(u8, base[0x10001..][0..5], out[0x10003..]);

    // Reserved opcode.
    const reserved = [_]u8{ 1, 1, 0 };
    var one: [1]u8 = undefined;
    try t.expectError(error.CorruptDelta, applyDelta("x", &reserved, &one));
}

test "delta: bounds violations rejected" {
    const t = std.testing;
    var out: [4]u8 = undefined;
    // Copy past the base end.
    try t.expectError(error.CorruptDelta, applyDelta("ab", &.{ 2, 4, 0x91, 1, 4 }, &out));
    // Insert past the output end.
    try t.expectError(error.CorruptDelta, applyDelta("ab", &.{ 2, 4, 5, 'a', 'b', 'c', 'd', 'e' }, &out));
    // Truncated insert.
    try t.expectError(error.CorruptDelta, applyDelta("ab", &.{ 2, 4, 4, 'a' }, &out));
    // Result shorter than declared.
    try t.expectError(error.CorruptDelta, applyDelta("ab", &.{ 2, 4, 2, 'a', 'b' }, &out));
    // Wrong base size.
    try t.expectError(error.CorruptDelta, applyDelta("abc", &.{ 2, 4, 4, 'a', 'b', 'c', 'd' }, &out));
    // Overlong varint.
    try t.expectError(error.CorruptDelta, parseHeader(&(@as([11]u8, @splat(0xff)))));
    try applyDelta("ab", &.{ 2, 4, 0x90, 2, 2, 'c', 'd' }, &out);
    try t.expectEqualStrings("abcd", &out);
}

test "fuzz: git-delta" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const split = if (input.len == 0) 0 else input[0] % (input.len + 1);
            const base = input[0..split];
            const delta = input[split..];
            const h = parseHeader(delta) catch return;
            if (h.result_size > 4096) return;
            var out: [4096]u8 = undefined;
            applyDelta(base, delta, out[0..@intCast(h.result_size)]) catch return;
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "git-delta") });
}
