//! Bitmap-strike tests: the Noto Color Emoji CBDT subset against RGBA
//! goldens from `testdata/provenance/gen_strike_golden.py`, crafted CBLC
//! index formats 1–5 and image formats 17–19, crafted sbix with `dupe`
//! chains, resampling and the decoded-image cache.

const std = @import("std");
const testing = std.testing;
const cbdt = @import("../ot/cbdt.zig");
const sbix = @import("../ot/sbix.zig");
const bs = @import("bitmap_strikes.zig");
const rz = @import("rasterizer.zig");
const Rasterizer = rz.Rasterizer;
const Face = @import("../ot/face.zig").Face;
const variation = @import("../ot/var/root.zig");
const fonts = @import("../testing/fonts.zig");

/// A 2×2 RGBA PNG: red, green / blue, white at alpha 128.
const tiny_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
    0x24, 0x00, 0x00, 0x00, 0x13, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x0c, 0x81, 0x34, 0x08, 0x34, 0x00, 0x00, 0x49, 0x49, 0x09, 0x78, 0x28, 0xa0, 0xdb, 0x77,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

const Golden = struct {
    glyphs: []const struct { cp: u21, px: f32, left: i16, top: i16, width: u16, height: u16, rgba: []const u8 },
};

test "cbdt noto subset glyph" {
    const gpa = testing.allocator;
    const data = try fonts.font(gpa, "NotoColorEmoji-CBDT-Subset.ttf");
    defer gpa.free(data);
    const face = try Face.init(data, 0);
    const gid = face.glyphIndex(0x1F600);
    try testing.expectEqual(@as(u16, 5), gid);
    const g = cbdt.cbdtGlyph(&face, gid, 20).?;
    try testing.expectEqual(@as(u16, 109), g.ppem);
    try testing.expectEqual(@as(f32, 0), g.origin_x);
    try testing.expectEqual(@as(f32, 101), g.origin_y);
    try testing.expectEqual(@as(?f32, 136), g.advance_px);
    try testing.expectEqual([2]u32{ 136, 128 }, cbdt.pngSize(g.png).?);
    // Larger than every strike: the largest is used.
    try testing.expectEqual(@as(u16, 109), cbdt.cbdtGlyph(&face, gid, 300).?.ppem);
    try testing.expect(cbdt.cbdtGlyph(&face, 0, 20) == null);
}

test "rgba goldens at 20 and 32 px" {
    const gpa = testing.allocator;
    const data = try fonts.font(gpa, "NotoColorEmoji-CBDT-Subset.ttf");
    defer gpa.free(data);
    const face = try Face.init(data, 0);
    var inst = try variation.FaceInstance.init(gpa, &face, &.{});
    defer inst.deinit(gpa);
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    for ([_][]const u8{ "golden/strike/NotoColorEmoji-CBDT-20px.zon", "golden/strike/NotoColorEmoji-CBDT-32px.zon" }) |file| {
        const src = try fonts.readTestdataZ(gpa, file);
        defer gpa.free(src);
        const gold = try std.zon.parse.fromSliceAlloc(Golden, gpa, src, null, .{});
        defer std.zon.parse.free(gpa, gold);
        try testing.expectEqual(@as(usize, 5), gold.glyphs.len);
        for (gold.glyphs) |want| {
            const bm = try r.rasterizeGlyph(&inst, face.glyphIndex(want.cp), .{ .px_per_em = want.px, .color = true });
            try testing.expectEqual(rz.Bitmap.Format.rgba8_premul, bm.format);
            try testing.expectEqual(want.left, bm.left);
            try testing.expectEqual(want.top, bm.top);
            try testing.expectEqual(want.width, bm.width);
            try testing.expectEqual(want.height, bm.height);
            const px = try gpa.alloc(u8, want.rgba.len / 2);
            defer gpa.free(px);
            _ = try std.fmt.hexToBytes(px, want.rgba);
            for (0..bm.height) |y| {
                const row = bm.row(y);
                for (row, px[y * @as(usize, bm.width) * 4 ..][0..row.len]) |got, exp| {
                    if (@abs(@as(i16, got) - exp) > 2) {
                        std.debug.print("U+{X} {d}px row {d}: got {d} want {d}\n", .{ want.cp, want.px, y, got, exp });
                        return error.TestExpectedEqual;
                    }
                }
            }
        }
    }
}

