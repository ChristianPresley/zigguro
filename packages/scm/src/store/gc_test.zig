//! Chunked blobs, compaction, GC and fsck on scratch stores.

const std = @import("std");
const id_mod = @import("id.zig");
const object = @import("object.zig");
const enc = @import("encode.zig");
const store_mod = @import("store.zig");
const chunker = @import("chunker.zig");
const compaction = @import("compaction.zig");
const gc_mod = @import("gc.zig");
const fsck_mod = @import("fsck.zig");
const Store = store_mod.Store;
const ObjectId = id_mod.ObjectId;
const Allocator = std.mem.Allocator;

const fast: store_mod.Options = .{ .fsync = false, .rescan_interval_ms = 0 };
const small: chunker.ChunkParams = .{ .min = 4 << 10, .avg = 16 << 10, .max = 64 << 10, .threshold = 64 << 10 };
const far_future: i96 = std.math.maxInt(i64);

/// A reader producing `len` bytes: 256 KiB blocks drawn from 16 seeded
/// patterns, so the content is incompressible but repeats at a scale
/// larger than a chunk.
const Synthetic = struct {
    len: u64,
    pos: u64 = 0,
    interface: std.Io.Reader,

    fn init(len: u64, buf: []u8) Synthetic {
        return .{ .len = len, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buf, .seek = 0, .end = 0 } };
    }

    fn byteAt(pos: u64) u8 {
        const block = pos >> 18;
        const pattern = std.hash.int(block *% 0x9e3779b97f4a7c15) % 16;
        return @truncate(std.hash.int((pattern << 18) | (pos & ((1 << 18) - 1))));
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const sy: *Synthetic = @fieldParentPtr("interface", r);
        if (sy.pos == sy.len) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n: usize = @intCast(@min(dest.len, sy.len - sy.pos));
        for (dest[0..n], 0..) |*b, k| b.* = byteAt(sy.pos + k);
        sy.pos += n;
        w.advance(n);
        return n;
    }
};

fn readAll(gpa: Allocator, s: *Store, id: ObjectId) ![]u8 {
    var buf: [4096]u8 = undefined;
    var br = try chunker.blobReader(s, id, &buf);
    defer br.deinit();
    return br.interface.allocRemaining(gpa, .unlimited);
}

test "chunker: small blobs stay plain, large ones round-trip" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try Store.open(gpa, t.io, tmp.dir, fast);
    defer s.close();

    var r: std.Io.Reader = .fixed("small file\n");
    const plain = try chunker.writeBlobStreaming(s, &r, small);
    try t.expect(plain.eql(id_mod.hashObject(.blob, "small file\n")));
    const back = try readAll(gpa, s, plain);
    defer gpa.free(back);
    try t.expectEqualStrings("small file\n", back);

    var prng: std.Random.DefaultPrng = .init(5);
    const data = try gpa.alloc(u8, 3 << 20);
    defer gpa.free(data);
    prng.random().bytes(data);
    var dr: std.Io.Reader = .fixed(data);
    const big = try chunker.writeBlobStreaming(s, &dr, small);
    try t.expectEqual(id_mod.Kind.chunked_blob, try s.readKind(big));
    const big_back = try readAll(gpa, s, big);
    defer gpa.free(big_back);
    try t.expectEqualSlices(u8, data, big_back);

    // A 1-byte edit in the middle re-stores at most 3 chunks.
    data[data.len / 2] ^= 0xff;
    const before = s.segmentCount();
    var er: std.Io.Reader = .fixed(data);
    const edited = try chunker.writeBlobStreaming(s, &er, small);
    try t.expect(!edited.eql(big));
    try t.expectEqual(before + 1, s.segmentCount());
    const newest = s.segments.items[0];
    // New chunks plus the chunked blob itself.
    try t.expect(newest.index.count <= 3 + 1);
    const edited_back = try readAll(gpa, s, edited);
    defer gpa.free(edited_back);
    try t.expectEqualSlices(u8, data, edited_back);
}

test "blobReader: streams 64 MiB synthetic with bounded memory" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try Store.open(gpa, t.io, tmp.dir, fast);
    defer s.close();
    const len: u64 = 64 << 20;
    var ibuf: [8192]u8 = undefined;
    var sy: Synthetic = .init(len, &ibuf);
    const id = try chunker.writeBlobStreaming(s, &sy.interface, small);
    // Repeated content dedupes: far less than 64 MiB was stored.
    var stored: u64 = 0;
    for (s.segments.items) |sg| stored += sg.data.bytes.len;
    try t.expect(stored < len / 4);
    var buf: [4096]u8 = undefined;
    var br = try chunker.blobReader(s, id, &buf);
    defer br.deinit();
    try t.expectEqual(len, br.size);
    var pos: u64 = 0;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = try br.interface.readSliceShort(&chunk);
        for (chunk[0..n], 0..) |b, k| if (b != Synthetic.byteAt(pos + k)) return error.TestUnexpectedResult;
        pos += n;
        if (n < chunk.len) break;
    }
    try t.expectEqual(len, pos);
}

