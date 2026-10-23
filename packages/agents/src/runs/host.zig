//! `RunHost` (E13.F01.S01.T02): turns `RunSpec`s into agents and drives
//! their lifecycle inside one process: queue, start, pause, resume, reply,
//! stop and attach, E09 lanes for isolated writers and E16 permission
//! profiles. Agent signals become `RunRegistry` updates.
//!
//! `start` only validates, records the run and queues it; a worker task
//! creates lanes and agents. Port calls are never made with `mutex` held,
//! because an agent may signal back synchronously.
//!
//! Pause is emulated: the host waits for the next tool boundary (or turn
//! end) and cancels the turn, keeping the session; resume submits a
//! continuation. Switch to E10's native pause when E10.F05.S02.T01 exposes
//! a pre-tool-call hook.

const std = @import("std");
const proto = @import("zg_ai_proto");
const run = @import("run.zig");
const queue_mod = @import("queue.zig");
const port = @import("port.zig");
const untrusted = @import("untrusted.zig");
const RunRegistry = @import("registry.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = run.RunId;
const RunKind = run.RunKind;

pub const HostConfig = struct {
    max_concurrent: u16 = 6,
    max_concurrent_per_kind: std.EnumArray(RunKind, u16) = .initFill(64),
    /// The working directory of runs that share the workspace.
    workspace_root: []const u8 = ".",
    /// Revset new lanes start from.
    lane_base: []const u8 = "trunk()",
    graceful_stop_ms: u32 = 5_000,
    /// Waits `ms` (tests pass a fake); defaults to `Io.sleep`.
    sleep: ?*const fn (ctx: ?*anyopaque, io: Io, ms: u32) void = null,
    sleep_ctx: ?*anyopaque = null,
};

pub const continue_text = "Continue from where you paused.";

pub const Error = error{ UnknownProfile, UnknownRun, NotWaiting, NotResumable, NotLive } || RunRegistry.Error;

pub const StopHow = enum { graceful, now };

/// A run this host knows about. Lives until `deinit` so that late agent
/// signals never touch freed memory.
const Live = struct {
    host: *RunHost,
    id: RunId,
    kind: RunKind,
    arena: std.heap.ArenaAllocator,
    /// The first message (prompt plus any wrapped payload).
    text: []const u8,
    model: ?[]const u8,
    agent_def: ?[]const u8,
    profile: []const u8,
    unattended: bool,
    isolation: run.Isolation,
    budgets: run.Budgets,
    // Under host.mutex:
    handle: ?usize = null,
    session: ?u128 = null,
    lane: ?[]const u8 = null,
    slot: bool = false,
    pause_req: bool = false,
    pause_sent: bool = false,
    stop_req: ?StopHow = null,
    resume_req: bool = false,
    done: bool = false,
    dispose_pending: bool = false,
};

gpa: Allocator,
io: Io,
reg: *RunRegistry,
agents: port.AgentPort,
lanes: ?port.LanePort,
profiles: port.ProfilePort,
cfg: HostConfig,

mutex: Io.Mutex = .init,
cond: Io.Condition = .init,
lives: std.AutoHashMapUnmanaged(u128, *Live) = .empty,
queue: queue_mod.RunQueue = .{},
counts: queue_mod.Counts = .{},
closing: bool = false,
group: Io.Group = .init,
/// Ops for the worker besides the queue.
disposals: std.ArrayList(usize) = .empty,

const RunHost = @This();

pub fn init(
    gpa: Allocator,
    io: Io,
    reg: *RunRegistry,
    agents: port.AgentPort,
    lanes: ?port.LanePort,
    profiles: port.ProfilePort,
    cfg: HostConfig,
) !*RunHost {
    const h = try gpa.create(RunHost);
    errdefer gpa.destroy(h);
    h.* = .{ .gpa = gpa, .io = io, .reg = reg, .agents = agents, .lanes = lanes, .profiles = profiles, .cfg = cfg };
    try h.group.concurrent(io, worker, .{h});
    return h;
}

/// Stops the worker and disposes every live agent. Runs still active are
/// left as they are in the registry (a later load marks them
/// interrupted, or a headless host takes them over first).
pub fn deinit(h: *RunHost) void {
    h.mutex.lockUncancelable(h.io);
    h.closing = true;
    h.cond.broadcast(h.io);
    h.mutex.unlock(h.io);
    h.group.cancel(h.io);
    var it = h.lives.valueIterator();
    while (it.next()) |l| {
        if (l.*.handle) |hd| h.agents.dispose(hd);
        l.*.arena.deinit();
        h.gpa.destroy(l.*);
    }
    h.lives.deinit(h.gpa);
    h.queue.deinit(h.gpa);
    h.disposals.deinit(h.gpa);
    h.gpa.destroy(h);
}

fn limits(h: *const RunHost) queue_mod.Limits {
    return .{ .max_concurrent = h.cfg.max_concurrent, .max_per_kind = h.cfg.max_concurrent_per_kind };
}

/// Records and queues a run; returns at once.
pub fn start(h: *RunHost, spec: run.RunSpec) Error!RunId {
    const profile = h.profiles.resolve(h.profiles.ctx, spec.profile) orelse return error.UnknownProfile;
    const id = try h.reg.create(spec);
    const l = try h.newLive(id, spec, profile);
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    try h.lives.put(h.gpa, id.toInt(), l);
    try h.queue.push(h.gpa, id, spec.kind);
    h.cond.signal(h.io);
    return id;
}

fn newLive(h: *RunHost, id: RunId, spec: run.RunSpec, profile: port.Profile) !*Live {
    const l = try h.gpa.create(Live);
    errdefer h.gpa.destroy(l);
    l.* = .{
        .host = h,
        .id = id,
        .kind = spec.kind,
        .arena = .init(h.gpa),
        .text = undefined,
        .model = null,
        .agent_def = null,
        .profile = undefined,
        .unattended = profile.unattended,
        .isolation = spec.isolation,
        .budgets = spec.budgets,
    };
    errdefer l.arena.deinit();
    const a = l.arena.allocator();
    l.text = if (spec.untrusted_payload) |p| try untrusted.wrap(a, spec.prompt, p) else try a.dupe(u8, spec.prompt);
    l.model = if (spec.model) |m| try a.dupe(u8, m) else null;
    l.agent_def = if (spec.agent_def) |d| try a.dupe(u8, d) else null;
    l.profile = try a.dupe(u8, spec.profile);
    return l;
}

fn find(h: *RunHost, id: RunId) ?*Live {
    return h.lives.get(id.toInt());
}

// ---- worker ----

const Job = union(enum) { launch: *Live, dispose: usize };

fn worker(h: *RunHost) void {
    while (true) {
        const job: Job = blk: {
            h.mutex.lockUncancelable(h.io);
            defer h.mutex.unlock(h.io);
            while (true) {
                if (h.closing) return;
                if (h.disposals.pop()) |d| break :blk .{ .dispose = d };
                if (h.queue.popRunnable(&h.counts, h.limits())) |id| {
                    const l = h.find(id).?;
                    l.slot = true;
                    h.counts.add(l.kind);
                    break :blk .{ .launch = l };
                }
                h.cond.wait(h.io, &h.mutex) catch return;
            }
        };
        switch (job) {
            .dispose => |d| h.agents.dispose(d),
            .launch => |l| h.launch(l),
        }
    }
}

fn launch(h: *RunHost, l: *Live) void {
    h.launchOrFail(l) catch |e| {
        h.finish(l, .failed, @errorName(e));
    };
}

fn launchOrFail(h: *RunHost, l: *Live) !void {
    const resuming, const handle = blk: {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const r = l.resume_req;
        l.resume_req = false;
        break :blk .{ r, l.handle };
    };
    // A paused run whose agent is still alive just continues.
    if (resuming) if (handle) |hd| {
        try h.reg.update(l.id, .{ .status = .working });
        try h.agents.submit(hd, continue_text);
        return;
    };
    try h.reg.update(l.id, .{ .status = .starting });
    try h.reg.update(l.id, .{ .started = h.reg.nowMs() });

    var cwd: []const u8 = h.cfg.workspace_root;
    if (l.isolation == .lane) {
        const lanes = h.lanes orelse return error.LanesUnavailable;
        const a = l.arena.allocator();
        if (resuming and l.lane != null) {
            cwd = lanes.find(a, l.lane.?) orelse return error.LaneForgotten;
        } else {
            const name = try std.fmt.allocPrint(a, "run/{s}", .{&l.id.short()});
            cwd = try lanes.create(a, name, h.cfg.lane_base);
            l.lane = name;
            try h.reg.update(l.id, .{ .lane = name });
        }
    }
    const started = try h.agents.start(.{
        .model = l.model,
        .agent_def = l.agent_def,
        .cwd = cwd,
        .budgets = l.budgets,
        .session = if (resuming) l.session else null,
        .profile = l.profile,
        .unattended = l.unattended,
        .sink = .{ .ctx = l, .f = onSignal },
    });
    {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        l.handle = started.handle;
        l.session = started.session;
    }
    try h.reg.update(l.id, .{ .session = started.session });
    try h.reg.update(l.id, .{ .status = .working });
    try h.agents.submit(started.handle, if (resuming) continue_text else l.text);
}

// ---- signals ----

fn onSignal(ctx: *anyopaque, s: port.Signal) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    l.host.signal(l, s) catch {};
}

