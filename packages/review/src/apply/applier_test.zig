const std = @import("std");
const model = @import("../model/root.zig");
const files_mod = @import("files.zig");
const applier_mod = @import("applier.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ChangeSet = model.changeset.ChangeSet;
const ChangesetId = model.ChangesetId;
const Applier = applier_mod.Applier;

const Fx = struct {
    blobs: model.MemBlobs,
    disk: files_mod.MemFiles,
    history: model.History,
    q: *model.Queue,
    ap: Applier,
    events: std.ArrayList(model.Event) = .empty,

    fn init(fx: *Fx) !void {
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .history = .init(gpa, null), .q = undefined, .ap = undefined };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs(), .hunk_options = .{ .merge_gap_lines = 0 } });
        fx.ap = .init(gpa, testing.io, fx.q, fx.disk.files(), &fx.history);
        _ = try fx.q.subscribe(.{ .ctx = fx, .on = onEvent });
    }

    fn deinit(fx: *Fx) void {
        fx.q.deinit();
        fx.history.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
        fx.events.deinit(gpa);
    }

    fn onEvent(ctx: *anyopaque, ev: *const model.Event) void {
        const fx: *Fx = @ptrCast(@alignCast(ctx));
        fx.events.append(gpa, ev.*) catch unreachable;
    }

    fn cs(fx: *Fx, id: ChangesetId) *const model.Changeset {
        return fx.q.get(id).?;
    }

    fn expectDisk(fx: *Fx, path: []const u8, want: ?[]const u8) !void {
        if (want) |w| try testing.expectEqualStrings(w, fx.disk.get(path) orelse return error.TestMissingFile) else try testing.expectEqual(@as(?[]const u8, null), fx.disk.get(path));
    }
};

fn prov() model.Provenance {
    return .{
        .origin = .{ .agent = .{ .ref = .{ .session = 9 }, .turn = 1, .model = "m" } },
        .label = "Turn 1",
        .workspace = "/w",
        .created_ms = 0,
    };
}

fn edit(base: []const u8, reps: []const model.changeset.Replace) !ChangeSet {
    return ChangeSet.fromEdits(gpa, base.len, reps);
}

const three = "a\n.\nb\n.\nc\n";

/// One file with three one-line hunks (a→A, b→B, c→C).
fn threeHunks(fx: *Fx) !ChangesetId {
    try fx.disk.put("f.txt", three, false);
    var e = try edit(three, &.{
        .{ .range = .{ .start = 0, .end = 1 }, .text = "A" },
        .{ .range = .{ .start = 4, .end = 5 }, .text = "B" },
        .{ .range = .{ .start = 8, .end = 9 }, .text = "C" },
    });
    defer e.deinit();
    const b = try fx.q.beginBatch(prov());
    try fx.q.addEdit(b, "f.txt", three, null, &e);
    return fx.q.commitBatch(b, .{});
}

test "applier: accept 2 of 3 hunks writes base∘selected, the rest stays pending on the new text" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try threeHunks(&fx);
    try testing.expectEqual(@as(usize, 3), fx.cs(id).files[0].hunks.len);

    const r = try fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 0, .input = .{ .accept = &.{ 0, 2 } } }} });
    try testing.expectEqual(@as(u32, 2), r.ok.hunks);
    try fx.expectDisk("f.txt", "A\n.\nb\n.\nC\n");
    const f = fx.cs(id).files[0];
    try testing.expectEqual(model.FileState.partially_applied, f.state);
    try testing.expectEqual(model.State.partially_applied, fx.cs(id).state);
    try testing.expectEqual(@as(usize, 1), f.hunks.len);
    try testing.expectEqual(@as(u32, 2), f.hunks[0].base_lines.start);
    try testing.expectEqualSlices(u8, &model.blobHash("A\n.\nb\n.\nC\n"), &f.content.text.base.?.hash);
    const rec = fx.history.get(r.ok.apply.?).?;
    try testing.expectEqualSlices(u8, &model.blobHash(three), &rec.files[0].pre.?);
    try testing.expectEqual(@as(?u128, 9), rec.session);
    // The preimage is in the blob store for undo and checkpoints.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqualStrings(three, (try fx.blobs.blobs().get(arena.allocator(), rec.files[0].pre.?)).?);

    const r2 = try fx.ap.acceptAll(id);
    try testing.expectEqual(@as(u32, 1), r2.ok.hunks);
    try fx.expectDisk("f.txt", "A\n.\nB\n.\nC\n");
    try testing.expectEqual(model.FileState.applied, fx.cs(id).files[0].state);
    try testing.expectEqual(model.State.applied, fx.cs(id).state);
    try testing.expect(fx.cs(id).decided_ms != null);
    try testing.expectEqual(@as(usize, 2), fx.history.items().len);
    try testing.expectError(error.NotOpen, fx.ap.acceptAll(id));
    var applied: u32 = 0;
    for (fx.events.items) |ev| if (ev == .applied) {
        applied += 1;
    };
    try testing.expectEqual(@as(u32, 2), applied);
}

