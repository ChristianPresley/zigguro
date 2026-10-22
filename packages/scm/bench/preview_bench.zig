//! E09.F03.S02.T02 preview benchmarks on a view with 1k bookmarks:
//! committing a detached operation, adopting it with nothing in between
//! (fast path, budget 2 ms), and adopting it after another operation
//! (three-way view merge, budget 10 ms). The harness times whole calls, so
//! the adopt benchmarks include writing the preview; subtract
//! `oplog.preview` for the adopt alone.

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const State = bench.State;

const names = [_][]const u8{ "oplog.preview", "oplog.adopt_fast", "oplog.adopt_merged_1k" };

fn wanted(b: *bench.Bench, name: []const u8) bool {
    const f = b.opts.filter orelse return true;
    return std.mem.indexOf(u8, name, f) != null;
}

const n_bookmarks = 1000;
const bench_dir = ".zig-cache/scm-preview-bench";

fn meta(description: []const u8) scm.OpMeta {
    return .{ .start_ms = 0, .end_ms = 0, .description = description, .user = "bench", .host = "host", .workspace = "default", .actor = .human, .tags = &.{} };
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

    const r0 = try scm.Repo.init(gpa, io, root, store, .{}, meta("init"));
    const tx = try r0.startTransaction(meta("bookmarks"));
    var prng: std.Random.DefaultPrng = .init(5);
    for (0..n_bookmarks) |i| {
        var name_buf: [32]u8 = undefined;
        var id: ?scm.ObjectId = undefined;
        prng.random().bytes(&id.?.bytes);
        try tx.mutRepo().setBookmark(try std.fmt.bufPrint(&name_buf, "bookmark-{d:0>4}", .{i}), .normal(&id));
    }
    const r1 = try tx.commit();
    r0.close();
    r1.close();

    const ctx: Ctx = .{ .root = root, .store = store };
    try b.run("oplog.preview: commit a detached operation moving one of 1k bookmarks", ctx, previewOnly);
    try b.run("oplog.adopt_fast: preview, then adopt with no operation in between", ctx, adoptFast);
    try b.run("oplog.adopt_merged_1k: preview, then adopt after another operation (1k bookmarks)", ctx, adoptMerged);
}

const Ctx = struct { root: std.Io.Dir, store: *scm.Store };

fn previewMove(r: *scm.Repo, prng: *std.Random.DefaultPrng, k: u64) !scm.DetachedOp {
    var name_buf: [32]u8 = undefined;
    var id: ?scm.ObjectId = undefined;
    prng.random().bytes(&id.?.bytes);
    const tx = try r.startTransaction(meta("preview"));
    errdefer tx.discard();
    try tx.mutRepo().setBookmark(try std.fmt.bufPrint(&name_buf, "bookmark-{d:0>4}", .{k % n_bookmarks}), .normal(&id));
    return scm.preview.commitDetached(tx, .proposal);
}

fn previewOnly(c: Ctx, s: *State) void {
    const gpa = s.allocator();
    const r = scm.Repo.load(gpa, s.ioHandle(), c.root, c.store, .{}, .head) catch unreachable;
    defer r.close();
    var prng: std.Random.DefaultPrng = .init(9);
    for (0..s.iterations()) |k| {
        const d = previewMove(r, &prng, k) catch unreachable;
        scm.preview.discard(r, d.op);
    }
}

fn adoptFast(c: Ctx, s: *State) void {
    const gpa = s.allocator();
    var r = scm.Repo.load(gpa, s.ioHandle(), c.root, c.store, .{}, .head) catch unreachable;
    defer r.close();
    var prng: std.Random.DefaultPrng = .init(10);
    for (0..s.iterations()) |k| {
        const d = previewMove(r, &prng, k) catch unreachable;
        const res = scm.adopt.adopt(r, d, meta("adopt")) catch unreachable;
        const next = r.reopen(res.adopted, false) catch unreachable;
        r.close();
        r = next;
    }
}

/// Each preview is made on the operation before the current one, which
/// moved a different bookmark, so every adopt takes the merge path.
fn adoptMerged(c: Ctx, s: *State) void {
    const gpa = s.allocator();
    var prev = scm.Repo.load(gpa, s.ioHandle(), c.root, c.store, .{}, .head) catch unreachable;
    defer prev.close();
    var prng: std.Random.DefaultPrng = .init(11);
    var cur = blk: {
        const d = previewMove(prev, &prng, 0) catch unreachable;
        const res = scm.adopt.adopt(prev, d, meta("adopt")) catch unreachable;
        break :blk prev.reopen(res.adopted, false) catch unreachable;
    };
    defer cur.close();
    for (0..s.iterations()) |k| {
        const d = previewMove(prev, &prng, k + 1) catch unreachable;
        var res = scm.adopt.adopt(cur, d, meta("adopt")) catch unreachable;
        const id = switch (res) {
            .adopted => |id| id,
            .conflicted => |*cf| {
                cf.deinit();
                unreachable;
            },
        };
        const next = cur.reopen(id, false) catch unreachable;
        prev.close();
        prev = cur;
        cur = next;
    }
}