/// Builds: blob a, blob b in a tree, a change on that tree, and garbage.
const Graph = struct {
    a: ObjectId,
    b: ObjectId,
    tree: ObjectId,
    change: ObjectId,
    garbage: [3]ObjectId,

    fn build(s: *Store, gpa: Allocator) !Graph {
        var g: Graph = undefined;
        var batch = s.batch();
        errdefer batch.abort();
        g.a = try batch.put(.blob, "a\n");
        g.b = try batch.put(.blob, "b\n");
        const tree_bytes = try enc.encodeAlloc(gpa, object.Tree, .{ .entries = &.{
            .{ .name = "a.txt", .kind = .file, .id = g.a },
            .{ .name = "b.txt", .kind = .file, .id = g.b },
        } });
        defer gpa.free(tree_bytes);
        g.tree = try batch.put(.tree, tree_bytes);
        const sig: object.Signature = .{ .name = "t", .email = "t@x", .time_ms = 0, .tz_offset_min = 0 };
        const change_bytes = try enc.encodeAlloc(gpa, object.Change, .{
            .parents = &.{},
            .tree_terms = &.{g.tree},
            .change_id = .{ .bytes = @splat(1) },
            .predecessors = &.{},
            .author = sig,
            .committer = sig,
            .description = "root\n",
            .provenance = null,
            .extra = &.{},
            .sig = null,
        });
        defer gpa.free(change_bytes);
        g.change = try batch.put(.change, change_bytes);
        for (&g.garbage, 0..) |*x, i| {
            var nb: [16]u8 = undefined;
            x.* = try batch.put(.blob, try std.fmt.bufPrint(&nb, "garbage {d}", .{i}));
        }
        try batch.commit();
        return g;
    }
};

const OneRoot = struct {
    id: ObjectId,

    fn forEach(ctx: *anyopaque, sink: *gc_mod.RootSink) anyerror!void {
        const self: *OneRoot = @ptrCast(@alignCast(ctx));
        try sink.add(self.id);
    }

    fn provider(self: *OneRoot) gc_mod.RootProvider {
        return .{ .ctx = self, .forEachRoot = forEach };
    }
};

test "gc: keeps reachable, removes unreachable after grace" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try Store.open(gpa, t.io, tmp.dir, fast);
    defer s.close();
    const g = try Graph.build(s, gpa);
    var root: OneRoot = .{ .id = g.change };
    const roots = [_]gc_mod.RootProvider{root.provider()};

    // Within the grace period nothing is collected.
    const r0 = try gc_mod.gc(s, &roots, .{});
    try t.expectEqual(@as(usize, 0), r0.objects_removed);
    try t.expect(s.contains(g.garbage[0]));

    const r1 = try gc_mod.gc(s, &roots, .{ .now_ns = far_future, .rewrite_below = 1 });
    try t.expectEqual(@as(usize, 3), r1.objects_removed);
    try t.expectEqual(@as(usize, 1), r1.segments_rewritten);
    try t.expectEqual(@as(usize, 0), r1.missing);
    for (g.garbage) |x| try t.expect(!s.contains(x));
    for ([_]ObjectId{ g.a, g.b, g.tree, g.change }) |x| (try s.readVerified(x)).release();
    try t.expectEqual(@as(usize, 1), s.segmentCount());

    var rep = try fsck_mod.fsck(s, .{ .roots = &roots });
    defer rep.deinit();
    try t.expect(rep.clean());
    try t.expectEqual(@as(usize, 0), rep.dangling.items.len);
    try t.expectEqual(@as(usize, 4), rep.objects);

    // Nothing reachable: the whole segment goes.
    const r2 = try gc_mod.gc(s, &.{}, .{ .now_ns = far_future });
    try t.expectEqual(@as(usize, 1), r2.segments_deleted);
    try t.expectEqual(@as(usize, 0), s.segmentCount());
    const fresh = try Store.open(gpa, t.io, tmp.dir, fast);
    defer fresh.close();
    try t.expect(!fresh.contains(g.change));
}

test "gc: concurrent writer during gc keeps its objects" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try Store.open(gpa, t.io, tmp.dir, fast);
    defer s.close();
    const g = try Graph.build(s, gpa);
    // A batch in flight deduplicates against an unreachable object; until
    // it ends, that object is pinned.
    var b = s.batch();
    try t.expect(g.garbage[1].eql(try b.put(.blob, "garbage 1")));
    var root: OneRoot = .{ .id = g.change };
    const roots = [_]gc_mod.RootProvider{root.provider()};
    const r = try gc_mod.gc(s, &roots, .{ .now_ns = far_future, .rewrite_below = 1 });
    try t.expectEqual(@as(usize, 2), r.objects_removed);
    try t.expect(s.contains(g.garbage[1]));
    try b.commit();
    // A fresh segment (inside the grace period) is never collected.
    var b2 = s.batch();
    const recent = try b2.put(.blob, "written just now");
    try b2.commit();
    _ = try gc_mod.gc(s, &roots, .{});
    try t.expect(s.contains(recent));
}

