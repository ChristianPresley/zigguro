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
version: u64 = 1,

const Tracker = @This();

/// One row per step in plan order, branches after their parallel step.
pub fn init(arena: Allocator, io: Io, id: run.RunId, d: *const def.WorkflowDef) Allocator.Error!Tracker {
    var rows: std.ArrayList(StepProgress) = .empty;
    for (d.steps) |*s| {
        try rows.append(arena, row(s, null));
        if (s.parallel) |br| for (br) |*b| try rows.append(arena, row(b, s.id));
    }
    return .{ .io = io, .arena = arena, .name = d.name, .id = id, .steps = rows.items };
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
        .version = t.version,
    };
}
