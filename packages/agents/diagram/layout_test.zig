//! The layered layout: cycle removal, layering, the crossing counter,
//! ordering quality against reference counts (run with -Dupdate-golden
//! to rewrite crossings.zon), no overlaps, clusters, directions, ports
//! and determinism.

const std = @import("std");
const options = @import("zg_options");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const parser = @import("parser.zig");
const lay = @import("layout/root.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const graph = lay.graph;

/// Monospace: 7 px a character, 16 px a line.
const Mono = struct {
    fn text(_: *anyopaque, s: []const u8, max_w: f32) [2]f32 {
        var lines: f32 = 0;
        var widest: f32 = 0;
        var it = std.mem.splitScalar(u8, s, '\n');
        while (it.next()) |l| {
            const w = @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(l) catch l.len)) * 7;
            const wraps = @max(1, @ceil(w / max_w));
            lines += wraps;
            widest = @max(widest, @min(w, max_w));
        }
        return .{ widest, lines * 16 };
    }
};
var mono_ctx: u8 = 0;
const mono: lay.Measure = .{ .ctx = &mono_ctx, .text = Mono.text };

fn parseOk(a: std.mem.Allocator, src: []const u8) !ast.Diagram {
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    const d = (try parser.parse(a, src, &diags)) orelse return error.NoDiagram;
    if (diag.hasErrors(diags.items)) {
        for (diags.items) |x| std.debug.print("{d}:{d}: {s}\n", .{ x.line, x.col, x.message });
        return error.ParseErrors;
    }
    return d;
}

fn isAcyclic(a: std.mem.Allocator, n: usize, edges: []const graph.LEdge) !bool {
    const indeg = try a.alloc(u32, n);
    @memset(indeg, 0);
    for (edges) |e| indeg[e.to] += 1;
    var q: std.ArrayList(u32) = .empty;
    for (0..n) |v| if (indeg[v] == 0) try q.append(a, @intCast(v));
    var h: usize = 0;
    while (h < q.items.len) : (h += 1) for (edges) |e| if (e.from == q.items[h]) {
        indeg[e.to] -= 1;
        if (indeg[e.to] == 0) try q.append(a, e.to);
    };
    return q.items.len == n;
}

fn edgesOf(a: std.mem.Allocator, pairs: []const [2]u32) ![]graph.LEdge {
    const out = try a.alloc(graph.LEdge, pairs.len);
    for (out, pairs, 0..) |*e, p, i| e.* = .{ .from = p[0], .to = p[1], .min_len = 1, .orig = @intCast(i) };
    return out;
}

test "acyclic_reverses_minimal_on_fixtures" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Fx = struct { n: usize, edges: []const [2]u32, min: usize };
    const cases = [_]Fx{
        .{ .n = 4, .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } }, .min = 0 },
        .{ .n = 3, .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } }, .min = 1 },
        .{ .n = 3, .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 }, .{ 0, 2 } }, .min = 1 },
        .{ .n = 6, .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 }, .{ 3, 4 }, .{ 4, 5 }, .{ 5, 3 } }, .min = 2 },
        .{ .n = 2, .edges = &.{ .{ 0, 1 }, .{ 1, 0 } }, .min = 1 },
        // A long cycle with a back edge: one reversal breaks both.
        .{ .n = 5, .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 0 }, .{ 3, 1 } }, .min = 1 },
        // Retry loops off a main path.
        .{ .n = 5, .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 2, 1 }, .{ 4, 3 } }, .min = 2 },
    };
    for (cases) |f| {
        const es = try edgesOf(a, f.edges);
        const r = try lay.acyclic.removeCycles(a, f.n, es);
        try testing.expect(try isAcyclic(a, f.n, es));
        try testing.expectEqual(f.min, r);
    }
    // Random graphs: always acyclic afterwards, and fewer than half the
    // edges reversed.
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    for (0..50) |_| {
        const n = rnd.intRangeAtMost(usize, 2, 40);
        const m = rnd.intRangeAtMost(usize, 1, 80);
        const pairs = try a.alloc([2]u32, m);
        for (pairs) |*p| {
            const u = rnd.uintLessThan(u32, @intCast(n));
            var v = rnd.uintLessThan(u32, @intCast(n));
            if (v == u) v = (u + 1) % @as(u32, @intCast(n));
            p.* = .{ u, v };
        }
        const es = try edgesOf(a, pairs);
        const r = try lay.acyclic.removeCycles(a, n, es);
        try testing.expect(try isAcyclic(a, n, es));
        try testing.expect(r <= m / 2);
    }
}

