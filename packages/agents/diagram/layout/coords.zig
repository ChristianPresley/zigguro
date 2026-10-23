//! Coordinates (E13.F07.S02.T02). Across: Brandes–Köpf — four vertical
//! alignments (up/down × left/right) along median neighbours, with
//! segments between dummies kept straight by marking the segments that
//! cross them; each alignment compacted against the vertices' widths;
//! the result the average of the two middle values of the four after
//! aligning them to the narrowest. Down: ranks spaced by their tallest
//! vertex plus the gap the clusters starting and ending there need.

const std = @import("std");
const graph = @import("graph.zig");
const clusters = @import("clusters.zig");

const Allocator = std.mem.Allocator;
const Graph = graph.Graph;

pub const Opts = struct {
    node_sep: f32,
    rank_sep: f32,
    edge_sep: f32,
    cluster_pad: f32,
};

/// The least distance between the centres of `v` and `w` when `v` is
/// left of `w` in a layer.
pub fn sep(g: *const Graph, v: u32, w: u32, o: Opts) f32 {
    const a = g.verts.items[v];
    const b = g.verts.items[w];
    const gap: f32 = blk: {
        if (a.kind == .border_left and b.cluster != null and g.contains(a.cluster.?, b.cluster)) break :blk o.cluster_pad;
        if (b.kind == .border_right and a.cluster != null and g.contains(b.cluster.?, a.cluster)) break :blk o.cluster_pad;
        if (a.isBorder() or b.isBorder()) break :blk o.node_sep;
        const da = a.kind == .dummy;
        const db = b.kind == .dummy;
        if (da and db) break :blk o.edge_sep;
        if (da or db) break :blk (o.node_sep + o.edge_sep) / 2;
        break :blk o.node_sep;
    };
    return a.w / 2 + a.right_extra + b.w / 2 + gap;
}

const Conflicts = std.AutoHashMapUnmanaged(u64, void);

fn key(u: u32, v: u32) u64 {
    return @as(u64, @min(u, v)) << 32 | @max(u, v);
}

/// Segments that cross an inner (dummy to dummy) segment.
fn markConflicts(a: Allocator, g: *const Graph) !Conflicts {
    var c: Conflicts = .empty;
    if (g.layers.len < 2) return c;
    for (0..g.layers.len - 1) |i| {
        const upper = g.layers[i];
        const lower = g.layers[i + 1];
        if (upper.len == 0) continue;
        var k0: u32 = 0;
        var scan: usize = 0;
        for (lower, 0..) |v, l1| {
            const inner = innerUpper(g, v);
            if (inner == null and l1 != lower.len - 1) continue;
            const k1: u32 = if (inner) |w| g.verts.items[w].order else @intCast(upper.len - 1);
            while (scan <= l1) : (scan += 1) {
                const u = lower[scan];
                for (g.up[u]) |x| {
                    if (g.verts.items[x].isDummyLike() and g.verts.items[u].isDummyLike()) continue;
                    const k = g.verts.items[x].order;
                    if (k < k0 or k > k1) try c.put(a, key(x, u), {});
                }
            }
            k0 = k1;
        }
    }
    return c;
}

fn innerUpper(g: *const Graph, v: u32) ?u32 {
    if (!g.verts.items[v].isDummyLike()) return null;
    for (g.up[v]) |w| if (g.verts.items[w].isDummyLike()) return w;
    return null;
}

/// Sets every vertex's `x`.
pub fn assignX(g: *Graph, o: Opts) !void {
    const a = g.a;
    const n = g.verts.items.len;
    if (n == 0) return;
    var conflicts = try markConflicts(a, g);
    defer conflicts.deinit(a);
    var xs: [4][]f32 = undefined;
    for (0..4) |k| xs[k] = try alignment(g, o, &conflicts, k < 2, k % 2 == 0);
    // Align to the narrowest: left alignments by their left edge, right
    // ones by their right edge.
    var lo: [4]f32 = undefined;
    var hi: [4]f32 = undefined;
    var best: usize = 0;
    for (0..4) |k| {
        lo[k] = std.math.inf(f32);
        hi[k] = -std.math.inf(f32);
        for (g.verts.items, 0..) |v, i| {
            lo[k] = @min(lo[k], xs[k][i] - v.w / 2);
            hi[k] = @max(hi[k], xs[k][i] + v.w / 2);
        }
        if (hi[k] - lo[k] < hi[best] - lo[best]) best = k;
    }
    for (0..4) |k| {
        const left = k % 2 == 0;
        const d = if (left) lo[best] - lo[k] else hi[best] - hi[k];
        for (xs[k]) |*x| x.* += d;
    }
    for (g.verts.items, 0..) |*v, i| {
        var s = [4]f32{ xs[0][i], xs[1][i], xs[2][i], xs[3][i] };
        std.sort.pdq(f32, &s, {}, std.sort.asc(f32));
        v.x = (s[1] + s[2]) / 2;
    }
}

