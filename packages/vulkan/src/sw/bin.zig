//! Tile binning for the software renderer: every prim is listed, in paint
//! order, in each 64×64 tile its pixels may touch, restricted to the
//! repaint rectangles. Pure functions; capacity is reused across frames.

const std = @import("std");
const r2d = @import("../r2d/root.zig");

const Prim = r2d.Prim;
const ClipRect = r2d.ClipRect;
const PxRect = r2d.PxRect;

/// Tile edge in pixels.
pub const tile_size = 64;

/// The tiles covering a target.
pub const TileGrid = struct {
    /// Target width in pixels.
    width: u32,
    /// Target height in pixels.
    height: u32,

    /// Tiles per row.
    pub fn cols(g: TileGrid) u32 {
        return (g.width + tile_size - 1) / tile_size;
    }
    /// Tile rows.
    pub fn rows(g: TileGrid) u32 {
        return (g.height + tile_size - 1) / tile_size;
    }
    /// Number of tiles.
    pub fn count(g: TileGrid) u32 {
        return g.cols() * g.rows();
    }
    /// The pixel rectangle of tile `i`.
    pub fn tile(g: TileGrid, i: u32) TileRect {
        const tx = (i % g.cols()) * tile_size;
        const ty = (i / g.cols()) * tile_size;
        return .{ .x = tx, .y = ty, .w = @min(tile_size, g.width - tx), .h = @min(tile_size, g.height - ty) };
    }
};

/// A tile's pixels.
pub const TileRect = struct {
    /// Left edge.
    x: u32,
    /// Top edge.
    y: u32,
    /// Width (≤ 64).
    w: u32,
    /// Height (≤ 64).
    h: u32,
};

/// Half-open pixel span x0..x1, y0..y1.
pub const Span = struct {
    /// First column.
    x0: i64,
    /// First row.
    y0: i64,
    /// Column after the last.
    x1: i64,
    /// Row after the last.
    y1: i64,

    /// Whether the span holds no pixel.
    pub fn empty(s: Span) bool {
        return s.x1 <= s.x0 or s.y1 <= s.y0;
    }

    /// The intersection of two spans.
    pub fn intersect(a: Span, b: Span) Span {
        return .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    }

    /// The span of a pixel rectangle.
    pub fn fromPx(r: PxRect) Span {
        return .{ .x0 = r.x, .y0 = r.y, .x1 = @as(i64, r.x) + r.w, .y1 = @as(i64, r.y) + r.h };
    }
};

/// Pixels whose centre lies in `[x0, x1) × [y0, y1)` (the GPU's top-left
/// rasterisation rule for a quad with these edges).
pub fn centreSpan(x0: f32, y0: f32, x1: f32, y1: f32) Span {
    return .{ .x0 = edge(x0), .y0 = edge(y0), .x1 = edge(x1), .y1 = edge(y1) };
}

fn edge(v: f32) i64 {
    const c = @ceil(v - 0.5);
    return @intFromFloat(std.math.clamp(c, -1e15, 1e15));
}

/// The pixels prim `p` may change: its cover rect, cut to its clip grown by
/// one pixel (beyond that the clip coverage is exactly zero).
pub fn primSpan(p: *const Prim, clips: []const ClipRect) Span {
    const c = p.coverRect();
    var s = centreSpan(c[0], c[1], c[2], c[3]);
    if (p.clip != 0 and p.clip < clips.len) {
        const b = clips[p.clip].bounds;
        s = s.intersect(centreSpan(b[0] - 1, b[1] - 1, b[0] + b[2] + 1, b[1] + b[3] + 1));
    }
    return s;
}

/// Per-tile prim index lists (counting sort; capacity kept).
pub const Bins = struct {
    /// `offsets[t]..offsets[t+1]` is tile t's range of `items`.
    offsets: std.ArrayList(u32) = .empty,
    /// Prim indices.
    items: std.ArrayList(u32) = .empty,
    /// Scratch: each prim's span.
    spans: std.ArrayList(Span) = .empty,

    /// Frees the arrays.
    pub fn deinit(b: *Bins, gpa: std.mem.Allocator) void {
        b.offsets.deinit(gpa);
        b.items.deinit(gpa);
        b.spans.deinit(gpa);
    }

    /// The prims of tile `t`, in paint order.
    pub fn tileItems(b: *const Bins, t: u32) []const u32 {
        return b.items.items[b.offsets.items[t]..b.offsets.items[t + 1]];
    }
};

/// Bins prims `range` of `prims` (only those with `layer_z == layer`) into
/// the tiles of `grid` that intersect `repaint`.
pub fn binPrims(
    gpa: std.mem.Allocator,
    prims: []const Prim,
    range: [2]u32,
    layer: u16,
    clips: []const ClipRect,
    grid: TileGrid,
    repaint: []const PxRect,
    out: *Bins,
) !void {
    const ntiles = grid.count();
    try out.offsets.resize(gpa, ntiles + 1);
    @memset(out.offsets.items, 0);
    out.items.clearRetainingCapacity();
    out.spans.clearRetainingCapacity();
    const n = range[1] - range[0];
    try out.spans.resize(gpa, n);
    const target: Span = .{ .x0 = 0, .y0 = 0, .x1 = grid.width, .y1 = grid.height };
    var bound: Span = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    for (repaint, 0..) |r, i| {
        const s = Span.fromPx(r);
        bound = if (i == 0) s else .{ .x0 = @min(bound.x0, s.x0), .y0 = @min(bound.y0, s.y0), .x1 = @max(bound.x1, s.x1), .y1 = @max(bound.y1, s.y1) };
    }
    bound = bound.intersect(target);
    const cols = grid.cols();

    // Pass 1: count.
    for (prims[range[0]..range[1]], 0..) |*p, k| {
        var s = primSpan(p, clips).intersect(bound);
        if (p.layer_z != layer) s = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
        out.spans.items[k] = s;
        if (s.empty()) continue;
        var it = tileIter(s, cols);
        while (it.next()) |t| {
            if (touchesRepaint(s, grid.tile(t), repaint)) out.offsets.items[t + 1] += 1;
        }
    }
    // Prefix sums.
    var total: u32 = 0;
    for (out.offsets.items[1..]) |*o| {
        total += o.*;
        o.* = total;
    }
    try out.items.resize(gpa, total);
    // Pass 2: fill, using offsets[t] as a cursor, then shift back.
    for (out.spans.items, 0..) |s, k| {
        if (s.empty()) continue;
        var it = tileIter(s, cols);
        while (it.next()) |t| {
            if (!touchesRepaint(s, grid.tile(t), repaint)) continue;
            out.items.items[out.offsets.items[t]] = range[0] + @as(u32, @intCast(k));
            out.offsets.items[t] += 1;
        }
    }
    var prev: u32 = 0;
    for (out.offsets.items[0..ntiles]) |*o| {
        const next = o.*;
        o.* = prev;
        prev = next;
    }
}

