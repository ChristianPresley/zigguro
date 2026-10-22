//! `Rasterizer`: turns outlines into bitmaps. One per worker thread; it
//! keeps its accumulator, path, outline scratch and output buffer between
//! calls, so a warm rasterizer does not allocate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const outline = @import("../outline/root.zig");
const Path = outline.Path;
const Affine = outline.Affine;
const ot = @import("../ot/root.zig");
const variation = ot.variation;
const coverage = @import("coverage.zig");
const flatten = @import("flatten.zig");
const embolden = @import("embolden.zig");
const lcd = @import("lcd.zig");
const sdf = @import("sdf.zig");
const bitmap_strikes = @import("bitmap_strikes.zig");

/// Largest bitmap side in pixels. Bigger requests fail with `TooLarge`;
/// callers use SDF or tiles instead.
pub const max_side = 1024;

/// Raster output. `pixels` belongs to the `Rasterizer` that produced it and
/// stays valid until its next call; copy it (into the atlas) before then.
pub const Bitmap = struct {
    width: u16 = 0,
    height: u16 = 0,
    stride: u32 = 0,
    /// Pen origin to the bitmap's top-left pixel corner, in pixels, y down.
    left: i16 = 0,
    top: i16 = 0,
    format: Format = .gray8,
    pixels: []u8 = &.{},

    /// Pixel layout.
    pub const Format = enum(u8) { gray8, lcd_rgb8x3, sdf8, rgba8_premul };

    /// True for a bitmap with no pixels (space, empty or invalid outline).
    pub fn isEmpty(b: Bitmap) bool {
        return b.width == 0 or b.height == 0;
    }

    /// The pixel row `y`.
    pub fn row(b: Bitmap, y: usize) []u8 {
        const bpp: usize = switch (b.format) {
            .gray8, .sdf8 => 1,
            .lcd_rgb8x3 => 3,
            .rgba8_premul => 4,
        };
        return b.pixels[y * b.stride ..][0 .. @as(usize, b.width) * bpp];
    }
};

/// How to rasterize.
pub const RasterParams = struct {
    /// Pixels per em, DPI scale included.
    px_per_em: f32,
    /// Horizontal pen offset within the pixel: 0, .25, .5 or .75.
    subpixel_x: f32 = 0,
    mode: Mode = .gray,
    synth_bold: bool = false,
    synth_oblique: bool = false,
    stem_darkening: bool = false,
    sdf_spread_px: f32 = 4,
    /// Use the face's colour data for this glyph when it has some (bitmap
    /// strikes; output `rgba8_premul`). A corrupt image falls back to the
    /// outline. `mode` and the synthetic styles apply only to outlines.
    color: bool = false,

    /// Output kind.
    pub const Mode = enum { gray, lcd_rgb, lcd_bgr, sdf };
};

/// Errors from rasterizing.
pub const Error = error{ TooLarge, Unsupported, Malformed, LimitExceeded, OutOfMemory };

/// Pixel-grid placement of a transformed outline.
pub const Placement = struct {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
};

