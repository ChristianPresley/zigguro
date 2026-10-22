//! The hit-test index: hit-testable nodes' clipped absolute rectangles in
//! paint order, rebuilt by every paint pass. Queries scan topmost-first;
//! a uniform grid of buckets keeps them sub-linear on large trees.

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");

const Rect = geom.Rect;
const Vec2 = geom.Vec2;
const NodeId = ids.NodeId;

/// One hit-testable rectangle.
pub const Entry = struct { rect: Rect, node: NodeId };

/// Hit-test rectangles of one window.
pub const HitIndex = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Bucket grid: `cell` px squares; each bucket lists entry indices.
    cell: f32 = 128,
    cols: u32 = 0,
    rows: u32 = 0,
    bucket_start: std.ArrayList(u32) = .empty,
    bucket_items: std.ArrayList(u32) = .empty,
    fill: std.ArrayList(u32) = .empty,
    built: bool = false,

    /// Frees the index.
    pub fn deinit(h: *HitIndex, gpa: std.mem.Allocator) void {
        h.entries.deinit(gpa);
        h.bucket_start.deinit(gpa);
        h.bucket_items.deinit(gpa);
        h.fill.deinit(gpa);
    }

    /// Empties the index (keeps capacity).
    pub fn clear(h: *HitIndex) void {
        h.entries.clearRetainingCapacity();
        h.built = false;
    }

    /// Appends `node` at `rect`; later entries are on top.
    pub fn add(h: *HitIndex, gpa: std.mem.Allocator, rect: Rect, node: NodeId) !void {
        if (rect.isEmpty()) return;
        try h.entries.append(gpa, .{ .rect = rect, .node = node });
        h.built = false;
    }

    /// Builds the bucket grid for a viewport of `size` (call after the
    /// paint pass; cheap when the index is small).
    pub fn finish(h: *HitIndex, gpa: std.mem.Allocator, size: geom.Size) !void {
        h.built = false;
        if (h.entries.items.len < 64) return; // linear scan is faster
        h.cols = @max(1, @as(u32, @intFromFloat(@ceil(size.w / h.cell))));
        h.rows = @max(1, @as(u32, @intFromFloat(@ceil(size.h / h.cell))));
        const n = h.cols * h.rows;
        try h.bucket_start.resize(gpa, n + 1);
        @memset(h.bucket_start.items, 0);
        // Count, prefix-sum, fill (entries in paint order per bucket).
        for (h.entries.items) |e| {
            var it = h.cells(e.rect);
            while (it.next()) |b| h.bucket_start.items[b + 1] += 1;
        }
        for (1..n + 1) |i| h.bucket_start.items[i] += h.bucket_start.items[i - 1];
        try h.bucket_items.resize(gpa, h.bucket_start.items[n]);
        try h.fill.resize(gpa, n);
        const fill = h.fill.items;
        @memcpy(fill, h.bucket_start.items[0..n]);
        for (h.entries.items, 0..) |e, idx| {
            var it = h.cells(e.rect);
            while (it.next()) |b| {
                h.bucket_items.items[fill[b]] = @intCast(idx);
                fill[b] += 1;
            }
        }
        h.built = true;
    }

    const CellIter = struct {
        x0: u32,
        x1: u32,
        y1: u32,
        x: u32,
        y: u32,
        cols: u32,
        fn next(it: *CellIter) ?u32 {
            if (it.y > it.y1) return null;
            const b = it.y * it.cols + it.x;
            if (it.x == it.x1) {
                it.x = it.x0;
                it.y += 1;
            } else it.x += 1;
            return b;
        }
    };

    fn cellOf(h: *const HitIndex, v: f32, n: u32) u32 {
        const c = @floor(v / h.cell);
        if (!(c > 0)) return 0;
        return @min(n - 1, @as(u32, @intFromFloat(c)));
    }

    fn cells(h: *const HitIndex, r: Rect) CellIter {
        const x0 = h.cellOf(r.x, h.cols);
        const y0 = h.cellOf(r.y, h.rows);
        return .{ .x0 = x0, .x1 = h.cellOf(r.right() - 0.001, h.cols), .y1 = h.cellOf(r.bottom() - 0.001, h.rows), .x = x0, .y = y0, .cols = h.cols };
    }

    /// The topmost node whose rectangle contains `p`, or `none`.
    pub fn hit(h: *const HitIndex, p: Vec2) NodeId {
        if (h.built) {
            const b = h.cellOf(p.y, h.rows) * h.cols + h.cellOf(p.x, h.cols);
            const items = h.bucket_items.items[h.bucket_start.items[b]..h.bucket_start.items[b + 1]];
            var i = items.len;
            while (i > 0) {
                i -= 1;
                const e = h.entries.items[items[i]];
                if (e.rect.contains(p)) return e.node;
            }
            return .none;
        }
        var i = h.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (h.entries.items[i].rect.contains(p)) return h.entries.items[i].node;
        }
        return .none;
    }
};

test "topmost wins, grid matches linear" {
    const gpa = std.testing.allocator;
    var h: HitIndex = .{};
    defer h.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var i: u24 = 1;
    while (i <= 500) : (i += 1) {
        try h.add(gpa, .{ .x = r.float(f32) * 900, .y = r.float(f32) * 600, .w = 5 + r.float(f32) * 100, .h = 5 + r.float(f32) * 60 }, .{ .index = i, .gen = 1 });
    }
    var linear: [200]NodeId = undefined;
    var pts: [200]Vec2 = undefined;
    for (&pts, &linear) |*p, *l| {
        p.* = .{ .x = r.float(f32) * 1000, .y = r.float(f32) * 700 };
        l.* = h.hit(p.*);
    }
    try h.finish(gpa, .{ .w = 1000, .h = 700 });
    try std.testing.expect(h.built);
    for (pts, linear) |p, l| try std.testing.expect(h.hit(p).eql(l));
}
