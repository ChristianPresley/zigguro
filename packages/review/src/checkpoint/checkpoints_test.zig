const std = @import("std");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const store_mod = @import("../store/root.zig");
const checkpoints_mod = @import("checkpoints.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ChangeSet = model.changeset.ChangeSet;
const ChangesetId = model.ChangesetId;
const Checkpoints = checkpoints_mod.Checkpoints;

const Fx = struct {
    blobs: model.MemBlobs,
    disk: apply.MemFiles,
    history: model.History,
    q: *model.Queue,
    ap: apply.Applier,
    cps: Checkpoints,
    arena: std.heap.ArenaAllocator,

    fn init(fx: *Fx) !void {
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .history = .init(gpa, null), .q = undefined, .ap = undefined, .cps = undefined, .arena = .init(gpa) };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs() });
        fx.ap = .init(gpa, testing.io, fx.q, fx.disk.files(), &fx.history);
        fx.cps = .init(gpa, testing.io, fx.q, &fx.history, fx.disk.files(), null);
    }

    fn deinit(fx: *Fx) void {
        fx.cps.deinit();
        fx.q.deinit();
        fx.history.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
        fx.arena.deinit();
    }

    /// Submits one whole-file edit of `path` (from what is on disk, or a
    /// create) for `session`.
    fn edit(fx: *Fx, session: u128, path: []const u8, new: []const u8) !ChangesetId {
        const b = try fx.q.beginBatch(prov(session));
        if (fx.disk.get(path)) |cur| {
            var e = try ChangeSet.fromEdits(gpa, cur.len, &.{.{ .range = .{ .start = 0, .end = cur.len }, .text = new }});
            defer e.deinit();
            try fx.q.addEdit(b, path, cur, null, &e);
        } else try fx.q.addCreate(b, path, new);
        return fx.q.commitBatch(b, .{});
    }

    fn accept(fx: *Fx, session: u128, path: []const u8, new: []const u8) !void {
        const id = try fx.edit(session, path, new);
        const r = try fx.ap.acceptAll(id);
        try testing.expect(r == .ok);
    }

    fn expectDisk(fx: *Fx, path: []const u8, want: ?[]const u8) !void {
        if (want) |w| try testing.expectEqualStrings(w, fx.disk.get(path) orelse return error.TestMissingFile) else try testing.expectEqual(@as(?[]const u8, null), fx.disk.get(path));
    }
};

fn prov(session: u128) model.Provenance {
    return .{ .origin = .{ .agent = .{ .ref = .{ .session = session }, .turn = 1, .model = "m" } }, .label = "Turn", .workspace = "/w", .created_ms = 0 };
}

const s1: u128 = 0x51;
const s2: u128 = 0x52;

test "checkpoints: create is cheap and records where history stood" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "a\n", false);
    const c1 = fx.cps.create(.{ .session = s1 }, 1, "first");
    try fx.accept(s1, "a.txt", "A\n");
    const c2 = Checkpoints.createErased(&fx.cps, testing.io, .{ .session = s1, .agent = 1 }, 2, "second");
    try testing.expect(c2 > c1);
    const a = fx.cps.get(c1).?;
    const b = fx.cps.get(c2).?;
    try testing.expectEqual(@as(u64, 0), a.after_apply);
    try testing.expectEqual(@as(u64, 1), b.after_apply);
    try testing.expectEqual(a.next_changeset + 1, b.next_changeset);
    try testing.expectEqualStrings("second", b.label);
    try testing.expectEqual(@as(u32, 1), b.agent);

    const t0 = std.Io.Clock.awake.now(testing.io);
    for (0..1000) |i| _ = fx.cps.create(.{ .session = s2 }, @intCast(i), "turn");
    const ns = t0.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds;
    try testing.expect(@divFloor(ns, 1000) < std.time.ns_per_ms);
    var list: std.ArrayList(model.Checkpoint) = .empty;
    defer list.deinit(gpa);
    try fx.cps.listSession(s1, &list, gpa);
    try testing.expectEqual(@as(usize, 2), list.items.len);
}