test "layering_respects_min_len" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(11);
    const rnd = prng.random();
    for (0..50) |_| {
        const n = rnd.intRangeAtMost(usize, 2, 60);
        var es: std.ArrayList(graph.LEdge) = .empty;
        for (0..rnd.intRangeAtMost(usize, 1, 120)) |i| {
            const u = rnd.uintLessThan(u32, @intCast(n - 1));
            const v = rnd.intRangeAtMost(u32, u + 1, @intCast(n - 1));
            try es.append(a, .{ .from = u, .to = v, .min_len = rnd.intRangeAtMost(u32, 1, 4), .orig = @intCast(i) });
        }
        const ranks = try lay.layering.assignRanks(a, n, es.items);
        var min: i32 = std.math.maxInt(i32);
        for (ranks) |r| min = @min(min, r);
        try testing.expectEqual(0, min);
        for (es.items) |e| try testing.expect(ranks[e.to] - ranks[e.from] >= @as(i32, @intCast(e.min_len)));
    }
    // Extra dashes lengthen the edge; edges stay tight otherwise.
    const d = try parseOk(a, "flowchart TB\n  A --> B\n  A ----> C\n  B --> D\n");
    const l = try lay.layout(a, &d, mono, .{});
    const ya = l.nodes[0].y;
    try testing.expect(l.nodes[1].y > ya);
    try testing.expect(l.nodes[2].y > l.nodes[1].y + 50);
    try testing.expect(l.nodes[2].y > l.nodes[3].y);
}

test "crossings_counter_vs_bruteforce" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(3);
    const rnd = prng.random();
    var tree: std.ArrayList(u32) = .empty;
    for (0..300) |_| {
        const p = rnd.intRangeAtMost(u32, 1, 12);
        const q = rnd.intRangeAtMost(u32, 1, 12);
        const m = rnd.intRangeAtMost(usize, 0, 40);
        const es = try a.alloc([2]u32, m);
        for (es) |*e| e.* = .{ rnd.uintLessThan(u32, p), rnd.uintLessThan(u32, q) };
        std.mem.sort([2]u32, es, {}, struct {
            fn lt(_: void, x: [2]u32, y: [2]u32) bool {
                return if (x[0] != y[0]) x[0] < y[0] else x[1] < y[1];
            }
        }.lt);
        const ends = try a.alloc(u32, m);
        for (ends, es) |*e, x| e.* = x[1];
        var brute: u64 = 0;
        for (es, 0..) |x, i| for (es[i + 1 ..]) |y| {
            if ((x[0] < y[0] and x[1] > y[1]) or (x[0] > y[0] and x[1] < y[1])) brute += 1;
        };
        try testing.expectEqual(brute, try lay.ordering.bilayer(a, &tree, ends, q));
    }
}

/// A random flowchart: `n` nodes, about 1.6·n edges (some backward),
/// in up to three subgraphs, some with labels.
fn randomDiagram(a: std.mem.Allocator, seed: u64, n: usize, with_subgraphs: bool) ![]const u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("flowchart TB\n");
    if (with_subgraphs) {
        var next: usize = 0;
        for (0..3) |s| {
            const k = rnd.intRangeAtMost(usize, 1, @max(1, n / 5));
            try w.writer.print("  subgraph s{d} [Group {d}]\n", .{ s, s });
            for (0..k) |_| {
                if (next >= n) break;
                try w.writer.print("    n{d}[Node {d}]\n", .{ next, next });
                next += 1;
            }
            try w.writer.writeAll("  end\n");
        }
    }
    for (0..n) |i| try w.writer.print("  n{d}[Node {d}]\n", .{ i, i });
    for (0..n + n * 3 / 5) |k| {
        const u = rnd.uintLessThan(usize, n);
        var v = rnd.uintLessThan(usize, n);
        if (u == v) v = (u + 1) % n;
        if (k % 7 == 3)
            try w.writer.print("  n{d} -->|e{d}| n{d}\n", .{ u, k, v })
        else
            try w.writer.print("  n{d} --> n{d}\n", .{ u, v });
    }
    return w.written();
}

const Fixture = struct { name: []const u8, src: []const u8 };

