//! Ancestry over the commit index: `isAncestor`, merge bases and ancestor
//! walks.
//!
//! Generation numbers prune the searches: a commit can only reach `a` if it
//! has a higher topological level and a later corrected time.
//! `isAncestor` walks from both ends at once, back from `b` through parents
//! and forward from `a` through children, and answers as soon as the walks
//! meet or either runs out. A commit on an abandoned branch has few
//! descendants, so "no" stays cheap even when `b` has a long history.
//! `mergeBases` is git's paint-down: walk both sides newest first (by
//! corrected time) painting each commit with the sides that reach it, and
//! stop once every queued commit is stale.

const std = @import("std");
const index = @import("index.zig");
const View = index.View;
const Pos = index.Pos;
const Allocator = std.mem.Allocator;

/// The commits a view (F03) shows; children are filtered by it.
pub const VisibleSet = struct {
    bits: std.DynamicBitSetUnmanaged,

    pub fn contains(v: *const VisibleSet, p: Pos) bool {
        return p.int() < v.bits.bit_length and v.bits.isSet(p.int());
    }
};

const p1: u8 = 1;
const p2: u8 = 2;
const stale: u8 = 4;
const result: u8 = 8;

const QItem = struct {
    ctime: u64,
    level: u32,
    pos: u32,

    fn of(v: *const View, x: u32) QItem {
        const p = Pos.of(x);
        return .{ .ctime = v.correctedTime(p), .level = v.level(p), .pos = x };
    }

    /// Newest first.
    fn cmp(_: void, a: QItem, b: QItem) std.math.Order {
        if (a.ctime != b.ctime) return std.math.order(b.ctime, a.ctime);
        if (a.level != b.level) return std.math.order(b.level, a.level);
        return std.math.order(b.pos, a.pos);
    }
};

const Queue = std.PriorityQueue(QItem, void, QItem.cmp);

