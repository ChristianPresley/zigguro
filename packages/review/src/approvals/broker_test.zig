const std = @import("std");
const zg_security = @import("zg_security");
const model = @import("../model/root.zig");
const store_mod = @import("../store/root.zig");
const broker_mod = @import("broker.zig");
const inbox = @import("inbox.zig");

const testing = std.testing;
const io = testing.io;
const contracts = zg_security.contracts;
const ApprovalBroker = broker_mod.ApprovalBroker;
const ApprovalId = inbox.ApprovalId;
const ApprovalState = inbox.ApprovalState;
const Answer = contracts.Answer;

fn command(session: []const u8, line: []const u8, created_ms: i64) contracts.ApprovalRequest {
    return .{
        .kind = .command,
        .actor = .{ .agent = .{ .session = session, .agent = "main" } },
        .title = "Run command",
        .detail_json = "{\"cwd\":\"/ws\",\"terminal\":1}",
        .command = line,
        .risk = &.{"runs build scripts"},
        .rule_suggestion = "run_command(cargo test *)",
        .editable = true,
        .created_ms = created_ms,
    };
}

/// Records listener calls.
const Heard = struct {
    calls: std.ArrayList(struct { u64, ApprovalState }) = .empty,
    mutex: std.Io.Mutex = .init,

    fn listener(h: *Heard) inbox.InboxListener {
        return .{ .ctx = h, .changed = changed };
    }
    fn changed(ctx: *anyopaque, id: ApprovalId, s: ApprovalState) void {
        const h: *Heard = @ptrCast(@alignCast(ctx));
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        h.calls.append(testing.allocator, .{ @intFromEnum(id), s }) catch {};
    }
    fn deinit(h: *Heard) void {
        h.calls.deinit(testing.allocator);
    }
};

test "approvals: E16 FakeApprovalPort-shaped round trip through approvalPort() vtable (present → await → answer)" {
    var b: ApprovalBroker = .init(testing.allocator, io, .{});
    defer b.deinit();
    const port = b.approvalPort();
    // E16 builds the ticket from the port, as with testing.FakeApprovalPort.
    var line_buf = "cargo test --release".*;
    const ticket = try port.present(command("s1", &line_buf, 5));
    line_buf[0] = 'X'; // the request was copied
    try testing.expectEqualStrings("cargo test --release", b.get(@enumFromInt(ticket.id)).?.req.command.?);
    var fut = try io.concurrent(contracts.ApprovalTicket.await, .{ ticket, io });
    try b.answer(@enumFromInt(ticket.id), .{ .allow_session = "run_command(cargo test *)" }, "inbox");
    const a = try fut.await(io);
    try testing.expectEqualStrings("run_command(cargo test *)", a.allow_session);
    const it = b.get(@enumFromInt(ticket.id)).?;
    try testing.expectEqual(ApprovalState.allowed_session, it.state);
    try testing.expectEqualStrings("inbox", it.answered_by.?);
    // A second await of an answered ticket returns at once.
    try testing.expectEqual(Answer.allow_session, std.meta.activeTag(try ticket.await(io)));
}

test "approvals: present from worker, answer on owner, await returns answer" {
    var b: ApprovalBroker = .init(testing.allocator, io, .{});
    defer b.deinit();
    var heard: Heard = .{};
    defer heard.deinit();
    try b.addListener(heard.listener());
    const Worker = struct {
        fn run(br: *ApprovalBroker) !Answer {
            const id = try br.present(command("s1", "make", 1));
            return br.await(id, io);
        }
    };
    var fut = try io.concurrent(Worker.run, .{&b});
    var tries: u32 = 0;
    while (b.pendingCount(.{}) == 0) : (tries += 1) {
        try testing.expect(tries < 2000);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const items = try b.list(testing.allocator, .{});
    defer testing.allocator.free(items);
    const t0 = std.Io.Clock.awake.now(io);
    try b.answer(items[0].id, .allow_once, "agent-pane");
    const a = try fut.await(io);
    const waited_ns = t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    try testing.expectEqual(Answer.allow_once, std.meta.activeTag(a));
    // Answer to resumed waiter: well under the 1 ms budget on a quiet
    // machine; generous here for loaded CI.
    try testing.expect(waited_ns < 250 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 2), heard.calls.items.len);
    try testing.expectEqual(ApprovalState.pending, heard.calls.items[0][1]);
    try testing.expectEqual(ApprovalState.allowed_once, heard.calls.items[1][1]);
}

test "approvals: first answer wins; second returns AlreadyAnswered" {
    var b: ApprovalBroker = .init(testing.allocator, io, .{});
    defer b.deinit();
    const id = try b.present(command("s1", "ls", 1));
    try b.answer(id, .{ .deny = "not now" }, "inbox");
    try testing.expectError(error.AlreadyAnswered, b.answer(id, .allow_once, "toast"));
    try testing.expectError(error.UnknownApproval, b.answer(@enumFromInt(999), .allow_once, "toast"));
    const it = b.get(id).?;
    try testing.expectEqual(ApprovalState.denied, it.state);
    try testing.expectEqualStrings("not now", it.answer.?.deny);
    try testing.expectEqualStrings("inbox", it.answered_by.?);
    // Cancelling an answered request changes nothing.
    b.cancel(id);
    try testing.expectEqual(ApprovalState.denied, b.get(id).?.state);
}