test "applier: edited hunk lands the reviewer's text" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try threeHunks(&fx);
    _ = try fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 0, .input = .{ .reject = &.{ 0, 2 }, .edited = &.{.{ .hunk = 1, .text = "beta\n" }} } }} });
    try fx.expectDisk("f.txt", "a\n.\nbeta\n.\nc\n");
    try testing.expectEqual(model.State.applied, fx.cs(id).state);
}

test "applier: rejecting everything writes nothing and records no apply" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try threeHunks(&fx);
    const r = try fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 0, .whole_file = .reject }} });
    try testing.expectEqual(@as(?u64, null), r.ok.apply);
    try fx.expectDisk("f.txt", three);
    try testing.expectEqual(model.State.rejected, fx.cs(id).state);
    try testing.expectEqual(@as(usize, 0), fx.history.items().len);
    try testing.expectEqual(@as(u32, 0), fx.disk.mutations);
}

test "applier: base moved fails before writing" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try threeHunks(&fx);
    try fx.disk.put("f.txt", "a\nb\n", false);
    try testing.expectError(error.BaseMoved, fx.ap.acceptAll(id));
    try fx.expectDisk("f.txt", "a\nb\n");
    try testing.expectEqual(model.State.pending, fx.cs(id).state);
    try testing.expectEqual(@as(u32, 0), fx.disk.mutations);
}

test "applier: requests are checked" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try threeHunks(&fx);
    try testing.expectError(error.UnknownChangeset, fx.ap.acceptAll(@enumFromInt(99)));
    try testing.expectError(error.UnknownFile, fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 1 }} }));
    try testing.expectError(error.DuplicateItem, fx.ap.apply(.{ .cs = id, .items = &.{ .{ .file = 0 }, .{ .file = 0 } } }));
    try testing.expectError(error.UnknownHunk, fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 0, .input = .{ .accept = &.{3} } }} }));
}

/// A changeset touching five files: modify, create, delete, rename and a
/// mode change.
fn mixed(fx: *Fx) !ChangesetId {
    try fx.disk.put("m.txt", "one\ntwo\n", false);
    try fx.disk.put("d.txt", "gone\n", false);
    try fx.disk.put("old.txt", "moved\n", true);
    try fx.disk.put("run.sh", "echo\n", false);
    var e = try edit("one\ntwo\n", &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "ONE" }});
    defer e.deinit();
    const b = try fx.q.beginBatch(prov());
    try fx.q.addEdit(b, "m.txt", "one\ntwo\n", null, &e);
    try fx.q.addCreate(b, "new/c.txt", "created\n");
    try fx.q.addDelete(b, "d.txt", "gone\n");
    try fx.q.addRename(b, "old.txt", "renamed.txt");
    try fx.q.setExecutable(b, "run.sh", true);
    return fx.q.commitBatch(b, .{});
}

const Snapshot = struct {
    const paths = [_][]const u8{ "m.txt", "new/c.txt", "d.txt", "old.txt", "renamed.txt", "run.sh" };

    fn take(fx: *Fx, out: *[paths.len]?[]const u8, exec: *[paths.len]bool) void {
        for (paths, out, exec) |p, *o, *x| {
            o.* = fx.disk.get(p);
            x.* = fx.disk.isExec(p);
        }
    }
};

