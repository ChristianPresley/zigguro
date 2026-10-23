//! The layered graph (E13.F07.S02.T02) the layout phases share: real
//! nodes, dummy and label vertices of long edges, cluster border
//! vertices, the edges between them, and the layers once ranked and
//! ordered. Sizes are in top-to-bottom space (LR and RL swap them).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    /// A diagram node.
    node,
    /// A bend of an edge spanning several ranks.
    dummy,
    /// The middle of a labelled edge, sized like its label.
    label,
    /// A cluster's left or right side at one rank.
    border_left,
    border_right,
    /// Stands in for a subgraph with no nodes.
    placeholder,
};

pub const Vertex = struct {
    kind: Kind,
    /// The diagram node (`node`), subgraph (`border_*`, `placeholder`)
    /// or layered edge (`dummy`, `label`).
    ref: u32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    /// Room kept on the right (a self-loop).
    right_extra: f32 = 0,
    /// The innermost subgraph holding it.
    cluster: ?u32 = null,
    rank: i32 = 0,
    /// Position in its layer.
    order: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,

    pub fn isDummyLike(v: Vertex) bool {
        return v.kind == .dummy or v.kind == .label or v.kind == .border_left or v.kind == .border_right;
    }

    pub fn isBorder(v: Vertex) bool {
        return v.kind == .border_left or v.kind == .border_right;
    }
};

/// A diagram edge as the layout sees it.
pub const LEdge = struct {
    from: u32,
    to: u32,
    min_len: u32,
    weight: f32 = 1,
    /// The diagram edge.
    orig: u32,
    /// Reversed to break a cycle.
    reversed: bool = false,
    /// Label size (top-to-bottom space), when labelled.
    label: ?[2]f32 = null,
    /// The vertices from `from` to `to`, one per rank (set by
    /// normalization).
    chain: []const u32 = &.{},
};

pub const Graph = struct {
    a: Allocator,
    verts: std.ArrayList(Vertex) = .empty,
    edges: std.ArrayList(LEdge) = .empty,
    /// Neighbours one rank up and down, after normalization.
    up: [][]u32 = &.{},
    down: [][]u32 = &.{},
    /// Vertices by rank, in order.
    layers: [][]u32 = &.{},
    /// Each subgraph's parent.
    sub_parent: []const ?u32 = &.{},

    pub fn add(g: *Graph, v: Vertex) !u32 {
        try g.verts.append(g.a, v);
        return @intCast(g.verts.items.len - 1);
    }

    /// Recomputes `order` from `layers`.
    pub fn syncOrder(g: *Graph) void {
        for (g.layers) |l| for (l, 0..) |v, i| {
            g.verts.items[v].order = @intCast(i);
        };
    }

    /// Whether subgraph `c` is `inner` or one of its ancestors.
    pub fn contains(g: *const Graph, c: u32, inner: ?u32) bool {
        var x = inner;
        while (x) |s| : (x = g.sub_parent[s]) if (s == c) return true;
        return false;
    }

    pub fn depth(g: *const Graph, c: ?u32) u32 {
        var d: u32 = 0;
        var x = c;
        while (x) |s| : (x = g.sub_parent[s]) d += 1;
        return d;
    }

    /// The innermost subgraph holding both `a` and `b`.
    pub fn lca(g: *const Graph, a: ?u32, b: ?u32) ?u32 {
        var x = a;
        var da = g.depth(a);
        var y = b;
        var db = g.depth(b);
        while (da > db) : (da -= 1) x = g.sub_parent[x.?];
        while (db > da) : (db -= 1) y = g.sub_parent[y.?];
        while (x != y) {
            x = g.sub_parent[x.?];
            y = g.sub_parent[y.?];
        }
        return x;
    }

    /// The subgraphs holding `c`, outermost first, into `buf`.
    pub fn path(g: *const Graph, c: ?u32, buf: []u32) []u32 {
        const d = g.depth(c);
        var x = c;
        var i = d;
        while (x) |s| : (x = g.sub_parent[s]) {
            i -= 1;
            buf[i] = s;
        }
        return buf[0..d];
    }
};

test {
    std.testing.refAllDecls(@This());
}