test "approvals: cancel via Io cancellation removes item and returns Canceled" {
    var b: ApprovalBroker = .init(testing.allocator, io, .{});
    defer b.deinit();
    var heard: Heard = .{};
    defer heard.deinit();
    try b.addListener(heard.listener());
    const id = try b.present(command("s1", "sleep 100", 1));
    var fut = try io.concurrent(ApprovalBroker.await, .{ &b, id, io });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, fut.cancel(io));
    try testing.expectEqual(ApprovalState.cancelled, b.get(id).?.state);
    const items = try b.list(testing.allocator, .{});
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 0), items.len);
    try testing.expectEqual(@as(usize, 0), b.pendingCount(.{}));
    try testing.expectEqual(ApprovalState.cancelled, heard.calls.items[heard.calls.items.len - 1][1]);
    try testing.expectError(error.AlreadyAnswered, b.answer(id, .allow_once, "inbox"));

    // The port's cancel (the turn ended) wakes a waiter with a denial.
    const id2 = try b.present(command("s1", "sleep 200", 2));
    var fut2 = try io.concurrent(ApprovalBroker.await, .{ &b, id2, io });
    b.approvalPort().vtable.cancel(&b, @intFromEnum(id2));
    try testing.expectEqualStrings("cancelled", (try fut2.await(io)).deny);
    b.removeListener(&heard);
}

test "approvals: edit only when editable; re-ask chains previous" {
    var b: ApprovalBroker = .init(testing.allocator, io, .{});
    defer b.deinit();
    var req = command("s1", "cargo test --release", 1);
    req.editable = false;
    const fixed = try b.present(req);
    try testing.expectError(error.NotEditable, b.answer(fixed, .{ .edit = "cargo test" }, "inbox"));
    try testing.expectEqual(ApprovalState.pending, b.get(fixed).?.state);

    const id = try b.present(command("s1", "cargo test --release", 2));
    try b.answer(id, .{ .edit = "cargo test" }, "inbox");
    const a = try b.await(id, io);
    try testing.expectEqualStrings("cargo test", a.edit);
    try testing.expectEqual(ApprovalState.edited_allowed, b.get(id).?.state);
    // The edited command still needs approval: a new request re-asks.
    const again = try b.presentChained(command("s1", "cargo test", 3), id);
    try testing.expectEqual(id, b.get(again).?.previous.?);
}

test "approvals: crash restore marks pending as expired" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var answered: ApprovalId = undefined;
    var waiting: ApprovalId = undefined;
    {
        const s = try store_mod.ChangesetStore.open(testing.allocator, io, tmp.dir, "review", .{ .process_tag = 7 });
        defer s.close();
        var b: ApprovalBroker = .init(testing.allocator, io, .{ .recorder = s.approvalRecorder(), .id_base = 7 << 32 });
        defer b.deinit();
        answered = try b.present(command("s1", "ls", 1));
        try b.answer(answered, .{ .allow_always = "run_command(ls)" }, "cli");
        var req = command("s2", "rm -rf build", 2);
        req.actor = .{ .mcp_server = "fs" };
        waiting = try b.present(req);
        try testing.expectEqual(@as(u64, (7 << 32) + 1), @intFromEnum(answered));
        // The process dies with `waiting` pending.
    }
    const s = try store_mod.ChangesetStore.open(testing.allocator, io, tmp.dir, "review", .{ .process_tag = 7 });
    defer s.close();
    const q = try model.Queue.init(testing.allocator, io, .{ .root = "/w", .blobs = s.blobs(), .journal = s.journalPort() });
    defer q.deinit();
    var b: ApprovalBroker = .init(testing.allocator, io, .{ .recorder = s.approvalRecorder(), .id_base = 7 << 32 });
    defer b.deinit();
    var sink = s.queueSink(q, null, null);
    sink.approvals = b.restoreSink();
    _ = try s.load(sink.sink());

    const a = b.get(answered).?;
    try testing.expectEqual(ApprovalState.allowed_always, a.state);
    try testing.expectEqualStrings("run_command(ls)", a.answer.?.allow_always);
    try testing.expectEqualStrings("cli", a.answered_by.?);
    try testing.expectEqualStrings("s1", a.session().?);
    try testing.expectEqualStrings("runs build scripts", a.req.risk[0]);
    try testing.expectEqualStrings("run_command(cargo test *)", a.req.rule_suggestion.?);
    const w = b.get(waiting).?;
    try testing.expectEqual(ApprovalState.expired, w.state);
    try testing.expectEqualStrings("fs", w.req.actor.mcp_server);
    try testing.expectEqualStrings("rm -rf build", w.req.command.?);
    // Shown in the history; nobody waits, and a late answer is refused.
    try testing.expectEqual(@as(usize, 0), b.pendingCount(.{}));
    const items = try b.list(testing.allocator, .{});
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectError(error.AlreadyAnswered, b.answer(waiting, .allow_once, "inbox"));
    try testing.expectEqual(Answer.deny, std.meta.activeTag(try b.await(waiting, io)));
    // Ids continue after the restored ones.
    try testing.expectEqual(@intFromEnum(waiting) + 1, @intFromEnum(try b.present(command("s1", "pwd", 3))));
}

