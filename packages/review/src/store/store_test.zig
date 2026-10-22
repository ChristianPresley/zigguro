const std = @import("std");
const model = @import("../model/root.zig");
const store_mod = @import("store.zig");
const journal = @import("journal.zig");
const records = @import("records.zig");

const testing = std.testing;
const io = testing.io;
const ChangesetStore = store_mod.ChangesetStore;
const ChangeSet = model.changeset.ChangeSet;

/// A queue bound to a store in `dir/review`.
const Proc = struct {
    store: *ChangesetStore,
    q: *model.Queue,
    history: model.History = undefined,
    sink: store_mod.QueueSink = undefined,

    fn open(self: *Proc, dir: std.Io.Dir, o: store_mod.Options) !store_mod.LoadReport {
        self.store = try ChangesetStore.open(testing.allocator, io, dir, "review", o);
        self.q = try model.Queue.init(testing.allocator, io, .{ .root = "/w", .blobs = self.store.blobs(), .journal = self.store.journalPort() });
        self.history = .init(testing.allocator, self.store.recorder());
        self.sink = self.store.queueSink(self.q, &self.history, null);
        return self.store.load(self.sink.sink());
    }
    fn close(self: *Proc) void {
        self.store.close();
        self.q.deinit();
        self.history.deinit();
    }
    fn tail(self: *Proc) !u32 {
        return self.store.tail(self.sink.sink());
    }
};

fn prov(turn: u32) model.Provenance {
    return .{ .origin = .{ .agent = .{ .ref = .{ .session = 42 }, .turn = turn, .model = "m" } }, .label = "Turn", .workspace = "/w", .created_ms = 0 };
}

fn submit(q: *model.Queue, path: []const u8, base: []const u8, at: u64, text: []const u8) !model.ChangesetId {
    const b = try q.beginBatch(prov(1));
    var e: ChangeSet = try .fromEdits(testing.allocator, base.len, &.{.{ .range = .{ .start = at, .end = at }, .text = text }});
    defer e.deinit();
    try q.addEdit(b, path, base, null, &e);
    return q.commitBatch(b, .{});
}

fn snapshot(q: *model.Queue, blobs: model.Blobs, id: model.ChangesetId) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try records.writeChangeset(&aw.writer, q.get(id).?, blobs, testing.allocator);
    return aw.toOwnedSlice();
}

test "store: append/fold round trip; ids continue after reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ids: [3]model.ChangesetId = undefined;
    var snaps: [3][]u8 = undefined;
    {
        var p: Proc = undefined;
        _ = try p.open(tmp.dir, .{});
        defer p.close();
        ids[0] = try submit(p.q, "a.txt", "one\ntwo\n", 4, "1.5\n");
        const b = try p.q.beginBatch(prov(2));
        try p.q.addCreate(b, "big.txt", "y" ** (records.inline_limit + 10));
        try p.q.addDelete(b, "gone.txt", "bye\n");
        ids[1] = try p.q.commitBatch(b, .{ .checkpoint = 3 });
        ids[2] = try submit(p.q, "c.txt", "", 0, "c\n");
        p.q.getMut(ids[0]).?.files[0].hunks[0].decision = .rejected;
        p.q.persist(ids[0]);
        p.q.remove(ids[2]);
        for (ids[0..2], snaps[0..2]) |id, *s| s.* = try snapshot(p.q, p.store.blobs(), id);
        try p.store.flush();
        // Blobs are on disk: bases, the created file, the large edits.
        var n: usize = 0;
        var w = try tmp.dir.openDir(io, "review/blobs", .{ .iterate = true });
        defer w.close(io);
        var walker = try w.walk(testing.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind == .file) n += 1;
        }
        try testing.expectEqual(@as(usize, 5), n);
    }
    defer for (snaps[0..2]) |s| testing.allocator.free(s);
    var p: Proc = undefined;
    const rep = try p.open(tmp.dir, .{});
    defer p.close();
    try testing.expectEqual(@as(u32, 5), rep.records);
    try testing.expectEqual(@as(usize, 2), p.q.changesets.count());
    try testing.expect(p.q.get(ids[2]) == null);
    for (ids[0..2], snaps[0..2]) |id, s| {
        const again = try snapshot(p.q, p.store.blobs(), id);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(s, again);
    }
    try testing.expectEqual(model.Decision.rejected, p.q.get(ids[0]).?.files[0].hunks[0].decision);
    const next = try submit(p.q, "d.txt", "", 0, "d");
    try testing.expectEqual(@intFromEnum(ids[2]) + 1, @intFromEnum(next));
}

