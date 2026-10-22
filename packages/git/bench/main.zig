//! zg_git benchmarks (`zig build bench`): the E09.F07 budgets for pack
//! reads, delta chains, indexing and zlib object encoding.

const std = @import("std");
const zg_core = @import("zg_core");
const git = @import("zg_git");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const Built = struct {
    pack: []u8,
    idx: []u8,
    ids: []git.Oid,

    fn deinit(b: *Built, gpa: std.mem.Allocator) void {
        gpa.free(b.pack);
        gpa.free(b.idx);
        gpa.free(b.ids);
    }
};

fn build(gpa: std.mem.Allocator, objects: []const []const u8, opts: git.pack_writer.WriteOptions) !Built {
    var pw = git.pack_writer.PackWriter.init(gpa, null, .sha1);
    defer pw.deinit();
    const ids = try gpa.alloc(git.Oid, objects.len);
    errdefer gpa.free(ids);
    for (objects, ids) |o, *id| id.* = try pw.addData(.blob, o, .{ .path = "bench/file" });
    var pack: std.Io.Writer.Allocating = .init(gpa);
    errdefer pack.deinit();
    const res = try pw.finish(&pack.writer, opts);
    var idx: std.Io.Writer.Allocating = .init(gpa);
    errdefer idx.deinit();
    try pw.writeIndex(&idx.writer, res.checksum);
    return .{ .pack = try pack.toOwnedSlice(), .idx = try idx.toOwnedSlice(), .ids = ids };
}

const HotCtx = struct { pack: *git.pack.Pack, cache: *git.cache.DeltaBaseCache, offsets: []const u64 };

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();

    // 10k distinct ~600-byte source-like blobs; no deltas.
    const n_hot = 10_000;
    const hot_objs = try gpa.alloc([]u8, n_hot);
    defer {
        for (hot_objs) |o| gpa.free(o);
        gpa.free(hot_objs);
    }
    for (hot_objs, 0..) |*o, i| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        for (0..12) |k| try aw.writer.print("    const value_{d}_{d} = compute({d}, {d});\n", .{ i, k, r.int(u32), k });
        o.* = try aw.toOwnedSlice();
    }
    var hot = try build(gpa, @ptrCast(hot_objs), .{ .window = 0 });
    defer hot.deinit(gpa);
    var hot_pack = try git.pack.Pack.init(.borrowed(hot.pack), .borrowed(hot.idx), .sha1, 0);
    const offsets = try gpa.alloc(u64, n_hot);
    defer gpa.free(offsets);
    for (offsets, 0..) |*o, i| o.* = hot_pack.find(hot.ids[(i * 7919) % n_hot]).?;
    var cache: git.cache.DeltaBaseCache = .init(gpa, b.io, 96 << 20);
    defer cache.deinit();
    try b.run("git.pack_read_hot: read a 600-byte non-delta object", HotCtx{ .pack = &hot_pack, .cache = &cache, .offsets = offsets }, packReadHot);
    try b.run("git.pack_lookup: idx find of a present oid", HotCtx{ .pack = &hot_pack, .cache = &cache, .offsets = offsets }, packLookup);
    try b.run("git.pack_read_header: type and size of a non-delta object", HotCtx{ .pack = &hot_pack, .cache = &cache, .offsets = offsets }, packReadHeader);

    // A 50-deep delta chain: one file growing by a line per version.
    const chain_objs = try gpa.alloc([]u8, 51);
    defer {
        for (chain_objs) |o| gpa.free(o);
        gpa.free(chain_objs);
    }
    {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        for (0..2000) |k| try aw.writer.print("base line {d}\n", .{k});
        for (chain_objs, 0..) |*o, i| {
            try aw.writer.print("appended line {d}\n", .{i});
            o.* = try gpa.dupe(u8, aw.written());
        }
    }
    var chain = try build(gpa, @ptrCast(chain_objs), .{ .window = 1, .depth = 50 });
    defer chain.deinit(gpa);
    var chain_pack = try git.pack.Pack.init(.borrowed(chain.pack), .borrowed(chain.idx), .sha1, 1);
    // The smallest version is the deepest delta.
    const tip = [_]u64{chain_pack.find(chain.ids[0]).?};
    try b.run("git.delta_chain_50: read the tip of a 50-deep chain, cache warm", HotCtx{ .pack = &chain_pack, .cache = &cache, .offsets = &tip }, packReadHot);
    try b.run("git.delta_chain_50_cold: same tip, no cache", HotCtx{ .pack = &chain_pack, .cache = &cache, .offsets = &tip }, packReadCold);

    try b.run("git.index_pack_throughput: index 10k-object pack (1 thread)", hot.pack, indexPack1);
    try b.run("git.index_pack_throughput_mt: index 10k-object pack (all cores)", hot.pack, indexPackMt);

    const blob64k = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(blob64k);
    {
        var w: std.Io.Writer = .fixed(blob64k);
        var k: usize = 0;
        while (w.end + 64 < blob64k.len) : (k += 1) w.print("fn f{d}(x: u32) u32 {{ return x * {d}; }}\n", .{ k, r.int(u16) }) catch break;
        @memset(blob64k[w.end..], '\n');
    }
    try b.run("git.loose_encode: zlib-encode a 64 KiB object", @as([]const u8, blob64k), looseEncode);
    try b.run("git.pack_write: 2k growing versions with deltas", @as([]const []const u8, @ptrCast(chain_objs)), packWrite);

    var refs_text: std.Io.Writer.Allocating = .init(gpa);
    defer refs_text.deinit();
    try refs_text.writer.writeAll("# pack-refs with: peeled fully-peeled sorted \n");
    for (0..50_000) |i| {
        var hb: [64]u8 = undefined;
        const id = git.oid.hashBytes(.sha1, std.mem.asBytes(&i));
        try refs_text.writer.print("{s} refs/tags/release-{d:0>6}\n", .{ id.hex(&hb), i });
    }
    try b.run("git.packed_refs_50k: parse and index 50k packed refs", @as([]const u8, refs_text.written()), packedRefs);
}

