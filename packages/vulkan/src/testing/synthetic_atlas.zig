//! Procedural glyph atlases and images for the scene corpus. The corpus
//! must not depend on fonts or E03, so glyphs are generated shapes (boxes,
//! rings, strokes, fractional coverage ramps) in 16×16 cells.

const std = @import("std");
const r2d = @import("../r2d/root.zig");

/// Cell edge in texels.
pub const cell = 16;
/// Cells per page row.
pub const cells_per_row = 8;
/// Page edge in texels.
pub const page_size = cell * cells_per_row;
/// Number of glyph shapes.
pub const glyph_count = cells_per_row * cells_per_row;

/// Coverage (0..255) of shape `g` at texel (x, y) of its cell.
pub fn coverage(g: u32, x: u32, y: u32) u8 {
    const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
    const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
    const c: f32 = cell / 2;
    const v: f32 = switch (g % 8) {
        // Filled box with a 1-texel margin.
        0 => if (x >= 2 and x < 14 and y >= 2 and y < 14) 1 else 0,
        // Ring.
        1 => blk: {
            const d = @sqrt((fx - c) * (fx - c) + (fy - c) * (fy - c));
            break :blk std.math.clamp(1.5 - @abs(d - 5.0), 0, 1);
        },
        // Diagonal stroke.
        2 => std.math.clamp(1.6 - @abs(fx - fy), 0, 1),
        // Anti-diagonal stroke.
        3 => std.math.clamp(1.6 - @abs(fx + fy - cell), 0, 1),
        // Horizontal coverage ramp.
        4 => if (y >= 4 and y < 12) fx / cell else 0,
        // Vertical bar of half coverage.
        5 => if (x >= 6 and x < 10 and y >= 1) 0.5 else 0,
        // Dot.
        6 => std.math.clamp(3.5 - @sqrt((fx - c) * (fx - c) + (fy - 11) * (fy - 11)), 0, 1),
        // "Letter" made of strokes: an L with a serif.
        else => if ((x >= 3 and x < 5 and y >= 2 and y < 14) or (y >= 12 and y < 14 and x >= 3 and x < 13) or (y >= 2 and y < 3 and x >= 1 and x < 7)) 1 else 0,
    };
    // Vary the shapes by row so each glyph id is distinct.
    const row_scale: f32 = 1.0 - @as(f32, @floatFromInt(g / 8)) * 0.07;
    return @intFromFloat(@floor(std.math.clamp(v * row_scale, 0, 1) * 255.0 + 0.5));
}

/// Writes the grayscale page (r8, `page_size`²) into `out`.
pub fn grayPage(out: []u8) void {
    std.debug.assert(out.len == page_size * page_size);
    for (0..page_size) |y| for (0..page_size) |x| {
        const g: u32 = @intCast((y / cell) * cells_per_row + x / cell);
        out[y * page_size + x] = coverage(g, @intCast(x % cell), @intCast(y % cell));
    };
}

/// Writes the subpixel page (rgba8, RGB = coverage sampled at -1/3, 0,
/// +1/3 texel, A = max) into `out`.
pub fn subpixelPage(out: []u8) void {
    std.debug.assert(out.len == page_size * page_size * 4);
    for (0..page_size) |y| for (0..page_size) |x| {
        const g: u32 = @intCast((y / cell) * cells_per_row + x / cell);
        const lx: u32 = @intCast(x % cell);
        const ly: u32 = @intCast(y % cell);
        const mid = coverage(g, lx, ly);
        const left = if (lx > 0) coverage(g, lx - 1, ly) else 0;
        const right = if (lx + 1 < cell) coverage(g, lx + 1, ly) else 0;
        const r: u8 = @intCast((@as(u32, left) + 2 * @as(u32, mid)) / 3);
        const b: u8 = @intCast((@as(u32, right) + 2 * @as(u32, mid)) / 3);
        const o = (y * page_size + x) * 4;
        out[o..][0..4].* = .{ r, mid, b, @max(r, @max(mid, b)) };
    };
}

/// Writes the colour page (premultiplied rgba8): each glyph is a coloured
/// disc with a highlight, like an emoji.
pub fn colorPage(out: []u8) void {
    std.debug.assert(out.len == page_size * page_size * 4);
    for (0..page_size) |y| for (0..page_size) |x| {
        const g: u32 = @intCast((y / cell) * cells_per_row + x / cell);
        const fx: f32 = @as(f32, @floatFromInt(x % cell)) + 0.5 - 8;
        const fy: f32 = @as(f32, @floatFromInt(y % cell)) + 0.5 - 8;
        const a = std.math.clamp(7.0 - @sqrt(fx * fx + fy * fy), 0, 1);
        const hl = std.math.clamp(2.5 - @sqrt((fx + 2) * (fx + 2) + (fy + 2) * (fy + 2)), 0, 1);
        const base = [3]f32{ @floatFromInt((g * 53) % 256), @floatFromInt((g * 97 + 80) % 256), @floatFromInt((g * 31 + 160) % 256) };
        var px: [4]u8 = undefined;
        for (0..3) |c| {
            const v = (base[c] * (1 - hl) + 255 * hl) / 255 * a;
            px[c] = @intFromFloat(@floor(v * 255 + 0.5));
        }
        px[3] = @intFromFloat(@floor(a * 255 + 0.5));
        const o = (y * page_size + x) * 4;
        out[o..][0..4].* = px;
    };
}

/// Writes a 32×32 premultiplied checker/gradient test image into `out`.
pub fn testImage(out: []u8) void {
    std.debug.assert(out.len == 32 * 32 * 4);
    for (0..32) |y| for (0..32) |x| {
        const checker = ((x / 4) + (y / 4)) % 2 == 0;
        const o = (y * 32 + x) * 4;
        out[o..][0..4].* = if (checker)
            .{ @intCast(x * 8), @intCast(y * 8), 128, 255 }
        else
            .{ 255, 255, @intCast(255 - x * 8), 255 };
    };
}

/// The quad of glyph `g` from a page, placed at (x, y) with `size` px.
pub fn quad(g: u32, x: f32, y: f32, size: f32, page: u16, format: r2d.AtlasFormat) r2d.GlyphQuad {
    const gx: f32 = @floatFromInt((g % glyph_count) % cells_per_row);
    const gy: f32 = @floatFromInt((g % glyph_count) / cells_per_row);
    const inv: f32 = 1.0 / @as(f32, cells_per_row);
    return .{
        .dst = .{ x, y, size, size },
        .uv = .{ gx * inv, gy * inv, (gx + 1) * inv, (gy + 1) * inv },
        .page = page,
        .format = format,
    };
}

test "synthetic atlas: shapes are distinct and bounded" {
    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    var g: u32 = 0;
    while (g < glyph_count) : (g += 1) {
        var h = std.hash.Wyhash.init(0);
        for (0..cell) |y| for (0..cell) |x| h.update(&.{coverage(g, @intCast(x), @intCast(y))});
        try seen.put(h.final(), {});
    }
    try std.testing.expectEqual(@as(usize, glyph_count), seen.count());
}
