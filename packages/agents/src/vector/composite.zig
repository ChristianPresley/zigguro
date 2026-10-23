//! Compositing (E13.F07.S01.T02): coverage × colour, source-over into
//! premultiplied RGBA8, in sRGB space like E02's UI blending. Integer
//! arithmetic only, so tiles are bit-identical on every target.

const std = @import("std");
const Color = @import("display_list.zig").Color;

/// A rectangle of pixels, `[x0, x1) × [y0, y1)`.
pub const PxRect = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

/// `(a * b + 127) / 255`, exact for bytes.
inline fn mul255(a: u32, b: u32) u32 {
    const t = a * b + 128;
    return (t + (t >> 8)) >> 8;
}

/// Blends `color` at `cov` coverage over `dst` (premultiplied RGBA,
/// `stride` bytes a row) inside `clip`. `cov` has `cov_stride` bytes a
/// row and the same origin as `dst`.
pub fn srcOver(dst: []u8, stride: usize, cov: []const u8, cov_stride: usize, color: Color, clip: PxRect) void {
    if (color.a == 0) return;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const crow = cov[y * cov_stride ..];
        const drow = dst[y * stride ..];
        var x = clip.x0;
        while (x < clip.x1) : (x += 1) {
            const c = crow[x];
            if (c == 0) continue;
            const px = drow[x * 4 ..][0..4];
            if (c == 255 and color.a == 255) {
                px.* = .{ color.r, color.g, color.b, 255 };
                continue;
            }
            const sa = mul255(color.a, c);
            const inv = 255 - sa;
            px[0] = @intCast(mul255(color.r, sa) + mul255(px[0], inv));
            px[1] = @intCast(mul255(color.g, sa) + mul255(px[1], inv));
            px[2] = @intCast(mul255(color.b, sa) + mul255(px[2], inv));
            px[3] = @intCast(sa + mul255(px[3], inv));
        }
    }
}

test "opaque fast path matches the blend" {
    var a = [_]u8{ 10, 20, 30, 40 } ** 2;
    var b = a;
    const cov = [_]u8{ 255, 255 };
    srcOver(&a, 8, &cov, 2, .{ .r = 200, .g = 100, .b = 50 }, .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 1 });
    // The general formula with sa = 255.
    for (0..2) |i| {
        const px = b[i * 4 ..][0..4];
        px.* = .{ @intCast(mul255(200, 255) + mul255(px[0], 0)), @intCast(mul255(100, 255) + mul255(px[1], 0)), @intCast(mul255(50, 255) + mul255(px[2], 0)), 255 };
    }
    try std.testing.expectEqualSlices(u8, &b, &a);
}

test "mul255 rounds a*b/255" {
    for (0..256) |a| for (0..256) |b| {
        const want: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(a * b)) / 255.0));
        try std.testing.expectEqual(want, mul255(@intCast(a), @intCast(b)));
    };
}
