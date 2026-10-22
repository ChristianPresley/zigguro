//! `Agent`: one conversation with a model, driven by a turn task that
//! alternates model calls and tool batches until the model ends its turn
//! (see turn.zig). The same type serves the GUI, the CLI and subagents.
//!
//! Threading: `submit`, `cancel`, `subscribe` and `snapshot` may be called
//! from any thread. The turn task is the only writer of the transcript and
//! the only event producer. It runs in the agent's `Io.Group`; `cancel`
//! cancels the group, which interrupts streaming, tools and backoff waits.

const std = @import("std");
const proto = @import("zg_ai_proto");
const ev = @import("events.zig");
const busm = @import("bus.zig");
const budget = @import("budget.zig");
const scheduler = @import("scheduler.zig");
const dp = @import("deps.zig");
const iq = @import("input_queue.zig");
const turn = @import("turn.zig");
const registry = @import("../models/registry.zig");
const ledger = @import("../models/ledger.zig");
const estimate = @import("../models/estimate.zig");

const Agent = @This();
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const UserInput = iq.UserInput;
pub const InputId = iq.InputId;

pub const Config = struct {
    /// Model id or alias.
    model: []const u8,
    system_append: ?[]const u8 = null,
    cwd: []const u8 = ".",
    budgets: budget.Budgets = .{},
    policy: scheduler.Policy = .{},
    parent: ?proto.AgentRef = null,
    /// The parent's tool call that spawned this subagent.
    spawned_by: ?[]const u8 = null,
    depth: u8 = 0,
    role: registry.Role = .main,
    /// Output cap per request; defaults to the profile, then 16k (capped
    /// by the model's limit).
    max_output_tokens: ?u32 = null,
    max_stop_hook_continuations: u8 = 3,
    /// `ai.autoContinueOnMaxTokens`.
    auto_continue: bool = true,
    /// `ai.refusalFallbackModel`.
    refusal_fallback: ?[]const u8 = null,
    /// The session id of a top-level agent (a resumed or forked session);
    /// generated when null. Ignored for subagents.
    session: ?proto.SessionId = null,
};

pub const Deps = struct {
    registry: *registry.ModelRegistry,
    providers: dp.Providers,
    tools: dp.Tools = .none,
    permission: dp.Permission = .allow_all,
    context: dp.ContextBuilder = .basic,
    session: ?dp.SessionLog = null,
    hooks: ?dp.Hooks = null,
    ledger: ?*ledger.CostLedger = null,
    estimator: ?*estimate.TokenEstimator = null,
    /// E12 checkpoints taken at the start of each user turn.
    checkpoints: ?dp.Checkpoints = null,
};

/// A checkpoint and the sequence number of its event.
pub const CheckpointMark = struct { seq: u64, id: u64 };

/// An immutable view of the agent's state.
pub const Snapshot = struct {
    status: ev.Status,
    turns: u32,
    usage: proto.Usage,
    cost_micros: u64,
    estimated: bool,
    messages: usize,
    queued: usize,
    last_finish: ?ev.FinishReason,
};

gpa: Allocator,
io: Io,
ref: proto.AgentRef,
cfg: Config,
deps: Deps,
/// Owns the transcript and event payloads; written only by the turn task.
arena: std.heap.ArenaAllocator,
transcript: std.ArrayList(proto.Message) = .empty,
/// The bus (and session record) sequence number of each transcript message.
seqs: std.ArrayList(u64) = .empty,
/// E12 checkpoints taken at the start of user turns, oldest first.
checkpoints: std.ArrayList(CheckpointMark) = .empty,
bus: busm.Bus,

/// Guards the fields below.
mutex: Io.Mutex = .init,
queue: iq.InputQueue = .{},
steer: iq.InputQueue = .{},
running: bool = false,
status: ev.Status = .idle,
used: budget.Used = .{},
estimated: bool = false,
last_finish: ?ev.FinishReason = null,
children: std.ArrayList(*Agent) = .empty,

/// Guards `arena` while tool tasks run (progress chunks).
alloc_mutex: Io.Mutex = .init,

