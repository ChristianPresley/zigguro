//! E09.F04.S01.T02 content merge benchmark: a 10k-line file with 20
//! scattered, non-overlapping edits on each side (budget 5 ms).

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
}

fn contentMerge(c: Ctx, s: *State) void {
    for (0..s.iterations()) |_| {
        var arena: std.heap.ArenaAllocator = .init(s.allocator());
        defer arena.deinit();
        const r = scm.content_merge.mergeContent(arena.allocator(), .{ .values = c.vals }, .{}) catch unreachable;
        bench.doNotOptimizeAway(r.clean.?.len);
    }
}
