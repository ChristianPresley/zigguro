//! SDF tests: exact distances on a circle, the threshold-and-upsample
//! check against a 4× coverage mask, overlapping contours and the spread
//! clamp.

const std = @import("std");
const testing = std.testing;
const sdf = @import("sdf.zig");
const rz = @import("rasterizer.zig");
const Rasterizer = rz.Rasterizer;
const Path = @import("../outline/path.zig").Path;
const Face = @import("../ot/face.zig").Face;
const variation = @import("../ot/var/root.zig");
const fonts = @import("../testing/fonts.zig");

/// A circle of radius `rad` at (cx, cy) from four cubics (kappa 0.5523).
fn circle(gpa: std.mem.Allocator, p: *Path, cx: f32, cy: f32, rad: f32) !void {
    const k = 0.5522847498 * rad;
    try p.moveTo(gpa, cx + rad, cy);
    try p.cubicTo(gpa, cx + rad, cy + k, cx + k, cy + rad, cx, cy + rad);
    try p.cubicTo(gpa, cx - k, cy + rad, cx - rad, cy + k, cx - rad, cy);
    try p.cubicTo(gpa, cx - rad, cy - k, cx - k, cy - rad, cx, cy - rad);
    try p.cubicTo(gpa, cx + k, cy - rad, cx + rad, cy - k, cx + rad, cy);
    try p.close(gpa);
}

fn sample(bm: rz.Bitmap, x: usize, y: usize) u8 {
    return bm.pixels[y * bm.stride + x];
}

test "sdf of circle is radial" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    var p: Path = .{};
    defer p.deinit(gpa);
    // 1 unit = 1 px at upem 48 / base 48.
    try circle(gpa, &p, 30, 10, 20);
    const bm = try sdf.generate(&r, &p, 48, .{});
    try testing.expectEqual(rz.Bitmap.Format.sdf8, bm.format);
    // Circle bounds plus 4 px spread on each side.
    try testing.expectEqual(@as(u16, 48), bm.width);
    try testing.expectEqual(@as(u16, 48), bm.height);
    var checked: usize = 0;
    for (0..bm.height) |y| for (0..bm.width) |x| {
        // Pixel centre in pixel space (y down); the centre is (30, -10).
        const px = @as(f32, @floatFromInt(bm.left)) + @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(bm.top)) + @as(f32, @floatFromInt(y)) + 0.5;
        const d = 20 - @sqrt((px - 30) * (px - 30) + (py + 10) * (py + 10));
        const want = std.math.clamp(0.5 + d / 8, 0, 1) * 255;
        const got: f32 = @floatFromInt(sample(bm, x, y));
        if (@abs(d) < 4) checked += 1;
        try testing.expect(@abs(got - want) <= 2);
    };
    try testing.expect(checked > 400);
}

test "spread clamp" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    var p: Path = .{};
    defer p.deinit(gpa);
    try p.moveTo(gpa, 0, 0);
    try p.lineTo(gpa, 30, 0);
    try p.lineTo(gpa, 30, 30);
    try p.lineTo(gpa, 0, 30);
    try p.close(gpa);
    const bm = try sdf.generate(&r, &p, 48, .{ .spread_px = 2 });
    try testing.expectEqual(@as(u16, 34), bm.width);
    // Corners are beyond the spread outside; the middle beyond it inside.
    try testing.expectEqual(@as(u8, 0), sample(bm, 0, 0));
    try testing.expectEqual(@as(u8, 255), sample(bm, 17, 17));
    // One pixel inside the edge: d = 0.5 px from the centre.
    try testing.expectEqual(@as(u8, 159), sample(bm, 2, 17));
    try testing.expectEqual(@as(u8, 96), sample(bm, 1, 17));
}

