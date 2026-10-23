//! Flowchart layout (E13.F07.S02.T02): the layered (Sugiyama) framework
//! over a parsed `Diagram` — cycle removal, layering, normalization,
//! cluster-aware ordering, Brandes–Köpf coordinates, edge routing —
//! giving a `Layout` of boxes and Bézier paths any renderer can draw.
//! Layout runs top to bottom; LR, RL and BT transform the result.

const std = @import("std");
const ast = @import("../ast.zig");
pub const graph = @import("graph.zig");
pub const acyclic = @import("acyclic.zig");
pub const layering = @import("layering.zig");
pub const normalize = @import("normalize.zig");
pub const ordering = @import("ordering.zig");
pub const coords = @import("coords.zig");
pub const clusters = @import("clusters.zig");
pub const routing = @import("routing.zig");
pub const shapes_geom = @import("shapes_geom.zig");

const Allocator = std.mem.Allocator;
const Diagram = ast.Diagram;

/// Measures label text: its size when wrapped at `max_w`.
pub const Measure = struct {
    ctx: *anyopaque,
    text: *const fn (ctx: *anyopaque, s: []const u8, max_w: f32) [2]f32,
};

pub const LayoutOpts = struct {
    node_sep: f32 = 40,
    rank_sep: f32 = 50,
    edge_sep: f32 = 10,
    cluster_pad: f32 = 16,
    max_sweeps: u8 = 24,
    /// Sweeps without improvement before ordering stops.
    ordering_patience: u8 = 4,
    /// Orderings tried from different starts at least; small graphs
    /// get more (see `ordering.restartsFor`). The best wins.
    ordering_restarts: u8 = 1,
    /// Labels wrap at this width.
    max_label_w: f32 = 240,
    margin: f32 = 8,
};

pub const NodeBox = shapes_geom.NodeBox;

pub const EdgePath = struct {
    edge: u32,
    /// Cubic Bézier control points (3n+1), from the edge's `from` end to
    /// its `to` end.
    points: []const [2]f32,
    /// The label's box (`node` holds the edge index).
    label: ?NodeBox,
    /// Laid out against its direction to break a cycle.
    reversed: bool,
};

pub const ClusterBox = struct { subgraph: u32, x: f32, y: f32, w: f32, h: f32, title_h: f32 };

pub const Layout = struct {
    /// One per diagram node, in order.
    nodes: []const NodeBox,
    /// One per diagram edge, in order.
    edges: []const EdgePath,
    /// One per subgraph, in order.
    clusters: []const ClusterBox,
    size: [2]f32,
};

pub const shapeBoundary = shapes_geom.shapeBoundary;

const self_loop: f32 = 16;
const label_pad: [2]f32 = .{ 4, 2 };
const placeholder: [2]f32 = .{ 40, 24 };

/// The layered graph through ordering, and what layout needs from the
/// diagram for the rest.
const Prepared = struct {
    g: graph.Graph,
    horizontal: bool,
    sizes: [][2]f32,
    rep: []u32,
    label_sizes: []?[2]f32,
    loops: []const u32,
    spans: []?clusters.Span,
    rank_sep: f32,
};

pub fn prepareForTest(arena: Allocator, d: *const Diagram, m: Measure, opts: LayoutOpts) !Prepared {
    return prepare(arena, d, m, opts);
}

