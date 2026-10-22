const std = @import("std");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const comments = @import("comments.zig");
const outcome = @import("outcome.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ChangeSet = model.changeset.ChangeSet;
const ChangesetId = model.ChangesetId;
const OutcomeReporter = outcome.OutcomeReporter;

/// Captures each outcome as rendered text.
const Sink = struct {
    texts: std.ArrayList([]u8) = .empty,
    finals: std.ArrayList(bool) = .empty,
    max_chars: u32 = 2000,

    fn sink(s: *Sink) outcome.OutcomeSink {
        return .{ .ctx = s, .deliver = deliver };
    }
    fn deinit(s: *Sink) void {
        for (s.texts.items) |t| gpa.free(t);
        s.texts.deinit(gpa);
        s.finals.deinit(gpa);
    }
    fn deliver(ctx: *anyopaque, o: *const outcome.Outcome) void {
        const s: *Sink = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(gpa);
        outcome.render(o, &aw.writer, s.max_chars) catch unreachable;
        s.texts.append(gpa, aw.toOwnedSlice() catch unreachable) catch unreachable;
        s.finals.append(gpa, o.final) catch unreachable;
    }
};

const Fx = struct {
    blobs: model.MemBlobs,
    disk: apply.MemFiles,
    history: model.History,
    q: *model.Queue,
    ap: apply.Applier,
    store: comments.CommentStore,
    sink: Sink = .{},
    rep: *OutcomeReporter,

    fn init(fx: *Fx, o: outcome.Options) !void {
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .history = .init(gpa, null), .q = undefined, .ap = undefined, .store = .init(gpa, .{}), .rep = undefined };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs(), .hunk_options = .{ .merge_gap_lines = 0 } });
        fx.ap = .init(gpa, testing.io, fx.q, fx.disk.files(), &fx.history);
        fx.rep = try OutcomeReporter.init(gpa, fx.q, &fx.store, fx.sink.sink(), o);
    }

    fn deinit(fx: *Fx) void {
        fx.rep.deinit();
        fx.store.deinit();
        fx.q.deinit();
        fx.history.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
        fx.sink.deinit();
    }

    fn begin(fx: *Fx) !model.BatchId {
        return fx.q.beginBatch(.{
            .origin = .{ .agent = .{ .ref = .{ .session = 9 }, .turn = 7, .model = "m" } },
            .label = "Turn 7: add retry to fetch",
            .workspace = "/w",
            .created_ms = 0,
        });
    }

    /// Adds `path` to batch `b`: each `.` separated line of `base`
    /// upper-cased, one hunk per line.
    fn addFile(fx: *Fx, b: model.BatchId, path: []const u8, base: []const u8) !void {
        try fx.disk.put(path, base, false);
        var reps: std.ArrayList(model.changeset.Replace) = .empty;
        defer reps.deinit(gpa);
        var bufs: std.ArrayList([]u8) = .empty;
        defer {
            for (bufs.items) |x| gpa.free(x);
            bufs.deinit(gpa);
        }
        var i: usize = 0;
        while (i < base.len) : (i += 1) if (base[i] >= 'a' and base[i] <= 'z') {
            const up = try gpa.dupe(u8, base[i .. i + 1]);
            up[0] = std.ascii.toUpper(up[0]);
            try bufs.append(gpa, up);
            try reps.append(gpa, .{ .range = .{ .start = i, .end = i + 1 }, .text = up });
        };
        var e: ChangeSet = try .fromEdits(gpa, base.len, reps.items);
        defer e.deinit();
        try fx.q.addEdit(b, path, base, null, &e);
    }

    fn take(fx: *Fx, id: ChangesetId, file: u32, in: apply.SelectionInput) !void {
        const r = try fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = file, .input = in }} });
        try testing.expect(r == .ok);
    }
};

