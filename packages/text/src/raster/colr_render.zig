//! COLR colour glyph rendering to premultiplied RGBA.
//!
//! The canvas is the glyph's clip box (or, without one, the bounds of every
//! outline its paint graph draws through; a graph that paints outside any
//! outline has no bounds and is refused), scaled to pixels and placed on
//! the pen origin like a gray glyph. Paints are evaluated recursively with
//! a current transform (glyph units to canvas pixels) and a current clip,
//! which is a coverage mask with a pixel box:
//!
//! - PaintGlyph rasterizes the outline through the current transform and
//!   multiplies it into the clip (as an anti-aliased clip path does).
//! - Solid and gradient leaves draw source-over into the current layer,
//!   weighted by the clip; gradients map each pixel centre back to glyph
//!   space with the inverse transform.
//! - PaintComposite draws backdrop and source into two temporary layers
//!   without the current clip's coverage, blends source onto backdrop with
//!   the mode, and draws the result onto the layer source-over weighted by
//!   the clip.
//!
//! Colours are sRGB-encoded and premultiplied throughout, with gradients
//! interpolating premultiplied colours (see `gradient.zig`); the text
//! colour comes in linear light and is encoded once. Layers are f32 and
//! pooled in the rasterizer; output is rounded to 8 bits once at the end.
//!
//! Limits: paint nesting ≤ 64, at most `max_paints` paints per glyph, 8
//! temporary layers and 16 clip masks; a cycle through PaintColrLayers or
//! PaintColrGlyph is `Malformed`. A canvas over 512 px a side renders at a
//! smaller size (the bitmap is then smaller than asked).

const std = @import("std");
const Allocator = std.mem.Allocator;
const outline = @import("../outline/root.zig");
const Path = outline.Path;
const Affine = outline.Affine;
const Rect = outline.Rect;
const ot = @import("../ot/root.zig");
const Colr = ot.colr.Colr;
const variation = ot.variation;
const rz = @import("rasterizer.zig");
const Rasterizer = rz.Rasterizer;
const Bitmap = rz.Bitmap;
const Error = rz.Error;
const flatten = @import("flatten.zig");
const nonzero = @import("nonzero.zig");
const gradient = @import("gradient.zig");
const compose = @import("compose.zig");

const V = gradient.V;

/// What to draw a colour glyph with.
pub const ColorRenderParams = struct {
    /// Pixels per em, DPI scale included.
    px_per_em: f32,
    /// Horizontal pen offset within the pixel.
    subpixel_x: f32 = 0,
    /// Requested CPAL palette.
    palette: u16 = 0,
    /// The text colour, linear-light premultiplied RGBA.
    fg: [4]f32 = .{ 0, 0, 0, 1 },
    /// Prefer a palette marked for dark backgrounds.
    dark_bg: bool = false,
};

/// Deepest paint nesting.
pub const max_depth = 64;
/// Temporary layers (two per nested PaintComposite).
pub const max_layers = 8;
/// Clip masks (one per nested PaintGlyph or clip box).
pub const max_masks = 16;
/// Largest canvas side in pixels.
pub const max_canvas = 512;
/// Curve flattening tolerance in pixels. Finer than gray glyphs' 0.2: a
/// colour glyph stacks many outlines, and a chord that sags into a layer
/// below lets its colour show through where a layer covers it fully.
const flatten_tol: f32 = 0.05;

/// Most paints evaluated for one glyph (bounds walk and drawing each).
pub const max_paints = 1 << 14;

/// Cycle-stack entry of a PaintColrGlyph target. Paint offsets stay below
/// this bit (`Colr.init` refuses tables of 2 GiB or more).
const glyph_tag: u32 = 0x8000_0000;