fn prepare(arena: Allocator, d: *const Diagram, m: Measure, opts: LayoutOpts) !Prepared {
    const a = arena;
    const horizontal = d.dir == .LR or d.dir == .RL;
    const ns = d.subgraphs.len;
    var g: graph.Graph = .{ .a = a };

    // The subgraph tree, and each node's innermost subgraph.
    const sub_parent = try a.alloc(?u32, ns);
    @memset(sub_parent, null);
    for (d.subgraphs, 0..) |s, i| for (s.children) |c| {
        sub_parent[c] = @intCast(i);
    };
    g.sub_parent = sub_parent;
    const node_sub = try a.alloc(?u32, d.nodes.len);
    @memset(node_sub, null);
    for (d.subgraphs, 0..) |s, i| for (s.members) |n| {
        node_sub[n] = @intCast(i);
    };

    // Nodes, sized in top-to-bottom space.
    const sizes = try a.alloc([2]f32, d.nodes.len);
    for (d.nodes, 0..) |n, i| {
        sizes[i] = shapes_geom.nodeSize(n.shape, m.text(m.ctx, n.label, opts.max_label_w));
        const s = tb(sizes[i], horizontal);
        _ = try g.add(.{ .kind = .node, .ref = @intCast(i), .w = s[0], .h = s[1], .cluster = node_sub[i] });
    }
    // A vertex to stand for each subgraph in edges to it: its first
    // node, or a placeholder when it has none.
    const rep = try a.alloc(u32, ns);
    for (0..ns) |s| rep[s] = try representative(&g, d, @intCast(s), horizontal);

    // Edges; self-loops are drawn beside their node.
    var labelled = false;
    const label_sizes = try a.alloc(?[2]f32, d.edges.len);
    for (d.edges, 0..) |e, i| {
        label_sizes[i] = if (e.label) |l| blk: {
            const s = m.text(m.ctx, l, opts.max_label_w);
            break :blk .{ s[0] + 2 * label_pad[0], s[1] + 2 * label_pad[1] };
        } else null;
    }
    var loops: std.ArrayList(u32) = .empty;
    for (d.edges, 0..) |e, i| {
        const from = if (e.from_kind == .node) e.from else rep[e.from];
        const to = if (e.to_kind == .node) e.to else rep[e.to];
        if (from == to) {
            try loops.append(a, @intCast(i));
            const lw = if (label_sizes[i]) |s| tb(s, horizontal)[0] + 4 else 0;
            const v = &g.verts.items[from];
            v.right_extra = @max(v.right_extra, self_loop * 1.6 + 8 + lw);
            continue;
        }
        const lab: ?[2]f32 = if (label_sizes[i]) |s| tb(s, horizontal) else null;
        labelled = labelled or lab != null;
        try g.edges.append(a, .{ .from = from, .to = to, .min_len = 1 + @as(u32, e.min_len), .orig = @intCast(i), .label = lab });
    }
    // Labels sit on a rank of their own between their ends.
    var rank_sep = opts.rank_sep;
    if (labelled) {
        for (g.edges.items) |*e| e.min_len *= 2;
        rank_sep /= 2;
    }

    const n_real = g.verts.items.len;
    _ = try acyclic.removeCycles(a, n_real, g.edges.items);
    const ranks = try layering.assignRanks(a, n_real, g.edges.items);
    for (g.verts.items, ranks) |*v, r| v.rank = r;
    try normalize.splitEdges(&g);
    const spans = try clusters.rankSpans(&g, ns);
    const links = try clusters.addBorders(&g, spans);
    try normalize.buildLayers(&g, links);
    try ordering.orderOpts(&g, .{ .max_sweeps = opts.max_sweeps, .patience = opts.ordering_patience, .restarts = opts.ordering_restarts });
    return .{ .g = g, .horizontal = horizontal, .sizes = sizes, .rep = rep, .label_sizes = label_sizes, .loops = loops.items, .spans = spans, .rank_sep = rank_sep };
}

/// The edge crossings of `d`'s ordered layers (tests and tuning).
pub fn crossings(arena: Allocator, d: *const Diagram, m: Measure, opts: LayoutOpts) !u64 {
    const p = try prepare(arena, d, m, opts);
    return ordering.crossings(arena, &p.g);
}

