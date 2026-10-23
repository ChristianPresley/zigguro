//! A timed tween: `from` to `to` over `ms` milliseconds along a cubic
//! bezier, and `Motion`, how a value gets to its target.

const std = @import("std");
const bezier = @import("bezier.zig");
const spring = @import("spring.zig");

const CubicBezier = bezier.CubicBezier;

/// How an animated value reaches its target.
pub const Motion = union(enum) {
    spring: spring.SpringParams,
    tween: struct { ms: f32, curve: CubicBezier = .standard },
    instant,
};

/// A tween in flight; `start_ns` is set by its first `at`.
pub const Tween = struct {
    from: f32,
    to: f32,
    ms: f32,
    curve: CubicBezier,
    start_ns: ?u64 = null,

    /// Progress in [0, 1] at `now_ns` (starts the clock on first call).
    pub fn progress(t: *Tween, now_ns: u64) f32 {
        const s = t.start_ns orelse blk: {
            t.start_ns = now_ns;
            break :blk now_ns;
        };
        if (!(t.ms > 0)) return 1;
        const el: f64 = @floatFromInt(now_ns -| s);
        return @floatCast(@min(1, el / (@as(f64, t.ms) * std.time.ns_per_ms)));
    }

    /// The value at `now_ns`.
    pub fn at(t: *Tween, now_ns: u64) f32 {
        const p = t.progress(now_ns);
        if (p >= 1) return t.to;
        return t.from + (t.to - t.from) * t.curve.eval(p);
    }

    /// True once the duration has passed.
    pub fn done(t: *const Tween, now_ns: u64) bool {
        const s = t.start_ns orelse return !(t.ms > 0);
        return @as(f64, @floatFromInt(now_ns -| s)) >= @as(f64, t.ms) * std.time.ns_per_ms;
    }
};

test "tween runs from start to end on its clock" {
    var t: Tween = .{ .from = 10, .to = 20, .ms = 100, .curve = .linear };
    try std.testing.expectEqual(@as(f32, 10), t.at(1_000_000_000));
    try std.testing.expectApproxEqAbs(@as(f32, 15), t.at(1_050_000_000), 1e-4);
    try std.testing.expect(!t.done(1_050_000_000));
    try std.testing.expectEqual(@as(f32, 20), t.at(1_200_000_000));
    try std.testing.expect(t.done(1_100_000_000));
}
