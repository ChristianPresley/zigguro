//! The golden scene corpus: deterministic draw lists that cover every
//! primitive, text mode, clip, layer, damage and edge case. `parity.zig`
//! renders each on the software renderer (exact) and, when available, on
//! Vulkan (tolerance) against `testdata/golden/scenes/<name>.png`.

const std = @import("std");
const r2d = @import("../r2d/root.zig");
const atlas = @import("synthetic_atlas.zig");
const image_diff = @import("image_diff.zig");

const DrawList = r2d.DrawList;
const Color = r2d.Color;
const RectF = r2d.RectF;
const Radii = r2d.Radii;
const Insets = r2d.Insets;
const GlyphQuad = r2d.GlyphQuad;

/// Requirements a backend must meet to run a scene.
pub const Needs = packed struct(u8) {
    /// Dual-source blending (subpixel text).
    dual_src: bool = false,
    /// Offscreen layers.
    layers: bool = false,
    _p: u6 = 0,
};

/// Glyph pages set up by the runner (see `setGlyphPages`).
pub const page_gray: u16 = 0;
/// The subpixel page.
pub const page_subpixel: u16 = 1;
/// The colour page.
pub const page_color: u16 = 2;

/// What a scene's build function gets.
pub const SceneCtx = struct {
    /// Frame being built (0-based).
    frame: u8,
    /// The 32×32 test image.
    image: r2d.TextureId,
    /// Seeded per scene.
    rnd: std.Random,
};

/// One scene.
pub const Scene = struct {
    /// Golden file name.
    name: []const u8,
    /// Target size in physical pixels.
    size: r2d.Size,
    /// Logical to physical scale.
    scale: f32 = 1.0,
    /// Draws one frame. Frame 0 is always a full redraw; later frames
    /// should add damage.
    build: *const fn (dl: *DrawList, ctx: *SceneCtx) void,
    /// Frames to render into the same image.
    frames: u8 = 1,
    /// GPU tolerance override.
    gpu_tolerance: ?image_diff.Tolerance = null,
    /// Backend requirements.
    needs: Needs = .{},
};

fn sz(w: u32, h: u32) r2d.Size {
    return .{ .w = w, .h = h };
}

fn bg(dl: *DrawList, c: Color) void {
    const s = dl.scale;
    dl.rect(.{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(dl.extent.w)) / s, .h = @as(f32, @floatFromInt(dl.extent.h)) / s }, c, .{});
}

const light = Color.fromHex("#f5f5f0");
const dark = Color.fromHex("#1e1f24");
const ink = Color.fromHex("#22252b");
const accent = Color.fromHex("#3d7eff");

fn text(dl: *DrawList, x0: f32, y: f32, n: u32, size: f32, adv: f32, page: u16, fmt: r2d.AtlasFormat, color: Color, aa: r2d.TextAa, first: u32) void {
    var buf: [64]GlyphQuad = undefined;
    var i: u32 = 0;
    while (i < n) {
        const k = @min(n - i, buf.len);
        for (buf[0..k], 0..) |*q, j| {
            const idx = i + @as(u32, @intCast(j));
            q.* = atlas.quad(first + idx * 7, x0 + @as(f32, @floatFromInt(idx)) * adv, y, size, page, fmt);
        }
        dl.glyphs(buf[0..k], color, aa);
        i += k;
    }
}

fn rectSolidGrid(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    var y: u32 = 0;
    while (y < 8) : (y += 1) {
        var x: u32 = 0;
        while (x < 10) : (x += 1) {
            const c: Color = .{ .r = @intCast(x * 25), .g = @intCast(y * 32), .b = @intCast(255 - x * 20) };
            dl.rect(.{ .x = @floatFromInt(4 + x * 12), .y = @floatFromInt(4 + y * 11), .w = 10, .h = 9 }, c, .{});
        }
    }
}

fn roundedRadiiMix(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.rect(.{ .x = 6, .y = 6, .w = 50, .h = 36 }, accent, .{ .tl = 12, .tr = 0, .br = 4, .bl = 18 });
    dl.rect(.{ .x = 66, .y = 6, .w = 50, .h = 36 }, Color.fromHex("#e0457b"), Radii.all(40)); // clamped to a pill
    dl.rect(.{ .x = 6, .y = 50, .w = 24, .h = 24 }, Color.fromHex("#2a9d8f"), Radii.all(12)); // circle
    dl.rect(.{ .x = 40.5, .y = 50.25, .w = 30.5, .h = 20.75 }, Color.fromHex("#f4a261"), Radii.all(6.5)); // fractional
    dl.rect(.{ .x = 80, .y = 50, .w = 36, .h = 36 }, .{ .r = 40, .g = 40, .b = 160, .a = 140 }, .{ .tl = 0, .tr = 18, .br = 0, .bl = 18 });
}

