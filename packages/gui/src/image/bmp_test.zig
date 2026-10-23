//! BMP decoding against files built by a small writer here.

const std = @import("std");
const bmp = @import("bmp.zig");
const image = @import("image.zig");
const decode = @import("decode.zig");

const testing = std.testing;
const gpa = testing.allocator;

const Spec = struct {
    w: u32,
    h: u32,
    bpp: u16,
    header: u32 = 40,
    compression: u32 = 0,
    /// R, G, B, A masks written for bitfields (and the V3+ alpha mask).
    masks: [4]u32 = .{ 0, 0, 0, 0 },
    palette: []const [3]u8 = &.{},
    top_down: bool = false,
    /// One raw pixel value per pixel, top row first: a palette index, or
    /// the packed 16/24/32-bit value.
    values: []const u32,
};

fn write(s: Spec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const masks_after = s.header == 40 and s.compression == 3;
    const pal_len = s.palette.len * 4;
    const data_at: u32 = 14 + s.header + @as(u32, if (masks_after) 12 else 0) + @as(u32, @intCast(pal_len));
    const row_bytes = (s.w * s.bpp + 31) / 32 * 4;
    try out.appendSlice(gpa, "BM");
    try put32(&out, data_at + row_bytes * s.h);
    try put32(&out, 0);
    try put32(&out, data_at);
    // Header.
    const hdr_at = out.items.len;
    try out.appendNTimes(gpa, 0, s.header);
    const h = out.items[hdr_at..];
    std.mem.writeInt(u32, h[0..4], s.header, .little);
    std.mem.writeInt(i32, h[4..8], @intCast(s.w), .little);
    std.mem.writeInt(i32, h[8..12], if (s.top_down) -@as(i32, @intCast(s.h)) else @intCast(s.h), .little);
    std.mem.writeInt(u16, h[12..14], 1, .little);
    std.mem.writeInt(u16, h[14..16], s.bpp, .little);
    std.mem.writeInt(u32, h[16..20], s.compression, .little);
    std.mem.writeInt(u32, h[32..36], @intCast(s.palette.len), .little);
    if (s.header >= 52) for (0..3) |i| std.mem.writeInt(u32, h[40 + i * 4 ..][0..4], s.masks[i], .little);
    if (s.header >= 56) std.mem.writeInt(u32, h[52..56], s.masks[3], .little);
    if (masks_after) for (0..3) |i| try put32(&out, s.masks[i]);
    for (s.palette) |c| try out.appendSlice(gpa, &.{ c[2], c[1], c[0], 0 });
    // Rows, bottom-up unless top-down.
    for (0..s.h) |k| {
        const y = if (s.top_down) k else s.h - 1 - k;
        var row = try gpa.alloc(u8, row_bytes);
        defer gpa.free(row);
        @memset(row, 0);
        for (0..s.w) |x| {
            const v = s.values[y * s.w + x];
            switch (s.bpp) {
                1, 4, 8 => {
                    const bit = x * s.bpp;
                    row[bit / 8] |= @intCast(v << @intCast(8 - s.bpp - bit % 8));
                },
                16 => std.mem.writeInt(u16, row[x * 2 ..][0..2], @intCast(v), .little),
                24 => {
                    row[x * 3] = @truncate(v);
                    row[x * 3 + 1] = @truncate(v >> 8);
                    row[x * 3 + 2] = @truncate(v >> 16);
                },
                32 => std.mem.writeInt(u32, row[x * 4 ..][0..4], v, .little),
                else => unreachable,
            }
        }
        try out.appendSlice(gpa, row);
    }
    return out.toOwnedSlice(gpa);
}

fn put32(out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn expectPixels(s: Spec, want: []const [4]u8) !void {
    const file = try write(s);
    defer gpa.free(file);
    var img = try decode.decode(gpa, file, .{});
    defer img.deinit(gpa);
    try testing.expectEqual(image.Format.bmp, img.format);
    try testing.expectEqual(s.w, img.w);
    try testing.expectEqual(s.h, img.h);
    for (want, 0..) |p, i| try testing.expectEqual(p, img.rgba[i * 4 ..][0..4].*);
}

const pal = [_][3]u8{ .{ 0, 0, 0 }, .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 } };

