//! The workflow engine (E13.F08.S01.T03). A workflow run is a parent run
//! (`kind = .workflow`) in the `RunRegistry`; every agent invocation is a
//! child run (`kind = .workflow_worker`, `parent` = the workflow run)
//! started through a `WorkerPort` (`host_workers.zig` binds it to
//! `RunHost`, so Mission Control, notifications, budgets, lanes and cost
//! accounting treat workers like any other run).
//!
//! Steps run in order on one driver task per run. Map items, vote copies
//! and parallel branches run concurrently, at most `limits.max_parallel`
//! agents at once per workflow (a semaphore, on top of the host's own
//! limits). The engine itself never waits on a model: it renders prompts,
//! starts children and sleeps on an event until a child reports.
//!
//! Replay (`replay.zig`): before an agent starts, its plan position and
//! replay key are looked up in the previous generation's journal. While
//! replaying, lookups happen in plan order (map items and vote copies are
//! prepared one by one before any starts; parallel branches run one after
//! another until the first miss), so a resumed run reuses exactly the
//! agents before the first change.
//!
//! Format and semantics: docs/formats/workflow.md.

const std = @import("std");
const zg_ai = @import("zg_ai");
const run = @import("../runs/run.zig");
const RunRegistry = @import("../runs/registry.zig");
const PromptLibrary = @import("../library/index.zig");
const def = @import("def.zig");
const path_mod = @import("path.zig");
const interp = @import("interpolate.zig");
const validate_mod = @import("validate.zig");
const JournalStore = @import("journal.zig");
const Replayer = @import("replay.zig").Replayer;
const BuiltinRegistry = @import("builtins.zig");
const Tracker = @import("progress.zig");
const step_agent = @import("step_agent.zig");
const step_map = @import("step_map.zig");
const step_vote = @import("step_vote.zig");
const step_loop = @import("step_loop.zig");
const step_gate = @import("step_gate.zig");
const step_command = @import("step_command.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const RunId = run.RunId;
const Validator = zg_ai.schema.validate.Validator;

pub const WorkflowProgress = Tracker.WorkflowProgress;
pub const LaneUse = BuiltinRegistry.LaneUse;

/// What a worker is asked to do. Strings live until the worker reports a
/// terminal event.
pub const WorkerRequest = struct {
    /// The child's run id, chosen by the engine.
    child: RunId,
    parent: RunId,
    step: []const u8,
    /// Plan position (`audit#3`, `pick.2`, `fix@1`).
    pos: []const u8,
    title: []const u8,
    prompt: []const u8,
    agent_def: ?[]const u8,
    tools: ?[]const []const u8,
    model_role: ?[]const u8,
    isolation: run.Isolation,
    profile: []const u8,
    budgets: run.Budgets,
    /// 0 for the first try; stall restarts and schema retries count up.
    attempt: u8,
    /// Differs per vote copy, the same across runs.
    seed: u64,
};

/// What a worker reports, from any thread (`WorkflowEngine.workerEvent`).
pub const WorkerEvent = union(enum) {
    /// Streaming, thinking or running a tool: resets the stall timer.
    activity,
    /// Cumulative cost of the child so far.
    cost: run.Cost,
    /// The E09 lane a `.lane` worker writes in.
    lane: []const u8,
    /// Finished; the final assistant text.
    result: []const u8,
    failed: []const u8,
    stopped,
};

pub const WorkerPort = struct {
    ctx: *anyopaque,
    start: *const fn (ctx: *anyopaque, req: *const WorkerRequest) anyerror!void,
    /// Stops a child; it reports `stopped` (or a result that raced it).
    stop: *const fn (ctx: *anyopaque, child: RunId) void,
};

pub const CommandRequest = struct {
    argv: []const []const u8,
    /// `argv[0]` is a command line for the user's shell.
    shell: bool = false,
    cwd: ?[]const u8,
    /// The workflow's permission profile.
    profile: []const u8,
    run: RunId,
    step: []const u8,
};

pub const CommandResult = struct { exit_code: i32, output: []const u8 };

/// E06 `TerminalService.exec`: asks for approval under `profile` and
/// returns `error.Denied` when it is refused.
pub const CommandPort = struct {
    ctx: *anyopaque,
    exec: *const fn (ctx: *anyopaque, arena: Allocator, req: CommandRequest) anyerror!CommandResult,
};

pub const Services = struct {
    workers: WorkerPort,
    commands: ?CommandPort = null,
    library: ?*PromptLibrary = null,
    /// Validates structured outputs; null only checks that they parse.
    validator: ?Validator = null,
    builtins: ?*BuiltinRegistry = null,
    /// `.zigguro/runs`: a run's journal and spilled values go in
    /// `<run id>/`. Null keeps them in memory.
    runs_dir: ?Io.Dir = null,
    /// How often a waiting agent checks for a stall (tests shorten it).
    stall_poll_ms: u32 = 1_000,
};

pub const StartOpts = struct {
    title: ?[]const u8 = null,
    origin: run.Origin = .user,
    project: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    /// Schema files next to the workflow file.
    schema_files: ?validate_mod.SchemaFiles = null,
    /// Step ids (and `$args`) whose values are untrusted data.
    untrusted: []const []const u8 = &.{},
    /// The workflow source, kept in the run folder for resume.
    source: ?[]const u8 = null,
    /// Resume: the previous generation's journal (borrowed until the run
    /// ends).
    prev: ?*JournalStore = null,
};

pub const Error = error{ UnknownRun, NoGate, NotWaiting, UnknownChild } || RunRegistry.Error;

/// Why a whole run ends early.
pub const Abort = error{ Stopped, OutOfMemory, Canceled };

/// A step's outcome: a value, or a failure message.
pub const Outcome = union(enum) {
    ok: Value,
    failed: []const u8,
};

gpa: Allocator,
io: Io,
reg: *RunRegistry,
svc: Services,

mutex: Io.Mutex = .init,
runs: std.AutoHashMapUnmanaged(u128, *Exec) = .empty,
/// Live children by id.
children: std.AutoHashMapUnmanaged(u128, *Pending) = .empty,
last_id: u128 = 0,
group: Io.Group = .init,

const WorkflowEngine = @This();

pub fn init(gpa: Allocator, io: Io, reg: *RunRegistry, svc: Services) !*WorkflowEngine {
    const e = try gpa.create(WorkflowEngine);
    e.* = .{ .gpa = gpa, .io = io, .reg = reg, .svc = svc };
    return e;
}

/// Stops every run and waits for the drivers.
pub fn deinit(e: *WorkflowEngine) void {
    {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        var it = e.runs.valueIterator();
        while (it.next()) |x| x.*.requestStop(null);
    }
    e.group.await(e.io) catch {};
    var it = e.runs.valueIterator();
    while (it.next()) |x| x.*.destroy();
    e.runs.deinit(e.gpa);
    e.children.deinit(e.gpa);
    e.gpa.destroy(e);
}

pub fn nowMs(e: *const WorkflowEngine) i64 {
    const t = Io.Clock.awake.now(e.io);
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_ms));
}