fn borderUneven(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.border(.{ .x = 8, .y = 8, .w = 50, .h = 40 }, .{ .l = 1, .t = 4, .r = 8, .b = 2 }, ink, .{});
    dl.border(.{ .x = 66, .y = 8.5, .w = 50, .h = 40 }, .{ .l = 0.5, .t = 1.5, .r = 2.5, .b = 3.5 }, accent, .{});
    dl.border(.{ .x = 8, .y = 56, .w = 108, .h = 32 }, Insets.all(20), Color.fromHex("#e76f51"), .{}); // wider than the box
}

fn borderRounded(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.border(.{ .x = 8, .y = 8, .w = 50, .h = 40 }, Insets.all(2), ink, Radii.all(8));
    dl.border(.{ .x = 66, .y = 8, .w = 50, .h = 40 }, .{ .l = 6, .t = 2, .r = 2, .b = 6 }, accent, Radii.all(12));
    dl.rect(.{ .x = 8, .y = 56, .w = 108, .h = 32 }, Color.white, Radii.all(10));
    dl.border(.{ .x = 8, .y = 56, .w = 108, .h = 32 }, Insets.all(1), .{ .r = 0, .g = 0, .b = 0, .a = 90 }, Radii.all(10));
}

fn shadowSigmas(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    const sh: Color = .{ .r = 0, .g = 0, .b = 0, .a = 160 };
    dl.shadow(.{ .x = 14, .y = 14, .w = 30, .h = 24 }, .{}, 0.5, 0, sh);
    dl.shadow(.{ .x = 70, .y = 14, .w = 30, .h = 24 }, .{}, 3, 0, sh);
    dl.shadow(.{ .x = 14, .y = 60, .w = 30, .h = 24 }, .{}, 8, 0, sh);
    dl.shadow(.{ .x = 70, .y = 60, .w = 30, .h = 24 }, .{}, 16, 0, sh);
    dl.rect(.{ .x = 70, .y = 60, .w = 30, .h = 24 }, Color.white, .{});
}

fn shadowRoundedSpread(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, Color.fromHex("#e9ecef"));
    const sh: Color = .{ .r = 10, .g = 20, .b = 60, .a = 120 };
    dl.shadow(.{ .x = 16, .y = 16, .w = 40, .h = 28 }, Radii.all(8), 4, 4, sh);
    dl.rect(.{ .x = 16, .y = 16, .w = 40, .h = 28 }, Color.white, Radii.all(8));
    dl.shadow(.{ .x = 76, .y = 20, .w = 30, .h = 30 }, Radii.all(15), 6, -3, sh);
    dl.rect(.{ .x = 76, .y = 20, .w = 30, .h = 30 }, accent, Radii.all(15));
    dl.shadow(.{ .x = 20, .y = 62, .w = 90, .h = 20 }, .{ .tl = 0, .tr = 10, .br = 0, .bl = 10 }, 2, 1, sh);
}

fn gradientAngles(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    const a = Color.fromHex("#ff7b00");
    const b = Color.fromHex("#5a00ff");
    dl.linearGradient(.{ .x = 4, .y = 4, .w = 56, .h = 40 }, .{ .x = 4, .y = 4 }, .{ .x = 60, .y = 4 }, a, b, .{});
    dl.linearGradient(.{ .x = 64, .y = 4, .w = 56, .h = 40 }, .{ .x = 64, .y = 4 }, .{ .x = 64, .y = 44 }, a, b, Radii.all(6));
    dl.linearGradient(.{ .x = 4, .y = 48, .w = 56, .h = 40 }, .{ .x = 4, .y = 48 }, .{ .x = 60, .y = 88 }, a, .{ .r = 0, .g = 0, .b = 255, .a = 0 }, .{});
    dl.linearGradient(.{ .x = 64, .y = 48, .w = 56, .h = 40 }, .{ .x = 100, .y = 60 }, .{ .x = 80, .y = 70 }, Color.white, Color.black, Radii.all(20));
}

