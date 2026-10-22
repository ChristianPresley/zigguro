//! COLR tests: the googlefonts COLRv1 test glyphs against Skia goldens from
//! `testdata/provenance/gen_colr_golden.py`, CPAL palette selection, v0
//! layers, the text colour, the 28 composite modes against the W3C
//! formulas, cycles, variable clip boxes and gradient extend modes.

const std = @import("std");
const testing = std.testing;
const colr_mod = @import("../ot/colr.zig");
const Colr = colr_mod.Colr;
const cr = @import("colr_render.zig");
const compose = @import("compose.zig");
const png = @import("png.zig");
const rz = @import("rasterizer.zig");
const Rasterizer = rz.Rasterizer;
const Bitmap = rz.Bitmap;
const Face = @import("../ot/face.zig").Face;
const variation = @import("../ot/var/root.zig");
const fonts = @import("../testing/fonts.zig");

/// sRGB (1, 0.5, 0) in linear light: the text colour the goldens use.
const golden_fg: [4]f32 = .{ 1, 0.21404114, 0, 1 };

/// Golden pixels the generator marks as edges (outline and clip edges,
/// hard colour stops, gradient singularities), and their neighbours, are
/// the area average of 256 samples where zg_text gives exact coverage
/// times the colour at the pixel centre: they differ legitimately where a
/// stop or stripes finer than a pixel fall inside it, or where layers share
/// an anti-aliased edge (conflation). Every other pixel must match to ±2.
/// Shape and placement are checked over all pixels through the alpha:
/// its total within 1% and its centroid within 0.05 px.
const flat_tol = 2;
const alpha_total_tol = 0.01;
const centroid_tol = 0.05;

/// Glyphs that differ more, and why. Each relaxes only the checks it
/// names; the rest keep the defaults above.
const Exception = struct {
    stem: []const u8,
    cp: u21,
    flat: u8 = flat_tol,
    alpha_total: f64 = alpha_total_tol,
    centroid: f64 = centroid_tol,
};
const exceptions = [_]Exception{
    // Five rotated copies of one glyph whose edges nearly coincide:
    // coverage-based anti-aliasing (as Skia draws at 1×) conflates them.
    .{ .stem = "test_glyphs-32px", .cp = 0xF1200, .flat = 12 },
    // Two layers drawn over each other with one shared edge: conflation
    // adds the edge pixels' coverage up (+7%, edge pixels only).
    .{ .stem = "test_glyphs-32px", .cp = 0xF0900, .alpha_total = 0.08 },
    // The same through a varied scale whose cross arms share edges (+4%).
    .{ .stem = "test_glyphs-variable-32px", .cp = 0xF0300, .alpha_total = 0.05 },
    // A varied two-point conical gradient no longer covers the plane; its
    // shader edge is sampled at pixel centres (as Skia does at 1×) where
    // the golden averages it (+2.4%).
    .{ .stem = "test_glyphs-variable-32px", .cp = 0xF0C0A, .alpha_total = 0.03 },
    // That gradient's edge plus two layers cut to one clip rectangle,
    // conflated on its edges (+2.2%, centroid 0.11 px).
    .{ .stem = "test_glyphs-variable-32px", .cp = 0xF0C04, .alpha_total = 0.03, .centroid = 0.15 },
};

const GoldenIndex = struct {
    px: f32,
    glyphs: []const struct { cp: u21, gid: u16, left: i32, top: i32, width: u32, height: u32, x: u32, y: u32 },
    refused: []const u21,
};

const Fixture = struct {
    data: []u8,
    face: Face,
    inst: variation.FaceInstance,
    colr: Colr,

    fn init(f: *Fixture, gpa: std.mem.Allocator, file: []const u8, user: []const variation.AxisValue) !void {
        f.data = try fonts.font(gpa, file);
        errdefer gpa.free(f.data);
        f.face = try Face.init(f.data, 0);
        f.inst = try variation.FaceInstance.init(gpa, &f.face, user);
        f.colr = Colr.fromFace(&f.face).?;
    }

    fn deinit(f: *Fixture, gpa: std.mem.Allocator) void {
        f.inst.deinit(gpa);
        gpa.free(f.data);
    }
};

