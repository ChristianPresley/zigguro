const std = @import("std");
const queue_mod = @import("queue.zig");
const changeset = @import("changeset.zig");
const blobs_mod = @import("blobs.zig");
const provenance = @import("provenance.zig");

const testing = std.testing;
const Queue = queue_mod.Queue;
const ChangeSet = changeset.ChangeSet;
const ChangesetId = @import("ids.zig").ChangesetId;

const Fx = struct {
    blobs: blobs_mod.MemBlobs,
    q: *Queue,
    log: std.ArrayList(queue_mod.Event) = .empty,

    fn init(self: *Fx) !void {
        self.* = .{ .blobs = .init(testing.allocator), .q = undefined };
        self.q = try Queue.init(testing.allocator, testing.io, .{ .root = "/w", .blobs = self.blobs.blobs() });
        _ = try self.q.subscribe(.{ .ctx = self, .on = record });
    }
    fn deinit(self: *Fx) void {
        self.q.deinit();
        self.blobs.deinit();
        self.log.deinit(testing.allocator);
    }
    fn record(ctx: *anyopaque, ev: *const queue_mod.Event) void {
        const self: *Fx = @ptrCast(@alignCast(ctx));
        self.log.append(testing.allocator, ev.*) catch unreachable;
    }
};

fn agentProv(session: u128, turn: u32) provenance.Provenance {
    return .{
        .origin = .{ .agent = .{ .ref = .{ .session = session }, .turn = turn, .model = "m" } },
        .label = "Turn",
        .tool_calls = &.{"t1"},
        .workspace = "/w",
        .created_ms = 0,
    };
}

fn cs1(base_len: u64, s: u64, e: u64, t: []const u8) !ChangeSet {
    return ChangeSet.fromEdits(testing.allocator, base_len, &.{.{ .range = .{ .start = s, .end = e }, .text = t }});
}

fn newText(q: *Queue, id: ChangesetId, file: usize, base: []const u8) ![]u8 {
    const f = q.get(id).?.files[file];
    return f.content.text.edits.applyToSlice(testing.allocator, base);
}

test "queue: batch of 3 edits on 2 files → 1 changeset, 2 files" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const q = fx.q;
    const a = "one\ntwo\nthree\n";
    const b = "alpha\nbeta\n";
    const bid = try q.beginBatch(agentProv(7, 3));
    var e1 = try cs1(a.len, 0, 3, "ONE");
    defer e1.deinit();
    try q.addEdit(bid, "/w/src/a.txt", a, 4, &e1);
    var e2 = try cs1(a.len, 8, 13, "THREE");
    defer e2.deinit();
    try q.addEdit(bid, "src/a.txt", "ONE\ntwo\nthree\n", null, &e2);
    var e3 = try cs1(b.len, 6, 6, "gamma\n");
    defer e3.deinit();
    try q.addEdit(bid, "src/b.txt", b, null, &e3);
    const id = try q.commitBatch(bid, .{});

    const cs = q.get(id).?;
    try testing.expectEqual(changeset.State.pending, cs.state);
    try testing.expectEqual(@as(usize, 2), cs.files.len);
    try testing.expectEqualStrings("src/a.txt", cs.files[0].path);
    try testing.expectEqual(@as(usize, 2), cs.files[0].hunks.len);
    try testing.expectEqual(@as(?u64, 4), cs.files[0].content.text.base.?.doc_version);
    const at = try newText(q, id, 0, a);
    defer testing.allocator.free(at);
    try testing.expectEqualStrings("ONE\ntwo\nTHREE\n", at);
    try testing.expectEqual(@as(u32, 1), cs.files[1].countLines().added);
    try testing.expectEqualStrings("t1", cs.prov.tool_calls[0]);
    // Bases are in the blob store.
    try testing.expectEqual(@as(usize, 2), fx.blobs.count());
    try testing.expectEqual(@as(usize, 1), fx.log.items.len);
    try testing.expectEqual(id, fx.log.items[0].submitted);
}

