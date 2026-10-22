//! Nonzero coverage where the accumulator's `min(|area|, 1)` is wrong.
//!
//! The accumulator integrates the winding number over each pixel, which is
//! the nonzero coverage only while the winding inside the pixel takes one
//! sign and magnitude 1. Two contours of opposite direction that meet
//! inside a pixel cancel instead of adding (a seam), and two overlapping
//! contours of one direction count twice (clamped). COLR test fonts draw
//! circles as four wedges of alternating direction, and real colour fonts
//! overlap freely, so colour glyph clips need the real thing.
//!
//! `supersample` computes nonzero coverage on `sub_rows` sample rows per
//! pixel with exact horizontal span coverage; `fixUp` keeps the exact
//! analytic coverage wherever the two agree to within the sampling error
//! and takes the sampled value elsewhere.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Accumulator = @import("coverage.zig").Accumulator;

/// Sample rows per pixel row.
pub const sub_rows = 16;

/// Where sampled and analytic coverage may differ by sampling alone.
const agree = 1.5 / @as(f32, sub_rows);

/// One edge crossing of a sample row.
const Crossing = struct { x: f32, dir: f32 };

/// Buffers kept between calls.
pub const Scratch = struct {
    segs: std.ArrayList([2][2]f32) = .empty,
    xs: std.ArrayList(Crossing) = .empty,
    starts: std.ArrayList(u32) = .empty,
    cov: std.ArrayList(f32) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.segs.deinit(gpa);
        s.xs.deinit(gpa);
        s.starts.deinit(gpa);
        s.cov.deinit(gpa);
        s.* = .{};
    }
};

/// A segment sink for `rasterizer.walk` that clips each segment to the
/// rows [y_lo, y_hi) exactly (the accumulator alone clamps endpoints,
/// which bends segments that leave the bitmap vertically), clamps x into
/// [x_lo, x_hi] (which keeps the winding inside that slab and flattens the
/// outline outside it onto its sides), and feeds the result to the
/// accumulator and, when `segs` is set, to a segment list. With the bounds
/// of a rectangle this intersects the outline with it exactly.
pub const Sink = struct {
    acc: *Accumulator,
    segs: ?*std.ArrayList([2][2]f32),
    gpa: Allocator,
    x_lo: f32 = 0,
    x_hi: f32,
    y_lo: f32 = 0,
    y_hi: f32,
    oom: bool = false,

    pub fn segment(s: *Sink, p0_in: [2]f32, p1_in: [2]f32) void {
        if (p0_in[1] == p1_in[1]) return; // no area
        if (@max(p0_in[1], p1_in[1]) <= s.y_lo or @min(p0_in[1], p1_in[1]) >= s.y_hi) return;
        const p0 = clipY(p0_in, p1_in, s.y_lo, s.y_hi);
        const p1 = clipY(p1_in, p0_in, s.y_lo, s.y_hi);
        // Split where the segment crosses x_lo or x_hi, then clamp each
        // piece: the part beyond a side runs along it.
        var ts: [4]f32 = .{ 0, 1, 1, 1 };
        var n: usize = 1;
        for ([_]f32{ s.x_lo, s.x_hi }) |b| {
            if ((p0[0] - b) * (p1[0] - b) < 0) {
                ts[n] = (b - p0[0]) / (p1[0] - p0[0]);
                n += 1;
            }
        }
        ts[n] = 1;
        if (n == 3 and ts[1] > ts[2]) std.mem.swap(f32, &ts[1], &ts[2]);
        var a = p0;
        for (ts[1 .. n + 1]) |t| {
            const b = if (t == 1) p1 else [2]f32{ p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t };
            s.emit(.{ std.math.clamp(a[0], s.x_lo, s.x_hi), a[1] }, .{ std.math.clamp(b[0], s.x_lo, s.x_hi), b[1] });
            a = b;
        }
    }

    fn emit(s: *Sink, p0: [2]f32, p1: [2]f32) void {
        if (p0[1] == p1[1]) return;
        s.acc.line(p0, p1);
        if (s.segs) |l| l.append(s.gpa, .{ p0, p1 }) catch {
            s.oom = true;
        };
    }

    /// `p` moved along the segment towards `q` into [lo, hi] when outside.
    fn clipY(p: [2]f32, q: [2]f32, lo: f32, hi: f32) [2]f32 {
        const y = std.math.clamp(p[1], lo, hi);
        if (y == p[1]) return p;
        const t = (y - p[1]) / (q[1] - p[1]);
        return .{ p[0] + (q[0] - p[0]) * t, y };
    }
};