/// Buffers kept by the rasterizer between colour glyphs.
pub const Scratch = struct {
    layers: [max_layers]std.ArrayList(f32) = @splat(.empty),
    masks: [max_masks]std.ArrayList(f32) = @splat(.empty),
    stops: std.ArrayList(gradient.Stop) = .empty,
    /// One outline's coverage before it joins the clip.
    local: std.ArrayList(f32) = .empty,
    nonzero: nonzero.Scratch = .{},

    /// Frees every buffer.
    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        for (&s.layers) |*l| l.deinit(gpa);
        for (&s.masks) |*m| m.deinit(gpa);
        s.stops.deinit(gpa);
        s.local.deinit(gpa);
        s.nonzero.deinit(gpa);
        s.* = .{};
    }
};

/// The current clip: coverage per canvas pixel (null for full coverage)
/// over the pixel box [x0, x1) × [y0, y1), zero outside it.
const Clip = struct {
    cov: ?[]const f32 = null,
    /// Set when `cov` is exactly this pixel-space rectangle: outlines
    /// clipped by it are then cut geometrically, so an edge they share
    /// with it is not anti-aliased twice.
    rect: ?Rect = null,
    x0: u32 = 0,
    y0: u32 = 0,
    x1: u32 = 0,
    y1: u32 = 0,

    fn isEmpty(c: Clip) bool {
        return c.x0 >= c.x1 or c.y0 >= c.y1;
    }
};

