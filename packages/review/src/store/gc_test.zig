const std = @import("std");
const model = @import("../model/root.zig");
const store_mod = @import("store.zig");
const gc = @import("gc.zig");
const Checkpoints = @import("../checkpoint/root.zig").Checkpoints;
const apply = @import("../apply/root.zig");
const comments = @import("../feedback/comments.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const ChangesetStore = store_mod.ChangesetStore;
const ChangeSet = model.changeset.ChangeSet;

/// A queue, history and checkpoints bound to a store in `dir/review`.
const Proc = struct {
    store: *ChangesetStore,
    q: *model.Queue,
    history: model.History,
    disk: apply.MemFiles,
    cps: Checkpoints,
    sink: store_mod.QueueSink,
    comments: comments.CommentStore,

    fn open(p: *Proc, dir: std.Io.Dir, tag: u32) !void {
        p.store = try ChangesetStore.open(gpa, io, dir, "review", .{ .process_tag = tag });
        p.q = try model.Queue.init(gpa, io, .{ .root = "/w", .blobs = p.store.blobs(), .journal = p.store.journalPort() });
        p.history = .init(gpa, p.store.recorder());
        p.disk = .init(gpa);
        p.cps = .init(gpa, io, p.q, &p.history, p.disk.files(), p.store.checkpointRecorder());
        p.sink = p.store.queueSink(p.q, &p.history, p.cps.sink());
        p.comments = .init(gpa, .{ .recorder = p.store.commentRecorder(), .id_base = @as(u64, tag) << 32 });
        p.sink.comments = p.comments.restoreSink();
        _ = try p.store.load(p.sink.sink());
    }

    fn close(p: *Proc) void {
        p.store.close();
        p.comments.deinit();
        p.cps.deinit();
        p.q.deinit();
        p.history.deinit();
        p.disk.deinit();
    }

    fn collect(p: *Proc, ret: gc.Retention) !gc.Report {
        return gc.collect(p.store, p.sink.sink(), .{ .q = p.q, .history = &p.history, .checkpoints = p.cps.gcList(), .comments = &p.comments }, ret);
    }

    fn submit(p: *Proc, path: []const u8, base: []const u8) !model.ChangesetId {
        const b = try p.q.beginBatch(.{ .origin = .{ .agent = .{ .ref = .{ .session = 7 }, .turn = 1, .model = "m" } }, .label = "Turn", .workspace = "/w", .created_ms = 0 });
        var e: ChangeSet = try .fromEdits(gpa, base.len, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "x" }});
        defer e.deinit();
        try p.q.addEdit(b, path, base, null, &e);
        return p.q.commitBatch(b, .{});
    }

    /// Decides `id` (rejected) at `ms`.
    fn decide(p: *Proc, id: model.ChangesetId, ms: i64) !void {
        const cs = p.q.getMut(id).?;
        try model.transition(cs, .rejected);
        cs.decided_ms = ms;
        p.q.persist(id);
    }

    /// A history record of `cs` writing `pre` → `post` to `path`.
    fn recordApply(p: *Proc, cs: ?model.ChangesetId, path: []const u8, pre: []const u8, post: []const u8) !u64 {
        const b = p.store.blobs();
        _ = try b.put(pre);
        _ = try b.put(post);
        return p.history.record(.{ .cs = cs, .session = 7, .created_ms = 1, .files = &.{.{ .path = path, .pre = model.blobHash(pre), .post = model.blobHash(post) }} });
    }
};

fn blobExists(dir: std.Io.Dir, bytes: []const u8) bool {
    var path: [80]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "review/{s}", .{&@import("blobs.zig").DiskBlobs.pathOf(model.blobHash(bytes))}) catch unreachable;
    dir.access(io, p, .{}) catch return false;
    return true;
}

/// Every blob old enough to collect.
const now_blobs: gc.Retention = .{ .keep_last_n = 1, .blob_grace_ms = -std.time.ms_per_hour };

