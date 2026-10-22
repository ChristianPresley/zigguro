//! `Repo`: a loaded, immutable repository state at one operation.
//!
//! Loading lists the op heads, drops heads that are ancestors of others,
//! and, when several remain (concurrent writers), merges their views three
//! ways against their common ancestor operation and publishes a merge
//! operation. Only heads are read, so loading does not depend on the
//! length of the op log.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const gc_mod = @import("../store/gc.zig");
const index_mod = @import("../graph/index.zig");
const op_mod = @import("operation.zig");
const view_mod = @import("view.zig");
const op_heads = @import("op_heads.zig");
const merge_views = @import("merge_views.zig");
const tx_mod = @import("transaction.zig");
const ObjectId = id_mod.ObjectId;
const Store = store_mod.Store;
const Operation = op_mod.Operation;
const OpMeta = op_mod.OpMeta;
const View = view_mod.View;
const Allocator = std.mem.Allocator;

/// Which operation to load.
pub const AtOp = union(enum) {
    /// The current heads (merged if several).
    head,
    op: ObjectId,
    /// A hex prefix of an operation ID (searched from the heads).
    op_prefix: []const u8,
};

pub const Options = struct {
    /// When set, heads are kept free of ancestors of other heads after
    /// merges and transactions.
    index: ?*index_mod.CommitIndex = null,
};

pub const Repo = struct {
    gpa: Allocator,
    io: std.Io,
    store: *Store,
    /// The repository directory (holding `op_heads/` and `detached/`).
    repo_dir: std.Io.Dir,
    heads_dir: std.Io.Dir,
    opts: Options,
    arena_state: std.heap.ArenaAllocator,
    op_id: ObjectId,
    operation: Operation,
    view_id: ObjectId,
    view_data: View,
    /// Loaded at a given operation (`--at-op`): transactions are refused.
    read_only: bool,

    /// Creates the op log in `repo_dir` (an `op_heads` directory) with a
    /// root operation whose view is empty.
    pub fn init(gpa: Allocator, io: std.Io, repo_dir: std.Io.Dir, store: *Store, opts: Options, meta: OpMeta) !*Repo {
        const dir = try repo_dir.createDirPathOpen(io, "op_heads", .{ .open_options = .{ .iterate = true } });
        defer dir.close(io);
        const existing = try op_heads.list(gpa, io, dir);
        defer gpa.free(existing);
        if (existing.len != 0) return error.AlreadyInitialized;
        var batch = store.batch();
        defer batch.abort();
        const view_bytes = try enc.encodeAlloc(gpa, View, View.empty);
        defer gpa.free(view_bytes);
        const view_id = try batch.put(.view, view_bytes);
        const op_bytes = try enc.encodeAlloc(gpa, Operation, .{ .parents = &.{}, .view = view_id, .meta = meta });
        defer gpa.free(op_bytes);
        const op_id = try batch.put(.operation, op_bytes);
        try batch.commit();
        try op_heads.add(io, dir, op_id);
        return fromOp(gpa, io, store, repo_dir, opts, op_id, false);
    }

    /// Loads the repository in `repo_dir`.
    pub fn load(gpa: Allocator, io: std.Io, repo_dir: std.Io.Dir, store: *Store, opts: Options, at: AtOp) !*Repo {
        const dir = repo_dir.openDir(io, "op_heads", .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return error.NotInitialized,
            else => return e,
        };
        defer dir.close(io);
        const id = switch (at) {
            .op => |id| return fromOp(gpa, io, store, repo_dir, opts, id, true),
            .op_prefix => |p| return fromOp(gpa, io, store, repo_dir, opts, try resolveOpPrefix(gpa, io, store, dir, p), true),
            .head => blk: {
                const heads = try op_heads.list(gpa, io, dir);
                defer gpa.free(heads);
                if (heads.len == 0) return error.NoOpHeads;
                if (heads.len == 1) break :blk heads[0];
                break :blk try mergeHeads(gpa, io, store, dir, opts, heads);
            },
        };
        return fromOp(gpa, io, store, repo_dir, opts, id, false);
    }

    /// Builds a repo at `op_id`. `repo_dir` is borrowed: the repo opens
    /// its own handles.
    pub fn fromOp(gpa: Allocator, io: std.Io, store: *Store, repo_dir: std.Io.Dir, opts: Options, op_id: ObjectId, read_only: bool) !*Repo {
        const own_dir = try repo_dir.openDir(io, ".", .{ .iterate = true });
        errdefer own_dir.close(io);
        const heads_dir = try repo_dir.openDir(io, "op_heads", .{ .iterate = true });
        errdefer heads_dir.close(io);
        const r = try gpa.create(Repo);
        errdefer gpa.destroy(r);
        r.* = .{
            .gpa = gpa,
            .io = io,
            .store = store,
            .repo_dir = own_dir,
            .heads_dir = heads_dir,
            .opts = opts,
            .arena_state = .init(gpa),
            .op_id = op_id,
            .operation = undefined,
            .view_id = undefined,
            .view_data = undefined,
            .read_only = read_only,
        };
        errdefer r.arena_state.deinit();
        const arena = r.arena_state.allocator();
        r.operation = try op_mod.read(Operation, store, arena, op_id);
        r.view_id = r.operation.view;
        r.view_data = try op_mod.read(View, store, arena, r.view_id);
        return r;
    }

    pub fn close(r: *Repo) void {
        r.arena_state.deinit();
        r.heads_dir.close(r.io);
        r.repo_dir.close(r.io);
        r.gpa.destroy(r);
    }

    pub fn view(r: *const Repo) *const View {
        return &r.view_data;
    }

    pub fn op(r: *const Repo) ObjectId {
        return r.op_id;
    }

    /// Starts a transaction on top of this operation.
    pub fn startTransaction(r: *Repo, meta: OpMeta) !*tx_mod.Transaction {
        if (r.read_only) return error.ReadOnly;
        return tx_mod.Transaction.begin(r, meta);
    }

    /// The same repository at another operation (after a commit).
    pub fn reopen(r: *const Repo, op_id: ObjectId, read_only: bool) !*Repo {
        return fromOp(r.gpa, r.io, r.store, r.repo_dir, r.opts, op_id, read_only);
    }

    /// GC roots: the current op heads and the detached (preview)
    /// operations. With `op_mod.gcEdges` as extra edges, everything the op
    /// log references stays alive.
    pub fn gcRoots(r: *Repo) gc_mod.RootProvider {
        return .{ .ctx = r, .forEachRoot = struct {
            fn each(ctx: *anyopaque, sink: *gc_mod.RootSink) anyerror!void {
                const self: *Repo = @ptrCast(@alignCast(ctx));
                const heads = try op_heads.list(self.gpa, self.io, self.heads_dir);
                defer self.gpa.free(heads);
                for (heads) |h| try sink.add(h);
                const detached = try listMarkers(self.gpa, self.io, self.repo_dir);
                defer self.gpa.free(detached);
                for (detached) |d| try sink.add(d);
            }
        }.each };
    }
};

