//! Document, snapshot and change-log tests, including the multi-threaded
//! snapshot stress test.

const std = @import("std");
const document = @import("document.zig");
const cs_mod = @import("edit/change_set.zig");

const Document = document.Document;
const ChangeSet = cs_mod.ChangeSet;
const gpa = std.testing.allocator;

fn edit(doc: *Document, start: u64, end: u64, text: []const u8) !void {
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = start, .end = end }, .text = text }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
}

fn snapText(s: anytype) ![]u8 {
    return s.tree.copyRange(gpa, .{ .start = 0, .end = s.tree.len() });
}

test "snapshot: survives 1000 edits" {
    var doc = try Document.initBytes(gpa, @enumFromInt(1), "version ten text");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    var prng: std.Random.DefaultPrng = .init(41);
    const r = prng.random();
    for (0..1000) |_| {
        const at = r.uintLessThan(u64, doc.len() + 1);
        if (r.boolean() or doc.len() < 4) try edit(doc, at, at, "ab") else try edit(doc, @min(at, doc.len() - 2), @min(at, doc.len() - 2) + 2, "");
    }
    const t = try snapText(&snap);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("version ten text", t);
    try std.testing.expectEqual(@as(u64, 1000), doc.version);
}

test "snapshot: release on worker defers free to UI drain" {
    var doc = try Document.initBytes(gpa, @enumFromInt(1), "abc" ** 5000);
    defer doc.deinit();
    var snap = doc.snapshot();
    // Diverge so the snapshot's nodes are its own.
    try edit(doc, 0, 3, "");
    try edit(doc, 100, 100, "zz");
    const live = doc.store.pool.live;
    const t = try std.Thread.spawn(.{}, struct {
        fn run(s: *document.Document, sn: *@import("snapshot.zig").Snapshot) void {
            _ = s;
            sn.release();
        }
    }.run, .{ doc, &snap });
    t.join();
    try std.testing.expectEqual(live, doc.store.pool.live);
    doc.endFrame();
    try std.testing.expect(doc.store.pool.live < live);
}

test "snapshot: outlives its document" {
    var doc = try Document.initBytes(gpa, @enumFromInt(1), "keep me");
    var snap = doc.snapshot();
    try edit(doc, 0, 4, "lose");
    doc.deinit();
    const t = try snapText(&snap);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("keep me", t);
    snap.release();
}

test "snapshot: stress 8 threads" {
    var doc = try Document.initBytes(gpa, @enumFromInt(1), "0123456789" ** 100);
    defer doc.deinit();
    const Shared = struct {
        mutex: std.atomic.Mutex = .unlocked,
        latest: ?@import("snapshot.zig").Snapshot = null,
        expected: []u8 = &.{},
        stop: std.atomic.Value(bool) = .init(false),
        failures: std.atomic.Value(u32) = .init(0),
    };
    var shared: Shared = .{};
    const Worker = struct {
        fn run(sh: *Shared) void {
            var buf: [64]u8 = undefined;
            while (!sh.stop.load(.acquire)) {
                while (!sh.mutex.tryLock()) std.atomic.spinLoopHint();
                var s = (sh.latest orelse {
                    sh.mutex.unlock();
                    continue;
                }).retain();
                const want_copy = std.heap.page_allocator.dupe(u8, sh.expected) catch unreachable;
                sh.mutex.unlock();
                defer std.heap.page_allocator.free(want_copy);
                // Read a few ranges and compare.
                var off: u64 = 0;
                while (off + buf.len <= s.len()) : (off += 97) {
                    var it = s.tree.slice(.{ .start = off, .end = off + buf.len });
                    var n: usize = 0;
                    while (it.next()) |ch| {
                        @memcpy(buf[n..][0..ch.len], ch);
                        n += ch.len;
                    }
                    if (!std.mem.eql(u8, buf[0..n], want_copy[@intCast(off)..][0..n])) _ = sh.failures.fetchAdd(1, .monotonic);
                }
                s.release();
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&shared});
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    for (0..2000) |_| {
        const at = r.uintLessThan(u64, doc.len());
        try edit(doc, at, @min(at + 3, doc.len()), "xyzw");
        const next = doc.snapshot();
        const text = try snapText(&next);
        while (!shared.mutex.tryLock()) std.atomic.spinLoopHint();
        if (shared.latest) |*old| old.release();
        gpa.free(shared.expected);
        shared.latest = next;
        shared.expected = text;
        shared.mutex.unlock();
        doc.endFrame();
    }
    shared.stop.store(true, .release);
    for (threads) |t| t.join();
    if (shared.latest) |*old| old.release();
    gpa.free(shared.expected);
    doc.endFrame();
    try std.testing.expectEqual(@as(u32, 0), shared.failures.load(.monotonic));
}

test "change_log: mapForward through inserts/deletes with biases" {
    var doc = try Document.initBytes(gpa, @enumFromInt(1), "abcdefghij");
    defer doc.deinit();
    const v0 = doc.version;
    try edit(doc, 2, 2, "XX"); // abXXcdefghij
    try edit(doc, 6, 8, ""); // abXXcdghij
    try std.testing.expectEqual(cs_mod.Range{ .start = 4, .end = 5 }, doc.mapForward(v0, .{ .start = 2, .end = 3 }, .right).?);
    try std.testing.expectEqual(cs_mod.Range{ .start = 2, .end = 5 }, doc.mapForward(v0, .{ .start = 2, .end = 3 }, .left).?);
    try std.testing.expectEqual(@as(?cs_mod.Range, null), doc.mapForward(v0, .{ .start = 4, .end = 6 }, .left));
    try std.testing.expectEqual(cs_mod.Range{ .start = 8, .end = 10 }, doc.mapForward(v0, .{ .start = 8, .end = 10 }, .left).?);
}

const Recorder = struct {
    count: u32 = 0,
    last_version: u64 = 0,
    fn onChange(ctx: *anyopaque, ev: *const document.ChangeEvent) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.last_version = ev.new_version;
    }
};

test "listener: called in order after each edit" {
    var doc = try Document.initBytes(gpa, @enumFromInt(1), "x");
    defer doc.deinit();
    var rec: Recorder = .{};
    const id = try doc.subscribe(.{ .ctx = &rec, .onChange = Recorder.onChange });
    try edit(doc, 0, 0, "a");
    try edit(doc, 0, 0, "b");
    doc.unsubscribe(id);
    try edit(doc, 0, 0, "c");
    try std.testing.expectEqual(@as(u32, 2), rec.count);
    try std.testing.expectEqual(@as(u64, 2), rec.last_version);
    try std.testing.expect(doc.isDirty());
}
