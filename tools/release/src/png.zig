//! A deterministic PNG writer (PNG 3rd edition): 8-bit RGBA, no
//! interlace, Paeth filter on every row, one zlib stream at the best level
//! split into IDAT chunks, and no ancillary chunks.

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

pub const signature = "\x89PNG\r\n\x1a\n";
/// Largest IDAT chunk written.
pub const max_idat = 64 * 1024;

/// Writes `rgba` (straight alpha, `width * 4` bytes per row) as a PNG.
pub fn writeRgba(gpa: Allocator, w: *std.Io.Writer, width: u32, height: u32, rgba: []const u8) !void {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    try w.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(w, "IHDR", &ihdr);

    const stride = @as(usize, width) * 4;
    const filtered = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(filtered);
    for (0..height) |y| {
        const row = rgba[y * stride ..][0..stride];
        const out = filtered[y * (stride + 1) ..][0 .. stride + 1];
        out[0] = 4;
        for (row, 0..) |x, i| {
            const a: u8 = if (i >= 4) row[i - 4] else 0;
            const b: u8 = if (y > 0) rgba[(y - 1) * stride + i] else 0;
            const c: u8 = if (y > 0 and i >= 4) rgba[(y - 1) * stride + i - 4] else 0;
            out[1 + i] = x -% paeth(a, b, c);
        }
    }

    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, filtered.len / 2 + 64);
    defer aw.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var z: flate.Compress = try .init(&aw.writer, window, .zlib, .best);
    try z.writer.writeAll(filtered);
    try z.finish();
    var rest = aw.written();
    while (rest.len > 0) {
        const n = @min(rest.len, max_idat);
        try chunk(w, "IDAT", rest[0..n]);
        rest = rest[n..];
    }
    try chunk(w, "IEND", "");
}

/// The Paeth predictor.
pub fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn chunk(w: *std.Io.Writer, comptime kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

const testing = std.testing;

test "png: crc values" {
    // The IEND chunk's CRC is fixed by the spec.
    try testing.expectEqual(@as(u32, 0xAE426082), std.hash.Crc32.hash("IEND"));
    try testing.expectEqual(@as(u32, 0xCBF43926), std.hash.Crc32.hash("123456789"));
}

test "png: paeth predictor" {
    try testing.expectEqual(@as(u8, 10), paeth(10, 20, 20));
    try testing.expectEqual(@as(u8, 20), paeth(10, 20, 10));
    try testing.expectEqual(@as(u8, 7), paeth(5, 9, 7));
    try testing.expectEqual(@as(u8, 5), paeth(5, 9, 9));
}

test "png: decodes back to the same pixels" {
    const gpa = testing.allocator;
    var px: [5 * 3 * 4]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @truncate(i *% 37 +% 11);
    for (0..15) |i| px[i * 4 + 3] = 255; // opaque: the decoder premultiplies
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeRgba(gpa, &aw.writer, 5, 3, &px);
    const bytes = aw.written();
    try testing.expectEqualStrings(signature, bytes[0..8]);
    try testing.expectEqualStrings("IEND", bytes[bytes.len - 8 ..][0..4]);

    // Inflate the IDAT data and undo the filter.
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var at: usize = 8;
    while (at < bytes.len) {
        const n = std.mem.readInt(u32, bytes[at..][0..4], .big);
        if (std.mem.eql(u8, bytes[at + 4 ..][0..4], "IDAT")) try idat.appendSlice(gpa, bytes[at + 8 ..][0..n]);
        at += 12 + n;
    }
    var in: std.Io.Reader = .fixed(idat.items);
    var dbuf: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .zlib, &dbuf);
    const raw = try d.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);
    try testing.expectEqual(@as(usize, 3 * 21), raw.len);
    var out: [px.len]u8 = undefined;
    for (0..3) |y| {
        try testing.expectEqual(@as(u8, 4), raw[y * 21]);
        for (0..20) |i| {
            const a: u8 = if (i >= 4) out[y * 20 + i - 4] else 0;
            const b: u8 = if (y > 0) out[(y - 1) * 20 + i] else 0;
            const c: u8 = if (y > 0 and i >= 4) out[(y - 1) * 20 + i - 4] else 0;
            out[y * 20 + i] = raw[y * 21 + 1 + i] +% paeth(a, b, c);
        }
    }
    try testing.expectEqualSlices(u8, &px, &out);
}