/// Parents and end times of operations, read on demand.
pub const OpGraph = struct {
    gpa: Allocator,
    store: *Store,
    arena_state: std.heap.ArenaAllocator,
    nodes: std.AutoHashMapUnmanaged(ObjectId, Node) = .empty,
    /// Merged views of op sets already computed (keyed by a hash of the
    /// sorted set), so criss-cross histories do not recompute shared
    /// virtual bases.
    merged: std.AutoHashMapUnmanaged(ObjectId, View) = .empty,

    /// Virtual bases nested deeper than this use the newest best common
    /// ancestor alone (which may report a conflict a deeper merge would
    /// resolve).
    pub const max_virtual_depth = 64;

    pub const Node = struct { parents: []const ObjectId, end_ms: i64, view: ObjectId };

    pub fn init(gpa: Allocator, store: *Store) OpGraph {
        return .{ .gpa = gpa, .store = store, .arena_state = .init(gpa) };
    }

    pub fn deinit(g: *OpGraph) void {
        g.nodes.deinit(g.gpa);
        g.merged.deinit(g.gpa);
        g.arena_state.deinit();
    }

    pub fn get(g: *OpGraph, id: ObjectId) !Node {
        if (g.nodes.get(id)) |n| return n;
        const o = try op_mod.read(Operation, g.store, g.arena_state.allocator(), id);
        const n: Node = .{ .parents = o.parents, .end_ms = o.meta.end_ms, .view = o.view };
        try g.nodes.put(g.gpa, id, n);
        return n;
    }

    /// Whether `a` is an ancestor of `b` (or `b` itself). Walks back from
    /// `b`, pruning operations that ended before `a`.
    pub fn isAncestor(g: *OpGraph, a: ObjectId, b: ObjectId) !bool {
        if (a.eql(b)) return true;
        const a_end = (try g.get(a)).end_ms;
        var seen: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
        defer seen.deinit(g.gpa);
        var stack: std.ArrayList(ObjectId) = .empty;
        defer stack.deinit(g.gpa);
        try stack.append(g.gpa, b);
        while (stack.pop()) |x| {
            for ((try g.get(x)).parents) |p| {
                if (p.eql(a)) return true;
                if ((try seen.getOrPut(g.gpa, p)).found_existing) continue;
                if ((try g.get(p)).end_ms < a_end) continue;
                try stack.append(g.gpa, p);
            }
        }
        return false;
    }

    /// The best common ancestors of (anything in) `a` and `b`: common
    /// ancestors that are not ancestors of other common ancestors, newest
    /// first (paint-down by end time, as git's merge-base). Allocated in
    /// `arena`.
    pub fn mergeBases(g: *OpGraph, arena: Allocator, a: []const ObjectId, b: ObjectId) ![]ObjectId {
        const left: u3 = 1;
        const right: u3 = 2;
        const stale: u3 = 4;
        const Item = struct { end: i64, id: ObjectId, live: bool };
        const Q = std.PriorityQueue(Item, void, struct {
            fn cmp(_: void, x: Item, y: Item) std.math.Order {
                if (x.end != y.end) return std.math.order(y.end, x.end);
                return y.id.order(x.id);
            }
        }.cmp);
        var q: Q = .empty;
        defer q.deinit(g.gpa);
        var color: std.AutoHashMapUnmanaged(ObjectId, u3) = .empty;
        defer color.deinit(g.gpa);
        // Queue entries pushed while not stale; the walk ends when none
        // remain.
        var live: usize = 0;
        const Ctx = struct {
            g: *OpGraph,
            q: *Q,
            color: *std.AutoHashMapUnmanaged(ObjectId, u3),
            live: *usize,
            fn paint(c: @This(), id: ObjectId, bits: u3) !void {
                const gop = try c.color.getOrPut(c.g.gpa, id);
                const old: u3 = if (gop.found_existing) gop.value_ptr.* else 0;
                if (old | bits == old) return;
                gop.value_ptr.* = old | bits;
                const is_live = (old | bits) & stale == 0;
                if (is_live) c.live.* += 1;
                try c.q.push(c.g.gpa, .{ .end = (try c.g.get(id)).end_ms, .id = id, .live = is_live });
            }
        };
        const ctx: Ctx = .{ .g = g, .q = &q, .color = &color, .live = &live };
        for (a) |x| try ctx.paint(x, left);
        try ctx.paint(b, right);
        var out: std.ArrayList(ObjectId) = .empty;
        while (live > 0) {
            const it = q.pop() orelse break;
            var c = color.get(it.id).?;
            if (it.live) live -= 1;
            if (c & (left | right) == left | right and c & stale == 0) {
                try out.append(arena, it.id);
                c |= stale;
                color.putAssumeCapacity(it.id, c);
            }
            for ((try g.get(it.id)).parents) |p| try ctx.paint(p, c);
        }
        // Drop results that are ancestors of other results.
        var keep: std.ArrayList(ObjectId) = .empty;
        for (out.items, 0..) |x, i| {
            const redundant = for (out.items, 0..) |y, j| {
                if (i != j and try g.isAncestor(x, y)) break true;
            } else false;
            if (!redundant) try keep.append(arena, x);
        }
        return keep.items;
    }

    /// The merged view of `ops` (sorted by end time). Where two sides have
    /// several best common ancestors, their merged view is the base
    /// (recursively, as git's recursive merge). Views are allocated in
    /// `arena` and memoized: use one arena per graph.
    pub fn mergedView(g: *OpGraph, arena: Allocator, ops: []const ObjectId) !View {
        return g.mergedViewDepth(arena, ops, 0);
    }

    fn mergedViewDepth(g: *OpGraph, arena: Allocator, ops: []const ObjectId, depth: u32) !View {
        var h = id_mod.Hasher.init(.operation, ops.len * 32);
        for (ops) |o| h.update(&o.bytes);
        const key = h.final();
        if (g.merged.get(key)) |v| return v;
        var acc = try op_mod.read(View, g.store, arena, (try g.get(ops[0])).view);
        for (ops[1..], 1..) |o, k| {
            const bases = try g.mergeBases(arena, ops[0..k], o);
            if (bases.len == 0) return error.UnrelatedOperations;
            g.sortByEnd(bases);
            const base = if (bases.len == 1 or depth >= max_virtual_depth)
                try op_mod.read(View, g.store, arena, (try g.get(bases[bases.len - 1])).view)
            else
                try g.mergedViewDepth(arena, bases, depth + 1);
            const right = try op_mod.read(View, g.store, arena, (try g.get(o)).view);
            acc = try merge_views.mergeViews(g.gpa, arena, base, acc, right);
        }
        try g.merged.put(g.gpa, key, acc);
        return acc;
    }

    /// Sorts oldest first by end time, then ID.
    pub fn sortByEnd(g: *OpGraph, ops: []ObjectId) void {
        std.mem.sort(ObjectId, ops, g, struct {
            fn lt(gg: *OpGraph, x: ObjectId, y: ObjectId) bool {
                const ex = (gg.get(x) catch return false).end_ms;
                const ey = (gg.get(y) catch return false).end_ms;
                return if (ex != ey) ex < ey else ObjectId.lessThan({}, x, y);
            }
        }.lt);
    }
};

