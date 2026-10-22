//! Benchmarks for zg_workspace; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_workspace = @import("zg_workspace");
const bench = zg_core.bench;
const wm = zg_workspace.ignore.wildmatch;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

const FastCtx = struct { pats: []const wm.Pattern, names: []const []const u8 };

fn register(b: *bench.Bench) !void {
    const a = arena_state.allocator();

    // Budget: <= 15 ns p50 per fast-path match (E08.F01.S02.T01).
    const srcs = [_][]const u8{ "*.o", "node_modules", "build*", "*_test.zig" };
    var pats: [srcs.len]wm.Pattern = undefined;
    for (srcs, 0..) |s, i| pats[i] = try wm.compile(a, s, .{});
    const names = [_][]const u8{ "main.o", "node_modules", "build.zig", "parser_test.zig", "README.md", "x.c" };
    try b.run("workspace/wildmatch_fast", FastCtx{ .pats = &pats, .names = &names }, struct {
        fn f(c: FastCtx, s: *bench.State) void {
            var hits: u64 = 0;
            for (0..s.iterations()) |i| {
                const p = &c.pats[i % c.pats.len];
                if (wm.match(p, c.names[i % c.names.len], .{})) hits += 1;
            }
            bench.doNotOptimizeAway(hits);
        }
    }.f);

    // Budget: isIgnored p50 <= 300 ns at depth 8 with 200 rules over 4 levels
    // (E08.F01.S02.T02).
    const st = try zg_workspace.IgnoreStack.init(std.heap.page_allocator, b.io, 1);
    const dirs = [_][]const u8{ "", "a/b", "a/b/c/d", "a/b/c/d/e/f" };
    for (dirs, 0..) |d, li| {
        var text: std.ArrayList(u8) = .empty;
        for (0..50) |k| {
            switch (k % 5) {
                0 => try text.print(a, "*.ext{d}{d}\n", .{ li, k }),
                1 => try text.print(a, "name{d}{d}\n", .{ li, k }),
                2 => try text.print(a, "dir{d}{d}/\n", .{ li, k }),
                3 => try text.print(a, "/anch{d}{d}/x\n", .{ li, k }),
                else => try text.print(a, "pre{d}{d}*\n", .{ li, k }),
            }
        }
        try st.loadDir(.of(0), d, text.items, null);
    }
    const paths = [_][]const u8{ "a/b/c/d/e/f/g/file.zig", "a/b/c/d/e/f/g/name011", "a/b/c/d/e/f/g/x.ext30" };
    try b.run("workspace/ignore_query", st, struct {
        fn f(s0: *zg_workspace.IgnoreStack, s: *bench.State) void {
            var n: u64 = 0;
            for (0..s.iterations()) |i| {
                if (s0.isIgnored(.of(0), paths[i % paths.len], false).isIgnored()) n += 1;
            }
            bench.doNotOptimizeAway(n);
        }
    }.f);
}