/// Pixel (x, y) in absolute canvas coordinates, zero outside the bitmap.
fn bitmapPx(b: Bitmap, x: i32, y: i32) [4]u8 {
    const bx = x - b.left;
    const by = y - b.top;
    if (bx < 0 or by < 0 or bx >= b.width or by >= b.height) return .{ 0, 0, 0, 0 };
    return b.pixels[@as(usize, @intCast(by)) * b.stride + @as(usize, @intCast(bx)) * 4 ..][0..4].*;
}

/// Golden pixel (x, y) of glyph `g` in absolute canvas coordinates, zero
/// outside its box.
fn goldenPx(img: *const png.Image, g: anytype, x: i32, y: i32) [4]u8 {
    if (x < g.left or y < g.top or x >= g.left + @as(i32, @intCast(g.width)) or y >= g.top + @as(i32, @intCast(g.height))) return .{ 0, 0, 0, 0 };
    const i = (g.y + @as(usize, @intCast(y - g.top))) * img.w + g.x + @as(usize, @intCast(x - g.left));
    return img.rgba[i * 4 ..][0..4].*;
}

/// Renders every glyph of a golden set and compares it with the reference
/// (see `flat_tol`); glyphs the reference refused must be `Malformed`.
fn checkGoldens(stem: []const u8, font_file: []const u8, user: []const variation.AxisValue) !void {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, font_file, user);
    defer f.deinit(gpa);
    var buf: [128]u8 = undefined;
    const zon = try fonts.readTestdataZ(gpa, try std.fmt.bufPrint(&buf, "golden/colr/{s}.zon", .{stem}));
    defer gpa.free(zon);
    const idx = try std.zon.parse.fromSliceAlloc(GoldenIndex, gpa, zon, null, .{});
    defer std.zon.parse.free(gpa, idx);
    const png_bytes = try fonts.readTestdata(gpa, try std.fmt.bufPrint(&buf, "golden/colr/{s}.png", .{stem}));
    defer gpa.free(png_bytes);
    var atlas = try png.decodeOpts(gpa, png_bytes, png.default_max_pixels, .{ .premultiply = false });
    defer atlas.deinit(gpa);
    const edge_bytes = try fonts.readTestdata(gpa, try std.fmt.bufPrint(&buf, "golden/colr/{s}-edges.png", .{stem}));
    defer gpa.free(edge_bytes);
    var edges = try png.decodeOpts(gpa, edge_bytes, png.default_max_pixels, .{ .premultiply = false });
    defer edges.deinit(gpa);

    var r = Rasterizer.init(gpa);
    defer r.deinit();
    var bad: usize = 0;
    for (idx.glyphs) |g| {
        const bm = try cr.renderColorGlyph(&r, &f.inst, &f.colr, g.gid, .{ .px_per_em = idx.px, .fg = golden_fg });
        if (!bm.isEmpty()) try testing.expectEqual(Bitmap.Format.rgba8_premul, bm.format);
        var ex: Exception = .{ .stem = stem, .cp = g.cp };
        for (exceptions) |e| if (e.cp == g.cp and std.mem.eql(u8, e.stem, stem)) {
            ex = e;
        };
        // Every pixel of the union of both boxes; zero outside each.
        const gx1 = g.left + @as(i32, @intCast(g.width));
        const gy1 = g.top + @as(i32, @intCast(g.height));
        var worst: u8 = 0;
        var mom_want: [3]f64 = .{ 0, 0, 0 };
        var mom_got: [3]f64 = .{ 0, 0, 0 };
        var y = @min(g.top, bm.top);
        while (y < @max(gy1, @as(i32, bm.top) + @as(i32, @intCast(bm.height)))) : (y += 1) {
            var x = @min(g.left, bm.left);
            while (x < @max(gx1, @as(i32, bm.left) + @as(i32, @intCast(bm.width)))) : (x += 1) {
                const want = goldenPx(&atlas, g, x, y);
                const got = bitmapPx(bm, x, y);
                const fx: f64 = @floatFromInt(x);
                const fy: f64 = @floatFromInt(y);
                mom_want[0] += @floatFromInt(want[3]);
                mom_want[1] += fx * @as(f64, @floatFromInt(want[3]));
                mom_want[2] += fy * @as(f64, @floatFromInt(want[3]));
                mom_got[0] += @floatFromInt(got[3]);
                mom_got[1] += fx * @as(f64, @floatFromInt(got[3]));
                mom_got[2] += fy * @as(f64, @floatFromInt(got[3]));
                var near_edge = false;
                for (0..3) |dy| for (0..3) |dx| {
                    if (goldenPx(&edges, g, x + @as(i32, @intCast(dx)) - 1, y + @as(i32, @intCast(dy)) - 1)[0] != 0) near_edge = true;
                };
                if (near_edge) continue;
                for (want, got) |a, b| worst = @max(worst, if (a > b) a - b else b - a);
            }
        }
        const total_ok = @abs(mom_got[0] - mom_want[0]) <= ex.alpha_total * mom_want[0] + 255;
        var centroid_off: f64 = 0;
        if (mom_want[0] > 0 and mom_got[0] > 0) {
            for (1..3) |k| centroid_off = @max(centroid_off, @abs(mom_got[k] / mom_got[0] - mom_want[k] / mom_want[0]));
        }
        if (worst > ex.flat or !total_ok or centroid_off > ex.centroid) {
            std.debug.print("{s} U+{X}: flat max {d}, alpha total {d} vs {d}, centroid off {d:.3} px\n", .{ stem, g.cp, worst, mom_got[0], mom_want[0], centroid_off });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
    for (idx.refused) |cp| {
        try testing.expectError(error.Malformed, cr.renderColorGlyph(&r, &f.inst, &f.colr, f.face.glyphIndex(cp), .{ .px_per_em = idx.px }));
    }
}

/// The axis settings of the variable goldens (see their .zon).
const golden_loc = [_]variation.AxisValue{
    av("SWPS", 30),   av("SWPE", -20),  av("SWC1", 0.5),  av("SWC2", -0.3), av("SWC3", 0.4), av("SWC4", -0.2),
    av("SCOX", 50),   av("SCOY", -30),  av("SCSX", 0.5),  av("SCSY", -0.3), av("GRX0", 100), av("GRY0", -50),
    av("GRX1", 200),  av("GRY1", 50),   av("GRX2", -100), av("GRY2", 80),   av("GRR0", 100), av("GRR1", -60),
    av("COL1", 0.5),  av("COL2", -0.4), av("COL3", 0.3),  av("ROTA", 40),   av("ROTX", 100), av("ROTY", -50),
    av("SKXA", 20),   av("SKYA", -15),  av("SKCX", 80),   av("SKCY", -40),  av("TRXX", 0.2), av("TRYX", -0.1),
    av("TRXY", 0.15), av("TRYY", -0.2), av("TRDX", 60),   av("TRDY", -40),  av("TLDX", 50),  av("TLDY", -70),
    av("CLXI", 100),  av("CLYI", -60),  av("CLXA", -80),  av("CLYA", 50),   av("CLIO", 40),  av("APH1", -0.4),
    av("APH2", -0.3), av("APH3", -0.6),
};

fn av(comptime t: *const [4]u8, v: f32) variation.AxisValue {
    return .{ .tag = @import("../ot/reader.zig").tag(t), .value = v };
}

test "each paint format renders" {
    try checkGoldens("test_glyphs-32px", "test_glyphs-glyf_colr_1.ttf", &.{});
}

test "each variable paint format renders" {
    try checkGoldens("test_glyphs-variable-32px", "test_glyphs-glyf_colr_1_variable.ttf", &golden_loc);
}

test "clipbox variable" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "test_glyphs-glyf_colr_1_variable.ttf", &golden_loc);
    defer f.deinit(gpa);
    // From blackrenderer (fontTools' VarStoreInstancer) at golden_loc.
    const cases = [_]struct { cp: u21, default: [4]f32, varied: [4]f32 }{
        .{ .cp = 0xF0C00, .default = .{ 0, 500, 500, 1000 }, .varied = .{ 100.0061, 440.0024, 420.0134, 1050.0183 } },
        .{ .cp = 0xF0C04, .default = .{ 250, 250, 750, 750 }, .varied = .{ 350.0061, 190.0024, 670.0134, 800.0183 } },
        .{ .cp = 0xF0C0A, .default = .{ 100, 100, 900, 900 }, .varied = .{ 140.0085, 140.0085, 859.9915, 859.9915 } },
    };
    for (cases) |c| {
        const gid = f.face.glyphIndex(c.cp);
        const d = f.colr.clipBox(gid, &.{}).?;
        const v = f.colr.clipBox(gid, f.inst.coordsSlice()).?;
        for ([4]f32{ d.x0, d.y0, d.x1, d.y1 }, c.default) |got, want| try testing.expectEqual(want, got);
        for ([4]f32{ v.x0, v.y0, v.x1, v.y1 }, c.varied) |got, want| try testing.expectApproxEqAbs(want, got, 0.05);
    }
    // No clip box for a glyph outside every clip range.
    try testing.expectEqual(@as(?@import("../outline/root.zig").Rect, null), f.colr.clipBox(0, &.{}));
}

