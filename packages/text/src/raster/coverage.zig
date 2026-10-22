//! The accumulation-buffer coverage rasterizer (the font-rs scheme). Line
//! segments in pixel space (y down) add signed area deltas to a dense f32
//! buffer; a per-row prefix sum turns the deltas into exact analytic area,
//! and `abs` plus a clamp to 1 gives the nonzero fill.
//!
//! Every row is integrated on its own: the deltas of a closed outline sum
//! to zero along each row, so the carry restarts at 0 and float drift
//! cannot leak from one row into the next. All arithmetic is plain mul and
//! add in a fixed order (no `@mulAdd`), so the result is bit-identical on
//! every target.

const std = @import("std");
const Allocator = std.mem.Allocator;

const V = @Vector(8, f32);

/// The signed-area buffer for one bitmap. Rows are `stride` floats apart;
/// `stride` covers the `w` output columns plus at least two guard columns
/// (the spill of a segment touching the right edge) and is a multiple of 8,
/// so `integrate` runs whole vectors with no scalar tail.
pub const Accumulator = struct {
    w: u32 = 0,
    h: u32 = 0,
    stride: u32 = 0,
    buf: []f32 = &.{},
    /// Allocated length of `buf`; it only grows.
    capacity: usize = 0,

    /// Frees the buffer.
    pub fn deinit(a: *Accumulator, gpa: Allocator) void {
        gpa.free(a.buf.ptr[0..a.capacity]);
        a.* = .{};
    }

    /// Sizes the buffer for a `w`×`h` bitmap and zeroes it, growing the
    /// allocation only when the new size exceeds every earlier one.
    pub fn reset(a: *Accumulator, gpa: Allocator, w: u32, h: u32) Allocator.Error!void {
        const stride = std.mem.alignForward(u32, w + 2, 8);
        const len = @as(usize, stride) * h;
        if (len > a.capacity) {
            const nb = try gpa.alloc(f32, len);
            gpa.free(a.buf.ptr[0..a.capacity]);
            a.buf = nb;
            a.capacity = len;
        }
        a.buf = a.buf.ptr[0..len];
        a.w = w;
        a.h = h;
        a.stride = stride;
        @memset(a.buf, 0);
    }

    /// Adds the signed area of the segment `p0`→`p1` (pixel space, y down;
    /// a downward segment adds positive area to its right). Points are
    /// clamped to the bitmap, so a stray point can never write outside it.
    pub fn line(a: *Accumulator, p0_in: [2]f32, p1_in: [2]f32) void {
        const fw: f32 = @floatFromInt(a.w);
        const fh: f32 = @floatFromInt(a.h);
        const p0 = [2]f32{ std.math.clamp(p0_in[0], 0, fw), std.math.clamp(p0_in[1], 0, fh) };
        const p1 = [2]f32{ std.math.clamp(p1_in[0], 0, fw), std.math.clamp(p1_in[1], 0, fh) };
        if (p0[1] == p1[1]) return;
        const dir: f32, const top, const bot = if (p0[1] < p1[1]) .{ 1, p0, p1 } else .{ -1, p1, p0 };
        const dxdy = (bot[0] - top[0]) / (bot[1] - top[1]);
        var x = top[0];
        const y_start: u32 = @intFromFloat(@floor(top[1]));
        const y_end: u32 = @min(a.h, @as(u32, @intFromFloat(@ceil(bot[1]))));
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const fy: f32 = @floatFromInt(y);
            const dy = @min(fy + 1, bot[1]) - @max(fy, top[1]);
            // The last row ends exactly at the endpoint, so rounding in
            // dxdy never pushes x outside the segment.
            const xnext = if (fy + 1 >= bot[1]) bot[0] else x + dxdy * dy;
            const d = dy * dir;
            const row = a.buf[@as(usize, y) * a.stride ..][0..a.stride];
            const x0 = @min(x, xnext);
            const x1 = @max(x, xnext);
            const x0floor = @floor(x0);
            const x0i: u32 = @intFromFloat(x0floor);
            const x1ceil = @ceil(x1);
            const x1i: u32 = @intFromFloat(x1ceil);
            if (x1i <= x0i + 1) {
                // Within one column: split by the mean x.
                const xmf = 0.5 * (x + xnext) - x0floor;
                row[x0i] += d - d * xmf;
                row[x0i + 1] += d * xmf;
            } else {
                // Across columns: the area to the right of the segment
                // grows linearly in x between the two partial columns.
                const s = 1 / (x1 - x0);
                const x0f = x0 - x0floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x1 - x1ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                row[x0i] += d * a0;
                if (x1i == x0i + 2) {
                    row[x0i + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - x0f);
                    row[x0i + 1] += d * (a1 - a0);
                    var xi = x0i + 2;
                    while (xi < x1i - 1) : (xi += 1) row[xi] += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    row[x1i - 1] += d * (1 - a2 - am);
                }
                row[x1i] += d * am;
            }
            x = xnext;
        }
    }

    /// `line` under the name the flatteners call (`flatten.quadTo` sinks).
    pub inline fn segment(a: *Accumulator, p0: [2]f32, p1: [2]f32) void {
        a.line(p0, p1);
    }

    /// Integrates every row into 8-bit coverage, `round(min(|area|, 1) *
    /// 255)`, writing `w` bytes per row `stride` bytes apart.
    pub fn integrate(a: *const Accumulator, out: []u8, stride: u32) void {
        std.debug.assert(out.len >= if (a.h == 0) 0 else @as(usize, stride) * (a.h - 1) + a.w);
        const zero: V = @splat(0);
        const one: V = @splat(1);
        const k255: V = @splat(255);
        const half: V = @splat(0.5);
        for (0..a.h) |y| {
            const row = a.buf[y * a.stride ..][0..a.stride];
            const dst = out[y * stride ..][0..a.w];
            // The carry stays a broadcast vector so the loop-carried chain
            // is one add and one shuffle per 8 pixels.
            var carry: V = zero;
            var x: usize = 0;
            while (x < a.stride) : (x += 8) {
                var v: V = row[x..][0..8].*;
                // Inclusive prefix sum: shift-add by 1, 2, 4 lanes.
                v += @shuffle(f32, v, zero, [8]i32{ -1, 0, 1, 2, 3, 4, 5, 6 });
                v += @shuffle(f32, v, zero, [8]i32{ -1, -1, 0, 1, 2, 3, 4, 5 });
                v += @shuffle(f32, v, zero, [8]i32{ -1, -1, -1, -1, 0, 1, 2, 3 });
                v += carry;
                carry = @shuffle(f32, v, undefined, [8]i32{ 7, 7, 7, 7, 7, 7, 7, 7 });
                if (x >= a.w) continue; // guard columns: only the carry matters
                const c = @min(@abs(v), one) * k255 + half;
                const bytes: [8]u8 = @as(@Vector(8, u8), @truncate(@as(@Vector(8, u32), @intFromFloat(c))));
                if (x + 8 <= a.w) {
                    dst[x..][0..8].* = bytes;
                } else {
                    @memcpy(dst[x..a.w], bytes[0 .. a.w - x]);
                }
            }
            // A closed outline's deltas cancel along each row.
            std.debug.assert(@abs(carry[0]) < 1e-2);
        }
    }

    /// Like `integrate` but writes linear coverage as floats in [0, 1]
    /// (the SDF and test paths).
    pub fn integrateF32(a: *const Accumulator, out: []f32) void {
        for (0..a.h) |y| {
            const row = a.buf[y * a.stride ..][0..a.stride];
            var acc: f32 = 0;
            for (0..a.w) |x| {
                acc += row[x];
                out[y * a.w + x] = @min(@abs(acc), 1);
            }
        }
    }
};

const testing = std.testing;

test "one pixel square" {
    var a: Accumulator = .{};
    defer a.deinit(testing.allocator);
    try a.reset(testing.allocator, 3, 3);
    // Clockwise on screen (y down) = counter-clockwise in font space.
    const pts = [_][2]f32{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 2 }, .{ 2, 1 } };
    for (pts, 0..) |p, i| a.line(p, pts[(i + 1) % pts.len]);
    var out: [9]u8 = undefined;
    a.integrate(&out, 3);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 255, 0, 0, 0, 0 }, &out);
}

test "reset reuses the allocation" {
    var a: Accumulator = .{};
    defer a.deinit(testing.allocator);
    try a.reset(testing.allocator, 40, 40);
    var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try a.reset(fa.allocator(), 20, 30);
    try testing.expectEqual(@as(u32, 24), a.stride);
}