/// Serializes group operations (`Io.Group` is not thread-safe).
group_mutex: Io.Mutex = .init,
group: Io.Group = .init,
/// Set once the previous turn task has published its last event.
finished: Io.Event = .is_set,

// Turn-task state.
turn_id: ev.TurnId = 0,
warned: budget.WarnOnce = .{},
wall: budget.WallClock,
last_cache_read: u64 = 0,

pub fn create(gpa: Allocator, io: Io, ref: proto.AgentRef, cfg: Config, d: Deps) Allocator.Error!*Agent {
    const a = try gpa.create(Agent);
    errdefer gpa.destroy(a);
    a.* = .{ .gpa = gpa, .io = io, .ref = ref, .cfg = cfg, .deps = d, .arena = .init(gpa), .bus = .init(gpa, io), .wall = .start(io) };
    errdefer a.arena.deinit();
    const ar = a.arena.allocator();
    a.cfg.model = try ar.dupe(u8, cfg.model);
    a.cfg.cwd = try ar.dupe(u8, cfg.cwd);
    if (cfg.system_append) |s| a.cfg.system_append = try ar.dupe(u8, s);
    if (cfg.refusal_fallback) |s| a.cfg.refusal_fallback = try ar.dupe(u8, s);
    if (ref.tool_call) |t| a.ref.tool_call = try ar.dupe(u8, t);
    return a;
}

/// Cancels everything, drains subscribers and frees the agent.
pub fn destroy(a: *Agent) void {
    a.cancel(.everything);
    a.bus.deinit();
    a.queue.deinit(a.gpa);
    a.steer.deinit(a.gpa);
    a.children.deinit(a.gpa);
    a.arena.deinit();
    a.gpa.destroy(a);
}

/// Queues an input; starts a turn when idle. `error.Busy` when 64 inputs
/// are already waiting.
pub fn submit(a: *Agent, in: UserInput) (error{Busy} || Allocator.Error || Io.ConcurrentError)!InputId {
    const id, const interrupt = blk: {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        const to_steer = in.mode == .steer and a.status == .running_tools;
        const id = try (if (to_steer) &a.steer else &a.queue).push(a.gpa, in);
        break :blk .{ id, in.mode == .interrupt and a.running };
    };
    if (interrupt) {
        a.cancel(.turn);
    } else {
        a.group_mutex.lockUncancelable(a.io);
        defer a.group_mutex.unlock(a.io);
        try a.ensureRunning();
    }
    return id;
}

/// Starts the turn task unless it runs. Hold `group_mutex`.
fn ensureRunning(a: *Agent) Io.ConcurrentError!void {
    {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        if (a.running or a.queue.len() == 0) return;
        a.running = true;
    }
    // The previous task has published its last event; release it.
    a.finished.waitUncancelable(a.io);
    a.group.await(a.io) catch {};
    a.finished.reset();
    a.group.concurrent(a.io, turn.runTurns, .{a}) catch |e| {
        a.mutex.lockUncancelable(a.io);
        a.running = false;
        a.mutex.unlock(a.io);
        a.finished.set(a.io);
        return e;
    };
}

pub const CancelWhat = enum { turn, everything };

/// Cancels the running turn (partial output is committed, every tool call
/// gets a result). `everything` also drops queued input and cancels
/// subagents. Thread-safe and idempotent; returns once the turn task has
/// stopped. Queued input then starts a new turn.
pub fn cancel(a: *Agent, what: CancelWhat) void {
    const kids = blk: {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        if (what == .everything) {
            a.queue.clear(a.gpa);
            a.steer.clear(a.gpa);
            break :blk a.gpa.dupe(*Agent, a.children.items) catch &.{};
        }
        break :blk &.{};
    };
    defer a.gpa.free(kids);
    for (kids) |k| k.cancel(.everything);
    a.group_mutex.lockUncancelable(a.io);
    defer a.group_mutex.unlock(a.io);
    a.group.cancel(a.io);
    a.ensureRunning() catch {};
}