const Ctx = struct {
    r: *Rasterizer,
    inst: *const variation.FaceInstance,
    colr: *const Colr,
    coords: variation.VarCoords,
    palette: u16,
    /// The text colour, straight sRGB-encoded RGBA.
    fg: [4]f32,
    /// Charstring units to font units.
    outline_m: Affine,
    w: u32 = 0,
    h: u32 = 0,
    paints: u32 = 0,
    /// PaintColrLayers offsets and PaintColrGlyph targets (`glyph_tag | gid`)
    /// being drawn.
    stack: [max_depth]u32 = undefined,
    stack_len: u32 = 0,
    layers_used: u32 = 0,
    masks_used: u32 = 0,

    fn count(c: *Ctx, depth: u32) Error!void {
        c.paints += 1;
        if (c.paints > max_paints or depth >= max_depth) return error.LimitExceeded;
    }

    fn push(c: *Ctx, off: u32) Error!void {
        for (c.stack[0..c.stack_len]) |o| if (o == off) return error.Malformed;
        if (c.stack_len == max_depth) return error.LimitExceeded;
        c.stack[c.stack_len] = off;
        c.stack_len += 1;
    }

    fn pop(c: *Ctx) void {
        c.stack_len -= 1;
    }

    /// The next free layer, zeroed inside `clip`'s box.
    fn layer(c: *Ctx, clip: Clip) Error![]f32 {
        if (c.layers_used == max_layers) return error.LimitExceeded;
        const l = &c.r.colr.layers[c.layers_used];
        try l.resize(c.r.gpa, @as(usize, c.w) * c.h * 4);
        c.layers_used += 1;
        for (clip.y0..clip.y1) |y| @memset(l.items[(y * c.w + clip.x0) * 4 .. (y * c.w + clip.x1) * 4], 0);
        return l.items;
    }

    fn mask(c: *Ctx) Error![]f32 {
        if (c.masks_used == max_masks) return error.LimitExceeded;
        const m = &c.r.colr.masks[c.masks_used];
        try m.resize(c.r.gpa, @as(usize, c.w) * c.h);
        c.masks_used += 1;
        return m.items;
    }

    /// Releases the mask of a clip made by `pathClip` (if it made one).
    fn release(c: *Ctx, clip: Clip) void {
        if (clip.cov != null) c.masks_used -= 1;
    }

    /// Straight sRGB colour of palette entry `index` with `alpha` applied.
    fn colorOf(c: *const Ctx, index: u16, alpha: f32) [4]f32 {
        var col = c.fg;
        if (index != ot.colr.foreground_index) if (c.colr.cpal) |*p| if (p.color(c.palette, index)) |rgba| {
            col = .{ @floatFromInt(rgba[0]), @floatFromInt(rgba[1]), @floatFromInt(rgba[2]), @floatFromInt(rgba[3]) };
            col = .{ col[0] / 255, col[1] / 255, col[2] / 255, col[3] / 255 };
        };
        col[3] *= std.math.clamp(alpha, 0, 1);
        return col;
    }

    /// The outline of `gid` (into the rasterizer's path).
    fn loadOutline(c: *Ctx, gid: ot.GlyphId) Error!*const Path {
        c.r.path.reset();
        try c.inst.outline(c.r.gpa, gid, &c.r.scratch, &c.r.path);
        return &c.r.path;
    }

    /// Canvas-pixel bounds of everything `off` draws, or `Unsupported`
    /// when it paints outside every outline.
    fn bounds(c: *Ctx, off: u32, m: Affine, depth: u32) Error!Rect {
        try c.count(depth);
        const p = c.colr.paint(off, c.coords) catch return error.Malformed;
        switch (p) {
            .layers => |l| {
                try c.push(off);
                defer c.pop();
                var b: Rect = .empty;
                for (0..l.count) |i| {
                    const child = c.colr.layerPaint(l.first +| @as(u32, @intCast(i))) orelse return error.Malformed;
                    b = b.unite(try c.bounds(child, m, depth + 1));
                }
                return b;
            },
            .solid, .linear, .radial, .sweep => return error.Unsupported,
            .glyph => |g| return rz.transformedBounds(try c.loadOutline(g.gid), m.mul(c.outline_m)),
            .colr_glyph => |gid| {
                const root = c.colr.v1Paint(gid) orelse return error.Malformed;
                try c.push(glyph_tag | @as(u32, gid));
                defer c.pop();
                if (c.colr.clipBox(gid, c.coords)) |cb| return rectBounds(cb, m);
                return c.bounds(root, m, depth + 1);
            },
            .transform => |t| return c.bounds(t.child, m.mul(t.m), depth + 1),
            .composite => |k| return (try c.bounds(k.source, m, depth + 1)).unite(try c.bounds(k.backdrop, m, depth + 1)),
        }
    }

    /// `parent` narrowed to the coverage of `path` through `m`.
    fn pathClip(c: *Ctx, path: *const Path, m: Affine, parent: Clip) Error!Clip {
        var b = rz.transformedBounds(path, m);
        if (b.isEmpty() or !std.math.isFinite(b.x0 + b.x1 + b.y0 + b.y1)) return .{};
        if (parent.rect) |pr| b = .{ .x0 = @max(b.x0, pr.x0), .y0 = @max(b.y0, pr.y0), .x1 = @min(b.x1, pr.x1), .y1 = @min(b.y1, pr.y1) };
        const fx0 = @max(@floor(b.x0), @as(f32, @floatFromInt(parent.x0)));
        const fy0 = @max(@floor(b.y0), @as(f32, @floatFromInt(parent.y0)));
        const fx1 = @min(@ceil(b.x1), @as(f32, @floatFromInt(parent.x1)));
        const fy1 = @min(@ceil(b.y1), @as(f32, @floatFromInt(parent.y1)));
        if (!(fx0 < fx1 and fy0 < fy1)) return .{};
        const out: Clip = .{ .x0 = @intFromFloat(fx0), .y0 = @intFromFloat(fy0), .x1 = @intFromFloat(fx1), .y1 = @intFromFloat(fy1) };
        const bw = out.x1 - out.x0;
        const bh = out.y1 - out.y0;
        const acc = &c.r.acc;
        try acc.reset(c.r.gpa, bw, bh);
        // Several contours may overlap or meet with opposite windings,
        // which the accumulator gets wrong; see nonzero.zig.
        var contours: usize = 0;
        for (path.verbs.items) |v| contours += @intFromBool(v == .move);
        const nz = &c.r.colr.nonzero;
        nz.segs.clearRetainingCapacity();
        var sink: nonzero.Sink = .{ .acc = acc, .segs = if (contours > 1) &nz.segs else null, .gpa = c.r.gpa, .x_hi = @floatFromInt(bw), .y_hi = @floatFromInt(bh) };
        if (parent.rect) |pr| {
            sink.x_lo = @max(0, pr.x0 - fx0);
            sink.x_hi = @min(sink.x_hi, pr.x1 - fx0);
            sink.y_lo = @max(0, pr.y0 - fy0);
            sink.y_hi = @min(sink.y_hi, pr.y1 - fy0);
        }
        rz.walk(path, m, .{ fx0, fy0 }, flatten_tol, &sink);
        if (sink.oom) return error.OutOfMemory;
        const local = &c.r.colr.local;
        try local.resize(c.r.gpa, @as(usize, bw) * bh);
        for (0..bh) |y| {
            const row = acc.buf[y * acc.stride ..][0..bw];
            var sum: f32 = 0;
            for (row, local.items[y * bw ..][0..bw]) |a, *o| {
                sum += a;
                o.* = @min(@abs(sum), 1);
            }
        }
        if (contours > 1) {
            try nz.cov.resize(c.r.gpa, @as(usize, bw) * bh);
            try nonzero.supersample(c.r.gpa, nz, nz.segs.items, bw, bh, nz.cov.items);
            nonzero.fixUp(local.items, nz.cov.items);
        }
        const cov = try c.mask();
        const pcov = if (parent.rect != null) null else parent.cov;
        for (out.y0..out.y1) |y| {
            const src = local.items[(y - out.y0) * bw ..][0..bw];
            for (src, out.x0..) |k, x| cov[y * c.w + x] = if (pcov) |pc| k * pc[y * c.w + x] else k;
        }
        var res = out;
        res.cov = cov;
        return res;
    }

    fn glyphClip(c: *Ctx, gid: ot.GlyphId, m: Affine, parent: Clip) Error!Clip {
        return c.pathClip(try c.loadOutline(gid), m.mul(c.outline_m), parent);
    }

    fn rectClip(c: *Ctx, box: Rect, m: Affine, parent: Clip) Error!Clip {
        const p = &c.r.work;
        p.reset();
        try p.ensureUnused(c.r.gpa, 6, 4);
        p.moveToAssume(box.x0, box.y0);
        p.lineToAssume(box.x0, box.y1);
        p.lineToAssume(box.x1, box.y1);
        p.lineToAssume(box.x1, box.y0);
        p.closeAssume();
        var res = try c.pathClip(p, m, parent);
        // Axis-aligned in pixels and not cut by anything but rectangles:
        // the clip is exactly a rectangle.
        if (!res.isEmpty() and m.xy == 0 and m.yx == 0 and (parent.cov == null or parent.rect != null)) {
            var r = rectBounds(box, m);
            if (parent.rect) |pr| r = .{ .x0 = @max(r.x0, pr.x0), .y0 = @max(r.y0, pr.y0), .x1 = @min(r.x1, pr.x1), .y1 = @min(r.y1, pr.y1) };
            res.rect = r;
        }
        return res;
    }

    fn draw(c: *Ctx, off: u32, m: Affine, dst: []f32, clip: Clip, depth: u32) Error!void {
        try c.count(depth);
        const p = c.colr.paint(off, c.coords) catch return error.Malformed;
        switch (p) {
            .layers => |l| {
                try c.push(off);
                defer c.pop();
                for (0..l.count) |i| {
                    const child = c.colr.layerPaint(l.first +| @as(u32, @intCast(i))) orelse return error.Malformed;
                    try c.draw(child, m, dst, clip, depth + 1);
                }
            },
            .solid => |s| fill(c, dst, clip, m, Solid{ .c = premul(c.colorOf(s.palette, s.alpha)) }),
            .linear => |g| {
                const stops, const range = try c.colorStops(g.line);
                if (stops.len == 0) return;
                const p1 = gradient.linearAxis(g.p0, g.p1, g.p2);
                if (gradient.linearT(g.p0, p1, g.p0) == null) return;
                fill(c, dst, clip, m, Linear{ .stops = stops, .extend = g.line.extend, .p0 = g.p0, .p1 = p1, .lo = range[0], .span = range[1] - range[0] });
            },
            .radial => |g| {
                const stops, const range = try c.colorStops(g.line);
                if (stops.len == 0) return;
                fill(c, dst, clip, m, Radial{ .stops = stops, .extend = g.line.extend, .g = .init(g.c0, g.r0, g.c1, g.r1), .lo = range[0], .span = range[1] - range[0] });
            },
            .sweep => |g| {
                const stops, const range = try c.colorStops(g.line);
                if (stops.len == 0) return;
                const coincident_stops = stops[0].t == stops[stops.len - 1].t;
                if (coincident_stops and g.line.extend != .pad) return;
                const start = g.start_deg + range[0] * (g.end_deg - g.start_deg);
                const end = g.start_deg + range[1] * (g.end_deg - g.start_deg);
                if (@abs(end - start) < 1e-6) {
                    if (g.line.extend != .pad) return;
                    fill(c, dst, clip, m, SweepStep{ .center = g.center, .angle = @mod(start, 360), .before = stops[0].c, .after = stops[stops.len - 1].c });
                    return;
                }
                fill(c, dst, clip, m, Sweep{ .stops = stops, .extend = g.line.extend, .center = g.center, .start = start, .span = end - start });
            },
            .glyph => |g| {
                const sub = try c.glyphClip(g.gid, m, clip);
                defer c.release(sub);
                if (!sub.isEmpty()) try c.draw(g.child, m, dst, sub, depth + 1);
            },
            .colr_glyph => |gid| {
                const root = c.colr.v1Paint(gid) orelse return error.Malformed;
                try c.push(glyph_tag | @as(u32, gid));
                defer c.pop();
                const box = c.colr.clipBox(gid, c.coords);
                const sub = if (box) |cb| try c.rectClip(cb, m, clip) else clip;
                defer if (box != null) c.release(sub);
                if (!sub.isEmpty()) try c.draw(root, m, dst, sub, depth + 1);
            },
            .transform => |t| try c.draw(t.child, m.mul(t.m), dst, clip, depth + 1),
            .composite => |k| {
                // Source and backdrop are drawn unclipped (within the clip's
                // pixel box), blended, and the result clipped once: an edge
                // pixel then gets coverage × blend(source, backdrop), the
                // mean of its inside and outside parts. A rectangle clip is
                // instead cut into the children's outlines exactly (an
                // outline that coincides with it is then not anti-aliased
                // twice) and not applied again.
                var open = clip;
                if (clip.rect == null) open.cov = null;
                const final_cov = if (clip.rect == null) clip.cov else null;
                const back = try c.layer(open);
                defer c.layers_used -= 1;
                try c.draw(k.backdrop, m, back, open, depth + 1);
                const src = try c.layer(open);
                defer c.layers_used -= 1;
                try c.draw(k.source, m, src, open, depth + 1);
                compose.blendLayers(k.mode, src, back, null, c.w, clip.x0, clip.y0, clip.x1, clip.y1);
                compose.blendLayers(.src_over, back, dst, final_cov, c.w, clip.x0, clip.y0, clip.x1, clip.y1);
            },
        }
    }

    /// The colour line's stops, sorted and normalized, with the original
    /// offset range. Stop colours are quantized to 8 bits per channel, as
    /// the reference renderers pass them.
    fn colorStops(c: *Ctx, line: ot.colr.ColorLine) Error!struct { []gradient.Stop, [2]f32 } {
        const list = &c.r.colr.stops;
        try list.resize(c.r.gpa, line.count);
        for (list.items, 0..) |*s, i| {
            const cs = c.colr.stop(line, i, c.coords);
            var col = c.colorOf(cs.palette, cs.alpha);
            for (&col) |*v| v.* = @round(std.math.clamp(v.*, 0, 1) * 255) / 255;
            s.* = .{ .t = cs.offset, .c = premul(col) };
        }
        const range = gradient.normalize(list.items);
        return .{ list.items, range };
    }
};