test "checkpoints: restore reverts later applies, keeps the user's edit, closes later changesets" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "one\ntwo\nthree\nfour\n", false);
    try fx.disk.put("b.txt", "bee\n", false);
    const cp = fx.cps.create(.{ .session = s1 }, 1, "turn 1");
    try fx.accept(s1, "a.txt", "ONE\ntwo\nthree\nfour\n");
    try fx.accept(s1, "a.txt", "ONE\nTWO\nthree\nfour\n");
    try fx.accept(s1, "b.txt", "BEE\n");
    try fx.accept(s1, "new.txt", "made\n");
    // The user edits a line the agent did not touch.
    try fx.disk.put("a.txt", "ONE\nTWO\nthree\nfour!\n", false);
    const open = try fx.edit(s1, "b.txt", "bee bee\n");
    const other = try fx.edit(s2, "b.txt", "other\n");

    const a = fx.arena.allocator();
    const dry = try fx.cps.restoreTo(a, cp, .{ .dry_run = true });
    try testing.expectEqual(@as(usize, 3), dry.restored.len);
    try testing.expectEqual(@as(usize, 1), dry.discarded.len);
    try fx.expectDisk("new.txt", "made\n");
    try testing.expectEqual(model.State.pending, fx.q.get(open).?.state);

    const r = try fx.cps.restoreTo(a, cp, .{});
    try testing.expectEqual(@as(usize, 0), r.conflicts.len);
    try fx.expectDisk("a.txt", "one\ntwo\nthree\nfour!\n");
    try fx.expectDisk("b.txt", "bee\n");
    try fx.expectDisk("new.txt", null);
    try testing.expectEqual(model.State.discarded, fx.q.get(open).?.state);
    try testing.expectEqual(model.State.pending, fx.q.get(other).?.state);
    try testing.expectEqual(model.ApplyKind.restore, fx.history.get(r.record.?).?.kind);
    // Restoring again finds nothing left to do.
    const again = try fx.cps.restoreTo(a, cp, .{});
    try testing.expectEqual(@as(usize, 0), again.restored.len);
    try testing.expectError(error.UnknownCheckpoint, fx.cps.restoreTo(a, 999, .{}));
}

test "checkpoints: redo reverses a restore, keeps later edits and revives what it closed" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "one\n.\ntwo\n.\nthree\n", false);
    const cp = fx.cps.create(.{ .session = s1 }, 1, "turn 1");
    try fx.accept(s1, "a.txt", "ONE\n.\ntwo\n.\nthree\n");
    try fx.accept(s1, "new.txt", "made\n");
    const open = try fx.edit(s1, "a.txt", "ONE\n.\ntwo\n.\nTHREE\n");
    const a = fx.arena.allocator();
    const r = try fx.cps.restoreTo(a, cp, .{});
    try fx.expectDisk("a.txt", "one\n.\ntwo\n.\nthree\n");
    try testing.expectEqual(model.State.discarded, fx.q.get(open).?.state);

    // The user edits another line after the restore.
    try fx.disk.put("a.txt", "one\n.\nTwo\n.\nthree\n", false);
    const dry = try fx.cps.redo(a, r.record.?, .{ .dry_run = true });
    try testing.expectEqual(@as(usize, 2), dry.restored.len);
    try testing.expectEqual(@as(usize, 1), dry.revived.len);
    try fx.expectDisk("new.txt", null);

    const rd = try fx.cps.redo(a, r.record.?, .{});
    try testing.expectEqual(@as(usize, 0), rd.conflicts.len);
    try fx.expectDisk("a.txt", "ONE\n.\nTwo\n.\nthree\n");
    try fx.expectDisk("new.txt", "made\n");
    try testing.expectEqual(model.State.pending, fx.q.get(open).?.state);
    try testing.expectEqual(r.record.?, fx.history.get(rd.record.?).?.undoes.?);
    try testing.expectError(error.AlreadyRedone, fx.cps.redo(a, r.record.?, .{}));
    try testing.expectError(error.NotARestore, fx.cps.redo(a, 1, .{}));
    try testing.expectError(error.UnknownRestore, fx.cps.redo(a, 999, .{}));

    // The redone applies count again: restoring the checkpoint reverts them.
    const again = try fx.cps.restoreTo(a, cp, .{});
    try testing.expectEqual(@as(usize, 2), again.restored.len);
    try fx.expectDisk("a.txt", "one\n.\nTwo\n.\nthree\n");
}

test "checkpoints: a restore that only closes changesets is recorded and redoable" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "a\n", false);
    const cp = fx.cps.create(.{ .session = s1 }, 1, "");
    const open = try fx.edit(s1, "a.txt", "A\n");
    const a = fx.arena.allocator();
    const r = try fx.cps.restoreTo(a, cp, .{});
    try testing.expectEqual(@as(usize, 0), r.restored.len);
    try testing.expectEqual(@as(usize, 1), fx.history.get(r.record.?).?.closed.len);
    // Redo gives it back.
    const rd = try fx.cps.redo(a, r.record.?, .{});
    try testing.expectEqual(@as(usize, 1), rd.revived.len);
    try testing.expectEqual(model.State.pending, fx.q.get(open).?.state);
}

test "checkpoints: conflicts are reported and left alone; scope picks the sessions" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "a\nb\n", false);
    const cp = fx.cps.create(.{ .session = s1 }, 1, "");
    try fx.accept(s1, "a.txt", "A\nb\n");
    try fx.accept(s1, "made.txt", "x\n");
    try fx.accept(s2, "theirs.txt", "y\n");
    try fx.disk.put("a.txt", "A?\nb\n", false);
    try fx.disk.put("made.txt", "x edited\n", false);
    const a = fx.arena.allocator();
    const r = try fx.cps.restoreTo(a, cp, .{});
    try testing.expectEqual(@as(usize, 2), r.conflicts.len);
    try testing.expectEqual(@as(usize, 0), r.restored.len);
    try testing.expectEqual(@as(?u64, null), r.record);
    try fx.expectDisk("a.txt", "A?\nb\n");
    try fx.expectDisk("theirs.txt", "y\n");
    const all = try fx.cps.restoreTo(a, cp, .{ .scope = .all_agents });
    try testing.expectEqual(@as(usize, 1), all.restored.len);
    try fx.expectDisk("theirs.txt", null);
}

