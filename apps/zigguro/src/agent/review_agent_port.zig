//! E12's `AgentPort` over the workbench agent (E10): review fix requests
//! (zg_review.feedback) reach the agent through it.
//!
//! - The workbench runs one agent, so another session counts as ended.
//! - Statuses: `idle`, `done`, `failed`, `canceled` and `waiting_user`
//!   are idle (a new turn); the others are running (the request steers,
//!   at the next tool boundary).
//! - Sessions are not saved yet, so resuming fails (`error.Unsupported`);
//!   "new session" sends the request to the workbench agent and names
//!   its session.
//!
//! `outcomeSink` queues review outcomes as reminders for the workbench
//! agent's next request; outcomes for other sessions are dropped.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_review = @import("zg_review");

const Agent = zg_ai.loop.Agent;
const fb = zg_review.feedback;

pub const ReviewAgentPort = struct {
    agent: *Agent,
    /// The agent's reminders (its context stack).
    reminders: ?*zg_ai.context.reminders.ReminderQueue = null,

    pub fn port(p: *ReviewAgentPort) fb.AgentPort {
        return .{ .ctx = p, .status = status, .submit = submit, .resumeSession = resumeSession, .newSession = newSession };
    }

    pub fn outcomeSink(p: *ReviewAgentPort) fb.OutcomeSink {
        return .{ .ctx = p, .deliver = deliverOutcome };
    }

    fn deliverOutcome(ctx: *anyopaque, o: *const fb.Outcome) void {
        const p = cast(ctx);
        const q = p.reminders orelse return;
        if (o.session != p.agent.ref.session) return;
        queueOutcome(q, o);
    }

    /// Renders `o` into `q`.
    pub fn queueOutcome(q: *zg_ai.context.reminders.ReminderQueue, o: *const fb.Outcome) void {
        var aw: std.Io.Writer.Allocating = .init(q.gpa);
        defer aw.deinit();
        fb.outcome.render(o, &aw.writer, 2000) catch return;
        q.push(.other, aw.written());
    }

    fn cast(ctx: *anyopaque) *ReviewAgentPort {
        return @ptrCast(@alignCast(ctx));
    }

    fn status(ctx: *anyopaque, s: u128) fb.AgentStatus {
        const a = cast(ctx).agent;
        if (a.ref.session != s) return .ended;
        return statusOf(a.snapshot().status);
    }

    pub fn statusOf(s: zg_ai.loop.events.Status) fb.AgentStatus {
        return switch (s) {
            .idle, .done, .failed, .canceled, .waiting_user => .idle,
            .thinking, .streaming, .running_tools, .awaiting_approval, .retrying, .compacting => .running,
        };
    }

    fn submit(ctx: *anyopaque, _: u128, msg: *const fb.FeedbackMessage, mode: fb.SubmitMode) anyerror!void {
        _ = try cast(ctx).agent.submit(.{ .text = msg.text, .mode = if (mode == .steer) .steer else .queue, .source = .ui });
    }

    fn resumeSession(_: *anyopaque, _: u128) anyerror!void {
        return error.Unsupported;
    }

    fn newSession(ctx: *anyopaque, msg: *const fb.FeedbackMessage) anyerror!u128 {
        const a = cast(ctx).agent;
        _ = try a.submit(.{ .text = msg.text, .source = .ui });
        return a.ref.session;
    }
};

test "review agent port: outcomes become reminders" {
    const T = std.testing;
    var q: zg_ai.context.reminders.ReminderQueue = .init(T.allocator, T.io);
    defer q.deinit();
    const files = [_]fb.FileOutcome{.{ .path = "a.zig", .accepted = 0, .rejected = 1, .edited = 0, .pending = 0 }};
    const o: fb.Outcome = .{ .cs = @enumFromInt(4), .session = 1, .label = "Turn 1", .files = &files, .comments = &.{}, .final = true };
    ReviewAgentPort.queueOutcome(&q, &o);
    try T.expectEqual(@as(usize, 1), q.len());
    var arena: std.heap.ArenaAllocator = .init(T.allocator);
    defer arena.deinit();
    const got = try q.drain(arena.allocator());
    try T.expect(std.mem.indexOf(u8, got[0], "Review outcome #4 (\"Turn 1\"):\n- a.zig: rejected (1/1)") != null);
}

test "review agent port: statuses" {
    const T = std.testing;
    try T.expectEqual(fb.AgentStatus.running, ReviewAgentPort.statusOf(.running_tools));
    try T.expectEqual(fb.AgentStatus.running, ReviewAgentPort.statusOf(.streaming));
    try T.expectEqual(fb.AgentStatus.idle, ReviewAgentPort.statusOf(.idle));
    try T.expectEqual(fb.AgentStatus.idle, ReviewAgentPort.statusOf(.done));
}