test "cpal palette selection dark" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "test_glyphs-glyf_colr_1.ttf", &.{});
    defer f.deinit(gpa);
    const cpal = f.colr.cpal.?;
    // paletteTypes are {0, dark, light}.
    try testing.expectEqual(@as(u16, 0), cpal.select(0, false));
    try testing.expectEqual(@as(u16, 1), cpal.select(0, true));
    try testing.expectEqual(@as(u16, 1), cpal.select(2, true));
    try testing.expectEqual(@as(u16, 2), cpal.select(2, false));
    // The v0 circles drawn for a dark background use palette 1's red slot.
    var r = Rasterizer.init(gpa);
    defer r.deinit();
    const bm = try cr.renderColorGlyph(&r, &f.inst, &f.colr, f.face.glyphIndex(0xF0E00), .{ .px_per_em = 32, .dark_bg = true });
    const dark = cpal.color(1, 0).?;
    try testing.expectEqual([4]u8{ dark[0], dark[1], dark[2], 255 }, bitmapPx(bm, 26, -20));
}

test "v0 two layers src-over" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "test_glyphs-glyf_colr_1.ttf", &.{});
    defer f.deinit(gpa);
    const gid = f.face.glyphIndex(0xF0E00); // colored_circles_v0
    const layers = f.colr.v0Layers(gid).?;
    try testing.expectEqual(@as(u16, 8), layers.count);
    try testing.expect(f.colr.v1Paint(gid) == null);
    var r = Rasterizer.init(gpa);
    defer r.deinit();
    const bm = try cr.renderColorGlyph(&r, &f.inst, &f.colr, gid, .{ .px_per_em = 32 });
    // Circles of radius 350, 300, ... around (500, 600), largest first: the
    // ring between r300 and r350 shows layer 0 (red), the one between r250
    // and r300 layer 1 (orange) drawn over it.
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, bitmapPx(bm, 26, -20));
    try testing.expectEqual([4]u8{ 255, 165, 0, 255 }, bitmapPx(bm, 24, -20));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, bitmapPx(bm, 29, -20));
}