/// A fresh, strictly increasing run id.
pub fn newId(e: *WorkflowEngine) RunId {
    var id = RunId.generate(e.io);
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    if (id.toInt() <= e.last_id) id = .fromInt(e.last_id + 1);
    e.last_id = id.toInt();
    return id;
}

/// Starts `d` (already validated) with `args` (an object; defaults are
/// filled in here). Returns the parent run at once.
pub fn start(e: *WorkflowEngine, d: *const def.WorkflowDef, args: Value, opts: StartOpts) !RunId {
    const x = try Exec.create(e, d, args, opts);
    errdefer x.destroy();
    const id = try e.reg.create(.{
        .kind = .workflow,
        .title = opts.title orelse d.name,
        .prompt = if (d.description.len > 0) d.description else d.name,
        .profile = d.profile orelse "default",
        .origin = opts.origin,
        .project = opts.project,
        .tags = opts.tags,
        .budgets = .{ .max_wall_ms = d.limits.max_wall_ms, .max_cost_micros = d.limits.max_cost_micros },
    });
    errdefer {
        e.reg.update(id, .{ .error_ = "the workflow could not start" }) catch {};
        e.reg.update(id, .{ .status = .stopped }) catch {};
    }
    x.id = id;
    x.tracker.id = id;
    try x.openJournal(opts);
    {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        try e.runs.put(e.gpa, id.toInt(), x);
    }
    e.group.concurrent(e.io, driver, .{x}) catch {
        e.mutex.lockUncancelable(e.io);
        _ = e.runs.remove(id.toInt());
        e.mutex.unlock(e.io);
        return error.Unavailable;
    };
    return id;
}

/// Starts `d` again as a new run that reuses `old`'s finished agents
/// (its journal in `runs_dir/<old>/`).
pub fn resumeFrom(e: *WorkflowEngine, old: RunId, d: *const def.WorkflowDef, args: Value, opts: StartOpts) !RunId {
    const dir = e.svc.runs_dir orelse return error.NoRunsDir;
    var sub = try dir.openDir(e.io, &old.text(), .{});
    defer sub.close(e.io);
    const prev = try JournalStore.load(e.gpa, e.io, sub);
    var o = opts;
    o.prev = prev;
    const id = e.start(d, args, o) catch |err| {
        prev.deinit();
        return err;
    };
    const x = e.find(id).?;
    x.owned_prev = true;
    return id;
}

