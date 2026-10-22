//! An interval tree over byte ranges with lazy offset deltas: a treap
//! keyed by (start, node index), augmented with the subtree's maximum end.
//! Shifting every interval after a position is a split, one tag and a
//! merge, O(log n), however many intervals move.
//!
//! A node's own `start`, `end` and `max_end` already include its own
//! `lazy`; `lazy` is still owed to its children. Queries carry the owed
//! offset down instead of pushing it, so they do not mutate.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const nil = std.math.maxInt(u32);

pub const Node = struct {
    start: u64,
    end: u64,
    max_end: u64,
    /// Owed to the children (two's complement, wrapping).
    lazy: u64 = 0,
    left: u32 = nil,
    right: u32 = nil,
    parent: u32 = nil,
    prio: u32,
};

comptime {
    std.debug.assert(@sizeOf(Node) == 48);
}

pub const Bounds = struct { start: u64, end: u64 };

pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    free: std.ArrayList(u32) = .empty,
    root: u32 = nil,
    len: usize = 0,
    rng: u64 = 0x9e3779b97f4a7c15,

    pub fn deinit(t: *Tree, gpa: Allocator) void {
        t.nodes.deinit(gpa);
        t.free.deinit(gpa);
    }

    /// Adds `[start, end]`; returns its node index (stable until removed).
    pub fn insert(t: *Tree, gpa: Allocator, start: u64, end: u64) Allocator.Error!u32 {
        std.debug.assert(start <= end);
        try t.free.ensureTotalCapacity(gpa, t.nodes.items.len + 1);
        const n: u32 = if (t.free.pop()) |f| f else blk: {
            try t.nodes.append(gpa, undefined);
            break :blk @intCast(t.nodes.items.len - 1);
        };
        t.nodes.items[n] = .{ .start = start, .end = end, .max_end = end, .prio = t.nextPrio() };
        t.link(n);
        t.len += 1;
        return n;
    }

    /// Removes node `n`.
    pub fn remove(t: *Tree, n: u32) void {
        t.unlink(n);
        t.free.appendAssumeCapacity(n);
        t.len -= 1;
    }

    /// A node index not in the tree (for `rebuild` or `attach`).
    pub fn alloc(t: *Tree, gpa: Allocator) Allocator.Error!u32 {
        try t.free.ensureTotalCapacity(gpa, t.nodes.items.len + 1);
        if (t.free.pop()) |f| {
            t.nodes.items[f].prio = t.nextPrio();
            return f;
        }
        try t.nodes.append(gpa, .{ .start = 0, .end = 0, .max_end = 0, .prio = t.nextPrio() });
        return @intCast(t.nodes.items.len - 1);
    }

    pub const Item = struct { node: u32, start: u64, end: u64 };

    /// Replaces the whole tree with `items`, sorted by (start, node), in
    /// O(n). Nodes left out must be freed with `freeDetached`. `stack` needs
    /// room for `items.len` entries.
    pub fn rebuild(t: *Tree, items: []const Item, stack: []u32) void {
        var depth: usize = 0;
        for (items) |it| {
            const n = it.node;
            const node = &t.nodes.items[n];
            node.* = .{ .start = it.start, .end = it.end, .max_end = it.end, .prio = node.prio };
            // Cartesian tree by priority: pop the lower ones into the left
            // child.
            var last: u32 = nil;
            while (depth > 0 and t.nodes.items[stack[depth - 1]].prio < node.prio) {
                depth -= 1;
                last = stack[depth];
            }
            t.setLeft(n, last);
            if (depth > 0) t.setRight(stack[depth - 1], n) else node.parent = nil;
            stack[depth] = n;
            depth += 1;
        }
        t.root = if (items.len > 0) stack[0] else nil;
        if (t.root != nil) {
            t.nodes.items[t.root].parent = nil;
            _ = t.pullAll(t.root);
        }
        t.len = items.len;
    }

    fn pullAll(t: *Tree, n: u32) u64 {
        const node = &t.nodes.items[n];
        var m = node.end;
        if (node.left != nil) m = @max(m, t.pullAll(node.left));
        if (node.right != nil) m = @max(m, t.pullAll(node.right));
        t.nodes.items[n].max_end = m;
        return m;
    }

    /// Takes node `n` out of the tree without freeing it (for `attach`).
    pub fn detach(t: *Tree, n: u32) void {
        t.unlink(n);
        t.len -= 1;
    }

    /// Puts a detached node back at `[start, end]`.
    pub fn attach(t: *Tree, n: u32, start: u64, end: u64) void {
        std.debug.assert(start <= end);
        const node = &t.nodes.items[n];
        node.* = .{ .start = start, .end = end, .max_end = end, .prio = node.prio };
        t.link(n);
        t.len += 1;
    }

    /// Frees a detached node.
    pub fn freeDetached(t: *Tree, n: u32) void {
        t.free.appendAssumeCapacity(n);
    }

    /// Moves node `n` to `[start, end]`.
    pub fn move(t: *Tree, n: u32, start: u64, end: u64) void {
        t.unlink(n);
        const node = &t.nodes.items[n];
        node.* = .{ .start = start, .end = end, .max_end = end, .prio = node.prio };
        t.link(n);
    }

    /// The current bounds of node `n`.
    pub fn bounds(t: *const Tree, n: u32) Bounds {
        var acc: u64 = 0;
        var p = t.nodes.items[n].parent;
        while (p != nil) : (p = t.nodes.items[p].parent) acc +%= t.nodes.items[p].lazy;
        const node = t.nodes.items[n];
        return .{ .start = node.start +% acc, .end = node.end +% acc };
    }

    /// Adds `d` to every interval starting after `after`. The caller keeps
    /// the order: shifted starts must stay above every unshifted one.
    pub fn shift(t: *Tree, after: u64, d: i64) void {
        if (d == 0 or t.root == nil) return;
        const parts = t.split(t.root, .{ .start = after +| 1, .idx = 0 });
        if (parts.r != nil) t.apply(parts.r, @bitCast(d));
        t.root = t.merge(parts.l, parts.r);
        if (t.root != nil) t.nodes.items[t.root].parent = nil;
    }

    /// Some node intersecting `[a, b]` (`start <= b and end >= a`), or nil.
    pub fn findIntersecting(t: *const Tree, a: u64, b: u64) u32 {
        return t.findIn(t.root, 0, a, b);
    }

    fn findIn(t: *const Tree, n: u32, acc: u64, a: u64, b: u64) u32 {
        if (n == nil) return nil;
        const node = &t.nodes.items[n];
        if (node.max_end +% acc < a) return nil;
        const s = node.start +% acc;
        const child = acc +% node.lazy;
        const l = t.findIn(node.left, child, a, b);
        if (l != nil) return l;
        if (s > b) return nil;
        if (node.end +% acc >= a) return n;
        return t.findIn(node.right, child, a, b);
    }

    /// Calls `f(ctx, node, bounds)` for every interval intersecting
    /// `[a, b]`, in key order.
    pub fn query(t: *const Tree, a: u64, b: u64, ctx: anytype, comptime f: fn (@TypeOf(ctx), u32, Bounds) void) void {
        t.queryIn(t.root, 0, a, b, ctx, f);
    }

    fn queryIn(t: *const Tree, n: u32, acc: u64, a: u64, b: u64, ctx: anytype, comptime f: fn (@TypeOf(ctx), u32, Bounds) void) void {
        if (n == nil) return;
        const node = &t.nodes.items[n];
        if (node.max_end +% acc < a) return;
        const child = acc +% node.lazy;
        t.queryIn(node.left, child, a, b, ctx, f);
        const s = node.start +% acc;
        if (s > b) return;
        const e = node.end +% acc;
        if (e >= a) f(ctx, n, .{ .start = s, .end = e });
        t.queryIn(node.right, child, a, b, ctx, f);
    }

    /// Checks the treap, heap and augmentation invariants (tests).
    pub fn check(t: *const Tree) !void {
        var count: usize = 0;
        _ = try t.checkIn(t.root, nil, 0, &count);
        if (count != t.len) return error.BadCount;
    }

    fn checkIn(t: *const Tree, n: u32, parent: u32, acc: u64, count: *usize) !u64 {
        if (n == nil) return 0;
        count.* += 1;
        const node = t.nodes.items[n];
        if (node.parent != parent) return error.BadParent;
        if (parent != nil and node.prio > t.nodes.items[parent].prio) return error.BadHeap;
        const s = node.start +% acc;
        const child = acc +% node.lazy;
        var max = node.end +% acc;
        if (node.left != nil) {
            if (t.keyLess(node.left, child, n, acc) == false) return error.BadOrder;
            max = @max(max, try t.checkIn(node.left, n, child, count));
        }
        if (node.right != nil) {
            if (t.keyLess(n, acc, node.right, child) == false) return error.BadOrder;
            max = @max(max, try t.checkIn(node.right, n, child, count));
        }
        if (s > node.end +% acc) return error.BadInterval;
        if (max != node.max_end +% acc) return error.BadMaxEnd;
        return max;
    }

    fn keyLess(t: *const Tree, x: u32, xacc: u64, y: u32, yacc: u64) bool {
        const xs = t.nodes.items[x].start +% xacc;
        const ys = t.nodes.items[y].start +% yacc;
        return xs < ys or (xs == ys and x < y);
    }

    // -- treap mechanics ----------------------------------------------------

    const Key = struct { start: u64, idx: u32 };

    fn nextPrio(t: *Tree) u32 {
        t.rng ^= t.rng << 13;
        t.rng ^= t.rng >> 7;
        t.rng ^= t.rng << 17;
        return @truncate(t.rng);
    }

    fn apply(t: *Tree, n: u32, d: u64) void {
        const node = &t.nodes.items[n];
        node.start +%= d;
        node.end +%= d;
        node.max_end +%= d;
        node.lazy +%= d;
    }

    fn push(t: *Tree, n: u32) void {
        const node = &t.nodes.items[n];
        if (node.lazy == 0) return;
        if (node.left != nil) t.apply(node.left, node.lazy);
        if (node.right != nil) t.apply(node.right, node.lazy);
        node.lazy = 0;
    }

    fn pull(t: *Tree, n: u32) void {
        const node = &t.nodes.items[n];
        var m = node.end;
        if (node.left != nil) m = @max(m, t.nodes.items[node.left].max_end);
        if (node.right != nil) m = @max(m, t.nodes.items[node.right].max_end);
        node.max_end = m;
    }

    fn setLeft(t: *Tree, n: u32, c: u32) void {
        t.nodes.items[n].left = c;
        if (c != nil) t.nodes.items[c].parent = n;
    }

    fn setRight(t: *Tree, n: u32, c: u32) void {
        t.nodes.items[n].right = c;
        if (c != nil) t.nodes.items[c].parent = n;
    }

    fn less(t: *const Tree, n: u32, k: Key) bool {
        const s = t.nodes.items[n].start;
        return s < k.start or (s == k.start and n < k.idx);
    }

    /// Splits into keys `< k` and `>= k`.
    fn split(t: *Tree, n: u32, k: Key) struct { l: u32, r: u32 } {
        if (n == nil) return .{ .l = nil, .r = nil };
        t.push(n);
        if (t.less(n, k)) {
            const parts = t.split(t.nodes.items[n].right, k);
            t.setRight(n, parts.l);
            t.pull(n);
            if (parts.r != nil) t.nodes.items[parts.r].parent = nil;
            return .{ .l = n, .r = parts.r };
        } else {
            const parts = t.split(t.nodes.items[n].left, k);
            t.setLeft(n, parts.r);
            t.pull(n);
            if (parts.l != nil) t.nodes.items[parts.l].parent = nil;
            return .{ .l = parts.l, .r = n };
        }
    }

    /// Joins two treaps whose keys are all ordered `a < b`.
    fn merge(t: *Tree, a: u32, b: u32) u32 {
        if (a == nil) return b;
        if (b == nil) return a;
        if (t.nodes.items[a].prio > t.nodes.items[b].prio) {
            t.push(a);
            t.setRight(a, t.merge(t.nodes.items[a].right, b));
            t.pull(a);
            return a;
        } else {
            t.push(b);
            t.setLeft(b, t.merge(a, t.nodes.items[b].left));
            t.pull(b);
            return b;
        }
    }

    /// Inserts the detached node `n` (its fields are absolute).
    fn link(t: *Tree, n: u32) void {
        const parts = t.split(t.root, .{ .start = t.nodes.items[n].start, .idx = n });
        t.root = t.merge(t.merge(parts.l, n), parts.r);
        t.nodes.items[t.root].parent = nil;
    }

    /// Detaches `n`, leaving its fields absolute.
    fn unlink(t: *Tree, n: u32) void {
        // Push the owed offsets down the path from the root to `n`.
        var path: [128]u32 = undefined;
        var depth: usize = 0;
        var p = t.nodes.items[n].parent;
        while (p != nil) : (p = t.nodes.items[p].parent) {
            path[depth] = p;
            depth += 1;
        }
        var i = depth;
        while (i > 0) {
            i -= 1;
            t.push(path[i]);
        }
        t.push(n);
        const node = &t.nodes.items[n];
        const sub = t.merge(node.left, node.right);
        const parent = node.parent;
        if (parent == nil) {
            t.root = sub;
            if (sub != nil) t.nodes.items[sub].parent = nil;
        } else if (t.nodes.items[parent].left == n) {
            t.setLeft(parent, sub);
        } else {
            t.setRight(parent, sub);
        }
        for (path[0..depth]) |a| t.pull(a);
        node.left = nil;
        node.right = nil;
        node.parent = nil;
        node.max_end = node.end;
    }
};