test "approvals: per-agent filter and ordering" {
    var b: ApprovalBroker = .init(testing.allocator, io, .{});
    defer b.deinit();
    const old_done = try b.present(command("a", "one", 10));
    const a_late = try b.present(command("a", "two", 30));
    const b_early = try b.present(command("b", "three", 20));
    var sys = command("a", "four", 5);
    sys.actor = .system;
    const system = try b.present(sys);
    try b.answer(old_done, .allow_once, "inbox");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all = try b.list(arena, .{});
    try testing.expectEqual(@as(usize, 4), all.len);
    // Pending first (oldest first), then answered.
    try testing.expectEqual(system, all[0].id);
    try testing.expectEqual(b_early, all[1].id);
    try testing.expectEqual(a_late, all[2].id);
    try testing.expectEqual(old_done, all[3].id);

    const pane = try b.list(arena, .{ .session = "a" });
    try testing.expectEqual(@as(usize, 2), pane.len);
    try testing.expectEqual(a_late, pane[0].id);
    try testing.expectEqual(old_done, pane[1].id);
    try testing.expectEqual(@as(usize, 1), (try b.list(arena, .{ .session = "a", .answered = false })).len);
    try testing.expectEqual(@as(usize, 1), b.pendingCount(.{ .session = "b" }));
    try testing.expectEqual(@as(usize, 3), b.pendingCount(.{}));

    // A request without a time gets the broker's clock.
    const stamped = try b.present(command("c", "five", 0));
    try testing.expect(b.get(stamped).?.req.created_ms > 0);
    b.cancel(stamped);

    // Pruning frees answered items only.
    try testing.expectEqual(@as(u32, 2), b.prune(std.math.maxInt(i64)));
    try testing.expectEqual(@as(?inbox.InboxItem, null), b.get(old_done));
    try testing.expectEqual(@as(usize, 3), b.pendingCount(.{}));
}

test "approvals: timeout setting expires" {
    var b: ApprovalBroker = .init(testing.allocator, io, .{ .timeout_ms = 1000 });
    defer b.deinit();
    const id = try b.present(command("s1", "npm test", 1));
    const later = try b.present(command("s1", "npm run lint", 800));
    var fut = try io.concurrent(ApprovalBroker.await, .{ &b, id, io });
    try testing.expectEqual(@as(u32, 0), b.expireDue(1000));
    try testing.expectEqual(@as(u32, 1), b.expireDue(1001));
    const a = try fut.await(io);
    try testing.expectEqualStrings("the approval request timed out", a.deny);
    try testing.expectEqual(ApprovalState.expired, b.get(id).?.state);
    try testing.expectEqual(ApprovalState.pending, b.get(later).?.state);

    var never: ApprovalBroker = .init(testing.allocator, io, .{});
    defer never.deinit();
    _ = try never.present(command("s1", "npm test", 1));
    try testing.expectEqual(@as(u32, 0), never.expireDue(std.math.maxInt(i64)));
}

test "approvals: journal record round trip" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var req = command("s1", "git push", 42);
    req.actor = .{ .agent = .{ .session = "s1", .agent = "sub", .parent = "main" } };
    const item: inbox.InboxItem = .{
        .id = @enumFromInt(3),
        .req = req,
        .state = .edited_allowed,
        .answer = .{ .edit = "git push --dry-run" },
        .answered_by = "inbox",
        .answered_ms = 50,
        .previous = @enumFromInt(2),
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try broker_mod.writeRecord(&aw.writer, &item);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, aw.written(), .{});
    const back = try broker_mod.readRecord(arena, v);
    try testing.expectEqual(item.id, back.id);
    try testing.expectEqual(item.state, back.state);
    try testing.expectEqualStrings("git push --dry-run", back.answer.?.edit);
    try testing.expectEqualStrings("main", back.req.actor.agent.parent.?);
    try testing.expectEqualStrings(req.detail_json, back.req.detail_json);
    try testing.expectEqual(@as(i64, 42), back.req.created_ms);
    try testing.expectEqual(@as(?i64, 50), back.answered_ms);
    try testing.expectEqual(item.previous, back.previous);
    try testing.expectError(error.InvalidRecord, broker_mod.readRecord(arena, .{ .integer = 1 }));
}