test "outcome: aggregation for accept/reject/edit mix (golden text)" {
    var fx: Fx = undefined;
    try fx.init(.{});
    defer fx.deinit();
    const b = try fx.begin();
    try fx.addFile(b, "src/a.zig", "a\n.\nb\n");
    try fx.addFile(b, "src/b.zig", "c\n.\nd\n.\ne\n");
    const id = try fx.q.commitBatch(b, .{});
    try fx.take(id, 0, .{ .accept = &.{ 0, 1 } });
    try fx.take(id, 1, .{ .accept = &.{0}, .reject = &.{1}, .edited = &.{.{ .hunk = 2, .text = "e2\n" }} });
    fx.rep.pump(0);
    try testing.expectEqual(@as(usize, 1), fx.sink.texts.items.len);
    try testing.expect(fx.sink.finals.items[0]);
    try testing.expectEqualStrings(
        \\Review outcome #1 ("Turn 7: add retry to fetch"):
        \\- src/a.zig: accepted (2/2)
        \\- src/b.zig: partially accepted (1 accepted, 1 rejected, 1 edited by user)
        \\  --- proposed
        \\  +++ landed
        \\  @@ -1 +1 @@
        \\  -E
        \\  +e2
        \\Rejected changes are not in the files; do not assume them.
        \\Re-read files before editing them again.
        \\
    , fx.sink.texts.items[0]);
    // Delivered once.
    fx.rep.pump(10_000);
    try testing.expectEqual(@as(u32, 0), fx.rep.flush(9));
    try testing.expectEqual(@as(usize, 1), fx.sink.texts.items.len);
}

test "outcome: partial outcome after 2 s idle; final on terminal state" {
    var fx: Fx = undefined;
    try fx.init(.{});
    defer fx.deinit();
    const b = try fx.begin();
    try fx.addFile(b, "f.zig", "a\n.\nb\n.\nc\n");
    const id = try fx.q.commitBatch(b, .{});
    try fx.take(id, 0, .{ .accept = &.{0} });
    fx.rep.pump(1000);
    fx.rep.pump(2500);
    try testing.expectEqual(@as(usize, 0), fx.sink.texts.items.len);
    fx.rep.pump(3000);
    try testing.expectEqual(@as(usize, 1), fx.sink.texts.items.len);
    try testing.expect(!fx.sink.finals.items[0]);
    try testing.expectEqualStrings(
        \\Review outcome #1 ("Turn 7: add retry to fetch"), so far (2 hunks still pending review):
        \\- f.zig: partially accepted (1 accepted, 2 pending)
        \\
    , fx.sink.texts.items[0]);
    // The rest: only the new decisions, and final at once.
    try fx.take(id, 0, .{ .reject = &.{ 0, 1 } });
    try testing.expectEqual(model.State.applied, fx.q.get(id).?.state);
    fx.rep.pump(3001);
    try testing.expectEqual(@as(usize, 2), fx.sink.texts.items.len);
    try testing.expect(fx.sink.finals.items[1]);
    try testing.expectEqualStrings(
        \\Review outcome #1 ("Turn 7: add retry to fetch"):
        \\- f.zig: rejected (2/2)
        \\Rejected changes are not in the files; do not assume them.
        \\Re-read files before editing them again.
        \\
    , fx.sink.texts.items[1]);
}

test "outcome: user_edit_diff capped at 30 lines" {
    var fx: Fx = undefined;
    try fx.init(.{});
    defer fx.deinit();
    const b = try fx.begin();
    try fx.addFile(b, "f.zig", "a\n.\nb\n");
    const id = try fx.q.commitBatch(b, .{});
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    for (0..40) |i| try long.print(gpa, "line {d}\n", .{i});
    try fx.take(id, 0, .{ .accept = &.{1}, .edited = &.{.{ .hunk = 0, .text = long.items }} });
    fx.rep.pump(0);
    try testing.expectEqualStrings(
        \\Review outcome #1 ("Turn 7: add retry to fetch"):
        \\- f.zig: partially accepted (1 accepted, 1 edited by user)
        \\  The user rewrote 40 lines; re-read the file.
        \\Re-read files before editing them again.
        \\
    , fx.sink.texts.items[0]);
}