test "foreground index uses fg" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "test_glyphs-glyf_colr_1.ttf", &.{});
    defer f.deinit(gpa);
    const solid = f.face.glyphIndex(0xF0B06); // foreground_color_solid_alpha_1
    try testing.expect(f.colr.usesForeground(solid));
    try testing.expect(f.colr.usesForeground(f.face.glyphIndex(0xF0B04))); // sweep stop
    try testing.expect(!f.colr.usesForeground(f.face.glyphIndex(0xF0100)));
    try testing.expect(!f.colr.usesForeground(f.face.glyphIndex(0xF0E00)));
    var r = Rasterizer.init(gpa);
    defer r.deinit();
    // Linear 0.214 (sRGB 0.5) at alpha 0.5: premultiplied sRGB 64 at 128.
    const bm = try cr.renderColorGlyph(&r, &f.inst, &f.colr, solid, .{ .px_per_em = 32, .fg = .{ 0.10702057, 0.10702057, 0.10702057, 0.5 } });
    const px = bitmapPx(bm, 16, -16);
    try testing.expectEqual(@as(u8, 128), px[3]);
    for (px[0..3]) |c| try testing.expectApproxEqAbs(@as(f32, 64), @as(f32, @floatFromInt(c)), 1);
}

test "cycle -> fallback" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "test_glyphs-glyf_colr_1.ttf", &.{});
    defer f.deinit(gpa);
    const gid = f.face.glyphIndex(0xF1100); // paintcolrglyph_cycle_first
    var r = Rasterizer.init(gpa);
    defer r.deinit();
    try testing.expectError(error.Malformed, cr.renderColorGlyph(&r, &f.inst, &f.colr, gid, .{ .px_per_em = 32 }));
    try testing.expect(f.colr.usesForeground(gid) or !f.colr.usesForeground(gid)); // terminates
    // The rasterizer falls back to the outline, as gray coverage.
    const bm = try r.rasterizeGlyph(&f.inst, gid, .{ .px_per_em = 32, .color = true });
    try testing.expectEqual(Bitmap.Format.gray8, bm.format);
    // A colour glyph that renders comes back as RGBA.
    const ok = try r.rasterizeGlyph(&f.inst, f.face.glyphIndex(0xF0E01), .{ .px_per_em = 32, .color = true });
    try testing.expectEqual(Bitmap.Format.rgba8_premul, ok.format);
}

