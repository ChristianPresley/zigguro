//! LCD subpixel rendering: coverage rasterized at 3× horizontal resolution
//! is run through FreeType's default 5-tap FIR filter (weights summing to
//! 256) across subpixels, then packed into one byte per colour channel.
//! The filter spreads each subpixel over its neighbours, which keeps colour
//! fringes down and conserves total coverage.

const std = @import("std");

/// Physical subpixel order of a horizontal-stripe panel.
pub const LcdOrder = enum { rgb, bgr };

/// The `text.lcd` setting.
pub const LcdSetting = enum { auto, on, off };

/// FreeType's `FT_LCD_FILTER_DEFAULT` weights.
pub const lcd_filter_default = [5]u8{ 0x08, 0x4D, 0x56, 0x4D, 0x08 };

/// Subpixels of padding the rasterizer adds on each side of a 3× bitmap,
/// the filter's reach.
pub const pad_subpixels = 2;

/// Filters the 3× coverage `src3x` (`w3` subpixels wide, a multiple of 3,
/// `h` rows) into `dst`, 3 bytes per pixel in display order. Subpixels
/// outside the row count as 0.
pub fn filter(src3x: []const u8, w3: u32, h: u32, src_stride: u32, order: LcdOrder, dst: []u8, dst_stride: u32) void {
    std.debug.assert(w3 % 3 == 0);
    const wt = lcd_filter_default;
    for (0..h) |y| {
        const s = src3x[y * src_stride ..][0..w3];
        const d = dst[y * dst_stride ..][0..w3];
        for (0..w3) |i| {
            var acc: u32 = 128;
            inline for (0..5) |k| {
                const j = @as(isize, @intCast(i)) + @as(isize, k) - 2;
                if (j >= 0 and j < w3) acc += @as(u32, wt[k]) * s[@intCast(j)];
            }
            d[i] = @intCast(@min(acc >> 8, 255));
        }
        if (order == .bgr) {
            var x: usize = 0;
            while (x < w3) : (x += 3) std.mem.swap(u8, &d[x], &d[x + 2]);
        }
    }
}

/// Whether text should use LCD output: the setting allows it, the subpixel
/// order is known, the background is opaque, the text is not transformed,
/// and (for `auto`) the display scale is below 1.5. `on` skips only the
/// scale check, because the other conditions make LCD output wrong.
pub fn shouldUseLcd(scale: f32, order: ?LcdOrder, opaque_bg: bool, transformed: bool, setting: LcdSetting) bool {
    return switch (setting) {
        .off => false,
        .on => order != null and opaque_bg and !transformed,
        .auto => order != null and opaque_bg and !transformed and scale < 1.5,
    };
}

const testing = std.testing;

test "lcd filter normalization" {
    // A solid run stays 255 in every channel away from the edges.
    var src: [30]u8 = @splat(255);
    var dst: [30]u8 = undefined;
    filter(&src, 30, 1, 30, .rgb, &dst, 30);
    for (dst[2..28]) |v| try testing.expectEqual(@as(u8, 255), v);
    var sum: u32 = 0;
    for (lcd_filter_default) |w| sum += w;
    try testing.expectEqual(@as(u32, 256), sum);
}

test "bgr swaps channels" {
    var src = [_]u8{ 0, 0, 0, 0, 0, 255, 0, 0, 0 };
    var rgb: [9]u8 = undefined;
    var bgr: [9]u8 = undefined;
    filter(&src, 9, 1, 9, .rgb, &rgb, 9);
    filter(&src, 9, 1, 9, .bgr, &bgr, 9);
    for (0..3) |p| {
        try testing.expectEqual(rgb[3 * p], bgr[3 * p + 2]);
        try testing.expectEqual(rgb[3 * p + 1], bgr[3 * p + 1]);
        try testing.expectEqual(rgb[3 * p + 2], bgr[3 * p]);
    }
    try testing.expectEqual(@as(u8, 86), rgb[5]);
}

test "shouldUseLcd truth table" {
    for ([_]LcdSetting{ .auto, .on, .off }) |s| for ([_]f32{ 1, 1.25, 2 }) |scale| for ([_]?LcdOrder{ null, .rgb, .bgr }) |o|
        for ([_]bool{ false, true }) |opq| for ([_]bool{ false, true }) |tr| {
            const want = s != .off and o != null and opq and !tr and (s == .on or scale < 1.5);
            try testing.expectEqual(want, shouldUseLcd(scale, o, opq, tr, s));
        };
}