test "outcome: flush on session request boundary delivers pending outcome once" {
    var fx: Fx = undefined;
    try fx.init(.{});
    defer fx.deinit();
    const b = try fx.begin();
    try fx.addFile(b, "f.zig", "a\n.\nb\n.\nc\n");
    const id = try fx.q.commitBatch(b, .{});
    try fx.take(id, 0, .{ .accept = &.{0} });
    try testing.expect(fx.rep.waiting(id));
    try testing.expectEqual(@as(u32, 0), fx.rep.flush(8));
    try testing.expectEqual(@as(u32, 1), fx.rep.flush(9));
    try testing.expectEqual(@as(u32, 0), fx.rep.flush(9));
    fx.rep.pump(0);
    fx.rep.pump(60_000);
    try testing.expectEqual(@as(usize, 1), fx.sink.texts.items.len);
    try testing.expect(!fx.sink.finals.items[0]);
    try testing.expect(!fx.rep.waiting(id));
}

test "outcome: open comments are mentioned; over budget, files are cut" {
    var fx: Fx = undefined;
    try fx.init(.{});
    defer fx.deinit();
    const b = try fx.begin();
    try fx.addFile(b, "src/one.zig", "a\n");
    try fx.addFile(b, "src/two.zig", "b\n");
    try fx.addFile(b, "src/three.zig", "c\n");
    const id = try fx.q.commitBatch(b, .{});
    const at: comments.CommentAnchor = try .at(gpa, "src/one.zig", .new, "A\n", .{ .start = 0, .count = 1 });
    _ = try fx.store.create(id, at, null, false, "why?", .{ .user = "dana" }, 1);
    fx.sink.max_chars = 220;
    try fx.take(id, 0, .{ .accept = &.{0} });
    fx.rep.pump(0);
    _ = fx.rep.flush(9);
    try testing.expectEqualStrings(
        \\Review outcome #1 ("Turn 7: add retry to fetch"), so far (2 hunks still pending review):
        \\- src/one.zig: accepted (1/1)
        \\- … and 2 more files
        \\The reviewer left 1 open review comment; a fix request may follow.
        \\
    , fx.sink.texts.items[0]);
}

const FakeRecords = struct {
    have: std.ArrayList(Key) = .empty,
    written: std.ArrayList(Key) = .empty,

    const Key = struct { apply: u64, hunk: u32, decision: model.Decision = .accepted };

    fn records(f: *FakeRecords) outcome.ReviewRecords {
        return .{ .ctx = f, .has = has, .record = record };
    }
    fn deinit(f: *FakeRecords) void {
        f.have.deinit(gpa);
        f.written.deinit(gpa);
    }
    fn has(ctx: *anyopaque, a: u64, _: []const u8, hunk: u32) bool {
        const f: *FakeRecords = @ptrCast(@alignCast(ctx));
        for (f.have.items) |k| if (k.apply == a and k.hunk == hunk) return true;
        return false;
    }
    fn record(ctx: *anyopaque, r: *const outcome.ReviewRef) anyerror!void {
        const f: *FakeRecords = @ptrCast(@alignCast(ctx));
        try testing.expectEqualStrings("f.zig", r.path);
        try testing.expectEqualStrings("user", r.reviewer);
        try f.written.append(gpa, .{ .apply = r.apply, .hunk = r.hunk, .decision = r.decision });
        try f.have.append(gpa, .{ .apply = r.apply, .hunk = r.hunk });
    }
};

test "outcome: review refs present for every applied hunk" {
    var recs: FakeRecords = .{};
    defer recs.deinit();
    var fx: Fx = undefined;
    try fx.init(.{ .records = recs.records() });
    defer fx.deinit();
    const b = try fx.begin();
    try fx.addFile(b, "f.zig", "a\n.\nb\n.\nc\n");
    const id = try fx.q.commitBatch(b, .{});
    // E09 recorded hunk 0 itself; hunk 2 (edited) is missing, hunk 1 was
    // rejected and needs none.
    try recs.have.append(gpa, .{ .apply = 1, .hunk = 0 });
    try fx.take(id, 0, .{ .accept = &.{0}, .reject = &.{1}, .edited = &.{.{ .hunk = 2, .text = "x\n" }} });
    try testing.expectEqual(@as(u64, 1), fx.history.lastApplyOf(id).?.id);
    fx.rep.pump(0);
    try testing.expectEqual(@as(usize, 1), recs.written.items.len);
    try testing.expectEqual(FakeRecords.Key{ .apply = 1, .hunk = 2, .decision = .edited }, recs.written.items[0]);
    // Checked once.
    fx.rep.pump(1);
    try testing.expectEqual(@as(usize, 1), recs.written.items.len);
}