test "extend reflect/repeat" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(gpa, "test_glyphs-glyf_colr_1.ttf", &.{});
    defer f.deinit(gpa);
    var r = Rasterizer.init(gpa);
    defer r.deinit();
    // linear_gradient_extend_mode_{pad,repeat,reflect}: the colour line
    // runs over x in [0, 307) font units (about 20 px at 64 px/em); past it
    // pad holds the end colour while repeat and reflect cycle (at x = 25 px,
    // t is 1.27: repeat samples 0.27 and reflect 0.73), so the three agree
    // only on the line itself.
    var rows: [3][4]u8 = undefined;
    var edges: [3][4]u8 = undefined;
    for ([_]u21{ 0xF0500, 0xF0501, 0xF0502 }, 0..) |cp, i| {
        const bm = try cr.renderColorGlyph(&r, &f.inst, &f.colr, f.face.glyphIndex(cp), .{ .px_per_em = 64 });
        rows[i] = bitmapPx(bm, 10, -40);
        edges[i] = bitmapPx(bm, 25, -40);
    }
    try testing.expectEqual(rows[0], rows[1]);
    try testing.expectEqual(rows[0], rows[2]);
    try testing.expect(!std.mem.eql(u8, &edges[0], &edges[1]));
    try testing.expect(!std.mem.eql(u8, &edges[1], &edges[2]));
    try testing.expect(!std.mem.eql(u8, &edges[0], &edges[2]));
}