/// Lays out `d` (all memory from `arena`).
pub fn layout(arena: Allocator, d: *const Diagram, m: Measure, opts: LayoutOpts) !Layout {
    const a = arena;
    var prep = try prepare(arena, d, m, opts);
    const g = &prep.g;
    const horizontal = prep.horizontal;
    const ns = d.subgraphs.len;
    const sizes = prep.sizes;
    const rep = prep.rep;
    const label_sizes = prep.label_sizes;
    const spans = prep.spans;
    const rank_sep = prep.rank_sep;

    // Cluster titles: on top, which is the top-to-bottom left side when
    // the layout is turned.
    const title_h = try a.alloc(f32, ns);
    for (d.subgraphs, 0..) |s, i| title_h[i] = if (s.title.len == 0) 0 else m.text(m.ctx, s.title, opts.max_label_w)[1] + 8;
    const zero = try a.alloc(f32, ns);
    @memset(zero, 0);
    const co: coords.Opts = .{ .node_sep = opts.node_sep, .rank_sep = rank_sep, .edge_sep = opts.edge_sep, .cluster_pad = opts.cluster_pad };
    if (horizontal) {
        // Room for the title inside the left border.
        for (g.verts.items) |*v| if (v.kind == .border_left) {
            v.right_extra = title_h[v.ref];
        };
    }
    try coords.assignX(g, co);
    try coords.straightenClusters(g, ns, co);
    const top_title = if (d.dir == .TB) title_h else zero;
    const bottom_title = if (d.dir == .BT) title_h else zero;
    try coords.assignY(g, spans, top_title, bottom_title, rank_sep, co);
    const tb_boxes = try clusters.boxes(g, spans, opts.cluster_pad, top_title, bottom_title);

    // To the diagram's direction.
    const tf = Transform{ .dir = d.dir };
    for (g.verts.items) |*v| {
        const p = tf.point(.{ v.x, v.y });
        v.x = p[0];
        v.y = p[1];
    }
    const nodes = try a.alloc(NodeBox, d.nodes.len);
    for (nodes, 0..) |*b, i| {
        const v = g.verts.items[i];
        b.* = .{ .node = @intCast(i), .x = v.x, .y = v.y, .w = sizes[i][0], .h = sizes[i][1] };
    }
    const cboxes = try a.alloc(ClusterBox, ns);
    const rects = try a.alloc(routing.Rect, ns);
    for (cboxes, rects, 0..) |*cb, *rect, i| {
        const b = tb_boxes[i] orelse clusters.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
        const p = tf.point(.{ b.x0, b.y0 });
        const q = tf.point(.{ b.x1, b.y1 });
        rect.* = .{ .x0 = @min(p[0], q[0]), .y0 = @min(p[1], q[1]), .x1 = @max(p[0], q[0]), .y1 = @max(p[1], q[1]) };
        cb.* = .{ .subgraph = @intCast(i), .x = rect.x0, .y = rect.y0, .w = rect.x1 - rect.x0, .h = rect.y1 - rect.y0, .title_h = title_h[i] };
    }

    // Routes.
    const paths = try a.alloc(EdgePath, d.edges.len);
    var pts: std.ArrayList([2]f32) = .empty;
    for (g.edges.items) |e| {
        const de = d.edges[e.orig];
        pts.clearRetainingCapacity();
        for (e.chain) |v| try pts.append(a, .{ g.verts.items[v].x, g.verts.items[v].y });
        if (e.reversed) std.mem.reverse([2]f32, pts.items);
        // pts now runs from the diagram edge's `from` to its `to`.
        const from_v = if (e.reversed) e.chain[e.chain.len - 1] else e.chain[0];
        const to_v = if (e.reversed) e.chain[0] else e.chain[e.chain.len - 1];
        try endPort(g, d, nodes, rects, &pts, from_v, de.from_kind, de.from, false);
        try endPort(g, d, nodes, rects, &pts, to_v, de.to_kind, de.to, true);
        var label: ?NodeBox = null;
        for (e.chain) |v| if (g.verts.items[v].kind == .label) {
            const s = label_sizes[e.orig].?;
            label = .{ .node = e.orig, .x = g.verts.items[v].x, .y = g.verts.items[v].y, .w = s[0], .h = s[1] };
        };
        paths[e.orig] = .{ .edge = e.orig, .points = try routing.bezier(a, pts.items), .label = label, .reversed = e.reversed };
    }
    for (prep.loops) |ei| {
        const de = d.edges[ei];
        const vi = if (de.from_kind == .node) de.from else rep[de.from];
        const v = g.verts.items[vi];
        const shape: ast.Shape = if (v.kind == .node) d.nodes[v.ref].shape else .rect;
        const box: NodeBox = if (v.kind == .node) nodes[v.ref] else .{ .node = 0, .x = v.x, .y = v.y, .w = placeholder[0], .h = placeholder[1] };
        const ctrl = try routing.selfLoop(a, shape, box, self_loop, horizontal);
        var label: ?NodeBox = null;
        if (label_sizes[ei]) |s| label = if (horizontal)
            .{ .node = ei, .x = box.x, .y = box.y + box.h / 2 + self_loop * 1.6 + 4 + s[1] / 2, .w = s[0], .h = s[1] }
        else
            .{ .node = ei, .x = box.x + box.w / 2 + self_loop * 1.6 + 4 + s[0] / 2, .y = box.y, .w = s[0], .h = s[1] };
        paths[ei] = .{ .edge = ei, .points = ctrl, .label = label, .reversed = false };
    }

    // Move everything to start at the margin.
    var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    const grow = struct {
        fn f(l: *[2]f32, h: *[2]f32, x0: f32, y0: f32, x1: f32, y1: f32) void {
            l[0] = @min(l[0], x0);
            l[1] = @min(l[1], y0);
            h[0] = @max(h[0], x1);
            h[1] = @max(h[1], y1);
        }
    }.f;
    for (nodes) |b| grow(&lo, &hi, b.x - b.w / 2, b.y - b.h / 2, b.x + b.w / 2, b.y + b.h / 2);
    for (cboxes) |b| if (b.w > 0) grow(&lo, &hi, b.x, b.y, b.x + b.w, b.y + b.h);
    for (paths) |p| {
        for (p.points) |q| grow(&lo, &hi, q[0], q[1], q[0], q[1]);
        if (p.label) |b| grow(&lo, &hi, b.x - b.w / 2, b.y - b.h / 2, b.x + b.w / 2, b.y + b.h / 2);
    }
    if (!std.math.isFinite(lo[0])) {
        lo = .{ 0, 0 };
        hi = .{ 0, 0 };
    }
    const dx = opts.margin - lo[0];
    const dy = opts.margin - lo[1];
    for (nodes) |*b| {
        b.x += dx;
        b.y += dy;
    }
    for (cboxes) |*b| {
        b.x += dx;
        b.y += dy;
    }
    for (paths) |*p| {
        const q = @constCast(p.points);
        for (q) |*pt| pt.* = .{ pt[0] + dx, pt[1] + dy };
        if (p.label) |*b| {
            b.x += dx;
            b.y += dy;
        }
    }
    return .{
        .nodes = nodes,
        .edges = paths,
        .clusters = cboxes,
        .size = .{ hi[0] - lo[0] + 2 * opts.margin, hi[1] - lo[1] + 2 * opts.margin },
    };
}

