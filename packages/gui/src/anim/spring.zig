//! A damped spring with an exact closed-form step (Ryan Juckett, "Damped
//! Springs"): the position and velocity after `dt` are a linear map of the
//! current offset from the target and velocity, with coefficients that
//! depend only on ω, ζ and dt. Being exact for any dt, the motion does not
//! depend on the frame rate.
//!
//! - ζ < 1 (under-damped): oscillates at α = ω√(1−ζ²);
//! - ζ = 1 (critical, |ζ − 1| < 1e-4): exponential × linear;
//! - ζ > 1 (over-damped): the sum of two exponentials.
//!
//! The coefficients are computed in f64; a caller stepping many springs
//! with the same parameters and dt computes them once (`Coeffs.of`).

const std = @import("std");

/// The spring's angular frequency ω (rad/s), damping ratio ζ, and the
/// distance (and velocity, scaled by ω) under which it is at rest.
pub const SpringParams = struct {
    omega: f32 = 30,
    zeta: f32 = 1.0,
    rest_eps: f32 = 0.01,

    pub fn eql(a: SpringParams, b: SpringParams) bool {
        return a.omega == b.omega and a.zeta == b.zeta and a.rest_eps == b.rest_eps;
    }
};

/// Treated as critically damped within this distance of ζ = 1.
pub const critical_band = 1e-4;

/// The linear map from (offset, velocity) now to after `dt`.
pub const Coeffs = struct {
    pp: f64 = 1,
    pv: f64 = 0,
    vp: f64 = 0,
    vv: f64 = 1,

    /// The coefficients for `p` over `dt_s` seconds.
    pub fn of(p: SpringParams, dt_s: f64) Coeffs {
        const omega: f64 = @max(0, p.omega);
        const zeta: f64 = @max(0, p.zeta);
        if (omega < 1e-6 or dt_s <= 0) return .{};
        if (zeta > 1 + critical_band) {
            // Over-damped.
            const za = -omega * zeta;
            const zb = omega * @sqrt(zeta * zeta - 1);
            const z1 = za - zb;
            const z2 = za + zb;
            const e1 = @exp(z1 * dt_s);
            const e2 = @exp(z2 * dt_s);
            const inv = 1 / (2 * zb);
            const e1o = e1 * inv;
            const e2o = e2 * inv;
            const z1e1o = z1 * e1o;
            const z2e2o = z2 * e2o;
            return .{
                .pp = e1o * z2 - z2e2o + e2,
                .pv = -e1o + e2o,
                .vp = (z1e1o - z2e2o + e2) * z2,
                .vv = -z1e1o + z2e2o,
            };
        } else if (zeta < 1 - critical_band) {
            // Under-damped.
            const oz = omega * zeta;
            const alpha = omega * @sqrt(1 - zeta * zeta);
            const e = @exp(-oz * dt_s);
            const c = @cos(alpha * dt_s);
            const s = @sin(alpha * dt_s);
            const inv_a = 1 / alpha;
            const es = e * s;
            const ec = e * c;
            const ezs = e * oz * s * inv_a;
            return .{
                .pp = ec + ezs,
                .pv = es * inv_a,
                .vp = -es * alpha - oz * ezs,
                .vv = ec - ezs,
            };
        } else {
            // Critically damped.
            const e = @exp(-omega * dt_s);
            const te = dt_s * e;
            const tew = te * omega;
            return .{
                .pp = tew + e,
                .pv = te,
                .vp = -omega * tew,
                .vv = -tew + e,
            };
        }
    }
};

/// A spring's position, velocity and target.
pub const SpringState = struct {
    x: f32,
    v: f32 = 0,
    target: f32,

    /// Advances by `dt_s` seconds (exact for any dt).
    pub fn step(s: *SpringState, p: SpringParams, dt_s: f32) void {
        s.apply(Coeffs.of(p, dt_s));
    }

    /// Advances with precomputed coefficients (`Coeffs.of`).
    pub fn apply(s: *SpringState, k: Coeffs) void {
        const x0: f64 = @as(f64, s.x) - s.target;
        const v0: f64 = s.v;
        s.x = @floatCast(x0 * k.pp + v0 * k.pv + s.target);
        s.v = @floatCast(x0 * k.vp + v0 * k.vv);
    }

    /// Within `rest_eps` of the target and moving slower than
    /// `rest_eps × ω`.
    pub fn atRest(s: *const SpringState, p: SpringParams) bool {
        return @abs(s.x - s.target) < p.rest_eps and @abs(s.v) < p.rest_eps * @max(p.omega, 1);
    }

    /// Jumps to the target and stops.
    pub fn settle(s: *SpringState) void {
        s.x = s.target;
        s.v = 0;
    }
};

