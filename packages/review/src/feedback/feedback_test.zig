const std = @import("std");
const model = @import("../model/root.zig");
const comments = @import("comments.zig");
const message = @import("message.zig");
const feedback = @import("feedback.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ChangesetId = model.ChangesetId;
const ChangeSet = model.changeset.ChangeSet;
const CommentStore = comments.CommentStore;
const Feedback = feedback.Feedback;

const base =
    \\const std = @import("std");
    \\
    \\pub fn fetch(url: []const u8) !void {
    \\    const buf = try alloc(4096);
    \\    try get(url, buf);
    \\}
    \\
    \\pub fn main() void {}
    \\
;

/// A queue with an agent changeset proposing `proposed` for src/net.zig.
const Fx = struct {
    blobs: model.MemBlobs,
    q: *model.Queue,
    store: CommentStore,
    agent: FakeAgent = .{},
    fb: Feedback,

    fn init(fx: *Fx) !void {
        fx.blobs = .init(gpa);
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs() });
        fx.store = .init(gpa, .{});
        fx.agent = .{};
        fx.fb = .init(gpa, fx.q, &fx.store, fx.agent.port(), .{});
        _ = try fx.q.subscribe(fx.fb.listener());
    }

    fn deinit(fx: *Fx) void {
        fx.fb.deinit();
        fx.store.deinit();
        fx.q.deinit();
        fx.blobs.deinit();
    }

    /// Submits `path`: `from` → `to` as session 7's turn `turn`.
    fn submit(fx: *Fx, turn: u32, path: []const u8, from: []const u8, to: []const u8) !ChangesetId {
        const b = try fx.q.beginBatch(.{
            .origin = .{ .agent = .{ .ref = .{ .session = 7 }, .turn = turn, .model = "m" } },
            .label = "Turn 7: add retry to fetch",
            .workspace = "/w",
            .created_ms = 0,
        });
        var e: ChangeSet = try .fromEdits(gpa, from.len, &.{.{ .range = .{ .start = 0, .end = from.len }, .text = to }});
        defer e.deinit();
        try fx.q.addEdit(b, path, from, null, &e);
        const id = try fx.q.commitBatch(b, .{});
        fx.fb.pump();
        return id;
    }

    fn comment(fx: *Fx, cs: ChangesetId, text: []const u8, start: u32, count: u32, body: []const u8) !comments.ThreadId {
        const at: comments.CommentAnchor = try .at(gpa, "src/net.zig", .new, text, .{ .start = start, .count = count });
        const p = @import("labels.zig").parseLabelPrefix(body);
        return fx.store.create(cs, at, p.label, p.blocking orelse false, body, .{ .user = "dana" }, 5);
    }
};

const FakeAgent = struct {
    status: feedback.AgentStatus = .idle,
    sent: std.ArrayList(u8) = .empty,
    modes: [4]?feedback.SubmitMode = @splat(null),
    n: usize = 0,
    resumed: bool = false,
    new_session: bool = false,

    fn port(a: *FakeAgent) feedback.AgentPort {
        return .{ .ctx = a, .status = st, .submit = submit, .resumeSession = res, .newSession = newS };
    }
    fn deinit(a: *FakeAgent) void {
        a.sent.deinit(gpa);
    }
    fn st(ctx: *anyopaque, _: u128) feedback.AgentStatus {
        return @as(*FakeAgent, @ptrCast(@alignCast(ctx))).status;
    }
    fn submit(ctx: *anyopaque, _: u128, msg: *const message.FeedbackMessage, mode: feedback.SubmitMode) anyerror!void {
        const a: *FakeAgent = @ptrCast(@alignCast(ctx));
        a.sent.clearRetainingCapacity();
        try a.sent.appendSlice(gpa, msg.text);
        a.modes[a.n] = mode;
        a.n += 1;
    }
    fn res(ctx: *anyopaque, _: u128) anyerror!void {
        @as(*FakeAgent, @ptrCast(@alignCast(ctx))).resumed = true;
    }
    fn newS(ctx: *anyopaque, msg: *const message.FeedbackMessage) anyerror!u128 {
        const a: *FakeAgent = @ptrCast(@alignCast(ctx));
        a.new_session = true;
        a.sent.clearRetainingCapacity();
        try a.sent.appendSlice(gpa, msg.text);
        return 8;
    }
};