/// One alignment: from the top (`down`) or the bottom, from the left
/// (`left`) or the right.
fn alignment(g: *Graph, o: Opts, conflicts: *const Conflicts, down: bool, left: bool) ![]f32 {
    const a = g.a;
    const n = g.verts.items.len;
    const nl = g.layers.len;
    // The layers as this alignment walks them.
    const layers = try a.alloc([]u32, nl);
    for (0..nl) |i| {
        const src = g.layers[if (down) i else nl - 1 - i];
        const l = try a.dupe(u32, src);
        if (!left) std.mem.reverse(u32, l);
        layers[i] = l;
    }
    const pos = try a.alloc(u32, n);
    for (layers) |l| for (l, 0..) |v, i| {
        pos[v] = @intCast(i);
    };
    const root = try a.alloc(u32, n);
    const al = try a.alloc(u32, n);
    for (root, al, 0..) |*r, *x, i| {
        r.* = @intCast(i);
        x.* = @intCast(i);
    }
    var nb: std.ArrayList(u32) = .empty;
    defer nb.deinit(a);
    for (layers[1..]) |l| {
        var r: i64 = -1;
        for (l) |v| {
            nb.clearRetainingCapacity();
            try nb.appendSlice(a, if (down) g.up[v] else g.down[v]);
            if (nb.items.len == 0) continue;
            std.sort.pdq(u32, nb.items, pos, struct {
                fn lt(p: []const u32, x: u32, y: u32) bool {
                    return p[x] < p[y];
                }
            }.lt);
            const d = nb.items.len;
            const ms = [2]usize{ (d - 1) / 2, d / 2 };
            for (ms, 0..) |m, mi| {
                if (mi == 1 and ms[1] == ms[0]) break;
                if (al[v] != v) break;
                const w = nb.items[m];
                if (conflicts.contains(key(w, v))) continue;
                if (r >= pos[w]) continue;
                al[w] = v;
                root[v] = root[w];
                al[v] = root[v];
                r = pos[w];
            }
        }
    }
    // Compaction over the block graph.
    const Edge = struct { from: u32, to: u32, w: f32 };
    var edges: std.ArrayList(Edge) = .empty;
    for (layers) |l| {
        if (l.len < 2) continue;
        for (l[0 .. l.len - 1], l[1..]) |v, w| {
            const s = if (left) sep(g, v, w, o) else sep(g, w, v, o);
            try edges.append(a, .{ .from = root[v], .to = root[w], .w = s });
        }
    }
    const indeg = try a.alloc(u32, n);
    @memset(indeg, 0);
    var out_start = try a.alloc(u32, n + 1);
    @memset(out_start, 0);
    for (edges.items) |e| {
        indeg[e.to] += 1;
        out_start[e.from + 1] += 1;
    }
    for (1..n + 1) |i| out_start[i] += out_start[i - 1];
    const out = try a.alloc(u32, edges.items.len);
    const cur = try a.dupe(u32, out_start[0..n]);
    for (edges.items, 0..) |e, i| {
        out[cur[e.from]] = @intCast(i);
        cur[e.from] += 1;
    }
    var in_lists = try a.alloc(std.ArrayList(u32), n);
    for (in_lists) |*l| l.* = .empty;
    for (edges.items, 0..) |e, i| try in_lists[e.to].append(a, @intCast(i));
    // Topological order of the blocks (roots only).
    var topo: std.ArrayList(u32) = .empty;
    for (0..n) |v| if (root[v] == v and indeg[v] == 0) try topo.append(a, @intCast(v));
    var head: usize = 0;
    while (head < topo.items.len) : (head += 1) {
        const b = topo.items[head];
        for (out[out_start[b]..out_start[b + 1]]) |ei| {
            const t = edges.items[ei].to;
            indeg[t] -= 1;
            if (indeg[t] == 0) try topo.append(a, t);
        }
    }
    const bx = try a.alloc(f32, n);
    @memset(bx, 0);
    for (topo.items) |b| {
        var x: f32 = 0;
        var any = false;
        for (in_lists[b].items) |ei| {
            const e = edges.items[ei];
            const c = bx[e.from] + e.w;
            x = if (any) @max(x, c) else c;
            any = true;
        }
        bx[b] = x;
    }
    // Pull blocks toward their right neighbours where there is room.
    const pinned: graph.Kind = if (left) .border_right else .border_left;
    var k = topo.items.len;
    while (k > 0) {
        k -= 1;
        const b = topo.items[k];
        var m = std.math.inf(f32);
        for (out[out_start[b]..out_start[b + 1]]) |ei| {
            const e = edges.items[ei];
            m = @min(m, bx[e.to] - e.w);
        }
        if (std.math.isFinite(m) and g.verts.items[b].kind != pinned) bx[b] = @max(bx[b], m);
    }
    const xs = try a.alloc(f32, n);
    for (xs, 0..) |*x, v| x.* = if (left) bx[root[v]] else -bx[root[v]];
    return xs;
}