fn packedRefs(text: []const u8, s: *State) void {
    s.setBytes(text.len);
    for (0..s.iterations()) |_| {
        const copy = s.allocator().dupe(u8, text) catch unreachable;
        var p = git.refs.packed_refs.PackedRefs.parse(s.allocator(), copy, .sha1) catch unreachable;
        bench.doNotOptimizeAway(p.find("refs/tags/release-025000"));
        p.deinit(s.allocator());
    }
}

fn packReadHot(c: HotCtx, s: *State) void {
    const gpa = s.allocator();
    for (0..s.iterations()) |i| {
        var o = c.pack.readAt(gpa, c.cache, c.offsets[i % c.offsets.len]) catch unreachable;
        bench.doNotOptimizeAway(o.data.len);
        o.deinit(gpa);
    }
}

fn packReadCold(c: HotCtx, s: *State) void {
    const gpa = s.allocator();
    for (0..s.iterations()) |i| {
        var o = c.pack.readAt(gpa, null, c.offsets[i % c.offsets.len]) catch unreachable;
        bench.doNotOptimizeAway(o.data.len);
        o.deinit(gpa);
    }
}

fn packLookup(c: HotCtx, s: *State) void {
    const n = c.pack.index.count();
    for (0..s.iterations()) |i| {
        const id = c.pack.index.oidAt(@intCast((i * 7919) % n));
        bench.doNotOptimizeAway(c.pack.find(id));
    }
}

fn packReadHeader(c: HotCtx, s: *State) void {
    for (0..s.iterations()) |i| {
        const h = c.pack.readHeaderAt(c.offsets[i % c.offsets.len]) catch unreachable;
        bench.doNotOptimizeAway(h.size);
    }
}

fn indexWith(pack: []const u8, s: *State, threads: u8) void {
    s.setBytes(pack.len);
    for (0..s.iterations()) |_| {
        var res = git.indexer.indexBytes(s.allocator(), s.ioHandle(), pack, .sha1, null, .{ .threads = threads }, null) catch unreachable;
        res.deinit(s.allocator());
    }
}

fn indexPack1(pack: []const u8, s: *State) void {
    indexWith(pack, s, 1);
}

fn indexPackMt(pack: []const u8, s: *State) void {
    indexWith(pack, s, 0);
}

fn looseEncode(blob: []const u8, s: *State) void {
    s.setBytes(blob.len);
    var aw: std.Io.Writer.Allocating = .init(s.allocator());
    defer aw.deinit();
    for (0..s.iterations()) |_| {
        aw.clearRetainingCapacity();
        git.loose.encode(s.allocator(), &aw.writer, .blob, blob, .default) catch unreachable;
        bench.doNotOptimizeAway(aw.written().len);
    }
}

fn packWrite(objs: []const []const u8, s: *State) void {
    var total: u64 = 0;
    for (objs) |o| total += o.len;
    s.setBytes(total);
    for (0..s.iterations()) |_| {
        var built = build(s.allocator(), objs, .{}) catch unreachable;
        built.deinit(s.allocator());
    }
}