test "store: torn tail truncated at last valid CRC" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var p: Proc = undefined;
        _ = try p.open(tmp.dir, .{});
        defer p.close();
        _ = try submit(p.q, "a", "x", 0, "y");
        _ = try submit(p.q, "b", "x", 0, "y");
    }
    const name = "review/journal/00000001.zrj";
    const full = try tmp.dir.readFileAlloc(io, name, testing.allocator, .unlimited);
    defer testing.allocator.free(full);
    // Every cut inside the second frame loses only that frame.
    var r: journal.Reader = .{ .bytes = full };
    _ = r.next();
    const first_end = r.pos;
    var cut = first_end + 1;
    while (cut < full.len) : (cut += 37) {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = full[0..cut] });
        var p: Proc = undefined;
        const rep = try p.open(tmp.dir, .{});
        defer p.close();
        try testing.expectEqual(@as(u32, 1), rep.records);
        try testing.expectEqual(@as(u64, cut - first_end), rep.truncated_bytes);
        try testing.expectEqual(@as(usize, 1), p.q.changesets.count());
        const st = try tmp.dir.statFile(io, name, .{});
        try testing.expectEqual(@as(u64, first_end), st.size);
    }
}

test "store: corrupt middle segment quarantined, later segments loaded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var p: Proc = undefined;
        _ = try p.open(tmp.dir, .{ .segment_bytes = 64 });
        defer p.close();
        for (0..3) |_| {
            _ = try submit(p.q, "a", "x", 0, "y");
            try p.store.flush();
        }
    }
    // Three segments, one frame each; break the second.
    const name = "review/journal/00000002.zrj";
    const bytes = try tmp.dir.readFileAlloc(io, name, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    bytes[20] ^= 0xff;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    var p: Proc = undefined;
    const rep = try p.open(tmp.dir, .{});
    defer p.close();
    try testing.expectEqual(@as(u32, 1), rep.quarantined);
    try testing.expectEqual(@as(u32, 2), rep.records);
    try testing.expect(p.q.get(@enumFromInt(1)) != null);
    try testing.expect(p.q.get(@enumFromInt(3)) != null);
    _ = try tmp.dir.statFile(io, "review/journal/00000002.zrj.bad", .{});
}

test "store: two processes see each other's appends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: Proc = undefined;
    _ = try a.open(tmp.dir, .{});
    defer a.close();
    var b: Proc = undefined;
    _ = try b.open(tmp.dir, .{});
    defer b.close();
    try testing.expect(a.store.processTag() != b.store.processTag());

    const id = try submit(a.q, "a", "base", 4, "!");
    try a.store.flush();
    try testing.expectEqual(@as(u32, 1), try b.tail());
    try testing.expectEqualStrings("a", b.q.get(id).?.files[0].path);
    // Nothing new: nothing replayed; a's own record is not replayed to a.
    try testing.expectEqual(@as(u32, 0), try b.tail());
    try testing.expectEqual(@as(u32, 0), try a.tail());

    // b decides, a sees it; b's next id does not collide.
    b.q.getMut(id).?.files[0].hunks[0].decision = .accepted;
    b.q.persist(id);
    const id2 = try submit(b.q, "b", "", 0, "x");
    try testing.expect(id2 != id);
    b.q.remove(id);
    try b.store.flush();
    try testing.expectEqual(@as(u32, 3), try a.tail());
    try testing.expect(a.q.get(id) == null);
    try testing.expect(a.q.get(id2) != null);
}

test "store: applies and their records reach another process" {
    const apply = @import("../apply/root.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: Proc = undefined;
    _ = try a.open(tmp.dir, .{ .process_tag = 1 });
    defer a.close();
    var b: Proc = undefined;
    _ = try b.open(tmp.dir, .{ .process_tag = 2 });
    defer b.close();

    var disk: apply.MemFiles = .init(testing.allocator);
    defer disk.deinit();
    try disk.put("a.txt", "one\ntwo\n", false);
    const id = try submit(a.q, "a.txt", "one\ntwo\n", 4, "1.5\n");
    var ap: apply.Applier = .init(testing.allocator, io, a.q, disk.files(), &a.history);
    const r = try ap.acceptAll(id);
    try a.store.flush();

    try testing.expect(try b.tail() >= 2);
    try testing.expectEqual(model.State.applied, b.q.get(id).?.state);
    const rec = b.history.get(r.ok.apply.?).?;
    try testing.expectEqual(@as(?model.ChangesetId, id), rec.cs);
    try testing.expectEqualSlices(u8, &model.blobHash("one\n1.5\ntwo\n"), &rec.files[0].post.?);
    // The preimage is a blob B can read.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("one\ntwo\n", (try b.store.blobs().get(arena.allocator(), rec.files[0].pre.?)).?);
    // B's next record gets a later id.
    try testing.expect(b.history.lastId() >= rec.id);
}
