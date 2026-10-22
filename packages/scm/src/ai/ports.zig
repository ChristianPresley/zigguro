//! The AI workflow ports (E09.F06.S01.T01), shared by describe, split,
//! resolve and lane landing. zg_scm builds contexts, prompts and
//! proposals; other packages plug in behind these interfaces:
//!
//! - `ModelPort` (E10): streaming model calls, structured output capable;
//! - `ReviewPort` (E12): every proposal becomes a review item, and nothing
//!   reaches visible history until it is approved;
//! - `CheckPort` (E13/E10): runs a landing check in a workspace;
//! - `NotificationPort` (E10/E04): tells a lane's owner what happened.
//!
//! A proposal's mutation is a detached preview operation (E09.F03.S02.T02):
//! approval adopts it, rejection discards it. Every port uses std types
//! only, so implementations need not depend on more of zg_scm than this.
//! Callbacks run on the caller's (ScmService worker) thread.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const operation = @import("../oplog/operation.zig");
const preview = @import("../oplog/preview.zig");
const ObjectId = id_mod.ObjectId;

// ---------------------------------------------------------------- model

pub const Role = enum { user, assistant };

pub const AiMessage = struct { role: Role, text: []const u8 };

pub const AiRequest = struct {
    system: []const u8,
    messages: []const AiMessage,
    /// A JSON schema the reply must match, when the provider supports
    /// structured output; otherwise the caller parses text.
    json_schema: ?[]const u8 = null,
    max_input_tokens: u32,
    max_output_tokens: u32 = 4096,
    /// Set by the caller to stop the call early.
    cancel: ?*const std.atomic.Value(bool) = null,

    pub fn cancelled(r: *const AiRequest) bool {
        const c = r.cancel orelse return false;
        return c.load(.acquire);
    }
};

pub const StopReason = enum { end, max_tokens, cancelled };

pub const Usage = struct { input_tokens: u32 = 0, output_tokens: u32 = 0 };

/// Streamed results of one call: any number of `onText` / `onJson`
/// chunks, then exactly one of `onDone` or `onError`. Chunks are only
/// valid during the callback.
pub const AiSink = struct {
    ctx: *anyopaque,
    onText: *const fn (ctx: *anyopaque, chunk: []const u8) void,
    /// A chunk of structured (JSON) output; concatenated, the chunks form
    /// one document.
    onJson: *const fn (ctx: *anyopaque, chunk: []const u8) void,
    onDone: *const fn (ctx: *anyopaque, reason: StopReason, usage: Usage) void,
    onError: *const fn (ctx: *anyopaque, message: []const u8) void,

    pub fn text(s: *AiSink, chunk: []const u8) void {
        s.onText(s.ctx, chunk);
    }
    pub fn json(s: *AiSink, chunk: []const u8) void {
        s.onJson(s.ctx, chunk);
    }
    pub fn done(s: *AiSink, reason: StopReason, usage: Usage) void {
        s.onDone(s.ctx, reason, usage);
    }
    pub fn fail(s: *AiSink, message: []const u8) void {
        s.onError(s.ctx, message);
    }
};

/// Implemented by E10.
pub const ModelPort = struct {
    ctx: *anyopaque,
    /// Streams the reply into `sink`. A returned error means the call
    /// could not start; failures after that go to `sink.onError`.
    complete: *const fn (ctx: *anyopaque, req: *const AiRequest, sink: *AiSink) anyerror!void,

    pub fn call(p: ModelPort, req: *const AiRequest, sink: *AiSink) !void {
        return p.complete(p.ctx, req, sink);
    }
};

// --------------------------------------------------------------- review

/// E12's review item ID (a changeset ID there).
pub const ReviewId = u64;

pub const ReviewStatus = enum {
    /// Waiting for a decision.
    in_review,
    approved,
    rejected,
    /// Withdrawn or discarded without a decision.
    cancelled,
    /// The port does not know the ID.
    unknown,
};

/// A reviewer's decision, as the review UI forwards it (for lanes, to
/// `LandingQueue.onReviewDecision`).
pub const ReviewDecision = struct {
    verdict: Verdict,
    /// Who decided: a user name, or a policy name for automatic decisions.
    reviewer: []const u8,
    note: []const u8 = "",

    pub const Verdict = enum { approve, reject };
};

pub const ProposalKind = enum { describe, split, resolve, land };

/// Who a proposal comes from, recorded on the operation that applies it
/// (with `review` filled in by then).
pub const ProvenanceRecord = struct {
    actor: operation.Actor,
    /// The model that produced it, for agent actors.
    model: []const u8 = "",
    review: ?ReviewId = null,
};

pub const Proposal = struct {
    kind: ProposalKind,
    /// The preview: a detached operation over `preview_op.base_op`. E12
    /// renders the diff between the current view and this one.
    preview_op: preview.DetachedOp,
    /// One line, shown as the review item's label.
    summary: []const u8,
    /// The commits the proposal creates or rewrites, in the preview view.
    changes: []const ObjectId,
    provenance: ProvenanceRecord,
    /// Why, in the proposer's words (may be empty).
    rationale: []const u8 = "",
    /// For `land`: the lane name.
    lane: []const u8 = "",
};

/// Implemented by E12.
pub const ReviewPort = struct {
    ctx: *anyopaque,
    /// Creates the review item. The proposal's slices are only valid
    /// during the call.
    submit: *const fn (ctx: *anyopaque, proposal: *const Proposal) anyerror!ReviewId,
    status: *const fn (ctx: *anyopaque, id: ReviewId) ReviewStatus,

    pub fn submitProposal(p: ReviewPort, proposal: *const Proposal) !ReviewId {
        return p.submit(p.ctx, proposal);
    }
    pub fn statusOf(p: ReviewPort, id: ReviewId) ReviewStatus {
        return p.status(p.ctx, id);
    }
};

// --------------------------------------------------------------- checks

pub const CheckSpec = struct {
    name: []const u8,
    /// argv, run in the workspace root.
    command: []const []const u8,
    timeout_s: u32 = 900,
};

pub const CheckResult = struct {
    passed: bool,
    exit_code: ?i32 = null,
    timed_out: bool = false,
    /// The tail of the log, owned by the port until the next call.
    log_tail: []const u8 = "",
    duration_ms: u64 = 0,
};

/// Streams check output as it arrives.
pub const CheckSink = struct {
    ctx: *anyopaque,
    onLog: *const fn (ctx: *anyopaque, check: []const u8, chunk: []const u8) void,

    pub fn log(s: *CheckSink, check: []const u8, chunk: []const u8) void {
        s.onLog(s.ctx, check, chunk);
    }
};

/// Implemented by E13/E10.
pub const CheckPort = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, ws_root: []const u8, spec: *const CheckSpec, sink: *CheckSink) anyerror!CheckResult,

    pub fn runCheck(p: CheckPort, ws_root: []const u8, spec: *const CheckSpec, sink: *CheckSink) !CheckResult {
        return p.run(p.ctx, ws_root, spec, sink);
    }
};

// -------------------------------------------------------- notifications

pub const Notification = struct {
    /// The lane's owner: a user name or an agent session ID.
    owner: []const u8,
    level: Level,
    title: []const u8,
    body: []const u8 = "",
    /// The lane or review the notification is about, if any.
    lane: []const u8 = "",
    review: ?ReviewId = null,

    pub const Level = enum { info, warning, failure };
};

/// Implemented by E10 (inject into the agent session) and E04 (toast).
pub const NotificationPort = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, n: *const Notification) void,

    pub fn send(p: NotificationPort, n: *const Notification) void {
        p.notify(p.ctx, n);
    }
};