test "sdf sign with overlapping contours" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    var p: Path = .{};
    defer p.deinit(gpa);
    try p.moveTo(gpa, 0, 0);
    try p.lineTo(gpa, 0, 20);
    try p.lineTo(gpa, 20, 20);
    try p.lineTo(gpa, 20, 0);
    try p.close(gpa);
    try p.moveTo(gpa, 10, 5);
    try p.lineTo(gpa, 10, 15);
    try p.lineTo(gpa, 30, 15);
    try p.lineTo(gpa, 30, 5);
    try p.close(gpa);
    const bm = try sdf.generate(&r, &p, 48, .{});
    // Every pixel inside the union is inside, including along the inner
    // edges of the overlap.
    for (0..bm.height) |y| for (0..bm.width) |x| {
        const px = @as(f32, @floatFromInt(bm.left + @as(i32, @intCast(x)))) + 0.5;
        const py = -(@as(f32, @floatFromInt(bm.top + @as(i32, @intCast(y)))) + 0.5);
        const in_a = px > 0.5 and px < 19.5 and py > 0.5 and py < 19.5;
        const in_b = px > 10.5 and px < 29.5 and py > 5.5 and py < 14.5;
        if (in_a or in_b) try testing.expect(sample(bm, x, y) > 127);
        const out_all = (px < -0.5 or px > 30.5 or py < -0.5 or py > 20.5) or
            (px > 20.5 and (py < 4.5 or py > 15.5));
        if (out_all) try testing.expect(sample(bm, x, y) < 128);
    };
}

fn bilinear(bm: rz.Bitmap, u: f32, v: f32) f32 {
    const x0 = @floor(u);
    const y0 = @floor(v);
    const fx = u - x0;
    const fy = v - y0;
    var acc: f32 = 0;
    inline for (.{ 0, 1 }) |dy| inline for (.{ 0, 1 }) |dx| {
        const xi = std.math.clamp(@as(i32, @intFromFloat(x0)) + dx, 0, @as(i32, bm.width) - 1);
        const yi = std.math.clamp(@as(i32, @intFromFloat(y0)) + dy, 0, @as(i32, bm.height) - 1);
        const wgt = (if (dx == 1) fx else 1 - fx) * (if (dy == 1) fy else 1 - fy);
        acc += wgt * @as(f32, @floatFromInt(sample(bm, @intCast(xi), @intCast(yi))));
    };
    return acc;
}

test "sdf threshold IoU" {
    const gpa = testing.allocator;
    const data = try fonts.font(gpa, "SourceSerif4-Regular.otf");
    defer gpa.free(data);
    const face = try Face.init(data, 0);
    var inst = try variation.FaceInstance.init(gpa, &face, &.{});
    defer inst.deinit(gpa);
    var rs: Rasterizer = .init(gpa);
    defer rs.deinit();
    var rc: Rasterizer = .init(gpa);
    defer rc.deinit();
    var worst: f64 = 1;
    for ("AaBgQRSWefkmos&@%8?3") |ch| {
        const gid = face.glyphIndex(ch);
        const s = try rs.rasterizeGlyph(&inst, gid, .{ .px_per_em = 48, .mode = .sdf });
        const c = try rc.rasterizeGlyph(&inst, gid, .{ .px_per_em = 192 });
        var inter: usize = 0;
        var uni: usize = 0;
        // Every 4× pixel of the SDF's padded box.
        const x_lo = @as(i32, s.left) * 4;
        const y_lo = @as(i32, s.top) * 4;
        var Y: i32 = y_lo;
        while (Y < y_lo + @as(i32, s.height) * 4) : (Y += 1) {
            var X: i32 = x_lo;
            while (X < x_lo + @as(i32, s.width) * 4) : (X += 1) {
                const u = (@as(f32, @floatFromInt(X)) + 0.5) / 4 - @as(f32, @floatFromInt(s.left)) - 0.5;
                const v = (@as(f32, @floatFromInt(Y)) + 0.5) / 4 - @as(f32, @floatFromInt(s.top)) - 0.5;
                const a = bilinear(s, u, v) >= 127.5;
                const cx = X - c.left;
                const cy = Y - c.top;
                const b = cx >= 0 and cy >= 0 and cx < c.width and cy < c.height and
                    c.pixels[@as(usize, @intCast(cy)) * c.stride + @as(usize, @intCast(cx))] >= 128;
                if (a and b) inter += 1;
                if (a or b) uni += 1;
            }
        }
        const iou = @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(uni));
        worst = @min(worst, iou);
    }
    try testing.expect(worst >= 0.98);
}
