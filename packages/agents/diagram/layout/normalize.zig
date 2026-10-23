//! Normalization (E13.F07.S02.T02): edges spanning several ranks get a
//! dummy vertex per rank (a labelled edge's middle one is sized like its
//! label), then the layers and the one-rank neighbour lists are built.

const std = @import("std");
const graph = @import("graph.zig");

const Graph = graph.Graph;

/// Splits every edge into one-rank segments, setting each edge's chain.
/// Dummies sit in the innermost subgraph holding both ends.
pub fn splitEdges(g: *Graph) !void {
    for (g.edges.items, 0..) |*e, ei| {
        const r0 = g.verts.items[e.from].rank;
        const r1 = g.verts.items[e.to].rank;
        std.debug.assert(r1 > r0);
        const span: usize = @intCast(r1 - r0);
        const chain = try g.a.alloc(u32, span + 1);
        chain[0] = e.from;
        chain[span] = e.to;
        const cluster = g.lca(g.verts.items[e.from].cluster, g.verts.items[e.to].cluster);
        const mid = span / 2;
        for (1..span) |k| {
            const is_label = e.label != null and k == mid;
            const sz = if (is_label) e.label.? else [2]f32{ 0, 0 };
            chain[k] = try g.add(.{
                .kind = if (is_label) .label else .dummy,
                .ref = @intCast(ei),
                .w = sz[0],
                .h = sz[1],
                .cluster = cluster,
                .rank = r0 + @as(i32, @intCast(k)),
            });
        }
        e.chain = chain;
    }
}

/// Builds `layers` (vertices by rank, in index order) and the
/// neighbour lists: chain segments, plus each border vertex linked to
/// the one a rank below on the same side.
pub fn buildLayers(g: *Graph, border_links: []const [2]u32) !void {
    const a = g.a;
    var max_rank: i32 = 0;
    for (g.verts.items) |v| max_rank = @max(max_rank, v.rank);
    const n_ranks: usize = if (g.verts.items.len == 0) 0 else @intCast(max_rank + 1);
    var lists = try a.alloc(std.ArrayList(u32), n_ranks);
    for (lists) |*l| l.* = .empty;
    for (g.verts.items, 0..) |v, i| try lists[@intCast(v.rank)].append(a, @intCast(i));
    g.layers = try a.alloc([]u32, n_ranks);
    for (g.layers, lists) |*l, li| l.* = li.items;

    const n = g.verts.items.len;
    var up = try a.alloc(std.ArrayList(u32), n);
    var down = try a.alloc(std.ArrayList(u32), n);
    for (up) |*l| l.* = .empty;
    for (down) |*l| l.* = .empty;
    for (g.edges.items) |e| for (e.chain[0 .. e.chain.len - 1], e.chain[1..]) |u, w| {
        try down[u].append(a, w);
        try up[w].append(a, u);
    };
    for (border_links) |l| {
        try down[l[0]].append(a, l[1]);
        try up[l[1]].append(a, l[0]);
    }
    g.up = try a.alloc([]u32, n);
    g.down = try a.alloc([]u32, n);
    for (g.up, up) |*d, s| d.* = s.items;
    for (g.down, down) |*d, s| d.* = s.items;
    g.syncOrder();
}

test {
    std.testing.refAllDecls(@This());
}
