//! zg_scm benchmarks (`zig build bench`): the E09.F01 budgets for hashing
//! and the canonical encoding, the store, and (graph_bench.zig) the commit
//! index.

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const graph_bench = @import("graph_bench.zig");
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

    try b.run("scm.chunker_throughput: FastCDC cut points over 16 MiB (one core)", @as([]const u8, big), chunkBlob);

    try storeBenches(b, r);
    try graph_bench.register(b);
}

fn chunkBlob(data: []const u8, s: *State) void {
    s.setBytes(data.len);
    for (0..s.iterations()) |_| {
        var c: scm.chunker.Chunker = .init(.{});
        var rest = data;
        var n: usize = 0;
        while (c.next(rest)) |cut| : (n += 1) rest = rest[cut..];
        bench.doNotOptimizeAway(n);
    }
}

const bench_dir = ".zig-cache/scm-store-bench";

const StoreCtx = struct { store: *scm.Store, ids: []const scm.ObjectId };

fn storeBenches(b: *bench.Bench, r: std.Random) !void {
    const gpa = b.gpa;
    const io = b.io;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, bench_dir) catch {};
    defer cwd.deleteTree(io, bench_dir) catch {};
    var root = try cwd.createDirPathOpen(io, bench_dir, .{});
    defer root.close(io);

    {
        var d = try root.createDirPathOpen(io, "hot", .{});
        defer d.close(io);
        const s = try scm.Store.open(gpa, io, d, .{});
        defer s.close();
        const ids = try gpa.alloc(scm.ObjectId, 10_000);
        defer gpa.free(ids);
        var batch = s.batch();
        var obj: [600]u8 = undefined;
        for (ids) |*id| {
            r.bytes(&obj);
            id.* = try batch.put(.blob, &obj);
        }
        try batch.commit();
        try b.run("scm.store_read_hot: read a 600-byte raw object", StoreCtx{ .store = s, .ids = ids }, readHot);
        try b.run("scm.store_contains: index lookup of a present id", StoreCtx{ .store = s, .ids = ids }, containsHot);

        const ds = try scm.Store.open(gpa, io, d, .{ .deflate_on_write = true });
        defer ds.close();
        var tbatch = ds.batch();
        const text_ids = try gpa.alloc(scm.ObjectId, 1000);
        defer gpa.free(text_ids);
        for (text_ids, 0..) |*id, i| {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            for (0..40) |k| try aw.writer.print("    const v{d}_{d} = f({d});\n", .{ i, k, r.int(u16) });
            id.* = try tbatch.put(.text, aw.written());
        }
        try tbatch.commit();
        try b.run("scm.store_read_hot_deflated: read a cached ~1.2 KiB deflated object", StoreCtx{ .store = ds, .ids = text_ids }, readHot);
    }

    {
        var d = try root.createDirPathOpen(io, "write", .{});
        defer d.close(io);
        const s = try scm.Store.open(gpa, io, d, .{});
        defer s.close();
        try b.run("scm.store_write_throughput: 64 x 64 KiB raw objects, one durable batch", WriteCtx{ .store = s, .size = 64 << 10, .count = 64, .text = false }, writeBatch);
        try b.run("scm.store_write_throughput_small: 256 x 4 KiB source objects, one durable batch", WriteCtx{ .store = s, .size = 4 << 10, .count = 256, .text = true }, writeBatch);
        const nosync = try scm.Store.open(gpa, io, d, .{ .fsync = false });
        defer nosync.close();
        try b.run("scm.store_write_nosync: 64 x 64 KiB raw objects, no fsync", WriteCtx{ .store = nosync, .size = 64 << 10, .count = 64, .text = false }, writeBatch);
        // The write path without the disk: put everything, then abort.
        try b.run("scm.store_write_cpu: 64 x 64 KiB raw objects, put then abort", WriteCtx{ .store = nosync, .size = 64 << 10, .count = 64, .text = false, .commit = false }, writeBatch);
        try b.run("scm.store_write_cpu_small: 256 x 4 KiB source objects, put then abort", WriteCtx{ .store = nosync, .size = 4 << 10, .count = 256, .text = true, .commit = false }, writeBatch);
        const deflating = try scm.Store.open(gpa, io, d, .{ .fsync = false, .deflate_on_write = true });
        defer deflating.close();
        try b.run("scm.store_write_cpu_deflate: 256 x 4 KiB source objects deflated on write, put then abort", WriteCtx{ .store = deflating, .size = 4 << 10, .count = 256, .text = true, .commit = false }, writeBatch);
    }

    {
        var d = try root.createDirPathOpen(io, "open", .{});
        defer d.close(io);
        const s = try scm.Store.open(gpa, io, d, .{ .fsync = false });
        for (0..64) |k| {
            var batch = s.batch();
            for (0..100) |j| {
                var obj: [64]u8 = undefined;
                r.bytes(&obj);
                std.mem.writeInt(u64, obj[0..8], k * 1000 + j, .little);
                _ = try batch.put(.blob, &obj);
            }
            try batch.commit();
        }
        s.close();
        try b.run("scm.store_open_64: open a store with 64 segments", d, openStore);
    }
}

fn readHot(c: StoreCtx, s: *State) void {
    for (0..s.iterations()) |i| {
        const ref = c.store.read(c.ids[(i * 7919) % c.ids.len]) catch unreachable;
        bench.doNotOptimizeAway(ref.bytes.len);
        ref.release();
    }
}

fn containsHot(c: StoreCtx, s: *State) void {
    for (0..s.iterations()) |i| bench.doNotOptimizeAway(c.store.contains(c.ids[(i * 7919) % c.ids.len]));
}

const WriteCtx = struct { store: *scm.Store, size: usize, count: usize, text: bool, commit: bool = true };

var write_round: u64 = 0;

fn writeBatch(c: WriteCtx, s: *State) void {
    s.setBytes(c.size * c.count);
    const gpa = s.allocator();
    const obj = gpa.alloc(u8, c.size) catch unreachable;
    defer gpa.free(obj);
    var prng: std.Random.DefaultPrng = .init(write_round);
    if (c.text) {
        for (obj, 0..) |*ch, k| ch.* = "pub fn next(self: *Iter) ?u32 {\n"[k % 32];
    } else prng.random().bytes(obj);
    for (0..s.iterations()) |_| {
        var batch = c.store.batch();
        for (0..c.count) |k| {
            // Unique objects every round, or dedup would skip the writes.
            write_round += 1;
            std.mem.writeInt(u64, obj[0..8], write_round, .little);
            std.mem.writeInt(u64, obj[obj.len - 8 ..][0..8], k, .little);
            _ = batch.put(.blob, obj) catch unreachable;
        }
        if (c.commit) batch.commit() catch unreachable else batch.abort();
    }
}

fn openStore(d: std.Io.Dir, s: *State) void {
    for (0..s.iterations()) |_| {
        const st = scm.Store.open(s.allocator(), s.ioHandle(), d, .{}) catch unreachable;
        bench.doNotOptimizeAway(st.segmentCount());
        st.close();
    }
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
