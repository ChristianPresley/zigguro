//! zlib helpers over `std.compress.flate`. The 0.16 decompressor reads the
//! zlib trailer but does not check it, so the adler32 is verified here.

const std = @import("std");
const flate = std.compress.flate;

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

/// Inflates a zlib stream that must produce exactly `out.len` bytes and
/// then end. No window buffer is needed: `out` is the history. On success
/// `input` is positioned just past the zlib trailer.
///
/// The decoder is always driven with an unlimited `stream` call: a limit
/// shorter than a pending match makes 0.16's decoder return 0 without
/// progress. Output past `out.len` fails in the fixed writer instead.
pub fn inflateExact(input: *std.Io.Reader, out: []u8) Error!void {
    var dec: flate.Decompress = .init(input, .zlib, &.{});
    var w: std.Io.Writer = .fixed(out);
    try drive(&dec, &w);
    if (w.end != out.len) return error.CorruptObject;
    try checkAdler(&dec, std.hash.Adler32.permute(1, out));
}

fn drive(dec: *flate.Decompress, w: *std.Io.Writer) Error!void {
    var stalls: u32 = 0;
    while (true) {
        const n = dec.reader.stream(w, .unlimited) catch |e| switch (e) {
            error.EndOfStream => return,
            error.WriteFailed => return error.CorruptObject,
            error.ReadFailed => return mapRead(e, dec),
        };
        if (n != 0) {
            stalls = 0;
        } else {
            stalls += 1;
            if (stalls > 64) return error.CorruptObject;
        }
    }
}

/// Inflates up to `out.len` bytes from the start of a zlib stream without
/// checking its end (for peeking at delta headers). The result can be a
/// little shorter than `out` when a match straddles its end.
pub fn inflatePrefix(input: *std.Io.Reader, out: []u8) Error![]u8 {
    var dec: flate.Decompress = .init(input, .zlib, &.{});
    var w: std.Io.Writer = .fixed(out);
    drive(&dec, &w) catch |e| switch (e) {
        error.CorruptObject => if (dec.err != null) return e,
        else => return e,
    };
    return w.buffered();
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
    var r1: std.Io.Reader = .fixed(z);
    try inflateExact(&r1, &out);
    try t.expectEqualStrings(payload, &out);
    try t.expectEqual(z.len, r1.seek);

    var short: [payload.len - 1]u8 = undefined;
    var r2: std.Io.Reader = .fixed(z);
    try t.expectError(error.CorruptObject, inflateExact(&r2, &short));
    var long: [payload.len + 1]u8 = undefined;
    var r3: std.Io.Reader = .fixed(z);
    try t.expectError(error.CorruptObject, inflateExact(&r3, &long));

    const bad = try t.allocator.dupe(u8, z);
    defer t.allocator.free(bad);
    bad[bad.len - 2] ^= 0x40;
    var r4: std.Io.Reader = .fixed(bad);
    try t.expectError(error.CorruptObject, inflateExact(&r4, &out));

    var r5: std.Io.Reader = .fixed(z);
    var pre: [64]u8 = undefined;
    const got = try inflatePrefix(&r5, &pre);
    try t.expect(got.len >= 3);
    try t.expectEqualStrings(payload[0..got.len], got);
}