const proposed_v1 =
    \\const std = @import("std");
    \\
    \\pub fn fetch(url: []const u8) !void {
    \\    const buf = try alloc(4096);
    \\    var tries: u32 = 0;
    \\    while (tries < 3) : (tries += 1) {
    \\        get(url, buf) catch continue;
    \\        return;
    \\    }
    \\    return error.Failed;
    \\}
    \\
    \\pub fn main() void {}
    \\
;

test "feedback: message golden for 3 threads + extra text" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    defer fx.agent.deinit();
    const id = try fx.submit(7, "src/net.zig", base, proposed_v1);
    const t1 = try fx.comment(id, proposed_v1, 3, 1, "issue (blocking): this leaks `buf` on error");
    const t2 = try fx.comment(id, proposed_v1, 5, 2, "suggestion: back off between tries\nwith a small sleep");
    const t3 = try fx.comment(id, proposed_v1, 9, 1, "Why `error.Failed`?");
    _ = try fx.store.reply(t3, "The caller only checks for failure.", .{ .agent = .{ .session = 7 } }, 6);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ts = [_]*const comments.Thread{ fx.store.get(t1).?, fx.store.get(t2).?, fx.store.get(t3).? };
    // Without texts the quotes are the threads' own.
    const plain = try message.compose(arena.allocator(), id, "Turn 7: add retry to fetch", &ts, "also add a test", null, .{});
    try testing.expect(std.mem.indexOf(u8, plain.text, "src/net.zig:4\n   this leaks") != null);
    var tx: Quotes = .{ .text = proposed_v1 };
    const q = try message.compose(arena.allocator(), id, "Turn 7: add retry to fetch", &ts, "also add a test", tx.textOf(), .{});
    try testing.expectEqualStrings(@embedFile("testdata/feedback_3_threads.md"), q.text);
    try testing.expectEqual(@as(usize, 3), q.context.len);
    try testing.expectEqualStrings("src/net.zig", q.context[1].ref.range.path);
    try testing.expectEqual([2]u32{ 6, 7 }, q.context[1].ref.range.lines);
}

const Quotes = struct {
    text: []const u8,
    fn textOf(q: *Quotes) message.TextOf {
        return .{ .ctx = q, .text = f };
    }
    fn f(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8, _: comments.Side) anyerror!?[]const u8 {
        return @as(*Quotes, @ptrCast(@alignCast(ctx))).text;
    }
};

test "feedback: token cap drops quotes before locations" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    defer fx.agent.deinit();
    const id = try fx.submit(7, "src/net.zig", base, proposed_v1);
    const t1 = try fx.comment(id, proposed_v1, 2, 9, "issue: too long");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ts = [_]*const comments.Thread{fx.store.get(t1).?};
    var tx: Quotes = .{ .text = proposed_v1 };
    const full = try message.compose(arena.allocator(), id, "L", &ts, "", tx.textOf(), .{});
    try testing.expect(!full.quotes_dropped);
    try testing.expect(std.mem.indexOf(u8, full.text, "while (tries < 3)") != null);
    const capped = try message.compose(arena.allocator(), id, "L", &ts, "", tx.textOf(), .{ .max_tokens = 60 });
    try testing.expect(capped.quotes_dropped);
    try testing.expect(std.mem.indexOf(u8, capped.text, "while (tries < 3)") == null);
    try testing.expect(std.mem.indexOf(u8, capped.text, "src/net.zig:3-11") != null);
    try testing.expect(std.mem.indexOf(u8, capped.text, "too long") != null);

    // Quotes over 40 lines keep the head and tail.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    for (0..60) |i| try long.print(gpa, "line {d}\n", .{i});
    const id2 = try fx.submit(8, "src/long.zig", "", long.items);
    const at: comments.CommentAnchor = try .at(gpa, "src/long.zig", .new, long.items, .{ .start = 0, .count = 60 });
    const t2 = try fx.store.create(id2, at, null, false, "split this", .{ .user = "u" }, 1);
    var lt: Quotes = .{ .text = long.items };
    const m = try message.compose(arena.allocator(), id2, "L", &.{fx.store.get(t2).?}, "", lt.textOf(), .{});
    try testing.expect(std.mem.indexOf(u8, m.text, "   line 19\n   …\n   line 41\n") != null);
    try testing.expect(std.mem.indexOf(u8, m.text, "line 20\n") == null);
}