test "gc: retention, snapshot, blob sweep, and ids that keep counting after reload" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var old: [2]model.ChangesetId = undefined;
    var open_id: model.ChangesetId = undefined;
    var kept_apply: u64 = 0;
    var cp_id: u64 = 0;
    var dropped_cp: u64 = 0;
    {
        var p: Proc = undefined;
        try p.open(tmp.dir, 1);
        defer p.close();
        old[0] = try p.submit("a.txt", "old base a\n");
        old[1] = try p.submit("b.txt", "old base b\n");
        try p.decide(old[0], 0);
        try p.decide(old[1], 0);
        _ = try p.recordApply(old[0], "a.txt", "old pre\n", "old post\n");
        dropped_cp = p.cps.create(.{ .session = 7 }, 1, "long ago");
        p.cps.list.items[0].created_ms = 0;
        cp_id = p.cps.create(.{ .session = 7 }, 2, "recent");
        kept_apply = try p.recordApply(null, "c.txt", "new pre\n", "new post\n");
        open_id = try p.submit("c.txt", "open base\n");
        try p.store.flush();
        try testing.expect(blobExists(tmp.dir, "old pre\n"));

        const r = try p.collect(now_blobs);
        try testing.expectEqual(@as(u32, 2), r.changesets_removed);
        try testing.expectEqual(@as(u32, 1), r.checkpoints_removed);
        try testing.expectEqual(@as(u32, 1), r.applies_removed);
        try testing.expectEqual(@as(u32, 1), r.segments_removed);
        try testing.expect(r.blobs_removed >= 4);
        try testing.expect(!blobExists(tmp.dir, "old pre\n"));
        try testing.expect(!blobExists(tmp.dir, "old post\n"));
        try testing.expect(!blobExists(tmp.dir, "old base a\n"));
        try testing.expect(blobExists(tmp.dir, "new pre\n"));
        try testing.expect(blobExists(tmp.dir, "open base\n"));
        try testing.expect(p.q.get(old[0]) == null);
        try testing.expect(p.cps.get(dropped_cp) == null);
        try testing.expectEqual(@as(usize, 1), p.history.items().len);
        try testing.expectEqual(@as(u32, 1), (try p.store.journalSize()).segments);
    }
    var p: Proc = undefined;
    try p.open(tmp.dir, 2);
    defer p.close();
    try testing.expectEqual(@as(usize, 1), p.q.changesets.count());
    try testing.expect(p.q.get(open_id) != null);
    try testing.expectEqual(@as(usize, 1), p.history.items().len);
    try testing.expectEqual(kept_apply, p.history.items()[0].id);
    try testing.expectEqualStrings("recent", p.cps.get(cp_id).?.label);
    try testing.expect(p.cps.get(dropped_cp) == null);
    // Dropped ids are not handed out again.
    try testing.expect(@intFromEnum(try p.submit("d.txt", "")) > @intFromEnum(open_id));
    try testing.expectEqual(kept_apply + 1, try p.recordApply(null, "d.txt", "1", "2"));
    try testing.expect(p.cps.create(.{ .session = 7 }, 3, "") > cp_id);
}

test "gc: history needed by kept changesets and checkpoints stays" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p: Proc = undefined;
    try p.open(tmp.dir, 1);
    defer p.close();
    const a = try p.submit("a.txt", "a\n");
    try p.decide(a, std.math.maxInt(i64) / 2); // decided "now": kept
    const first = try p.recordApply(a, "a.txt", "a\n", "A\n");
    _ = try p.recordApply(null, "z.txt", "z\n", "Z\n");
    const r = try p.collect(.{ .keep_last_n = 1, .blob_grace_ms = -std.time.ms_per_hour });
    try testing.expectEqual(@as(u32, 0), r.applies_removed);
    try testing.expectEqual(first, p.history.items()[0].id);
    try testing.expect(blobExists(tmp.dir, "A\n"));
}

