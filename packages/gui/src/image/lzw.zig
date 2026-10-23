//! GIF's variable-length LZW (GIF89a Appendix F): codes from
//! `min_code_size + 1` bits up to 12, LSB first, with clear and end codes.
//! The dictionary is two fixed arrays (prefix code, suffix byte), so no
//! code allocates. When it fills up, decoding carries on with 12-bit
//! codes until the encoder sends a clear ("deferred clear").

const std = @import("std");
const image = @import("image.zig");

const DecodeError = image.DecodeError;
const max_codes = 4096;

pub const LzwDecoder = struct {
    min_code_size: u4,
    clear: u16,
    eoi: u16,
    next: u16,
    code_size: u5,
    prev: ?u16 = null,
    prefix: [max_codes]u16 = undefined,
    suffix: [max_codes]u8 = undefined,
    /// The first byte of each code's string.
    first: [max_codes]u8 = undefined,
    /// Bit reader state across `feed` calls.
    bits: u32 = 0,
    nbits: u5 = 0,
    /// Bytes of the data read so far.
    pos: usize = 0,
    done: bool = false,
    /// A string that did not fit in the last `out`.
    pending: [max_codes]u8 = undefined,
    pending_start: u16 = 0,
    pending_end: u16 = 0,

    /// `min_code_size` must be 2..11 (`feed` reports others as
    /// `Malformed`).
    pub fn init(min_code_size: u4) LzwDecoder {
        const m: u4 = @min(min_code_size, 11);
        const clear: u16 = @as(u16, 1) << m;
        var d: LzwDecoder = .{ .min_code_size = min_code_size, .clear = clear, .eoi = clear + 1, .next = clear + 2, .code_size = @as(u5, m) + 1 };
        for (0..clear) |i| {
            d.suffix[i] = @truncate(i);
            d.first[i] = @truncate(i);
            d.prefix[i] = 0;
        }
        return d;
    }

    fn reset(d: *LzwDecoder) void {
        d.next = d.eoi + 1;
        d.code_size = @as(u5, @min(d.min_code_size, 11)) + 1;
        d.prev = null;
    }

    /// Decodes the data bytes (sub-block lengths removed) into `out`;
    /// returns how many bytes it wrote. `data` is all the data so far:
    /// the same bytes on every call, possibly with more appended. It stops
    /// at the end code, when `out` is full, or when `data` runs out.
    pub fn feed(d: *LzwDecoder, data: []const u8, out: []u8) DecodeError!usize {
        if (d.min_code_size < 2 or d.min_code_size > 11) return error.Malformed;
        var n: usize = d.drain(out);
        var i: usize = d.pos;
        defer d.pos = i;
        while (n < out.len and !d.done) {
            while (d.nbits < d.code_size) {
                if (i >= data.len) return n;
                d.bits |= @as(u32, data[i]) << d.nbits;
                d.nbits += 8;
                i += 1;
            }
            const mask = (@as(u32, 1) << d.code_size) - 1;
            const code: u16 = @intCast(d.bits & mask);
            d.bits >>= d.code_size;
            d.nbits -= d.code_size;

            if (code == d.clear) {
                d.reset();
                continue;
            }
            if (code == d.eoi) {
                d.done = true;
                break;
            }
            const prev = d.prev orelse {
                if (code >= d.clear) return error.Malformed;
                out[n] = @truncate(code);
                n += 1;
                d.prev = code;
                continue;
            };
            var head: u8 = undefined;
            if (code < d.next) {
                head = d.first[code];
                n += d.emit(code, null, out[n..]);
            } else if (code == d.next and d.next < max_codes) {
                head = d.first[prev];
                n += d.emit(prev, head, out[n..]);
            } else return error.Malformed;
            if (d.next < max_codes) {
                d.prefix[d.next] = prev;
                d.suffix[d.next] = head;
                d.first[d.next] = d.first[prev];
                d.next += 1;
                if (d.next == (@as(u32, 1) << d.code_size) and d.code_size < 12) d.code_size += 1;
            }
            d.prev = code;
        }
        return n;
    }

    /// Writes the string of `code` (then `extra`) to `out`; what does not
    /// fit waits in `pending`.
    fn emit(d: *LzwDecoder, code: u16, extra: ?u8, out: []u8) usize {
        // Walk the chain backwards into the end of `pending`.
        var end: usize = max_codes;
        if (extra) |e| {
            end -= 1;
            d.pending[end] = e;
        }
        var c = code;
        var start = end;
        while (true) {
            start -= 1;
            d.pending[start] = d.suffix[c];
            if (c < d.clear) break;
            c = d.prefix[c];
            if (start == 0) break;
        }
        d.pending_start = @intCast(start);
        d.pending_end = @intCast(max_codes);
        if (extra == null) d.pending_end = @intCast(end);
        return d.drain(out);
    }

    fn drain(d: *LzwDecoder, out: []u8) usize {
        const avail = d.pending_end - d.pending_start;
        const k = @min(avail, out.len);
        @memcpy(out[0..k], d.pending[d.pending_start..][0..k]);
        d.pending_start += @intCast(k);
        return k;
    }

    /// Whether the end code was read.
    pub fn finished(d: *const LzwDecoder) bool {
        return d.done;
    }
};

