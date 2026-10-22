//! E09.F06.S01.T01 describe benchmark: building the describe context
//! (diff, statistics, trunk conventions, prompt) for a change whose diff
//! is 2k lines (budget 50 ms).

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const State = bench.State;

const bench_dir = ".zig-cache/scm-describe-bench";

fn meta(description: []const u8) scm.OpMeta {
    return .{ .start_ms = 0, .end_ms = 0, .description = description, .user = "bench", .host = "host", .workspace = "default", .actor = .human, .tags = &.{} };
}

fn commit(m: *scm.mutable_repo.MutableRepo, gpa: std.mem.Allocator, parents: []const scm.ObjectId, description: []const u8, files: []const [2][]const u8) !scm.ObjectId {
    var tm = scm.tree_merge.TreeMerger.init(gpa, m.batch.store, m.batch);
    defer tm.deinit();
    const tree = try scm.tree_merge.testTree(&tm, files);
    const sig: scm.Signature = .{ .name = "b", .email = "b@example.com", .time_ms = 0, .tz_offset_min = 0 };
    var cid: scm.ChangeId = undefined;
    std.mem.writeInt(u128, &cid.bytes, std.hash.Wyhash.hash(3, description), .little);
    return m.writeChange(.{
        .parents = try m.arena.dupe(scm.ObjectId, parents),
        .tree_terms = try m.arena.dupe(scm.ObjectId, &.{tree}),
        .change_id = cid,
        .predecessors = &.{},
        .author = sig,
        .committer = sig,
        .description = try m.arena.dupe(u8, description),
        .provenance = null,
        .extra = &.{},
        .sig = null,
    });
}

pub fn register(b: *bench.Bench) !void {
    if (b.opts.filter) |f| if (std.mem.indexOf(u8, "describe.context_2k", f) == null) return;
    const gpa = b.gpa;
    const io = b.io;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, bench_dir) catch {};
    defer cwd.deleteTree(io, bench_dir) catch {};
    var root = try cwd.createDirPathOpen(io, bench_dir, .{});
    defer root.close(io);
    const store = try scm.Store.open(gpa, io, root, .{ .fsync = false });
    defer store.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 10 files of 300 lines; the change rewrites 100 lines in each (2k
    // diff lines), on top of 50 trunk commits.
    var base: [10][2][]const u8 = undefined;
    var changed: [10][2][]const u8 = undefined;
    for (&base, &changed, 0..) |*x, *y, i| {
        var old: std.ArrayList(u8) = .empty;
        var new: std.ArrayList(u8) = .empty;
        for (0..300) |l| {
            try old.print(a, "    const v{d} = compute({d}, {d});\n", .{ l, i, l });
            if (l % 3 == 1) try new.print(a, "    const v{d} = computeFaster({d}, {d});\n", .{ l, i, l }) else try new.print(a, "    const v{d} = compute({d}, {d});\n", .{ l, i, l });
        }
        const path = try std.fmt.allocPrint(a, "src/m{d}.zig", .{i});
        x.* = .{ path, old.items };
        y.* = .{ path, new.items };
    }
    const r0 = try scm.Repo.init(gpa, io, root, store, .{}, meta("init"));
    defer r0.close();
    const tx = try r0.startTransaction(meta("setup"));
    const m = tx.mutRepo();
    var trunk = try commit(m, gpa, &.{}, "root", &base);
    for (0..50) |i| trunk = try commit(m, gpa, &.{trunk}, try std.fmt.allocPrint(a, "Trunk change {d}", .{i}), &base);
    var main: ?scm.ObjectId = trunk;
    try m.setBookmark("main", .normal(&main));
    const change = try commit(m, gpa, &.{trunk}, "wip", &changed);
    const r1 = try tx.commit();
    defer r1.close();

    try b.run("describe.context_2k: describe context for a 2k-line diff", Ctx{ .repo = r1, .change = change }, context2k);
}

const Ctx = struct { repo: *scm.Repo, change: scm.ObjectId };

fn context2k(c: Ctx, s: *State) void {
    var d: scm.ai.describe.Describer = .{ .repo = c.repo, .model = .{ .ctx = undefined, .complete = undefined } };
    for (0..s.iterations()) |_| {
        var arena: std.heap.ArenaAllocator = .init(s.allocator());
        defer arena.deinit();
        const ctx = d.buildContext(arena.allocator(), c.change, .{}) catch unreachable;
        bench.doNotOptimizeAway(ctx.tokens);
    }
}
