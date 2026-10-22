//! Store tests on scratch directories: round trips, dedup, concurrent
//! writers, cross-store visibility and injected commit failures.

const std = @import("std");
const id_mod = @import("id.zig");
const seg = @import("segment.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Allocator = std.mem.Allocator;

const fast: store_mod.Options = .{ .fsync = false, .rescan_interval_ms = 0, .deflate_on_write = true };

/// Object `i` of a deterministic test set: sizes from 0 to ~20 KiB, every
/// third one compressible text.
fn makeObject(gpa: Allocator, i: usize) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(i);
    const r = prng.random();
    const len = r.uintAtMost(usize, if (i % 50 == 0) 20_000 else 2_000);
    const b = try gpa.alloc(u8, len);
    if (i % 3 == 0) {
        for (b, 0..) |*c, k| c.* = "const x = compute(y);\n"[(k + i) % 22];
    } else r.bytes(b);
    return b;
}

fn kindOf(i: usize) Kind {
    return switch (i % 4) {
        0 => .blob,
        1 => .tree,
        2 => .change,
        else => .text,
    };
}

fn expectObject(s: *Store, id: ObjectId, kind: Kind, want: []const u8) !void {
    const r = try s.read(id);
    defer r.release();
    try std.testing.expectEqual(kind, r.kind);
    try std.testing.expectEqualSlices(u8, want, r.bytes);
}

/// Every published segment's index hashes correctly and every record
/// hashes to its ID (the core of T03's fsck).
fn verifyStore(s: *Store) !usize {
    try s.rescan();
    var n: usize = 0;
    for (s.segments.items) |sg| {
        try std.testing.expect(sg.index.verifyChecksum());
        try std.testing.expect(sg.index.verifyOrder());
        for (0..sg.index.count) |k| {
            const id = sg.index.id(@intCast(k));
            const r = try s.readVerified(id);
            r.release();
            n += 1;
        }
    }
    return n;
}

test "store: put/read 10k" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const n = 10_000;
    const ids = try gpa.alloc(ObjectId, n);
    defer gpa.free(ids);
    {
        const s = try Store.open(gpa, t.io, tmp.dir, fast);
        defer s.close();
        var b = s.batch();
        for (ids, 0..) |*id, i| {
            const obj = try makeObject(gpa, i);
            defer gpa.free(obj);
            id.* = try b.put(kindOf(i), obj);
            try t.expect(id.eql(id_mod.hashObject(kindOf(i), obj)));
        }
        try b.commit();
        try t.expectEqual(@as(usize, 1), s.segmentCount());
        for (ids, 0..) |id, i| {
            const obj = try makeObject(gpa, i);
            defer gpa.free(obj);
            try expectObject(s, id, kindOf(i), obj);
            try t.expectEqual(kindOf(i), try s.readKind(id));
            try t.expect(s.contains(id));
        }
        try t.expect(!s.contains(id_mod.hashObject(.blob, "absent")));
        try t.expectError(error.NotFound, s.read(id_mod.hashObject(.blob, "absent")));
    }
    // A fresh store sees the same objects, and some records were deflated.
    const s = try Store.open(gpa, t.io, tmp.dir, fast);
    defer s.close();
    var deflated: usize = 0;
    const sg = s.segments.items[0];
    for (0..sg.index.count) |k| {
        if ((try sg.record(@intCast(k))).deflated()) deflated += 1;
    }
    try t.expect(deflated > n / 10);
    for (ids, 0..) |id, i| {
        if (i % 7 != 0) continue;
        const obj = try makeObject(gpa, i);
        defer gpa.free(obj);
        try expectObject(s, id, kindOf(i), obj);
    }
    // Some generated objects coincide; each distinct one is stored once.
    var distinct: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
    defer distinct.deinit(gpa);
    for (ids) |id| try distinct.put(gpa, id, {});
    try t.expectEqual(@as(usize, distinct.count()), try verifyStore(s));
}

test "store: dedup in batch and across batches" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try Store.open(t.allocator, t.io, tmp.dir, fast);
    defer s.close();
    var b = s.batch();
    const a = try b.put(.blob, "same");
    try t.expect(a.eql(try b.put(.blob, "same")));
    // Same bytes, different kind: a different object.
    try t.expect(!a.eql(try b.put(.text, "same")));
    try t.expectEqual(@as(usize, 2), b.entries.items.len);
    try b.commit();
    var b2 = s.batch();
    try t.expect(a.eql(try b2.put(.blob, "same")));
    try t.expectEqual(@as(usize, 0), b2.entries.items.len);
    try b2.commit(); // nothing to publish
    try t.expectEqual(@as(usize, 1), s.segmentCount());
    var b3 = s.batch();
    _ = try b3.put(.blob, "new");
    b3.abort();
    try t.expectEqual(@as(usize, 1), s.segmentCount());
    try t.expect(!s.contains(id_mod.hashObject(.blob, "new")));
    // No leftovers from the aborted batch.
    var files: usize = 0;
    var it = s.seg_dir.iterate();
    while (try it.next(t.io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".zgs") or std.mem.endsWith(u8, e.name, ".zgi")) files += 1;
    }
    try t.expectEqual(@as(usize, 2), files);
}

