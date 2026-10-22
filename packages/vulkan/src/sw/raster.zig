//! Per-tile shading of the software renderer. A tile's destination pixels
//! are loaded into a premultiplied f32 scratch (structure of arrays), every
//! binned prim is evaluated `lanes` pixels at a time with the shared
//! `r2d/shading.zig` math and blended in paint order, and the result is
//! stored back with round-half-up, only where the repaint mask is set.
//!
//! The code is generic over the lane count; 8 lanes is the production
//! path and 1 lane is the scalar reference. Both execute the same float
//! operations, so their outputs are bit-identical.

const std = @import("std");
const r2d = @import("../r2d/root.zig");
const bin = @import("bin.zig");
const texture = @import("texture.zig");

const sh = r2d.shading;
const Prim = r2d.Prim;
const ClipRect = r2d.ClipRect;
const Color = r2d.Color;
const tile_size = bin.tile_size;
const CpuTexture = texture.CpuTexture;

/// Pixels per tile.
pub const tile_px = tile_size * tile_size;

/// One thread's tile scratch: premultiplied r, g, b, a planes.
pub const Scratch = struct {
    /// Red plane, row-major 64×64.
    r: [tile_px]f32 align(32),
    /// Green plane.
    g: [tile_px]f32 align(32),
    /// Blue plane.
    b: [tile_px]f32 align(32),
    /// Alpha plane.
    a: [tile_px]f32 align(32),
    /// Text coverage lookup tables, one per recent text luminance.
    luts: LutCache = .{},
};

/// `textCoverageT` precomputed for the 256 exact unorm8 inputs of a few
/// text luminances. Table entries are the function's own results, so a
/// lookup equals the direct evaluation bit for bit.
pub const LutCache = struct {
    keys: [4]u32 = .{ 0, 0, 0, 0 },
    used: u8 = 0,
    next: u8 = 0,
    tables: [4][256]f32 = undefined,

    /// The table for luminance `l` under `p`.
    pub fn get(c: *LutCache, l: f32, p: sh.TextParams) *const [256]f32 {
        const key: u32 = @bitCast(l);
        for (c.keys[0..c.used], 0..) |k, i| if (k == key) return &c.tables[i];
        const i = c.next;
        c.next = (c.next + 1) % 4;
        c.used = @max(c.used, i + 1);
        c.keys[i] = key;
        for (&c.tables[i], 0..) |*e, v| e.* = sh.textCoverageT(f32, r2d.color.unorm(@intCast(v)), l, p);
        return &c.tables[i];
    }
};

/// Looks up `lut` for exact unorm8 coverage values `c`.
fn lutLookup(comptime T: type, lut: *const [256]f32, c: T) T {
    const idx = c * sh.splat(T, 255.0) + sh.splat(T, 0.5);
    if (T == f32) return lut[@intFromFloat(idx)];
    var out: T = undefined;
    inline for (0..@typeInfo(T).vector.len) |i| out[i] = lut[@intFromFloat(idx[i])];
    return out;
}

/// Everything shading needs besides the prims.
pub const ShadeCtx = struct {
    /// The draw list's clip table.
    clips: []const ClipRect,
    /// Textures indexed by `Prim.tex` (null entries are missing textures).
    textures: []const ?*const CpuTexture,
    /// Layer images indexed by a layer prim's `params`.
    layers: []const ?*const CpuTexture,
    /// Text coverage correction.
    text: sh.TextParams,
    /// Whether subpixel text blends per channel (else it is downgraded).
    dual_src: bool = true,
};

/// A destination buffer of 8-bit premultiplied pixels.
pub const Target = struct {
    /// Bytes.
    pixels: []u8,
    /// Bytes per row.
    stride: u32,
    /// Width in pixels.
    width: u32,
    /// Height in pixels.
    height: u32,
    /// Byte order of each pixel.
    bgra: bool,
};

/// Bit x of `mask[y]` set = pixel (tile.x + x, tile.y + y) is repainted.
pub const TileMask = [tile_size]u64;