/// The integer pixel box of `bounds` (pixel space), or null when it is
/// empty or not finite. `left`/`top` are floors, so the baseline stays on
/// the pixel grid.
pub fn place(bounds: outline.Rect) ?Placement {
    if (bounds.isEmpty()) return null;
    if (!(std.math.isFinite(bounds.x0) and std.math.isFinite(bounds.x1) and
        std.math.isFinite(bounds.y0) and std.math.isFinite(bounds.y1))) return null;
    // Far outside i32 is as good as infinite here.
    const lim: f32 = 1 << 24;
    if (@abs(bounds.x0) > lim or @abs(bounds.x1) > lim or @abs(bounds.y0) > lim or @abs(bounds.y1) > lim) return null;
    const left: i32 = @intFromFloat(@floor(bounds.x0));
    const top: i32 = @intFromFloat(@floor(bounds.y0));
    const right: i32 = @intFromFloat(@ceil(bounds.x1));
    const bottom: i32 = @intFromFloat(@ceil(bounds.y1));
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

/// The font-units-to-pixels map: scale, y flip and subpixel offset, then
/// the optional synthetic oblique shear (applied in font units).
pub fn pixelTransform(units_per_em: f32, p: RasterParams) Affine {
    const s = p.px_per_em / units_per_em;
    var m: Affine = .{ .xx = s, .yy = -s, .dx = p.subpixel_x };
    if (p.synth_oblique) m.xy = s * oblique_tan;
    return m;
}

/// tan(12°), the synthetic oblique slant.
pub const oblique_tan: f32 = 0.21255656;

/// A path's control box after `m`, computed without touching the path.
/// Any NaN or infinite point makes the whole box NaN (so `place` rejects
/// it), because `@min`/`@max` would otherwise skip NaN silently.
pub fn transformedBounds(path: *const Path, m: Affine) outline.Rect {
    var b: outline.Rect = .empty;
    for (path.points.items) |pt| {
        const q = m.apply(pt);
        if (!(std.math.isFinite(q[0]) and std.math.isFinite(q[1]))) {
            const nan = std.math.nan(f32);
            return .{ .x0 = nan, .y0 = nan, .x1 = nan, .y1 = nan };
        }
        b = b.include(q[0], q[1]);
    }
    return b;
}

/// Feeds every segment of `path`, mapped by `m` and then shifted by
/// (-left, -top), into `sink.segment(a, b)` with curves flattened to
/// `tol` pixels. Open contours are closed, as the fill rule requires.
pub fn walk(path: *const Path, m: Affine, origin: [2]f32, tol: f32, sink: anytype) void {
    const mm: Affine = .{ .xx = m.xx, .xy = m.xy, .yx = m.yx, .yy = m.yy, .dx = m.dx - origin[0], .dy = m.dy - origin[1] };
    const pts = path.points.items;
    var i: usize = 0;
    var start: [2]f32 = .{ 0, 0 };
    var cur: [2]f32 = .{ 0, 0 };
    var open = false;
    for (path.verbs.items) |v| switch (v) {
        .move => {
            if (open) sink.segment(cur, start);
            start = mm.apply(pts[i]);
            cur = start;
            open = true;
            i += 1;
        },
        .line => {
            const q = mm.apply(pts[i]);
            sink.segment(cur, q);
            cur = q;
            i += 1;
        },
        .quad => {
            const c = mm.apply(pts[i]);
            const q = mm.apply(pts[i + 1]);
            flatten.quadTo(sink, cur, c, q, tol);
            cur = q;
            i += 2;
        },
        .cubic => {
            const c1 = mm.apply(pts[i]);
            const c2 = mm.apply(pts[i + 1]);
            const q = mm.apply(pts[i + 2]);
            flatten.cubicTo(sink, cur, c1, c2, q, tol);
            cur = q;
            i += 3;
        },
        .close => {
            if (open) sink.segment(cur, start);
            cur = start;
            open = false;
        },
    };
    if (open) sink.segment(cur, start);
}

/// One per worker thread.
pub const Rasterizer = struct {
    gpa: Allocator,
    acc: coverage.Accumulator = .{},
    path: Path = .{},
    scratch: variation.OutlineScratch = .{},
    out: std.ArrayList(u8) = .empty,
    /// Emboldened copy of a caller's path.
    work: Path = .{},
    /// 3× coverage before the LCD filter; the sign mask for SDF.
    sub: std.ArrayList(u8) = .empty,
    /// SDF segment list and its grid buckets.
    segs: std.ArrayList([2][2]f32) = .empty,
    cell_start: std.ArrayList(u32) = .empty,
    cell_items: std.ArrayList(u32) = .empty,
    /// Float scratch for colour glyph resampling and compositing.
    fbuf: std.ArrayList(f32) = .empty,
    /// Decoded bitmap-strike PNGs.
    strikes: bitmap_strikes.StrikeCache = .{},

    /// A rasterizer with empty buffers.
    pub fn init(gpa: Allocator) Rasterizer {
        return .{ .gpa = gpa };
    }

    /// Frees every buffer.
    pub fn deinit(r: *Rasterizer) void {
        r.acc.deinit(r.gpa);
        r.path.deinit(r.gpa);
        r.scratch.deinit(r.gpa);
        r.out.deinit(r.gpa);
        r.work.deinit(r.gpa);
        r.sub.deinit(r.gpa);
        r.segs.deinit(r.gpa);
        r.cell_start.deinit(r.gpa);
        r.cell_items.deinit(r.gpa);
        r.fbuf.deinit(r.gpa);
        r.strikes.deinit(r.gpa);
    }

    /// Rasterizes `path` (font units, y up) at `p`. An empty or non-finite
    /// outline gives an empty bitmap.
    pub fn rasterizePath(r: *Rasterizer, path: *const Path, units_per_em: u16, p: RasterParams) Error!Bitmap {
        if (units_per_em == 0) return error.Malformed;
        return r.rasterizeMapped(path, pixelTransform(@floatFromInt(units_per_em), p), p);
    }

    /// Rasterizes `gid` of `inst`: from a bitmap strike when `p.color` is
    /// set and the face has one for the glyph, else from its outline.
    pub fn rasterizeGlyph(r: *Rasterizer, inst: *const variation.FaceInstance, gid: ot.GlyphId, p: RasterParams) Error!Bitmap {
        if (p.color) {
            const strike = ot.cbdt.cbdtGlyph(inst.face, gid, p.px_per_em) orelse ot.sbix.sbixGlyph(inst.face, gid, p.px_per_em);
            if (strike) |g| {
                if (bitmap_strikes.renderStrike(r, g, p.px_per_em, &r.strikes)) |bm| {
                    return bm;
                } else |e| switch (e) {
                    error.Malformed, error.Unsupported => {}, // outline fallback
                    else => return e,
                }
            }
        }
        r.path.reset();
        try inst.outline(r.gpa, gid, &r.scratch, &r.path);
        const upem: f32 = @floatFromInt(inst.face.units_per_em);
        if (upem == 0) return error.Malformed;
        var m = pixelTransform(upem, p);
        if (inst.cff) |*c| {
            // Charstring units to font units through FontMatrix (the usual
            // 0.001 matrix with a 1000-unit em is the identity).
            const fm = c.fontMatrix();
            m = m.mul(.{ .xx = fm.xx * upem, .xy = fm.xy * upem, .yx = fm.yx * upem, .yy = fm.yy * upem, .dx = fm.dx * upem, .dy = fm.dy * upem });
        }
        return r.rasterizeMapped(&r.path, m, p);
    }

    fn rasterizeMapped(r: *Rasterizer, path_in: *const Path, m: Affine, p: RasterParams) Error!Bitmap {
        const path = try r.emboldened(path_in, m, p);
        if (p.mode == .sdf) return sdf.generateMapped(r, path, m, p.sdf_spread_px);
        if (p.mode == .gray) {
            const pl = place(transformedBounds(path, m)) orelse return .{};
            if (pl.width > max_side or pl.height > max_side) return error.TooLarge;
            try r.acc.reset(r.gpa, pl.width, pl.height);
            walk(path, m, .{ @floatFromInt(pl.left), @floatFromInt(pl.top) }, flatten.tol_gray, &r.acc);
            const px = try r.outputBuffer(pl.width * pl.height);
            r.acc.integrate(px, pl.width);
            return bitmapOf(pl, pl.width, .gray8, px);
        }
        // LCD: x at 3×, padded by the filter's reach, with the left edge on
        // a whole pixel so every 3 subpixels make one pixel.
        var m3 = m;
        m3.xx *= 3;
        m3.xy *= 3;
        m3.dx *= 3;
        const b3 = transformedBounds(path, m3);
        const pad: f32 = lcd.pad_subpixels;
        var b = b3;
        b.x0 = (b3.x0 - pad) / 3;
        b.x1 = (b3.x1 + pad) / 3;
        const pl = place(b) orelse return .{};
        if (pl.width > max_side or pl.height > max_side) return error.TooLarge;
        const w3 = pl.width * 3;
        try r.acc.reset(r.gpa, w3, pl.height);
        walk(path, m3, .{ @floatFromInt(pl.left * 3), @floatFromInt(pl.top) }, flatten.tol_gray, &r.acc);
        r.sub.clearRetainingCapacity();
        try r.sub.ensureTotalCapacity(r.gpa, w3 * pl.height);
        r.sub.items.len = w3 * pl.height;
        r.acc.integrate(r.sub.items, w3);
        const px = try r.outputBuffer(w3 * pl.height);
        lcd.filter(r.sub.items, w3, pl.height, w3, if (p.mode == .lcd_bgr) .bgr else .rgb, px, w3);
        return bitmapOf(pl, w3, .lcd_rgb8x3, px);
    }

    /// `path`, or a copy in `work` grown by synthetic bold and stem
    /// darkening (amounts in pixels, converted through the vertical scale
    /// of `m`, which the oblique shear leaves alone).
    fn emboldened(r: *Rasterizer, path: *const Path, m: Affine, p: RasterParams) Error!*const Path {
        const s = @abs(m.yy);
        if (!(s > 0)) return path;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (p.synth_bold) dx += p.px_per_em / 48 / s;
        if (p.stem_darkening) {
            const a = embolden.stem_darkening_max_px * std.math.clamp((24 - p.px_per_em) / 15, 0, 1) / s;
            dx += a;
            dy += a;
        }
        if (dx == 0 and dy == 0) return path;
        if (path != &r.work) {
            r.work.reset();
            try r.work.ensureUnused(r.gpa, path.verbs.items.len, path.points.items.len);
            r.work.verbs.appendSliceAssumeCapacity(path.verbs.items);
            r.work.points.appendSliceAssumeCapacity(path.points.items);
            r.work.bounds = path.bounds;
        }
        embolden.embolden(&r.work, dx, dy);
        return &r.work;
    }

    /// The output buffer resized to `n` bytes (valid until the next call).
    pub fn outputBuffer(r: *Rasterizer, n: usize) Allocator.Error![]u8 {
        r.out.clearRetainingCapacity();
        try r.out.ensureTotalCapacity(r.gpa, n);
        r.out.items.len = n;
        return r.out.items;
    }

    /// A `Bitmap` over `px` at placement `pl`.
    pub fn bitmapOf(pl: Placement, stride: u32, format: Bitmap.Format, px: []u8) Error!Bitmap {
        return .{
            .width = @intCast(pl.width),
            .height = @intCast(pl.height),
            .stride = stride,
            .left = std.math.cast(i16, pl.left) orelse return error.TooLarge,
            .top = std.math.cast(i16, pl.top) orelse return error.TooLarge,
            .format = format,
            .pixels = px,
        };
    }
};
