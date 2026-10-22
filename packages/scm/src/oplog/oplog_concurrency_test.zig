//! Concurrency tests for the op log: real threads (some sharing a store,
//! some with their own, as separate processes would) and seeded random
//! interleavings of writers that each hold a stale repo. Every committed
//! operation must stay reachable from the final head, and every writer's
//! last bookmark move must survive the merges.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const store_mod = @import("../store/store.zig");
const compaction = @import("../store/compaction.zig");
const repo_mod = @import("repo.zig");
const view_mod = @import("view.zig");
const fx = @import("test_fixture.zig");
const ObjectId = id_mod.ObjectId;
const Store = store_mod.Store;
const Repo = repo_mod.Repo;
const Allocator = std.mem.Allocator;

/// One writer's step: a new change on top of its bookmark, which moves.
fn step(r: *Repo, writer: usize, n: usize, last: *?ObjectId) !*Repo {
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "w{d}", .{writer});
    var desc_buf: [32]u8 = undefined;
    const desc = try std.fmt.bufPrint(&desc_buf, "w{d}-{d}", .{ writer, n });
    const tx = try r.startTransaction(fx.meta(desc));
    errdefer tx.discard();
    const m = tx.mutRepo();
    const prev = r.view().bookmark(name).asNormal();
    const parents: []const ObjectId = if (prev) |p| &.{p} else &.{};
    const c = try fx.change(m, parents, desc);
    var t: ?ObjectId = c;
    try m.setBookmark(name, fx.target(&t));
    last.* = c;
    return tx.commit();
}

/// Checks that every op in `ops` is an ancestor of `head` and that each
/// writer's bookmark points at its last change.
fn checkFinal(gpa: Allocator, f: *fx.Fixture, ops: []const ObjectId, last: []const ?ObjectId) !void {
    const t = std.testing;
    const r = try f.load(.head);
    defer r.close();
    const heads = try @import("op_heads.zig").list(gpa, f.io, r.heads_dir);
    defer gpa.free(heads);
    try t.expectEqualSlices(ObjectId, &.{r.op()}, heads);
    var g: repo_mod.OpGraph = .init(gpa, f.store);
    defer g.deinit();
    for (ops) |op| try t.expect(try g.isAncestor(op, r.op()));
    for (last, 0..) |want, w| {
        var buf: [16]u8 = undefined;
        const got = r.view().bookmark(try std.fmt.bufPrint(&buf, "w{d}", .{w}));
        try t.expect(!got.isConflicted());
        try t.expect(view_mod.optEql(want, got.asNormal()));
        if (want) |c| try t.expect(r.view().hasHead(c));
    }
}

test "oplog: random interleavings of 4 writers x 200 ops" {
    const gpa = std.testing.allocator;
    // One full-size run, plus smaller runs on other seeds.
    for ([_][2]u64{ .{ 1, 200 }, .{ 2, 50 }, .{ 3, 50 } }) |run| {
        const seed = run[0];
        const per = run[1];
        var f = try fx.Fixture.init(gpa);
        defer f.deinit();
        const root = try f.initRepo();
        root.close();
        var prng: std.Random.DefaultPrng = .init(seed);
        const rng = prng.random();
        const writers = 4;
        var repos: [writers]*Repo = undefined;
        for (&repos) |*r| r.* = try f.load(.head);
        defer for (repos) |r| r.close();
        var done = [_]usize{0} ** writers;
        var last = [_]?ObjectId{null} ** writers;
        var ops: std.ArrayList(ObjectId) = .empty;
        defer ops.deinit(gpa);
        while (true) {
            var open: [writers]usize = undefined;
            var n: usize = 0;
            for (done, 0..) |d, w| if (d < per) {
                open[n] = w;
                n += 1;
            };
            if (n == 0) break;
            const w = open[rng.uintLessThan(usize, n)];
            // Sometimes catch up with the others first (merging their
            // heads); otherwise commit on a stale repo.
            if (rng.uintLessThan(u8, 4) == 0) {
                repos[w].close();
                repos[w] = try f.load(.head);
            }
            const next = try step(repos[w], w, done[w], &last[w]);
            repos[w].close();
            repos[w] = next;
            try ops.append(gpa, next.op());
            done[w] += 1;
            // Keep the segment count logarithmic, as a running repo would.
            if (ops.items.len % 64 == 0) _ = try compaction.compact(f.store, .{ .deflate = false });
        }
        try checkFinal(gpa, &f, ops.items, &last);
    }
}

const Shared = struct {
    gpa: Allocator,
    f: *fx.Fixture,
    store: *Store,
    writer: usize,
    per: usize,
    ops: []ObjectId,
    last: *?ObjectId,
    failed: *std.atomic.Value(bool),

    fn run(s: Shared) void {
        s.body() catch |e| {
            std.debug.print("writer {d}: {t}\n", .{ s.writer, e });
            s.failed.store(true, .monotonic);
        };
    }

    fn body(s: Shared) !void {
        var r = try Repo.load(s.gpa, s.f.io, s.f.tmp.dir, s.store, .{}, .head);
        defer r.close();
        for (0..s.per) |n| {
            // Reload every few ops so writers see (and merge) each other.
            if (n % 3 == 0) {
                const fresh = try Repo.load(s.gpa, s.f.io, s.f.tmp.dir, s.store, .{}, .head);
                r.close();
                r = fresh;
            }
            const next = try step(r, s.writer, n, s.last);
            r.close();
            r = next;
            s.ops[n] = next.op();
        }
    }
};

test "oplog: concurrent writers on threads and separate stores" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    const root = try f.initRepo();
    root.close();
    const writers = 4;
    const per = 50;
    const ops = try gpa.alloc(ObjectId, writers * per);
    defer gpa.free(ops);
    var last = [_]?ObjectId{null} ** writers;
    // Writers 0 and 2 share the fixture's store; 1 and 3 open their own.
    var stores: [writers]*Store = undefined;
    for (&stores, 0..) |*s, w| s.* = if (w % 2 == 0) f.store else try Store.open(gpa, f.io, f.tmp.dir, fx.store_options);
    defer for (stores, 0..) |s, w| if (w % 2 == 1) s.close();
    var failed: std.atomic.Value(bool) = .init(false);
    var g: std.Io.Group = .init;
    for (0..writers) |w| {
        try g.concurrent(f.io, Shared.run, .{Shared{
            .gpa = gpa,
            .f = &f,
            .store = stores[w],
            .writer = w,
            .per = per,
            .ops = ops[w * per ..][0..per],
            .last = &last[w],
            .failed = &failed,
        }});
    }
    try g.await(f.io);
    try t.expect(!failed.load(.monotonic));
    try f.store.rescan();
    try checkFinal(gpa, &f, ops, &last);
}

test "oplog: no lock files" {
    // The op log must stay lock-free: no lock files in the sources.
    const t = std.testing;
    inline for (.{ "operation.zig", "view.zig", "op_heads.zig", "transaction.zig", "mutable_repo.zig", "merge_views.zig", "repo.zig", "undo.zig" }) |name| {
        const src = @embedFile(name);
        try t.expect(std.mem.indexOf(u8, src, ".lock\"") == null);
        try t.expect(std.mem.indexOf(u8, src, "lockFile") == null);
    }
}
