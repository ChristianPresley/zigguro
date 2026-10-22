//! Ancestry over the commit index: `isAncestor`, merge bases and ancestor
//! walks.
//!
//! Generation numbers prune the searches: a commit can only reach `a` if it
//! has a higher topological level and a later corrected time.
//! Reachability labels (GRAIL) prune further. Two depth-first walks over
//! parent edges number every commit; a commit's post-order interval must
//! contain the interval of anything it reaches, which answers most "no"
//! queries outright, and a commit inside another's spanning subtree is
//! surely reached, which answers most "yes" queries. The first walk runs
//! down the longest lines of history first, so their subtrees are exact
//! and a search reaches one within a few steps.
//! `isAncestor` walks from both ends at once, back from `b` through parents
//! and forward from `a` through children, skipping commits whose labels
//! rule them out, and answers as soon as the walks meet or either runs out.
//! `mergeBases` is git's paint-down: walk both sides newest first (by
//! corrected time) painting each commit with the sides that reach it, and
//! stop once every queued commit is stale.

const std = @import("std");
const index = @import("index.zig");
const View = index.View;
const Pos = index.Pos;
const seg = @import("index_segment.zig");
const ObjectId = @import("../store/id.zig").ObjectId;
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

/// Depth-first walks per labelling.
const dims = 2;

/// One commit's reachability label. `low[d]..post[d]` is the interval from
/// depth-first walk `d` (over parent edges, from the heads); `pre[d]` and
/// `post[d]` place the commit in that walk's spanning tree.
const Label = struct {
    pre: [dims]u32,
    post: [dims]u32,
    low: [dims]u32,
};