fn find(e: *WorkflowEngine, id: RunId) ?*Exec {
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    return e.runs.get(id.toInt());
}

/// Stops a run: children are stopped, the run ends `stopped`.
pub fn stop(e: *WorkflowEngine, id: RunId) void {
    const x = e.find(id) orelse return;
    x.requestStop(null);
}

/// Pauses a run: running agents finish, no new agent starts.
pub fn pause(e: *WorkflowEngine, id: RunId) void {
    const x = e.find(id) orelse return;
    x.setPaused(true);
}

pub fn unpause(e: *WorkflowEngine, id: RunId) void {
    const x = e.find(id) orelse return;
    x.setPaused(false);
}

/// Stops child `child` and starts its agent again from scratch.
pub fn restartAgent(e: *WorkflowEngine, id: RunId, child: RunId) Error!void {
    _ = e.find(id) orelse return error.UnknownRun;
    const p = blk: {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        const p = e.children.get(child.toInt()) orelse return error.UnknownChild;
        p.restart_req.store(true, .release);
        break :blk p;
    };
    e.svc.workers.stop(e.svc.workers.ctx, p.child);
}

/// Answers the gate run `id` waits at.
pub fn answerGate(e: *WorkflowEngine, id: RunId, gate: []const u8, approve: bool, note: ?[]const u8) Error!void {
    const x = e.find(id) orelse return error.UnknownRun;
    x.mutex.lockUncancelable(e.io);
    defer x.mutex.unlock(e.io);
    const g = x.gate orelse return error.NotWaiting;
    if (!std.mem.eql(u8, g, gate)) return error.NoGate;
    x.gate_answer = .{ .approve = approve, .note = if (note) |n| try x.arena.allocator().dupe(u8, n) else null };
    x.cond.broadcast(e.io);
}

/// The run's progress, copied into `arena`.
pub fn progress(e: *WorkflowEngine, id: RunId, arena: Allocator) !?WorkflowProgress {
    const x = e.find(id) orelse return null;
    return try x.tracker.snapshot(arena);
}

/// Blocks until run `id`'s driver finished; returns its final status.
pub fn wait(e: *WorkflowEngine, id: RunId) !run.RunStatus {
    const x = e.find(id) orelse return error.UnknownRun;
    try x.done.wait(e.io);
    return x.final_status;
}

/// The value step `step_id` produced in run `id` (copied into `arena`).
pub fn result(e: *WorkflowEngine, id: RunId, step_id: []const u8, arena: Allocator) !?Value {
    const x = e.find(id) orelse return error.UnknownRun;
    x.mutex.lockUncancelable(e.io);
    defer x.mutex.unlock(e.io);
    const v = x.scope.get(step_id) orelse return null;
    return try cloneValue(arena, v);
}

/// Forgets a finished run (its registry record stays).
pub fn forget(e: *WorkflowEngine, id: RunId) void {
    const x = blk: {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        const x = e.runs.get(id.toInt()) orelse return;
        if (!x.done.isSet()) return;
        _ = e.runs.remove(id.toInt());
        break :blk x;
    };
    x.destroy();
}

/// A worker's report about `child`. Unknown children are ignored.
pub fn workerEvent(e: *WorkflowEngine, child: RunId, ev: WorkerEvent) void {
    e.mutex.lockUncancelable(e.io);
    const p = e.children.get(child.toInt()) orelse {
        e.mutex.unlock(e.io);
        return;
    };
    e.mutex.unlock(e.io);
    p.event(ev);
}

// ---- one run ----

pub const GateAnswer = struct { approve: bool, note: ?[]const u8 };

