const std = @import("std");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const rs = @import("review_session.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ChangesetId = model.ChangesetId;
const ReviewSession = rs.ReviewSession;

const Fx = struct {
    blobs: model.MemBlobs,
    disk: apply.MemFiles,
    history: model.History,
    q: *model.Queue,
    ap: apply.Applier,
    clock: i64 = 0,

    fn init(fx: *Fx) !void {
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .history = .init(gpa, null), .q = undefined, .ap = undefined };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs(), .hunk_options = .{ .merge_gap_lines = 0 } });
        fx.ap = .init(gpa, testing.io, fx.q, fx.disk.files(), &fx.history);
    }

    fn deinit(fx: *Fx) void {
        fx.q.deinit();
        fx.history.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
    }

    /// A changeset of session `session` editing `paths` from `base` to `new`.
    fn submit(fx: *Fx, session: u128, edits: []const struct { []const u8, []const u8, []const u8 }) !ChangesetId {
        fx.clock += 1;
        const b = try fx.q.beginBatch(.{
            .origin = .{ .agent = .{ .ref = .{ .session = session }, .turn = 1, .model = "m" } },
            .label = "Turn",
            .workspace = "/w",
            .created_ms = fx.clock,
        });
        for (edits) |e| {
            if (fx.disk.get(e[0]) == null) try fx.disk.put(e[0], e[1], false);
            var cs = try model.merge3.lineChangeSet(gpa, e[1], e[2]);
            defer cs.deinit();
            try fx.q.addEdit(b, e[0], e[1], null, &cs);
        }
        return fx.q.commitBatch(b, .{});
    }

    fn expectDisk(fx: *Fx, path: []const u8, want: []const u8) !void {
        try testing.expectEqualStrings(want, fx.disk.get(path).?);
    }
};

const three = "a\n.\nb\n.\nc\n";

test "session: next/prev across files, n skips decided, c jumps conflicts" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    _ = try fx.submit(1, &.{ .{ "b.txt", three, "A\n.\nB\n.\nc\n" }, .{ "a.txt", "x\n", "y\n" } });
    const s = try ReviewSession.init(gpa, fx.q, &fx.ap, .{ .session = 1 });
    defer s.deinit();

    // Path order inside the changeset: a.txt (1 hunk), b.txt (2 hunks).
    try testing.expectEqual(@as(usize, 2), s.files().len);
    try testing.expectEqualStrings("a.txt", s.fileChange(0).?.path);
    try testing.expectEqual(rs.Cursor{ .file = 0, .hunk = 0 }, s.cursor);
    s.next();
    try testing.expectEqual(rs.Cursor{ .file = 1, .hunk = 0 }, s.cursor);
    s.next();
    try testing.expectEqual(rs.Cursor{ .file = 1, .hunk = 1 }, s.cursor);
    s.next(); // at the end: stays
    try testing.expectEqual(rs.Cursor{ .file = 1, .hunk = 1 }, s.cursor);
    s.prev();
    s.prev();
    try testing.expectEqual(rs.Cursor{ .file = 0, .hunk = 0 }, s.cursor);
    try testing.expectEqual(rs.Progress{ .decided = 0, .total = 3 }, s.progress());

    // Accepting a.txt's only hunk moves on to b.txt.
    try testing.expectEqual(@as(?rs.Failure, null), try s.acceptHunk());
    try testing.expectEqual(@as(u32, 1), s.cursor.file);
    try testing.expectEqual(rs.Progress{ .decided = 1, .total = 3 }, s.progress());
    s.focus(.{ .file = 0 });
    try testing.expect(s.nextUndecided());
    try testing.expectEqual(rs.Cursor{ .file = 1, .hunk = 0 }, s.cursor);

    // A conflict on b.txt's second hunk.
    fx.q.getMut(s.files()[1].cs).?.files[s.files()[1].idx].hunks[1].conflict = .{ .kind = .external_change, .ours_lines = .{ .start = 2, .count = 1 }, .theirs_text = "" };
    try testing.expect(s.nextConflict());
    try testing.expectEqual(rs.Cursor{ .file = 1, .hunk = 1 }, s.cursor);
}

