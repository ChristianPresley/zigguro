//! Tests for the styled raster paths: LCD output against gray coverage,
//! stem darkening, synthetic bold and oblique, on real glyphs.

const std = @import("std");
const testing = std.testing;
const rz = @import("rasterizer.zig");
const Rasterizer = rz.Rasterizer;
const Face = @import("../ot/face.zig").Face;
const variation = @import("../ot/var/root.zig");
const fonts = @import("../testing/fonts.zig");

const Fixture = struct {
    data: []u8,
    face: Face,
    inst: variation.FaceInstance,

    fn init(f: *Fixture, gpa: std.mem.Allocator, file: []const u8) !void {
        f.data = try fonts.font(gpa, file);
        f.face = try Face.init(f.data, 0);
        f.inst = try variation.FaceInstance.init(gpa, &f.face, &.{});
    }

    fn deinit(f: *Fixture, gpa: std.mem.Allocator) void {
        f.inst.deinit(gpa);
        gpa.free(f.data);
    }
};

fn total(bm: rz.Bitmap) u64 {
    var t: u64 = 0;
    for (0..bm.height) |y| for (bm.row(y)) |v| {
        t += v;
    };
    return t;
}

test "lcd sum equals gray" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "SourceSerif4-Regular.otf");
    defer f.deinit(gpa);
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    var gray_r: Rasterizer = .init(gpa);
    defer gray_r.deinit();
    for ("AaBgQ@&%#Wil1|") |ch| for ([_]f32{ 0, 0.25, 0.5, 0.75 }) |sub| {
        const gid = f.face.glyphIndex(ch);
        const g = try gray_r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 14, .subpixel_x = sub });
        const l = try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 14, .subpixel_x = sub, .mode = .lcd_rgb });
        try testing.expectEqual(rz.Bitmap.Format.lcd_rgb8x3, l.format);
        try testing.expectEqual(g.top, l.top);
        try testing.expectEqual(g.height, l.height);
        try testing.expect(l.left <= g.left and l.left + @as(i32, l.width) >= g.left + @as(i32, g.width));
        // The filter conserves area: per row, the filtered channels sum
        // to the unfiltered 3× coverage up to rounding.
        const w3 = @as(usize, l.width) * 3;
        for (0..l.height) |y| {
            var fs: i64 = 0;
            for (l.row(y)) |v| fs += v;
            var us: i64 = 0;
            for (r.sub.items[y * w3 ..][0..w3]) |v| us += v;
            try testing.expect(@abs(fs - us) <= w3 / 2 + 1);
        }
        // Against gray: mean coverage per gray pixel within 3/255. (Rows
        // differ more, because the 3× outline is flattened more finely.
        // The font has no overlapping contours: where contours overlap,
        // abs-and-clamp counts partial pixels twice, and 3× resolution
        // changes how much.)
        const gt: f64 = @floatFromInt(total(g));
        const lt: f64 = @as(f64, @floatFromInt(total(l))) / 3;
        try testing.expect(@abs(gt - lt) / @as(f64, @floatFromInt(@as(u32, g.width) * g.height)) <= 3);
    };
}

test "stem darkening adds coverage below 24px only" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "SourceSerif4-Regular.otf");
    defer f.deinit(gpa);
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    const gid = f.face.glyphIndex('m');
    const plain = total(try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 11 }));
    const dark = total(try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 11, .stem_darkening = true }));
    try testing.expect(dark > plain);
    const big = total(try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 30 }));
    const big_dark = total(try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 30, .stem_darkening = true }));
    try testing.expectEqual(big, big_dark);
}

test "synthetic bold widens, oblique shears" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "JetBrainsMono[wght].ttf");
    defer f.deinit(gpa);
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    const gid = f.face.glyphIndex('I');
    const plain = try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 48 });
    const pw = plain.width;
    const pt = total(plain);
    const bold = try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 48, .synth_bold = true });
    try testing.expect(total(bold) > pt);
    try testing.expect(bold.width >= pw + 1); // 2 px wider at 48 px
    const obl = try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 48, .synth_oblique = true });
    // The top leans right by tan(12°) of the glyph height.
    try testing.expect(obl.width > pw + 5);
    try testing.expectApproxEqRel(@as(f64, @floatFromInt(pt)), @as(f64, @floatFromInt(total(obl))), 0.02);
}