test "applier: accept-all across modify, create, delete, rename and mode is atomic" {
    // Fail each mutation in turn: everything is rolled back.
    var k: u32 = 0;
    while (true) : (k += 1) {
        var fx: Fx = undefined;
        try fx.init();
        defer fx.deinit();
        const id = try mixed(&fx);
        var before: [Snapshot.paths.len]?[]const u8 = undefined;
        var bx: [Snapshot.paths.len]bool = undefined;
        Snapshot.take(&fx, &before, &bx);
        var copies: [Snapshot.paths.len]?[]u8 = undefined;
        for (before, &copies) |b, *c| c.* = if (b) |x| try gpa.dupe(u8, x) else null;
        defer for (copies) |c| if (c) |x| gpa.free(x);

        fx.disk.fail_at = k;
        const r = try fx.ap.acceptAll(id);
        if (r == .ok) {
            // Past the last mutation: the run without a fault.
            try testing.expect(k > 0);
            try fx.expectDisk("m.txt", "ONE\ntwo\n");
            try fx.expectDisk("new/c.txt", "created\n");
            try fx.expectDisk("d.txt", null);
            try fx.expectDisk("old.txt", null);
            try fx.expectDisk("renamed.txt", "moved\n");
            try testing.expect(fx.disk.isExec("renamed.txt"));
            try testing.expect(fx.disk.isExec("run.sh"));
            try testing.expectEqual(model.State.applied, fx.cs(id).state);
            const rec = fx.history.items()[0];
            try testing.expectEqual(@as(usize, 6), rec.files.len);
            break;
        }
        try testing.expect(r.failed.rolled_back);
        try testing.expectEqual(error.InjectedFault, r.failed.err);
        var after: [Snapshot.paths.len]?[]const u8 = undefined;
        var ax: [Snapshot.paths.len]bool = undefined;
        Snapshot.take(&fx, &after, &ax);
        for (copies, after) |b, a| {
            if (b) |x| try testing.expectEqualStrings(x, a.?) else try testing.expectEqual(@as(?[]const u8, null), a);
        }
        try testing.expectEqualSlices(bool, &bx, &ax);
        try testing.expectEqual(model.State.pending, fx.cs(id).state);
        try testing.expectEqual(@as(usize, 0), fx.history.items().len);
    }
}

test "applier: files without hunks need a whole-file decision; rename target must be free" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try mixed(&fx);
    try testing.expectError(error.DecisionNeeded, fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 2 }} }));
    try fx.disk.put("renamed.txt", "in the way\n", false);
    try testing.expectError(error.TargetExists, fx.ap.acceptAll(id));
    // Reject the rename, take the rest.
    const r = try fx.ap.apply(.{ .cs = id, .items = &.{
        .{ .file = 0, .whole_file = .accept },
        .{ .file = 1, .whole_file = .accept },
        .{ .file = 2, .whole_file = .reject },
        .{ .file = 3, .whole_file = .reject },
    } });
    try testing.expectEqual(@as(u32, 4), r.ok.files);
    try fx.expectDisk("d.txt", "gone\n");
    try fx.expectDisk("old.txt", "moved\n");
    try testing.expectEqual(model.State.partially_applied, fx.cs(id).state);
    _ = try fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 4, .whole_file = .reject }} });
    try testing.expectEqual(model.State.applied, fx.cs(id).state);
}

test "applier: through DirFiles on a real directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_files: files_mod.DirFiles = .{ .dir = tmp.dir, .io = testing.io };
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    fx.ap.files = dir_files.files();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = three });
    var e = try edit(three, &.{.{ .range = .{ .start = 4, .end = 5 }, .text = "B" }});
    defer e.deinit();
    const b = try fx.q.beginBatch(prov());
    try fx.q.addEdit(b, "f.txt", three, null, &e);
    try fx.q.addCreate(b, "sub/dir/n.txt", "new\n");
    const id = try fx.q.commitBatch(b, .{});
    _ = try fx.ap.acceptAll(id);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("a\n.\nB\n.\nc\n", try tmp.dir.readFile(testing.io, "f.txt", &buf));
    try testing.expectEqualStrings("new\n", try tmp.dir.readFile(testing.io, "sub/dir/n.txt", &buf));
}

