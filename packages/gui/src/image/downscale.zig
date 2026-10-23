//! Box-filter downscaling in linear light (E04.F06.S02.T01): each output
//! pixel averages the source pixels its box covers after converting sRGB
//! to linear, so thumbnails keep their brightness.

const std = @import("std");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;
const Image = image.Image;

/// sRGB byte to linear light.
const to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]f32 = undefined;
    for (0..256) |i| {
        const c: f64 = @as(f64, @floatFromInt(i)) / 255.0;
        t[i] = @floatCast(if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4));
    }
    break :blk t;
};

fn toSrgb(l: f32) u8 {
    const c: f32 = if (l <= 0.0031308) l * 12.92 else 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255));
}

/// `img` scaled so its longer side is at most `max_side` (a copy at the
/// same size when it already fits). Premultiplied channels are averaged
/// as they are, which is exact for opaque images.
pub fn downscale(gpa: Allocator, img: *const Image, max_side: u32) Allocator.Error!Image {
    const long = @max(img.w, img.h);
    if (long <= max_side or max_side == 0) {
        return .{ .w = img.w, .h = img.h, .rgba = try gpa.dupe(u8, img.rgba), .format = img.format };
    }
    const ow: u32 = @max(1, @as(u32, @intCast((@as(u64, img.w) * max_side + long / 2) / long)));
    const oh: u32 = @max(1, @as(u32, @intCast((@as(u64, img.h) * max_side + long / 2) / long)));
    const out = try gpa.alloc(u8, @as(usize, ow) * oh * 4);
    for (0..oh) |oy| {
        const y0 = oy * img.h / oh;
        const y1 = @max(y0 + 1, (oy + 1) * img.h / oh);
        for (0..ow) |ox| {
            const x0 = ox * img.w / ow;
            const x1 = @max(x0 + 1, (ox + 1) * img.w / ow);
            var sum: [4]f32 = .{ 0, 0, 0, 0 };
            for (y0..y1) |y| {
                const row = img.rgba[y * img.w * 4 ..];
                for (x0..x1) |x| {
                    const p = row[x * 4 ..][0..4];
                    sum[0] += to_linear[p[0]];
                    sum[1] += to_linear[p[1]];
                    sum[2] += to_linear[p[2]];
                    sum[3] += @floatFromInt(p[3]);
                }
            }
            const n: f32 = @floatFromInt((y1 - y0) * (x1 - x0));
            const o = out[(oy * ow + ox) * 4 ..][0..4];
            o[0] = toSrgb(sum[0] / n);
            o[1] = toSrgb(sum[1] / n);
            o[2] = toSrgb(sum[2] / n);
            o[3] = @intFromFloat(@round(sum[3] / n));
        }
    }
    return .{ .w = ow, .h = oh, .rgba = out, .format = img.format };
}

test "downscale averages in linear light" {
    const gpa = std.testing.allocator;
    // Black and white columns average to linear mid grey (sRGB ~188).
    var px = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 } ** 2;
    const img: Image = .{ .w = 2, .h = 2, .rgba = &px };
    var s = try downscale(gpa, &img, 1);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), s.w);
    try std.testing.expectEqual(@as(u8, 188), s.rgba[0]);
    try std.testing.expectEqual(@as(u8, 255), s.rgba[3]);
}