/// LZW-encodes `pixels` the way GIF encoders do (tests and fixtures):
/// a clear first, then codes growing to 12 bits, a clear when the
/// dictionary fills (unless `defer_clear`), and the end code.
pub fn encode(gpa: std.mem.Allocator, min_code_size: u4, pixels: []const u8, defer_clear: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const clear: u16 = @as(u16, 1) << min_code_size;
    var bits: u32 = 0;
    var nbits: u5 = 0;
    var code_size: u5 = @as(u5, min_code_size) + 1;
    var next: u16 = clear + 2;
    var dict: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    defer dict.deinit(gpa);
    const Put = struct {
        fn put(o: *std.ArrayList(u8), g: std.mem.Allocator, b: *u32, nb: *u5, cs: u5, code: u16) !void {
            b.* |= @as(u32, code) << nb.*;
            nb.* += cs;
            while (nb.* >= 8) {
                try o.append(g, @truncate(b.*));
                b.* >>= 8;
                nb.* -= 8;
            }
        }
    };
    try Put.put(&out, gpa, &bits, &nbits, code_size, clear);
    if (pixels.len == 0) {
        try Put.put(&out, gpa, &bits, &nbits, code_size, clear + 1);
        if (nbits > 0) try out.append(gpa, @truncate(bits));
        return out.toOwnedSlice(gpa);
    }
    var cur: u16 = pixels[0];
    for (pixels[1..]) |p| {
        const key = @as(u32, cur) << 8 | p;
        if (dict.get(key)) |c| {
            cur = c;
            continue;
        }
        try Put.put(&out, gpa, &bits, &nbits, code_size, cur);
        if (next < max_codes) {
            try dict.put(gpa, key, next);
            next += 1;
            if (next > (@as(u32, 1) << code_size) and code_size < 12) code_size += 1;
        } else if (!defer_clear) {
            try Put.put(&out, gpa, &bits, &nbits, code_size, clear);
            dict.clearRetainingCapacity();
            next = clear + 2;
            code_size = @as(u5, min_code_size) + 1;
        }
        cur = p;
    }
    try Put.put(&out, gpa, &bits, &nbits, code_size, cur);
    if (next < max_codes and next + 1 > (@as(u32, 1) << code_size) and code_size < 12) code_size += 1;
    try Put.put(&out, gpa, &bits, &nbits, code_size, clear + 1);
    if (nbits > 0) try out.append(gpa, @truncate(bits));
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn roundTrip(min: u4, pixels: []const u8, defer_clear: bool) !void {
    const gpa = testing.allocator;
    const data = try encode(gpa, min, pixels, defer_clear);
    defer gpa.free(data);
    const out = try gpa.alloc(u8, pixels.len);
    defer gpa.free(out);
    var d: LzwDecoder = .init(min);
    // Small output buffers exercise strings split across calls.
    var n: usize = 0;
    while (n < out.len) {
        const k = try d.feed(data, out[n..@min(out.len, n + 7)]);
        if (k == 0) break;
        n += k;
        if (d.done) break;
    }
    try testing.expectEqualSlices(u8, pixels, out[0..n]);
}

test "lzw round trips" {
    try roundTrip(2, &.{ 0, 1, 2, 3, 0, 0, 0, 0, 1, 1, 1, 2 }, false);
    var big: [20000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (&big, 0..) |*b, i| b.* = if (i % 5 == 0) prng.random().int(u8) else @truncate(i / 64);
    try roundTrip(8, &big, false);
    try roundTrip(8, &big, true);
}

test "lzw rejects a code past the dictionary" {
    var d: LzwDecoder = .init(2);
    var out: [16]u8 = undefined;
    // clear (4), then 7 (> next = 6) in 3-bit codes.
    const data = [_]u8{ 0b00_111_100, 0 };
    try testing.expectError(error.Malformed, d.feed(&data, &out));
}
