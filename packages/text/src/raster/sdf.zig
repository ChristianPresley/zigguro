//! Single-channel signed distance fields (Valve, SIGGRAPH 2007) for UI
//! zoom, animation, icons and large display text. One entry at a 48 px
//! base serves a wide range of drawn sizes.
//!
//! Value mapping: `v = clamp(0.5 + d / (2 * spread), 0, 1) * 255`, rounded,
//! where `d` is the signed distance in base pixels from the pixel centre to
//! the outline, positive inside. Inside is above 127.
//!
//! Pipeline: the outline is flattened at 0.05 px into a segment list,
//! padded by `spread` on every side. The sign comes from the coverage
//! rasterizer on the same grid (inside when coverage ≥ 0.5), which handles
//! overlapping contours with no per-pixel winding. The distance is the
//! minimum over the segments in the 3×3 block of `spread`-sized grid cells
//! around the pixel, which holds every segment closer than `spread`.
//!
//! Shader contract (E02):
//! - `alpha = smoothstep(0.5 - w, 0.5 + w, sample)` with
//!   `w = 0.5 * fwidth(sample)`, or `w = 0.7 / (spread * 2 * scale_ratio)`
//!   where derivatives are unavailable (`scale_ratio` = drawn px / base px).
//! - Outline and glow are thresholds at other values (Valve paper).
//! - Sample the R8 page as linear UNORM, never sRGB. Entries carry
//!   `spread` pixels of padding, which the atlas must keep.
//!
//! MSDF (multi-channel, sharp corners) is a P2 follow-up; msdfgen is the
//! prior art.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rz = @import("rasterizer.zig");
const Rasterizer = rz.Rasterizer;
const Bitmap = rz.Bitmap;
const Path = @import("../outline/path.zig").Path;
const Affine = @import("../outline/path.zig").Affine;
const flatten = @import("flatten.zig");

/// Base size and spread.
pub const SdfParams = struct {
    base_px: f32 = 48,
    spread_px: f32 = 4,
};

/// Flattening tolerance for SDF outlines, in pixels.
pub const tol: f32 = 0.05;

/// The SDF of `path` (font units, y up) at `p.base_px`.
pub fn generate(r: *Rasterizer, path: *const Path, units_per_em: u16, p: SdfParams) rz.Error!Bitmap {
    if (units_per_em == 0) return error.Malformed;
    const m = rz.pixelTransform(@floatFromInt(units_per_em), .{ .px_per_em = p.base_px });
    return generateMapped(r, path, m, p.spread_px);
}

/// Segment sink that fills the rasterizer's segment list.
const SegSink = struct {
    list: *std.ArrayList([2][2]f32),
    gpa: Allocator,
    failed: bool = false,

    pub fn segment(s: *SegSink, a: [2]f32, b: [2]f32) void {
        s.list.append(s.gpa, .{ a, b }) catch {
            s.failed = true;
        };
    }
};

