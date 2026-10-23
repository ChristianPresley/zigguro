//! Scales (E13.F07.S01.T03): data values to pixels and colours. Linear
//! and log for quantities, time for timestamps, band (bars, padding 0.1)
//! and point for categories; categorical and sequential colour.

const std = @import("std");
const transform = @import("transform.zig");
const ticks = @import("ticks.zig");
const query = @import("../data/query/root.zig");

const Allocator = std.mem.Allocator;
const Lit = query.plan.Lit;

pub const Kind = enum { linear, log, time, band, point };

/// A position scale. Continuous kinds map `[d0, d1]` to `[r0, r1]`;
/// discrete kinds map each domain key to a band or point.
pub const Scale = struct {
    kind: Kind,
    d0: f64 = 0,
    d1: f64 = 1,
    r0: f32 = 0,
    r1: f32 = 1,
    /// Discrete domain: keys (label text) in display order.
    keys: []const []const u8 = &.{},
    /// The original values of `keys` (for formatting and sorting).
    values: []const Lit = &.{},
    index: std.StringHashMapUnmanaged(u32) = .empty,
    padding_inner: f32 = 0.1,
    padding_outer: f32 = 0.05,
    /// Time scales: the zone ticks align to.
    zone: ticks.Zone = .utc,

    pub fn continuous(s: *const Scale) bool {
        return s.kind == .linear or s.kind == .log or s.kind == .time;
    }

    /// The pixel position of a number on a continuous scale.
    pub fn mapNum(s: *const Scale, x: f64) f32 {
        const t: f64 = switch (s.kind) {
            .log => if (x > 0 and s.d0 > 0) (std.math.log10(x) - std.math.log10(s.d0)) / (std.math.log10(s.d1) - std.math.log10(s.d0)) else std.math.nan(f64),
            else => if (s.d1 != s.d0) (x - s.d0) / (s.d1 - s.d0) else 0.5,
        };
        return s.r0 + @as(f32, @floatCast(t)) * (s.r1 - s.r0);
    }

    /// The position of a value: a number or time on continuous scales,
    /// the band's start or the point on discrete ones. Null when the
    /// value has no place (null, unknown key, log of ≤ 0).
    pub fn map(s: *const Scale, a: Allocator, v: Lit) !?f32 {
        switch (s.kind) {
            .linear, .log => {
                const x = transform.toNum(v) orelse return null;
                const p = s.mapNum(x);
                return if (std.math.isNan(p)) null else p;
            },
            .time => {
                const t = transform.toTime(v) orelse return null;
                return s.mapNum(@floatFromInt(t));
            },
            .band, .point => {
                if (v == .null_) return null;
                const k = try transform.litText(a, v);
                const i = s.index.get(k) orelse return null;
                return s.discretePos(i);
            },
        }
    }

    /// The distance between band or point starts.
    pub fn step(s: *const Scale) f32 {
        const n: f32 = @floatFromInt(@max(s.keys.len, 1));
        const span = s.r1 - s.r0;
        return switch (s.kind) {
            .band => span / (n - s.padding_inner + 2 * s.padding_outer),
            .point => span / n,
            else => 0,
        };
    }

    /// A band's width (0 for other kinds).
    pub fn bandwidth(s: *const Scale) f32 {
        return if (s.kind == .band) s.step() * (1 - s.padding_inner) else 0;
    }

    pub fn discretePos(s: *const Scale, i: u32) f32 {
        const st = s.step();
        const fi: f32 = @floatFromInt(i);
        return switch (s.kind) {
            .band => s.r0 + st * (s.padding_outer + fi),
            .point => s.r0 + st * (0.5 + fi),
            else => 0,
        };
    }

    /// The centre of a band or the point itself.
    pub fn center(s: *const Scale, i: u32) f32 {
        return s.discretePos(i) + s.bandwidth() / 2;
    }

    /// The data value at pixel `p` on a continuous scale.
    pub fn invert(s: *const Scale, p: f32) f64 {
        const t: f64 = if (s.r1 != s.r0) (p - s.r0) / (s.r1 - s.r0) else 0;
        return switch (s.kind) {
            .log => std.math.pow(f64, 10, std.math.log10(s.d0) + t * (std.math.log10(s.d1) - std.math.log10(s.d0))),
            else => s.d0 + t * (s.d1 - s.d0),
        };
    }
};

/// Builds a discrete scale over `values` (already in display order).
pub fn discrete(a: Allocator, kind: Kind, values: []const Lit, r0: f32, r1: f32) !Scale {
    var s: Scale = .{ .kind = kind, .r0 = r0, .r1 = r1, .values = values };
    const keys = try a.alloc([]const u8, values.len);
    for (keys, values, 0..) |*k, v, i| {
        k.* = try transform.litText(a, v);
        try s.index.put(a, k.*, @intCast(i));
    }
    s.keys = keys;
    return s;
}

// ---- Colour ----

pub const Rgb = u24;

/// The default categorical palette (Vega's "tableau10", distinguishable
/// for common colour-vision deficiencies and on light and dark
/// backgrounds); apps pass their theme's tokens instead.
pub const default_palette = [10]Rgb{ 0x4C78A8, 0xF58518, 0xE45756, 0x72B7B2, 0x54A24B, 0xEECA3B, 0xB279A2, 0xFF9DA6, 0x9D755D, 0xBAB0AC };

/// A sequential ramp's ends (light to dark blue).
pub const default_ramp = [2]Rgb{ 0xDEEBF7, 0x08519C };

pub const ColorScale = union(enum) {
    /// One colour for everything.
    constant: Rgb,
    /// Keys to palette entries, cycling.
    categorical: struct { scale: Scale, palette: []const Rgb },
    /// A number between `d0` and `d1` to a point on the ramp.
    sequential: struct { d0: f64, d1: f64, ramp: [2]Rgb },

    pub fn map(c: *const ColorScale, a: Allocator, v: Lit) !Rgb {
        switch (c.*) {
            .constant => |k| return k,
            .categorical => |cat| {
                if (v == .null_) return 0x999999;
                const k = try transform.litText(a, v);
                const i = cat.scale.index.get(k) orelse return 0x999999;
                return cat.palette[i % cat.palette.len];
            },
            .sequential => |sq| {
                const x = transform.toNum(v) orelse return 0x999999;
                const t = if (sq.d1 > sq.d0) std.math.clamp((x - sq.d0) / (sq.d1 - sq.d0), 0, 1) else 0.5;
                return lerp(sq.ramp[0], sq.ramp[1], t);
            },
        }
    }
};

/// Linear interpolation of two colours in sRGB.
pub fn lerp(a: Rgb, b: Rgb, t: f64) Rgb {
    var out: Rgb = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const x: f64 = @floatFromInt((a >> sh) & 0xFF);
        const y: f64 = @floatFromInt((b >> sh) & 0xFF);
        const v: Rgb = @intFromFloat(@round(x + (y - x) * t));
        out |= v << sh;
    }
    return out;
}

test {
    std.testing.refAllDecls(@This());
}
