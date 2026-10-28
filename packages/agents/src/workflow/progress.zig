//! Workflow progress (E13.F08.S01.T03): per-step counters the engine
//! updates as agents start and finish, and the immutable snapshot the
//! progress view (E13.F08.S01.T02) and `workflow_status` read. Updates are
//! a few integer writes under a mutex; `snapshot` copies the counters into
//! the caller's arena (one per frame), so readers never block the engine
//! for longer than that copy.

const std = @import("std");
const def = @import("def.zig");
const run = @import("../runs/run.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const StepState = enum { pending, running, waiting, done, failed, skipped };

pub const StepProgress = struct {
    id: []const u8,
    phase: ?[]const u8,
    kind: def.StepKind,
    label: ?[]const u8,
    /// The parallel step this is a branch of.
    parent: ?[]const u8 = null,
    state: StepState = .pending,
    /// Agents (or map items) the step will run; 0 until known.
    total: u32 = 0,
    running: u32 = 0,
    done: u32 = 0,
    failed: u32 = 0,
    /// Results taken from the previous journal on resume.
    reused: u32 = 0,
    /// Stall restarts and schema retries.
    retries: u32 = 0,
    /// Loop rounds so far.
    round: u32 = 0,
    error_: ?[]const u8 = null,
};

pub const Gate = struct { step: []const u8, title: []const u8, show: []const u8 };

pub const WorkerState = enum { running, done, failed, stopped };

/// One agent attempt of the workflow (a child run).
pub const Worker = struct {
    child: run.RunId,
    step: []const u8,
    /// Plan position (`audit#3`).
    pos: []const u8,
    /// 0 for the first try.
    attempt: u8,
    prompt: []const u8,
    state: WorkerState = .running,
    started_ms: i64,
    ended_ms: ?i64 = null,
    cost: run.Cost = .{},
    /// The answer (at most `max_text` bytes) or why the attempt ended.
    text: []const u8 = "",
};

/// Answers longer than this are cut in the progress (the full result is
/// in the step's result and the child's transcript).
pub const max_text = 16 * 1024;

pub const WorkflowProgress = struct {
    run: run.RunId,
    name: []const u8,
    status: run.RunStatus,
    steps: []const StepProgress,
    /// Agents started (attempts included).
    agents: u32,
    cost: run.Cost,
    gate: ?Gate = null,
    error_: ?[]const u8 = null,
    /// Every agent attempt, in start order.
    workers: []const Worker = &.{},
    started_ms: i64 = 0,
    /// `limits.max_cost_micros`.
    budget_micros: ?u64 = null,
    /// Bumped by every change.
    version: u64,
};

mutex: Io.Mutex = .init,
io: Io,
/// Owns names and messages.
arena: Allocator,
name: []const u8,
id: run.RunId,
status: run.RunStatus = .queued,
steps: []StepProgress,
agents: u32 = 0,
cost: run.Cost = .{},
gate: ?Gate = null,
error_: ?[]const u8 = null,
workers: std.ArrayList(Worker) = .empty,
/// Child run → index in `workers`.
by_child: std.AutoHashMapUnmanaged(u128, u32) = .empty,
started_ms: i64 = 0,
budget_micros: ?u64 = null,
version: u64 = 1,

const Tracker = @This();

/// One row per step in plan order, branches after their parallel step.
pub fn init(arena: Allocator, io: Io, id: run.RunId, d: *const def.WorkflowDef) Allocator.Error!Tracker {
    var rows: std.ArrayList(StepProgress) = .empty;
    for (d.steps) |*s| {
        try rows.append(arena, row(s, null));
        if (s.parallel) |br| for (br) |*b| try rows.append(arena, row(b, s.id));
    }
    return .{ .io = io, .arena = arena, .name = d.name, .id = id, .steps = rows.items, .budget_micros = d.limits.max_cost_micros };
}

fn row(s: *const def.NamedStep, parent: ?[]const u8) StepProgress {
    const label: ?[]const u8 = switch (s.step().?) {
        .agent, .reduce => |a| a.label,
        .map => |m| if (m.agent) |a| a.label else null,
        .vote => |v| v.agent.label,
        .loop_until => |l| l.agent.label,
        .gate => |g| g.title,
        else => null,
    };
    return .{ .id = s.id, .phase = s.phase, .kind = s.kind().?, .label = label, .parent = parent };
}

pub fn indexOf(t: *const Tracker, id: []const u8) ?usize {
    for (t.steps, 0..) |s, i| if (std.mem.eql(u8, s.id, id)) return i;
    return null;
}

pub fn setState(t: *Tracker, id: []const u8, s: StepState) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    const i = t.indexOf(id) orelse return;
    t.steps[i].state = s;
    t.version += 1;
}