pub const Exec = struct {
    eng: *WorkflowEngine,
    id: RunId = .zero,
    /// Thread-safe (std's arena is): owns the definition copy, results and
    /// messages.
    arena: std.heap.ArenaAllocator,
    def: def.WorkflowDef,
    args: Value,
    /// Step results by id plus `$args`. Written by the driver only (under
    /// `mutex`); tasks read clones made before they start.
    scope: std.json.ObjectMap = .empty,
    journal: *JournalStore = undefined,
    journal_open: bool = false,
    prev: ?*JournalStore,
    owned_prev: bool = false,
    replayer: Replayer,
    /// Serializes replay lookups (plan order).
    replay_mutex: Io.Mutex = .init,
    seq: std.atomic.Value(u32) = .init(0),
    /// Distinct agents started (the `max_agents` cap).
    agents: std.atomic.Value(u32) = .init(0),
    sem: Io.Semaphore,
    schema_files: ?validate_mod.SchemaFiles,
    untrusted: []const []const u8,
    dir: ?Io.Dir = null,
    tracker: Tracker,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    stop_req: std.atomic.Value(bool) = .init(false),
    /// Why the run was stopped by the engine ("budget: …"); null for a
    /// user stop.
    abort_reason: ?[]const u8 = null,
    paused: bool = false,
    gate: ?[]const u8 = null,
    gate_answer: ?GateAnswer = null,
    cost: run.Cost = .{},
    deadline_ms: ?i64 = null,
    lanes: std.ArrayList(LaneUse) = .empty,
    /// Children of this run that are running now.
    live: std.ArrayList(*Pending) = .empty,
    done: Io.Event = .unset,
    final_status: run.RunStatus = .queued,

    fn create(e: *WorkflowEngine, d: *const def.WorkflowDef, args: Value, opts: StartOpts) !*Exec {
        const x = try e.gpa.create(Exec);
        errdefer e.gpa.destroy(x);
        x.* = .{
            .eng = e,
            .arena = .init(e.gpa),
            .def = undefined,
            .args = undefined,
            .prev = opts.prev,
            .replayer = .init(opts.prev),
            .sem = .{ .permits = d.limits.max_parallel },
            .schema_files = opts.schema_files,
            .untrusted = opts.untrusted,
            .tracker = undefined,
        };
        errdefer x.arena.deinit();
        const a = x.arena.allocator();
        x.def = try run.deepClone(def.WorkflowDef, a, d.*);
        x.args = try fillArgs(a, &x.def, args);
        x.untrusted = try run.deepClone([]const []const u8, a, opts.untrusted);
        try x.scope.put(a, path_mod.args_key, x.args);
        x.tracker = try .init(a, e.io, .zero, &x.def);
        if (d.limits.max_wall_ms) |ms| x.deadline_ms = e.nowMs() + @as(i64, @intCast(ms));
        return x;
    }

    fn openJournal(x: *Exec, opts: StartOpts) !void {
        const e = x.eng;
        if (e.svc.runs_dir) |dir| {
            const sub = try dir.createDirPathOpen(e.io, &x.id.text(), .{});
            x.dir = sub;
            x.journal = try JournalStore.create(e.gpa, e.io, sub);
            x.journal_open = true;
            if (opts.source) |src| try sub.writeFile(e.io, .{ .sub_path = "workflow.zon", .data = src });
            const args_json = try std.json.Stringify.valueAlloc(x.arena.allocator(), x.args, .{});
            try sub.writeFile(e.io, .{ .sub_path = "args.json", .data = args_json });
        } else {
            x.journal = try JournalStore.memory(e.gpa, e.io);
            x.journal_open = true;
        }
    }

    fn destroy(x: *Exec) void {
        const e = x.eng;
        if (x.journal_open) x.journal.deinit();
        if (x.owned_prev) if (x.prev) |p| p.deinit();
        if (x.dir) |d| d.close(e.io);
        x.lanes.deinit(e.gpa);
        x.live.deinit(e.gpa);
        x.arena.deinit();
        e.gpa.destroy(x);
    }

    pub fn allocator(x: *Exec) Allocator {
        return x.arena.allocator();
    }

    pub fn stopped(x: *const Exec) bool {
        return x.stop_req.load(.acquire);
    }

    /// Stops the run (`reason` set: it ends failed with that reason).
    pub fn requestStop(x: *Exec, reason: ?[]const u8) void {
        const e = x.eng;
        var kids: std.ArrayList(RunId) = .empty;
        defer kids.deinit(e.gpa);
        {
            x.mutex.lockUncancelable(e.io);
            defer x.mutex.unlock(e.io);
            if (!x.stop_req.load(.acquire)) {
                if (reason) |r| x.abort_reason = x.allocator().dupe(u8, r) catch "stopped";
                x.stop_req.store(true, .release);
            }
            for (x.live.items) |p| kids.append(e.gpa, p.child) catch {};
            x.cond.broadcast(e.io);
        }
        for (kids.items) |c| e.svc.workers.stop(e.svc.workers.ctx, c);
    }

    fn setPaused(x: *Exec, on: bool) void {
        const e = x.eng;
        x.mutex.lockUncancelable(e.io);
        defer x.mutex.unlock(e.io);
        if (x.paused == on or x.done.isSet()) return;
        x.paused = on;
        x.cond.broadcast(e.io);
        e.reg.update(x.id, .{ .status = if (on) .paused else .working }) catch {};
        x.tracker.setStatus(if (on) .paused else .working, null);
    }

    /// The next journal sequence number.
    pub fn nextSeq(x: *Exec) u32 {
        return x.seq.fetchAdd(1, .monotonic);
    }

    /// Takes a slot for one agent: waits while paused or at
    /// `max_parallel`, and checks the agent cap and the budgets.
    pub fn acquire(x: *Exec, first_attempt: bool) Abort!void {
        const e = x.eng;
        try x.sem.wait(e.io);
        errdefer x.sem.post(e.io);
        {
            x.mutex.lockUncancelable(e.io);
            defer x.mutex.unlock(e.io);
            while (x.paused and !x.stopped()) try x.cond.wait(e.io, &x.mutex);
        }
        if (x.stopped()) return error.Stopped;
        if (first_attempt) {
            const n = x.agents.fetchAdd(1, .monotonic) + 1;
            if (n > x.def.limits.max_agents) {
                x.requestStop(std.fmt.allocPrint(x.allocator(), "the workflow tried to start more than {d} agents", .{x.def.limits.max_agents}) catch "too many agents");
                return error.Stopped;
            }
        }
        if (x.budgetExceeded()) |why| {
            x.requestStop(why);
            return error.Stopped;
        }
    }

    pub fn release(x: *Exec) void {
        x.sem.post(x.eng.io);
    }

    fn budgetExceeded(x: *Exec) ?[]const u8 {
        const l = x.def.limits;
        x.mutex.lockUncancelable(x.eng.io);
        defer x.mutex.unlock(x.eng.io);
        if (l.max_cost_micros) |m| if (x.cost.micros >= m) return "budget: cost limit reached";
        if (l.max_tokens) |m| if (x.cost.input_tokens + x.cost.output_tokens >= m) return "budget: token limit reached";
        if (x.deadline_ms) |d| if (x.eng.nowMs() >= d) return "budget: time limit reached";
        return null;
    }

    /// What one child may spend: what is left of the workflow budget.
    pub fn childBudgets(x: *Exec) run.Budgets {
        const l = x.def.limits;
        x.mutex.lockUncancelable(x.eng.io);
        defer x.mutex.unlock(x.eng.io);
        var b: run.Budgets = .{};
        if (l.max_cost_micros) |m| b.max_cost_micros = m -| x.cost.micros;
        if (x.deadline_ms) |d| b.max_wall_ms = @intCast(@max(0, d - x.eng.nowMs()));
        return b;
    }

    /// Adds `delta` to the run's cost (rolled up into the parent record).
    pub fn addCost(x: *Exec, delta: run.Cost) void {
        const total = blk: {
            x.mutex.lockUncancelable(x.eng.io);
            defer x.mutex.unlock(x.eng.io);
            x.cost.micros += delta.micros;
            x.cost.input_tokens += delta.input_tokens;
            x.cost.output_tokens += delta.output_tokens;
            break :blk x.cost;
        };
        x.tracker.setCost(total);
        x.eng.reg.update(x.id, .{ .cost = total }) catch {};
        if (x.budgetExceeded()) |why| x.requestStop(why);
    }

    pub fn addLane(x: *Exec, l: LaneUse) void {
        x.mutex.lockUncancelable(x.eng.io);
        defer x.mutex.unlock(x.eng.io);
        x.lanes.append(x.eng.gpa, l) catch {};
    }

    /// A copy of the lanes used so far.
    pub fn lanesSnapshot(x: *Exec, arena: Allocator) ![]const LaneUse {
        x.mutex.lockUncancelable(x.eng.io);
        defer x.mutex.unlock(x.eng.io);
        return arena.dupe(LaneUse, x.lanes.items);
    }

    /// Registers a child before it starts, so its events are routed.
    pub fn track(x: *Exec, p: *Pending) !void {
        const e = x.eng;
        {
            e.mutex.lockUncancelable(e.io);
            defer e.mutex.unlock(e.io);
            try e.children.put(e.gpa, p.child.toInt(), p);
        }
        x.mutex.lockUncancelable(e.io);
        defer x.mutex.unlock(e.io);
        try x.live.append(e.gpa, p);
    }

    pub fn untrack(x: *Exec, p: *Pending) void {
        const e = x.eng;
        {
            e.mutex.lockUncancelable(e.io);
            defer e.mutex.unlock(e.io);
            _ = e.children.remove(p.child.toInt());
        }
        x.mutex.lockUncancelable(e.io);
        defer x.mutex.unlock(e.io);
        for (x.live.items, 0..) |q, i| if (q == p) {
            _ = x.live.swapRemove(i);
            break;
        };
    }

    /// Whether replay already diverged (no more lookups can hit).
    pub fn diverged(x: *Exec) bool {
        x.replay_mutex.lockUncancelable(x.eng.io);
        defer x.replay_mutex.unlock(x.eng.io);
        return x.replayer.diverged;
    }

    /// Replay lookup in plan order; a hit is journaled in this generation
    /// too, so a later resume can reuse it again.
    pub fn lookup(x: *Exec, pos: []const u8, key: JournalStore.ReplayKey) Abort!?Value {
        x.replay_mutex.lockUncancelable(x.eng.io);
        defer x.replay_mutex.unlock(x.eng.io);
        const v = x.replayer.lookup(pos, key) orelse return null;
        const old = x.prev.?.atPos(pos).?;
        const seq = x.nextSeq();
        x.journal.recordStart(seq, pos, key, old.child) catch |err| return mapErr(err);
        x.journal.recordResult(seq, .{ .ok = v }) catch |err| return mapErr(err);
        return try cloneValue(x.allocator(), v);
    }

    /// A clone of `base` with extra bindings, for a task to read.
    pub fn scopeWith(x: *Exec, base: std.json.ObjectMap, extra: []const Binding) Allocator.Error!Value {
        const a = x.allocator();
        var o: std.json.ObjectMap = .empty;
        try o.ensureTotalCapacity(a, base.count() + extra.len);
        var it = base.iterator();
        while (it.next()) |en| o.putAssumeCapacity(en.key_ptr.*, en.value_ptr.*);
        for (extra) |b| try o.put(a, b.name, b.value);
        return .{ .object = o };
    }

    /// The driver's current scope, cloned.
    pub fn snapshotScope(x: *Exec, extra: []const Binding) Allocator.Error!Value {
        x.mutex.lockUncancelable(x.eng.io);
        defer x.mutex.unlock(x.eng.io);
        return x.scopeWith(x.scope, extra);
    }

    fn putResult(x: *Exec, id: []const u8, v: Value) Allocator.Error!void {
        x.mutex.lockUncancelable(x.eng.io);
        defer x.mutex.unlock(x.eng.io);
        try x.scope.put(x.allocator(), id, v);
    }

    pub fn failf(x: *Exec, comptime fmt: []const u8, args: anytype) Allocator.Error!Outcome {
        return .{ .failed = try std.fmt.allocPrint(x.allocator(), fmt, args) };
    }

    /// Writes a large value next to the journal (interpolation spill).
    pub fn spillPort(x: *Exec) ?interp.SpillPort {
        if (x.dir == null) return null;
        return .{ .ctx = x, .spill = spillFn };
    }

    fn spillFn(ctx: *anyopaque, arena: Allocator, bytes: []const u8) anyerror![]const u8 {
        const x: *Exec = @ptrCast(@alignCast(ctx));
        const io = x.eng.io;
        var h: [8]u8 = undefined;
        std.mem.writeInt(u64, &h, std.hash.Wyhash.hash(0, bytes), .little);
        const name = try std.fmt.allocPrint(arena, "spill/{x}.txt", .{&h});
        try x.dir.?.createDirPath(io, "spill");
        try x.dir.?.writeFile(io, .{ .sub_path = name, .data = bytes });
        return std.fmt.allocPrint(arena, ".zigguro/runs/{s}/{s}", .{ &x.id.text(), name });
    }
};

