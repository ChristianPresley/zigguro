//! Ordering (E13.F07.S02.T02): vertices within each layer to reduce
//! crossings. A DFS gives the first order; sweeps down and up sort each
//! layer by the median of its neighbours in the layer before; adjacent
//! swaps then fix what they can; the best order over `max_sweeps` wins.
//! Sorting goes cluster by cluster so each subgraph's vertices stay
//! together, between its border vertices.

const std = @import("std");
const graph = @import("graph.zig");

const Allocator = std.mem.Allocator;
const Graph = graph.Graph;

/// Orders `g.layers` in place.
pub fn order(g: *Graph, max_sweeps: u8) !void {
    return orderOpts(g, .{ .max_sweeps = max_sweeps });
}

pub const Opts = struct {
    max_sweeps: u8 = 24,
    /// Sweeps without improvement before a run stops.
    patience: u8 = 4,
    /// Runs from different first orders (DFS, DFS from the other side,
    /// reversed, then shuffled); the best wins. Small graphs get more,
    /// up to `max_restarts`, while restarts × (vertices + edges) stays
    /// under `work_budget`.
    restarts: u8 = 1,
    max_restarts: u8 = 32,
    work_budget: u32 = 9_000,
};

/// Restarts for a graph of `size` vertices plus edges.
pub fn restartsFor(o: Opts, size: usize) u8 {
    const fit = o.work_budget / @max(1, size);
    return @intCast(@max(@max(1, o.restarts), @min(fit, o.max_restarts)));
}

pub fn orderOpts(g: *Graph, o: Opts) !void {
    const a = g.a;
    if (g.layers.len == 0) return;
    var s: Sorter = try .init(g);
    defer s.deinit();
    const base = try snapshot(a, g);
    var best: ?[][]u32 = null;
    var best_c: u64 = std.math.maxInt(u64);
    const runs = restartsFor(o, g.verts.items.len + g.edges.items.len);
    var k: u8 = 0;
    while (k < runs and best_c > 0) : (k += 1) {
        for (base, g.layers) |b, l| @memcpy(l, b);
        try initialOrder(g, k);
        const c = try s.run(o.max_sweeps, o.patience, k % 2 == 1);
        if (c < best_c) {
            best_c = c;
            if (best) |b| {
                for (b, g.layers) |x, l| @memcpy(x, l);
            } else best = try snapshot(a, g);
        }
    }
    for (best.?, g.layers) |b, l| @memcpy(l, b);
    g.syncOrder();
}

fn snapshot(a: Allocator, g: *const Graph) ![][]u32 {
    const out = try a.alloc([]u32, g.layers.len);
    for (out, g.layers) |*o, l| o.* = try a.dupe(u32, l);
    return out;
}

/// A first order. Variant 0: the order a depth-first walk from the top
/// reaches the vertices; 1: the same walk taking neighbours and starts
/// from the other end; 2: variant 0 reversed; others: shuffled.
fn initialOrder(g: *Graph, variant: u8) !void {
    const a = g.a;
    const n = g.verts.items.len;
    if (variant >= 3) {
        var prng: std.Random.DefaultPrng = .init(variant);
        for (g.layers) |l| prng.random().shuffle(u32, l);
        g.syncOrder();
        return;
    }
    const flip = variant == 1;
    const seen = try a.alloc(bool, n);
    defer a.free(seen);
    @memset(seen, false);
    const fill = try a.alloc(u32, g.layers.len);
    defer a.free(fill);
    @memset(fill, 0);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    // Starts: by rank, then index, so every vertex is reached.
    const starts = try snapshot(a, g);
    for (starts) |l| {
        if (flip) std.mem.reverse(u32, l);
        for (l) |s0| {
            if (seen[s0]) continue;
            try stack.append(a, s0);
            while (stack.pop()) |v| {
                if (seen[v]) continue;
                seen[v] = true;
                const r: usize = @intCast(g.verts.items[v].rank);
                g.layers[r][fill[r]] = v;
                fill[r] += 1;
                // Pushed so the first neighbour (last when flipped) is
                // visited first.
                const nb = g.down[v];
                for (0..nb.len) |i| {
                    const w = nb[if (flip) i else nb.len - 1 - i];
                    if (!seen[w]) try stack.append(a, w);
                }
            }
        }
    }
    if (variant == 2) for (g.layers) |l| std.mem.reverse(u32, l);
    g.syncOrder();
}

