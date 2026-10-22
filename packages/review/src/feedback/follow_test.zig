const std = @import("std");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const ConflictIndex = @import("../rebase/conflict_index.zig").ConflictIndex;
const comments = @import("comments.zig");
const Follow = @import("follow.zig").Follow;

const testing = std.testing;
const gpa = testing.allocator;
const ChangesetId = model.ChangesetId;

const Fx = struct {
    blobs: model.MemBlobs,
    disk: apply.MemFiles,
    history: model.History,
    q: *model.Queue,
    ap: apply.Applier,
    ci: *ConflictIndex,
    store: comments.CommentStore,
    follow: Follow,

    fn init(fx: *Fx) !void {
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .history = .init(gpa, null), .q = undefined, .ap = undefined, .ci = undefined, .store = .init(gpa, .{}), .follow = undefined };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs(), .hunk_options = .{ .merge_gap_lines = 0 } });
        fx.ap = .init(gpa, testing.io, fx.q, fx.disk.files(), &fx.history);
        fx.ci = try ConflictIndex.init(gpa, fx.q, .{ .history = &fx.history });
        fx.follow = .init(gpa, fx.q, &fx.store);
        _ = try fx.q.subscribe(fx.follow.listener());
    }

    fn deinit(fx: *Fx) void {
        fx.follow.deinit();
        fx.store.deinit();
        fx.ci.deinit();
        fx.q.deinit();
        fx.history.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
    }

    fn edit(fx: *Fx, session: u128, path: []const u8, from: []const u8, new: []const u8) !ChangesetId {
        const b = try fx.q.beginBatch(.{
            .origin = .{ .agent = .{ .ref = .{ .session = session }, .turn = 1, .model = "m" } },
            .label = "Turn 1",
            .workspace = "/w",
            .created_ms = 0,
        });
        var e = try model.merge3.lineChangeSet(gpa, from, new);
        defer e.deinit();
        try fx.q.addEdit(b, path, from, null, &e);
        return fx.q.commitBatch(b, .{});
    }

    fn comment(fx: *Fx, cs: ChangesetId, side: comments.Side, text: []const u8, line: u32) !comments.ThreadId {
        const at: comments.CommentAnchor = try .at(gpa, "f.txt", side, text, .{ .start = line, .count = 1 });
        return fx.store.create(cs, at, null, false, "look", .{ .user = "dana" }, 1);
    }
};

const base = "a\nb\nc\nd\ne\n";

test "follow: a sibling rebased onto another apply keeps its comment on its line" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("f.txt", base, false);
    // Session 1 inserts two lines at the top; session 2 changes `d`.
    const first = try fx.edit(1, "f.txt", base, "x\ny\na\nb\nc\nd\ne\n");
    const second_text = "a\nb\nc\nD\ne\n";
    const second = try fx.edit(2, "f.txt", base, second_text);
    const tid = try fx.comment(second, .new, second_text, 3);
    const removed = try fx.comment(second, .base, base, 3);

    _ = try fx.ap.acceptAll(first);
    _ = try fx.ci.rebaseApplied();
    fx.follow.pump();
    // `D` is now line 5 of the rebased proposal, `d` line 5 of its base.
    try testing.expectEqual(@as(u32, 5), fx.store.get(tid).?.anchor.lines.start);
    try testing.expect(!fx.store.get(tid).?.outdated);
    try testing.expectEqual(@as(u32, 5), fx.store.get(removed).?.anchor.lines.start);
}

test "follow: a partial apply moves comments; lines that were rejected go outdated" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("f.txt", base, false);
    const proposed = "n1\nn2\na\nb\nc\nd\nE\n";
    const id = try fx.edit(1, "f.txt", base, proposed);
    try testing.expectEqual(@as(usize, 2), fx.q.get(id).?.files[0].hunks.len);
    const on_e = try fx.comment(id, .new, proposed, 6);
    const on_n1 = try fx.comment(id, .new, proposed, 0);

    // Reject the inserted lines: `E` moves up two lines; `n1` is gone.
    _ = try fx.ap.apply(.{ .cs = id, .items = &.{.{ .file = 0, .input = .{ .reject = &.{0} } }} });
    fx.follow.pump();
    try testing.expectEqual(@as(u32, 4), fx.store.get(on_e).?.anchor.lines.start);
    try testing.expect(fx.store.get(on_n1).?.outdated);
    // Nothing more to do.
    fx.follow.pump();
    try testing.expectEqual(@as(usize, 0), fx.follow.noted.items.len);
}
