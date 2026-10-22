//! E09.F03.S02 op log benchmarks over a synthetic 100k-operation history:
//! loading the repo at the head and committing one operation. Both have a
//! 10 ms budget.

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const State = bench.State;

const names = [_][]const u8{ "oplog.load_100k", "oplog.commit" };

fn wanted(b: *bench.Bench, name: []const u8) bool {
    const f = b.opts.filter orelse return true;
    return std.mem.indexOf(u8, name, f) != null;
}

const n_ops = 100_000;
const n_bookmarks = 100;
const bench_dir = ".zig-cache/scm-oplog-bench";

fn meta(description: []const u8, t: i64) scm.OpMeta {
    return .{ .start_ms = t, .end_ms = t, .description = description, .user = "bench", .host = "host", .workspace = "default", .actor = .human, .tags = &.{} };
}

pub fn register(b: *bench.Bench) !void {
    for (names) |n| {
        if (wanted(b, n)) break;
    } else return;
    const gpa = b.gpa;
    const io = b.io;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, bench_dir) catch {};
    defer cwd.deleteTree(io, bench_dir) catch {};
    var root = try cwd.createDirPathOpen(io, bench_dir, .{});
    defer root.close(io);
    const store = try scm.Store.open(gpa, io, root, .{});
    defer store.close();

    // A linear history: each operation moves one of 100 bookmarks.
    const r0 = try scm.Repo.init(gpa, io, root, store, .{}, meta("init", 1));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(3);
    const r = prng.random();
    var targets: [n_bookmarks]?scm.ObjectId = undefined;
    for (&targets) |*t| {
        var id: scm.ObjectId = undefined;
        r.bytes(&id.bytes);
        t.* = id;
    }
    var named: [n_bookmarks]scm.view.NamedRef = undefined;
    for (&named, 0..) |*n, i| n.* = .{ .name = try std.fmt.allocPrint(arena, "bookmark-{d:0>3}", .{i}), .target = .normal(&targets[i]) };
    var heads = [1]scm.ObjectId{targets[0].?};
    var batch = store.batch();
    var parent = r0.op();
    r0.close();
    for (0..n_ops) |k| {
        const slot = k % n_bookmarks;
        var id: scm.ObjectId = undefined;
        r.bytes(&id.bytes);
        targets[slot] = id;
        heads[0] = id;
        var v = scm.View.empty;
        v.heads = &heads;
        v.bookmarks = &named;
        const vb = try scm.encode.encodeAlloc(gpa, scm.View, v);
        defer gpa.free(vb);
        const view_id = try batch.put(.view, vb);
        const ob = try scm.encode.encodeAlloc(gpa, scm.Operation, .{ .parents = &.{parent}, .view = view_id, .meta = meta("move", @intCast(k + 2)) });
        defer gpa.free(ob);
        parent = try batch.put(.operation, ob);
    }
    try batch.commit();
    var heads_dir = try root.openDir(io, "op_heads", .{ .iterate = true });
    defer heads_dir.close(io);
    try scm.op_heads.publish(io, heads_dir, parent, &.{});
    {
        const r1 = try scm.Repo.load(gpa, io, root, store, .{}, .head);
        defer r1.close();
        const old = try scm.op_heads.list(gpa, io, heads_dir);
        defer gpa.free(old);
        for (old) |h| if (!h.eql(parent)) scm.op_heads.remove(io, heads_dir, h);
    }

    const ctx: Ctx = .{ .root = root, .store = store };
    try b.run("oplog.load_100k: load the repo at the head of a 100k-operation log", ctx, loadHead);
    try b.run("oplog.commit: commit one bookmark move (durable)", ctx, commitOne);
}

const Ctx = struct { root: std.Io.Dir, store: *scm.Store };

fn loadHead(c: Ctx, s: *State) void {
    for (0..s.iterations()) |_| {
        const r = scm.Repo.load(s.allocator(), s.ioHandle(), c.root, c.store, .{}, .head) catch unreachable;
        bench.doNotOptimizeAway(r.view().bookmarks.len);
        r.close();
    }
}

fn commitOne(c: Ctx, s: *State) void {
    const gpa = s.allocator();
    var r = scm.Repo.load(gpa, s.ioHandle(), c.root, c.store, .{}, .head) catch unreachable;
    defer r.close();
    var prng: std.Random.DefaultPrng = .init(9);
    for (0..s.iterations()) |_| {
        const tx = r.startTransaction(meta("bench", 0)) catch unreachable;
        var id: ?scm.ObjectId = undefined;
        prng.random().bytes(&id.?.bytes);
        tx.mutRepo().setBookmark("bookmark-000", .normal(&id)) catch unreachable;
        const next = tx.commit() catch unreachable;
        r.close();
        r = next;
    }
}
