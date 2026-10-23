//! Layering (E13.F07.S02.T02): longest-path ranks, then a bounded
//! network-simplex-lite pass that moves each vertex within the room its
//! `min_len` constraints leave to shorten its edges.

const std = @import("std");
const graph = @import("graph.zig");

const Allocator = std.mem.Allocator;
const LEdge = graph.LEdge;

pub const max_passes = 32;

/// Ranks for `n` vertices over acyclic `edges`: rank(to) − rank(from) ≥
/// min_len for every edge; the smallest rank is 0.
pub fn assignRanks(a: Allocator, n: usize, edges: []const LEdge) ![]i32 {
    const rank = try a.alloc(i32, n);
    @memset(rank, 0);
    const indeg = try a.alloc(u32, n);
    defer a.free(indeg);
    @memset(indeg, 0);
    var out_lists = try a.alloc(std.ArrayList(u32), n);
    defer {
        for (out_lists) |*l| l.deinit(a);
        a.free(out_lists);
    }
    var in_lists = try a.alloc(std.ArrayList(u32), n);
    defer {
        for (in_lists) |*l| l.deinit(a);
        a.free(in_lists);
    }
    for (out_lists) |*l| l.* = .empty;
    for (in_lists) |*l| l.* = .empty;
    for (edges, 0..) |e, i| {
        try out_lists[e.from].append(a, @intCast(i));
        try in_lists[e.to].append(a, @intCast(i));
        indeg[e.to] += 1;
    }
    // Longest path in topological order (sources first, by index).
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(a);
    for (0..n) |v| if (indeg[v] == 0) try queue.append(a, @intCast(v));
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const v = queue.items[head];
        for (out_lists[v].items) |ei| {
            const e = edges[ei];
            rank[e.to] = @max(rank[e.to], rank[v] + @as(i32, @intCast(e.min_len)));
            indeg[e.to] -= 1;
            if (indeg[e.to] == 0) try queue.append(a, e.to);
        }
    }
    std.debug.assert(queue.items.len == n);

    // Pull each vertex toward the side with more edge weight.
    var pass: usize = 0;
    while (pass < max_passes) : (pass += 1) {
        var moved = false;
        for (queue.items) |v| {
            var lo: i32 = std.math.minInt(i32);
            var hi: i32 = std.math.maxInt(i32);
            var in_w: f32 = 0;
            var out_w: f32 = 0;
            for (in_lists[v].items) |ei| {
                const e = edges[ei];
                lo = @max(lo, rank[e.from] + @as(i32, @intCast(e.min_len)));
                in_w += e.weight;
            }
            for (out_lists[v].items) |ei| {
                const e = edges[ei];
                hi = @min(hi, rank[e.to] - @as(i32, @intCast(e.min_len)));
                out_w += e.weight;
            }
            const want: i32 = if (in_w > out_w and lo != std.math.minInt(i32))
                lo
            else if (out_w > in_w and hi != std.math.maxInt(i32))
                hi
            else
                rank[v];
            if (want != rank[v]) {
                rank[v] = want;
                moved = true;
            }
        }
        if (!moved) break;
    }
    var min: i32 = std.math.maxInt(i32);
    for (rank) |r| min = @min(min, r);
    if (n > 0) for (rank) |*r| {
        r.* -= min;
    };
    return rank;
}

test {
    std.testing.refAllDecls(@This());
}
