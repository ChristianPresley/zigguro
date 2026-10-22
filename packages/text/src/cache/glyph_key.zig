//! `GlyphKey`: everything that changes a glyph's pixels, packed into one
//! never-zero `u64` so the glyph cache can use 0 as its empty slot.

const std = @import("std");
const rasterizer = @import("../raster/rasterizer.zig");
const RasterParams = rasterizer.RasterParams;

/// How a glyph is rendered.
pub const RenderMode = enum(u3) {
    /// Grayscale coverage.
    gray,
    /// LCD subpixel coverage, RGB stripe order.
    lcd_rgb,
    /// LCD subpixel coverage, BGR stripe order.
    lcd_bgr,
    /// Signed distance field (large sizes, zoom).
    sdf,
    /// Colour glyph (COLR, bitmap strikes) that does not use the text colour.
    color,
    /// Colour glyph whose paint uses the text colour; `fg_bucket` keys it.
    color_fg,
};

/// Largest `size_q`: 2047.75 px.
pub const max_size_q: u13 = std.math.maxInt(u13);

/// Above this size (in px) outlines are cached as SDF instead of coverage.
pub const sdf_threshold_px: f32 = 256;

/// A glyph of a font instance at a size, subpixel bin and render mode.
/// Field order is the bit order from the least significant bit.
pub const GlyphKey = packed struct(u64) {
    /// FontRegistry instance id (face, variation coordinates, synthetic
    /// styles).
    instance: u18,
    glyph: u16,
    /// Pixels per em × 4 (0.25 px steps).
    size_q: u13,
    /// Horizontal subpixel bin 0..3 (quarter pixels); 0 on a monospace
    /// grid.
    subpx: u2 = 0,
    mode: RenderMode = .gray,
    /// `color_fg` only: a quantized hash of the text colour; else 0.
    fg_bucket: u8 = 0,
    /// Never-zero marker, so 0 can mean "empty slot".
    valid: u4 = 0xA,

    /// The key as its packed bits (never 0).
    pub inline fn bits(k: GlyphKey) u64 {
        return @bitCast(k);
    }

    /// The key stored as `b`; asserts it came from `bits`.
    pub inline fn fromBits(b: u64) GlyphKey {
        const k: GlyphKey = @bitCast(b);
        std.debug.assert(k.valid == 0xA);
        return k;
    }

    /// The size in pixels per em.
    pub fn pxPerEm(k: GlyphKey) f32 {
        return @as(f32, @floatFromInt(k.size_q)) / 4;
    }

    /// True for the cheap kinds a frame may rasterize synchronously:
    /// coverage (gray/LCD) at up to 48 px.
    pub fn isCheap(k: GlyphKey) bool {
        return switch (k.mode) {
            .gray, .lcd_rgb, .lcd_bgr => k.size_q <= 48 * 4,
            .sdf, .color, .color_fg => false,
        };
    }
};

/// `px` quantized to quarter pixels, clamped to `max_size_q` (0 for
/// non-finite or non-positive sizes).
pub fn quantizeSize(px: f32) u13 {
    if (!(px > 0)) return 0;
    const q = @round(px * 4);
    if (!(q < @as(f32, max_size_q))) return max_size_q;
    return @intFromFloat(q);
}

/// The subpixel bin (0..3) of a pen x position.
pub fn subpixelBin(pen_x: f32) u2 {
    const frac = pen_x - @floor(pen_x);
    if (!std.math.isFinite(frac)) return 0;
    const b: u32 = @intFromFloat(@floor(frac * 4 + 0.5));
    return @intCast(b & 3);
}

/// The key's mode for a requested `mode` at `px`: coverage modes become
/// `sdf` above `sdf_threshold_px`.
pub fn modeForSize(mode: RenderMode, px: f32) RenderMode {
    return switch (mode) {
        .gray, .lcd_rgb, .lcd_bgr => if (px > sdf_threshold_px) .sdf else mode,
        else => mode,
    };
}