fn clipRectNested(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.pushClip(.{ .x = 10, .y = 10, .w = 80, .h = 60 }, .{});
    dl.rect(.{ .x = 0, .y = 0, .w = 128, .h = 96 }, Color.fromHex("#a8dadc"), .{});
    dl.pushClip(.{ .x = 40, .y = 30, .w = 80, .h = 60 }, .{});
    dl.rect(.{ .x = 0, .y = 0, .w = 128, .h = 96 }, Color.fromHex("#457b9d"), .{});
    dl.popClip();
    dl.pushClip(.{ .x = 12.5, .y = 12.5, .w = 20.25, .h = 10.75 }, .{});
    dl.rect(.{ .x = 0, .y = 0, .w = 128, .h = 96 }, Color.fromHex("#e63946"), .{});
    dl.popClip();
    dl.popClip();
}

fn clipRoundedNested(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.pushClip(.{ .x = 8, .y = 8, .w = 112, .h = 80 }, Radii.all(16));
    dl.rect(.{ .x = 0, .y = 0, .w = 128, .h = 96 }, Color.fromHex("#264653"), .{});
    dl.pushClip(.{ .x = 8, .y = 8, .w = 112, .h = 30 }, .{}); // keeps the top corners
    dl.rect(.{ .x = 0, .y = 0, .w = 128, .h = 96 }, Color.fromHex("#e9c46a"), .{});
    dl.popClip();
    dl.pushClip(.{ .x = 60, .y = 44, .w = 50, .h = 36 }, Radii.all(10));
    dl.linearGradient(.{ .x = 0, .y = 0, .w = 128, .h = 96 }, .{ .x = 60, .y = 44 }, .{ .x = 110, .y = 80 }, Color.fromHex("#f4a261"), Color.fromHex("#e76f51"), .{});
    dl.popClip();
    dl.popClip();
}

fn clipCullOffscreen(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.pushClip(.{ .x = 20, .y = 20, .w = 40, .h = 40 }, .{});
    var i: u32 = 0;
    while (i < 50) : (i += 1) dl.rect(.{ .x = @floatFromInt(i * 13), .y = @floatFromInt(i * 7), .w = 12, .h = 12 }, accent, .{});
    dl.popClip();
    dl.rect(.{ .x = -50, .y = -50, .w = 60, .h = 60 }, ink, Radii.all(30));
    dl.rect(.{ .x = 120, .y = 90, .w = 60, .h = 60 }, ink, .{});
    dl.rect(.{ .x = 300, .y = 10, .w = 10, .h = 10 }, ink, .{});
}

fn alphaStack(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, Color.white);
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const c: Color = .{ .r = @intCast((i * 70) % 256), .g = @intCast((i * 40 + 30) % 256), .b = @intCast(255 - i * 20), .a = @intCast(40 + i * 15) };
        dl.rect(.{ .x = @floatFromInt(4 + i * 8), .y = @floatFromInt(4 + i * 5), .w = 40, .h = 40 }, c, Radii.all(@floatFromInt(i)));
    }
}

fn textGrayDarkOnLight(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    var row: u32 = 0;
    while (row < 6) : (row += 1) text(dl, 4, @floatFromInt(4 + row * 15), 14, 14, 8.5, page_gray, .r8, ink, .grayscale, row * 3);
}

fn textGrayLightOnDark(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, dark);
    var row: u32 = 0;
    while (row < 6) : (row += 1) text(dl, 4, @floatFromInt(4 + row * 15), 14, 14, 8.5, page_gray, .r8, Color.fromHex("#d8dee9"), .grayscale, row * 5);
}

fn textSubpixelRgb(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    var row: u32 = 0;
    while (row < 6) : (row += 1) text(dl, 4, @floatFromInt(4 + row * 15), 14, 14, 8.5, page_subpixel, .rgb_subpixel, ink, .subpixel_rgb, row * 3);
}

fn textSubpixelBgr(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, dark);
    var row: u32 = 0;
    while (row < 6) : (row += 1) text(dl, 4, @floatFromInt(4 + row * 15), 14, 14, 8.5, page_subpixel, .rgb_subpixel, Color.fromHex("#ffd479"), .subpixel_bgr, row * 3);
}

fn textColorEmoji(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    text(dl, 4, 4, 7, 16, 17, page_color, .rgba_color, Color.white, .grayscale, 0);
    text(dl, 4, 24, 7, 16, 17, page_color, .rgba_color, .{ .r = 255, .g = 255, .b = 255, .a = 128 }, .grayscale, 9);
    text(dl, 4, 44, 14, 16, 8, page_gray, .r8, accent, .grayscale, 1);
    text(dl, 4, 64, 7, 16, 17, page_color, .rgba_color, Color.white, .grayscale, 20);
}