/// Shades tile `tile` of `dst`: loads it, blends the prims listed in `items`
/// and stores the pixels selected by `mask`.
pub fn shadeTile(comptime lanes: comptime_int, tile: bin.TileRect, items: []const u32, prims: []const Prim, ctx: *const ShadeCtx, dst: Target, mask: *const TileMask, scratch: *Scratch) void {
    load(tile, dst, scratch);
    for (items) |i| shadePrim(lanes, tile, &prims[i], ctx, scratch);
    store(tile, dst, mask, scratch);
}

fn load(tile: bin.TileRect, dst: Target, s: *Scratch) void {
    var y: u32 = 0;
    while (y < tile.h) : (y += 1) {
        const row = dst.pixels[@as(usize, tile.y + y) * dst.stride + @as(usize, tile.x) * 4 ..];
        var x: u32 = 0;
        while (x < tile.w) : (x += 1) {
            const p = row[x * 4 ..][0..4];
            const o = y * tile_size + x;
            const rc: u8 = if (dst.bgra) p[2] else p[0];
            const bc: u8 = if (dst.bgra) p[0] else p[2];
            s.r[o] = r2d.color.unorm(rc);
            s.g[o] = r2d.color.unorm(p[1]);
            s.b[o] = r2d.color.unorm(bc);
            s.a[o] = r2d.color.unorm(p[3]);
        }
    }
}

fn store(tile: bin.TileRect, dst: Target, mask: *const TileMask, s: *const Scratch) void {
    var y: u32 = 0;
    while (y < tile.h) : (y += 1) {
        const m = mask[y];
        if (m == 0) continue;
        const row = dst.pixels[@as(usize, tile.y + y) * dst.stride + @as(usize, tile.x) * 4 ..];
        var x: u32 = 0;
        while (x < tile.w) : (x += 1) {
            if ((m >> @intCast(x)) & 1 == 0) continue;
            const o = y * tile_size + x;
            const r = r2d.color.toUnorm8(s.r[o]);
            const g = r2d.color.toUnorm8(s.g[o]);
            const b = r2d.color.toUnorm8(s.b[o]);
            const a = r2d.color.toUnorm8(s.a[o]);
            row[x * 4 ..][0..4].* = if (dst.bgra) .{ b, g, r, a } else .{ r, g, b, a };
        }
    }
}

fn unpackColor(v: u32) [4]f32 {
    return Color.fromU32(v).toF32();
}

fn V(comptime lanes: comptime_int) type {
    return if (lanes == 1) f32 else @Vector(lanes, f32);
}

inline fn lane(comptime T: type, v: T, i: usize) f32 {
    return if (T == f32) v else v[i];
}

/// Fetches texel (x, y) of `t` as premultiplied r, g, b, a (r8 is gray
/// coverage replicated, alpha = coverage).
fn texel(t: *const CpuTexture, x: i64, y: i64) [4]f32 {
    const cx: u32 = @intCast(std.math.clamp(x, 0, @as(i64, t.width) - 1));
    const cy: u32 = @intCast(std.math.clamp(y, 0, @as(i64, t.height) - 1));
    switch (t.format) {
        .r8 => {
            const v = r2d.color.unorm(t.pixels[@as(usize, cy) * t.stride + cx]);
            return .{ v, v, v, v };
        },
        .rgba8 => {
            const p = t.pixels[@as(usize, cy) * t.stride + @as(usize, cx) * 4 ..][0..4];
            return .{ r2d.color.unorm(p[0]), r2d.color.unorm(p[1]), r2d.color.unorm(p[2]), r2d.color.unorm(p[3]) };
        },
    }
}