test "corrupt strike PNG falls back" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    var bad = tiny_png;
    bad[20] ^= 0xff; // breaks the IHDR CRC
    try testing.expectError(error.Malformed, bs.renderStrike(&r, .{ .png = &bad, .origin_x = 0, .origin_y = 2, .ppem = 2 }, 4, &r.strikes));
}

test "downscale preserves average color" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    // 2×2 strike drawn at the same size: exactly the source pixels.
    const same = try bs.renderStrike(&r, .{ .png = &tiny_png, .origin_x = 0, .origin_y = 2, .ppem = 2 }, 2, &r.strikes);
    try testing.expectEqual(@as(u16, 2), same.width);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, same.row(0));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 128, 128, 128, 128 }, same.row(1));
    // Down to one pixel: the linear-light average, premultiplied.
    const one = try bs.renderStrike(&r, .{ .png = &tiny_png, .origin_x = 0, .origin_y = 2, .ppem = 2 }, 1, &r.strikes);
    try testing.expectEqual(@as(u16, 1), one.width);
    const a = (3.0 + 128.0 / 255.0) / 4.0;
    const lin = (1.0 + 128.0 / 255.0) / 4.0; // each channel: one opaque primary + white at alpha 0.5
    const srgb = if (lin / a <= 0.0031308) lin / a * 12.92 else 1.055 * std.math.pow(f64, lin / a, 1.0 / 2.4) - 0.055;
    const want: u8 = @intFromFloat(srgb * a * 255 + 0.5);
    for (one.pixels[0..3]) |v| try testing.expect(@abs(@as(i16, v) - want) <= 1);
    try testing.expectEqual(@as(u8, @intFromFloat(a * 255 + 0.5)), one.pixels[3]);
}

test "strike cache evicts least recently used" {
    const gpa = testing.allocator;
    var c: bs.StrikeCache = .{ .budget_bytes = 80 };
    defer c.deinit(gpa);
    const copies = [3][tiny_png.len]u8{ tiny_png, tiny_png, tiny_png };
    _ = try c.get(gpa, &copies[0]); // 32 bytes each (16-bit RGBA)
    _ = try c.get(gpa, &copies[1]);
    _ = try c.get(gpa, &copies[0]); // 0 is now newer than 1
    _ = try c.get(gpa, &copies[2]); // over budget: evicts 1
    try testing.expectEqual(@as(usize, 2), c.entries.items.len);
    for (c.entries.items) |e| try testing.expect(e.key != @intFromPtr(&copies[1]));
    try testing.expectEqual(@as(usize, 64), c.bytes);
}

fn put16(l: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try l.appendSlice(testing.allocator, &b);
}

fn put32(l: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try l.appendSlice(testing.allocator, &b);
}

const big_metrics = [8]u8{ 2, 2, 1, 2, 3, 0, 0, 0 }; // h, w, bx, by, adv, vert…