test "gc: another process tails the snapshot and the removals" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: Proc = undefined;
    try a.open(tmp.dir, 1);
    defer a.close();
    var b: Proc = undefined;
    try b.open(tmp.dir, 2);
    defer b.close();
    const x = try a.submit("x.txt", "x\n");
    try a.decide(x, 0);
    const y = try a.submit("y.txt", "y\n");
    try a.store.flush();
    _ = try b.store.tail(b.sink.sink());
    try testing.expectEqual(@as(usize, 2), b.q.changesets.count());
    // B appends something A has not read yet; GC reads it first.
    const z = try b.submit("z.txt", "z\n");
    try b.store.flush();
    _ = try a.collect(now_blobs);
    try testing.expect(a.q.get(z) != null);
    try testing.expect(blobExists(tmp.dir, "z\n"));
    _ = try b.store.tail(b.sink.sink());
    try testing.expect(b.q.get(x) == null);
    try testing.expect(b.q.get(y) != null);
    try testing.expect(b.q.get(z) != null);
    // B keeps appending after the compaction, and A reads it.
    const w = try b.submit("w.txt", "w\n");
    try b.store.flush();
    _ = try a.store.tail(a.sink.sink());
    try testing.expect(a.q.get(w) != null);
}

test "gc: a crash between the snapshot and the deletes loads the same state" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const seg = "review/journal/00000001.zrj";
    var old_bytes: []u8 = undefined;
    var kept: model.ChangesetId = undefined;
    {
        var p: Proc = undefined;
        try p.open(tmp.dir, 1);
        defer p.close();
        const gone = try p.submit("a.txt", "a\n");
        try p.decide(gone, 0);
        kept = try p.submit("b.txt", "b\n");
        _ = p.cps.create(.{ .session = 7 }, 1, "cp");
        try p.store.flush();
        old_bytes = try tmp.dir.readFileAlloc(io, seg, gpa, .unlimited);
        _ = try p.collect(.{ .keep_last_n = 1 });
    }
    defer gpa.free(old_bytes);
    // Put the old segment back, as if the deletes had not happened.
    try tmp.dir.writeFile(io, .{ .sub_path = seg, .data = old_bytes });
    var p: Proc = undefined;
    try p.open(tmp.dir, 3);
    defer p.close();
    try testing.expect(p.q.get(kept) != null);
    try testing.expectEqual(@as(usize, 1), p.q.changesets.count());
    var list: std.ArrayList(model.Checkpoint) = .empty;
    defer list.deinit(gpa);
    try p.cps.listSession(7, &list, gpa);
    try testing.expectEqual(@as(usize, 1), list.items.len);
}

test "gc: comment threads stay with kept changesets and go with dropped ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var kept_thread: comments.ThreadId = undefined;
    var kept: model.ChangesetId = undefined;
    var gone: model.ChangesetId = undefined;
    {
        var p: Proc = undefined;
        try p.open(tmp.dir, 1);
        defer p.close();
        gone = try p.submit("a.txt", "a\n");
        try p.decide(gone, 0);
        kept = try p.submit("b.txt", "b\n");
        const anchor: comments.CommentAnchor = try .at(gpa, "b.txt", .new, "xb\n", .{ .start = 0, .count = 1 });
        _ = try p.comments.create(gone, anchor, null, false, "old", .{ .user = "u" }, 1);
        kept_thread = try p.comments.create(kept, anchor, .issue, true, "issue (blocking): b", .{ .user = "u" }, 2);
        _ = try p.comments.reply(kept_thread, "on it", .{ .user = "agent" }, 3);
        try p.comments.resolve(kept_thread, true);
        try p.store.flush();
        _ = try p.collect(now_blobs);
        try testing.expectEqual(@as(usize, 0), p.comments.threadsOf(gone).len);
    }
    var p: Proc = undefined;
    try p.open(tmp.dir, 1);
    defer p.close();
    try testing.expectEqual(@as(usize, 0), p.comments.threadsOf(gone).len);
    const t = p.comments.get(kept_thread).?;
    try testing.expectEqual(kept, t.target);
    try testing.expectEqual(@as(usize, 2), t.comments.items.len);
    try testing.expect(t.resolved and t.blocking);
    // The id counter survives the compaction.
    const anchor: comments.CommentAnchor = try .at(gpa, "b.txt", .new, "xb\n", .{ .start = 0, .count = 1 });
    try testing.expect(@intFromEnum(try p.comments.create(kept, anchor, null, false, "new", .{ .user = "u" }, 4)) > t.comments.items[1].id);
}