pub fn setTotal(t: *Tracker, id: []const u8, n: u32) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    const i = t.indexOf(id) orelse return;
    t.steps[i].total = n;
    t.version += 1;
}

pub fn setRound(t: *Tracker, id: []const u8, r: u32) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    const i = t.indexOf(id) orelse return;
    t.steps[i].round = r;
    t.version += 1;
}

/// `item_ok`/`item_failed` count map items with a command or builtin
/// body (no agent).
pub const Change = enum { started, retried, ok, failed, reused, item_ok, item_failed };

/// Counts one agent of step `id`.
pub fn agent(t: *Tracker, id: []const u8, c: Change) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    if (c == .started or c == .retried) t.agents += 1;
    const i = t.indexOf(id) orelse return;
    const s = &t.steps[i];
    switch (c) {
        .started => s.running += 1,
        .retried => s.retries += 1,
        .ok => {
            s.running -|= 1;
            s.done += 1;
        },
        .failed => {
            s.running -|= 1;
            s.failed += 1;
        },
        .reused => {
            s.done += 1;
            s.reused += 1;
        },
        .item_ok => s.done += 1,
        .item_failed => s.failed += 1,
    }
    t.version += 1;
}

pub fn fail(t: *Tracker, id: []const u8, msg: []const u8) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    const i = t.indexOf(id) orelse return;
    t.steps[i].state = .failed;
    t.steps[i].error_ = t.arena.dupe(u8, msg) catch null;
    t.version += 1;
}

/// Records an agent attempt that just started (`prompt` must outlive the
/// tracker; the engine's arena owns it).
pub fn workerStarted(t: *Tracker, w: Worker) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    t.by_child.put(t.arena, w.child.toInt(), @intCast(t.workers.items.len)) catch return;
    t.workers.append(t.arena, w) catch {
        _ = t.by_child.remove(w.child.toInt());
        return;
    };
    t.version += 1;
}

pub fn workerEnded(t: *Tracker, child: run.RunId, state: WorkerState, text: []const u8, now_ms: i64) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    const i = t.by_child.get(child.toInt()) orelse return;
    const w = &t.workers.items[i];
    w.state = state;
    w.ended_ms = now_ms;
    w.text = t.arena.dupe(u8, text[0..@min(text.len, max_text)]) catch "";
    t.version += 1;
}

/// The child's cumulative cost.
pub fn workerCost(t: *Tracker, child: run.RunId, c: run.Cost) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    const i = t.by_child.get(child.toInt()) orelse return;
    t.workers.items[i].cost = c;
    t.version += 1;
}

pub fn setCost(t: *Tracker, c: run.Cost) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    t.cost = c;
    t.version += 1;
}

pub fn setStatus(t: *Tracker, s: run.RunStatus, err: ?[]const u8) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    t.status = s;
    if (err) |e| t.error_ = t.arena.dupe(u8, e) catch null;
    t.version += 1;
}

pub fn setGate(t: *Tracker, g: ?Gate) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    t.gate = g;
    t.version += 1;
}

/// A copy of the current state in `arena`. Strings are shared with the
/// tracker and live as long as the engine keeps the run.
pub fn snapshot(t: *Tracker, arena: Allocator) Allocator.Error!WorkflowProgress {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    return .{
        .run = t.id,
        .name = t.name,
        .status = t.status,
        .steps = try arena.dupe(StepProgress, t.steps),
        .agents = t.agents,
        .cost = t.cost,
        .gate = t.gate,
        .error_ = t.error_,
        .workers = try arena.dupe(Worker, t.workers.items),
        .started_ms = t.started_ms,
        .budget_micros = t.budget_micros,
        .version = t.version,
    };
}