pub const Binding = struct { name: []const u8, value: Value };

/// One child attempt the engine waits on.
pub const Pending = struct {
    x: *Exec,
    child: RunId,
    step: []const u8,
    pos: []const u8,
    ev: Io.Event = .unset,
    last_activity_ms: std.atomic.Value(i64),
    restart_req: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    outcome: ?WorkerOutcome = null,
    cost: run.Cost = .{},

    pub const WorkerOutcome = union(enum) { result: []const u8, failed: []const u8, stopped };

    fn event(p: *Pending, ev: WorkerEvent) void {
        const x = p.x;
        const io = x.eng.io;
        p.last_activity_ms.store(x.eng.nowMs(), .release);
        switch (ev) {
            .activity => {},
            .cost => |c| {
                const delta = blk: {
                    p.mutex.lockUncancelable(io);
                    defer p.mutex.unlock(io);
                    const d: run.Cost = .{
                        .micros = c.micros -| p.cost.micros,
                        .input_tokens = c.input_tokens -| p.cost.input_tokens,
                        .output_tokens = c.output_tokens -| p.cost.output_tokens,
                    };
                    p.cost = c;
                    break :blk d;
                };
                x.addCost(delta);
            },
            .lane => |l| x.addLane(.{ .step = p.step, .pos = p.pos, .child = p.child, .lane = x.allocator().dupe(u8, l) catch return }),
            .result, .failed, .stopped => {
                {
                    p.mutex.lockUncancelable(io);
                    defer p.mutex.unlock(io);
                    if (p.outcome != null) return;
                    p.outcome = switch (ev) {
                        .result => |t| .{ .result = x.allocator().dupe(u8, t) catch "" },
                        .failed => |m| .{ .failed = x.allocator().dupe(u8, m) catch "failed" },
                        else => .stopped,
                    };
                }
                p.ev.set(io);
            },
        }
    }

    pub fn take(p: *Pending) ?WorkerOutcome {
        p.mutex.lockUncancelable(p.x.eng.io);
        defer p.mutex.unlock(p.x.eng.io);
        return p.outcome;
    }
};

