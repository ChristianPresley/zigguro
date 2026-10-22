//! zlib helpers. Slices inflate with zg_git's own decoder; streams still
//! go through `std.compress.flate`, whose 0.16 decompressor reads the zlib
//! trailer but does not check it, so the adler32 is verified here.

const std = @import("std");
const flate = std.compress.flate;
const inflate_mod = @import("zlib/inflate.zig");

/// The one-shot decoder behind `inflateExact` and `inflatePrefix`.
pub const inflate = inflate_mod;

/// Errors from inflating a zlib stream.
pub const Error = error{ CorruptObject, ReadFailed };

/// Maps a reader error of `dec` to `Error`.
pub fn mapRead(e: anyerror, dec: *const flate.Decompress) Error {
    return switch (e) {
        error.ReadFailed => if (dec.err != null) error.CorruptObject else error.ReadFailed,
        else => error.CorruptObject,
    };
}

/// Fails unless the stored zlib trailer matches `adler`.
pub fn checkAdler(dec: *const flate.Decompress, adler: u32) error{CorruptObject}!void {
    switch (dec.container_metadata) {
        .zlib => |z| if (z.adler != adler) return error.CorruptObject,
        else => unreachable,
    }
}

/// Inflates the zlib stream at the start of `input`, which must produce
/// exactly `out.len` bytes and then end with a valid trailer. Returns the
/// input bytes the stream took. Uses zg_git's own decoder
/// (`zlib/inflate.zig`).
pub fn inflateExact(input: []const u8, out: []u8) error{CorruptObject}!usize {
    return (try inflate_mod.zlibInflate(input, out, .exact)).consumed;
}

/// Inflates up to `out.len` bytes from the start of a zlib stream without
/// checking its end (for peeking at delta headers). The result is shorter
/// than `out` only when the stream is.
pub fn inflatePrefix(input: []const u8, out: []u8) error{CorruptObject}![]u8 {
    return out[0..(try inflate_mod.zlibInflate(input, out, .prefix)).written];
}

test "zlib: inflateExact checks length and trailer" {
    const t = std.testing;
    const payload = "abcabcabc" ** 300;
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    _ = try aw.writer.writableSliceGreedy(16);
    var window: [flate.max_window_len]u8 = undefined;
    var c: flate.Compress = try .init(&aw.writer, &window, .zlib, .default);
    try c.writer.writeAll(payload);
    try c.finish();
    const z = aw.written();

    var out: [payload.len]u8 = undefined;
    try t.expectEqual(z.len, try inflateExact(z, &out));
    try t.expectEqualStrings(payload, &out);

    var short: [payload.len - 1]u8 = undefined;
    try t.expectError(error.CorruptObject, inflateExact(z, &short));
    var long: [payload.len + 1]u8 = undefined;
    try t.expectError(error.CorruptObject, inflateExact(z, &long));

    const bad = try t.allocator.dupe(u8, z);
    defer t.allocator.free(bad);
    bad[bad.len - 2] ^= 0x40;
    try t.expectError(error.CorruptObject, inflateExact(bad, &out));

    var pre: [64]u8 = undefined;
    const got = try inflatePrefix(z, &pre);
    try t.expectEqual(@as(usize, 64), got.len);
    try t.expectEqualStrings(payload[0..got.len], got);
}

test {
    _ = inflate_mod;
}