fn textTiny(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    var row: u32 = 0;
    while (row < 9) : (row += 1) text(dl, 2, @floatFromInt(2 + row * 10), 22, 9, 5.5, page_gray, .r8, ink, .grayscale, row);
    text(dl, 2, 92, 22, 9, 5.5, page_subpixel, .rgb_subpixel, ink, .grayscale, 4); // rgb page drawn as gray
}

fn textDenseEditor(dl: *DrawList, ctx: *SceneCtx) void {
    bg(dl, dark);
    // Gutter.
    dl.rect(.{ .x = 0, .y = 0, .w = 48, .h = 720 }, Color.fromHex("#25262c"), .{});
    const cols = [_]Color{ Color.fromHex("#c8ccd4"), Color.fromHex("#c678dd"), Color.fromHex("#98c379"), Color.fromHex("#61afef"), Color.fromHex("#e5c07b") };
    var row: u32 = 0;
    while (row < 72) : (row += 1) {
        const y: f32 = @floatFromInt(row * 10);
        text(dl, 4, y, 4, 10, 6, page_gray, .r8, Color.fromHex("#5c6370"), .grayscale, row);
        if (row == 30) dl.rect(.{ .x = 48, .y = y, .w = 1232, .h = 10 }, Color.fromHex("#2c313c"), .{});
        var x: f32 = 52;
        var run: u32 = 0;
        while (x < 1270) : (run += 1) {
            const len = 2 + ctx.rnd.uintLessThan(u32, 12);
            text(dl, x, y, len, 10, 6, page_gray, .r8, cols[run % cols.len], .grayscale, row * 31 + run);
            x += @as(f32, @floatFromInt(len + 1)) * 6;
        }
    }
    dl.rect(.{ .x = 400, .y = 300, .w = 1.5, .h = 10 }, Color.fromHex("#528bff"), .{});
}