fn premul(c: [4]f32) V {
    const a = std.math.clamp(c[3], 0, 1);
    return .{ c[0] * a, c[1] * a, c[2] * a, a };
}

/// The canvas-pixel box of `r` (font units) through `m`.
fn rectBounds(r: Rect, m: Affine) Rect {
    var b: Rect = .empty;
    for ([_][2]f32{ .{ r.x0, r.y0 }, .{ r.x0, r.y1 }, .{ r.x1, r.y0 }, .{ r.x1, r.y1 } }) |pt| {
        const q = m.apply(pt);
        b = b.include(q[0], q[1]);
    }
    return b;
}

/// The inverse of `m`, or null when it is singular.
fn invert(m: Affine) ?Affine {
    const det = m.xx * m.yy - m.xy * m.yx;
    if (!(@abs(det) > 1e-12) or !std.math.isFinite(det)) return null;
    const i = 1 / det;
    return .{
        .xx = m.yy * i,
        .xy = -m.xy * i,
        .yx = -m.yx * i,
        .yy = m.xx * i,
        .dx = (m.xy * m.dy - m.yy * m.dx) * i,
        .dy = (m.yx * m.dx - m.xx * m.dy) * i,
    };
}

const Solid = struct {
    c: V,
    const constant = true;
    inline fn at(s: Solid, _: [2]f32) ?V {
        return s.c;
    }
};