test "queue: create, delete, rename and mode changes" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const q = fx.q;
    const bid = try q.beginBatch(agentProv(1, 1));
    try q.addCreate(bid, "new.sh", "#!/bin/sh\necho\n");
    try q.setExecutable(bid, "new.sh", true);
    try q.addDelete(bid, "old.txt", "bye\n");
    try q.addRename(bid, "x.txt", "y.txt");
    try q.setExecutable(bid, "run", true);
    const id = try q.commitBatch(bid, .{ .presentation = .preview, .checkpoint = 9 });
    const cs = q.get(id).?;
    try testing.expectEqual(changeset.Presentation.preview, cs.presentation);
    try testing.expectEqual(@as(?u64, 9), cs.checkpoint);
    try testing.expect(cs.files[0].op.create.executable);
    try testing.expectEqual(@as(usize, 1), cs.files[0].hunks.len);
    try testing.expectEqual(@as(u32, 2), cs.files[0].hunks[0].new_lines.count);
    try testing.expect(cs.files[1].op == .delete);
    try testing.expectEqual(@as(u64, 4), cs.files[1].base.?.size);
    try testing.expectEqualStrings("x.txt", cs.files[2].op.rename.from);
    try testing.expect(cs.files[2].content == .none);
    try testing.expect(cs.files[3].op.set_executable);
}

test "queue: auto_apply without policy hook stays pending" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const bid = try fx.q.beginBatch(agentProv(1, 1));
    try fx.q.addCreate(bid, "a", "x");
    const id = try fx.q.commitBatch(bid, .{ .auto_apply = true });
    try testing.expectEqual(changeset.State.pending, fx.q.get(id).?.state);
    try testing.expect(!fx.q.get(id).?.auto_applied);
}

test "queue: fold same-session pending edits; different sessions do not fold" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const q = fx.q;
    const base = "a\nb\nc\nd\ne\n";
    // Turn 1 changes line a.
    const b1 = try q.beginBatch(agentProv(5, 1));
    var e1 = try cs1(base.len, 0, 1, "A");
    defer e1.deinit();
    try q.addEdit(b1, "f", base, null, &e1);
    const id1 = try q.commitBatch(b1, .{});
    // Turn 2 of the same session edits its own pending text.
    const b2 = try q.beginBatch(agentProv(5, 2));
    const viewed = "A\nb\nc\nd\ne\n";
    var e2 = try cs1(viewed.len, 8, 9, "E");
    defer e2.deinit();
    try q.addEdit(b2, "f", viewed, null, &e2);
    try q.addCreate(b2, "g", "g\n");
    const id2 = try q.commitBatch(b2, .{});

    const c1 = q.get(id1).?;
    try testing.expectEqual(@as(usize, 2), c1.files[0].hunks.len);
    try testing.expectEqual(id2, c1.files[0].folded_from[0]);
    const t = try newText(q, id1, 0, base);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("A\nb\nc\nd\nE\n", t);
    const c2 = q.get(id2).?;
    try testing.expectEqual(changeset.FileState.superseded, c2.files[0].state);
    try testing.expectEqual(changeset.State.pending, c2.state);
    try testing.expectEqual(queue_mod.Event{ .updated = id1 }, fx.log.items[1]);

    // Another session editing the same viewed text does not fold.
    const b3 = try q.beginBatch(agentProv(6, 1));
    var e3 = try cs1(viewed.len, 2, 3, "B");
    defer e3.deinit();
    try q.addEdit(b3, "f", viewed, null, &e3);
    const id3 = try q.commitBatch(b3, .{});
    try testing.expectEqual(changeset.FileState.pending, q.get(id3).?.files[0].state);
    try testing.expectEqual(@as(usize, 1), q.get(id1).?.files[0].folded_from.len);

    // An edit against the disk text (not the pending one) does not fold.
    const b4 = try q.beginBatch(agentProv(5, 3));
    var e4 = try cs1(base.len, 2, 3, "B");
    defer e4.deinit();
    try q.addEdit(b4, "f", base, null, &e4);
    const id4 = try q.commitBatch(b4, .{});
    try testing.expectEqual(changeset.FileState.pending, q.get(id4).?.files[0].state);

    // A changeset whose every file folded is superseded.
    const b5 = try q.beginBatch(agentProv(5, 4));
    const viewed2 = "A\nb\nc\nd\nE\n";
    var e5 = try cs1(viewed2.len, 4, 5, "C");
    defer e5.deinit();
    try q.addEdit(b5, "f", viewed2, null, &e5);
    const id5 = try q.commitBatch(b5, .{});
    try testing.expectEqual(changeset.State.superseded, q.get(id5).?.state);

    var open: std.ArrayList(ChangesetId) = .empty;
    defer open.deinit(testing.allocator);
    try q.list(.{ .open_only = true, .session = 5 }, &open, testing.allocator);
    try testing.expectEqualSlices(ChangesetId, &.{ id1, id2, id4 }, open.items);
}