fn imageNearestLinear(dl: *DrawList, ctx: *SceneCtx) void {
    bg(dl, light);
    dl.imageFiltered(ctx.image, .{ .x = 4, .y = 4, .w = 32, .h = 32 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.white, .{}, .nearest);
    dl.imageFiltered(ctx.image, .{ .x = 40, .y = 4, .w = 80, .h = 56 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.white, .{}, .nearest);
    dl.image(ctx.image, .{ .x = 4, .y = 40, .w = 32, .h = 50 }, .{ .x = 0.25, .y = 0.25, .w = 0.5, .h = 0.5 }, Color.white, .{});
    dl.image(ctx.image, .{ .x = 40.5, .y = 63.5, .w = 80, .h = 30 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .r = 255, .g = 200, .b = 200, .a = 200 }, .{});
}

fn imageRounded(dl: *DrawList, ctx: *SceneCtx) void {
    bg(dl, dark);
    dl.image(ctx.image, .{ .x = 8, .y = 8, .w = 48, .h = 48 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.white, Radii.all(24));
    dl.imageFiltered(ctx.image, .{ .x = 64, .y = 8, .w = 56, .h = 80 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.white, .{ .tl = 16, .br = 16 }, .nearest);
}

fn layerPlainOpacity(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    if (dl.beginLayer(@enumFromInt(1), .{ .w = 60, .h = 40 }, &.{})) {
        dl.rect(.{ .x = 0, .y = 0, .w = 60, .h = 40 }, Color.fromHex("#2a9d8f"), Radii.all(8));
        text(dl, 4, 12, 6, 16, 9, page_gray, .r8, Color.white, .grayscale, 2);
        dl.endLayer();
    }
    dl.drawLayer(@enumFromInt(1), .{ .x = 4, .y = 4, .w = 60, .h = 40 }, .{}, 1);
    dl.drawLayer(@enumFromInt(1), .{ .x = 64, .y = 30, .w = 60, .h = 40 }, .{}, 0.5);
    dl.drawLayer(@enumFromInt(1), .{ .x = 20, .y = 52, .w = 40, .h = 30 }, .{ .x = 10, .y = 5 }, 1);
}

fn scrollLayerOffsets(dl: *DrawList, ctx: *SceneCtx) void {
    // A tall striped "document" layer scrolled by integer and fractional
    // offsets over six frames; each frame damages the viewport.
    bg(dl, light);
    if (dl.beginLayer(@enumFromInt(2), .{ .w = 80, .h = 200 }, &.{})) {
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            dl.rect(.{ .x = 0, .y = @floatFromInt(i * 10), .w = 80, .h = 10 }, if (i % 2 == 0) Color.fromHex("#fafafa") else Color.fromHex("#e0e7ff"), .{});
            text(dl, 2, @floatFromInt(i * 10), 8, 10, 7, page_gray, .r8, ink, .grayscale, i);
        }
        dl.endLayer();
    }
    const offsets = [_]f32{ 0, 3, 17, 40.5, 77.25, 100 };
    dl.drawLayer(@enumFromInt(2), .{ .x = 20, .y = 10, .w = 80, .h = 70 }, .{ .y = offsets[ctx.frame] }, 1);
    if (ctx.frame > 0) dl.addDamage(.{ .x = 20, .y = 10, .w = 80, .h = 70 });
}

/// The scroll layer seam scene (E02.F06.S03.T01): a 400 px striped
/// document in a 80×100 wraparound layer (viewport 80×60 plus overscan),
/// scrolled across the texture seam at integer and fractional offsets.
pub const seam = struct {
    /// Document scroll position per frame.
    pub const scrolls = [_]f32{ 0, 3, 17, 40.5, 77.25, 130, 211, 209.5, 150 };
    /// Viewport in the window.
    pub const viewport: RectF = .{ .x = 20, .y = 10, .w = 80, .h = 60 };
    /// Layer size: the viewport plus 20 px above and below.
    pub const layer_size: r2d.Size = .{ .w = 80, .h = 100 };
    const overscan = 20;
    pub const doc_h = 400;

    /// Document y at the top of the layer for `frame`.
    pub fn windowTop(frame: usize) i32 {
        const top = @as(i32, @intFromFloat(@floor(scrolls[frame]))) - overscan;
        return std.math.clamp(top, 0, doc_h - @as(i32, layer_size.h));
    }

    /// Draws the document rows in `[top, top + h)`, row y at
    /// (x0, y0 + y - top).
    pub fn document(dl: *DrawList, top: i32, h: i32, x0: f32, y0: f32) void {
        var i: i32 = @divFloor(top, 10);
        while (i * 10 < top + h and i < doc_h / 10) : (i += 1) {
            const y: f32 = y0 + @as(f32, @floatFromInt(i * 10 - top));
            const u: u32 = @intCast(i);
            dl.rect(.{ .x = x0, .y = y, .w = 80, .h = 10 }, if (u % 2 == 0) Color.fromHex("#fafafa") else Color.fromHex("#e0e7ff"), .{});
            dl.rect(.{ .x = x0 + 70, .y = y + 2, .w = 6, .h = 6 }, accent, Radii.all(3));
            text(dl, x0 + 2, y, 8, 10, 7, page_gray, .r8, ink, .grayscale, u);
        }
    }

    /// The scene frame drawn without a scroll layer: the document
    /// clipped to the viewport (integer scrolls), or a plain layer of the
    /// whole document composited at the same offset (fractional ones).
    pub fn reference(dl: *DrawList, frame: usize) void {
        bg(dl, light);
        const s = scrolls[frame];
        if (s == @floor(s)) {
            dl.pushClip(viewport, .{});
            document(dl, 0, doc_h, viewport.x, viewport.y - s);
            dl.popClip();
            return;
        }
        const id: r2d.LayerId = @enumFromInt(9);
        if (dl.beginLayer(id, .{ .w = 80, .h = doc_h }, &.{})) {
            document(dl, 0, doc_h, 0, 0);
            dl.endLayer();
        }
        dl.drawLayer(id, viewport, .{ .y = s }, 1);
    }

    /// The scene frame (see `scrollLayerSeam`).
    pub fn layered(dl: *DrawList, frame: u8, image: r2d.TextureId, rnd: std.Random) void {
        var ctx: SceneCtx = .{ .frame = frame, .image = image, .rnd = rnd };
        scrollLayerSeam(dl, &ctx);
    }
};

fn scrollLayerSeam(dl: *DrawList, ctx: *SceneCtx) void {
    bg(dl, light);
    const id: r2d.LayerId = @enumFromInt(3);
    const top = seam.windowTop(ctx.frame);
    const origin: [2]i32 = .{ 0, @mod(top, @as(i32, seam.layer_size.h)) };
    var strips: [2]r2d.PxRect = undefined;
    const n = if (ctx.frame == 0) 0 else r2d.layers.scrollDamage(.{ 0, top - seam.windowTop(ctx.frame - 1) }, seam.layer_size, &strips);
    const full = [_]r2d.PxRect{.{ .x = 0, .y = 0, .w = seam.layer_size.w, .h = seam.layer_size.h }};
    const dmg: []const r2d.PxRect = if (ctx.frame == 0) &full else strips[0..n];
    if (dl.beginScrollLayer(id, seam.layer_size, origin, dmg)) {
        seam.document(dl, top, seam.layer_size.h, 0, 0);
        dl.endLayer();
    }
    dl.drawLayer(id, seam.viewport, .{ .y = seam.scrolls[ctx.frame] - @as(f32, @floatFromInt(top)) }, 1);
    if (ctx.frame > 0) dl.addDamage(.{ .x = 20, .y = 10, .w = 80, .h = 60 });
}

fn damageKeystroke(dl: *DrawList, ctx: *SceneCtx) void {
    bg(dl, light);
    const n: u32 = 6 + ctx.frame;
    var row: u32 = 0;
    while (row < 5) : (row += 1) {
        const len: u32 = if (row == 2) n else 12;
        text(dl, 4, @floatFromInt(4 + row * 14), len, 12, 7, page_gray, .r8, ink, .grayscale, row * 11);
    }
    dl.rect(.{ .x = 4 + @as(f32, @floatFromInt(n)) * 7, .y = 32, .w = 1, .h = 12 }, accent, .{});
    if (ctx.frame > 0) dl.addDamage(.{ .x = 4 + @as(i32, @intCast(n - 1)) * 7, .y = 32, .w = 16, .h = 12 });
}

fn hidpi2x(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.rect(.{ .x = 4, .y = 4, .w = 30, .h = 20 }, accent, Radii.all(4));
    dl.border(.{ .x = 38, .y = 4, .w = 22, .h = 20 }, Insets.all(0.5), ink, Radii.all(3));
    dl.shadow(.{ .x = 8, .y = 30, .w = 20, .h = 12 }, Radii.all(2), 2, 0, .{ .r = 0, .g = 0, .b = 0, .a = 120 });
    text(dl, 32, 30, 4, 7, 4.5, page_gray, .r8, ink, .grayscale, 3);
}

fn subpixelPositions(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const f: f32 = @as(f32, @floatFromInt(i)) * 0.125;
        dl.rect(.{ .x = 4 + f, .y = @as(f32, @floatFromInt(4 + i * 11)), .w = 40, .h = 8 + f }, ink, .{});
        dl.rect(.{ .x = 50 + f * 3, .y = @as(f32, @floatFromInt(4 + i * 11)) + f, .w = 9, .h = 9 }, accent, Radii.all(4.5));
        text(dl, 64 + f, @as(f32, @floatFromInt(4 + i * 11)) + f, 6, 9, 8, page_gray, .r8, ink, .grayscale, i);
    }
}

fn hugeRect(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.rect(.{ .x = -1e6, .y = 40, .w = 2e6, .h = 16 }, accent, .{});
    dl.rect(.{ .x = 60, .y = -1e6, .w = 8, .h = 2e6 }, ink, Radii.all(4));
    dl.border(.{ .x = -1e6, .y = -1e6, .w = 1e6 + 100, .h = 1e6 + 80 }, Insets.all(3), Color.fromHex("#e63946"), .{});
}

fn zeroSize(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    dl.rect(.{ .x = 10, .y = 10, .w = 0, .h = 20 }, ink, .{});
    dl.rect(.{ .x = 10, .y = 10, .w = 20, .h = -5 }, ink, .{});
    dl.border(.{ .x = 30, .y = 30, .w = 0, .h = 0 }, Insets.all(2), ink, .{});
    dl.shadow(.{ .x = 40, .y = 40, .w = 0, .h = 10 }, .{}, 0, 0, ink);
    dl.rect(.{ .x = 50, .y = 50, .w = 0.25, .h = 0.25 }, ink, .{});
    dl.pushClip(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, .{});
    dl.rect(.{ .x = 0, .y = 0, .w = 50, .h = 50 }, ink, .{});
    dl.popClip();
}

fn diffViewLike(dl: *DrawList, ctx: *SceneCtx) void {
    bg(dl, dark);
    const del = Color.fromHex("#3b1f24");
    const add = Color.fromHex("#1f3b2a");
    var row: u32 = 0;
    while (row < 12) : (row += 1) {
        const y: f32 = @floatFromInt(row * 12);
        if (row % 5 == 1) dl.rect(.{ .x = 0, .y = y, .w = 240, .h = 12 }, del, .{});
        if (row % 5 == 2 or row % 5 == 3) dl.rect(.{ .x = 0, .y = y, .w = 240, .h = 12 }, add, .{});
        if (row % 5 == 2) dl.rect(.{ .x = 60, .y = y, .w = 42, .h = 12 }, Color.fromHex("#2f6b44"), .{});
        const len = 10 + ctx.rnd.uintLessThan(u32, 20);
        text(dl, 18, y + 1, len, 10, 7, page_gray, .r8, Color.fromHex("#d0d4dc"), .grayscale, row * 13);
    }
}

fn agentTranscriptLike(dl: *DrawList, ctx: *SceneCtx) void {
    bg(dl, Color.fromHex("#f7f7f8"));
    var y: f32 = 6;
    var msg: u32 = 0;
    while (msg < 4) : (msg += 1) {
        const user = msg % 2 == 0;
        const lines: u32 = 1 + ctx.rnd.uintLessThan(u32, 3);
        const h: f32 = @as(f32, @floatFromInt(lines)) * 12 + 8;
        const x: f32 = if (user) 60 else 6;
        dl.shadow(.{ .x = x, .y = y, .w = 170, .h = h }, Radii.all(8), 2, 0, .{ .r = 0, .g = 0, .b = 0, .a = 40 });
        dl.rect(.{ .x = x, .y = y, .w = 170, .h = h }, if (user) Color.fromHex("#dbe7ff") else Color.white, Radii.all(8));
        var l: u32 = 0;
        while (l < lines) : (l += 1) text(dl, x + 6, y + 4 + @as(f32, @floatFromInt(l)) * 12, 22, 10, 7, page_gray, .r8, ink, .grayscale, msg * 50 + l * 7);
        y += h + 6;
    }
}

fn terminalGridLike(dl: *DrawList, ctx: *SceneCtx) void {
    bg(dl, Color.black);
    var row: u32 = 0;
    while (row < 12) : (row += 1) {
        var col: u32 = 0;
        while (col < 30) : (col += 1) {
            const x: f32 = @floatFromInt(col * 8);
            const y: f32 = @floatFromInt(row * 12);
            if (ctx.rnd.uintLessThan(u32, 6) == 0) dl.rect(.{ .x = x, .y = y, .w = 8, .h = 12 }, .{ .r = ctx.rnd.int(u8) / 2, .g = ctx.rnd.int(u8) / 2, .b = ctx.rnd.int(u8) / 2 }, .{});
            const q = [_]GlyphQuad{atlas.quad(row * 30 + col, x, y + 1, 10, page_gray, .r8)};
            dl.glyphs(&q, .{ .r = 180 + ctx.rnd.int(u8) / 4, .g = 200, .b = 180 }, .grayscale);
        }
    }
    dl.rect(.{ .x = 8 * 12, .y = 12 * 5, .w = 8, .h = 12 }, Color.fromHex("#e0e0e0"), .{});
}

fn textAaNone(dl: *DrawList, _: *SceneCtx) void {
    bg(dl, light);
    var row: u32 = 0;
    while (row < 4) : (row += 1) text(dl, 4, @floatFromInt(4 + row * 20), 10, 16, 11, page_gray, .r8, ink, .none, row * 9);
}

fn manyKinds(dl: *DrawList, ctx: *SceneCtx) void {
    // Every kind in one list, interleaved, inside a rounded clip.
    bg(dl, light);
    dl.pushClip(.{ .x = 2, .y = 2, .w = 124, .h = 92 }, Radii.all(10));
    dl.shadow(.{ .x = 10, .y = 10, .w = 50, .h = 30 }, Radii.all(6), 4, 0, .{ .r = 0, .g = 0, .b = 0, .a = 100 });
    dl.linearGradient(.{ .x = 10, .y = 10, .w = 50, .h = 30 }, .{ .x = 10, .y = 10 }, .{ .x = 60, .y = 40 }, accent, Color.fromHex("#9b5de5"), Radii.all(6));
    dl.border(.{ .x = 10, .y = 10, .w = 50, .h = 30 }, Insets.all(1), Color.white, Radii.all(6));
    text(dl, 14, 18, 5, 12, 8, page_gray, .r8, Color.white, .grayscale, 4);
    dl.image(ctx.image, .{ .x = 70, .y = 10, .w = 48, .h = 48 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.white, Radii.all(6));
    text(dl, 10, 60, 6, 16, 17, page_color, .rgba_color, Color.white, .grayscale, 30);
    dl.rect(.{ .x = 0, .y = 80, .w = 128, .h = 20 }, .{ .r = 0, .g = 0, .b = 0, .a = 60 }, .{});
    dl.popClip();
}

/// Every scene.
pub const all = [_]Scene{
    .{ .name = "rect_solid_grid", .size = sz(128, 96), .build = rectSolidGrid },
    .{ .name = "rounded_rect_radii_mix", .size = sz(128, 96), .build = roundedRadiiMix },
    .{ .name = "border_uneven_widths", .size = sz(128, 96), .build = borderUneven },
    .{ .name = "border_rounded", .size = sz(128, 96), .build = borderRounded },
    .{ .name = "shadow_small_large_sigma", .size = sz(128, 96), .build = shadowSigmas },
    .{ .name = "shadow_rounded_spread", .size = sz(128, 96), .build = shadowRoundedSpread },
    .{ .name = "gradient_linear_angles", .size = sz(128, 96), .build = gradientAngles },
    .{ .name = "clip_rect_nested", .size = sz(128, 96), .build = clipRectNested },
    .{ .name = "clip_rounded_nested", .size = sz(128, 96), .build = clipRoundedNested },
    .{ .name = "clip_cull_offscreen", .size = sz(128, 96), .build = clipCullOffscreen },
    .{ .name = "alpha_stack_premul", .size = sz(128, 96), .build = alphaStack },
    .{ .name = "text_gray_dark_on_light", .size = sz(128, 96), .build = textGrayDarkOnLight },
    .{ .name = "text_gray_light_on_dark", .size = sz(128, 96), .build = textGrayLightOnDark },
    .{ .name = "text_subpixel_rgb", .size = sz(128, 96), .build = textSubpixelRgb, .needs = .{ .dual_src = true } },
    .{ .name = "text_subpixel_bgr", .size = sz(128, 96), .build = textSubpixelBgr, .needs = .{ .dual_src = true } },
    .{ .name = "text_color_emoji", .size = sz(128, 96), .build = textColorEmoji },
    .{ .name = "text_tiny_9px", .size = sz(128, 104), .build = textTiny },
    .{ .name = "text_dense_editor", .size = sz(1280, 720), .build = textDenseEditor },
    .{ .name = "text_aa_none", .size = sz(128, 96), .build = textAaNone },
    .{ .name = "image_nearest_linear", .size = sz(128, 96), .build = imageNearestLinear },
    .{ .name = "image_rounded", .size = sz(128, 96), .build = imageRounded },
    .{ .name = "layer_plain_opacity", .size = sz(128, 96), .build = layerPlainOpacity, .needs = .{ .layers = true } },
    .{ .name = "scroll_layer_offsets", .size = sz(120, 90), .build = scrollLayerOffsets, .frames = 6, .needs = .{ .layers = true } },
    .{ .name = "scroll_layer_seam", .size = sz(120, 90), .build = scrollLayerSeam, .frames = seam.scrolls.len, .needs = .{ .layers = true } },
    .{ .name = "damage_keystroke", .size = sz(128, 80), .build = damageKeystroke, .frames = 3 },
    .{ .name = "hidpi_scale_2x", .size = sz(128, 96), .scale = 2, .build = hidpi2x },
    .{ .name = "subpixel_positions", .size = sz(128, 96), .build = subpixelPositions },
    .{ .name = "huge_rect_bounds", .size = sz(128, 96), .build = hugeRect },
    .{ .name = "zero_size_prims", .size = sz(64, 64), .build = zeroSize },
    .{ .name = "diff_view_like", .size = sz(240, 144), .build = diffViewLike },
    .{ .name = "agent_transcript_like", .size = sz(240, 160), .build = agentTranscriptLike },
    .{ .name = "terminal_grid_like", .size = sz(240, 144), .build = terminalGridLike },
    .{ .name = "many_kinds_rounded_clip", .size = sz(128, 96), .build = manyKinds },
};

test "scenes: names unique, sizes ≤ 1024×1024 except dense editor" {
    try std.testing.expect(all.len >= 30);
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        if (!std.mem.eql(u8, a.name, "text_dense_editor")) try std.testing.expect(a.size.w <= 1024 and a.size.h <= 1024);
    }
}