/// The SDF of `path` mapped to pixels by `m` (y down), with `spread`
/// pixels of padding. Shares the rasterizer's buffers; the result lives in
/// its output buffer like any other bitmap.
pub fn generateMapped(r: *Rasterizer, path: *const Path, m: Affine, spread_in: f32) rz.Error!Bitmap {
    const spread = if (spread_in >= 0.5 and spread_in <= 64) spread_in else 4;
    var b = rz.transformedBounds(path, m);
    b.x0 -= spread;
    b.y0 -= spread;
    b.x1 += spread;
    b.y1 += spread;
    const pl = rz.place(b) orelse return .{};
    if (pl.width > rz.max_side or pl.height > rz.max_side) return error.TooLarge;
    const w = pl.width;
    const h = pl.height;

    r.segs.clearRetainingCapacity();
    var sink: SegSink = .{ .list = &r.segs, .gpa = r.gpa };
    rz.walk(path, m, .{ @floatFromInt(pl.left), @floatFromInt(pl.top) }, tol, &sink);
    if (sink.failed) return error.OutOfMemory;
    const segs = r.segs.items;

    // Sign: coverage on the same grid.
    try r.acc.reset(r.gpa, w, h);
    for (segs) |s| r.acc.line(s[0], s[1]);
    r.sub.clearRetainingCapacity();
    try r.sub.ensureTotalCapacity(r.gpa, w * h);
    r.sub.items.len = w * h;
    const cov = r.sub.items;
    r.acc.integrate(cov, w);

    // Bucket the segments into spread-sized cells (counting sort).
    const cell = spread;
    const cw: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(w)) / cell));
    const ch: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(h)) / cell));
    const n_cells = @as(usize, cw) * ch;
    r.cell_start.clearRetainingCapacity();
    try r.cell_start.ensureTotalCapacity(r.gpa, n_cells + 1);
    r.cell_start.items.len = n_cells + 1;
    const start = r.cell_start.items;
    @memset(start, 0);
    for (segs) |s| {
        const c = cellRange(s, cell, cw, ch);
        for (c[1]..c[3] + 1) |cy| for (c[0]..c[2] + 1) |cx| {
            start[cy * cw + cx + 1] += 1;
        };
    }
    for (1..start.len) |i| start[i] += start[i - 1];
    r.cell_items.clearRetainingCapacity();
    try r.cell_items.ensureTotalCapacity(r.gpa, start[n_cells]);
    r.cell_items.items.len = start[n_cells];
    const items = r.cell_items.items;
    // Fill using start[cell] as a cursor, then shift back.
    for (segs, 0..) |s, si| {
        const c = cellRange(s, cell, cw, ch);
        for (c[1]..c[3] + 1) |cy| for (c[0]..c[2] + 1) |cx| {
            const k = cy * cw + cx;
            items[start[k]] = @intCast(si);
            start[k] += 1;
        };
    }
    var i = n_cells;
    while (i > 0) : (i -= 1) start[i] = start[i - 1];
    start[0] = 0;

    const out = try r.outputBuffer(w * h);
    const inv = 1 / (2 * spread);
    const sp2 = spread * spread;
    for (0..h) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const cy: u32 = @min(ch - 1, @as(u32, @intFromFloat(py / cell)));
        for (0..w) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const cx: u32 = @min(cw - 1, @as(u32, @intFromFloat(px / cell)));
            var best = sp2;
            var yy = cy -| 1;
            while (yy <= @min(ch - 1, cy + 1)) : (yy += 1) {
                var xx = cx -| 1;
                while (xx <= @min(cw - 1, cx + 1)) : (xx += 1) {
                    const k = yy * cw + xx;
                    for (items[start[k]..start[k + 1]]) |si| best = @min(best, dist2(.{ px, py }, segs[si]));
                }
            }
            const d = @sqrt(best);
            const sd = if (cov[y * w + x] >= 128) d else -d;
            const v = std.math.clamp(0.5 + sd * inv, 0, 1) * 255 + 0.5;
            out[y * w + x] = @intFromFloat(v);
        }
    }
    return Rasterizer.bitmapOf(pl, w, .sdf8, out);
}

/// Cells touched by a segment's bounding box: x0, y0, x1, y1 inclusive.
fn cellRange(s: [2][2]f32, cell: f32, cw: u32, ch: u32) [4]usize {
    const x0 = @min(s[0][0], s[1][0]);
    const x1 = @max(s[0][0], s[1][0]);
    const y0 = @min(s[0][1], s[1][1]);
    const y1 = @max(s[0][1], s[1][1]);
    return .{ cellOf(x0, cell, cw), cellOf(y0, cell, ch), cellOf(x1, cell, cw), cellOf(y1, cell, ch) };
}

fn cellOf(v: f32, cell: f32, n: u32) usize {
    const c = @floor(v / cell);
    if (!(c > 0)) return 0;
    if (c >= @as(f32, @floatFromInt(n - 1))) return n - 1;
    return @intFromFloat(c);
}

/// Squared distance from `p` to the segment `s`.
fn dist2(p: [2]f32, s: [2][2]f32) f32 {
    const dx = s[1][0] - s[0][0];
    const dy = s[1][1] - s[0][1];
    const l2 = dx * dx + dy * dy;
    var t: f32 = 0;
    if (l2 > 0) t = std.math.clamp(((p[0] - s[0][0]) * dx + (p[1] - s[0][1]) * dy) / l2, 0, 1);
    const ex = s[0][0] + t * dx - p[0];
    const ey = s[0][1] + t * dy - p[1];
    return ex * ex + ey * ey;
}