/// CBLC/CBDT with one 20 ppem strike over glyphs 1..3 using index format
/// `ifmt` and image format `imgfmt`. Sparse formats (4, 5) hold glyphs 1
/// and 3 only.
fn buildCbdt(ifmt: u16, imgfmt: u16) ![2][]u8 {
    const gpa = testing.allocator;
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    switch (imgfmt) {
        17 => try rec.appendSlice(gpa, big_metrics[0..5]),
        18 => try rec.appendSlice(gpa, &big_metrics),
        else => {},
    }
    try put32(&rec, tiny_png.len);
    try rec.appendSlice(gpa, &tiny_png);
    const size: u32 = @intCast(rec.items.len);
    const sparse = ifmt == 4 or ifmt == 5;
    const n_img: u32 = if (sparse) 2 else 3;
    var d: std.ArrayList(u8) = .empty;
    errdefer d.deinit(gpa);
    try put32(&d, 0x00030000);
    for (0..n_img) |_| try d.appendSlice(gpa, rec.items);

    var l: std.ArrayList(u8) = .empty;
    errdefer l.deinit(gpa);
    try put16(&l, 3);
    try put16(&l, 0);
    try put32(&l, 1);
    try put32(&l, 56); // indexSubTableArrayOffset
    try put32(&l, 0);
    try put32(&l, 1); // one index subtable
    try put32(&l, 0);
    try l.appendNTimes(gpa, 0, 24); // line metrics
    try put16(&l, 1);
    try put16(&l, 3);
    try l.appendSlice(gpa, &.{ 20, 20, 32, 1 });
    try put16(&l, 1); // array entry: glyphs 1..3
    try put16(&l, 3);
    try put32(&l, 8);
    try put16(&l, ifmt);
    try put16(&l, imgfmt);
    try put32(&l, 4);
    switch (ifmt) {
        1 => for (0..4) |k| try put32(&l, @intCast(k * size)),
        3 => for (0..4) |k| try put16(&l, @intCast(k * size)),
        2 => {
            try put32(&l, size);
            try l.appendSlice(gpa, &big_metrics);
        },
        4 => {
            try put32(&l, 2);
            for ([_]u16{ 1, 3, 0 }, 0..) |g, k| {
                try put16(&l, g);
                try put16(&l, @intCast(k * size));
            }
        },
        5 => {
            try put32(&l, size);
            try l.appendSlice(gpa, &big_metrics);
            try put32(&l, 2);
            try put16(&l, 1);
            try put16(&l, 3);
        },
        else => unreachable,
    }
    return .{ try l.toOwnedSlice(gpa), try d.toOwnedSlice(gpa) };
}

test "cblc index formats 1-5 and image formats 17-19" {
    const gpa = testing.allocator;
    const combos = [_][2]u16{ .{ 1, 17 }, .{ 1, 18 }, .{ 3, 17 }, .{ 4, 18 }, .{ 2, 19 }, .{ 5, 19 }, .{ 2, 17 }, .{ 5, 18 } };
    for (combos) |cb| {
        const t = try buildCbdt(cb[0], cb[1]);
        defer for (t) |b| gpa.free(b);
        const c = try cbdt.Cbdt.init(t[0], t[1]);
        for ([_]u16{ 1, 2, 3 }) |gid| {
            const g = c.glyph(gid, 16);
            const sparse = cb[0] == 4 or cb[0] == 5;
            if (gid == 2 and sparse) {
                try testing.expect(g == null);
                continue;
            }
            const got = g orelse return error.TestUnexpectedResult;
            try testing.expectEqualSlices(u8, &tiny_png, got.png);
            try testing.expectEqual(@as(f32, 1), got.origin_x);
            try testing.expectEqual(@as(f32, 2), got.origin_y);
            try testing.expectEqual(@as(u16, 20), got.ppem);
        }
        try testing.expect(c.glyph(4, 16) == null);
    }
}