test "bmp: 1, 4 and 8 bpp palettes" {
    const values = [_]u32{ 1, 0, 1, 1, 0, 1, 0, 0, 1 };
    try expectPixels(.{ .w = 9, .h = 1, .bpp = 1, .palette = pal[0..2], .values = &values }, &.{ .{ 255, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 255, 0, 0, 255 } });
    try expectPixels(.{ .w = 3, .h = 2, .bpp = 4, .palette = &pal, .values = &.{ 0, 1, 2, 3, 2, 1 } }, &.{ .{ 0, 0, 0, 255 }, .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 255 }, .{ 255, 0, 0, 255 } });
    try expectPixels(.{ .w = 2, .h = 2, .bpp = 8, .palette = &pal, .values = &.{ 3, 2, 1, 0 } }, &.{ .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 255 }, .{ 255, 0, 0, 255 }, .{ 0, 0, 0, 255 } });
}

test "bmp: 16 bpp 5-5-5 and bitfields 5-6-5" {
    try expectPixels(.{ .w = 2, .h = 1, .bpp = 16, .values = &.{ 0x7C00, 0x001F } }, &.{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 255 } });
    try expectPixels(.{ .w = 2, .h = 1, .bpp = 16, .compression = 3, .masks = .{ 0xF800, 0x07E0, 0x001F, 0 }, .values = &.{ 0x07E0, 0xF800 } }, &.{ .{ 0, 255, 0, 255 }, .{ 255, 0, 0, 255 } });
}

test "bmp: 24 and 32 bpp, top-down" {
    try expectPixels(.{ .w = 2, .h = 2, .bpp = 24, .values = &.{ 0xFF0000, 0x00FF00, 0x0000FF, 0x102030 } }, &.{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 0x10, 0x20, 0x30, 255 } });
    try expectPixels(.{ .w = 2, .h = 2, .bpp = 24, .top_down = true, .values = &.{ 0xFF0000, 0x00FF00, 0x0000FF, 0x102030 } }, &.{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 0x10, 0x20, 0x30, 255 } });
    // BI_RGB 32 bpp with an INFO header ignores the X byte: opaque.
    try expectPixels(.{ .w = 1, .h = 1, .bpp = 32, .values = &.{0x00FF8040} }, &.{.{ 0xFF, 0x80, 0x40, 255 }});
}

test "bmp: v5 alpha mask premultiplies" {
    try expectPixels(.{ .w = 2, .h = 1, .bpp = 32, .header = 124, .compression = 3, .masks = .{ 0xFF0000, 0xFF00, 0xFF, 0xFF000000 }, .values = &.{ 0x80FF0000, 0x00FFFFFF } }, &.{ .{ 128, 0, 0, 128 }, .{ 0, 0, 0, 0 } });
}

test "bmp: rle is unsupported, limits are checked first, truncation is malformed" {
    const rle = try write(.{ .w = 1, .h = 1, .bpp = 8, .compression = 1, .palette = &pal, .values = &.{0} });
    defer gpa.free(rle);
    try testing.expectError(error.Unsupported, bmp.decodeBmp(gpa, rle, .{}));
    const big = try write(.{ .w = 1, .h = 1, .bpp = 24, .values = &.{0} });
    defer gpa.free(big);
    std.mem.writeInt(i32, big[18..22], 100_000, .little);
    std.mem.writeInt(i32, big[22..26], 100_000, .little);
    try testing.expectError(error.TooLarge, bmp.decodeBmp(gpa, big, .{}));
    const ok = try write(.{ .w = 4, .h = 4, .bpp = 24, .values = &([_]u32{0} ** 16) });
    defer gpa.free(ok);
    try testing.expectError(error.Malformed, bmp.decodeBmp(gpa, ok[0 .. ok.len - 1], .{}));
}

test "fuzz: image-bmp" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            if (bmp.decodeBmp(testing.allocator, input, .{ .max_pixels = 1 << 16 })) |img| {
                var m = img;
                try testing.expectEqual(@as(usize, m.w) * m.h * 4, m.rgba.len);
                m.deinit(testing.allocator);
            } else |_| {}
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "image-bmp") });
}
