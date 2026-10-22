//! Piece tree nodes and their per-document pool.
//!
//! Nodes are refcounted (`std.atomic.Value(u32)`) and shared between tree
//! versions. A node is mutable only while its count is 1 and it was reached
//! through nodes whose counts were also 1 (`makeMut`); everything else is
//! copied first, which is what makes old versions immutable.
//!
//! Memory ordering: increments are `.monotonic` (a reference can only be
//! copied from one already held); decrements are `.release`, and the thread
//! that drops the last reference issues an `.acquire` load before freeing,
//! so every write made through other references happens-before the free.
//! Only the owner thread (the one that created the pool, the UI thread)
//! touches the free lists. A node whose last reference is dropped on another
//! thread is pushed onto a lock-free garbage stack and freed by the owner in
//! `drainGarbage` (called at frame end).

const std = @import("std");
const Summary = @import("summary.zig").Summary;
const Piece = @import("buffers.zig").Piece;

const Allocator = std.mem.Allocator;

/// Pieces per leaf.
pub const leaf_max = 32;
/// Children per internal node.
pub const inner_max = 16;

/// Common node header; `height == 0` is a leaf.
pub const Node = struct {
    rc: std.atomic.Value(u32) = .init(1),
    height: u8,
    count: u8 = 0,
    /// Combined summary of every slot.
    total: Summary = .empty,
    /// Garbage stack link.
    gc_next: ?*Node = null,

    /// Whether this is a leaf.
    pub inline fn isLeaf(n: *const Node) bool {
        return n.height == 0;
    }

    /// The leaf containing this header.
    pub inline fn leaf(n: *Node) *Leaf {
        std.debug.assert(n.height == 0);
        return @fieldParentPtr("node", n);
    }

    /// The internal node containing this header.
    pub inline fn inner(n: *Node) *Inner {
        std.debug.assert(n.height != 0);
        return @fieldParentPtr("node", n);
    }

    /// The summary of slot `i`.
    pub inline fn sum(n: *Node, i: usize) Summary {
        return if (n.height == 0) n.leaf().sums[i] else n.inner().sums[i];
    }

    /// Adds a reference.
    pub fn retain(n: *Node) void {
        _ = n.rc.fetchAdd(1, .monotonic);
    }

    /// Recomputes `total` from the slot summaries.
    pub fn recompute(n: *Node) void {
        var t: Summary = .empty;
        const sums: []const Summary = if (n.height == 0) n.leaf().sums[0..n.count] else n.inner().sums[0..n.count];
        for (sums) |s| t = t.combine(s);
        n.total = t;
    }
};

/// A leaf: up to 32 pieces with their summaries.
pub const Leaf = struct {
    node: Node,
    sums: [leaf_max]Summary,
    pieces: [leaf_max]Piece,
};

/// An internal node: up to 16 children with cached summaries.
pub const Inner = struct {
    node: Node,
    sums: [inner_max]Summary,
    children: [inner_max]*Node,
};

