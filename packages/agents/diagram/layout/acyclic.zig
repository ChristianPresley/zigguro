//! Cycle removal (E13.F07.S02.T02): the Eades–Lin–Smyth greedy order —
//! peel sinks to the back and sources to the front, else take the
//! vertex with the largest out − in degree — and reverse the edges that
//! point backward in it.

const std = @import("std");
const graph = @import("graph.zig");

const Allocator = std.mem.Allocator;
const LEdge = graph.LEdge;

/// Reverses a small set of `edges` (over `n` vertices) so none form a
/// cycle; returns how many were reversed. Self-loops must be removed
/// first.
pub fn removeCycles(a: Allocator, n: usize, edges: []LEdge) !usize {
    const out_w = try a.alloc(f32, n);
    defer a.free(out_w);
    const in_w = try a.alloc(f32, n);
    defer a.free(in_w);
    const gone = try a.alloc(bool, n);
    defer a.free(gone);
    @memset(out_w, 0);
    @memset(in_w, 0);
    @memset(gone, false);
    // Adjacency as edge indexes per vertex.
    const out_start = try a.alloc(u32, n + 1);
    defer a.free(out_start);
    const in_start = try a.alloc(u32, n + 1);
    defer a.free(in_start);
    const out_list = try a.alloc(u32, edges.len);
    defer a.free(out_list);
    const in_list = try a.alloc(u32, edges.len);
    defer a.free(in_list);
    csr(n, edges, out_start, out_list, true);
    csr(n, edges, in_start, in_list, false);
    for (edges) |e| {
        out_w[e.from] += e.weight;
        in_w[e.to] += e.weight;
    }

    // s1 grows from the front, s2 from the back.
    const pos = try a.alloc(u32, n);
    defer a.free(pos);
    var front: u32 = 0;
    var back: u32 = @intCast(n);
    var left = n;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    while (left > 0) {
        var changed = true;
        while (changed) {
            changed = false;
            // Sinks (then sources), repeatedly; removing one may make
            // others.
            for (0..n) |v| if (!gone[v] and out_w[v] <= 0) {
                try stack.append(a, @intCast(v));
                while (stack.pop()) |s| {
                    if (gone[s] or out_w[s] > 0) continue;
                    back -= 1;
                    pos[s] = back;
                    remove(s, edges, out_start, out_list, in_start, in_list, gone, out_w, in_w);
                    left -= 1;
                    changed = true;
                    for (in_list[in_start[s]..in_start[s + 1]]) |ei| {
                        const u = edges[ei].from;
                        if (!gone[u] and out_w[u] <= 0) try stack.append(a, u);
                    }
                }
            };
            for (0..n) |v| if (!gone[v] and in_w[v] <= 0) {
                try stack.append(a, @intCast(v));
                while (stack.pop()) |s| {
                    if (gone[s] or in_w[s] > 0) continue;
                    pos[s] = front;
                    front += 1;
                    remove(s, edges, out_start, out_list, in_start, in_list, gone, out_w, in_w);
                    left -= 1;
                    changed = true;
                    for (out_list[out_start[s]..out_start[s + 1]]) |ei| {
                        const w = edges[ei].to;
                        if (!gone[w] and in_w[w] <= 0) try stack.append(a, w);
                    }
                }
            };
        }
        if (left == 0) break;
        var best: ?u32 = null;
        var best_d: f32 = -std.math.inf(f32);
        for (0..n) |v| if (!gone[v]) {
            const d = out_w[v] - in_w[v];
            if (d > best_d) {
                best_d = d;
                best = @intCast(v);
            }
        };
        const v = best.?;
        pos[v] = front;
        front += 1;
        remove(v, edges, out_start, out_list, in_start, in_list, gone, out_w, in_w);
        left -= 1;
    }
    var reversed: usize = 0;
    for (edges) |*e| if (pos[e.from] > pos[e.to]) {
        std.mem.swap(u32, &e.from, &e.to);
        e.reversed = !e.reversed;
        reversed += 1;
    };
    return reversed;
}

fn csr(n: usize, edges: []const LEdge, start: []u32, list: []u32, out: bool) void {
    @memset(start, 0);
    for (edges) |e| start[(if (out) e.from else e.to) + 1] += 1;
    for (1..n + 1) |i| start[i] += start[i - 1];
    // Place with `start` as the cursor; afterwards start[v] is the end
    // of v's range.
    for (edges, 0..) |e, i| {
        const v = if (out) e.from else e.to;
        list[start[v]] = @intCast(i);
        start[v] += 1;
    }
    var i: usize = n;
    while (i > 0) : (i -= 1) start[i] = start[i - 1];
    start[0] = 0;
}

fn remove(v: u32, edges: []const LEdge, out_start: []const u32, out_list: []const u32, in_start: []const u32, in_list: []const u32, gone: []bool, out_w: []f32, in_w: []f32) void {
    gone[v] = true;
    for (out_list[out_start[v]..out_start[v + 1]]) |ei| in_w[edges[ei].to] -= edges[ei].weight;
    for (in_list[in_start[v]..in_start[v + 1]]) |ei| out_w[edges[ei].from] -= edges[ei].weight;
}

test {
    std.testing.refAllDecls(@This());
}
