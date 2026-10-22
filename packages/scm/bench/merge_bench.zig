//! E09.F04.S01.T02 content merge benchmark: a 10k-line file with 20
//! scattered, non-overlapping edits on each side (budget 5 ms), and tree
//! merges: rebasing a 20-commit stack over a 10k-file tree, and the trees
//! loaded merging 100k-file trees that differ in 10 files (at most
//! 3 x depth x 10). Also the
//! E09.F06.S02.T01 resolve proposer's per-region work on a 5k-line Zig
//! file: building the context (budget 5 ms) and validating a reply
//! (budget 20 ms).

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const State = bench.State;

const Ctx = struct { vals: []const []const u8 };

pub fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(gpa);
    var left: std.ArrayList(u8) = .empty;
    defer left.deinit(gpa);
    var right: std.ArrayList(u8) = .empty;
    defer right.deinit(gpa);
    for (0..10_000) |i| {
        try base.print(gpa, "    const line_{d} = compute({d});\n", .{ i, i * 7 });
        if (i % 500 == 100) try left.print(gpa, "    const line_{d} = changed_left({d});\n", .{ i, i }) else try left.print(gpa, "    const line_{d} = compute({d});\n", .{ i, i * 7 });
        if (i % 500 == 350) try right.print(gpa, "    const line_{d} = changed_right({d});\n", .{ i, i }) else try right.print(gpa, "    const line_{d} = compute({d});\n", .{ i, i * 7 });
    }
    const vals = [_][]const u8{ left.items, base.items, right.items };
    try b.run("merge.content_10k: 3-way merge of a 10k-line file, 20 edits a side", Ctx{ .vals = &vals }, contentMerge);
    try registerResolve(b);
    try registerTrees(b);
}

const bench_dir = ".zig-cache/scm-merge-bench";

/// A 3-level grid of files: `dirs` x `subs` x `files`.
const Grid = struct {
    dirs: usize,
    subs: usize,
    files: usize,

    fn build(g: Grid, tm: *scm.tree_merge.TreeMerger) !scm.ObjectId {
        const a = tm.arena_state.allocator();
        var top: std.ArrayList(scm.TreeEntry) = .empty;
        for (0..g.dirs) |d| {
            var mid: std.ArrayList(scm.TreeEntry) = .empty;
            for (0..g.subs) |s| {
                var leaf: std.ArrayList(scm.TreeEntry) = .empty;
                for (0..g.files) |f| {
                    const content = try std.fmt.allocPrint(a, "file {d}/{d}/{d}\nwith a second line\n", .{ d, s, f });
                    try leaf.append(a, .{ .name = try std.fmt.allocPrint(a, "f{d}.txt", .{f}), .kind = .file, .id = try tm.putBlob(content) });
                }
                try mid.append(a, .{ .name = try std.fmt.allocPrint(a, "s{d}", .{s}), .kind = .tree, .id = try tm.write(leaf.items) });
            }
            try top.append(a, .{ .name = try std.fmt.allocPrint(a, "d{d}", .{d}), .kind = .tree, .id = try tm.write(mid.items) });
        }
        return tm.write(top.items);
    }
};

/// `root` with file d/s/f replaced by `content`.
fn edit(tm: *scm.tree_merge.TreeMerger, root: scm.ObjectId, d: usize, s: usize, f: usize, content: []const u8) !scm.ObjectId {
    var names: [3][16]u8 = undefined;
    const path = [3][]const u8{
        try std.fmt.bufPrint(&names[0], "d{d}", .{d}),
        try std.fmt.bufPrint(&names[1], "s{d}", .{s}),
        try std.fmt.bufPrint(&names[2], "f{d}.txt", .{f}),
    };
    return editAt(tm, root, &path, content);
}

fn editAt(tm: *scm.tree_merge.TreeMerger, tree: scm.ObjectId, path: []const []const u8, content: []const u8) !scm.ObjectId {
    const a = tm.arena_state.allocator();
    const t = try tm.read(tree);
    const entries = try a.dupe(scm.TreeEntry, t.entries);
    for (entries) |*e| {
        if (!std.mem.eql(u8, e.name, path[0])) continue;
        e.id = if (path.len == 1) try tm.putBlob(content) else try editAt(tm, e.id, path[1..], content);
    }
    return tm.write(entries);
}

const StackCtx = struct {
    store: *scm.Store,
    trunk: scm.ObjectId,
    base: scm.ObjectId,
    stack: []const scm.ObjectId,
};

fn registerTrees(b: *bench.Bench) !void {
    const gpa = b.gpa;
    const io = b.io;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, bench_dir) catch {};
    defer cwd.deleteTree(io, bench_dir) catch {};
    var dir = try cwd.createDirPathOpen(io, bench_dir, .{});
    defer dir.close(io);
    const store = try scm.Store.open(gpa, io, dir, .{ .fsync = false });
    defer store.close();

    // A 10k-file tree, trunk moved by 10 edits, and a stack of 20
    // commits editing other files (each on top of the previous).
    var batch = store.batch();
    var tm = scm.tree_merge.TreeMerger.init(gpa, store, &batch);
    defer tm.deinit();
    const grid: Grid = .{ .dirs = 10, .subs = 10, .files = 100 };
    const base = try grid.build(&tm);
    var trunk = base;
    for (0..10) |i| trunk = try edit(&tm, trunk, i, 0, 0, "trunk\n");
    var stack: [20]scm.ObjectId = undefined;
    var prev = base;
    for (&stack, 0..) |*c, i| {
        prev = try edit(&tm, prev, i % 10, 5, i, "stack\n");
        c.* = prev;
    }

    // 100k files, 10 differing: 5 edits on each side, in the same
    // top-level directories.
    const big: Grid = .{ .dirs = 10, .subs = 100, .files = 100 };
    const big_base = try big.build(&tm);
    var left = big_base;
    var right = big_base;
    for (0..5) |i| {
        left = try edit(&tm, left, i, i, i, "left\n");
        right = try edit(&tm, right, i, 50 + i, i, "right\n");
    }
    try batch.commit();

    {
        var b2 = store.batch();
        defer b2.abort();
        var lazy = scm.tree_merge.TreeMerger.init(gpa, store, &b2);
        defer lazy.deinit();
        _ = (try lazy.merge3(big_base, left, right)).?;
        std.debug.print("merge.lazy_100k: merging 100k-file trees differing in 10 files loaded {d} trees (limit {d})\n", .{ lazy.loaded, 3 * 3 * 10 });
        if (lazy.loaded > 3 * 3 * 10) return error.TooManyTreesLoaded;
    }

    const ctx: StackCtx = .{ .store = store, .trunk = trunk, .base = base, .stack = &stack };
    try b.run("merge.stack_rebase_20: rebase a 20-commit stack over a moved 10k-file trunk", ctx, stackRebase);
}

