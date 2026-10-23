//! CSS cubic-bezier easing (CSS Easing Functions Level 1): the curve from
//! (0, 0) to (1, 1) through control points (x1, y1) and (x2, y2). `eval`
//! solves x(t) = progress for t by Newton's method, falling back to
//! bisection, and returns y(t).

const std = @import("std");

const log = std.log.scoped(.gui_anim);

pub const CubicBezier = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub const linear: CubicBezier = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 };
    pub const ease: CubicBezier = .{ .x1 = 0.25, .y1 = 0.1, .x2 = 0.25, .y2 = 1.0 };
    pub const ease_in: CubicBezier = .{ .x1 = 0.42, .y1 = 0, .x2 = 1, .y2 = 1 };
    pub const ease_out: CubicBezier = .{ .x1 = 0, .y1 = 0, .x2 = 0.58, .y2 = 1 };
    pub const ease_in_out: CubicBezier = .{ .x1 = 0.42, .y1 = 0, .x2 = 0.58, .y2 = 1 };
    /// Material's standard curve: quick start, long settle.
    pub const standard: CubicBezier = .{ .x1 = 0.2, .y1 = 0, .x2 = 0, .y2 = 1 };

    /// A curve with x1 and x2 clamped to [0, 1] (CSS rejects others; we
    /// warn and clamp so x(t) stays monotonic).
    pub fn init(x1: f32, y1: f32, x2: f32, y2: f32) CubicBezier {
        const b: CubicBezier = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
        if (!b.valid()) log.warn("cubic-bezier x out of [0, 1] ({d}, {d}); clamped", .{ x1, x2 });
        return b.clamped();
    }

    /// x1 and x2 lie in [0, 1].
    pub fn valid(b: CubicBezier) bool {
        return b.x1 >= 0 and b.x1 <= 1 and b.x2 >= 0 and b.x2 <= 1;
    }

    /// The curve with x1 and x2 clamped to [0, 1].
    pub fn clamped(b: CubicBezier) CubicBezier {
        var out = b;
        out.x1 = std.math.clamp(if (std.math.isNan(b.x1)) 0 else b.x1, 0, 1);
        out.x2 = std.math.clamp(if (std.math.isNan(b.x2)) 1 else b.x2, 0, 1);
        return out;
    }

    /// The eased value at progress `t` ∈ [0, 1] (clamped).
    pub fn eval(b0: CubicBezier, t: f32) f32 {
        const b = b0.clamped();
        if (!(t > 0)) return 0;
        if (t >= 1) return 1;
        if (b.x1 == b.y1 and b.x2 == b.y2) return t;
        const x: f64 = t;
        const cx: f64 = 3 * @as(f64, b.x1);
        const bx: f64 = 3 * (@as(f64, b.x2) - b.x1) - cx;
        const ax: f64 = 1 - cx - bx;
        const cy: f64 = 3 * @as(f64, b.y1);
        const by: f64 = 3 * (@as(f64, b.y2) - b.y1) - cy;
        const ay: f64 = 1 - cy - by;
        const eps = 1e-7;

        // Newton from u = x.
        var u = x;
        var solved = false;
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const err = ((ax * u + bx) * u + cx) * u - x;
            if (@abs(err) < eps) {
                solved = true;
                break;
            }
            const d = (3 * ax * u + 2 * bx) * u + cx;
            if (@abs(d) < 1e-6) break;
            u -= err / d;
        }
        if (solved and u >= 0 and u <= 1) return @floatCast(((ay * u + by) * u + cy) * u);
        // Bisection: x(u) is monotonic on [0, 1].
        var lo: f64 = 0;
        var hi: f64 = 1;
        u = x;
        i = 0;
        while (i < 40) : (i += 1) {
            const xu = ((ax * u + bx) * u + cx) * u;
            if (@abs(xu - x) < eps) break;
            if (xu < x) lo = u else hi = u;
            u = (lo + hi) / 2;
        }
        return @floatCast(((ay * u + by) * u + cy) * u);
    }
};

test "bezier eval known values" {
    const e = CubicBezier.ease;
    try std.testing.expectApproxEqAbs(@as(f32, 0.8024), e.eval(0.5), 1e-3);
    try std.testing.expectEqual(@as(f32, 0), e.eval(0));
    try std.testing.expectEqual(@as(f32, 1), e.eval(1));
    try std.testing.expectEqual(@as(f32, 0.3), CubicBezier.linear.eval(0.3));
    // ease-in-out is symmetric about the middle.
    const io = CubicBezier.ease_in_out;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), io.eval(0.5), 1e-4);
    try std.testing.expectApproxEqAbs(1 - io.eval(0.2), io.eval(0.8), 1e-4);
    // Monotonic along the way.
    var prev: f32 = 0;
    var k: u32 = 1;
    while (k <= 100) : (k += 1) {
        const y = CubicBezier.standard.eval(@as(f32, @floatFromInt(k)) / 100);
        try std.testing.expect(y >= prev);
        prev = y;
    }
    // Overshooting y is allowed.
    const back: CubicBezier = .{ .x1 = 0.3, .y1 = -0.5, .x2 = 0.7, .y2 = 1.5 };
    try std.testing.expect(back.eval(0.1) < 0);
}

test "invalid x clamped" {
    const b: CubicBezier = .{ .x1 = -0.5, .y1 = 0, .x2 = 1.5, .y2 = 1 };
    try std.testing.expect(!b.valid());
    const c = b.clamped();
    try std.testing.expectEqual(@as(f32, 0), c.x1);
    try std.testing.expectEqual(@as(f32, 1), c.x2);
    try std.testing.expect(c.valid());
    // Out of range progress clamps too.
    try std.testing.expectEqual(@as(f32, 0), b.eval(-1));
    try std.testing.expectEqual(@as(f32, 1), b.eval(2));
    const y = b.eval(0.5);
    try std.testing.expect(y > 0 and y < 1);
}