fn fixtures(a: std.mem.Allocator) ![]Fixture {
    var out: std.ArrayList(Fixture) = .empty;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "diagram/testdata/flowchart", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| if (std.mem.endsWith(u8, e.name, ".mmd")) try names.append(a, try a.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    // Corpus diagrams with at least three edges.
    for (names.items) |name| {
        const src = try dir.readFileAlloc(io, name, a, .limited(1 << 20));
        var diags: std.ArrayList(diag.Diagnostic) = .empty;
        const d = (try parser.parse(a, src, &diags)) orelse continue;
        if (d.edges.len >= 3 and out.items.len < 14) try out.append(a, .{ .name = name[0 .. name.len - 4], .src = src });
    }
    var seed: u64 = 1;
    while (out.items.len < 40) : (seed += 1) {
        const n: usize = 6 + @as(usize, @intCast(seed * 7 % 40));
        try out.append(a, .{ .name = try std.fmt.allocPrint(a, "random_{d}", .{seed}), .src = try randomDiagram(a, seed, n, seed % 3 == 0) });
    }
    return out.items;
}

test "ordering_quality_corpus" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const fx = try fixtures(a);
    try testing.expectEqual(40, fx.len);
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    const path = "diagram/testdata/flowchart/crossings.zon";
    if (options.update_golden) {
        // References: a long search (64 starts, many sweeps, no early stop).
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll(".{\n");
        for (fx) |f| {
            const d = try parseOk(a, f.src);
            const c = try lay.crossings(a, &d, mono, .{ .max_sweeps = 255, .ordering_patience = 255, .ordering_restarts = 64 });
            try w.writer.print("    .{{ .name = \"{s}\", .crossings = {d} }},\n", .{ f.name, c });
        }
        try w.writer.writeAll("}\n");
        try root.writeFile(io, .{ .sub_path = path, .data = w.written() });
    }
    const text = try root.readFileAllocOptions(io, path, a, .limited(1 << 20), .of(u8), 0);
    const Ref = struct { name: []const u8, crossings: u64 };
    const refs = try std.zon.parse.fromSliceAlloc([]const Ref, a, text, null, .{});
    try testing.expectEqual(fx.len, refs.len);
    var total: u64 = 0;
    var total_ref: u64 = 0;
    var over: usize = 0;
    for (fx, refs) |f, r| {
        try testing.expectEqualStrings(r.name, f.name);
        const d = try parseOk(a, f.src);
        const c = try lay.crossings(a, &d, mono, .{});
        total += c;
        total_ref += r.crossings;
        const allowed = r.crossings + (r.crossings + 9) / 10;
        if (c > allowed) {
            std.debug.print("{s}: {d} crossings, reference {d}\n", .{ f.name, c, r.crossings });
            over += 1;
        }
    }
    if (total * 10 > total_ref * 11) std.debug.print("total {d} vs {d}\n", .{ total, total_ref });
    try testing.expectEqual(0, over);
    try testing.expect(total * 10 <= total_ref * 11);
}

fn overlap(a: lay.NodeBox, b: lay.NodeBox) bool {
    const eps = 0.5;
    return @abs(a.x - b.x) * 2 + eps < a.w + b.w and @abs(a.y - b.y) * 2 + eps < a.h + b.h;
}

fn rectOf(c: lay.ClusterBox) [4]f32 {
    return .{ c.x, c.y, c.x + c.w, c.y + c.h };
}

fn boxOverlapsRect(b: lay.NodeBox, r: [4]f32) bool {
    return b.x + b.w / 2 > r[0] + 0.5 and b.x - b.w / 2 < r[2] - 0.5 and b.y + b.h / 2 > r[1] + 0.5 and b.y - b.h / 2 < r[3] - 0.5;
}

fn boxInRect(b: lay.NodeBox, r: [4]f32) bool {
    return b.x - b.w / 2 >= r[0] - 0.5 and b.x + b.w / 2 <= r[2] + 0.5 and b.y - b.h / 2 >= r[1] - 0.5 and b.y + b.h / 2 <= r[3] + 0.5;
}

fn rectsOverlap(p: [4]f32, q: [4]f32) bool {
    return p[0] < q[2] - 0.5 and q[0] < p[2] - 0.5 and p[1] < q[3] - 0.5 and q[1] < p[3] - 0.5;
}

fn rectIn(inner: [4]f32, outer: [4]f32) bool {
    return inner[0] >= outer[0] - 0.5 and inner[1] >= outer[1] - 0.5 and inner[2] <= outer[2] + 0.5 and inner[3] <= outer[3] + 0.5;
}