/// The labels of a view's positions. They stay valid for later views of
/// the same index: indexing only appends positions, and folding segments
/// together copies their entries in order, so the first segment and the
/// last labelled commit identify the history they describe.
const Labels = struct {
    items: std.ArrayList(Label) = .empty,
    first: [seg.checksum_len]u8 = undefined,
    last: ObjectId = undefined,
    /// Positions covered by the last full build.
    built: u32 = 0,

    fn deinit(l: *Labels, gpa: Allocator) void {
        l.items.deinit(gpa);
    }

    fn clear(l: *Labels) void {
        l.items.clearRetainingCapacity();
        l.built = 0;
    }

    /// Whether `x` may reach `a`: its intervals contain `a`'s.
    inline fn mayReach(l: *const Labels, x: u32, a: u32) bool {
        const lx = &l.items.items[x];
        const la = &l.items.items[a];
        inline for (0..dims) |d| {
            if (lx.low[d] > la.low[d] or la.post[d] > lx.post[d]) return false;
        }
        return true;
    }

    /// Whether `a` is in `x`'s subtree of either walk, so `x` surely
    /// reaches it.
    inline fn treeReach(l: *const Labels, x: u32, a: u32) bool {
        const lx = &l.items.items[x];
        const la = &l.items.items[a];
        inline for (0..dims) |d| {
            if (lx.pre[d] <= la.pre[d] and la.post[d] <= lx.post[d]) return true;
        }
        return false;
    }

    /// How many positions of `v` the labels describe.
    fn reusable(l: *const Labels, v: *const View) u32 {
        const n: u32 = @intCast(l.items.items.len);
        if (n == 0 or v.segs.len == 0) return 0;
        if (!std.mem.eql(u8, &l.first, &v.segs[0].seg.checksum())) return 0;
        if (v.count < n) return v.count;
        return if (v.id(Pos.of(n - 1)).eql(l.last)) n else 0;
    }

    /// Labels every position of `v`: extended in place for appended
    /// positions, rebuilt when they cannot be reused or have grown by more
    /// than a quarter since the last build (extensions get wide intervals).
    fn ensure(l: *Labels, gpa: Allocator, v: *const View) Allocator.Error!void {
        const have = l.reusable(v);
        if (have == v.count) return;
        if (have == 0 or v.count - l.built > l.built / 4) {
            try l.build(gpa, v);
        } else {
            try l.items.resize(gpa, v.count);
            // A new position is newer than every labelled one, so numbering
            // it after them keeps parents below children; it reaches what
            // its parents reach. It never claims a tree descendant.
            for (have..v.count) |k| {
                const x: u32 = @intCast(k);
                var lab: Label = .{ .pre = @splat(x), .post = @splat(x), .low = @splat(x) };
                var ps = v.parents(Pos.of(x));
                while (ps.next()) |p| {
                    const lp = &l.items.items[p.int()];
                    for (&lab.low, lp.low) |*lo, plo| lo.* = @min(lo.*, plo);
                }
                l.items.items[x] = lab;
            }
        }
        l.first = v.segs[0].seg.checksum();
        l.last = v.id(Pos.of(v.count - 1));
    }

    /// Two depth-first walks over parent edges from every head: the first
    /// from the highest head, highest parent first; the second in the
    /// opposite orders.
    fn build(l: *Labels, gpa: Allocator, v: *const View) Allocator.Error!void {
        const n = v.count;
        try l.items.resize(gpa, n);
        // Parent lists, flattened once for both walks.
        const offs = try gpa.alloc(u32, n + 1);
        defer gpa.free(offs);
        var edges: std.ArrayList(u32) = .empty;
        defer edges.deinit(gpa);
        for (0..n) |k| {
            offs[k] = @intCast(edges.items.len);
            var ps = v.parents(Pos.of(@intCast(k)));
            while (ps.next()) |p| try edges.append(gpa, p.int());
        }
        offs[n] = @intCast(edges.items.len);

        const seen = try gpa.alloc(bool, n);
        defer gpa.free(seen);
        // Heads (commits without children), highest level first.
        @memset(seen, false);
        for (edges.items) |p| seen[p] = true;
        var heads: std.ArrayList(u32) = .empty;
        defer heads.deinit(gpa);
        for (0..n) |k| if (!seen[k]) try heads.append(gpa, @intCast(k));
        const ByLevel = struct {
            fn higher(vv: *const View, x1: u32, x2: u32) bool {
                return vv.level(Pos.of(x1)) > vv.level(Pos.of(x2));
            }
        };
        std.mem.sort(u32, heads.items, v, ByLevel.higher);
        // Walk 0 takes the highest parent first, so it runs down the longest
        // lines of history and their commits' subtrees are exact.
        for (0..n) |k| {
            const ps = edges.items[offs[k]..offs[k + 1]];
            if (ps.len > 1) std.mem.sort(u32, ps, v, ByLevel.higher);
        }
        const Frame = struct { x: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        for (0..dims) |d| {
            @memset(seen, false);
            var pre: u32 = 0;
            var post: u32 = 0;
            for (0..heads.items.len) |hi| {
                const k = if (d == 0) heads.items[hi] else heads.items[heads.items.len - 1 - hi];
                seen[k] = true;
                l.items.items[k].pre[d] = pre;
                pre += 1;
                try stack.append(gpa, .{ .x = @intCast(k), .next = 0 });
                while (stack.items.len > 0) {
                    const top = &stack.items[stack.items.len - 1];
                    const x = top.x;
                    const ps = edges.items[offs[x]..offs[x + 1]];
                    if (top.next < ps.len) {
                        const i = top.next;
                        top.next += 1;
                        const p = if (d == 0) ps[i] else ps[ps.len - 1 - i];
                        if (seen[p]) continue;
                        seen[p] = true;
                        l.items.items[p].pre[d] = pre;
                        pre += 1;
                        try stack.append(gpa, .{ .x = p, .next = 0 });
                        continue;
                    }
                    _ = stack.pop();
                    const lab = &l.items.items[x];
                    lab.post[d] = post;
                    var low = post;
                    for (ps) |p| low = @min(low, l.items.items[p].low[d]);
                    lab.low[d] = low;
                    post += 1;
                }
            }
        }
        l.built = n;
    }
};

/// Reusable scratch for ancestry queries: one colour byte per position,
/// cleared through a dirty list so a query costs only what it touches.
pub const Walker = struct {
    gpa: Allocator,
    color: std.ArrayList(u8) = .empty,
    dirty: std.ArrayList(u32) = .empty,
    stack: std.ArrayList(u32) = .empty,
    fwd: std.ArrayList(u32) = .empty,
    queue: Queue = .empty,
    labels: Labels = .{},

    pub fn init(gpa: Allocator) Walker {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Walker) void {
        w.color.deinit(w.gpa);
        w.dirty.deinit(w.gpa);
        w.stack.deinit(w.gpa);
        w.fwd.deinit(w.gpa);
        w.queue.deinit(w.gpa);
        w.labels.deinit(w.gpa);
    }

    /// Drops the reachability labels, for a rebuilt index whose positions
    /// may have changed.
    pub fn invalidate(w: *Walker) void {
        w.labels.clear();
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
        try w.labels.ensure(w.gpa, v);
        const ai = a.int();
        const bi = b.int();
        if (!w.labels.mayReach(bi, ai)) return false;
        if (w.labels.treeReach(bi, ai)) return true;
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
                if (try w.stepBack(v, ai, la, ca)) return true;
            } else if (try w.stepForward(v, bi, lb, cb)) return true;
        }
        return false;
    }

    fn stepBack(w: *Walker, v: *const View, a: u32, la: u32, ca: u64) Allocator.Error!bool {
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
                if (!w.labels.mayReach(pi, a)) continue;
                if (w.labels.treeReach(pi, a)) return true;
                try w.stack.append(w.gpa, pi);
            }
        }
        return false;
    }

    fn stepForward(w: *Walker, v: *const View, b: u32, lb: u32, cb: u64) Allocator.Error!bool {
        {
            const y = w.fwd.pop().?;
            var ks = v.childrenBuilt(Pos.of(y), null);
            while (ks.next()) |k| {
                const ki = k.int();
                const c = w.color.items[ki];
                if (c & p1 != 0) return true;
                if (c != 0) continue;
                if (v.level(k) >= lb or v.correctedTime(k) >= cb) continue;
                if (!w.labels.mayReach(b, ki)) continue;
                if (w.labels.treeReach(b, ki)) return true;
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
