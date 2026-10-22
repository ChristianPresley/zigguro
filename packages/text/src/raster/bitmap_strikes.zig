//! Bitmap-strike glyphs (CBDT, sbix): decode the strike's PNG once into
//! premultiplied linear light (cached), then resample it to the requested
//! size with an exact-area box filter, and return premultiplied sRGB RGBA8
//! placed like any other glyph.

const std = @import("std");
const Allocator = std.mem.Allocator;
const png = @import("png.zig");
const rz = @import("rasterizer.zig");
const Rasterizer = rz.Rasterizer;
const Bitmap = rz.Bitmap;
const StrikeGlyph = @import("../ot/cbdt.zig").StrikeGlyph;

/// A decoded strike image: premultiplied linear-light RGBA, 16 bits per
/// channel (0..65535), rows top to bottom.
pub const LinearImage = struct {
    w: u32,
    h: u32,
    px: []u16,
};

/// Decoded strike images, least recently used evicted first once the
/// total exceeds `budget_bytes`. Keyed by the PNG's address in the font,
/// so one cache serves every face a rasterizer sees.
pub const StrikeCache = struct {
    budget_bytes: usize = 4 << 20,
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    clock: u64 = 0,

    const Entry = struct { key: usize, len: usize, img: LinearImage, used: u64 };

    /// Frees every image.
    pub fn deinit(c: *StrikeCache, gpa: Allocator) void {
        for (c.entries.items) |e| gpa.free(e.img.px);
        c.entries.deinit(gpa);
        c.* = .{};
    }

    /// The decoded image of `data`, decoding and caching it on a miss.
    pub fn get(c: *StrikeCache, gpa: Allocator, data: []const u8) png.Error!*const LinearImage {
        c.clock += 1;
        const key = @intFromPtr(data.ptr);
        for (c.entries.items) |*e| if (e.key == key and e.len == data.len) {
            e.used = c.clock;
            return &e.img;
        };
        var img = try png.decodeOpts(gpa, data, png.default_max_pixels, .{ .premultiply = false });
        defer img.deinit(gpa);
        const lin = try gpa.alloc(u16, img.rgba.len);
        errdefer gpa.free(lin);
        for (0..img.rgba.len / 4) |i| {
            const p = img.rgba[i * 4 ..][0..4];
            const a: u32 = p[3];
            inline for (0..3) |k| lin[i * 4 + k] = @intCast((@as(u32, to_linear16[p[k]]) * a + 127) / 255);
            lin[i * 4 + 3] = @intCast(a * 257);
        }
        const size = lin.len * 2;
        while (c.entries.items.len > 0 and c.bytes + size > c.budget_bytes) {
            var lru: usize = 0;
            for (c.entries.items, 0..) |e, i| if (e.used < c.entries.items[lru].used) {
                lru = i;
            };
            c.bytes -= c.entries.items[lru].img.px.len * 2;
            gpa.free(c.entries.items[lru].img.px);
            _ = c.entries.swapRemove(lru);
        }
        try c.entries.append(gpa, .{ .key = key, .len = data.len, .img = .{ .w = img.w, .h = img.h, .px = lin }, .used = c.clock });
        c.bytes += size;
        return &c.entries.items[c.entries.items.len - 1].img;
    }
};

/// sRGB-encoded byte to 16-bit linear light.
const to_linear16: [256]u16 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*v, i| {
        const c = @as(f64, @floatFromInt(i)) / 255;
        const l = if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        v.* = @intFromFloat(l * 65535 + 0.5);
    }
    break :blk t;
};

/// Linear light quantized to 14 bits, to sRGB-encoded 0..255 (the step is
/// under 0.25 of an output level everywhere).
const srgb_lut_bits = 14;
const to_srgb: [1 << srgb_lut_bits]u8 = blk: {
    @setEvalBranchQuota(10_000_000);
    var t: [1 << srgb_lut_bits]u8 = undefined;
    for (&t, 0..) |*v, i| {
        const l = @as(f64, @floatFromInt(i)) / ((1 << srgb_lut_bits) - 1);
        const c = if (l <= 0.0031308) l * 12.92 else 1.055 * std.math.pow(f64, l, 1.0 / 2.4) - 0.055;
        v.* = @intFromFloat(c * 255 + 0.5);
    }
    break :blk t;
};

fn toSrgb8(l: f32) f32 {
    const c = std.math.clamp(l, 0, 1);
    return @floatFromInt(to_srgb[@intFromFloat(c * ((1 << srgb_lut_bits) - 1) + 0.5)]);
}

/// Box-filter weights along one axis: target pixel t takes source pixels
/// `first[t] ..` with weights `w[off[t] .. off[t + 1]]`.
const Axis = struct {
    first: []u32,
    off: []u32,
    w: []f32,
};