/// Blocks until the agent is idle with nothing queued (tests, CLI).
pub fn waitIdle(a: *Agent) void {
    while (true) {
        {
            a.mutex.lockUncancelable(a.io);
            defer a.mutex.unlock(a.io);
            if (!a.running and a.queue.len() == 0) break;
        }
        a.finished.waitUncancelable(a.io);
        a.io.sleep(.fromMilliseconds(1), .awake) catch return;
    }
    a.finished.waitUncancelable(a.io);
}

pub fn subscribe(a: *Agent, s: busm.Subscriber) (Allocator.Error || Io.ConcurrentError)!busm.SubscriptionId {
    return a.bus.subscribe(s);
}

pub fn unsubscribe(a: *Agent, id: busm.SubscriptionId) void {
    a.bus.unsubscribe(id);
}

pub fn snapshot(a: *Agent) Snapshot {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    return .{
        .status = a.status,
        .turns = a.used.turns,
        .usage = a.used.usage,
        .cost_micros = a.used.cost_micros,
        .estimated = a.estimated,
        .messages = a.transcript.items.len,
        .queued = a.queue.len() + a.steer.len(),
        .last_finish = a.last_finish,
    };
}

/// The transcript. Stable only while the agent is idle.
pub fn messages(a: *Agent) []const proto.Message {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    return a.transcript.items;
}

/// The sequence number of transcript message `i` (0 when unknown).
pub fn messageSeq(a: *Agent, i: usize) u64 {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    return if (i < a.seqs.items.len) a.seqs.items[i] else 0;
}

/// Replaces the transcript (resume, rewind, compaction) with deep copies
/// of `msgs`, whose sequence numbers are `seqs`. Numbering continues
/// after `last_seq`. Only while the agent is idle.
pub fn setTranscript(a: *Agent, msgs: []const proto.Message, seqs: []const u64, last_seq: u64) (error{Busy} || Allocator.Error)!void {
    std.debug.assert(msgs.len == seqs.len);
    const ar = a.arena.allocator();
    const copy = try ar.alloc(proto.Message, msgs.len);
    for (msgs, copy) |m, *c| c.* = try proto.json.cloneMessage(ar, m);
    {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        if (a.running) return error.Busy;
        a.transcript.clearRetainingCapacity();
        try a.transcript.appendSlice(ar, copy);
        a.seqs.clearRetainingCapacity();
        try a.seqs.appendSlice(ar, seqs);
    }
    // The bus lock is never taken under the agent lock.
    a.bus.startAt(last_seq);
}

/// Replaces the known checkpoints (a resume).
pub fn setCheckpoints(a: *Agent, marks: []const CheckpointMark) Allocator.Error!void {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    a.checkpoints.clearRetainingCapacity();
    try a.checkpoints.appendSlice(a.arena.allocator(), marks);
}

/// The latest checkpoint taken before sequence number `seq`.
pub fn checkpointBefore(a: *Agent, seq: u64) ?CheckpointMark {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    var best: ?CheckpointMark = null;
    for (a.checkpoints.items) |c| if (c.seq < seq and (best == null or c.seq > best.?.seq)) {
        best = c;
    };
    return best;
}

/// Drops the transcript from message `len` on (a conversation rewind).
/// Only while the agent is idle.
pub fn truncate(a: *Agent, len: usize) error{Busy}!void {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    if (a.running) return error.Busy;
    a.transcript.items.len = @min(a.transcript.items.len, len);
    a.seqs.items.len = @min(a.seqs.items.len, len);
}

/// Registers a subagent for `cancel(.everything)`.
pub fn addChild(a: *Agent, child: *Agent) Allocator.Error!void {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    try a.children.append(a.gpa, child);
}

pub fn removeChild(a: *Agent, child: *Agent) void {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    for (a.children.items, 0..) |c, i| if (c == child) {
        _ = a.children.swapRemove(i);
        return;
    };
}

// Used by turn.zig.

pub fn setStatus(a: *Agent, s: ev.Status) void {
    {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        if (a.status == s) return;
        a.status = s;
    }
    a.bus.publish(.{ .status = s });
}

/// A copy of the spend so far.
pub fn usedSnapshot(a: *Agent) budget.Used {
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    return a.used;
}

pub fn publish(a: *Agent, e: ev.AgentEvent) void {
    a.bus.publish(e);
}