const Linear = struct {
    stops: []const gradient.Stop,
    extend: ot.colr.Extend,
    p0: [2]f32,
    p1: [2]f32,
    lo: f32,
    span: f32,
    const constant = false;
    inline fn at(g: Linear, p: [2]f32) ?V {
        const t = gradient.linearT(g.p0, g.p1, p) orelse return null;
        return gradient.sample(g.stops, gradient.applyExtend(g.extend, (t - g.lo) / g.span));
    }
};

const Radial = struct {
    stops: []const gradient.Stop,
    extend: ot.colr.Extend,
    g: gradient.Radial,
    lo: f32,
    span: f32,
    const constant = false;
    inline fn at(g: Radial, p: [2]f32) ?V {
        const t = g.g.t(p) orelse return null;
        return gradient.sample(g.stops, gradient.applyExtend(g.extend, (t - g.lo) / g.span));
    }
};

const Sweep = struct {
    stops: []const gradient.Stop,
    extend: ot.colr.Extend,
    center: [2]f32,
    start: f32,
    span: f32,
    const constant = false;
    inline fn at(g: Sweep, p: [2]f32) ?V {
        const t = (gradient.sweepAngle(g.center, p) - g.start) / g.span;
        return gradient.sample(g.stops, gradient.applyExtend(g.extend, t));
    }
};