/// Crossings between all adjacent layers (border links excluded), by
/// the accumulator tree of Barth, Jünger and Mutzel.
pub fn crossings(a: Allocator, g: *const Graph) !u64 {
    var total: u64 = 0;
    var tree: std.ArrayList(u32) = .empty;
    defer tree.deinit(a);
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(a);
    for (0..g.layers.len -| 1) |r| {
        const lower = g.layers[r + 1];
        ends.clearRetainingCapacity();
        for (g.layers[r]) |u| {
            if (g.verts.items[u].isBorder()) continue;
            const start = ends.items.len;
            for (g.down[u]) |w| try ends.append(a, g.verts.items[w].order);
            sortSmall(ends.items[start..]);
        }
        total += try bilayer(a, &tree, ends.items, lower.len);
    }
    return total;
}

/// Sorts positions ascending; most slices are a vertex's few edges, where
/// insertion sort beats pdq's setup.
fn sortSmall(xs: []u32) void {
    if (xs.len < 2) return;
    if (xs.len > 16) return std.sort.pdq(u32, xs, {}, std.sort.asc(u32));
    for (1..xs.len) |i| {
        const x = xs[i];
        var j = i;
        while (j > 0 and xs[j - 1] > x) : (j -= 1) xs[j] = xs[j - 1];
        xs[j] = x;
    }
}

/// Inversions in `ends` (lower positions in upper-major order).
pub fn bilayer(a: Allocator, tree: *std.ArrayList(u32), ends: []const u32, q: usize) !u64 {
    var first: usize = 1;
    while (first < q) first *= 2;
    const size = 2 * first - 1;
    first -= 1;
    try tree.resize(a, size);
    @memset(tree.items, 0);
    var cross: u64 = 0;
    for (ends) |p| {
        var i = p + first;
        tree.items[i] += 1;
        while (i > 0) {
            if (i % 2 == 1) cross += tree.items[i + 1];
            i = (i - 1) / 2;
            tree.items[i] += 1;
        }
    }
    return cross;
}

/// Swaps neighbours in a layer (same cluster, no borders) while that
/// removes crossings.
fn transpose(g: *Graph) void {
    var pass: u32 = 0;
    var improved = true;
    while (improved and pass < 2) : (pass += 1) {
        improved = false;
        for (g.layers) |l| {
            if (l.len < 2) continue;
            for (0..l.len - 1) |i| {
                const u = l[i];
                const v = l[i + 1];
                const vu = g.verts.items[u];
                const vv = g.verts.items[v];
                if (vu.isBorder() or vv.isBorder() or vu.cluster != vv.cluster) continue;
                const keep = pairCross(g, u, v);
                const swap = pairCross(g, v, u);
                if (swap < keep) {
                    l[i] = v;
                    l[i + 1] = u;
                    g.verts.items[v].order = @intCast(i);
                    g.verts.items[u].order = @intCast(i + 1);
                    improved = true;
                }
            }
        }
    }
}

/// Crossings between `u`'s and `v`'s edges with `u` left of `v`.
fn pairCross(g: *const Graph, u: u32, v: u32) u32 {
    var c: u32 = 0;
    for ([_][][]u32{ g.up, g.down }) |nb| {
        for (nb[u]) |x| for (nb[v]) |y| {
            if (g.verts.items[x].order > g.verts.items[y].order) c += 1;
        };
    }
    return c;
}