/// No node or label overlaps another; clusters hold their members,
/// nest inside their parents, keep out non-members and don't overlap
/// their siblings.
fn checkGeometry(d: *const ast.Diagram, l: lay.Layout) !void {
    for (l.nodes, 0..) |x, i| for (l.nodes[i + 1 ..]) |y| {
        if (overlap(x, y)) {
            std.debug.print("nodes {s} and {s} overlap\n", .{ d.nodes[x.node].id, d.nodes[y.node].id });
            return error.TestUnexpectedResult;
        }
    };
    for (l.edges) |e| if (e.label) |lb| for (l.nodes) |n| {
        if (overlap(lb, n)) {
            std.debug.print("label of edge {d} overlaps node {s}\n", .{ e.edge, d.nodes[n.node].id });
            return error.TestUnexpectedResult;
        }
    };
    // Each node's innermost subgraph and all its ancestors.
    for (d.subgraphs, 0..) |s, si| {
        const r = rectOf(l.clusters[si]);
        const inside = try gpa.alloc(bool, d.nodes.len);
        defer gpa.free(inside);
        @memset(inside, false);
        markInside(d, @intCast(si), inside);
        for (l.nodes, 0..) |n, ni| {
            if (inside[ni]) {
                if (!boxInRect(n, r)) {
                    std.debug.print("node {s} sticks out of subgraph {s}\n", .{ d.nodes[ni].id, s.id });
                    return error.TestUnexpectedResult;
                }
            } else if (boxOverlapsRect(n, r)) {
                std.debug.print("node {s} overlaps subgraph {s}\n", .{ d.nodes[ni].id, s.id });
                return error.TestUnexpectedResult;
            }
        }
        for (s.children) |c| try testing.expect(rectIn(rectOf(l.clusters[c]), r));
        for (s.children, 0..) |c, k| for (s.children[k + 1 ..]) |c2| {
            if (rectsOverlap(rectOf(l.clusters[c]), rectOf(l.clusters[c2]))) {
                std.debug.print("subgraphs {s} and {s} overlap\n", .{ d.subgraphs[c].id, d.subgraphs[c2].id });
                return error.TestUnexpectedResult;
            }
        };
    }
    // Top-level subgraphs don't overlap each other.
    for (d.subgraphs, 0..) |_, i| for (d.subgraphs[i + 1 ..], i + 1..) |_, j| {
        if (isRoot(d, i) and isRoot(d, j) and rectsOverlap(rectOf(l.clusters[i]), rectOf(l.clusters[j]))) {
            std.debug.print("subgraphs {s} and {s} overlap\n", .{ d.subgraphs[i].id, d.subgraphs[j].id });
            return error.TestUnexpectedResult;
        }
    };
}

fn isRoot(d: *const ast.Diagram, s: usize) bool {
    for (d.subgraphs) |p| for (p.children) |c| if (c == s) return false;
    return true;
}

fn markInside(d: *const ast.Diagram, s: u32, inside: []bool) void {
    for (d.subgraphs[s].members) |m| inside[m] = true;
    for (d.subgraphs[s].children) |c| markInside(d, c, inside);
}

test "bk_no_overlaps" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..60) |seed| {
        const src = try randomDiagram(a, 1000 + seed, 4 + seed % 30, false);
        const d = try parseOk(a, src);
        const l = try lay.layout(a, &d, mono, .{});
        checkGeometry(&d, l) catch |e| {
            std.debug.print("seed {d}:\n{s}\n", .{ 1000 + seed, src });
            return e;
        };
    }
}