/// sbix with one 20 ppem strike over 5 glyphs: 0 empty, 1 PNG at (1, -1),
/// 2 dupe → 1, 3 dupe → 3 (a cycle), 4 JPEG.
fn buildSbix() ![]u8 {
    const gpa = testing.allocator;
    var recs: [5]std.ArrayList(u8) = @splat(.empty);
    defer for (&recs) |*r| r.deinit(gpa);
    try put16(&recs[1], 1);
    try put16(&recs[1], @bitCast(@as(i16, -1)));
    try recs[1].appendSlice(gpa, "png ");
    try recs[1].appendSlice(gpa, &tiny_png);
    for ([_]u16{ 1, 3 }, 2..) |target, k| {
        try put32(&recs[k], 0);
        try recs[k].appendSlice(gpa, "dupe");
        try put16(&recs[k], target);
    }
    try put32(&recs[4], 0);
    try recs[4].appendSlice(gpa, "jpg ");
    try recs[4].appendSlice(gpa, "\xff\xd8");
    var t: std.ArrayList(u8) = .empty;
    errdefer t.deinit(gpa);
    try put16(&t, 1);
    try put16(&t, 1);
    try put32(&t, 1);
    try put32(&t, 12);
    try put16(&t, 20);
    try put16(&t, 72);
    var off: u32 = 4 + 6 * 4;
    try put32(&t, off);
    for (recs) |r| {
        off += @intCast(r.items.len);
        try put32(&t, off);
    }
    for (recs) |r| try t.appendSlice(gpa, r.items);
    return t.toOwnedSlice(gpa);
}

test "sbix dupe chain" {
    const gpa = testing.allocator;
    const t = try buildSbix();
    defer gpa.free(t);
    const s = try sbix.Sbix.init(t, 5);
    try testing.expect(s.glyph(0, 20, null) == null);
    const g1 = s.glyph(1, 20, null).?;
    try testing.expectEqual(@as(f32, 1), g1.origin_x);
    try testing.expectEqual(@as(f32, 1), g1.origin_y); // -1 + image height 2
    try testing.expectEqualSlices(u8, &tiny_png, g1.png);
    const g2 = s.glyph(2, 20, null).?;
    try testing.expectEqual(g1.png.ptr, g2.png.ptr);
    try testing.expect(s.glyph(3, 20, null) == null); // cycle stops after 4 hops
    try testing.expect(s.glyph(4, 20, null) == null); // JPEG unsupported
    try testing.expect(s.glyph(5, 20, null) == null);
    // With glyf bounds, the image moves to (xMin, yMin).
    const g = s.glyph(1, 20, .{ 0.5, -0.25 }).?;
    try testing.expectEqual(@as(f32, 11), g.origin_x);
    try testing.expectEqual(@as(f32, -4), g.origin_y);
}

test "fuzz: cbdt-sbix" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try fuzzStrikes(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "cbdt-sbix") });
}

/// Input: byte 0 = split point (as a fraction of the rest) between CBLC
/// and CBDT; the whole rest is also read as an sbix table with 8 glyphs.
/// Every lookup must return null or a PNG slice inside the input, and
/// rendering a found image must fail cleanly or succeed.
fn fuzzStrikes(input: []const u8) !void {
    if (input.len < 2) return;
    const rest = input[1..];
    const k = rest.len * input[0] / 256;
    var r: Rasterizer = .init(testing.allocator);
    defer r.deinit();
    const in_range = struct {
        fn f(outer: []const u8, inner: []const u8) bool {
            const lo = @intFromPtr(outer.ptr);
            const p = @intFromPtr(inner.ptr);
            return p >= lo and p + inner.len <= lo + outer.len;
        }
    }.f;
    if (cbdt.Cbdt.init(rest[0..k], rest[k..])) |c| {
        for (0..8) |gid| for ([_]f32{ 8, 20, 300 }) |ppem| {
            if (c.glyph(@intCast(gid), ppem)) |g| {
                try testing.expect(in_range(rest, g.png));
                _ = bs.renderStrike(&r, g, 20, &r.strikes) catch {};
            }
        };
    } else |_| {}
    if (sbix.Sbix.init(rest, 8)) |sb| {
        for (0..9) |gid| if (sb.glyph(@intCast(gid), 20, null)) |g| {
            try testing.expect(in_range(rest, g.png));
            _ = bs.renderStrike(&r, g, 20, &r.strikes) catch {};
        };
    } else |_| {}
}