fn touchesRepaint(s: Span, t: TileRect, repaint: []const PxRect) bool {
    const ts: Span = .{ .x0 = t.x, .y0 = t.y, .x1 = t.x + t.w, .y1 = t.y + t.h };
    const st = s.intersect(ts);
    if (st.empty()) return false;
    for (repaint) |r| {
        if (!st.intersect(Span.fromPx(r)).empty()) return true;
    }
    return false;
}

const TileIter = struct {
    tx0: u32,
    tx1: u32,
    ty1: u32,
    tx: u32,
    ty: u32,
    cols: u32,

    fn next(it: *TileIter) ?u32 {
        if (it.ty > it.ty1) return null;
        const t = it.ty * it.cols + it.tx;
        if (it.tx == it.tx1) {
            it.tx = it.tx0;
            it.ty += 1;
        } else it.tx += 1;
        return t;
    }
};

fn tileIter(s: Span, cols: u32) TileIter {
    const tx0: u32 = @intCast(@divFloor(s.x0, tile_size));
    const ty0: u32 = @intCast(@divFloor(s.y0, tile_size));
    const tx1: u32 = @intCast(@divFloor(s.x1 - 1, tile_size));
    const ty1: u32 = @intCast(@divFloor(s.y1 - 1, tile_size));
    return .{ .tx0 = tx0, .tx1 = tx1, .ty1 = ty1, .tx = tx0, .ty = ty0, .cols = cols };
}

test "sw: centre span follows the top-left rule" {
    const s = centreSpan(0, 0, 4, 4);
    try std.testing.expectEqual(Span{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 4 }, s);
    const f = centreSpan(0.6, 0.4, 2.5, 2.6);
    try std.testing.expectEqual(Span{ .x0 = 1, .y0 = 0, .x1 = 2, .y1 = 3 }, f);
}

test "sw: bin assignment matches brute force" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var prims: [300]Prim = undefined;
    for (&prims) |*p| {
        p.* = .{
            .bounds = .{ rnd.float(f32) * 400 - 50, rnd.float(f32) * 300 - 50, rnd.float(f32) * 120, rnd.float(f32) * 90 },
            .kind = if (rnd.boolean()) .rect else .glyph_gray,
            .clip = rnd.uintLessThan(u16, 3),
            .layer_z = if (rnd.uintLessThan(u8, 10) == 0) 1 else 0,
        };
    }
    const clips = [_]ClipRect{
        .{ .bounds = .{ -1e30, -1e30, 2e30, 2e30 } },
        .{ .bounds = .{ 10, 10, 100, 100 } },
        .{ .bounds = .{ 150.5, 20.25, 70, 200 } },
    };
    const grid: TileGrid = .{ .width = 333, .height = 250 };
    const repaint = [_]PxRect{ .{ .x = 0, .y = 0, .w = 100, .h = 60 }, .{ .x = 200, .y = 130, .w = 133, .h = 120 } };
    var bins: Bins = .{};
    defer bins.deinit(gpa);
    try binPrims(gpa, &prims, .{ 0, prims.len }, 0, &clips, grid, &repaint, &bins);
    var t: u32 = 0;
    while (t < grid.count()) : (t += 1) {
        const tr = grid.tile(t);
        var want: std.ArrayList(u32) = .empty;
        defer want.deinit(gpa);
        for (&prims, 0..) |*p, i| {
            if (p.layer_z != 0) continue;
            const s = primSpan(p, &clips);
            var hit = false;
            var y = tr.y;
            while (y < tr.y + tr.h and !hit) : (y += 1) {
                var x = tr.x;
                while (x < tr.x + tr.w) : (x += 1) {
                    const in_prim = x >= s.x0 and x < s.x1 and y >= s.y0 and y < s.y1;
                    var in_rep = false;
                    for (repaint) |r| in_rep = in_rep or (x >= r.x and x < r.x + @as(i64, r.w) and y >= r.y and y < r.y + @as(i64, r.h));
                    if (in_prim and in_rep) {
                        hit = true;
                        break;
                    }
                }
            }
            if (hit) try want.append(gpa, @intCast(i));
        }
        try std.testing.expectEqualSlices(u32, want.items, bins.tileItems(t));
    }
    // Reuse keeps working with a smaller frame.
    try binPrims(gpa, prims[0..10], .{ 0, 10 }, 0, &clips, .{ .width = 64, .height = 64 }, &.{.{ .x = 0, .y = 0, .w = 64, .h = 64 }}, &bins);
    try std.testing.expectEqual(@as(usize, 2), bins.offsets.items.len);
}