fn stackRebase(c: StackCtx, s: *State) void {
    for (0..s.iterations()) |_| {
        var batch = c.store.batch();
        defer batch.abort();
        var tm = scm.tree_merge.TreeMerger.init(s.allocator(), c.store, &batch);
        defer tm.deinit();
        var cache = scm.tree_merge.MergeCache.init(s.allocator());
        defer cache.deinit();
        tm.cache = &cache;
        var old_parent = c.base;
        var new_parent = c.trunk;
        for (c.stack) |own| {
            const merged = (tm.merge3(old_parent, new_parent, own) catch unreachable).?;
            old_parent = own;
            new_parent = merged;
        }
        bench.doNotOptimizeAway(new_parent.bytes[0]);
    }
}

const resolve = scm.ai.resolve;

const ResolveCtx = struct { set: *const resolve.ConflictSet, region: *const resolve.Region, gpa: std.mem.Allocator };

fn registerResolve(b: *bench.Bench) !void {
    var arena_state: std.heap.ArenaAllocator = .init(b.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var texts: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    for (0..1250) |i| {
        for (&texts, [_][]const u8{ "a", "", "b" }) |*x, tag| {
            try x.print(a, "fn f{d}(x: u32) u32 {{\n", .{i});
            if (i == 800) try x.print(a, "    return {s}{d};\n", .{ tag, i }) else try x.print(a, "    return x + {d};\n", .{i});
            try x.appendSlice(a, "}\n\n");
        }
    }
    const vals = [_][]const u8{ texts[0].items, texts[1].items, texts[2].items };
    const res = try scm.content_merge.mergeContent(a, .{ .values = &vals }, .{});
    var hunk: u32 = 0;
    for (res.hunks, 0..) |h, i| if (h == .conflict) {
        hunk = @intCast(i);
    };
    const m = res.hunks[hunk].conflict.values;
    const sig: scm.Signature = .{ .name = "b", .email = "b@example.com", .time_ms = 0, .tz_offset_min = 0 };
    const c: scm.Change = .{
        .parents = &.{},
        .tree_terms = &.{},
        .change_id = .{ .bytes = @splat(0) },
        .predecessors = &.{},
        .author = sig,
        .committer = sig,
        .description = "bench",
        .provenance = null,
        .extra = &.{},
        .sig = null,
    };
    const files = [_]resolve.ConflictFile{.{ .path = "big.zig", .entries = .{ null, null, null }, .hunks = res.hunks }};
    const regions = [_]resolve.Region{.{ .path = "big.zig", .region_idx = 0, .kind = .text, .terms = .{ m[0], m[1], m[2] }, .file = 0, .hunk = hunk }};
    const set: resolve.ConflictSet = .{ .change = scm.ObjectId.zero, .commit = c, .side_changes = .{ c, c }, .files = &files, .regions = &regions };
    const ctx: ResolveCtx = .{ .set = &set, .region = &regions[0], .gpa = b.gpa };
    try b.run("resolve.context_5k: one region's context in a 5k-line file", ctx, resolveContext);
    try b.run("resolve.validate_5k: markers, identifiers and Zig syntax for one region of a 5k-line file", ctx, resolveValidate);
}

fn resolveContext(c: ResolveCtx, s: *State) void {
    for (0..s.iterations()) |_| {
        var arena: std.heap.ArenaAllocator = .init(s.allocator());
        defer arena.deinit();
        const ctx = resolve.context(arena.allocator(), c.set, c.region, .{}) catch unreachable;
        bench.doNotOptimizeAway(ctx.before.len + ctx.after.len);
    }
}

fn resolveValidate(c: ResolveCtx, s: *State) void {
    var res: resolve.Resolver = .{ .gpa = c.gpa, .io = undefined, .store = undefined, .model = undefined };
    const ans: resolve.Answer = .{ .resolution = "    return a800 + b800;\n", .addresses_sides = &.{ true, true } };
    for (0..s.iterations()) |_| {
        var arena: std.heap.ArenaAllocator = .init(s.allocator());
        defer arena.deinit();
        const why = res.validate(arena.allocator(), c.set, c.region, ans) catch unreachable;
        if (why != null) @panic(why.?);
    }
}

fn contentMerge(c: Ctx, s: *State) void {
    for (0..s.iterations()) |_| {
        var arena: std.heap.ArenaAllocator = .init(s.allocator());
        defer arena.deinit();
        const r = scm.content_merge.mergeContent(arena.allocator(), .{ .values = c.vals }, .{}) catch unreachable;
        bench.doNotOptimizeAway(r.clean.?.len);
    }
}