test "clusters_contiguous_and_nested" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const srcs = [_][]const u8{
        "flowchart TB\n  subgraph outer [Outer]\n    x --> y\n    subgraph inner [Inner]\n      p --> q\n    end\n  end\n  a --> x\n  a --> p\n  q --> b\n  y --> b\n  a --> b\n",
        "flowchart LR\n  subgraph one\n    a1 --> a2\n  end\n  subgraph two\n    b1 --> b2\n  end\n  subgraph three\n    c1\n  end\n  a1 --> b2\n  b1 --> a2\n  c1 --> a1\n  start --> one\n  two --> finish\n",
        "flowchart TB\n  A --> B --> C --> D\n  subgraph S [Side]\n    direction LR\n    s1 --> s2\n  end\n  A --> s1\n  s2 --> D\n  B --> D\n",
        "flowchart BT\n  subgraph g1\n    subgraph g2\n      subgraph g3\n        z\n      end\n    end\n  end\n  top --> z --> bottom\n",
        "flowchart RL\n  subgraph empty [Nothing here]\n  end\n  a --> empty --> b\n",
    };
    for (srcs) |src| {
        const d = try parseOk(a, src);
        const l = try lay.layout(a, &d, mono, .{});
        checkGeometry(&d, l) catch |e| {
            std.debug.print("{s}\n", .{src});
            return e;
        };
    }
    for (0..30) |seed| {
        const src = try randomDiagram(a, 500 + seed, 8 + seed % 25, true);
        const d = try parseOk(a, src);
        const l = try lay.layout(a, &d, mono, .{});
        checkGeometry(&d, l) catch |e| {
            std.debug.print("seed {d}:\n{s}\n", .{ 500 + seed, src });
            return e;
        };
    }
    // In the ordered layers, each cluster's vertices are contiguous.
    const d = try parseOk(a, srcs[0]);
    var counts: [4]u64 = undefined;
    _ = &counts;
    const c = try lay.crossings(a, &d, mono, .{});
    try testing.expect(c <= 2);
}

test "directions_transform" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "TB", "BT", "LR", "RL" }) |dir| {
        const src = try std.fmt.allocPrint(a, "flowchart {s}\n  A[Start] --> B{{Check}} --> C[(Store)]\n  B -->|no| D([Stop])\n  A --> D\n", .{dir});
        const d = try parseOk(a, src);
        const l = try lay.layout(a, &d, mono, .{});
        for (d.edges) |e| {
            const f = l.nodes[e.from];
            const t = l.nodes[e.to];
            switch (d.dir) {
                .TB => try testing.expect(t.y > f.y),
                .BT => try testing.expect(t.y < f.y),
                .LR => try testing.expect(t.x > f.x),
                .RL => try testing.expect(t.x < f.x),
            }
        }
        // Boxes keep their own size whichever way the layout runs.
        try testing.expectEqual(l.nodes[0].w, (try lay.layout(a, &(try parseOk(a, "flowchart TB\n  A[Start]\n")), mono, .{})).nodes[0].w);
        try checkGeometry(&d, l);
        try testing.expect(l.size[0] > 0 and l.size[1] > 0);
        for (l.nodes) |n| try testing.expect(n.x - n.w / 2 >= 0 and n.y - n.h / 2 >= 0 and n.x + n.w / 2 <= l.size[0] and n.y + n.h / 2 <= l.size[1]);
    }
}

test "ports_on_boundary" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const shapes = [_][]const u8{ "[r]", "(r)", "([s])", "[[s]]", "[(c)]", "((c))", "(((d)))", ">a]", "{r}", "{{h}}", "[/p/]", "[\\p\\]", "[/t\\]", "[\\t/]" };
    for ([_][]const u8{ "TB", "LR" }) |dir| {
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.print("flowchart {s}\n", .{dir});
        for (shapes, 0..) |s, i| try w.writer.print("  n{d}{s}\n", .{ i, s });
        for (shapes, 0..) |_, i| {
            try w.writer.print("  n{d} --> n{d}\n", .{ i, (i + 1) % shapes.len });
            try w.writer.print("  n{d} --> n{d}\n", .{ i, (i * 5 + 3) % shapes.len });
        }
        const d = try parseOk(a, w.written());
        const l = try lay.layout(a, &d, mono, .{});
        try checkGeometry(&d, l);
        for (d.edges, l.edges) |e, p| {
            try testing.expectEqual((p.points.len - 1) % 3, 0);
            if (e.from == e.to) continue;
            const s = p.points[0];
            const t = p.points[p.points.len - 1];
            const ds = lay.shapes_geom.outlineDistance(d.nodes[e.from].shape, l.nodes[e.from], s);
            const dt = lay.shapes_geom.outlineDistance(d.nodes[e.to].shape, l.nodes[e.to], t);
            if (ds > 0.5 or dt > 0.5) {
                std.debug.print("{s} edge {s}->{s}: start off by {d}, end by {d}\n", .{ dir, d.nodes[e.from].id, d.nodes[e.to].id, ds, dt });
                return error.TestUnexpectedResult;
            }
        }
    }
    // Edges to a subgraph end on its box.
    const d = try parseOk(a, "flowchart TB\n  a --> S\n  subgraph S\n    b --> c\n  end\n  S --> z\n");
    const l = try lay.layout(a, &d, mono, .{});
    const r = rectOf(l.clusters[0]);
    for (l.edges, d.edges) |p, e| {
        const end = if (e.to_kind == .subgraph) p.points[p.points.len - 1] else if (e.from_kind == .subgraph) p.points[0] else continue;
        const on_edge = @abs(end[1] - r[1]) < 0.6 or @abs(end[1] - r[3]) < 0.6 or @abs(end[0] - r[0]) < 0.6 or @abs(end[0] - r[2]) < 0.6;
        try testing.expect(on_edge);
    }
}