fn signal(h: *RunHost, l: *Live, s: port.Signal) !void {
    switch (s) {
        .working => {
            const v = h.reg.snapshot();
            defer h.reg.release(v);
            const rec = v.get(l.id) orelse return;
            if (rec.status == .needs_input) try h.reg.update(l.id, .{ .status = .working });
        },
        .needs_input => |q| {
            try h.reg.update(l.id, .{ .question = q });
            h.reg.update(l.id, .{ .status = .needs_input }) catch |e| switch (e) {
                error.InvalidTransition => {},
                else => return e,
            };
        },
        .cost => |c| try h.reg.update(l.id, .{ .cost = c }),
        .summary => |text| {
            var buf: [200]u8 = undefined;
            try h.reg.update(l.id, .{ .summary = run.summarize(&buf, text) });
        },
        .output => |o| try h.reg.update(l.id, .{ .output = o }),
        .tool_boundary => {
            const hd = blk: {
                h.mutex.lockUncancelable(h.io);
                defer h.mutex.unlock(h.io);
                if (!l.pause_req or l.pause_sent) return;
                l.pause_sent = true;
                break :blk l.handle orelse return;
            };
            h.agents.cancel(hd, .turn);
        },
        .turn_finished => |why| h.turnFinished(l, why),
        .failed => |msg| h.finish(l, .failed, msg),
    }
}