/// The W3C Compositing and Blending formulas on straight colours, in f64,
/// written out independently of compose.zig.
fn w3c(mode: colr_mod.CompositeMode, s: [4]f64, d: [4]f64) [4]f64 {
    const sa = s[3];
    const da = d[3];
    const pd = struct {
        fn f(src: [4]f64, dst: [4]f64, fa: f64, fb: f64) [4]f64 {
            var o: [4]f64 = undefined;
            for (0..3) |i| o[i] = src[i] * src[3] * fa + dst[i] * dst[3] * fb;
            o[3] = src[3] * fa + dst[3] * fb;
            return o;
        }
    }.f;
    switch (mode) {
        .clear => return .{ 0, 0, 0, 0 },
        .src => return pd(s, d, 1, 0),
        .dest => return pd(s, d, 0, 1),
        .src_over => return pd(s, d, 1, 1 - sa),
        .dest_over => return pd(s, d, 1 - da, 1),
        .src_in => return pd(s, d, da, 0),
        .dest_in => return pd(s, d, 0, sa),
        .src_out => return pd(s, d, 1 - da, 0),
        .dest_out => return pd(s, d, 0, 1 - sa),
        .src_atop => return pd(s, d, da, 1 - sa),
        .dest_atop => return pd(s, d, 1 - da, sa),
        .xor => return pd(s, d, 1 - da, 1 - sa),
        .plus => {
            var o = pd(s, d, 1, 1);
            for (&o) |*v| v.* = @min(v.*, 1);
            return o;
        },
        else => {},
    }
    const cs = [3]f64{ s[0], s[1], s[2] };
    const cb = [3]f64{ d[0], d[1], d[2] };
    var b: [3]f64 = undefined;
    switch (mode) {
        .hue, .saturation, .color, .luminosity => b = switch (mode) {
            .hue => setLum(setSat(cs, sat(cb)), lum(cb)),
            .saturation => setLum(setSat(cb, sat(cs)), lum(cb)),
            .color => setLum(cs, lum(cb)),
            else => setLum(cb, lum(cs)),
        },
        else => for (0..3) |i| {
            b[i] = separable(mode, cs[i], cb[i]);
        },
    }
    var o: [4]f64 = undefined;
    for (0..3) |i| o[i] = (1 - da) * sa * cs[i] + (1 - sa) * da * cb[i] + sa * da * b[i];
    o[3] = sa + da - sa * da;
    return o;
}

fn separable(mode: colr_mod.CompositeMode, cs: f64, cb: f64) f64 {
    return switch (mode) {
        .multiply => cs * cb,
        .screen => cb + cs - cb * cs,
        .overlay => separable(.hard_light, cb, cs),
        .darken => @min(cs, cb),
        .lighten => @max(cs, cb),
        .color_dodge => if (cb == 0) 0 else if (cs == 1) 1 else @min(1, cb / (1 - cs)),
        .color_burn => if (cb == 1) 1 else if (cs == 0) 0 else 1 - @min(1, (1 - cb) / cs),
        .hard_light => if (cs <= 0.5) cb * 2 * cs else separable(.screen, 2 * cs - 1, cb),
        .soft_light => if (cs <= 0.5) cb - (1 - 2 * cs) * cb * (1 - cb) else cb + (2 * cs - 1) * ((if (cb <= 0.25) ((16 * cb - 12) * cb + 4) * cb else @sqrt(cb)) - cb),
        .difference => @abs(cs - cb),
        .exclusion => cs + cb - 2 * cs * cb,
        else => unreachable,
    };
}

fn lum(c: [3]f64) f64 {
    return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];
}

fn clipColor(c: [3]f64) [3]f64 {
    const l = lum(c);
    const n = @min(c[0], c[1], c[2]);
    const x = @max(c[0], c[1], c[2]);
    var o = c;
    if (n < 0) for (&o) |*v| {
        v.* = l + (v.* - l) * l / (l - n);
    };
    if (x > 1) for (&o) |*v| {
        v.* = l + (v.* - l) * (1 - l) / (x - l);
    };
    return o;
}

fn setLum(c: [3]f64, l: f64) [3]f64 {
    const d = l - lum(c);
    return clipColor(.{ c[0] + d, c[1] + d, c[2] + d });
}

fn sat(c: [3]f64) f64 {
    return @max(c[0], c[1], c[2]) - @min(c[0], c[1], c[2]);
}

fn setSat(c: [3]f64, s: f64) [3]f64 {
    const mx = @max(c[0], c[1], c[2]);
    const mn = @min(c[0], c[1], c[2]);
    var o: [3]f64 = .{ 0, 0, 0 };
    if (mx > mn) {
        // The middle channel scales; the max goes to s and the min to 0.
        var max_i: usize = 0;
        var min_i: usize = 0;
        for (0..3) |i| {
            if (c[i] > c[max_i]) max_i = i;
            if (c[i] < c[min_i]) min_i = i;
        }
        if (max_i == min_i) min_i = (max_i + 1) % 3;
        const mid_i = 3 - max_i - min_i;
        o[mid_i] = (c[mid_i] - mn) * s / (mx - mn);
        o[max_i] = s;
    }
    return o;
}