pub fn mapErr(err: anyerror) Abort {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Stopped,
    };
}

// ---- the driver ----

fn driver(x: *Exec) Io.Cancelable!void {
    const e = x.eng;
    defer x.done.set(e.io);
    e.reg.update(x.id, .{ .status = .starting }) catch {};
    e.reg.update(x.id, .{ .started = e.reg.nowMs() }) catch {};
    e.reg.update(x.id, .{ .status = .working }) catch {};
    x.tracker.setStatus(.working, null);
    const out = runSteps(x) catch |err| switch (err) {
        error.Stopped, error.Canceled => Outcome{ .failed = "" },
        error.OutOfMemory => Outcome{ .failed = "out of memory" },
    };
    const status: run.RunStatus, const msg: ?[]const u8 = switch (out) {
        .ok => .{ .completed, null },
        .failed => |m| if (x.stopped())
            if (x.abort_reason) |r| .{ .failed, r } else .{ .stopped, if (m.len > 0) m else null }
        else
            .{ .failed, m },
    };
    if (msg) |m| e.reg.update(x.id, .{ .error_ = m }) catch {};
    if (status == .completed) if (finalSummary(x)) |s| {
        var buf: [200]u8 = undefined;
        e.reg.update(x.id, .{ .summary = run.summarize(&buf, s) }) catch {};
    };
    e.reg.update(x.id, .{ .ended = e.reg.nowMs() }) catch {};
    // A paused run that ends goes through working first.
    e.reg.update(x.id, .{ .status = .working }) catch {};
    e.reg.update(x.id, .{ .status = status }) catch {};
    x.tracker.setStatus(status, msg);
    x.final_status = status;
}