/// A quantized bucket of a text colour (straight sRGB bytes) for
/// `color_fg` keys: 2 bits per channel with alpha folded into the top
/// bits, never 0 so it differs from "no foreground".
pub fn fgBucket(rgba: [4]u8) u8 {
    const r: u8 = rgba[0] >> 6;
    const g: u8 = rgba[1] >> 6;
    const b: u8 = rgba[2] >> 6;
    const a: u8 = rgba[3] >> 6;
    const v = r | g << 2 | b << 4 | a << 6;
    return if (v == 0) 1 else v;
}

/// Synthetic styles and colour inputs that come with an instance, not the
/// key.
pub const Style = struct {
    synth_bold: bool = false,
    synth_oblique: bool = false,
    stem_darkening: bool = false,
    /// COLR palette and dark-background preference.
    palette: u16 = 0,
    dark_bg: bool = false,
    /// Text colour for `color_fg` glyphs (linear premultiplied RGBA).
    fg: [4]f32 = .{ 0, 0, 0, 1 },
};

/// The raster parameters that produce `k`'s bitmap.
pub fn rasterParams(k: GlyphKey, s: Style) RasterParams {
    const color = k.mode == .color or k.mode == .color_fg;
    return .{
        .px_per_em = k.pxPerEm(),
        .subpixel_x = @as(f32, @floatFromInt(k.subpx)) * 0.25,
        .mode = switch (k.mode) {
            .gray, .color, .color_fg => .gray,
            .lcd_rgb => .lcd_rgb,
            .lcd_bgr => .lcd_bgr,
            .sdf => .sdf,
        },
        .synth_bold = s.synth_bold,
        .synth_oblique = s.synth_oblique,
        .stem_darkening = s.stem_darkening,
        .color = color,
        .palette = s.palette,
        .fg = s.fg,
        .dark_bg = s.dark_bg,
    };
}

test "glyph key: packing roundtrip" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    for (0..10_000) |_| {
        const k: GlyphKey = .{
            .instance = rnd.int(u18),
            .glyph = rnd.int(u16),
            .size_q = rnd.int(u13),
            .subpx = rnd.int(u2),
            .mode = rnd.enumValue(RenderMode),
            .fg_bucket = rnd.int(u8),
        };
        const back = GlyphKey.fromBits(k.bits());
        try std.testing.expectEqual(k, back);
    }
}

test "glyph key: never zero" {
    const zero: GlyphKey = .{ .instance = 0, .glyph = 0, .size_q = 0 };
    try std.testing.expect(zero.bits() != 0);
    try std.testing.expectEqual(@as(u64, 0xA) << 60, zero.bits());
}

test "glyph key: helpers" {
    try std.testing.expectEqual(@as(u13, 56), quantizeSize(14));
    try std.testing.expectEqual(@as(u13, 57), quantizeSize(14.2));
    try std.testing.expectEqual(max_size_q, quantizeSize(1e9));
    try std.testing.expectEqual(@as(u13, 0), quantizeSize(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u2, 0), subpixelBin(10.0));
    try std.testing.expectEqual(@as(u2, 1), subpixelBin(10.26));
    try std.testing.expectEqual(@as(u2, 2), subpixelBin(-0.5));
    try std.testing.expectEqual(@as(u2, 0), subpixelBin(3.9));
    try std.testing.expectEqual(RenderMode.sdf, modeForSize(.gray, 300));
    try std.testing.expectEqual(RenderMode.color, modeForSize(.color, 300));
    try std.testing.expect(fgBucket(.{ 0, 0, 0, 0 }) != 0);
    const k: GlyphKey = .{ .instance = 1, .glyph = 2, .size_q = quantizeSize(14), .subpx = 2, .mode = .lcd_bgr };
    try std.testing.expect(k.isCheap());
    const p = rasterParams(k, .{ .synth_bold = true });
    try std.testing.expectEqual(@as(f32, 14), p.px_per_em);
    try std.testing.expectEqual(@as(f32, 0.5), p.subpixel_x);
    try std.testing.expectEqual(RasterParams.Mode.lcd_bgr, p.mode);
    try std.testing.expect(p.synth_bold and !p.color);
}