pub fn now(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// Merges several op heads into one operation and publishes it.
fn mergeHeads(gpa: Allocator, io: std.Io, store: *Store, dir: std.Io.Dir, opts: Options, all: []const ObjectId) !ObjectId {
    var g: OpGraph = .init(gpa, store);
    defer g.deinit();
    // Drop heads that are ancestors of other heads (stale head files).
    var heads: std.ArrayList(ObjectId) = .empty;
    defer heads.deinit(gpa);
    for (all, 0..) |h, i| {
        const stale = for (all, 0..) |o, j| {
            if (i != j and try g.isAncestor(h, o)) break true;
        } else false;
        if (!stale) try heads.append(gpa, h);
    }
    if (heads.items.len == 1) {
        for (all) |h| if (!h.eql(heads.items[0])) op_heads.remove(io, dir, h);
        return heads.items[0];
    }
    // Merge in end-time order so the newest operation's side wins ties.
    // Heads were read already, so sorting cannot fail on a read.
    g.sortByEnd(heads.items);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var acc = try g.mergedView(arena, heads.items);
    if (opts.index) |ix| acc = try normalizeHeads(arena, ix, acc);

    // The merge operation depends only on the heads, so loaders merging
    // the same heads at once write the same operation instead of
    // criss-crossing merges. Its end time is the newest head's: end times
    // never go backwards along the op graph (walks prune by them).
    var t: i64 = 0;
    for (heads.items) |h| t = @max(t, (try g.get(h)).end_ms);
    const meta: OpMeta = .{
        .start_ms = t,
        .end_ms = t,
        .description = "merge concurrent operations",
        .user = "",
        .host = "",
        .workspace = "",
        .actor = op_mod.Actor.systemTask("op_merge"),
        .tags = &.{},
    };
    var batch = store.batch();
    defer batch.abort();
    const view_bytes = try enc.encodeAlloc(gpa, View, acc);
    defer gpa.free(view_bytes);
    const view_id = try batch.put(.view, view_bytes);
    const op_bytes = try enc.encodeAlloc(gpa, Operation, .{ .parents = heads.items, .view = view_id, .meta = meta });
    defer gpa.free(op_bytes);
    const op_id = try batch.put(.operation, op_bytes);
    try batch.commit();
    try op_heads.publish(io, dir, op_id, all);
    return op_id;
}

/// Drops heads that are ancestors of other heads (they are still visible,
/// through their descendants).
pub fn normalizeHeads(arena: Allocator, ix: *index_mod.CommitIndex, v: View) !View {
    if (v.heads.len < 2) return v;
    try ix.ensureIndexed(v.heads);
    var keep: std.ArrayList(ObjectId) = .empty;
    for (v.heads, 0..) |h, i| {
        const hp = ix.pos(h) orelse {
            try keep.append(arena, h);
            continue;
        };
        const hidden = for (v.heads, 0..) |o, j| {
            if (i == j) continue;
            const op = ix.pos(o) orelse continue;
            if (try ix.isAncestor(hp, op)) break true;
        } else false;
        if (!hidden) try keep.append(arena, h);
    }
    var out = v;
    out.heads = keep.items;
    return out;
}

/// The directory under the repo directory holding one empty marker file
/// per detached (preview) operation, named by its hex ID.
pub const detached_dir_name = "detached";

/// The detached operation IDs, sorted (none when the directory is
/// missing).
pub fn listMarkers(gpa: Allocator, io: std.Io, repo_dir: std.Io.Dir) ![]ObjectId {
    var dir = repo_dir.openDir(io, detached_dir_name, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return gpa.alloc(ObjectId, 0),
        else => return e,
    };
    defer dir.close(io);
    return op_heads.list(gpa, io, dir);
}

/// Finds the operation whose hex ID starts with `prefix`, searching back
/// from the op heads.
fn resolveOpPrefix(gpa: Allocator, io: std.Io, store: *Store, dir: std.Io.Dir, prefix: []const u8) !ObjectId {
    if (prefix.len == 0 or prefix.len > 64) return error.InvalidOpId;
    for (prefix) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidOpId;
    var g: OpGraph = .init(gpa, store);
    defer g.deinit();
    const heads = try op_heads.list(gpa, io, dir);
    defer gpa.free(heads);
    var seen: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
    defer seen.deinit(gpa);
    var stack: std.ArrayList(ObjectId) = .empty;
    defer stack.deinit(gpa);
    try stack.appendSlice(gpa, heads);
    var found: ?ObjectId = null;
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(gpa, x)).found_existing) continue;
        var hex: [64]u8 = undefined;
        if (std.mem.startsWith(u8, x.hex(&hex), prefix)) {
            if (found != null) return error.AmbiguousOpId;
            found = x;
        }
        try stack.appendSlice(gpa, (try g.get(x)).parents);
    }
    return found orelse error.OpNotFound;
}