const Sorter = struct {
    g: *Graph,
    key: []f32,
    /// Each vertex's subgraphs, outermost first.
    paths: [][]u32,
    /// Sibling subgraphs keep this left-to-right order in every layer, so
    /// their boxes can't overlap.
    cluster_rank: []u32,
    /// Whether a vertex's key came from neighbours (others keep their
    /// place).
    has_key: []bool,
    scratch: std.ArrayList(u32) = .empty,

    fn init(g: *Graph) !Sorter {
        const a = g.a;
        const n = g.verts.items.len;
        const key = try a.alloc(f32, n);
        const paths = try a.alloc([]u32, n);
        var buf: [256]u32 = undefined;
        for (paths, g.verts.items) |*p, v| p.* = try a.dupe(u32, g.path(v.cluster, &buf));
        const cluster_rank = try a.alloc(u32, g.sub_parent.len);
        for (cluster_rank, 0..) |*r, i| r.* = @intCast(i);
        const has_key = try a.alloc(bool, n);
        @memset(has_key, false);
        return .{ .g = g, .key = key, .paths = paths, .cluster_rank = cluster_rank, .has_key = has_key };
    }

    fn deinit(s: *Sorter) void {
        s.scratch.deinit(s.g.a);
    }

    /// Groups the current order by cluster, then sweeps (down first,
    /// or up when `up_first`), keeping the best order; returns its
    /// crossings.
    fn run(s: *Sorter, max_sweeps: u8, patience: u8, up_first: bool) !u64 {
        const g = s.g;
        const a = g.a;
        s.refreshClusterOrder();
        for (g.layers) |l| {
            for (l) |v| {
                s.key[v] = @floatFromInt(g.verts.items[v].order);
                s.has_key[v] = true;
            }
            try s.sortLayer(l);
        }
        g.syncOrder();
        const best = try snapshot(a, g);
        var best_c = try crossings(a, g);
        var stall: u32 = 0;
        var it: u8 = 0;
        while (it < max_sweeps and best_c > 0) : (it += 1) {
            s.refreshClusterOrder();
            const downward = (it % 2 == 0) != up_first;
            if (downward) {
                for (1..g.layers.len) |r| try s.sweepLayer(g.layers[r], true);
            } else {
                var r = g.layers.len - 1;
                while (r > 0) {
                    r -= 1;
                    try s.sweepLayer(g.layers[r], false);
                }
            }
            transpose(g);
            const c = try crossings(a, g);
            if (c < best_c) {
                for (best, g.layers) |b, l| @memcpy(b, l);
                best_c = c;
                stall = 0;
            } else {
                stall += 1;
                if (stall >= patience) break;
            }
        }
        for (best, g.layers) |b, l| @memcpy(l, b);
        g.syncOrder();
        return best_c;
    }

    /// Ranks the subgraphs by the mean relative position of their
    /// vertices over all layers.
    fn refreshClusterOrder(s: *Sorter) void {
        const g = s.g;
        const ns = s.cluster_rank.len;
        if (ns == 0) return;
        const a = g.a;
        const sum = a.alloc(f64, ns) catch return;
        defer a.free(sum);
        const cnt = a.alloc(f64, ns) catch return;
        defer a.free(cnt);
        @memset(sum, 0);
        @memset(cnt, 0);
        for (g.layers) |l| for (l) |v| {
            const rel = @as(f64, @floatFromInt(g.verts.items[v].order)) / @as(f64, @floatFromInt(l.len));
            for (s.paths[v]) |c| {
                sum[c] += rel;
                cnt[c] += 1;
            }
        };
        const ids = a.alloc(u32, ns) catch return;
        defer a.free(ids);
        for (ids, 0..) |*x, i| x.* = @intCast(i);
        const Ctx = struct { sum: []f64, cnt: []f64 };
        std.sort.pdq(u32, ids, Ctx{ .sum = sum, .cnt = cnt }, struct {
            fn lt(c: Ctx, x: u32, y: u32) bool {
                const mx = if (c.cnt[x] > 0) c.sum[x] / c.cnt[x] else 0;
                const my = if (c.cnt[y] > 0) c.sum[y] / c.cnt[y] else 0;
                return if (mx != my) mx < my else x < y;
            }
        }.lt);
        for (ids, 0..) |c, r| s.cluster_rank[c] = @intCast(r);
    }

    /// Sorts layer `l` by the median position of each vertex's
    /// neighbours above (`from_above`) or below.
    fn sweepLayer(s: *Sorter, l: []u32, from_above: bool) !void {
        const g = s.g;
        for (l) |v| {
            const nb = if (from_above) g.up[v] else g.down[v];
            s.has_key[v] = nb.len > 0;
            s.key[v] = if (nb.len == 0) @floatFromInt(g.verts.items[v].order) else try s.median(nb);
        }
        try s.sortLayer(l);
        for (l, 0..) |v, i| g.verts.items[v].order = @intCast(i);
    }

    fn median(s: *Sorter, nb: []const u32) !f32 {
        const vs = s.g.verts.items;
        if (nb.len == 1) return @floatFromInt(vs[nb[0]].order);
        if (nb.len == 2) return (@as(f32, @floatFromInt(vs[nb[0]].order)) + @as(f32, @floatFromInt(vs[nb[1]].order))) / 2;
        s.scratch.clearRetainingCapacity();
        for (nb) |x| try s.scratch.append(s.g.a, s.g.verts.items[x].order);
        const p = s.scratch.items;
        sortSmall(p);
        const m = p.len / 2;
        // Odd: the median; even: the mean of the two middle ones.
        return if (p.len % 2 == 1) @floatFromInt(p[m]) else (@as(f32, @floatFromInt(p[m - 1])) + @as(f32, @floatFromInt(p[m]))) / 2;
    }

    /// Reorders `l` by key, keeping clusters contiguous and their borders
    /// at their ends.
    fn sortLayer(s: *Sorter, l: []u32) !void {
        const a = s.g.a;
        const items = try a.dupe(u32, l);
        defer a.free(items);
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(a);
        try s.group(items, 0, null, &out);
        @memcpy(l, out.items);
    }

    /// A vertex, or a child subgraph's vertices, sorted as one.
    const Unit = struct { key: f32, first: u32, v: u32, child: ?u32, fixed: bool = false, sum: f32 = 0, n: f32 = 0, all_sum: f32 = 0, all_n: f32 = 0, keyed: bool = false };

    fn group(s: *Sorter, items: []const u32, depth: usize, cluster: ?u32, out: *std.ArrayList(u32)) !void {
        const a = s.g.a;
        var left: ?u32 = null;
        var right: ?u32 = null;
        var units: std.ArrayList(Unit) = .empty;
        defer units.deinit(a);
        try units.ensureTotalCapacity(a, items.len);
        var n_child: usize = 0;
        var child_at: std.ArrayList(u32) = .empty;
        defer child_at.deinit(a);
        for (items, 0..) |v, i| {
            const vx = s.g.verts.items[v];
            const p = s.paths[v];
            if (vx.isBorder() and p.len == depth and vx.cluster == cluster) {
                if (vx.kind == .border_left) left = v else right = v;
                continue;
            }
            const k = s.key[v];
            if (p.len <= depth) {
                units.appendAssumeCapacity(.{ .key = k, .first = @intCast(i), .v = v, .child = null, .fixed = !s.has_key[v] });
                continue;
            }
            const c = p[depth];
            var unit: ?*Unit = null;
            for (child_at.items) |ui| if (units.items[ui].child == c) {
                unit = &units.items[ui];
                break;
            };
            if (unit == null) {
                try child_at.append(a, @intCast(units.items.len));
                units.appendAssumeCapacity(.{ .key = 0, .first = @intCast(i), .v = v, .child = c });
                n_child += 1;
                unit = &units.items[units.items.len - 1];
            }
            const u = unit.?;
            u.all_sum += k;
            u.all_n += 1;
            u.keyed = u.keyed or s.has_key[v];
            if (!vx.isBorder()) {
                u.sum += k;
                u.n += 1;
            }
        }
        for (units.items) |*u| if (u.child != null) {
            u.key = if (u.n > 0) u.sum / u.n else u.all_sum / u.all_n;
            u.fixed = !u.keyed;
        };
        // Units without neighbours keep their slots; the rest are sorted
        // into the others.
        var moving: std.ArrayList(Unit) = .empty;
        defer moving.deinit(a);
        for (units.items) |u| if (!u.fixed) try moving.append(a, u);
        const by_key = struct {
            fn lt(_: void, x: Unit, y: Unit) bool {
                return if (x.key != y.key) x.key < y.key else x.first < y.first;
            }
        }.lt;
        // Later sweeps mostly find a layer already in order.
        if (!std.sort.isSorted(Unit, moving.items, {}, by_key)) std.sort.pdq(Unit, moving.items, {}, by_key);
        var mi: usize = 0;
        for (units.items) |*u| if (!u.fixed) {
            u.* = moving.items[mi];
            mi += 1;
        };
        if (n_child > 1) {
            // Subgraphs take the slots subgraphs got, in their fixed order.
            var slots: std.ArrayList(usize) = .empty;
            defer slots.deinit(a);
            var subs: std.ArrayList(Unit) = .empty;
            defer subs.deinit(a);
            for (units.items, 0..) |u, i| if (u.child != null) {
                try slots.append(a, i);
                try subs.append(a, u);
            };
            std.sort.pdq(Unit, subs.items, s.cluster_rank, struct {
                fn lt(r: []const u32, x: Unit, y: Unit) bool {
                    return r[x.child.?] < r[y.child.?];
                }
            }.lt);
            for (slots.items, subs.items) |i, u| units.items[i] = u;
        }
        if (left) |v| try out.append(a, v);
        var sub_items: std.ArrayList(u32) = .empty;
        defer sub_items.deinit(a);
        for (units.items) |u| {
            const c = u.child orelse {
                try out.append(a, u.v);
                continue;
            };
            sub_items.clearRetainingCapacity();
            for (items) |v| {
                const p = s.paths[v];
                if (p.len > depth and p[depth] == c) try sub_items.append(a, v);
            }
            try s.group(sub_items.items, depth + 1, c, out);
        }
        if (right) |v| try out.append(a, v);
    }
};

test {
    std.testing.refAllDecls(@This());
}