test "feedback: delivery by status (running→steer, idle→new_turn, ended→prompt)" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    defer fx.agent.deinit();
    const id = try fx.submit(7, "src/net.zig", base, proposed_v1);
    const t1 = try fx.comment(id, proposed_v1, 3, 1, "issue: leak");
    fx.agent.status = .running;
    try testing.expectEqual(feedback.Delivery.steered, try fx.fb.requestFix(id, &.{t1}, "", 10));
    try testing.expectEqual(@as(?i64, 10), fx.store.get(t1).?.sent_ms);
    fx.agent.status = .idle;
    try testing.expectEqual(feedback.Delivery.new_turn, try fx.fb.requestFix(id, &.{t1}, "", 11));
    try testing.expectEqual(@as(?feedback.SubmitMode, .steer), fx.agent.modes[0]);
    try testing.expectEqual(@as(?feedback.SubmitMode, .new_turn), fx.agent.modes[1]);
    try testing.expect(std.mem.startsWith(u8, fx.agent.sent.items, "Review feedback on changeset #1"));

    fx.agent.status = .ended;
    try testing.expectEqual(feedback.Delivery.ask_resume, try fx.fb.requestFix(id, &.{t1}, "", 12));
    try testing.expectEqual(@as(usize, 2), fx.agent.n);
    try testing.expectEqual(@as(?i64, 11), fx.store.get(t1).?.sent_ms);
    try fx.fb.finishEnded(.resume_session, 13);
    try testing.expect(fx.agent.resumed);
    try testing.expectEqual(@as(?i64, 13), fx.store.get(t1).?.sent_ms);
    _ = try fx.fb.requestFix(id, &.{t1}, "", 14);
    try fx.fb.finishEnded(.new_session, 15);
    try testing.expect(fx.agent.new_session);
    _ = try fx.fb.requestFix(id, &.{t1}, "", 16);
    try fx.fb.finishEnded(.cancel, 17);
    try testing.expectEqual(@as(?i64, 15), fx.store.get(t1).?.sent_ms);
    try testing.expectError(error.NothingWaiting, fx.fb.finishEnded(.cancel, 18));
    try testing.expectError(error.NoThreads, fx.fb.requestFix(id, &.{}, " ", 19));
}

const proposed_v2 =
    \\const std = @import("std");
    \\
    \\pub fn fetch(url: []const u8) !void {
    \\    const buf = try alloc(4096);
    \\    defer free(buf);
    \\    var tries: u32 = 0;
    \\    while (tries < 3) : (tries += 1) {
    \\        get(url, buf) catch continue;
    \\        return;
    \\    }
    \\    return error.Failed;
    \\}
    \\
    \\pub fn main() void {}
    \\
;

test "feedback: folded revision bumps revision and snapshots N−1; interdiff and maybe_addressed" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    defer fx.agent.deinit();
    const id = try fx.submit(7, "src/net.zig", base, proposed_v1);
    const leak = try fx.comment(id, proposed_v1, 3, 1, "issue (blocking): this leaks `buf` on error");
    const why = try fx.comment(id, proposed_v1, 9, 1, "question: why error.Failed?");
    _ = try fx.fb.requestFix(id, &.{ leak, why }, "", 10);
    try testing.expect(fx.fb.waitingOn(id));

    // The agent edits its own pending text: it folds into #1.
    const id2 = try fx.submit(8, "src/net.zig", proposed_v1, proposed_v2);
    try testing.expectEqual(model.State.superseded, fx.q.get(id2).?.state);
    const cs = fx.q.get(id).?;
    try testing.expectEqual(@as(u16, 2), cs.revision);
    try testing.expect(!fx.fb.waitingOn(id));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = (try fx.fb.interdiff(id, id, "src/net.zig", arena.allocator())).?;
    try testing.expectEqualStrings(proposed_v1, d.left);
    try testing.expectEqualStrings(proposed_v2, d.right);
    try testing.expectEqualStrings("revision 1", d.left_label);

    // Both threads' lines are still there (one line was inserted under
    // the first): moved, not addressed.
    try testing.expectEqual(@as(u32, 3), fx.store.get(leak).?.anchor.lines.start);
    try testing.expectEqual(@as(u32, 10), fx.store.get(why).?.anchor.lines.start);
    try testing.expect(!fx.store.get(why).?.maybe_addressed);
}

