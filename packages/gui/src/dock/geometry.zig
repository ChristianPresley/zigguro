//! Dock geometry (E04.F07.S01.T01): lays a dock tree out into group
//! rectangles, and finds a group's neighbor in a direction.
//!
//! A split shares its rectangle along its axis by ratio, less `gap` per
//! splitter between children; each child gets at least `min_size` when
//! the space allows it (the ratios themselves are left alone).

const std = @import("std");
const model = @import("model.zig");

const DockModel = model.DockModel;
const GroupId = model.GroupId;
const GroupRect = model.GroupRect;
const Node = model.Node;
const Rect = model.Rect;
const Dir = model.Dir;

/// Layout options.
pub const Options = struct {
    /// Splitter thickness between siblings.
    gap: f32 = 4,
    /// The least a child gets along the split axis.
    min_size: f32 = 80,
};

/// A splitter between two children of a split (for drag handles).
pub const SplitterRect = struct { s: model.SplitId, index: u32, rect: Rect, axis: model.Axis };

/// Appends the rectangle of every group under `root` laid out in `r`
/// (and, when `splitters` is set, every splitter's). With `maximized`,
/// only that group shows, filling `r`.
pub fn layout(m: *const DockModel, root: ?Node, r: Rect, opts: Options, gpa: std.mem.Allocator, out: *std.ArrayList(GroupRect), splitters: ?*std.ArrayList(SplitterRect)) std.mem.Allocator.Error!void {
    const n = root orelse return;
    if (m.maximized) |g| if (contains(m, n, g)) return out.append(gpa, .{ .g = g, .rect = r });
    try layoutNode(m, n, r, opts, gpa, out, splitters);
}

fn contains(m: *const DockModel, n: Node, g: GroupId) bool {
    return switch (n) {
        .group => |x| x == g,
        .split => |s| blk: {
            const sp = m.splitOf(s) orelse break :blk false;
            for (sp.children.items) |c| if (contains(m, c, g)) break :blk true;
            break :blk false;
        },
    };
}

fn layoutNode(m: *const DockModel, n: Node, r: Rect, opts: Options, gpa: std.mem.Allocator, out: *std.ArrayList(GroupRect), splitters: ?*std.ArrayList(SplitterRect)) std.mem.Allocator.Error!void {
    switch (n) {
        .group => |g| try out.append(gpa, .{ .g = g, .rect = r }),
        .split => |s| {
            const sp = m.splitOf(s) orelse return;
            const k = sp.children.items.len;
            if (k == 0) return;
            const row = sp.axis == .row;
            const total = if (row) r.w else r.h;
            var sizes_buf: [64]f32 = undefined;
            const sizes = sizes_buf[0..@min(k, sizes_buf.len)];
            share(sp.ratios.items[0..sizes.len], @max(0, total - opts.gap * @as(f32, @floatFromInt(sizes.len - 1))), opts.min_size, sizes);
            var pos = if (row) r.x else r.y;
            for (sp.children.items[0..sizes.len], sizes, 0..) |c, size, i| {
                const cr: Rect = if (row) .{ .x = pos, .y = r.y, .w = size, .h = r.h } else .{ .x = r.x, .y = pos, .w = r.w, .h = size };
                try layoutNode(m, c, cr, opts, gpa, out, splitters);
                pos += size;
                if (i + 1 < sizes.len) {
                    if (splitters) |sl| try sl.append(gpa, .{
                        .s = s,
                        .index = @intCast(i),
                        .axis = sp.axis,
                        .rect = if (row) .{ .x = pos, .y = r.y, .w = opts.gap, .h = r.h } else .{ .x = r.x, .y = pos, .w = r.w, .h = opts.gap },
                    });
                    pos += opts.gap;
                }
            }
        },
    }
}

/// Splits `total` by `ratios` into `out`, raising children below `min`
/// to `min` (taken from the others in proportion) when `total` allows.
pub fn share(ratios: []const f32, total: f32, min: f32, out: []f32) void {
    for (ratios, out) |r, *o| o.* = r * total;
    const k: f32 = @floatFromInt(ratios.len);
    if (min * k > total) return;
    // Raise the small ones, then take the deficit from the rest by size.
    var deficit: f32 = 0;
    var spare: f32 = 0;
    for (out) |*o| {
        if (o.* < min) {
            deficit += min - o.*;
            o.* = min;
        } else spare += o.* - min;
    }
    if (deficit == 0 or spare <= 0) return;
    for (out) |*o| if (o.* > min) {
        o.* -= deficit * (o.* - min) / spare;
    };
}

/// The group next to `g` in `dir`: among the groups beyond `g`'s edge
/// that overlap it on the other axis, the nearest, then the most
/// overlapping.
pub fn neighbor(g: GroupId, dir: Dir, rects: []const GroupRect) ?GroupId {
    const from = for (rects) |gr| {
        if (gr.g == g) break gr.rect;
    } else return null;
    const eps: f32 = 0.5;
    var best: ?GroupId = null;
    var best_d: f32 = std.math.inf(f32);
    var best_o: f32 = 0;
    for (rects) |gr| {
        if (gr.g == g) continue;
        const c = gr.rect;
        const d: f32, const o: f32 = switch (dir) {
            .right => .{ c.x - (from.x + from.w), overlap(from.y, from.h, c.y, c.h) },
            .left => .{ from.x - (c.x + c.w), overlap(from.y, from.h, c.y, c.h) },
            .down => .{ c.y - (from.y + from.h), overlap(from.x, from.w, c.x, c.w) },
            .up => .{ from.y - (c.y + c.h), overlap(from.x, from.w, c.x, c.w) },
        };
        if (d < -eps or o <= 0) continue;
        if (d < best_d - eps or (@abs(d - best_d) <= eps and o > best_o)) {
            best = gr.g;
            best_d = d;
            best_o = o;
        }
    }
    return best;
}

fn overlap(a: f32, al: f32, b: f32, bl: f32) f32 {
    return @min(a + al, b + bl) - @max(a, b);
}
