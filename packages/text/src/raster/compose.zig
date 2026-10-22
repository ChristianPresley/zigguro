//! The 28 COLRv1 composite modes (W3C Compositing and Blending Level 1)
//! on premultiplied RGBA. Porter-Duff operators are `s*Fa + d*Fb`; blend
//! modes are `s*(1 - da) + d*(1 - sa) + sa*da*B(cs, cd)` with alpha
//! `sa + da - sa*da`, where `B` takes unpremultiplied colours. Separable
//! modes compute `sa*da*B` directly from premultiplied values; soft light
//! and the four non-separable modes unpremultiply first.

const std = @import("std");
const CompositeMode = @import("../ot/colr.zig").CompositeMode;

/// Premultiplied RGBA.
pub const V = @Vector(4, f32);

inline fn splat(x: f32) V {
    return @splat(x);
}

/// `mode` applied to source `s` over backdrop `d`.
pub inline fn blend(comptime mode: CompositeMode, s: V, d: V) V {
    const sa = s[3];
    const da = d[3];
    switch (mode) {
        .clear => return splat(0),
        .src => return s,
        .dest => return d,
        .src_over => return s + d * splat(1 - sa),
        .dest_over => return s * splat(1 - da) + d,
        .src_in => return s * splat(da),
        .dest_in => return d * splat(sa),
        .src_out => return s * splat(1 - da),
        .dest_out => return d * splat(1 - sa),
        .src_atop => return s * splat(da) + d * splat(1 - sa),
        .dest_atop => return s * splat(1 - da) + d * splat(sa),
        .xor => return s * splat(1 - da) + d * splat(1 - sa),
        .plus => return @min(s + d, splat(1)),
        else => {},
    }
    const sada = sa * da;
    // sa*da*B for each colour channel.
    const b: V = switch (mode) {
        .multiply => s * d,
        .screen => s * splat(da) + d * splat(sa) - s * d,
        .overlay => hardLight(d, splat(da), s, splat(sa)),
        .hard_light => hardLight(s, splat(sa), d, splat(da)),
        .darken => @min(s * splat(da), d * splat(sa)),
        .lighten => @max(s * splat(da), d * splat(sa)),
        .difference => @abs(s * splat(da) - d * splat(sa)),
        .exclusion => s * splat(da) + d * splat(sa) - splat(2) * s * d,
        .color_dodge => blk: {
            var o: V = undefined;
            inline for (0..3) |i| o[i] = if (d[i] <= 0) 0 else if (s[i] >= sa) sada else @min(sada, d[i] * sa * sa / (sa - s[i]));
            break :blk o;
        },
        .color_burn => blk: {
            var o: V = undefined;
            inline for (0..3) |i| o[i] = if (d[i] >= da) sada else if (s[i] <= 0) 0 else sada - @min(sada, (da - d[i]) * sa * sa / s[i]);
            break :blk o;
        },
        .soft_light => blk: {
            const cs = unpremul(s);
            const cd = unpremul(d);
            var o: V = undefined;
            inline for (0..3) |i| o[i] = sada * softLight(cs[i], cd[i]);
            break :blk o;
        },
        .hue, .saturation, .color, .luminosity => blk: {
            const cs = unpremul(s);
            const cd = unpremul(d);
            const r: [3]f32 = switch (mode) {
                .hue => setLum(setSat(rgb(cs), sat(rgb(cd))), lum(rgb(cd))),
                .saturation => setLum(setSat(rgb(cd), sat(rgb(cs))), lum(rgb(cd))),
                .color => setLum(rgb(cs), lum(rgb(cd))),
                .luminosity => setLum(rgb(cd), lum(rgb(cs))),
                else => unreachable,
            };
            break :blk V{ r[0], r[1], r[2], 0 } * splat(sada);
        },
        else => unreachable,
    };
    var out = s * splat(1 - da) + d * splat(1 - sa) + b;
    out[3] = sa + da - sada;
    return out;
}

/// sa*da*HardLight(cs, cd) from premultiplied s (alpha sa) and d (alpha da).
inline fn hardLight(s: V, sa: V, d: V, da: V) V {
    const two: V = @splat(2);
    return @select(f32, two * s <= sa, two * s * d, sa * da - two * (sa - s) * (da - d));
}

fn softLight(cs: f32, cd: f32) f32 {
    if (cs <= 0.5) return cd - (1 - 2 * cs) * cd * (1 - cd);
    const dd = if (cd <= 0.25) ((16 * cd - 12) * cd + 4) * cd else @sqrt(cd);
    return cd + (2 * cs - 1) * (dd - cd);
}

inline fn unpremul(c: V) V {
    return if (c[3] > 0) c / splat(c[3]) else splat(0);
}

inline fn rgb(c: V) [3]f32 {
    return .{ c[0], c[1], c[2] };
}

fn lum(c: [3]f32) f32 {
    return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];
}

fn clipColor(c_in: [3]f32) [3]f32 {
    var c = c_in;
    const l = lum(c);
    const n = @min(c[0], @min(c[1], c[2]));
    const x = @max(c[0], @max(c[1], c[2]));
    if (n < 0 and l - n > 0) {
        for (&c) |*v| v.* = l + (v.* - l) * l / (l - n);
    }
    if (x > 1 and x - l > 0) {
        for (&c) |*v| v.* = l + (v.* - l) * (1 - l) / (x - l);
    }
    return c;
}

fn setLum(c: [3]f32, l: f32) [3]f32 {
    const d = l - lum(c);
    return clipColor(.{ c[0] + d, c[1] + d, c[2] + d });
}

fn sat(c: [3]f32) f32 {
    return @max(c[0], @max(c[1], c[2])) - @min(c[0], @min(c[1], c[2]));
}

fn setSat(c: [3]f32, s: f32) [3]f32 {
    // Indices of the smallest, middle and largest channel.
    var lo: usize = 0;
    var mid: usize = 1;
    var hi: usize = 2;
    if (c[lo] > c[mid]) std.mem.swap(usize, &lo, &mid);
    if (c[mid] > c[hi]) std.mem.swap(usize, &mid, &hi);
    if (c[lo] > c[mid]) std.mem.swap(usize, &lo, &mid);
    var o: [3]f32 = .{ 0, 0, 0 };
    if (c[hi] > c[lo]) {
        o[mid] = (c[mid] - c[lo]) * s / (c[hi] - c[lo]);
        o[hi] = s;
    }
    return o;
}

/// `b = lerp(b, mode(s, b), m)` over the pixels of rows y0..y1, columns
/// x0..x1 of `w`-wide RGBA layers; `mask` (one f32 per pixel, null for
/// full coverage) weights the result, as a clipped layer restore does.
pub fn blendLayers(mode: CompositeMode, src: []const f32, dst: []f32, mask: ?[]const f32, w: u32, x0: u32, y0: u32, x1: u32, y1: u32) void {
    switch (mode) {
        inline else => |m| for (y0..y1) |y| for (x0..x1) |x| {
            const i = y * w + x;
            const s: V = src[i * 4 ..][0..4].*;
            const d: V = dst[i * 4 ..][0..4].*;
            const r = blend(m, s, d);
            const k = if (mask) |mk| mk[i] else 1;
            dst[i * 4 ..][0..4].* = d + (r - d) * splat(k);
        },
    }
}
