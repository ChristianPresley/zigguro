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

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_review = @import("zg_review");

const Agent = zg_ai.loop.Agent;
const fb = zg_review.feedback;

pub const ReviewAgentPort = struct {
    agent: *Agent,

    pub fn port(p: *ReviewAgentPort) fb.AgentPort {
        return .{ .ctx = p, .status = status, .submit = submit, .resumeSession = resumeSession, .newSession = newSession };
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

test "review agent port: statuses" {
    const T = std.testing;
    try T.expectEqual(fb.AgentStatus.running, ReviewAgentPort.statusOf(.running_tools));
    try T.expectEqual(fb.AgentStatus.running, ReviewAgentPort.statusOf(.streaming));
    try T.expectEqual(fb.AgentStatus.idle, ReviewAgentPort.statusOf(.idle));
    try T.expectEqual(fb.AgentStatus.idle, ReviewAgentPort.statusOf(.done));
}