fn finalSummary(x: *Exec) ?[]const u8 {
    const last = x.def.steps[x.def.steps.len - 1];
    const v = x.scope.get(last.id) orelse return null;
    return interp.render(x.allocator(), v) catch null;
}

fn runSteps(x: *Exec) Abort!Outcome {
    for (x.def.steps) |*s| {
        if (x.stopped()) return error.Stopped;
        const scope = try x.snapshotScope(&.{});
        const out = try runNamed(x, s, scope, s.id);
        switch (out) {
            .ok => |v| {
                try x.putResult(s.id, v);
                // Branch results are also readable by their own ids.
                if (s.parallel) |br| for (br) |b| {
                    if (v.object.get(b.id)) |bv| try x.putResult(b.id, bv);
                };
            },
            .failed => |m| return x.failf("step {s}: {s}", .{ s.id, m }),
        }
    }
    return .{ .ok = .null };
}

/// Runs one named step (`when` included) at plan position `pos`.
pub fn runNamed(x: *Exec, s: *const def.NamedStep, scope: Value, pos: []const u8) Abort!Outcome {
    const a = x.allocator();
    if (s.when) |w| {
        const p = path_mod.Path.compile(a, w) catch return x.failf("invalid when path", .{});
        const v = try p.first(scope, a);
        if (v == null or !path_mod.truthy(v.?)) {
            x.tracker.setState(s.id, .skipped);
            return .{ .ok = .null };
        }
    }
    x.tracker.setState(s.id, .running);
    const out = try runStep(x, s, scope, pos);
    switch (out) {
        .ok => x.tracker.setState(s.id, .done),
        .failed => |m| x.tracker.fail(s.id, m),
    }
    return out;
}