/// A sweep whose start and end angles coincide (pad): one colour before
/// the angle, the other from it on.
const SweepStep = struct {
    center: [2]f32,
    angle: f32,
    before: V,
    after: V,
    const constant = false;
    inline fn at(g: SweepStep, p: [2]f32) ?V {
        return if (gradient.sweepAngle(g.center, p) < g.angle) g.before else g.after;
    }
};

/// Draws `shader` source-over into `dst` inside `clip`, weighted by it.
fn fill(c: *const Ctx, dst: []f32, clip: Clip, m: Affine, shader: anytype) void {
    const inv = invert(m) orelse return;
    for (clip.y0..clip.y1) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        for (clip.x0..clip.x1) |x| {
            const i = y * c.w + x;
            const k = if (clip.cov) |cov| cov[i] else 1;
            if (k == 0) continue;
            const g = if (@TypeOf(shader).constant) .{ 0, 0 } else inv.apply(.{ @as(f32, @floatFromInt(x)) + 0.5, py });
            const s = shader.at(g) orelse continue;
            const d: V = dst[i * 4 ..][0..4].*;
            const sk = s * @as(V, @splat(k));
            dst[i * 4 ..][0..4].* = sk + d * @as(V, @splat(1 - sk[3]));
        }
    }
}

/// The text colour (linear premultiplied) as straight sRGB.
fn fgSrgb(fg: [4]f32) [4]f32 {
    const a = std.math.clamp(fg[3], 0, 1);
    if (!(a > 0)) return .{ 0, 0, 0, 0 };
    var o: [4]f32 = undefined;
    for (0..3) |i| {
        const l = std.math.clamp(fg[i] / a, 0, 1);
        o[i] = if (l <= 0.0031308) l * 12.92 else 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055;
    }
    o[3] = a;
    return o;
}

