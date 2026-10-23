//! Clusters (E13.F07.S02.T02): each subgraph gets a left and a right
//! border vertex on every rank it spans, so ordering keeps its members
//! between them and coordinate assignment keeps them straight; its box
//! is then read off the borders and its contents.

const std = @import("std");
const graph = @import("graph.zig");

const Graph = graph.Graph;

pub const Span = struct { lo: i32, hi: i32 };

/// The ranks each subgraph's vertices span (null: none).
pub fn rankSpans(g: *const Graph, n_subs: usize) ![]?Span {
    const out = try g.a.alloc(?Span, n_subs);
    @memset(out, null);
    for (g.verts.items) |v| {
        if (v.isBorder()) continue;
        var c = v.cluster;
        while (c) |s| : (c = g.sub_parent[s]) {
            if (out[s]) |*sp| {
                sp.lo = @min(sp.lo, v.rank);
                sp.hi = @max(sp.hi, v.rank);
            } else out[s] = .{ .lo = v.rank, .hi = v.rank };
        }
    }
    // A cluster spans at least its children.
    return out;
}

/// Adds the border vertices; returns the vertical links between them.
pub fn addBorders(g: *Graph, spans: []const ?Span) ![]const [2]u32 {
    var links: std.ArrayList([2]u32) = .empty;
    for (spans, 0..) |sp_opt, c| {
        const sp = sp_opt orelse continue;
        var prev: [2]?u32 = .{ null, null };
        var r = sp.lo;
        while (r <= sp.hi) : (r += 1) {
            const l = try g.add(.{ .kind = .border_left, .ref = @intCast(c), .cluster = @intCast(c), .rank = r });
            const rr = try g.add(.{ .kind = .border_right, .ref = @intCast(c), .cluster = @intCast(c), .rank = r });
            if (prev[0]) |p| try links.append(g.a, .{ p, l });
            if (prev[1]) |p| try links.append(g.a, .{ p, rr });
            prev = .{ l, rr };
        }
    }
    return links.items;
}

pub const Box = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// Each subgraph's box: between its border vertices across, and from
/// `pad` above its top contents to `pad` below its bottom ones, plus
/// its title's height on the side it goes; nested boxes are inside
/// their parents'.
pub fn boxes(g: *const Graph, spans: []const ?Span, pad: f32, title_top: []const f32, title_bottom: []const f32) ![]?Box {
    const n = spans.len;
    const out = try g.a.alloc(?Box, n);
    @memset(out, null);
    // Deepest first, so children are known when their parent is boxed.
    const order = try g.a.alloc(u32, n);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, g, struct {
        fn gt(gg: *const Graph, x: u32, y: u32) bool {
            const dx = gg.depth(x);
            const dy = gg.depth(y);
            return if (dx != dy) dx > dy else x < y;
        }
    }.gt);
    for (order) |c| {
        if (spans[c] == null) continue;
        var b: Box = .{ .x0 = std.math.inf(f32), .y0 = std.math.inf(f32), .x1 = -std.math.inf(f32), .y1 = -std.math.inf(f32) };
        for (g.verts.items) |v| {
            if (v.cluster != c) continue;
            if (v.isBorder()) {
                b.x0 = @min(b.x0, v.x);
                b.x1 = @max(b.x1, v.x);
            } else if (v.kind == .node or v.kind == .placeholder or v.kind == .label) {
                b.y0 = @min(b.y0, v.y - v.h / 2);
                b.y1 = @max(b.y1, v.y + v.h / 2);
            } else {
                b.y0 = @min(b.y0, v.y);
                b.y1 = @max(b.y1, v.y);
            }
        }
        for (0..n) |k| if (g.sub_parent[k] == c) if (out[k]) |cb| {
            b.y0 = @min(b.y0, cb.y0);
            b.y1 = @max(b.y1, cb.y1);
        };
        out[c] = .{ .x0 = b.x0, .x1 = b.x1, .y0 = b.y0 - pad - title_top[c], .y1 = b.y1 + pad + title_bottom[c] };
    }
    return out;
}

test {
    std.testing.refAllDecls(@This());
}