test "checkpoints: a failed restore is rolled back" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "a\n", false);
    try fx.disk.put("b.txt", "b\n", false);
    const cp = fx.cps.create(.{ .session = s1 }, 1, "");
    try fx.accept(s1, "a.txt", "A\n");
    try fx.accept(s1, "b.txt", "B\n");
    const open = try fx.edit(s1, "a.txt", "AA\n");
    fx.disk.fail_at = fx.disk.mutations + 1;
    const r = try fx.cps.restoreTo(fx.arena.allocator(), cp, .{});
    try testing.expect(r.failed.?.rolled_back);
    try fx.expectDisk("a.txt", "A\n");
    try fx.expectDisk("b.txt", "B\n");
    try testing.expectEqual(model.State.pending, fx.q.get(open).?.state);
    try testing.expectEqual(@as(usize, 2), fx.history.items().len);
}

test "checkpoints: journaled and replayed by another process" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const Proc = struct {
        store: *store_mod.ChangesetStore,
        q: *model.Queue,
        history: model.History,
        cps: Checkpoints,
        disk: apply.MemFiles,
        sink: store_mod.store.QueueSink,

        fn open(p: *@This(), dir: std.Io.Dir, tag: u32) !void {
            p.store = try .open(gpa, testing.io, dir, "review", .{ .process_tag = tag });
            p.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = p.store.blobs(), .journal = p.store.journalPort() });
            p.history = .init(gpa, p.store.recorder());
            p.disk = .init(gpa);
            p.cps = .init(gpa, testing.io, p.q, &p.history, p.disk.files(), p.store.checkpointRecorder());
            p.sink = p.store.queueSink(p.q, &p.history, p.cps.sink());
            _ = try p.store.load(p.sink.sink());
        }
        fn close(p: *@This()) void {
            p.store.close();
            p.cps.deinit();
            p.q.deinit();
            p.history.deinit();
            p.disk.deinit();
        }
    };
    var a: Proc = undefined;
    try a.open(tmp.dir, 1);
    defer a.close();
    var b: Proc = undefined;
    try b.open(tmp.dir, 2);
    defer b.close();
    const id = a.cps.create(.{ .session = s1, .agent = 3 }, 4, "Turn 4: refactor");
    try a.store.flush();
    _ = try b.store.tail(b.sink.sink());
    const got = b.cps.get(id).?;
    try testing.expectEqualStrings("Turn 4: refactor", got.label);
    try testing.expectEqual(@as(u32, 3), got.agent);
    try testing.expect(b.cps.create(.{ .session = s2 }, 1, "") > id);
}

test "checkpoints: random agent applies and user edits on other lines restore exactly" {
    var prng: std.Random.DefaultPrng = .init(0xc4ec);
    const rnd = prng.random();
    for (0..40) |_| {
        var fx: Fx = undefined;
        try fx.init();
        defer fx.deinit();
        const n = 24;
        var lines: [n][]const u8 = undefined;
        var want: [n][]const u8 = undefined;
        const a = fx.arena.allocator();
        for (&lines, &want, 0..) |*l, *w, i| {
            l.* = try std.fmt.allocPrint(a, "line {d}\n", .{i});
            w.* = l.*;
        }
        try fx.disk.put("f.txt", try std.mem.concat(a, u8, &lines), false);
        const cp = fx.cps.create(.{ .session = s1 }, 1, "");
        // Agent turns edit lines 0 mod 4, the user lines 2 mod 4, interleaved.
        for (0..4) |round| {
            for (&lines, 0..) |*l, i| if (i % 4 == 0 and rnd.boolean()) {
                l.* = try std.fmt.allocPrint(a, "agent {d} {d}\n", .{ round, i });
            };
            try fx.accept(s1, "f.txt", try std.mem.concat(a, u8, &lines));
            for (&lines, &want, 0..) |*l, *w, i| if (i % 4 == 2 and rnd.uintLessThan(u8, 4) == 0) {
                l.* = try std.fmt.allocPrint(a, "user {d} {d}\n", .{ round, i });
                w.* = l.*;
            };
            try fx.disk.put("f.txt", try std.mem.concat(a, u8, &lines), false);
        }
        const before = try std.mem.concat(a, u8, &lines);
        const r = try fx.cps.restoreTo(a, cp, .{});
        try testing.expectEqual(@as(usize, 0), r.conflicts.len);
        try fx.expectDisk("f.txt", try std.mem.concat(a, u8, &want));
        // Redo right away gives back exactly what was there.
        if (r.record) |id| {
            const rd = try fx.cps.redo(a, id, .{});
            try testing.expectEqual(@as(usize, 0), rd.conflicts.len);
        }
        try fx.expectDisk("f.txt", before);
    }
}
