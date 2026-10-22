//! Crash injection for the store (E09.F01.S01.T02): a FaultIo fails or
//! tears a write at a random point while batches commit and segments
//! compact; a store reopened afterwards must still hold every committed
//! object, may hold the crashed batch only in full, and must pass fsck.
//! The plain test runs a few hundred seeds; the fuzz target lets the
//! nightly campaign run many more.

const std = @import("std");
const id_mod = @import("id.zig");
const store_mod = @import("store.zig");
const compaction = @import("compaction.zig");
const fsck_mod = @import("fsck.zig");
const FaultIo = @import("fault_io.zig").FaultIo;
const Store = store_mod.Store;
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Object `i`: up to ~3 KiB, half of them compressible.
fn makeObject(buf: []u8, i: u64) []const u8 {
    var prng: std.Random.DefaultPrng = .init(i *% 0x9e3779b97f4a7c15);
    const r = prng.random();
    const b = buf[0..r.uintAtMost(usize, @min(buf.len, 3000))];
    if (i % 2 == 0) {
        for (b, 0..) |*c, k| c.* = "fn crash(x: u32) void {}\n"[(k + i) % 25];
    } else r.bytes(b);
    return b;
}

fn kindOf(i: u64) Kind {
    return if (i % 3 == 0) .text else .blob;
}

const Written = struct { id: ObjectId, i: u64 };

const Run = struct {
    gpa: Allocator,
    rng: std.Random,
    next: u64 = 0,
    committed: std.ArrayList(Written) = .empty,
    /// Objects of the batch that was committing when the fault hit.
    maybe: std.ArrayList(Written) = .empty,

    fn deinit(run: *Run) void {
        run.committed.deinit(run.gpa);
        run.maybe.deinit(run.gpa);
    }

    /// Writes one batch; on failure its objects go to `maybe`.
    fn batch(run: *Run, s: *Store) !void {
        var b = s.batch();
        defer b.abort();
        var pending: std.ArrayList(Written) = .empty;
        defer pending.deinit(run.gpa);
        var buf: [3000]u8 = undefined;
        const n = 1 + run.rng.uintLessThan(usize, 40);
        const ok = for (0..n) |_| {
            const i = run.next;
            run.next += 1;
            const id = b.put(kindOf(i), makeObject(&buf, i)) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => break false,
            };
            try pending.append(run.gpa, .{ .id = id, .i = i });
        } else if (b.commit()) |_| true else |e| switch (e) {
            error.OutOfMemory => return e,
            else => false,
        };
        try (if (ok) &run.committed else &run.maybe).appendSlice(run.gpa, pending.items);
        if (!ok) return error.Crashed;
    }
};

fn expectSame(s: *Store, w: Written) !void {
    var buf: [3000]u8 = undefined;
    const r = try s.readVerified(w.id);
    defer r.release();
    try testing.expectEqual(kindOf(w.i), r.kind);
    try testing.expectEqualSlices(u8, makeObject(&buf, w.i), r.bytes);
}

fn crashOnce(gpa: Allocator, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const opts: store_mod.Options = .{
        .fsync = rng.boolean(),
        .rescan_interval_ms = 0,
        .deflate_on_write = rng.uintLessThan(u8, 4) == 0,
    };
    var run: Run = .{ .gpa = gpa, .rng = rng };
    defer run.deinit();

    // Before the crash: a few clean batches.
    {
        const s = try Store.open(gpa, testing.io, tmp.dir, opts);
        defer s.close();
        for (0..1 + rng.uintLessThan(usize, 3)) |_| try run.batch(s);
    }

    // The crashing process: batches and compactions until the fault.
    {
        var fio: FaultIo = undefined;
        fio.init(testing.io, rng.uintLessThan(u64, 80));
        defer fio.deinit();
        fio.torn_len = if (rng.boolean()) rng.uintLessThan(usize, 600) else 0;
        if (Store.open(gpa, fio.io(), tmp.dir, opts)) |s| {
            defer s.close();
            for (0..6) |_| {
                if (rng.uintLessThan(u8, 4) == 0) {
                    _ = compaction.compact(s, .{ .all = rng.boolean(), .deflate = rng.boolean() }) catch |e| switch (e) {
                        error.OutOfMemory => return e,
                        else => break,
                    };
                } else run.batch(s) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => break,
                };
            }
        } else |e| switch (e) {
            error.OutOfMemory => return e,
            else => {},
        }
    }

    // The restarted process.
    const s = try Store.open(gpa, testing.io, tmp.dir, opts);
    defer s.close();
    for (run.committed.items) |w| try expectSame(s, w);
    for (run.maybe.items) |w| {
        if (s.contains(w.id)) try expectSame(s, w);
    }
    var report = try fsck_mod.fsck(s, .{});
    defer report.deinit();
    if (!report.clean()) {
        std.debug.print("seed {d}: {f}\n", .{ seed, report });
        return error.FsckFailed;
    }
}

test "store: crash injection at random points" {
    for (0..300) |seed| try crashOnce(testing.allocator, seed);
}

test "fuzz: store crash injection" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            try crashOnce(testing.allocator, sm.value(u64));
        }
    }.one, .{});
}

test "store: retire defers deleting files that are still mapped" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fio: FaultIo = undefined;
    fio.init(testing.io, std.math.maxInt(u64));
    defer fio.deinit();
    const s = try Store.open(gpa, fio.io(), tmp.dir, .{ .fsync = false, .rescan_interval_ms = 0 });
    defer s.close();
    var b = s.batch();
    const a = try b.put(.blob, "first segment");
    try b.commit();
    b = s.batch();
    _ = try b.put(.blob, "second segment");
    try b.commit();
    const old = s.segments.items[1];
    const stem = try gpa.dupe(u8, old.stem);
    defer gpa.free(stem);

    // Windows refuses to delete a mapped file; FaultIo does the same for
    // the segment we hold, so the deferred path runs everywhere.
    const held = try s.read(a);
    fio.fail_deletes_of = stem;
    _ = try compaction.compact(s, .{ .all = true });
    try testing.expectEqual(@as(usize, 1), s.segmentCount());
    // Still on disk, but a rescan does not bring it back.
    var nb: [64]u8 = undefined;
    _ = try s.seg_dir.statFile(testing.io, try std.fmt.bufPrint(&nb, "{s}.zgi", .{stem}), .{});
    try s.rescan();
    try testing.expectEqual(@as(usize, 1), s.segmentCount());
    try testing.expectEqualSlices(u8, "first segment", held.bytes);

    // The last reference unmaps, then deletes.
    fio.fail_deletes_of = null;
    held.release();
    for ([_][]const u8{ "zgi", "zgs" }) |ext| {
        try testing.expectError(error.FileNotFound, s.seg_dir.statFile(testing.io, try std.fmt.bufPrint(&nb, "{s}.{s}", .{ stem, ext }), .{}));
    }
    try s.rescan();
    try testing.expectEqual(@as(usize, 1), s.segmentCount());
    const again = try s.read(a);
    again.release();
}