/// Nonzero coverage of the closed segment soup `segs` (pixel space, rows
/// [0, h)) into `out` (`w`×`h`, row-major), sampled on `sub_rows` rows per
/// pixel with exact horizontal span coverage.
pub fn supersample(gpa: Allocator, s: *Scratch, segs: []const [2][2]f32, w: u32, h: u32, out: []f32) Allocator.Error!void {
    const k: f32 = sub_rows;
    const nrows: usize = @as(usize, h) * sub_rows;
    try s.starts.resize(gpa, nrows + 1);
    const starts = s.starts.items;
    @memset(starts, 0);
    // Sample row j is at y = (j + 0.5) / k; a segment covers samples
    // j0 <= j < j1 with ya <= y < yb.
    const Range = struct {
        fn of(seg: [2][2]f32, n: usize) [2]usize {
            const ya = @min(seg[0][1], seg[1][1]) * sub_rows - 0.5;
            const yb = @max(seg[0][1], seg[1][1]) * sub_rows - 0.5;
            const fl: f32 = @floatFromInt(n);
            return .{ @intFromFloat(std.math.clamp(@ceil(ya), 0, fl)), @intFromFloat(std.math.clamp(@ceil(yb), 0, fl)) };
        }
    };
    var total: usize = 0;
    for (segs) |seg| {
        if (seg[0][1] == seg[1][1]) continue;
        const r = Range.of(seg, nrows);
        for (r[0]..r[1]) |j| starts[j + 1] += 1;
        total += r[1] - r[0];
    }
    for (1..nrows + 1) |j| starts[j] += starts[j - 1];
    try s.xs.resize(gpa, total);
    const xs = s.xs.items;
    // Fill, using starts[j] as the cursor of row j (restored below).
    for (segs) |seg| {
        if (seg[0][1] == seg[1][1]) continue;
        const r = Range.of(seg, nrows);
        const dir: f32 = if (seg[1][1] > seg[0][1]) 1 else -1;
        const dxdy = (seg[1][0] - seg[0][0]) / (seg[1][1] - seg[0][1]);
        for (r[0]..r[1]) |j| {
            const y = (@as(f32, @floatFromInt(j)) + 0.5) / k;
            xs[starts[j]] = .{ .x = seg[0][0] + (y - seg[0][1]) * dxdy, .dir = dir };
            starts[j] += 1;
        }
    }
    var j = nrows;
    while (j > 0) : (j -= 1) starts[j] = starts[j - 1];
    starts[0] = 0;

    @memset(out[0 .. @as(usize, w) * h], 0);
    const fw: f32 = @floatFromInt(w);
    const wgt = 1 / k;
    for (0..nrows) |row| {
        const cs = xs[starts[row]..starts[row + 1]];
        if (cs.len < 2) continue;
        std.mem.sort(Crossing, cs, {}, struct {
            fn lt(_: void, a: Crossing, b: Crossing) bool {
                return a.x < b.x;
            }
        }.lt);
        const line = out[(row / sub_rows) * w ..][0..w];
        var wind: f32 = 0;
        var x_start: f32 = 0;
        for (cs) |cr| {
            const before = wind;
            wind += cr.dir;
            if (before == 0 and wind != 0) {
                x_start = cr.x;
            } else if (before != 0 and wind == 0) {
                addSpan(line, std.math.clamp(x_start, 0, fw), std.math.clamp(cr.x, 0, fw), wgt);
            }
        }
    }
}

/// Adds coverage `wgt` × the overlap of [xa, xb) with each pixel.
fn addSpan(line: []f32, xa: f32, xb: f32, wgt: f32) void {
    if (!(xb > xa)) return;
    const ia: usize = @intFromFloat(@floor(xa));
    const ib: usize = @intFromFloat(@floor(xb));
    if (ia == ib) {
        if (ia < line.len) line[ia] += (xb - xa) * wgt;
        return;
    }
    line[ia] += (@as(f32, @floatFromInt(ia + 1)) - xa) * wgt;
    for (line[ia + 1 .. ib]) |*v| v.* += wgt;
    if (ib < line.len) line[ib] += (xb - @as(f32, @floatFromInt(ib))) * wgt;
}

/// `analytic[i]` replaced by `sampled[i]` where they differ by more than
/// sampling error, or where every sample row is covered across the whole
/// pixel but the analytic value falls short (a seam that cancelled only a
/// little).
pub fn fixUp(analytic: []f32, sampled: []const f32) void {
    for (analytic, sampled) |*a, sv| {
        const v = @min(sv, 1);
        if (@abs(a.* - v) > agree or (v >= 1 - 1e-5 and a.* < v)) a.* = v;
    }
}

test "opposite wedges meet without a seam" {
    const gpa = std.testing.allocator;
    var s: Scratch = .{};
    defer s.deinit(gpa);
    // Two unit-height boxes sharing the edge x = 2.5, wound oppositely.
    const segs = [_][2][2]f32{
        .{ .{ 0.5, 0 }, .{ 0.5, 1 } }, .{ .{ 2.5, 1 }, .{ 2.5, 0 } },
        .{ .{ 2.5, 1 }, .{ 2.5, 0 } }, .{ .{ 4.5, 0 }, .{ 4.5, 1 } },
    };
    var out: [5]f32 = undefined;
    try supersample(gpa, &s, &segs, 5, 1, &out);
    for (out, [_]f32{ 0.5, 1, 1, 1, 0.5 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-5);
}
