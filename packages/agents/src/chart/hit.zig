//! Hover hit testing (E13.F07.S01.T03): a uniform grid over the marks'
//! bounding boxes; the nearest mark within 8 px of the pointer wins,
//! the topmost among equals.

const std = @import("std");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;

pub const radius: f32 = 8;

/// Something hoverable: a bar, a point, a line vertex.
pub const Target = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    /// The data row it shows.
    row: u32,
    /// The mark item it belongs to.
    item: u32,

    pub fn distance(t: Target, p: [2]f32) f32 {
        const dx: f32 = @max(@max(t.x0 - p[0], p[0] - t.x1), 0);
        const dy: f32 = @max(@max(t.y0 - p[1], p[1] - t.y1), 0);
        return @sqrt(dx * dx + dy * dy);
    }
};

pub const Index = struct {
    targets: []const Target = &.{},
    origin: [2]f32 = .{ 0, 0 },
    cell: f32 = 32,
    cols: u32 = 0,
    rows: u32 = 0,
    /// Per cell, the targets touching it (`starts` delimits).
    starts: []const u32 = &.{},
    ids: []const u32 = &.{},

    pub fn build(a: Allocator, targets: []const Target, bounds: layout.Box, cell: f32) !Index {
        var ix: Index = .{ .targets = targets, .origin = .{ bounds.x - radius, bounds.y - radius }, .cell = cell };
        ix.cols = @intFromFloat(@max(1, @ceil((bounds.w + 2 * radius) / cell)));
        ix.rows = @intFromFloat(@max(1, @ceil((bounds.h + 2 * radius) / cell)));
        const n = @as(usize, ix.cols) * ix.rows;
        const counts = try a.alloc(u32, n + 1);
        @memset(counts, 0);
        for (targets) |t| {
            const r = ix.cells(t.x0, t.y0, t.x1, t.y1) orelse continue;
            var y = r[1];
            while (y <= r[3]) : (y += 1) {
                var x = r[0];
                while (x <= r[2]) : (x += 1) counts[y * ix.cols + x + 1] += 1;
            }
        }
        for (1..n + 1) |i| counts[i] += counts[i - 1];
        const ids = try a.alloc(u32, counts[n]);
        const fill = try a.dupe(u32, counts[0..n]);
        for (targets, 0..) |t, ti| {
            const r = ix.cells(t.x0, t.y0, t.x1, t.y1) orelse continue;
            var y = r[1];
            while (y <= r[3]) : (y += 1) {
                var x = r[0];
                while (x <= r[2]) : (x += 1) {
                    const c = y * ix.cols + x;
                    ids[fill[c]] = @intCast(ti);
                    fill[c] += 1;
                }
            }
        }
        ix.starts = counts;
        ix.ids = ids;
        return ix;
    }

    /// The cell range `[x0, y0, x1, y1]` (inclusive) a box touches.
    fn cells(ix: *const Index, x0: f32, y0: f32, x1: f32, y1: f32) ?[4]usize {
        if (!(x0 <= x1 and y0 <= y1)) return null;
        const cx0 = ix.cellOf(x0, 0);
        const cy0 = ix.cellOf(y0, 1);
        const cx1 = ix.cellOf(x1, 0);
        const cy1 = ix.cellOf(y1, 1);
        if (cx1 < 0 or cy1 < 0 or cx0 >= ix.cols or cy0 >= ix.rows) return null;
        return .{ @intCast(@max(cx0, 0)), @intCast(@max(cy0, 0)), @intCast(@min(cx1, ix.cols - 1)), @intCast(@min(cy1, ix.rows - 1)) };
    }

    fn cellOf(ix: *const Index, v: f32, axis: usize) i64 {
        if (!std.math.isFinite(v)) return if (v > 0) std.math.maxInt(i32) else -1;
        const c: f32 = @floor((v - ix.origin[axis]) / ix.cell);
        const lim: f32 = 1 << 30;
        return @intFromFloat(@max(-1.0, @min(c, lim)));
    }

    /// The target nearest `p` within `radius` (the last one drawn on ties).
    pub fn nearest(ix: *const Index, p: [2]f32) ?u32 {
        const r = ix.cells(p[0] - radius, p[1] - radius, p[0] + radius, p[1] + radius) orelse return null;
        var best: ?u32 = null;
        var best_d: f32 = radius + 1e-3;
        var y = r[1];
        while (y <= r[3]) : (y += 1) {
            var x = r[0];
            while (x <= r[2]) : (x += 1) {
                const c = y * ix.cols + x;
                for (ix.ids[ix.starts[c]..ix.starts[c + 1]]) |id| {
                    const d = ix.targets[id].distance(p);
                    if (d < best_d or (d == best_d and best != null and id > best.?)) {
                        best_d = d;
                        best = id;
                    }
                }
            }
        }
        return best;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "nearest within the radius" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const targets = [_]Target{
        .{ .x0 = 10, .y0 = 10, .x1 = 20, .y1 = 50, .row = 0, .item = 0 },
        .{ .x0 = 100, .y0 = 100, .x1 = 100, .y1 = 100, .row = 1, .item = 1 },
    };
    const ix = try Index.build(arena.allocator(), &targets, .{ .w = 200, .h = 200 }, 32);
    try std.testing.expectEqual(0, ix.nearest(.{ 15, 30 }).?);
    try std.testing.expectEqual(1, ix.nearest(.{ 105, 104 }).?);
    try std.testing.expectEqual(null, ix.nearest(.{ 150, 150 }));
}