test "composite modes table" {
    // Straight-colour source and backdrop pixels: opaque, translucent,
    // transparent, dark, light and saturated.
    const pixels = [_][4]f64{
        .{ 1, 0, 0, 1 },         .{ 0.2, 0.6, 0.9, 1 },     .{ 0.25, 0.75, 0.5, 0.5 },
        .{ 0.9, 0.9, 0.1, 0.8 }, .{ 0.05, 0.1, 0.02, 0.3 }, .{ 0, 0, 0, 0 },
        .{ 1, 1, 1, 1 },         .{ 0.5, 0.5, 0.5, 0.25 },
    };
    inline for (@typeInfo(colr_mod.CompositeMode).@"enum".fields) |field| {
        const mode: colr_mod.CompositeMode = @enumFromInt(field.value);
        for (pixels) |s| for (pixels) |d| {
            const want = w3c(mode, s, d);
            const sp: compose.V = .{ @floatCast(s[0] * s[3]), @floatCast(s[1] * s[3]), @floatCast(s[2] * s[3]), @floatCast(s[3]) };
            const dp: compose.V = .{ @floatCast(d[0] * d[3]), @floatCast(d[1] * d[3]), @floatCast(d[2] * d[3]), @floatCast(d[3]) };
            const got: [4]f32 = compose.blend(mode, sp, dp);
            for (0..4) |i| {
                testing.expectApproxEqAbs(want[i], @as(f64, got[i]), 1e-5) catch |e| {
                    std.debug.print("{s} s={any} d={any} ch {d}: want {d} got {d}\n", .{ field.name, s, d, i, want[i], got[i] });
                    return e;
                };
            }
        };
    }
}

/// The variable test font, instanced at the default and at `golden_loc`,
/// kept across fuzz inputs (its outlines and variations feed the paints).
var fuzz_font: ?struct { f: Fixture, varied: variation.FaceInstance } = null;

/// Input: a flags byte (bit 0: render at `golden_loc`, bit 1: dark
/// background), the COLR length as a little-endian u32 (clamped), COLR, then
/// CPAL. Up to 32 glyphs with a colour definition are rendered at 16 px;
/// any result but a bitmap or Malformed/Unsupported/LimitExceeded fails.
fn fuzzColr(input: []const u8) !void {
    if (input.len < 5) return;
    const gpa = std.heap.page_allocator;
    if (fuzz_font == null) {
        var f: Fixture = undefined;
        try f.init(gpa, "test_glyphs-glyf_colr_1_variable.ttf", &.{});
        fuzz_font = .{ .f = f, .varied = try variation.FaceInstance.init(gpa, &f.face, &golden_loc) };
    }
    const ff = &fuzz_font.?;
    const rest = input[5..];
    const n = @min(std.mem.readInt(u32, input[1..5], .little), rest.len);
    const colr = Colr.init(rest[0..n], rest[n..]) catch return;
    const inst = if (input[0] & 1 != 0) &ff.varied else &ff.f.inst;
    var r = Rasterizer.init(testing.allocator);
    defer r.deinit();
    var rendered: usize = 0;
    var gid: u16 = 0;
    while (gid < ff.f.face.num_glyphs and rendered < 32) : (gid += 1) {
        if (!colr.hasGlyph(gid)) continue;
        rendered += 1;
        _ = colr.usesForeground(gid);
        _ = colr.clipBox(gid, inst.coordsSlice());
        const bm = cr.renderColorGlyph(&r, inst, &colr, gid, .{ .px_per_em = 16, .dark_bg = input[0] & 2 != 0, .fg = golden_fg }) catch |e| switch (e) {
            error.Malformed, error.Unsupported, error.LimitExceeded => continue,
            else => return e,
        };
        try testing.expect(bm.isEmpty() or bm.pixels.len >= @as(usize, bm.height - 1) * bm.stride + bm.width * 4);
    }
}

test "fuzz: colr" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try fuzzColr(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "colr") });
}