/// Samples `t` at texel-space coordinates (`u`, `v` in texels, pixel
/// centres at +0.5) with nearest or bilinear (clamp-to-edge) filtering.
fn sample(comptime T: type, t: ?*const CpuTexture, u: T, v: T, nearest: bool) [4]T {
    var out: [4]T = .{ sh.splat(T, 0), sh.splat(T, 0), sh.splat(T, 0), sh.splat(T, 0) };
    const tex = t orelse return out;
    if (nearest) {
        const fu = @floor(u);
        const fv = @floor(v);
        const n = if (T == f32) 1 else @typeInfo(T).vector.len;
        inline for (0..n) |i| {
            const px = texel(tex, toInt(lane(T, fu, i)), toInt(lane(T, fv, i)));
            inline for (0..4) |c| setLane(T, &out[c], i, px[c]);
        }
        return out;
    }
    const tu = u - sh.splat(T, 0.5);
    const tv = v - sh.splat(T, 0.5);
    const x0 = @floor(tu);
    const y0 = @floor(tv);
    const fx = tu - x0;
    const fy = tv - y0;
    var t00: [4]T = out;
    var t10: [4]T = out;
    var t01: [4]T = out;
    var t11: [4]T = out;
    const n = if (T == f32) 1 else @typeInfo(T).vector.len;
    inline for (0..n) |i| {
        const ix = toInt(lane(T, x0, i));
        const iy = toInt(lane(T, y0, i));
        const a = texel(tex, ix, iy);
        const b = texel(tex, ix + 1, iy);
        const c = texel(tex, ix, iy + 1);
        const d = texel(tex, ix + 1, iy + 1);
        inline for (0..4) |ch| {
            setLane(T, &t00[ch], i, a[ch]);
            setLane(T, &t10[ch], i, b[ch]);
            setLane(T, &t01[ch], i, c[ch]);
            setLane(T, &t11[ch], i, d[ch]);
        }
    }
    inline for (0..4) |ch| {
        const top = t00[ch] + (t10[ch] - t00[ch]) * fx;
        const bot = t01[ch] + (t11[ch] - t01[ch]) * fx;
        out[ch] = top + (bot - top) * fy;
    }
    return out;
}

inline fn setLane(comptime T: type, v: *T, i: usize, x: f32) void {
    if (T == f32) v.* = x else v[i] = x;
}

fn toInt(f: f32) i64 {
    return @intFromFloat(std.math.clamp(f, -1e9, 1e9));
}

/// Evaluates prim `p` over its pixels inside `tile` and blends into `s`.
pub fn shadePrim(comptime lanes: comptime_int, tile: bin.TileRect, p: *const Prim, ctx: *const ShadeCtx, s: *Scratch) void {
    const T = V(lanes);
    const span = bin.primSpan(p, ctx.clips).intersect(.{ .x0 = tile.x, .y0 = tile.y, .x1 = tile.x + tile.w, .y1 = tile.y + tile.h });
    if (span.empty()) return;
    const lx0: u32 = @intCast(span.x0 - tile.x);
    const lx1: u32 = @intCast(span.x1 - tile.x);
    const g0 = lx0 / lanes;
    const g1 = (lx1 + lanes - 1) / lanes;
    var lane_off: T = undefined;
    inline for (0..lanes) |i| setLane(T, &lane_off, i, @floatFromInt(i));

    var y: i64 = span.y0;
    while (y < span.y1) : (y += 1) {
        const ly: u32 = @intCast(y - tile.y);
        const py = sh.splat(T, @as(f32, @floatFromInt(y)) + 0.5);
        var g = g0;
        while (g < g1) : (g += 1) {
            const lx = g * lanes;
            const xs = sh.splat(T, @as(f32, @floatFromInt(tile.x + lx)) + 0.5) + lane_off;
            // Lanes outside the span get zero coverage.
            const li = sh.splat(T, @floatFromInt(lx)) + lane_off;
            const in_span = band(T, li >= sh.splat(T, @floatFromInt(lx0)), li < sh.splat(T, @floatFromInt(lx1)));
            const o = ly * tile_size + lx;
            shadeGroup(T, p, ctx, xs, py, in_span, s, o);
        }
    }
}

inline fn band(comptime T: type, a: sh.Bool(T), b: sh.Bool(T)) sh.Bool(T) {
    return if (T == f32) (a and b) else (a & b);
}