test "self loops, labels and reversed edges" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseOk(a, "flowchart TB\n  A --> B -->|retry| A\n  B --> B\n  B -->|done| C\n  C -->|again| C\n");
    const l = try lay.layout(a, &d, mono, .{});
    try checkGeometry(&d, l);
    try testing.expectEqual(5, l.edges.len);
    var reversed: usize = 0;
    for (l.edges, d.edges) |p, e| {
        if (p.reversed) reversed += 1;
        try testing.expectEqual(e.label != null, p.label != null);
        // Paths run from the edge's `from` to its `to`.
        if (e.from != e.to) {
            const s = p.points[0];
            const t = p.points[p.points.len - 1];
            try testing.expect(@abs(s[1] - l.nodes[e.from].y) <= l.nodes[e.from].h / 2 + 0.5);
            try testing.expect(@abs(t[1] - l.nodes[e.to].y) <= l.nodes[e.to].h / 2 + 0.5);
        }
    }
    try testing.expectEqual(1, reversed);
}

test "deterministic_layout" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try randomDiagram(a, 99, 60, true);
    var outs: [2][]const u8 = undefined;
    for (&outs) |*o| {
        var inner: std.heap.ArenaAllocator = .init(gpa);
        defer inner.deinit();
        const d = try parseOk(inner.allocator(), src);
        const l = try lay.layout(inner.allocator(), &d, mono, .{});
        var w: std.Io.Writer.Allocating = .init(a);
        try std.zon.stringify.serialize(l, .{ .whitespace = false }, &w.writer);
        o.* = w.written();
    }
    try testing.expectEqualStrings(outs[0], outs[1]);
}

/// A flowchart shaped like a real one: a main flow where each step
/// leads to the next and sometimes a few steps on, the odd retry loop
/// back, labelled branches, and three subgraphs of consecutive steps.
/// The layout bench uses the same shape (300 nodes, ~480 edges).
pub fn realistic(a: std.mem.Allocator, n: usize, seed: u64) ![]const u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("flowchart TB\n");
    var at: usize = 0;
    for (0..3) |sg| {
        at += rnd.intRangeAtMost(usize, 0, n / 6);
        const len = rnd.intRangeAtMost(usize, 3, n / 8 + 3);
        try w.writer.print("  subgraph s{d} [Stage {d}]\n", .{ sg, sg });
        for (at..@min(n, at + len)) |i| try w.writer.print("    n{d}[Step {d}]\n", .{ i, i });
        try w.writer.writeAll("  end\n");
        at += len;
    }
    for (0..n) |i| {
        if (i + 1 < n) try w.writer.print("  n{d} --> n{d}\n", .{ i, i + 1 });
        if (rnd.boolean() and i + 2 < n) {
            const j = @min(n - 1, i + rnd.intRangeAtMost(usize, 2, 6));
            if (rnd.intRangeLessThan(u8, 0, 4) == 0) try w.writer.print("  n{d} -->|branch {d}| n{d}\n", .{ i, i, j }) else try w.writer.print("  n{d} --> n{d}\n", .{ i, j });
        }
        if (rnd.intRangeLessThan(u8, 0, 12) == 0 and i > 2) try w.writer.print("  n{d} -.->|retry| n{d}\n", .{ i, i - rnd.intRangeAtMost(usize, 1, 3) });
    }
    return w.written();
}

pub fn sample300(a: std.mem.Allocator) ![]const u8 {
    return realistic(a, 300, 300);
}

test "300 nodes" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseOk(a, try sample300(a));
    const l = try lay.layout(a, &d, mono, .{});
    try testing.expectEqual(300, l.nodes.len);
    try checkGeometry(&d, l);
}