/// Renders colour glyph `gid` (COLRv1 paint graph, else COLRv0 layers) as
/// `.rgba8_premul` into the rasterizer's output buffer. `Unsupported` when
/// the glyph has no colour data or no bounds, `Malformed` for a cycle or a
/// bad table, `LimitExceeded` past the limits; callers fall back to the
/// outline on any of these.
pub fn renderColorGlyph(r: *Rasterizer, inst: *const variation.FaceInstance, colr: *const Colr, gid: ot.GlyphId, p: ColorRenderParams) Error!Bitmap {
    const upem: f32 = @floatFromInt(inst.face.units_per_em);
    if (!(upem > 0) or !(p.px_per_em > 0) or !std.math.isFinite(p.px_per_em) or !std.math.isFinite(p.subpixel_x)) return error.Malformed;
    var c: Ctx = .{
        .r = r,
        .inst = inst,
        .colr = colr,
        .coords = inst.coordsSlice(),
        .palette = if (colr.cpal) |*cp| cp.select(p.palette, p.dark_bg) else 0,
        .fg = fgSrgb(p.fg),
        .outline_m = rz.outlineMatrix(inst),
    };
    const root = colr.v1Paint(gid);
    const v0 = if (root == null) colr.v0Layers(gid) orelse return error.Unsupported else null;
    const clip_box: ?Rect = if (root != null) colr.clipBox(gid, c.coords) else null;

    var px = p.px_per_em;
    var tries: u32 = 0;
    const pl, var m = while (true) : (tries += 1) {
        const m: Affine = .{ .xx = px / upem, .yy = -px / upem, .dx = p.subpixel_x };
        c.paints = 0;
        const b = if (clip_box) |cb| rectBounds(cb, m) else if (root) |off| try c.bounds(off, m, 0) else blk: {
            var b: Rect = .empty;
            for (0..v0.?.count) |i| {
                const l = colr.v0Layer(@intCast(v0.?.first + i));
                b = b.unite(rz.transformedBounds(try c.loadOutline(l.gid), m.mul(c.outline_m)));
            }
            break :blk b;
        };
        const pl = rz.place(b) orelse return .{};
        if (pl.width <= max_canvas and pl.height <= max_canvas) break .{ pl, m };
        if (tries == 3) return error.TooLarge;
        px *= @as(f32, max_canvas) / @as(f32, @floatFromInt(@max(pl.width, pl.height))) * 0.999;
    };
    m.dx -= @floatFromInt(pl.left);
    m.dy -= @floatFromInt(pl.top);
    c.w = pl.width;
    c.h = pl.height;
    c.paints = 0;

    const full: Clip = .{ .x0 = 0, .y0 = 0, .x1 = c.w, .y1 = c.h };
    const dst = try c.layer(full);
    if (root) |off| {
        const clip = if (clip_box) |cb| try c.rectClip(cb, m, full) else full;
        if (!clip.isEmpty()) try c.draw(off, m, dst, clip, 0);
    } else for (0..v0.?.count) |i| {
        const l = colr.v0Layer(@intCast(v0.?.first + i));
        const clip = try c.glyphClip(l.gid, m, full);
        defer c.release(clip);
        if (!clip.isEmpty()) fill(&c, dst, clip, m, Solid{ .c = premul(c.colorOf(l.palette, 1)) });
    }

    const out = try r.outputBuffer(@as(usize, c.w) * c.h * 4);
    for (0..@as(usize, c.w) * c.h) |i| {
        const v: V = dst[i * 4 ..][0..4].*;
        const a = std.math.clamp(v[3], 0, 1);
        inline for (0..3) |k| out[i * 4 + k] = @intFromFloat(std.math.clamp(v[k], 0, a) * 255 + 0.5);
        out[i * 4 + 3] = @intFromFloat(a * 255 + 0.5);
    }
    return Rasterizer.bitmapOf(pl, c.w * 4, .rgba8_premul, out);
}