test "queue: folding re-derives hunks and keeps their keys" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const q = fx.q;
    const base = "a\nb\nc\n";
    const b1 = try q.beginBatch(agentProv(5, 1));
    var e1 = try cs1(base.len, 0, 1, "A");
    defer e1.deinit();
    try q.addEdit(b1, "f", base, null, &e1);
    const id1 = try q.commitBatch(b1, .{});
    const key = q.get(id1).?.files[0].hunks[0].key;
    const b2 = try q.beginBatch(agentProv(5, 2));
    var e2 = try cs1(base.len, 4, 5, "C");
    defer e2.deinit();
    try q.addEdit(b2, "f", "A\nb\nc\n", null, &e2);
    _ = try q.commitBatch(b2, .{});
    const hs = q.get(id1).?.files[0].hunks;
    try testing.expectEqual(@as(usize, 2), hs.len);
    try testing.expectEqual(key, hs[0].key);
}

test "queue: commitBatch from 8 threads concurrently → ids unique, all visible after drain" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const Wk = struct {
        var wakes: std.atomic.Value(u32) = .init(0);
        fn wake(_: *anyopaque) void {
            _ = wakes.fetchAdd(1, .monotonic);
        }
        fn run(s: *queue_mod.Submitter, t: usize, out: []ChangesetId) void {
            for (out, 0..) |*o, i| {
                const b = s.beginBatch(agentProv(100 + t, @intCast(i))) catch unreachable;
                var name: [16]u8 = undefined;
                s.addCreate(b, std.fmt.bufPrint(&name, "t{d}/{d}", .{ t, i }) catch unreachable, "x") catch unreachable;
                o.* = s.commitBatch(b) catch unreachable;
            }
        }
    };
    fx.q.wake = .{ .ctx = undefined, .wake = Wk.wake };
    var ids: [8][20]ChangesetId = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Wk.run, .{ fx.q.submitter(), t, &ids[t] });
    for (threads) |th| th.join();
    try testing.expectEqual(@as(u32, 160), Wk.wakes.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), fx.q.changesets.count());
    fx.q.drain();
    try testing.expectEqual(@as(usize, 160), fx.q.changesets.count());
    var seen: std.AutoHashMapUnmanaged(ChangesetId, void) = .empty;
    defer seen.deinit(testing.allocator);
    for (ids) |row| for (row) |id| {
        try testing.expect(!seen.contains(id));
        try seen.put(testing.allocator, id, {});
        try testing.expect(fx.q.get(id) != null);
    };
}

test "queue: abort and unknown batches" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const b = try fx.q.beginBatch(agentProv(1, 1));
    try fx.q.addCreate(b, "a", "x");
    fx.q.abortBatch(b);
    try testing.expectError(error.UnknownBatch, fx.q.addCreate(b, "b", "y"));
    try testing.expectError(error.UnknownBatch, fx.q.commitBatch(b, .{}));
    try testing.expectError(error.PathOutsideWorkspace, blk: {
        const c = try fx.q.beginBatch(agentProv(1, 1));
        defer fx.q.abortBatch(c);
        break :blk fx.q.addCreate(c, "../x", "y");
    });
}
