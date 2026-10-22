//! E09.F11.S02.T01 graph layout benchmarks over a synthetic 100k-commit
//! history (a trunk with short side branches and merges): a full layout
//! (budget 30 ms) and an incremental one after the top commit changes
//! (budget 1 ms).

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const State = bench.State;
const layout = scm.layout;

const names = [_][]const u8{ "ui.graph_layout_100k", "ui.graph_layout_100k_incremental" };
const n_rows = 100_000;

fn wanted(b: *bench.Bench, name: []const u8) bool {
    const f = b.opts.filter orelse return true;
    return std.mem.indexOf(u8, name, f) != null;
}

const Ctx = struct { nodes: []const layout.GraphNodeIn, edited: []const layout.GraphNodeIn, prev: *const layout.Layout };

pub fn register(b: *bench.Bench) !void {
    for (names) |n| {
        if (wanted(b, n)) break;
    } else return;
    const gpa = b.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(4);
    const r = prng.random();

    // Rows are commits in display order; every eighth starts a side branch
    // of up to four commits that a later trunk commit merges.
    const nodes = try a.alloc(layout.GraphNodeIn, n_rows);
    for (nodes, 0..) |*node, i| {
        const ps = try a.alloc(layout.Pos, if (i + 1 == n_rows) 0 else if (i % 8 == 0 and i + 6 < n_rows) 2 else 1);
        if (ps.len > 0) ps[0] = @enumFromInt(i + 1);
        if (ps.len > 1) ps[1] = @enumFromInt(i + 2 + r.uintLessThan(usize, 4));
        node.* = .{ .id = @enumFromInt(i), .parents = ps };
    }
    const edited = try a.dupe(layout.GraphNodeIn, nodes);
    edited[0].kind = .wc;
    var prev = try layout.compute(gpa, nodes, .{});
    defer prev.deinit();

    const ctx: Ctx = .{ .nodes = nodes, .edited = edited, .prev = &prev };
    try b.run("ui.graph_layout_100k: full lane layout of 100k commits", ctx, full);
    try b.run("ui.graph_layout_100k_incremental: relayout after the top commit changes", ctx, incremental);
}

fn full(c: Ctx, s: *State) void {
    for (0..s.iterations()) |_| {
        var l = layout.compute(s.allocator(), c.nodes, .{}) catch unreachable;
        bench.doNotOptimizeAway(l.width);
        l.deinit();
    }
}

fn incremental(c: Ctx, s: *State) void {
    for (0..s.iterations()) |_| {
        var l = layout.computeIncremental(c.prev, c.nodes, c.edited, .{}, s.allocator()) catch unreachable;
        bench.doNotOptimizeAway(l.width);
        l.deinit();
    }
}