/// `s` in top-to-bottom space.
fn tb(s: [2]f32, horizontal: bool) [2]f32 {
    return if (horizontal) .{ s[1], s[0] } else s;
}

const Transform = struct {
    dir: ast.Dir,

    fn point(t: Transform, p: [2]f32) [2]f32 {
        return switch (t.dir) {
            .TB => p,
            .BT => .{ p[0], -p[1] },
            .LR => .{ p[1], p[0] },
            .RL => .{ -p[1], p[0] },
        };
    }
};

/// The first node in subgraph `s` (depth first), or a new placeholder.
fn representative(g: *graph.Graph, d: *const Diagram, s: u32, horizontal: bool) !u32 {
    if (firstNode(d, s)) |n| return n;
    const sz = tb(placeholder, horizontal);
    return g.add(.{ .kind = .placeholder, .ref = s, .w = sz[0], .h = sz[1], .cluster = s });
}

fn firstNode(d: *const Diagram, s: u32) ?u32 {
    const sg = d.subgraphs[s];
    if (sg.members.len > 0) return sg.members[0];
    for (sg.children) |c| if (firstNode(d, c)) |n| return n;
    return null;
}

/// Ends the polyline on the node's outline, or on the subgraph's box
/// when the edge goes to a subgraph.
fn endPort(g: *const graph.Graph, d: *const Diagram, nodes: []const NodeBox, rects: []const routing.Rect, pts: *std.ArrayList([2]f32), v: u32, kind: ast.End, ref: u32, at_end: bool) !void {
    const p = pts.items;
    if (kind == .subgraph) {
        if (routing.clipToRect(pts, rects[ref], at_end)) return;
    }
    const vx = g.verts.items[v];
    const other = if (at_end) p[p.len - 2] else p[1];
    const port = if (vx.kind == .node)
        shapes_geom.shapeBoundary(d.nodes[vx.ref].shape, nodes[vx.ref], other)
    else
        shapes_geom.shapeBoundary(.rect, .{ .node = 0, .x = vx.x, .y = vx.y, .w = placeholder[0], .h = placeholder[1] }, other);
    if (at_end) p[p.len - 1] = port else p[0] = port;
}

test {
    std.testing.refAllDecls(@This());
}