fn turnFinished(h: *RunHost, l: *Live, why: port.TurnEnd) void {
    const Next = enum { stopped, paused, failed, completed, wait_user };
    const next: Next = blk: {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        if (l.done) return;
        if (l.stop_req != null) break :blk .stopped;
        if (l.pause_req) {
            l.pause_req = false;
            l.pause_sent = false;
            h.freeSlotLocked(l);
            break :blk .paused;
        }
        break :blk switch (why) {
            .failed => .failed,
            .canceled => .stopped,
            .end_turn, .other => if (l.kind == .interactive) .wait_user else .completed,
        };
    };
    switch (next) {
        .paused => h.reg.update(l.id, .{ .status = .paused }) catch {},
        .wait_user => {
            h.reg.update(l.id, .{ .question = null }) catch {};
            h.reg.update(l.id, .{ .status = .needs_input }) catch {};
        },
        .stopped => h.finish(l, .stopped, null),
        .failed => h.finish(l, .failed, null),
        .completed => h.finish(l, .completed, null),
    }
}

fn freeSlotLocked(h: *RunHost, l: *Live) void {
    if (!l.slot) return;
    l.slot = false;
    h.counts.sub(l.kind);
    h.cond.signal(h.io);
}

/// Ends a run: terminal status, slot freed, agent disposed by the worker.
fn finish(h: *RunHost, l: *Live, status: run.RunStatus, err: ?[]const u8) void {
    {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        if (l.done) return;
        l.done = true;
        h.freeSlotLocked(l);
        _ = h.queue.remove(l.id);
        if (l.handle) |hd| {
            l.handle = null;
            h.disposals.append(h.gpa, hd) catch {};
            h.cond.signal(h.io);
        }
    }
    if (err) |e| h.reg.update(l.id, .{ .error_ = e }) catch {};
    h.reg.update(l.id, .{ .ended = h.reg.nowMs() }) catch {};
    h.reg.update(l.id, .{ .status = status }) catch {};
}

// ---- control ----

