//! Benchmarks for zg_lsp; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("lsp.glob: **/*.{zig,zon} on 60-byte paths", {}, globMatch);
    try b.run("lsp.fuzzy.20k: 20k identifiers x 3 patterns", {}, fuzzy20k);
}

const paths = [_][]const u8{
    "packages/lsp/src/features/completion/engine_internal_x.zig",
    "packages/editor/src/buffer/piece_tree/node_storage_abcd.zon",
    "packages/terminal/src/vt/parser/state_machine_tables_ab.txt",
    "apps/zigguro/src/main/window/frame_scheduler_internals.zig",
};

fn globMatch(_: void, s: *State) void {
    const gpa = s.allocator();
    var g = zg_lsp.glob.Glob.compile(gpa, "**/*.{zig,zon}", .{ .case_insensitive = false }) catch unreachable;
    defer g.deinit(gpa);
    var hits: usize = 0;
    for (0..s.iterations()) |i| {
        if (g.match(paths[i & 3])) hits += 1;
    }
    bench.doNotOptimizeAway(hits);
}

fn fuzzy20k(_: void, s: *State) void {
    const gpa = s.allocator();
    const n = 20_000;
    const words = gpa.alloc([]u8, n) catch unreachable;
    defer {
        for (words) |w| gpa.free(w);
        gpa.free(words);
    }
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    const parts = [_][]const u8{ "get", "set", "Buffer", "parse", "_args", "Node", "tree", "Index", "count", "lsp", "Request", "id" };
    for (words) |*w| {
        var buf: [96]u8 = undefined;
        var len: usize = 0;
        for (0..2 + r.uintLessThan(usize, 4)) |_| {
            const p = parts[r.uintLessThan(usize, parts.len)];
            @memcpy(buf[len..][0..p.len], p);
            len += p.len;
        }
        w.* = gpa.dupe(u8, buf[0..len]) catch unreachable;
    }
    const patterns = [_]zg_lsp.fuzzy.Fuzzy{ .init("gbi"), .init("parseNode"), .init("req") };
    const scratch = gpa.create(zg_lsp.fuzzy.Scratch) catch unreachable;
    defer gpa.destroy(scratch);
    for (0..s.iterations()) |_| {
        var total: i64 = 0;
        for (&patterns) |*p| {
            for (words) |w| total += p.score(w, scratch, null) orelse 0;
        }
        bench.doNotOptimizeAway(total);
    }
}