fn loadPlane(comptime T: type, plane: *const [tile_px]f32, o: u32) T {
    if (T == f32) return plane[o];
    const n = @typeInfo(T).vector.len;
    return plane[o..][0..n].*;
}

fn storePlane(comptime T: type, plane: *[tile_px]f32, o: u32, v: T) void {
    if (T == f32) {
        plane[o] = v;
    } else {
        const n = @typeInfo(T).vector.len;
        plane[o..][0..n].* = v;
    }
}

fn shadeGroup(comptime T: type, p: *const Prim, ctx: *const ShadeCtx, px: T, py: T, in_span: sh.Bool(T), s: *Scratch, o: u32) void {
    const zero = sh.splat(T, 0);
    const one = sh.splat(T, 1);
    const b = p.bounds;
    const radii = p.radiiF();
    var cov: T = undefined;
    var src: [4]T = undefined;
    var sub_cov: ?[3]T = null;
    const c0 = unpackColor(p.color0);
    switch (p.kind) {
        .rect => {
            cov = sh.boxCoverageT(T, px, py, b, radii);
            src = splat4(T, c0);
        },
        .border => {
            cov = sh.borderCoverageT(T, px, py, b, radii, p.uv);
            src = splat4(T, c0);
        },
        .shadow => {
            const sp = p.shadowParams();
            cov = sh.clampT(T, sh.roundedBoxShadowT(T, px, py, .{ b[0], b[1] }, .{ b[0] + b[2], b[1] + b[3] }, sp[0], radii), 0, 1);
            src = splat4(T, c0);
        },
        .linear_gradient => {
            cov = sh.boxCoverageT(T, px, py, b, radii);
            const t = sh.gradientT(T, px, py, .{ p.uv[0], p.uv[1] }, .{ p.uv[2], p.uv[3] });
            const c1 = unpackColor(p.color1);
            inline for (0..4) |ch| src[ch] = sh.splat(T, c0[ch]) + sh.splat(T, c1[ch] - c0[ch]) * t;
        },
        .glyph_gray, .glyph_subpixel, .glyph_color => {
            const tex = lookup(ctx.textures, p.tex);
            const tw: f32 = if (tex) |t| @floatFromInt(t.width) else 1;
            const th: f32 = if (tex) |t| @floatFromInt(t.height) else 1;
            const u = (sh.splat(T, p.uv[0]) + (px - sh.splat(T, b[0])) / sh.splat(T, b[2]) * sh.splat(T, p.uv[2] - p.uv[0])) * sh.splat(T, tw);
            const v = (sh.splat(T, p.uv[1]) + (py - sh.splat(T, b[1])) / sh.splat(T, b[3]) * sh.splat(T, p.uv[3] - p.uv[1])) * sh.splat(T, th);
            const tx = sample(T, tex, u, v, true);
            cov = one;
            const l = textLuma(c0);
            switch (p.kind) {
                .glyph_color => {
                    inline for (0..4) |ch| src[ch] = tx[ch] * sh.splat(T, c0[3]);
                },
                .glyph_gray => {
                    var c = if (p.flags.rgb_avg) (tx[0] + tx[1] + tx[2]) / sh.splat(T, 3) else tx[0];
                    if (p.flags.aa_none) {
                        c = sh.sel(T, c >= sh.splat(T, 0.5), one, zero);
                    } else if (p.flags.rgb_avg) {
                        c = sh.textCoverageT(T, c, l, ctx.text);
                    } else {
                        c = lutLookup(T, s.luts.get(l, ctx.text), c);
                    }
                    cov = c;
                    src = splat4(T, c0);
                },
                else => {
                    var rc = tx[0];
                    var bc = tx[2];
                    if (p.flags.bgr) std.mem.swap(T, &rc, &bc);
                    if (ctx.dual_src) {
                        const lut = s.luts.get(l, ctx.text);
                        sub_cov = .{ lutLookup(T, lut, rc), lutLookup(T, lut, tx[1]), lutLookup(T, lut, bc) };
                    } else {
                        cov = sh.textCoverageT(T, (rc + tx[1] + bc) / sh.splat(T, 3), l, ctx.text);
                    }
                    src = splat4(T, c0);
                },
            }
        },
        .image, .layer => {
            const is_layer = p.kind == .layer;
            const tex = if (is_layer) lookup(ctx.layers, @intCast(@min(p.params, std.math.maxInt(u16)))) else lookup(ctx.textures, p.tex);
            cov = sh.boxCoverageT(T, px, py, b, radii);
            var u: T = undefined;
            var v: T = undefined;
            var nearest = p.flags.nearest;
            if (is_layer) {
                // Layer pixels map 1:1, offset by the scroll position.
                u = px - sh.splat(T, b[0]) + sh.splat(T, p.uv[0]);
                v = py - sh.splat(T, b[1]) + sh.splat(T, p.uv[1]);
                nearest = p.uv[0] == @floor(p.uv[0]) and p.uv[1] == @floor(p.uv[1]) and b[0] == @floor(b[0]) and b[1] == @floor(b[1]);
            } else {
                const tw: f32 = if (tex) |t| @floatFromInt(t.width) else 1;
                const th: f32 = if (tex) |t| @floatFromInt(t.height) else 1;
                u = (sh.splat(T, p.uv[0]) + (px - sh.splat(T, b[0])) / sh.splat(T, b[2]) * sh.splat(T, p.uv[2] - p.uv[0])) * sh.splat(T, tw);
                v = (sh.splat(T, p.uv[1]) + (py - sh.splat(T, b[1])) / sh.splat(T, b[3]) * sh.splat(T, p.uv[3] - p.uv[1])) * sh.splat(T, th);
            }
            const tx = sample(T, tex, u, v, nearest);
            inline for (0..4) |ch| src[ch] = tx[ch] * sh.splat(T, c0[ch]);
        },
        _ => return,
    }
    // Clip coverage.
    if (p.clip != 0 and p.clip < ctx.clips.len) {
        const c = ctx.clips[p.clip];
        cov = cov * sh.boxCoverageT(T, px, py, c.bounds, c.radii);
        if (sub_cov) |*sc| {
            const cc = sh.boxCoverageT(T, px, py, c.bounds, c.radii);
            inline for (0..3) |ch| sc[ch] = sc[ch] * cc;
        }
    }
    cov = sh.sel(T, in_span, cov, zero);

    const dst = [4]T{ loadPlane(T, &s.r, o), loadPlane(T, &s.g, o), loadPlane(T, &s.b, o), loadPlane(T, &s.a, o) };
    var out: [4]T = undefined;
    if (sub_cov) |sc| {
        const m = [3]T{ sh.sel(T, in_span, sc[0], zero), sh.sel(T, in_span, sc[1], zero), sh.sel(T, in_span, sc[2], zero) };
        out = sh.blendSubpixelT(T, dst, src, m);
    } else {
        const sc = [4]T{ src[0] * cov, src[1] * cov, src[2] * cov, src[3] * cov };
        out = sh.blendPremulT(T, dst, sc);
    }
    storePlane(T, &s.r, o, out[0]);
    storePlane(T, &s.g, o, out[1]);
    storePlane(T, &s.b, o, out[2]);
    storePlane(T, &s.a, o, out[3]);
}

fn lookup(list: []const ?*const CpuTexture, i: u16) ?*const CpuTexture {
    return if (i < list.len) list[i] else null;
}

fn splat4(comptime T: type, c: [4]f32) [4]T {
    return .{ sh.splat(T, c[0]), sh.splat(T, c[1]), sh.splat(T, c[2]), sh.splat(T, c[3]) };
}

/// Luminance of a premultiplied text colour, unpremultiplied first.
pub fn textLuma(c: [4]f32) f32 {
    if (!(c[3] > 0)) return 0;
    return sh.luma(.{ c[0] / c[3], c[1] / c[3], c[2] / c[3] });
}
