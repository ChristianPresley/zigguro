//! E09.F02 commit index benchmarks over a synthetic 1M-commit history.
//! `graph.rebuild_1M` and `graph.is_ancestor_p99` time single operations
//! (a rebuild is seconds long; the p99 is over individual queries), so
//! they print their numbers instead of going through the harness.

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const gen_dag = @import("gen_dag.zig");
const bench = zg_core.bench;
const State = bench.State;

const names = [_][]const u8{
    "graph.index_open_1M",
    "graph.entry",
    "graph.pos",
    "graph.is_ancestor_p99",
    "graph.merge_bases",
    "graph.rebuild_1M",
    "graph.ancestors_1000",
};

fn wanted(b: *bench.Bench, name: []const u8) bool {
    const f = b.opts.filter orelse return true;
    return std.mem.indexOf(u8, name, f) != null;
}

const n_commits = 1_000_000;
const bench_dir = ".zig-cache/scm-graph-bench";

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
    const store = try scm.Store.open(gpa, io, root, .{ .fsync = false });
    defer store.close();
    var ix_dir = try root.createDirPathOpen(io, "index", .{ .open_options = .{ .iterate = true } });
    defer ix_dir.close(io);

    var t0 = now(io);
    const ids = try gen_dag.generate(gpa, store, n_commits, 1);
    defer gpa.free(ids);
    std.debug.print("graph: generated {d} commits in {d} ms\n", .{ n_commits, (now(io) - t0) / std.time.ns_per_ms });

    const ix = try scm.CommitIndex.open(gpa, io, ix_dir, store, .{ .fsync = false });
    defer ix.close();
    if (wanted(b, "graph.rebuild_1M")) {
        var best: u64 = std.math.maxInt(u64);
        for (0..3) |_| {
            t0 = now(io);
            try ix.rebuild();
            best = @min(best, now(io) - t0);
        }
        std.debug.print("graph.rebuild_1M: rebuild the index from 1M changes: best of 3 = {d} ms\n", .{best / std.time.ns_per_ms});
    } else try ix.rebuild();
    // A second segment on top, as after normal use.
    try ix.ensureIndexed(ids[ids.len - 1 ..]);

    try b.run("graph.index_open_1M: open a 1M-commit index", OpenCtx{ .dir = ix_dir, .store = store }, openIndex);
    const ctx: Ctx = .{ .ix = ix, .ids = ids };
    try b.run("graph.entry: read one entry", ctx, entryHot);
    try b.run("graph.pos: id -> position lookup", ctx, posHot);
    try b.run("graph.merge_bases: merge bases of nearby commits", ctx, mergeBasesNear);
    try b.run("graph.ancestors_1000: stream 1000 ancestors", ctx, ancestors1000);
    if (wanted(b, "graph.is_ancestor_p99")) try isAncestorP99(gpa, io, ix);
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

const OpenCtx = struct { dir: std.Io.Dir, store: *scm.Store };
const Ctx = struct { ix: *scm.CommitIndex, ids: []const scm.ObjectId };

fn openIndex(c: OpenCtx, s: *State) void {
    for (0..s.iterations()) |_| {
        const ix = scm.CommitIndex.open(s.allocator(), s.ioHandle(), c.dir, c.store, .{}) catch unreachable;
        bench.doNotOptimizeAway(ix.count());
        ix.close();
    }
}

fn entryHot(c: Ctx, s: *State) void {
    const n = c.ix.count();
    for (0..s.iterations()) |i| {
        const e = c.ix.entry(scm.Pos.of(@intCast((i * 7919) % n)));
        bench.doNotOptimizeAway(e.corrected_time);
    }
}

fn posHot(c: Ctx, s: *State) void {
    for (0..s.iterations()) |i| bench.doNotOptimizeAway(c.ix.pos(c.ids[(i * 7919) % c.ids.len]));
}

fn mergeBasesNear(c: Ctx, s: *State) void {
    const n = c.ix.count();
    for (0..s.iterations()) |i| {
        const a: u32 = @intCast(1000 + (i * 7919) % (n - 1000));
        const bases = c.ix.mergeBases(s.allocator(), scm.Pos.of(a), scm.Pos.of(a - 1 - @as(u32, @intCast(i % 200)))) catch unreachable;
        bench.doNotOptimizeAway(bases.len);
        s.allocator().free(bases);
    }
}

fn ancestors1000(c: Ctx, s: *State) void {
    const v = c.ix.acquire();
    defer v.release();
    for (0..s.iterations()) |i| {
        const start = scm.Pos.of(@intCast(c.ix.count() - 1 - (i % 1000)));
        var it = scm.ancestry.walkAncestors(s.allocator(), v, &.{start}, .{ .limit = 1000 }) catch unreachable;
        defer it.deinit();
        var k: usize = 0;
        while (it.next() catch unreachable) |_| k += 1;
        bench.doNotOptimizeAway(k);
    }
}

/// Per-query latency over 20k pairs, reported separately for nearby pairs
/// (within 1000 positions, the common UI case) and pairs drawn from the
/// whole history (mostly long, far-apart walks).
fn isAncestorP99(gpa: std.mem.Allocator, io: std.Io, ix: *scm.CommitIndex) !void {
    var prng: std.Random.DefaultPrng = .init(5);
    const rng = prng.random();
    const n = ix.count();
    // The first query builds the reverse edges; keep it out of the numbers.
    _ = try ix.isAncestor(scm.Pos.of(0), scm.Pos.of(n - 1));
    for ([_][]const u8{ "near", "far" }, 0..) |label, kind| {
        const samples = try gpa.alloc(u64, 10_000);
        defer gpa.free(samples);
        var yes: usize = 0;
        for (samples) |*t| {
            const b = rng.uintLessThan(u32, n);
            const a = if (kind == 0) b -| rng.uintLessThan(u32, 1000) else rng.uintLessThan(u32, n);
            const t0 = now(io);
            const r = try ix.isAncestor(scm.Pos.of(a), scm.Pos.of(b));
            t.* = now(io) - t0;
            if (r) yes += 1;
        }
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        std.debug.print("graph.is_ancestor_p99 ({s} pairs): p50 {d} ns, p99 {d} ns, max {d} ns ({d}/{d} true)\n", .{
            label, samples[samples.len / 2], samples[samples.len * 99 / 100], samples[samples.len - 1], yes, samples.len,
        });
    }
}