fn runStep(x: *Exec, s: *const def.NamedStep, scope: Value, pos: []const u8) Abort!Outcome {
    return switch (s.step().?) {
        .agent, .reduce => |ag| blk: {
            x.tracker.setTotal(s.id, 1);
            break :blk step_agent.runOne(x, s.id, &ag, scope, pos, null, 0);
        },
        .map => |m| step_map.run(x, s.id, &m, scope, pos),
        .parallel => |br| runParallel(x, s.id, br, scope, pos),
        .vote => |v| step_vote.run(x, s.id, &v, scope, pos),
        .loop_until => |l| step_loop.run(x, s.id, &l, scope, pos),
        .gate => |g| step_gate.run(x, s.id, &g, scope, pos),
        .builtin => |b| step_command.runBuiltin(x, s.id, &b, scope, pos),
        .command => |c| step_command.run(x, s.id, &c, scope),
    };
}

const Branch = struct {
    x: *Exec,
    s: *const def.NamedStep,
    scope: Value,
    pos: []const u8,
    out: Abort!Outcome = .{ .ok = .null },

    fn go(b: *Branch) Io.Cancelable!void {
        b.out = runNamed(b.x, b.s, b.scope, b.pos);
    }
};

/// Branches run at once (one after another while replay has not
/// diverged). The result is an object keyed by branch id; the first
/// failed branch (in order) fails the step.
fn runParallel(x: *Exec, id: []const u8, br: []const def.NamedStep, scope: Value, pos: []const u8) Abort!Outcome {
    _ = id;
    const a = x.allocator();
    const bs = try a.alloc(Branch, br.len);
    var g: Io.Group = .init;
    defer g.cancel(x.eng.io);
    for (br, bs) |*s, *b| {
        b.* = .{ .x = x, .s = s, .scope = scope, .pos = try std.fmt.allocPrint(a, "{s}/{s}", .{ pos, s.id }) };
        if (!x.diverged()) {
            try b.go();
            continue;
        }
        g.concurrent(x.eng.io, Branch.go, .{b}) catch try b.go();
    }
    try g.await(x.eng.io);
    var o: std.json.ObjectMap = .empty;
    for (bs) |*b| switch (try b.out) {
        .ok => |v| try o.put(a, b.s.id, v),
        .failed => |m| return x.failf("branch {s}: {s}", .{ b.s.id, m }),
    };
    return .{ .ok = .{ .object = o } };
}

// ---- helpers ----

/// `args` with declared defaults filled in (strings parsed by type).
fn fillArgs(a: Allocator, d: *const def.WorkflowDef, args: Value) !Value {
    var o: std.json.ObjectMap = .empty;
    if (args == .object) {
        var it = args.object.iterator();
        while (it.next()) |en| try o.put(a, try a.dupe(u8, en.key_ptr.*), try cloneValue(a, en.value_ptr.*));
    }
    for (d.args) |decl| {
        if (o.contains(decl.name)) continue;
        const dv = decl.default orelse {
            if (decl.required) return error.MissingArgument;
            continue;
        };
        const v: Value = switch (decl.type) {
            .number, .bool, .json => std.json.parseFromSliceLeaky(Value, a, dv, .{}) catch .{ .string = dv },
            else => .{ .string = dv },
        };
        try o.put(a, decl.name, v);
    }
    return .{ .object = o };
}

pub fn cloneValue(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out: std.json.Array = .init(a);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |x| out.appendAssumeCapacity(try cloneValue(a, x));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: std.json.ObjectMap = .empty;
            try out.ensureTotalCapacity(a, o.count());
            var it = o.iterator();
            while (it.next()) |en| out.putAssumeCapacity(try a.dupe(u8, en.key_ptr.*), try cloneValue(a, en.value_ptr.*));
            break :blk .{ .object = out };
        },
        else => v,
    };
}

/// JSON with object keys sorted: equal values give equal text (votes,
/// no-progress signatures).
pub fn canonical(a: Allocator, v: Value) Allocator.Error![]const u8 {
    var w: Io.Writer.Allocating = .init(a);
    writeCanonical(&w.writer, a, v) catch return error.OutOfMemory;
    return w.written();
}

fn writeCanonical(w: *Io.Writer, a: Allocator, v: Value) !void {
    switch (v) {
        .object => |o| {
            const keys = try a.dupe([]const u8, o.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn lt(_: void, l: []const u8, r: []const u8) bool {
                    return std.mem.order(u8, l, r) == .lt;
                }
            }.lt);
            try w.writeByte('{');
            for (keys, 0..) |k, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.value(k, .{}, w);
                try w.writeByte(':');
                try writeCanonical(w, a, o.get(k).?);
            }
            try w.writeByte('}');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try writeCanonical(w, a, x);
            }
            try w.writeByte(']');
        },
        else => try std.json.Stringify.value(v, .{}, w),
    }
}