/// Reusable scratch for ancestry queries: one colour byte per position,
/// cleared through a dirty list so a query costs only what it touches.
pub const Walker = struct {
    gpa: Allocator,
    color: std.ArrayList(u8) = .empty,
    dirty: std.ArrayList(u32) = .empty,
    stack: std.ArrayList(u32) = .empty,
    fwd: std.ArrayList(u32) = .empty,
    queue: Queue = .empty,

    pub fn init(gpa: Allocator) Walker {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Walker) void {
        w.color.deinit(w.gpa);
        w.dirty.deinit(w.gpa);
        w.stack.deinit(w.gpa);
        w.fwd.deinit(w.gpa);
        w.queue.deinit(w.gpa);
    }

    fn prepare(w: *Walker, n: u32) Allocator.Error!void {
        const old = w.color.items.len;
        if (old < n) {
            try w.color.resize(w.gpa, n);
            @memset(w.color.items[old..], 0);
        }
    }

    inline fn mark(w: *Walker, x: u32, bits: u8) Allocator.Error!void {
        if (w.color.items[x] == 0) try w.dirty.append(w.gpa, x);
        w.color.items[x] |= bits;
    }

    fn reset(w: *Walker) void {
        for (w.dirty.items) |x| w.color.items[x] = 0;
        w.dirty.clearRetainingCapacity();
        w.stack.clearRetainingCapacity();
        w.fwd.clearRetainingCapacity();
        w.queue.clearRetainingCapacity();
    }

    /// Whether `a` is `b` or one of its ancestors.
    pub fn isAncestor(w: *Walker, v: *const View, a: Pos, b: Pos) Allocator.Error!bool {
        if (a == b) return true;
        const la = v.level(a);
        const ca = v.correctedTime(a);
        const lb = v.level(b);
        const cb = v.correctedTime(b);
        if (la >= lb or ca >= cb) return false;
        try v.ensureChildren();
        try w.prepare(v.count);
        defer w.reset();
        // p1: reached back from b; p2: reached forward from a.
        try w.mark(b.int(), p1);
        try w.mark(a.int(), p2);
        try w.stack.append(w.gpa, b.int());
        try w.fwd.append(w.gpa, a.int());
        while (w.stack.items.len > 0 and w.fwd.items.len > 0) {
            // Step the smaller frontier, so the cost stays near twice the
            // cheaper of the two walks.
            if (w.stack.items.len <= w.fwd.items.len) {
                if (try w.stepBack(v, la, ca)) return true;
            } else if (try w.stepForward(v, lb, cb)) return true;
        }
        return false;
    }

    fn stepBack(w: *Walker, v: *const View, la: u32, ca: u64) Allocator.Error!bool {
        {
            const x = w.stack.pop().?;
            var ps = v.parents(Pos.of(x));
            while (ps.next()) |p| {
                const pi = p.int();
                const c = w.color.items[pi];
                if (c & p2 != 0) return true;
                if (c != 0) continue;
                try w.mark(pi, p1);
                if (v.level(p) <= la or v.correctedTime(p) <= ca) continue;
                try w.stack.append(w.gpa, pi);
            }
        }
        return false;
    }

    fn stepForward(w: *Walker, v: *const View, lb: u32, cb: u64) Allocator.Error!bool {
        {
            const y = w.fwd.pop().?;
            var ks = v.childrenBuilt(Pos.of(y), null);
            while (ks.next()) |k| {
                const ki = k.int();
                const c = w.color.items[ki];
                if (c & p1 != 0) return true;
                if (c != 0) continue;
                if (v.level(k) >= lb or v.correctedTime(k) >= cb) continue;
                try w.mark(ki, p2);
                try w.fwd.append(w.gpa, ki);
            }
        }
        return false;
    }

    /// The best common ancestors of `a` and `b`: common ancestors none of
    /// which is an ancestor of another. Newest first; caller frees.
    pub fn mergeBases(w: *Walker, v: *const View, gpa: Allocator, a: Pos, b: Pos) Allocator.Error![]Pos {
        if (a == b) {
            const out = try gpa.alloc(Pos, 1);
            out[0] = a;
            return out;
        }
        try w.prepare(v.count);
        var found: std.ArrayList(u32) = .empty;
        defer found.deinit(w.gpa);
        {
            defer w.reset();
            try w.mark(a.int(), p1);
            try w.mark(b.int(), p2);
            try w.queue.push(w.gpa, QItem.of(v, a.int()));
            try w.queue.push(w.gpa, QItem.of(v, b.int()));
            while (w.hasNonStale()) {
                const x = w.queue.pop().?.pos;
                var flags = w.color.items[x] & (p1 | p2 | stale);
                if (flags == p1 | p2) {
                    if (w.color.items[x] & result == 0) {
                        try w.mark(x, result);
                        try found.append(w.gpa, x);
                    }
                    flags |= stale;
                }
                var ps = v.parents(Pos.of(x));
                while (ps.next()) |p| {
                    const pi = p.int();
                    if (w.color.items[pi] & flags == flags) continue;
                    try w.mark(pi, flags);
                    try w.queue.push(w.gpa, QItem.of(v, pi));
                }
            }
        }
        // Drop candidates that are ancestors of other candidates.
        var keep: std.ArrayList(Pos) = .empty;
        errdefer keep.deinit(gpa);
        outer: for (found.items, 0..) |x, i| {
            for (found.items, 0..) |y, j| {
                if (i != j and try w.isAncestor(v, Pos.of(x), Pos.of(y))) continue :outer;
            }
            try keep.append(gpa, Pos.of(x));
        }
        const S = struct {
            v: *const View,
            fn newer(c: @This(), l: Pos, r: Pos) bool {
                return QItem.cmp({}, QItem.of(c.v, l.int()), QItem.of(c.v, r.int())) == .lt;
            }
        };
        std.mem.sort(Pos, keep.items, S{ .v = v }, S.newer);
        return keep.toOwnedSlice(gpa);
    }

    fn hasNonStale(w: *const Walker) bool {
        for (w.queue.items) |it| {
            if (w.color.items[it.pos] & stale == 0) return true;
        }
        return false;
    }
};

pub const WalkOpts = struct {
    /// Stop after this many commits.
    limit: ?usize = null,
};

/// Streams the ancestors of a set of commits (the starts included), newest
/// corrected time first. Free with `deinit`.
pub const AncestorIter = struct {
    gpa: Allocator,
    view: *const View,
    seen: std.DynamicBitSetUnmanaged,
    queue: Queue = .empty,
    left: ?usize,

    pub fn deinit(it: *AncestorIter) void {
        it.seen.deinit(it.gpa);
        it.queue.deinit(it.gpa);
    }

    pub fn next(it: *AncestorIter) Allocator.Error!?Pos {
        if (it.left) |*l| {
            if (l.* == 0) return null;
            l.* -= 1;
        }
        const top = it.queue.pop() orelse return null;
        var ps = it.view.parents(Pos.of(top.pos));
        while (ps.next()) |p| try it.push(p.int());
        return Pos.of(top.pos);
    }

    fn push(it: *AncestorIter, x: u32) Allocator.Error!void {
        if (it.seen.isSet(x)) return;
        it.seen.set(x);
        try it.queue.push(it.gpa, QItem.of(it.view, x));
    }
};

pub fn walkAncestors(gpa: Allocator, v: *const View, starts: []const Pos, opts: WalkOpts) Allocator.Error!AncestorIter {
    var it: AncestorIter = .{ .gpa = gpa, .view = v, .seen = try .initEmpty(gpa, v.count), .left = opts.limit };
    errdefer it.deinit();
    for (starts) |s| try it.push(s.int());
    return it;
}