test "session: accept writes, undo reverts the apply" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try fx.submit(1, &.{.{ "f.txt", three, "A\n.\nB\n.\nC\n" }});
    const s = try ReviewSession.init(gpa, fx.q, &fx.ap, .{ .changeset = id });
    defer s.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const tx = (try s.texts(arena_state.allocator(), 0)).?;
    try testing.expectEqualStrings(three, tx.base);
    try testing.expectEqualStrings("A\n.\nB\n.\nC\n", tx.new);
    try testing.expectEqual(@as(?rs.Failure, null), try s.acceptHunk());
    try fx.expectDisk("f.txt", "A\n.\nb\n.\nc\n");
    // The next hunk is under the cursor now.
    try testing.expectEqual(@as(u32, 0), s.cursor.hunk.?);
    try testing.expectEqual(@as(usize, 2), s.fileChange(0).?.hunks.len);
    try testing.expectEqual(@as(?rs.Failure, null), try s.acceptHunk());
    try fx.expectDisk("f.txt", "A\n.\nB\n.\nc\n");

    try testing.expectEqual(@as(?rs.Failure, null), try s.undo());
    try fx.expectDisk("f.txt", "A\n.\nb\n.\nc\n");
    try testing.expectEqual(@as(usize, 2), s.fileChange(0).?.hunks.len);
    try testing.expectEqual(rs.Progress{ .decided = 1, .total = 3 }, s.progress());
    try testing.expectEqual(@as(?rs.Failure, null), try s.undo());
    try fx.expectDisk("f.txt", three);
    try testing.expectEqual(model.State.pending, fx.q.get(id).?.state);
    try testing.expectError(error.NothingToUndo, s.undo());
}

test "session: reject writes nothing and undo brings the hunk back" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try fx.submit(1, &.{.{ "f.txt", three, "A\n.\nb\n.\nC\n" }});
    const s = try ReviewSession.init(gpa, fx.q, &fx.ap, .{ .changeset = id });
    defer s.deinit();
    try testing.expectEqual(@as(?rs.Failure, null), try s.rejectHunk());
    try fx.expectDisk("f.txt", three);
    try testing.expectEqual(@as(usize, 1), s.fileChange(0).?.hunks.len);
    try testing.expectEqual(@as(?rs.Failure, null), try s.rejectFile());
    try testing.expectEqual(model.State.rejected, fx.q.get(id).?.state);
    try testing.expectEqual(@as(?rs.Failure, null), try s.undo());
    try testing.expectEqual(model.State.pending, fx.q.get(id).?.state);
    try testing.expectEqual(@as(?rs.Failure, null), try s.undo());
    try testing.expectEqual(@as(usize, 2), s.fileChange(0).?.hunks.len);
    // And accepting all of it lands both.
    try testing.expectEqual(@as(?rs.Failure, null), try s.acceptChangeset());
    try fx.expectDisk("f.txt", "A\n.\nb\n.\nC\n");
    try testing.expectEqual(model.State.applied, fx.q.get(id).?.state);
}

test "session: a failed accept changes nothing and says why" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try fx.submit(1, &.{.{ "f.txt", three, "A\n.\nb\n.\nc\n" }});
    try fx.disk.put("f.txt", "moved\n", false);
    const s = try ReviewSession.init(gpa, fx.q, &fx.ap, .{ .changeset = id });
    defer s.deinit();
    const f = (try s.acceptHunk()).?;
    try testing.expect(std.mem.indexOf(u8, f.message, "BaseMoved") != null);
    try testing.expectEqualStrings(f.message, s.last_error.?);
    try testing.expectEqual(rs.Cursor{ .file = 0, .hunk = 0 }, s.cursor);
    try testing.expectEqual(@as(usize, 0), s.undo_stack.items.len);
}

test "session: new changesets append; the cursor keeps its hunk" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    _ = try fx.submit(1, &.{.{ "b.txt", three, "a\n.\nB\n.\nC\n" }});
    const s = try ReviewSession.init(gpa, fx.q, &fx.ap, .{ .session = 1 });
    defer s.deinit();
    s.next();
    const key = s.hunk().?.key;
    _ = try fx.submit(1, &.{.{ "a.txt", "x\n", "y\n" }});
    _ = try fx.submit(2, &.{.{ "c.txt", "x\n", "y\n" }});
    try testing.expectEqual(@as(usize, 2), s.files().len);
    try testing.expect(s.files()[1].new);
    try testing.expectEqualStrings("a.txt", s.fileChange(1).?.path);
    try testing.expectEqual(key, s.hunk().?.key);
}