// -- tests --------------------------------------------------------------------

/// Integrates x'' = −2ζω x' − ω² (x − target) with classic RK4.
fn rk4(p: SpringParams, x0: f64, v0: f64, target: f64, t_end: f64, h: f64, out: []f64) void {
    const w2 = @as(f64, p.omega) * p.omega;
    const d = 2 * @as(f64, p.zeta) * p.omega;
    const Acc = struct {
        fn a(x: f64, v: f64, tg: f64, ww: f64, dd: f64) f64 {
            return -dd * v - ww * (x - tg);
        }
    };
    var x = x0;
    var v = v0;
    var t: f64 = 0;
    const per = out.len;
    const sample = t_end / @as(f64, @floatFromInt(per));
    var next: usize = 0;
    while (next < per) {
        const due = sample * @as(f64, @floatFromInt(next + 1));
        while (t + h <= due + 1e-12) : (t += h) {
            const k1x = v;
            const k1v = Acc.a(x, v, target, w2, d);
            const k2x = v + h / 2 * k1v;
            const k2v = Acc.a(x + h / 2 * k1x, v + h / 2 * k1v, target, w2, d);
            const k3x = v + h / 2 * k2v;
            const k3v = Acc.a(x + h / 2 * k2x, v + h / 2 * k2v, target, w2, d);
            const k4x = v + h * k3v;
            const k4v = Acc.a(x + h * k3x, v + h * k3v, target, w2, d);
            x += h / 6 * (k1x + 2 * k2x + 2 * k3x + k4x);
            v += h / 6 * (k1v + 2 * k2v + 2 * k3v + k4v);
        }
        out[next] = x;
        next += 1;
    }
}

test "spring regimes match numerical RK4 with tiny dt" {
    const cases = [_]SpringParams{
        .{ .omega = 30, .zeta = 1 },
        .{ .omega = 25, .zeta = 0.8 },
        .{ .omega = 12, .zeta = 0.2 },
        .{ .omega = 30, .zeta = 2.5 },
        .{ .omega = 30, .zeta = 1.00005 },
    };
    for (cases) |p| {
        var ref: [200]f64 = undefined;
        rk4(p, 0, 3, 1, 2, 1e-5, &ref);
        var s: SpringState = .{ .x = 0, .v = 3, .target = 1 };
        for (ref) |want| {
            s.step(p, 0.01);
            try std.testing.expectApproxEqAbs(want, s.x, 1e-3);
        }
    }
}

test "frame-rate independence 60/120/144" {
    const p: SpringParams = .{ .omega = 25, .zeta = 0.8 };
    var at: [3]f32 = undefined;
    for ([_]u32{ 60, 120, 144 }, 0..) |hz, i| {
        var s: SpringState = .{ .x = 0, .target = 100 };
        const k = Coeffs.of(p, 1 / @as(f64, @floatFromInt(hz)));
        var n: u32 = 0;
        // 0.25 s at each rate.
        while (n < hz / 4) : (n += 1) s.apply(k);
        at[i] = s.x;
    }
    try std.testing.expectApproxEqAbs(at[0], at[1], 1e-3);
    try std.testing.expectApproxEqAbs(at[0], at[2], 1e-3);
}

test "retarget velocity continuous" {
    const p: SpringParams = .{};
    var s: SpringState = .{ .x = 0, .target = 100 };
    s.step(p, 0.05);
    const v = s.v;
    const x = s.x;
    s.target = -50;
    // The retarget itself changes neither position nor velocity.
    try std.testing.expectEqual(v, s.v);
    try std.testing.expectEqual(x, s.x);
    s.step(p, 1e-4);
    try std.testing.expectApproxEqRel(v, s.v, 0.05);
}

test "spring comes to rest" {
    const p: SpringParams = .{};
    var s: SpringState = .{ .x = 0, .target = 1 };
    var n: u32 = 0;
    while (!s.atRest(p)) : (n += 1) s.step(p, 1.0 / 120.0);
    try std.testing.expect(n > 10 and n < 120);
}