test "store: another store's writes become visible" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const reader = try Store.open(t.allocator, t.io, tmp.dir, fast);
    defer reader.close();
    const writer = try Store.open(t.allocator, t.io, tmp.dir, fast);
    defer writer.close();
    var b = writer.batch();
    const a = try b.put(.blob, "from the other process");
    const c = try b.put(.blob, "second");
    try b.commit();
    // contains notices through seg/GEN; read rescans on a miss.
    try t.expect(reader.contains(a));
    try expectObject(reader, c, .blob, "second");
}

const Shared = struct {
    gpa: Allocator,
    store: *Store,
    worker: usize,
    failed: *std.atomic.Value(bool),
    ids: []ObjectId,

    fn run(sh: Shared) void {
        sh.work() catch |e| {
            std.debug.print("writer {d}: {s}\n", .{ sh.worker, @errorName(e) });
            sh.failed.store(true, .monotonic);
        };
    }

    fn work(sh: Shared) !void {
        // Overlapping sets: worker w writes objects [w*200, w*200 + 600).
        var round: usize = 0;
        while (round < 3) : (round += 1) {
            var b = sh.store.batch();
            errdefer b.abort();
            for (0..200) |k| {
                const i = sh.worker * 200 + round * 200 + k;
                const obj = try makeObject(sh.gpa, i);
                defer sh.gpa.free(obj);
                sh.ids[i] = try b.put(kindOf(i), obj);
            }
            try b.commit();
        }
    }
};

test "store: concurrent writers (8 threads)" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const workers = 8;
    const total = workers * 200 + 400;
    const ids = try gpa.alloc(ObjectId, total);
    defer gpa.free(ids);
    // Half the workers share one store; the rest each have their own, as
    // separate processes would.
    var stores: [workers]*Store = undefined;
    stores[0] = try Store.open(gpa, t.io, tmp.dir, fast);
    for (1..workers) |w| stores[w] = if (w % 2 == 0) stores[0] else try Store.open(gpa, t.io, tmp.dir, fast);
    defer for (stores, 0..) |s, w| if (w == 0 or w % 2 == 1) s.close();
    var failed: std.atomic.Value(bool) = .init(false);
    var g: std.Io.Group = .init;
    for (0..workers) |w| {
        try g.concurrent(t.io, Shared.run, .{Shared{ .gpa = gpa, .store = stores[w], .worker = w, .failed = &failed, .ids = ids }});
    }
    try g.await(t.io);
    try t.expect(!failed.load(.monotonic));
    const check = try Store.open(gpa, t.io, tmp.dir, fast);
    defer check.close();
    for (ids, 0..) |id, i| {
        const obj = try makeObject(gpa, i);
        defer gpa.free(obj);
        try expectObject(check, id, kindOf(i), obj);
    }
    // Duplicates across segments are allowed (compaction removes them).
    try t.expect(try verifyStore(check) >= total);
}

test "store: crash injection" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try Store.open(gpa, t.io, tmp.dir, fast);
    defer s.close();
    var b = s.batch();
    const kept = try b.put(.blob, "committed before the crash");
    try b.commit();
    for ([_]store_mod.FailPoint{ .after_records, .after_segment_link, .before_index_link }, 0..) |fp, k| {
        var bad = s.batch();
        var lost: [3]ObjectId = undefined;
        for (&lost, 0..) |*id, j| {
            var name: [32]u8 = undefined;
            id.* = try bad.put(.blob, try std.fmt.bufPrint(&name, "lost {d} {d}", .{ k, j }));
        }
        bad.fail_at = fp;
        try t.expectError(error.InjectedFailure, bad.commit());
        const re = try Store.open(gpa, t.io, tmp.dir, fast);
        defer re.close();
        try expectObject(re, kept, .blob, "committed before the crash");
        for (lost) |id| try t.expect(!re.contains(id));
        try t.expectEqual(@as(usize, 1), re.segmentCount());
    }
    // An orphaned, truncated segment and a truncated index are ignored.
    try s.seg_dir.writeFile(t.io, .{ .sub_path = "0000000000000000-0000000000000001.zgs", .data = "ZGSG\x01\x00" });
    try s.seg_dir.writeFile(t.io, .{ .sub_path = "0000000000000000-0000000000000002.zgs", .data = "ZGSG\x01\x00\x00\x00" ++ "u" ** 16 });
    try s.seg_dir.writeFile(t.io, .{ .sub_path = "0000000000000000-0000000000000002.zgi", .data = "ZGSI\x01\x00\x00\x00" });
    const re = try Store.open(gpa, t.io, tmp.dir, fast);
    defer re.close();
    try t.expectEqual(@as(usize, 1), re.segmentCount());
    try expectObject(re, kept, .blob, "committed before the crash");
}

test "store: objects stay readable while referenced across eviction" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var opts = fast;
    opts.cache_bytes = 16 * 4096;
    const s = try Store.open(t.allocator, t.io, tmp.dir, opts);
    defer s.close();
    var b = s.batch();
    var ids: [64]ObjectId = undefined;
    var buf: [3201]u8 = undefined;
    @memcpy(buf[1..], "abcdefgh" ** 400);
    for (&ids, 0..) |*id, i| {
        buf[0] = @intCast(i);
        id.* = try b.put(.text, &buf);
    }
    try b.commit();
    const first = try s.read(ids[0]);
    try t.expect(first.owner == .cached);
    for (ids[1..]) |id| (try s.read(id)).release();
    try t.expectEqualSlices(u8, "abcdefgh" ** 400, first.bytes[1..]);
    first.release();
}
