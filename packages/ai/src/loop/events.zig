//! `AgentEvent`: everything an agent does, in order. Payload slices point
//! into the agent's append-only transcript arena and stay valid until the
//! agent is disposed, so subscribers may keep them without copying.

const std = @import("std");
const proto = @import("zg_ai_proto");
const pevents = @import("../provider/events.zig");
const budget = @import("budget.zig");

pub const TurnId = u32;

/// Agent lifecycle state; every change is published as `status`.
pub const Status = enum { idle, thinking, streaming, running_tools, awaiting_approval, waiting_user, retrying, compacting, done, failed, canceled };

pub const RequestInfo = struct {
    turn: TurnId,
    model: []const u8,
    messages: u32,
    tools: u32,
    est_input_tokens: u64,
};

/// Index of a committed message in the agent's transcript.
pub const MessageRef = struct {
    index: u32,
    role: proto.Role,
    /// Partial message committed after a cancel or error.
    interrupted: bool = false,
};

pub const ToolCallInfo = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
};

pub const ToolFinished = struct {
    id: []const u8,
    name: []const u8,
    is_error: bool,
    /// Not executed (an earlier mutation failed, or the turn was canceled).
    skipped: bool = false,
};

pub const UsageTotals = struct {
    /// This request.
    last: proto.Usage,
    /// The agent so far.
    total: proto.Usage,
    cost_micros: u64,
    estimated: bool,
};

pub const RetryInfo = struct {
    attempt: u8,
    delay_ms: u64,
    status: ?u16,
    err: []const u8,
};

pub const RecoveryInfo = struct {
    action: []const u8,
    detail: []const u8 = "",
};

pub const BudgetInfo = struct {
    kind: budget.Kind,
    level: enum { warn, stop },
};

pub const ErrorInfo = struct {
    kind: []const u8,
    message: []const u8,
    request_id: ?[]const u8 = null,
};

/// An E12 checkpoint taken at the start of a user turn.
pub const CheckpointInfo = struct {
    id: u64,
    turn: TurnId,
    label: []const u8,
};

/// One `todo_write` item.
pub const Todo = struct {
    id: []const u8,
    content: []const u8,
    status: enum { pending, in_progress, completed },
    active_form: ?[]const u8 = null,
};

/// The agent waits on the user (`ask_user`; `exit_plan_mode` later).
pub const ApprovalNeeded = struct {
    kind: enum { question, plan },
    /// The tool call id; the answer names it.
    id: []const u8,
    /// Who asks: empty for the main agent, else the subagent's name.
    label: []const u8 = "",
    /// The questions or plan as JSON.
    json: []const u8,
};

pub const FinishReason = enum { end_turn, budget, blocked, canceled, failed, max_turns, refusal, max_tokens };

pub const TurnFinished = struct {
    turn: TurnId,
    reason: FinishReason,
    budget_kind: ?budget.Kind = null,
};

/// One agent event.
pub const AgentEvent = union(enum) {
    turn_started: TurnId,
    checkpoint: CheckpointInfo,
    request_sent: RequestInfo,
    /// A provider stream event of the in-progress assistant message.
    stream: pevents.StreamEvent,
    message_committed: MessageRef,
    tool_queued: ToolCallInfo,
    tool_started: []const u8,
    tool_progress: struct { id: []const u8, chunk: []const u8 },
    /// A validation, hook, permission or bounding decision about a call.
    tool_decision: @import("deps.zig").ToolDecision,
    tool_finished: ToolFinished,
    usage: UsageTotals,
    retrying: RetryInfo,
    recovery: RecoveryInfo,
    budget: BudgetInfo,
    /// A user input was queued, steered or interrupted.
    input_queued: struct { mode: []const u8 },
    warning: []const u8,
    error_: ErrorInfo,
    turn_finished: TurnFinished,
    status: Status,
    /// `exit_plan_mode` presented a plan for approval.
    plan_proposed: []const u8,
    /// The plan was approved; the agent now runs in `mode`.
    plan_approved: struct { mode: []const u8, path: []const u8 },
    /// `todo_write` changed the agent's list (the whole new list).
    todo_changed: []const Todo,
    approval_needed: ApprovalNeeded,

    /// Structural events are never coalesced or dropped.
    pub fn isDelta(e: AgentEvent) bool {
        return e == .stream and (e.stream == .text_delta or e.stream == .thinking_delta);
    }
};

/// An event with its per-agent sequence number.
pub const Envelope = struct {
    seq: u64,
    ev: AgentEvent,
};

/// Writes one envelope as a JSON line (golden logs, stream-json, debugging).
pub fn writeJson(w: *std.Io.Writer, e: Envelope) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("seq");
    try s.write(e.seq);
    try s.objectField("type");
    try s.write(@tagName(e.ev));
    switch (e.ev) {
        .stream => |se| {
            try s.objectField("event");
            try s.write(@tagName(se));
            switch (se) {
                .text_delta => |d| {
                    try s.objectField("text");
                    try s.write(d.text);
                },
                .thinking_delta => |d| {
                    try s.objectField("text");
                    try s.write(d.text);
                },
                .tool_input_delta => |d| {
                    try s.objectField("json");
                    try s.write(d.partial_json);
                },
                .block_start => |b| {
                    try s.objectField("kind");
                    try s.write(@tagName(b.kind));
                    if (b.tool_name) |n| {
                        try s.objectField("name");
                        try s.write(n);
                    }
                },
                .stop => |r| {
                    try s.objectField("reason");
                    try s.write(@tagName(r));
                },
                else => {},
            }
        },
        inline else => |payload| {
            if (@TypeOf(payload) != void) {
                try s.objectField("data");
                try s.write(payload);
            }
        },
    }
    try s.endObject();
}

test "json line" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJson(&w, .{ .seq = 3, .ev = .{ .tool_finished = .{ .id = "t1", .name = "read", .is_error = false } } });
    try std.testing.expectEqualStrings(
        \\{"seq":3,"type":"tool_finished","data":{"id":"t1","name":"read","is_error":false,"skipped":false}}
    , w.buffered());
    w = .fixed(&buf);
    try writeJson(&w, .{ .seq = 4, .ev = .{ .stream = .{ .text_delta = .{ .index = 0, .text = "hi" } } } });
    try std.testing.expectEqualStrings(
        \\{"seq":4,"type":"stream","event":"text_delta","text":"hi"}
    , w.buffered());
}
