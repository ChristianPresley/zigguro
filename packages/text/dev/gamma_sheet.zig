//! `text-gamma-sheet`: renders a contact sheet for tuning text gamma and
//! contrast without a GPU. Each row is a sample line at one size from 8 to
//! 20 px; the left panel is dark text on a light background, the right
//! panel light on dark. Coverage goes through `raster.gamma.textCoverage`
//! and is blended in sRGB-encoded space, as E02's shader does, so both
//! panels should look equally heavy at good settings.
//!
//!   text-gamma-sheet <out.ppm> [--font <path>] [--gamma 1.8] [--contrast 0.25]
//!                    [--lcd] [--stem-darkening]

const std = @import("std");
const zg_text = @import("zg_text");
const ot = zg_text.ot;
const raster = zg_text.raster;

const sample = "Hamburgefonstiv 0Oo1lI {}[]() => fn main()";
const panel_w = 560;
const pad = 8;

const Theme = struct { fg: [3]u8, bg: [3]u8 };
const themes = [2]Theme{
    .{ .fg = .{ 0x20, 0x20, 0x20 }, .bg = .{ 0xfa, 0xfa, 0xfa } },
    .{ .fg = .{ 0xe0, 0xe0, 0xe0 }, .bg = .{ 0x1e, 0x1e, 0x1e } },
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) return usage();
    var font_path: []const u8 = "testdata/fonts/JetBrainsMono[wght].ttf";
    var gp: raster.GammaParams = .{};
    var lcd = false;
    var stem = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--lcd")) {
            lcd = true;
        } else if (std.mem.eql(u8, a, "--stem-darkening")) {
            stem = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--font")) {
            i += 1;
            font_path = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--gamma")) {
            i += 1;
            gp.gamma = try std.fmt.parseFloat(f32, args[i]);
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--contrast")) {
            i += 1;
            gp.contrast = try std.fmt.parseFloat(f32, args[i]);
        } else return usage();
    }
    var font = try ot.MappedFont.openAlloc(io, std.Io.Dir.cwd(), font_path, gpa);
    defer font.close(io);
    const face = try ot.Face.init(font.bytes(), 0);
    var inst = try ot.variation.FaceInstance.init(gpa, &face, &.{});
    defer inst.deinit(gpa);
    var r: raster.Rasterizer = .init(gpa);
    defer r.deinit();

    const sizes = [_]f32{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20 };
    var height: usize = pad;
    for (sizes) |px| height += @as(usize, @intFromFloat(@ceil(px * 1.5)));
    const width: usize = 2 * panel_w;
    const img = try gpa.alloc(u8, width * height * 3);
    for (themes, 0..) |t, k| for (0..height) |y| for (0..panel_w) |x| {
        @memcpy(img[(y * width + k * panel_w + x) * 3 ..][0..3], &t.bg);
    };
    const upem: f32 = @floatFromInt(face.units_per_em);
    var baseline: f32 = pad;
    for (sizes) |px| {
        baseline += @round(px * 1.15);
        for (themes, 0..) |t, k| {
            var pen: f32 = pad;
            for (sample) |ch| {
                const gid = face.glyphIndex(ch);
                const whole = @floor(pen);
                const frac = @round((pen - whole) * 4) / 4;
                const bm = try r.rasterizeGlyph(&inst, gid, .{
                    .px_per_em = px,
                    .subpixel_x = frac,
                    .mode = if (lcd) .lcd_rgb else .gray,
                    .stem_darkening = stem,
                });
                const ox: i64 = @as(i64, @intFromFloat(whole)) + bm.left + @as(i64, @intCast(k * panel_w));
                const oy: i64 = @as(i64, @intFromFloat(baseline)) + bm.top;
                blit(img, width, height, k, bm, ox, oy, t, gp);
                pen += inst.advance(gid) * px / upem;
            }
        }
        baseline += @round(px * 0.35);
    }
    var buf: [1 << 16]u8 = undefined;
    const out = try std.Io.Dir.cwd().createFile(io, args[1], .{});
    defer out.close(io);
    var fw = out.writer(io, &buf);
    try fw.interface.print("P6\n{d} {d}\n255\n", .{ width, height });
    try fw.interface.writeAll(img);
    try fw.interface.flush();
    return 0;
}

fn blit(img: []u8, width: usize, height: usize, panel: usize, bm: raster.Bitmap, ox: i64, oy: i64, t: Theme, gp: raster.GammaParams) void {
    const fg = [3]f32{ @as(f32, @floatFromInt(t.fg[0])) / 255, @as(f32, @floatFromInt(t.fg[1])) / 255, @as(f32, @floatFromInt(t.fg[2])) / 255 };
    const l = raster.gamma.luma(fg);
    const lo: i64 = @intCast(panel * panel_w);
    for (0..bm.height) |y| {
        const py = oy + @as(i64, @intCast(y));
        if (py < 0 or py >= height) continue;
        const row = bm.row(y);
        for (0..bm.width) |x| {
            const px = ox + @as(i64, @intCast(x));
            if (px < lo or px >= lo + panel_w) continue;
            const dst = img[(@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))) * 3 ..][0..3];
            for (0..3) |c| {
                const raw = if (bm.format == .lcd_rgb8x3) row[x * 3 + c] else row[x];
                const cov = raster.gamma.textCoverage(@as(f32, @floatFromInt(raw)) / 255, l, gp);
                const d: f32 = @floatFromInt(dst[c]);
                const f: f32 = @floatFromInt(t.fg[c]);
                dst[c] = @intFromFloat(@round(d + (f - d) * cov));
            }
        }
    }
}

fn usage() u8 {
    std.debug.print(
        \\usage: text-gamma-sheet <out.ppm> [--font <path>] [--gamma 1.8] [--contrast 0.25] [--lcd] [--stem-darkening]
        \\
    , .{});
    return 2;
}
