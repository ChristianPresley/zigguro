//! E09.F04.S01.T02 content merge benchmark: a 10k-line file with 20
//! scattered, non-overlapping edits on each side (budget 5 ms). Also the
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