/// Stops a run: queued and paused runs end at once; a working run is
/// cancelled at the end of its turn (`graceful`, forced after
/// `graceful_stop_ms`) or immediately (`now`).
pub fn stop(h: *RunHost, id: RunId, how: StopHow) void {
    const Act = union(enum) { none, finish, cancel: usize };
    const act: Act = blk: {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const l = h.find(id) orelse return;
        if (l.done) return;
        if (h.queue.remove(id)) break :blk .finish;
        const hd = l.handle orelse break :blk .finish;
        if (!l.slot) break :blk .finish; // paused
        l.stop_req = how;
        break :blk .{ .cancel = hd };
    };
    const l = blk: {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        break :blk h.find(id).?;
    };
    switch (act) {
        .none => {},
        .finish => h.finish(l, .stopped, null),
        .cancel => |hd| switch (how) {
            .now => {
                h.agents.cancel(hd, .everything);
                h.finish(l, .stopped, null);
            },
            .graceful => {
                h.agents.cancel(hd, .turn);
                h.group.concurrent(h.io, forceStop, .{ h, l }) catch forceStop(h, l);
            },
        },
    }
}

fn forceStop(h: *RunHost, l: *Live) void {
    if (h.cfg.sleep) |s| s(h.cfg.sleep_ctx, h.io, h.cfg.graceful_stop_ms) else {
        h.io.sleep(.fromMilliseconds(h.cfg.graceful_stop_ms), .awake) catch return;
    }
    const hd = blk: {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        if (l.done) return;
        break :blk l.handle;
    };
    if (hd) |x| h.agents.cancel(x, .everything);
    h.finish(l, .stopped, null);
}

/// Pauses a working run at its next tool boundary or turn end.
pub fn pause(h: *RunHost, id: RunId) void {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    const l = h.find(id) orelse return;
    if (l.done or l.handle == null or !l.slot) return;
    l.pause_req = true;
}

/// Resumes a paused or interrupted run (it queues for a slot). An
/// interrupted run unknown to this host is rebuilt from its record and
/// resumes its E10 session.
pub fn resumeRun(h: *RunHost, id: RunId) Error!void {
    h.reg.loadDetail(id) catch |e| switch (e) {
        error.UnknownRun, error.OutOfMemory => |x| return x,
        else => return error.NotResumable,
    };
    const v = h.reg.snapshot();
    defer h.reg.release(v);
    const rec = v.get(id) orelse return error.UnknownRun;
    if (rec.status != .paused and rec.status != .interrupted) return error.NotResumable;
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    const l = h.find(id) orelse blk: {
        const profile = h.profiles.resolve(h.profiles.ctx, rec.spec.profile) orelse return error.UnknownProfile;
        const l = try h.newLive(id, rec.spec, profile);
        errdefer {
            l.arena.deinit();
            h.gpa.destroy(l);
        }
        l.session = rec.session;
        if (rec.lane) |ln| l.lane = try l.arena.allocator().dupe(u8, ln);
        try h.lives.put(h.gpa, id.toInt(), l);
        break :blk l;
    };
    l.done = false;
    l.stop_req = null;
    l.resume_req = true;
    try h.queue.push(h.gpa, id, l.kind);
    h.cond.signal(h.io);
}

/// Answers a run waiting for input, or steers a working one.
pub fn reply(h: *RunHost, id: RunId, text: []const u8) Error!void {
    const hd = blk: {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const l = h.find(id) orelse return error.UnknownRun;
        if (l.done) return error.NotWaiting;
        break :blk l.handle orelse return error.NotWaiting;
    };
    const v = h.reg.snapshot();
    const status = if (v.get(id)) |r| r.status else .queued;
    h.reg.release(v);
    if (status != .needs_input and status != .working) return error.NotWaiting;
    // Working first: the agent may finish the turn inside `submit`.
    if (status == .needs_input) try h.reg.update(id, .{ .status = .working });
    h.agents.submit(hd, text) catch return error.NotWaiting;
}

/// The live agent of a run, for the GUI to open its E10 pane.
pub fn attach(h: *RunHost, id: RunId) Error!proto.AgentRef {
    const hd = blk: {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const l = h.find(id) orelse return error.UnknownRun;
        break :blk l.handle orelse return error.NotLive;
    };
    return h.agents.ref(hd) orelse error.NotLive;
}

/// Runs this host is driving (queued, running or paused), for handoff.
pub fn liveRuns(h: *RunHost, gpa: Allocator, out: *std.ArrayList(RunId)) Allocator.Error!void {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    var it = h.lives.valueIterator();
    while (it.next()) |l| if (!l.*.done) try out.append(gpa, l.*.id);
}

/// Runs holding a slot.
pub fn running(h: *RunHost) u16 {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    return h.counts.total;
}

test {
    _ = @import("host_test.zig");
}