/// Per-document node allocator with free lists and deferred reclamation.
pub const NodePool = struct {
    gpa: Allocator,
    owner: std.Thread.Id,
    free_leaves: ?*Node = null,
    free_inners: ?*Node = null,
    garbage: std.atomic.Value(?*Node) = .init(null),
    /// Live nodes (for leak checks and tests).
    live: usize = 0,

    /// A pool owned by the calling thread.
    pub fn init(gpa: Allocator) NodePool {
        return .{ .gpa = gpa, .owner = std.Thread.getCurrentId() };
    }

    /// Frees the free lists. Every tree must be released first. Callable
    /// from any thread once nothing else can reach the pool (the last
    /// snapshot of a closed document may be released on a worker).
    pub fn deinit(p: *NodePool) void {
        p.drainAll();
        while (p.free_leaves) |n| {
            p.free_leaves = n.gc_next;
            p.gpa.destroy(n.leaf());
        }
        while (p.free_inners) |n| {
            p.free_inners = n.gc_next;
            p.gpa.destroy(n.inner());
        }
        p.* = undefined;
    }

    /// A fresh leaf with count 0 and refcount 1.
    pub fn allocLeaf(p: *NodePool) Allocator.Error!*Leaf {
        const l: *Leaf = if (p.free_leaves) |n| blk: {
            p.free_leaves = n.gc_next;
            break :blk n.leaf();
        } else try p.gpa.create(Leaf);
        l.node = .{ .height = 0 };
        p.live += 1;
        return l;
    }

    /// A fresh internal node of `height` with count 0 and refcount 1.
    pub fn allocInner(p: *NodePool, height: u8) Allocator.Error!*Inner {
        std.debug.assert(height > 0);
        const in: *Inner = if (p.free_inners) |n| blk: {
            p.free_inners = n.gc_next;
            n.height = 1; // satisfy the inner() assertion
            break :blk n.inner();
        } else try p.gpa.create(Inner);
        in.node = .{ .height = height };
        p.live += 1;
        return in;
    }

    /// Returns a node shell to the free list without touching its children
    /// (their references were moved elsewhere). Owner thread only.
    pub fn freeShell(p: *NodePool, n: *Node) void {
        p.live -= 1;
        if (n.height == 0) {
            n.gc_next = p.free_leaves;
            p.free_leaves = n;
        } else {
            n.gc_next = p.free_inners;
            p.free_inners = n;
        }
    }

    /// Drops a reference (any thread). The last reference frees the node and
    /// releases its children, inline on the owner thread or deferred to
    /// `drainGarbage` elsewhere.
    pub fn release(p: *NodePool, n: *Node) void {
        if (n.rc.fetchSub(1, .release) != 1) return;
        _ = n.rc.load(.acquire);
        if (std.Thread.getCurrentId() == p.owner) {
            p.destroy(n);
        } else {
            var head = p.garbage.load(.monotonic);
            while (true) {
                n.gc_next = head;
                head = p.garbage.cmpxchgWeak(head, n, .release, .monotonic) orelse break;
            }
        }
    }

    fn destroy(p: *NodePool, n: *Node) void {
        if (n.height != 0) {
            const in = n.inner();
            for (in.children[0..n.count]) |c| p.release(c);
        }
        p.freeShell(n);
    }

    /// Frees nodes released on other threads. Owner thread only.
    pub fn drainGarbage(p: *NodePool) void {
        std.debug.assert(std.Thread.getCurrentId() == p.owner);
        p.drainAll();
    }

    /// Drains until empty: destroying a node off the owner thread may push
    /// its children back onto the stack.
    fn drainAll(p: *NodePool) void {
        while (p.garbage.swap(null, .acquire)) |first| {
            var head: ?*Node = first;
            while (head) |n| {
                head = n.gc_next;
                p.destroy(n);
            }
        }
    }

    /// Returns `n` itself when it is uniquely owned, otherwise a copy (with
    /// the children retained) after dropping the reference to `n`. Owner
    /// thread only.
    pub fn makeMut(p: *NodePool, n: *Node) Allocator.Error!*Node {
        if (n.rc.load(.acquire) == 1) return n;
        const copy: *Node = if (n.height == 0) blk: {
            const l = try p.allocLeaf();
            const src = n.leaf();
            l.sums = src.sums;
            l.pieces = src.pieces;
            break :blk &l.node;
        } else blk: {
            const in = try p.allocInner(n.height);
            const src = n.inner();
            in.sums = src.sums;
            in.children = src.children;
            for (in.children[0..n.count]) |c| c.retain();
            break :blk &in.node;
        };
        copy.count = n.count;
        copy.total = n.total;
        p.release(n);
        return copy;
    }
};

test "node_pool: makeMut copies shared nodes and reuses unique ones" {
    var pool: NodePool = .init(std.testing.allocator);
    defer pool.deinit();
    const l = try pool.allocLeaf();
    const n = &l.node;
    try std.testing.expectEqual(n, try pool.makeMut(n));
    n.retain();
    const c = try pool.makeMut(n);
    try std.testing.expect(c != n);
    try std.testing.expectEqual(@as(u32, 1), n.rc.load(.monotonic));
    pool.release(c);
    pool.release(n);
    try std.testing.expectEqual(@as(usize, 0), pool.live);
}

test "node_pool: release on another thread defers to drain" {
    var pool: NodePool = .init(std.testing.allocator);
    defer pool.deinit();
    const l = try pool.allocLeaf();
    const t = try std.Thread.spawn(.{}, NodePool.release, .{ &pool, &l.node });
    t.join();
    try std.testing.expectEqual(@as(usize, 1), pool.live);
    pool.drainGarbage();
    try std.testing.expectEqual(@as(usize, 0), pool.live);
}
