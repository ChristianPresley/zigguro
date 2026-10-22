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

/// A seeded synthetic monorepo, about ten files per directory:
/// packages/p<0..199>/<dir>/<dir><0..4>/f<i>_<file>.
fn monorepo(a: std.mem.Allocator, n: usize) ![]const []const u8 {
    var prng: std.Random.DefaultPrng = .init(1_000_000);
    const r = prng.random();
    const dirs = [_][]const u8{ "src", "lib", "test", "components", "utils", "internal", "api", "core", "views", "models" };
    const files = [_][]const u8{ "index.ts", "mod.rs", "__init__.py", "main.zig", "util.go", "README.md", "types.d.ts", "handler.ts" };
    const out = try a.alloc([]const u8, n);
    for (out, 0..) |*p, i| {
        p.* = try std.fmt.allocPrint(a, "packages/p{d}/{s}/{s}{d}/f{d}_{s}", .{
            r.uintLessThan(u32, 200), dirs[r.uintLessThan(usize, dirs.len)], dirs[r.uintLessThan(usize, dirs.len)],
            r.uintLessThan(u32, 5),   i,                                     files[r.uintLessThan(usize, files.len)],
        });
    }
    return out;
}

const StoreCtx = struct { paths: []const []const u8, ops: []zg_workspace.paths.Delta.Op };

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

    // Budget: 1 M paths < 110 MB and < 400 ms single-threaded
    // (E08.F01.S01.T02). One op = building the whole store; bytes_alloc_per_op
    // is the total footprint, and lookups are timed separately below.
    const mono = try monorepo(a, 1_000_000);
    // A directory listing groups paths by directory, as a scan delivers them.
    std.mem.sort([]const u8, @constCast(mono), {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    const ops = try a.alloc(zg_workspace.paths.Delta.Op, mono.len);
    for (ops, mono) |*o, p| o.* = .{ .upsert = .{ .root = .of(0), .rel = p, .info = .{ .kind = .file, .size = 10 } } };
    try b.run("workspace/path_store_1m", StoreCtx{ .paths = mono, .ops = ops }, struct {
        fn f(c: StoreCtx, s: *bench.State) void {
            for (0..s.iterations()) |_| {
                const ps = zg_workspace.PathStore.init(s.allocator(), s.ioHandle()) catch @panic("oom");
                defer ps.deinit();
                ps.addRoot(.of(0), false) catch @panic("oom");
                var ch: std.ArrayList(zg_workspace.paths.Change) = .empty;
                defer ch.deinit(std.heap.page_allocator);
                ch.ensureTotalCapacity(std.heap.page_allocator, c.ops.len * 5 / 4) catch @panic("oom");
                ps.applyWith(&.{ .ops = c.ops }, &ch, std.heap.page_allocator) catch @panic("oom");
                bench.doNotOptimizeAway(ps.nodeCount());
            }
        }
    }.f);
    {
        const ps = try zg_workspace.PathStore.init(std.heap.page_allocator, b.io);
        try ps.addRoot(.of(0), false);
        var ch: std.ArrayList(zg_workspace.paths.Change) = .empty;
        try ps.apply(&.{ .ops = ops }, &ch);
        const snap = ps.snapshot();
        for (mono[0..1000]) |p| _ = snap.lookup(.of(0), p); // warm the children caches
        const LookupCtx = struct { snap: *const zg_workspace.Snapshot, paths: []const []const u8 };
        try b.run("workspace/path_store_lookup", LookupCtx{ .snap = snap, .paths = mono[0..1000] }, struct {
            fn f(c: LookupCtx, s: *bench.State) void {
                for (0..s.iterations()) |i| bench.doNotOptimizeAway(c.snap.lookup(.of(0), c.paths[i % c.paths.len]));
            }
        }.f);
    }

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