test "applier: undo accept keeps a later user edit and reopens the hunks" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try threeHunks(&fx);
    const r = try fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 0, .input = .{ .accept = &.{0}, .reject = &.{2} } }} });
    try fx.expectDisk("f.txt", "A\n.\nb\n.\nc\n");
    try fx.disk.put("f.txt", "A\nuser\nb\n.\nc\n", false);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const u = try fx.ap.undoApply(arena.allocator(), r.ok.apply.?);
    try fx.expectDisk("f.txt", "a\nuser\nb\n.\nc\n");
    try testing.expect(fx.history.undone(r.ok.apply.?));
    try testing.expectEqual(model.ApplyKind.undo, fx.history.get(u.ok).?.kind);
    try testing.expectEqual(@as(?*const model.Apply, null), fx.history.lastApplyOf(id));
    const f = fx.cs(id).files[0];
    try testing.expectEqual(model.State.pending, fx.cs(id).state);
    try testing.expectEqual(model.FileState.pending, f.state);
    // Hunk 0 is back; the rejected hunk 2 stays dropped.
    try testing.expectEqual(@as(usize, 2), f.hunks.len);
    for (f.hunks) |h| try testing.expectEqual(model.Decision.undecided, h.decision);
    try testing.expectEqualSlices(u8, &model.blobHash(three), &f.content.text.base.?.hash);
    const want = try f.content.text.edits.applyToSlice(gpa, three);
    defer gpa.free(want);
    try testing.expectEqualStrings("A\n.\nB\n.\nc\n", want);
    try testing.expectError(error.AlreadyUndone, fx.ap.undoApply(arena.allocator(), r.ok.apply.?));
}

test "applier: undo accept reports overlapping edits and writes nothing" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try threeHunks(&fx);
    const r = try fx.ap.acceptAll(id);
    try fx.disk.put("f.txt", "A!\n.\nB\n.\nC\n", false);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const before = fx.disk.mutations;
    const u = try fx.ap.undoApply(arena.allocator(), r.ok.apply.?);
    try testing.expectEqual(@as(usize, 1), u.conflicts.len);
    try testing.expectEqual(@as(u32, 1), u.conflicts[0].regions);
    try testing.expectEqual(before, fx.disk.mutations);
    try testing.expectEqual(model.State.applied, fx.cs(id).state);
}

test "applier: only the newest apply of a changeset can be undone" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try threeHunks(&fx);
    const r1 = try fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 0, .input = .{ .accept = &.{0} } }} });
    const r2 = try fx.ap.acceptAll(id);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectError(error.NotLatest, fx.ap.undoApply(arena.allocator(), r1.ok.apply.?));
    _ = try fx.ap.undoApply(arena.allocator(), r2.ok.apply.?);
    try fx.expectDisk("f.txt", "A\n.\nb\n.\nc\n");
    try testing.expectEqual(model.State.partially_applied, fx.cs(id).state);
    try testing.expectEqual(model.FileState.partially_applied, fx.cs(id).files[0].state);
    _ = try fx.ap.undoApply(arena.allocator(), r1.ok.apply.?);
    try fx.expectDisk("f.txt", three);
    try testing.expectEqual(model.State.pending, fx.cs(id).state);
    try testing.expectEqual(@as(usize, 3), fx.cs(id).files[0].hunks.len);
    // Accepting again lands the same text.
    _ = try fx.ap.acceptAll(id);
    try fx.expectDisk("f.txt", "A\n.\nB\n.\nC\n");
}

test "applier: undo of a mixed apply restores every file and reopens every op" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try mixed(&fx);
    const r = try fx.ap.acceptAll(id);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try fx.ap.undoApply(arena.allocator(), r.ok.apply.?);
    try fx.expectDisk("m.txt", "one\ntwo\n");
    try fx.expectDisk("new/c.txt", null);
    try fx.expectDisk("d.txt", "gone\n");
    try fx.expectDisk("old.txt", "moved\n");
    try fx.expectDisk("renamed.txt", null);
    try testing.expect(fx.disk.isExec("old.txt"));
    try testing.expect(!fx.disk.isExec("run.sh"));
    const c = fx.cs(id);
    try testing.expectEqual(model.State.pending, c.state);
    for (c.files) |f| try testing.expectEqual(model.FileState.pending, f.state);
    try testing.expect(c.files[1].op == .create);
    try testing.expect(c.files[3].op == .rename);
    _ = try fx.ap.acceptAll(id);
    try fx.expectDisk("m.txt", "ONE\ntwo\n");
    try fx.expectDisk("new/c.txt", "created\n");
    try fx.expectDisk("renamed.txt", "moved\n");
    try testing.expect(fx.disk.isExec("run.sh"));
}