test "feedback: maybe_addressed tagging" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    defer fx.agent.deinit();
    const id = try fx.submit(7, "src/net.zig", base, proposed_v1);
    const why = try fx.comment(id, proposed_v1, 9, 1, "question: why error.Failed?");
    const other = try fx.comment(id, proposed_v1, 12, 1, "note: main is empty");
    _ = try fx.fb.requestFix(id, &.{why}, "", 10);
    const v2 = try std.mem.replaceOwned(u8, gpa, proposed_v1, "return error.Failed;", "return error.RetriesExhausted;");
    defer gpa.free(v2);
    _ = try fx.submit(8, "src/net.zig", proposed_v1, v2);
    try testing.expect(fx.store.get(why).?.maybe_addressed);
    try testing.expect(fx.store.get(why).?.outdated);
    // Unchanged and never sent: neither.
    try testing.expect(!fx.store.get(other).?.maybe_addressed);
    try testing.expect(!fx.store.get(other).?.outdated);
}

test "feedback: superseding changeset copies and re-anchors threads" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    defer fx.agent.deinit();
    const id = try fx.submit(7, "src/net.zig", base, proposed_v1);
    const leak = try fx.comment(id, proposed_v1, 3, 1, "issue (blocking): this leaks `buf` on error");
    const done = try fx.comment(id, proposed_v1, 12, 1, "praise: nice");
    try fx.store.resolve(done, true);
    _ = try fx.fb.requestFix(id, &.{leak}, "", 10);
    // #1 was partly decided: the agent's next edit cannot fold into it.
    fx.q.getMut(id).?.files[0].hunks[0].decision = .accepted;
    const id2 = try fx.submit(8, "src/net.zig", proposed_v1, proposed_v2);
    const n = fx.q.get(id2).?;
    try testing.expectEqual(@as(?ChangesetId, id), n.supersedes);
    const copied = fx.store.threadsOf(id2);
    try testing.expectEqual(@as(usize, 1), copied.len);
    try testing.expectEqual(@as(?comments.ThreadId, leak), copied[0].copied_from);
    try testing.expectEqual(@as(u32, 3), copied[0].anchor.lines.start);
    try testing.expect(copied[0].blocking);
    try testing.expectEqual(@as(usize, 2), fx.store.threadsOf(id).len);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = (try fx.fb.interdiff(id, id2, "src/net.zig", arena.allocator())).?;
    try testing.expectEqualStrings(proposed_v1, d.left);
    try testing.expectEqualStrings(proposed_v2, d.right);
    try testing.expectEqualStrings("#1", d.left_label);
}

test "feedback: the previous proposal survives a store round trip" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    defer fx.agent.deinit();
    const id = try fx.submit(7, "src/net.zig", base, proposed_v1);
    const t = try fx.comment(id, proposed_v1, 3, 1, "issue: leak");
    _ = try fx.fb.requestFix(id, &.{t}, "", 10);
    _ = try fx.submit(8, "src/net.zig", proposed_v1, proposed_v2);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try @import("../store/records.zig").writeChangeset(&aw.writer, fx.q.get(id).?, fx.blobs.blobs(), gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), aw.written(), .{});
    const back = try @import("../store/records.zig").readChangeset(gpa, v, fx.blobs.blobs());
    defer {
        back.deinit(gpa);
        gpa.destroy(back);
    }
    try testing.expectEqual(fx.q.get(id).?.files[0].previous.?, back.files[0].previous.?);
    try testing.expectEqual(@as(u16, 2), back.revision);
}