const testing = std.testing;

test "interval_tree: insert, query, shift, move, remove against naive" {
    const gpa = testing.allocator;
    var t: Tree = .{};
    defer t.deinit(gpa);
    var naive: std.AutoArrayHashMapUnmanaged(u32, Bounds) = .empty;
    defer naive.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    for (0..3000) |step| {
        switch (r.uintLessThan(u8, 10)) {
            0...3 => {
                const s = r.uintLessThan(u64, 1000);
                const e = s + r.uintLessThan(u64, 50);
                const n = try t.insert(gpa, s, e);
                try naive.put(gpa, n, .{ .start = s, .end = e });
            },
            4 => if (naive.count() > 0) {
                const n = naive.keys()[r.uintLessThan(usize, naive.count())];
                t.remove(n);
                _ = naive.swapRemove(n);
            },
            5 => if (naive.count() > 0) {
                const n = naive.keys()[r.uintLessThan(usize, naive.count())];
                const s = r.uintLessThan(u64, 1000);
                t.move(n, s, s + 3);
                naive.putAssumeCapacity(n, .{ .start = s, .end = s + 3 });
            },
            6 => {
                // Shift by a delta that keeps order: up, or down no
                // further than the gap above the last unshifted start.
                const after = r.uintLessThan(u64, 1000);
                var max_below: u64 = 0;
                var min_above: u64 = std.math.maxInt(u64);
                for (naive.values()) |b| {
                    if (b.start <= after) max_below = @max(max_below, b.start) else min_above = @min(min_above, b.start);
                }
                const room: i64 = if (min_above == std.math.maxInt(u64)) 0 else @intCast(min_above - max_below - 1);
                const d: i64 = r.intRangeAtMost(i64, -@min(room, 20), 20);
                t.shift(after, d);
                for (naive.values()) |*b| if (b.start > after) {
                    b.start = @intCast(@as(i64, @intCast(b.start)) + d);
                    b.end = @intCast(@as(i64, @intCast(b.end)) + d);
                };
            },
            else => {
                const a = r.uintLessThan(u64, 1100);
                const b = a + r.uintLessThan(u64, 100);
                var got: std.ArrayList(u32) = .empty;
                defer got.deinit(gpa);
                const Ctx = struct {
                    list: *std.ArrayList(u32),
                    fn f(c: @This(), n: u32, _: Bounds) void {
                        c.list.append(testing.allocator, n) catch unreachable;
                    }
                };
                t.query(a, b, Ctx{ .list = &got }, Ctx.f);
                var want: usize = 0;
                for (naive.keys(), naive.values()) |n, bb| if (bb.start <= b and bb.end >= a) {
                    want += 1;
                    try testing.expect(std.mem.indexOfScalar(u32, got.items, n) != null);
                };
                try testing.expectEqual(want, got.items.len);
                const any = t.findIntersecting(a, b);
                try testing.expectEqual(want == 0, any == nil);
            },
        }
        if (step % 50 == 0) {
            try t.check();
            for (naive.keys(), naive.values()) |n, b| try testing.expectEqual(b, t.bounds(n));
        }
    }
}