/// Makes each cluster's sides straight: all its left border vertices
/// share one x (the leftmost) and all its right ones another (the
/// rightmost), and vertices move right just enough to keep their
/// separations. Dummies are kept apart from other vertices but not from
/// borders, so an edge may pass through a cluster but no node sits in
/// one it doesn't belong to. A cluster whose straight sides would
/// conflict with the order keeps its bent borders.
pub fn straightenClusters(g: *Graph, n_subs: usize, o: Opts) !void {
    const a = g.a;
    const n = g.verts.items.len;
    if (n == 0) return;
    const merged = try a.alloc(bool, n_subs);
    @memset(merged, true);
    const canon = try a.alloc(u32, n);
    const x = try a.alloc(f32, n);
    var attempt: usize = 0;
    while (attempt <= n_subs) : (attempt += 1) {
        // Each vertex's variable: a cluster side's first border vertex.
        var first_l = try a.alloc(?u32, n_subs);
        var first_r = try a.alloc(?u32, n_subs);
        @memset(first_l, null);
        @memset(first_r, null);
        for (g.verts.items, 0..) |v, i| {
            canon[i] = @intCast(i);
            x[i] = v.x;
            if (!v.isBorder() or !merged[v.ref]) continue;
            const slot = if (v.kind == .border_left) &first_l[v.ref] else &first_r[v.ref];
            if (slot.*) |f| {
                canon[i] = f;
                x[f] = if (v.kind == .border_left) @min(x[f], v.x) else @max(x[f], v.x);
            } else slot.* = @intCast(i);
        }
        const Con = struct { from: u32, to: u32, s: f32 };
        var cons: std.ArrayList(Con) = .empty;
        for (g.layers) |l| {
            var prev_solid: ?u32 = null;
            var prev_flow: ?u32 = null;
            for (l) |v| {
                const k = g.verts.items[v].kind;
                if (k != .dummy) {
                    if (prev_solid) |u| try cons.append(a, .{ .from = canon[u], .to = canon[v], .s = sep(g, u, v, o) });
                    prev_solid = v;
                }
                if (k != .border_left and k != .border_right) {
                    if (prev_flow) |u| try cons.append(a, .{ .from = canon[u], .to = canon[v], .s = sep(g, u, v, o) });
                    prev_flow = v;
                }
            }
        }
        // Push right in topological order.
        const indeg = try a.alloc(u32, n);
        @memset(indeg, 0);
        var outs = try a.alloc(std.ArrayList(u32), n);
        for (outs) |*l| l.* = .empty;
        for (cons.items, 0..) |c, ci| {
            indeg[c.to] += 1;
            try outs[c.from].append(a, @intCast(ci));
        }
        var queue: std.ArrayList(u32) = .empty;
        for (0..n) |v| if (canon[v] == v and indeg[v] == 0) try queue.append(a, @intCast(v));
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const u = queue.items[head];
            for (outs[u].items) |ci| {
                const c = cons.items[ci];
                x[c.to] = @max(x[c.to], x[u] + c.s);
                indeg[c.to] -= 1;
                if (indeg[c.to] == 0) try queue.append(a, c.to);
            }
        }
        var vars: usize = 0;
        for (0..n) |v| vars += @intFromBool(canon[v] == v);
        if (queue.items.len == vars) {
            for (g.verts.items, 0..) |*v, i| v.x = x[canon[i]];
            return;
        }
        // A cycle: unmerge the clusters stuck in it and try again.
        const done = try a.alloc(bool, n);
        @memset(done, false);
        for (queue.items) |v| done[v] = true;
        var any = false;
        for (g.verts.items, 0..) |v, i| if (v.isBorder() and canon[i] == i and !done[i] and merged[v.ref]) {
            merged[v.ref] = false;
            any = true;
        };
        if (!any) return;
    }
}

/// Sets every vertex's `y`: ranks top to bottom, each as tall as its
/// tallest vertex, with room between ranks for the cluster edges and
/// titles that start or end there.
pub fn assignY(g: *Graph, spans: []const ?clusters.Span, title_top: []const f32, title_bottom: []const f32, rank_sep: f32, o: Opts) !void {
    const nl = g.layers.len;
    if (nl == 0) return;
    const a = g.a;
    const rh = try a.alloc(f32, nl);
    @memset(rh, 0);
    for (g.verts.items) |v| if (!v.isBorder()) {
        const r: usize = @intCast(v.rank);
        rh[r] = @max(rh[r], v.h);
    };
    // Space each cluster needs above its first rank and below its last.
    const above = try a.alloc(f32, nl);
    const below = try a.alloc(f32, nl);
    @memset(above, 0);
    @memset(below, 0);
    for (spans, 0..) |sp_opt, c| if (sp_opt) |sp| {
        above[@intCast(sp.lo)] += o.cluster_pad + title_top[c];
        below[@intCast(sp.hi)] += o.cluster_pad + title_bottom[c];
    };
    var y: f32 = above[0];
    for (0..nl) |r| {
        if (r > 0) y += @max(rank_sep, below[r - 1] + above[r] + 8);
        y += rh[r] / 2;
        for (g.layers[r]) |v| g.verts.items[v].y = y;
        y += rh[r] / 2;
    }
}

test {
    std.testing.refAllDecls(@This());
}