/// Weights for `n` source pixels, each covering [o + i*s, o + (i+1)*s) in
/// target pixels, onto `m` targets: the overlap with [t, t + 1). A target
/// fully inside the image gets weights summing to 1 (the area average).
fn axisWeights(n: u32, m: u32, s: f32, o: f32, ints: []u32, floats: []f32) Axis {
    const first = ints[0..m];
    const off = ints[m..][0 .. m + 1];
    var k: u32 = 0;
    for (0..m) |t| {
        const ft: f32 = @floatFromInt(t);
        const lo_f = @floor((ft - o) / s);
        const lo: u32 = if (lo_f > 0) @intFromFloat(@min(lo_f, @as(f32, @floatFromInt(n)))) else 0;
        off[t] = k;
        first[t] = lo;
        var i = lo;
        while (i < n and k < floats.len) : (i += 1) {
            const a = o + @as(f32, @floatFromInt(i)) * s;
            if (a >= ft + 1) break;
            floats[k] = @max(0, @min(a + s, ft + 1) - @max(a, ft));
            k += 1;
        }
    }
    off[m] = k;
    return .{ .first = first, .off = off, .w = floats[0..k] };
}

/// Most weights one axis can need.
fn axisCap(m: u32, s: f32) usize {
    return @as(usize, m) * (@as(usize, @intFromFloat(@ceil(1 / s))) + 2);
}

/// Renders `g` at `target_ppem` into the rasterizer's output buffer.
/// Bearings scale by `target_ppem / g.ppem`; the advance comes from hmtx.
pub fn renderStrike(r: *Rasterizer, g: StrikeGlyph, target_ppem: f32, cache: *StrikeCache) rz.Error!Bitmap {
    if (g.ppem == 0 or !(target_ppem > 0) or !std.math.isFinite(g.origin_x) or !std.math.isFinite(g.origin_y)) return error.Malformed;
    const img = cache.get(r.gpa, g.png) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.TooLarge,
        else => error.Malformed,
    };
    const s = target_ppem / @as(f32, @floatFromInt(g.ppem));
    // The image spans [x0, x0 + w*s] × [y0, y0 + h*s] in target pixels (y down).
    const x0 = g.origin_x * s;
    const y0 = -g.origin_y * s;
    const pl = rz.place(.{ .x0 = x0, .y0 = y0, .x1 = x0 + @as(f32, @floatFromInt(img.w)) * s, .y1 = y0 + @as(f32, @floatFromInt(img.h)) * s }) orelse return .{};
    if (pl.width > rz.max_side or pl.height > rz.max_side) return error.TooLarge;
    const ow = pl.width;
    const oh = pl.height;

    // Scratch: weights for both axes, then the horizontal pass (ow × h).
    const cx = axisCap(ow, s);
    const cy = axisCap(oh, s);
    const mid_len = @as(usize, ow) * img.h * 4;
    try r.fbuf.resize(r.gpa, cx + cy + mid_len);
    try r.cell_start.resize(r.gpa, 2 * (@as(usize, ow) + oh) + 2);
    const ints = r.cell_start.items;
    const ax = axisWeights(img.w, ow, s, x0 - @as(f32, @floatFromInt(pl.left)), ints[0 .. 2 * ow + 1], r.fbuf.items[0..cx]);
    const ay = axisWeights(img.h, oh, s, y0 - @as(f32, @floatFromInt(pl.top)), ints[2 * ow + 1 ..], r.fbuf.items[cx..][0..cy]);
    const mid = r.fbuf.items[cx + cy ..][0..mid_len];

    const V = @Vector(4, f32);
    for (0..img.h) |y| {
        const src = img.px[y * img.w * 4 ..][0 .. img.w * 4];
        for (0..ow) |t| {
            var acc: V = @splat(0);
            for (ax.w[ax.off[t]..ax.off[t + 1]], ax.first[t]..) |w, i| {
                const p: @Vector(4, u16) = src[i * 4 ..][0..4].*;
                acc += @as(V, @floatFromInt(p)) * @as(V, @splat(w));
            }
            mid[(y * ow + t) * 4 ..][0..4].* = acc;
        }
    }
    const out = try r.outputBuffer(@as(usize, ow) * oh * 4);
    const inv: V = @splat(1.0 / 65535.0);
    for (0..oh) |t| {
        for (0..ow) |x| {
            var acc: V = @splat(0);
            for (ay.w[ay.off[t]..ay.off[t + 1]], ay.first[t]..) |w, i| {
                const p: V = mid[(i * ow + x) * 4 ..][0..4].*;
                acc += p * @as(V, @splat(w));
            }
            acc *= inv;
            const a = std.math.clamp(acc[3], 0, 1);
            const o = out[(t * ow + x) * 4 ..][0..4];
            if (a <= 0) {
                o.* = .{ 0, 0, 0, 0 };
                continue;
            }
            inline for (0..3) |c| o[c] = @intFromFloat(@min(255, toSrgb8(acc[c] / a) * a + 0.5));
            o[3] = @intFromFloat(a * 255 + 0.5);
        }
    }
    return Rasterizer.bitmapOf(pl, ow * 4, .rgba8_premul, out);
}