test "fsck: detects flipped byte, missing object, bad index" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        const s = try Store.open(gpa, t.io, tmp.dir, fast);
        defer s.close();
        const g = try Graph.build(s, gpa);
        // A tree naming a blob the store does not have.
        var b = s.batch();
        const ghost = id_mod.hashObject(.blob, "never stored");
        const tree_bytes = try enc.encodeAlloc(gpa, object.Tree, .{ .entries = &.{.{ .name = "ghost", .kind = .file, .id = ghost }} });
        defer gpa.free(tree_bytes);
        _ = try b.put(.tree, tree_bytes);
        try b.commit();
        var rep = try fsck_mod.fsck(s, .{});
        defer rep.deinit();
        try t.expectEqual(@as(usize, 0), rep.corrupt.items.len);
        try t.expectEqual(@as(usize, 1), rep.missing.items.len);
        try t.expect(rep.missing.items[0].eql(ghost));
        try t.expect(!rep.clean());

        // Flip a byte inside blob "a\n" in the first segment's data.
        const sg = for (s.segments.items) |x| {
            if (x.index.find(g.a) != null) break x;
        } else unreachable;
        const rec = try sg.record(sg.index.find(g.a).?);
        const off = @intFromPtr(rec.payload.ptr) - @intFromPtr(sg.data.bytes.ptr);
        var name: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "seg/{s}.zgs", .{sg.stem});
        const f = try tmp.dir.openFile(t.io, path, .{ .mode = .read_write });
        try f.writePositionalAll(t.io, "A", off);
        f.close(t.io);
    }
    const s = try Store.open(gpa, t.io, tmp.dir, fast);
    defer s.close();
    var rep = try fsck_mod.fsck(s, .{});
    defer rep.deinit();
    try t.expectEqual(@as(usize, 1), rep.corrupt.items.len);
    try t.expectEqualStrings("content does not hash to its id", rep.corrupt.items[0].reason);

    // Truncate one index and leave an unpublished data file.
    var it = s.seg_dir.iterate();
    var zgi_name: [64]u8 = undefined;
    var zgi_len: usize = 0;
    while (try it.next(t.io)) |e| if (std.mem.endsWith(u8, e.name, ".zgi")) {
        @memcpy(zgi_name[0..e.name.len], e.name);
        zgi_len = e.name.len;
    };
    try s.seg_dir.writeFile(t.io, .{ .sub_path = zgi_name[0..zgi_len], .data = "ZGSI\x01\x00\x00\x00" });
    try s.seg_dir.writeFile(t.io, .{ .sub_path = "00000000000000ff-0000000000000000.zgs", .data = "ZGSG" });
    var rep2 = try fsck_mod.fsck(s, .{});
    defer rep2.deinit();
    try t.expect(rep2.corrupt.items.len >= 1);
    try t.expectEqual(@as(usize, 1), rep2.unpublished.items.len);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try rep2.format(&aw.writer);
    try t.expect(std.mem.indexOf(u8, aw.written(), "unpublished 00000000000000ff") != null);

    // GC removes the unpublished file once it is past the grace period.
    const r = try gc_mod.gc(s, &.{}, .{ .now_ns = far_future, .rewrite_below = 0 });
    try t.expect(r.unpublished_removed >= 1);
}

test "compaction: merges small segments and deflates" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try Store.open(gpa, t.io, tmp.dir, fast);
    defer s.close();
    var ids: std.ArrayList(ObjectId) = .empty;
    defer ids.deinit(gpa);
    var text: [2048]u8 = undefined;
    for (0..10) |k| {
        var b = s.batch();
        for (0..20) |j| {
            for (&text, 0..) |*c, x| c.* = "fn main() void {}\n"[(x + j + k) % 18];
            std.mem.writeInt(u64, text[0..8], k * 100 + j, .little);
            try ids.append(gpa, try b.put(.text, &text));
        }
        try b.commit();
    }
    // A duplicate across segments, written by a second store.
    {
        const other = try Store.open(gpa, t.io, tmp.dir, .{ .fsync = false, .rescan_interval_ms = 60_000 });
        defer other.close();
        var b = other.batch();
        b.store = other;
        try b.copyRecord(ids.items[0], try s.segments.items[9].record(s.segments.items[9].index.find(ids.items[0]).?), false);
        try b.commit();
    }
    try s.rescan();
    try t.expectEqual(@as(usize, 11), s.segmentCount());
    var before: u64 = 0;
    for (s.segments.items) |sg| before += sg.data.bytes.len;
    const r = try compaction.compact(s, .{ .all = true });
    try t.expectEqual(@as(usize, 11), r.merged);
    try t.expectEqual(@as(usize, 200), r.objects);
    try t.expectEqual(@as(usize, 1), s.segmentCount());
    try t.expect(s.segments.items[0].data.bytes.len < before / 4);
    for (ids.items) |id| (try s.readVerified(id)).release();
    var rep = try fsck_mod.fsck(s, .{});
    defer rep.deinit();
    try t.expect(rep.clean());
    try t.expectEqual(@as(usize, 1), rep.segments);
    // Nothing more to merge.
    try t.expectEqual(@as(usize, 0), (try compaction.compact(s, .{})).merged);
}
