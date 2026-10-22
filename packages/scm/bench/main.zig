//! zg_scm benchmarks (`zig build bench`): the E09.F01 budgets for hashing
//! and the canonical encoding.

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();

    const big = try gpa.alloc(u8, 16 << 20);
    defer gpa.free(big);
    r.bytes(big);
    try b.run("scm.blake3_throughput: hash a 16 MiB blob (one core)", @as([]const u8, big), hashBlob);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = try arena.alloc(scm.TreeEntry, 10_000);
    for (entries, 0..) |*e, i| {
        var id: scm.ObjectId = undefined;
        r.bytes(&id.bytes);
        e.* = .{ .name = try std.fmt.allocPrint(arena, "source_file_{d}.zig", .{i}), .kind = if (i % 10 == 0) .tree else .file, .id = id };
    }
    scm.Tree.sort(entries);
    const tree: scm.Tree = .{ .entries = entries };
    try b.run("scm.encode_tree_10k: encode a 10k-entry tree", tree, encodeTree);
    try b.run("scm.validate_tree_10k: check a 10k-entry tree is canonical", tree, struct {
        fn f(tr: scm.Tree, s: *State) void {
            for (0..s.iterations()) |_| {
                var x = tr;
                bench.doNotOptimizeAway(&x);
                x.validate() catch unreachable;
            }
        }
    }.f);
    const encoded = try scm.encode.encodeAlloc(arena, scm.Tree, tree);
    try b.run("scm.decode_tree_10k: decode a 10k-entry tree", @as([]const u8, encoded), decodeTree);
}

fn hashBlob(data: []const u8, s: *State) void {
    s.setBytes(data.len);
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(scm.hashObject(.blob, data));
}

fn encodeTree(tree: scm.Tree, s: *State) void {
    var aw: std.Io.Writer.Allocating = .init(s.allocator());
    defer aw.deinit();
    for (0..s.iterations()) |_| {
        aw.clearRetainingCapacity();
        scm.encode.encode(scm.Tree, tree, &aw.writer) catch unreachable;
        bench.doNotOptimizeAway(aw.written().len);
    }
}

fn decodeTree(bytes: []const u8, s: *State) void {
    s.setBytes(bytes.len);
    var arena_state: std.heap.ArenaAllocator = .init(s.allocator());
    defer arena_state.deinit();
    for (0..s.iterations()) |_| {
        _ = arena_state.reset(.retain_capacity);
        const t = scm.encode.decode(scm.Tree, arena_state.allocator(), bytes) catch unreachable;
        bench.doNotOptimizeAway(t.entries.len);
    }
}
