//! One debug session (E07.F06.S02.T01): drives an adapter from the
//! pre-launch task to `terminated`, keeps its threads, console and
//! capabilities, and controls execution.
//!
//! Start (`run`, on the session's worker):
//!   1. substitute `${...}` in the configuration (when the manager has a
//!      variable context); the adapter's normalize hook runs on the
//!      result before it is sent;
//!   2. run `pre_launch_task`; on failure the session waits on a prompt
//!      (Debug Anyway / Abort, `answerPrompt`);
//!   3. spawn the adapter and connect;
//!   4. `initialize`, keep the capabilities;
//!   5. send `launch`/`attach` without waiting for its response (adapters
//!      answer only after `configurationDone`);
//!   6. wait for `initialized` (10 s), send the breakpoints (the
//!      manager's `BreakpointSink`);
//!   7. `configurationDone` when supported;
//!   8. wait for the launch/attach response: a failure fails the session
//!      with the adapter's message (and `url`).
//!
//! Events arrive on the connection's dispatcher, in wire order. A
//! `stopped` event marks threads, bumps the generation, and fetches the
//! thread list, the stopped thread's stack and the top frame's scopes
//! (two round trips). Control requests mark threads running at once and
//! put them back if the adapter refuses. Steps are coalesced: while one is
//! in flight (until the next `stopped`) one more is kept, later presses
//! replace it.
//!
//! Stop: a launched session gets `terminate` (when supported), then
//! `disconnect {terminateDebuggee: true}` after `stop_grace` without
//! `terminated`, then the adapter's process tree is killed after another
//! `stop_grace`. An attached session gets `disconnect {terminateDebuggee:
//! false}`. `restart` uses the adapter's `restart` when supported, else
//! stops and starts again with the `terminated` event's `restart` value
//! as `__restart`. `post_debug_task` runs after the session ends.
//!
//! Reverse requests (E07.F06.S02.T02): `runInTerminal`
//! (run_in_terminal.zig) and `startDebugging` (child_sessions.zig).
//! Stopping a session stops its children first. A member of a `stopAll`
//! compound (compounds.zig) stops and restarts with the other members.
//!
//! Threading: the accessors take the session lock and may be called from
//! any thread. Listeners (`DebugManager.subscribe`) are called on the
//! dispatcher or the session's worker, never with the lock held; the app
//! posts to its mailbox from them. Never call `deinit` from a listener.

const DebugSession = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const protocol = @import("../gen/protocol.zig");
const dap_json = @import("../proto/json.zig");
const DapConnection = @import("../conn/DapConnection.zig");
const LaunchConfig = @import("../config/LaunchConfig.zig");
const variables = @import("../config/variables.zig");
const threads_mod = @import("threads.zig");
const console_events = @import("console_events.zig");
const DebugManager = @import("DebugManager.zig");
const run_in_terminal = @import("run_in_terminal.zig");
const child_sessions = @import("child_sessions.zig");
const compounds = @import("compounds.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const ServerProcess = zg_lsp.client.ServerProcess;
const Subsystem = zg_core.runtime.Subsystem;
const RawJson = DapConnection.RawJson;

pub const ThreadState = threads_mod.ThreadState;
pub const StopReason = threads_mod.StopReason;
pub const Console = console_events.Console;

pub const SessionState = enum { initializing, configuring, launching, running, stopped, terminating, terminated, failed };

/// Who drives the session: a manual action through the UI hands it back
/// to the user (E07.F05.S02.T01).
pub const Controller = enum { user, agent };

pub const StepKind = enum { over, into, out, back };
pub const Granularity = enum { statement, line, instruction };

pub const SourceRef = struct {
    path: ?[]const u8 = null,
    source_reference: ?i64 = null,
    name: ?[]const u8 = null,
};

pub const StartOptions = struct {
    no_debug: bool = false,
    parent: ?*DebugSession = null,
    controller: Controller = .user,
    /// Sent as the launch/attach arguments instead of the configuration's
    /// (child sessions, E07.F06.S02.T02).
    start_request_override: ?Value = null,
    /// The configuration's inputs, for `${input:id}`.
    inputs: []const variables.InputDef = &.{},
    /// A child of a TCP adapter: connect to the parent's server instead
    /// of starting an adapter.
    connect: ?Connect = null,
    /// The compound this session was started with.
    compound: ?*compounds.CompoundRun = null,

    pub const Connect = struct { port: u16, adapter_id: []const u8 };
};

/// What changed, for listeners.
pub const Change = enum {
    state,
    threads,
    stopped,
    continued,
    focus,
    output,
    capabilities,
    progress,
    process,
    modules,
    loaded_sources,
    exited,
    invalidated,
    memory,
    prompt,
    /// The top frame and its scopes arrived after a stop.
    stack,
};

/// A question the session waits on.
pub const Prompt = struct {
    pub const Kind = enum { pre_launch_task_failed };
    pub const Choice = enum { debug_anyway, abort };

    kind: Kind,
    task: []const u8,
    message: []const u8,
};

pub const FrameInfo = struct {
    id: i64,
    name: []const u8,
    path: ?[]const u8,
    line: u32,
    column: u32,
};

pub const ScopeInfo = struct {
    name: []const u8,
    variables_reference: i64,
    expensive: bool,
};

pub const ProcessInfo = struct {
    name: []const u8,
    pid: ?i64,
};

pub const ModuleInfo = struct {
    /// The module id as JSON text (adapters use numbers or strings).
    id: []const u8,
    name: []const u8,
    path: ?[]const u8,
};

pub const Progress = struct {
    id: []const u8,
    title: []const u8,
    message: ?[]const u8,
    percentage: ?f64,
};

pub const StepInTarget = struct { id: i64, label: []const u8 };

pub const TargetsCb = struct {
    ctx: ?*anyopaque,
    /// `targets` is valid during the call; empty when the request failed.
    func: *const fn (ctx: ?*anyopaque, ok: bool, targets: []const StepInTarget) void,
};

pub const GotoCb = struct {
    ctx: ?*anyopaque,
    /// `message` (on failure) is valid during the call.
    func: *const fn (ctx: ?*anyopaque, ok: bool, message: ?[]const u8) void,
};

manager: *DebugManager,
rt: *zg_core.Runtime,
gpa: Allocator,
io: Io,
id: u32,
/// The configuration (a copy; `args` substituted once started).
cfg: LaunchConfig,
opts: StartOptions,
/// Configuration copies, launch arguments, messages. Under `mutex`.
arena: std.heap.ArenaAllocator,
mutex: Io.Mutex = .init,

state_: SessionState = .initializing,
caps_: protocol.Capabilities = .{},
caps_arena: std.heap.ArenaAllocator,
table: threads_mod.Table,
console: Console,
generation_: u64 = 0,
controller_: Controller,
children_: std.ArrayList(*DebugSession) = .empty,
/// Why the session failed (and the adapter's link for it).
failure: ?[]const u8 = null,
failure_url: ?[]const u8 = null,
exit_code_: ?i64 = null,
/// The `terminated` event's `restart` value, as JSON text.
restart_data: ?[]const u8 = null,
process_: ?ProcessInfo = null,
modules_: std.ArrayList(ModuleInfo) = .empty,
loaded_sources_: std.ArrayList([]const u8) = .empty,
progress_: std.ArrayList(Progress) = .empty,
top_frame_: ?FrameInfo = null,
top_scopes_: []const ScopeInfo = &.{},
/// The stopped thread's first `stackTrace` page and the top frame's
/// `scopes`, as body JSON (in `inspect_arena`), for the inspection model.
stack_body_: ?[]const u8 = null,
stack_thread_: i64 = 0,
scopes_body_: ?[]const u8 = null,
/// The last `invalidated` event body (gpa).
invalidated_: std.ArrayList(u8) = .empty,
/// Stack prefetch results; reset on every stop.
inspect_arena: std.heap.ArenaAllocator,
prompt_: ?Prompt = null,
prompt_answer: Prompt.Choice = .abort,
prompt_event: Io.Event = .unset,

step_in_flight: bool = false,
queued_step: ?QueuedStep = null,
temp_breakpoint: bool = false,
/// `initialized` events seen (a second one follows a native restart).
initialized_count: u32 = 0,

proc: ?*ServerProcess = null,
conn: ?*DapConnection = null,
initialized_event: Io.Event = .unset,
terminated_event: Io.Event = .unset,
/// Set when the session has ended (terminated or failed) and its adapter
/// is gone.
ended_event: Io.Event = .unset,
/// We are stopping it (no finisher on `terminated`).
stopping: std.atomic.Value(bool) = .init(false),
/// The connection is closed and the adapter terminated.
torn_down: std.atomic.Value(bool) = .init(true),
restarting: bool = false,
/// How children reach the adapter: its TCP port (0 for stdio) and
/// `adapterID`. Under `mutex`.
adapter_port: u16 = 0,
adapter_id: []const u8 = "",
work: Subsystem,

const QueuedStep = struct { kind: StepKind, thread: i64, gran: Granularity };

pub fn create(m: *DebugManager, id: u32, cfg: *const LaunchConfig, opts: StartOptions) !*DebugSession {
    const gpa = m.gpa;
    const s = try gpa.create(DebugSession);
    errdefer gpa.destroy(s);
    s.* = .{
        .manager = m,
        .rt = m.rt,
        .gpa = gpa,
        .io = m.rt.io,
        .id = id,
        .cfg = undefined,
        .opts = opts,
        .arena = .init(gpa),
        .caps_arena = .init(gpa),
        .table = .init(gpa),
        .console = .init(gpa),
        .inspect_arena = .init(gpa),
        .controller_ = opts.controller,
        .work = .init(m.rt.io),
    };
    errdefer s.freeParts();
    s.cfg = try copyConfig(s.arena.allocator(), cfg);
    if (opts.start_request_override) |v| s.opts.start_request_override = try copyValue(s.arena.allocator(), v);
    if (opts.connect) |cn| s.opts.connect = .{ .port = cn.port, .adapter_id = try s.arena.allocator().dupe(u8, cn.adapter_id) };
    return s;
}

fn freeParts(s: *DebugSession) void {
    s.console.deinit();
    s.table.deinit();
    s.inspect_arena.deinit();
    s.caps_arena.deinit();
    s.children_.deinit(s.gpa);
    s.modules_.deinit(s.gpa);
    s.loaded_sources_.deinit(s.gpa);
    s.progress_.deinit(s.gpa);
    s.invalidated_.deinit(s.gpa);
    s.arena.deinit();
}

/// Stops the session if it still runs, waits for its work and frees it.
/// Not from a listener or a connection callback.
pub fn deinit(s: *DebugSession) void {
    s.prompt_answer = .abort;
    s.prompt_event.set(s.io);
    if (!s.ended_event.isSet() and s.conn != null) s.stopBlocking(false);
    s.work.join() catch {};
    s.teardown();
    s.freeAdapter();
    s.freeParts();
    s.gpa.destroy(s);
}

fn freeAdapter(s: *DebugSession) void {
    if (s.conn) |c| c.deinit();
    s.conn = null;
    if (s.proc) |p| p.deinit();
    s.proc = null;
}

fn copyValue(a: Allocator, v: Value) Allocator.Error!Value {
    const text = std.json.Stringify.valueAlloc(a, v, .{}) catch return error.OutOfMemory;
    return std.json.parseFromSliceLeaky(Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

fn copyConfig(a: Allocator, c: *const LaunchConfig) Allocator.Error!LaunchConfig {
    var out = c.*;
    out.name = try a.dupe(u8, c.name);
    out.type = try a.dupe(u8, c.type);
    out.args = (try copyValue(a, .{ .object = c.args })).object;
    out.pre_launch_task = if (c.pre_launch_task) |t| try a.dupe(u8, t) else null;
    out.post_debug_task = if (c.post_debug_task) |t| try a.dupe(u8, t) else null;
    out.presentation = null;
    out.generated_task = null;
    out.origin_path = null;
    out.disabled_reason = null;
    return out;
}

// ---------------------------------------------------------------------
// Accessors.

pub fn state(s: *DebugSession) SessionState {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.state_;
}

/// The capabilities, merged with `capabilities` events. Slices stay valid
/// for the session's life.
pub fn caps(s: *DebugSession) protocol.Capabilities {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.caps_;
}

/// A copy of the threads, in `a`.
pub fn threads(s: *DebugSession, a: Allocator) Allocator.Error![]ThreadState {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const out = try a.alloc(ThreadState, s.table.list.items.len);
    for (out, s.table.list.items) |*o, t| {
        o.* = t;
        o.name = try a.dupe(u8, t.name);
        if (t.stop_reason) |r| o.stop_reason = .{
            .reason = try a.dupe(u8, r.reason),
            .description = if (r.description) |d| try a.dupe(u8, d) else null,
            .text = if (r.text) |d| try a.dupe(u8, d) else null,
            .hit_breakpoint_ids = try a.dupe(i64, r.hit_breakpoint_ids),
            .preserve_focus = r.preserve_focus,
        };
    }
    return out;
}

pub fn currentThread(s: *DebugSession) ?i64 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.table.current;
}

pub fn setCurrentThread(s: *DebugSession, id: i64) void {
    s.mutex.lockUncancelable(s.io);
    s.table.current = id;
    s.mutex.unlock(s.io);
    s.notify(.focus);
}

/// Bumps on every stop and resume: variable and frame references from an
/// older generation are stale (E07.F06.S04).
pub fn generation(s: *DebugSession) u64 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.generation_;
}

pub fn controller(s: *DebugSession) Controller {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.controller_;
}

pub fn setController(s: *DebugSession, c: Controller) void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    s.controller_ = c;
}

/// Child sessions (`startDebugging`, E07.F06.S02.T02). The list is
/// appended to by the manager only; read it on the thread that starts
/// sessions.
pub fn children(s: *const DebugSession) []const *DebugSession {
    return s.children_.items;
}

/// Child `i`, under the manager's lock (children are added from session
/// workers).
pub fn childAt(s: *DebugSession, i: usize) ?*DebugSession {
    const m = s.manager;
    m.mutex.lockUncancelable(m.rt.io);
    defer m.mutex.unlock(m.rt.io);
    return if (i < s.children_.items.len) s.children_.items[i] else null;
}

/// Why the session failed, in `a`.
pub fn failureMessage(s: *DebugSession, a: Allocator) Allocator.Error!?[]u8 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return if (s.failure) |f| try a.dupe(u8, f) else null;
}

pub fn exitCode(s: *DebugSession) ?i64 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.exit_code_;
}

/// The question the session waits on, if any (strings live as long as
/// the session).
pub fn prompt(s: *DebugSession) ?Prompt {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.prompt_;
}

pub fn answerPrompt(s: *DebugSession, choice: Prompt.Choice) void {
    s.mutex.lockUncancelable(s.io);
    s.prompt_answer = choice;
    s.prompt_ = null;
    s.mutex.unlock(s.io);
    s.prompt_event.set(s.io);
}

/// The stopped thread's top frame and scopes (fetched after each stop),
/// copied into `a`.
pub fn topFrame(s: *DebugSession, a: Allocator) Allocator.Error!?struct { frame: FrameInfo, scopes: []ScopeInfo } {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const f = s.top_frame_ orelse return null;
    var frame = f;
    frame.name = try a.dupe(u8, f.name);
    frame.path = if (f.path) |p| try a.dupe(u8, p) else null;
    const scopes = try a.alloc(ScopeInfo, s.top_scopes_.len);
    for (scopes, s.top_scopes_) |*o, sc| o.* = .{ .name = try a.dupe(u8, sc.name), .variables_reference = sc.variables_reference, .expensive = sc.expensive };
    return .{ .frame = frame, .scopes = scopes };
}

/// What the session fetched after the last stop, for the inspection
/// model (E07.F06.S04): set once the `stack` change is sent.
pub const Prefetch = struct {
    gen: u64,
    thread: i64,
    /// The `stackTrace` body (`startFrame: 0, levels: 20`).
    stack: []const u8,
    /// The top frame's `scopes` body.
    scopes: ?[]const u8,
};

/// The last stop's prefetch, copied into `a`.
pub fn prefetch(s: *DebugSession, a: Allocator) Allocator.Error!?Prefetch {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const stack = s.stack_body_ orelse return null;
    return .{
        .gen = s.generation_,
        .thread = s.stack_thread_,
        .stack = try a.dupe(u8, stack),
        .scopes = if (s.scopes_body_) |b| try a.dupe(u8, b) else null,
    };
}

/// The last `invalidated` event body, copied into `a`.
pub fn lastInvalidated(s: *DebugSession, a: Allocator) Allocator.Error![]u8 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return a.dupe(u8, s.invalidated_.items);
}

/// Runs `f(ctx, console)` under the session lock.
pub fn withConsole(s: *DebugSession, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Console) void) void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    f(ctx, &s.console);
}

pub fn process(s: *DebugSession) ?ProcessInfo {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.process_;
}

pub fn modulesCount(s: *DebugSession) usize {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.modules_.items.len;
}

pub fn loadedSourcesCount(s: *DebugSession) usize {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.loaded_sources_.items.len;
}

/// Running progress reports (`progressStart` without `progressEnd`).
pub fn progressCount(s: *DebugSession) usize {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.progress_.items.len;
}

/// The connection, for the inspection model and the breakpoint manager
/// (null before the adapter starts and after it ends).
pub fn connection(s: *DebugSession) ?*DapConnection {
    if (s.torn_down.load(.acquire)) return null;
    return s.conn;
}

/// Waits until the session has ended or `timeout` passed.
pub fn waitEnded(s: *DebugSession, timeout: Io.Duration) error{Timeout}!void {
    s.ended_event.waitTimeout(s.io, .{ .duration = .{ .raw = timeout, .clock = .awake } }) catch |e| switch (e) {
        error.Timeout => return error.Timeout,
        error.Canceled => return error.Timeout,
    };
}

fn notify(s: *DebugSession, change: Change) void {
    s.manager.notify(s, change);
}

fn setState(s: *DebugSession, st: SessionState) void {
    s.mutex.lockUncancelable(s.io);
    const changed = s.state_ != st;
    s.state_ = st;
    s.mutex.unlock(s.io);
    if (changed) s.notify(.state);
}

fn breakpointsEnded(s: *DebugSession) void {
    if (s.manager.cfg.breakpoints) |bp| if (bp.onEnd) |f| f(bp.ctx, s);
}

/// Adds an `important` line to the console (the session's own notices).
pub fn note(s: *DebugSession, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    s.mutex.lockUncancelable(s.io);
    const added = s.console.add(.{ .category = "important", .output = text }) catch null;
    s.mutex.unlock(s.io);
    if (added != null) s.notify(.output);
}

/// How a child session reaches this session's adapter.
pub fn adapterReach(s: *DebugSession) struct { port: u16, adapter_id: []const u8 } {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return .{ .port = s.adapter_port, .adapter_id = s.adapter_id };
}

fn fail(s: *DebugSession, comptime fmt: []const u8, args: anytype, url: ?[]const u8) void {
    s.mutex.lockUncancelable(s.io);
    const a = s.arena.allocator();
    s.failure = std.fmt.allocPrint(a, fmt, args) catch "out of memory";
    s.failure_url = if (url) |u| a.dupe(u8, u) catch null else null;
    s.state_ = .failed;
    s.mutex.unlock(s.io);
    s.notify(.state);
}

// ---------------------------------------------------------------------
// Requests.

/// Waits for one request's result from a worker thread (never the
/// dispatcher). The waiter is shared with the callback, so giving up
/// early is safe.
const Waiter = struct {
    gpa: Allocator,
    io: Io,
    event: Io.Event = .unset,
    result: ?DapConnection.RawResult = null,
    refs: std.atomic.Value(u8) = .init(2),

    fn done(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
        const w: *Waiter = @ptrCast(@alignCast(ctx.?));
        w.result = r;
        w.event.set(w.io);
        w.release();
    }

    fn release(w: *Waiter) void {
        if (w.refs.fetchSub(1, .acq_rel) != 1) return;
        if (w.result) |r| r.deinit();
        w.gpa.destroy(w);
    }
};

/// The outcome of `call`; free with `deinit`.
const CallResult = union(enum) {
    ok: DapConnection.OwnedResponse,
    failed: DapConnection.OwnedResponse,
    timeout,
    closed,

    fn deinit(r: CallResult) void {
        switch (r) {
            .ok, .failed => |o| o.deinit(),
            else => {},
        }
    }
};

/// Sends `command` and waits up to `timeout` (null: the connection's own
/// per-command timeout).
fn call(s: *DebugSession, command: []const u8, args: ?[]const u8, timeout: ?Io.Duration) CallResult {
    const c = s.connection() orelse return .closed;
    const w = s.gpa.create(Waiter) catch return .closed;
    w.* = .{ .gpa = s.gpa, .io = s.io };
    _ = c.requestRaw(command, args, .{ .ctx = w, .func = Waiter.done }) catch {
        s.gpa.destroy(w);
        return .closed;
    };
    if (timeout) |t| {
        w.event.waitTimeout(s.io, .{ .duration = .{ .raw = t, .clock = .awake } }) catch {
            w.release();
            return .timeout;
        };
    } else w.event.waitUncancelable(s.io);
    // The callback has run: take the result before dropping our ref.
    const r = w.result.?;
    w.result = null;
    w.release();
    return switch (r) {
        .ok => |o| .{ .ok = o },
        .failed => |o| .{ .failed = o },
        .timeout => .timeout,
        .closed => .closed,
    };
}

/// Sends `command` without waiting; `cb` (or nothing) gets the result.
fn send(s: *DebugSession, command: []const u8, args: ?[]const u8, cb: ?DapConnection.RawRespCb) bool {
    const c = s.connection() orelse return false;
    _ = c.requestRaw(command, args, cb orelse .{ .ctx = null, .func = ignore }) catch return false;
    return true;
}

/// Sends `command` (`args` is JSON text, or null) without waiting; `cb`
/// gets the result on the dispatcher. False when the adapter is gone (`cb`
/// is not called).
pub fn sendRequest(s: *DebugSession, command: []const u8, args: ?[]const u8, cb: DapConnection.RawRespCb) bool {
    return s.send(command, args, cb);
}

fn ignore(_: ?*anyopaque, r: DapConnection.RawResult) void {
    r.deinit();
}

/// A request callback that knows its session and the generation it was
/// sent in.
const Ctx = struct {
    s: *DebugSession,
    gen: u64,
    thread: i64 = 0,
    extra: ?*anyopaque = null,
    goto_cb: ?GotoCb = null,
    targets_cb: ?TargetsCb = null,
    snapshot: []ThreadState = &.{},
    all_stopped: bool = false,

    fn make(s: *DebugSession, gen: u64) ?*Ctx {
        const c = s.gpa.create(Ctx) catch return null;
        c.* = .{ .s = s, .gen = gen };
        return c;
    }

    fn destroy(c: *Ctx) void {
        c.s.gpa.free(c.snapshot);
        c.s.gpa.destroy(c);
    }
};

fn jsonText(a: Allocator, v: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{ .emit_null_optional_fields = false }) catch error.OutOfMemory;
}

fn parseBody(comptime T: type, a: Allocator, body: ?RawJson) ?T {
    const b = body orelse return null;
    return std.json.parseFromSliceLeaky(T, a, b.bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

// ---------------------------------------------------------------------
// Start.

/// The start sequence; runs on the session's worker.
pub fn run(s: *DebugSession) Io.Cancelable!void {
    s.runStart() catch |e| switch (e) {
        error.OutOfMemory => s.fail("out of memory", .{}, null),
    };
    if (s.state() == .failed) {
        s.teardown();
        s.breakpointsEnded();
        s.ended_event.set(s.io);
        s.notify(.state);
        if (s.opts.parent) |p| {
            var buf: [512]u8 = undefined;
            s.mutex.lockUncancelable(s.io);
            const why = std.fmt.bufPrint(&buf, "{s}", .{s.failure orelse "failed"}) catch buf[0..];
            s.mutex.unlock(s.io);
            p.note("The child session \"{s}\" failed: {s}", .{ s.cfg.name, why });
        }
    }
}

fn runStart(s: *DebugSession) Allocator.Error!void {
    s.setState(.initializing);
    const m = s.manager;
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // 1. Variables, on a copy (a restart substitutes again).
    var args: Value = .{ .object = s.cfg.args };
    if (s.opts.start_request_override) |o| args = o;
    args = try copyValue(sa, args);
    if (args != .object) return s.fail("the launch arguments of \"{s}\" are not an object", .{s.cfg.name}, null);
    if (m.cfg.vars) |vars| if (s.opts.parent == null) {
        variables.substituteValue(sa, &args, vars, s.opts.inputs) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => return s.fail("cancelled", .{}, null),
            else => return s.fail("cannot start \"{s}\": {t}", .{ s.cfg.name, e }, null),
        };
    };

    // 2. Pre-launch task.
    if (s.cfg.pre_launch_task) |label| if (m.cfg.tasks) |th| {
        const out = th.run(th.ctx, label, sa);
        switch (out) {
            .ok => {},
            .failed => |msg| {
                s.mutex.lockUncancelable(s.io);
                s.prompt_event.reset();
                s.prompt_ = .{ .kind = .pre_launch_task_failed, .task = label, .message = try s.arena.allocator().dupe(u8, msg) };
                s.mutex.unlock(s.io);
                s.notify(.prompt);
                s.prompt_event.waitUncancelable(s.io);
                if (s.prompt_answer == .abort) return s.fail("preLaunchTask \"{s}\" failed: {s}", .{ label, msg }, null);
            },
        }
    };

    // 3. The adapter (a child of a TCP adapter connects to its server).
    const spec: DebugManager.AdapterSpec = if (s.opts.connect) |cn|
        .{ .transport = .{ .tcp_connect = .{ .port = cn.port } }, .adapter_id = cn.adapter_id }
    else
        m.cfg.resolver.resolve(m.cfg.resolver.ctx, sa, &s.cfg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return s.fail("no debug adapter for \"{s}\": {t}", .{ s.cfg.type, e }, null),
        };
    if (spec.message) |msg| return s.fail("{s}", .{msg}, null);
    s.proc = ServerProcess.start(s.rt, .{
        .argv = spec.argv,
        .cwd = spec.cwd,
        .transport = spec.transport,
        .base_env = spec.env,
        .name = "debug adapter",
    }, m.cfg.policy, ServerProcess.default_stderr_cap) catch |e| {
        return s.fail("cannot start the debug adapter ({s}): {t}", .{ if (spec.argv.len > 0) spec.argv[0] else "connect", e }, null);
    };
    {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.adapter_port = if (spec.transport == .stdio) 0 else s.proc.?.port;
        s.adapter_id = try s.arena.allocator().dupe(u8, spec.adapter_id);
    }
    s.conn = DapConnection.init(s.rt, s.proc.?.transport(), m.cfg.conn) catch |e| {
        return s.fail("cannot connect to the debug adapter: {t}", .{e}, null);
    };
    const c = s.conn.?;
    try c.onEvent(.{ .ctx = s, .func = onEvent });
    c.onClose(.{ .ctx = s, .func = onClose });
    try c.onReverseRequest("runInTerminal", .{ .ctx = s, .func = run_in_terminal.handle });
    try c.onReverseRequest("startDebugging", .{ .ctx = s, .func = child_sessions.handle });
    s.initialized_event.reset();
    s.terminated_event.reset();
    s.ended_event.reset();
    s.stopping.store(false, .release);
    s.torn_down.store(false, .release);
    c.start() catch |e| return s.fail("cannot connect to the debug adapter: {t}", .{e}, null);

    // 4. initialize.
    const init_args: protocol.InitializeRequestArguments = .{
        .clientID = "zigguro",
        .clientName = "zigguro",
        .adapterID = spec.adapter_id,
        .locale = m.cfg.locale,
        .linesStartAt1 = true,
        .columnsStartAt1 = true,
        .pathFormat = .{ .known = .path },
        .supportsVariableType = true,
        .supportsVariablePaging = true,
        .supportsRunInTerminalRequest = true,
        .supportsMemoryReferences = true,
        .supportsProgressReporting = true,
        .supportsInvalidatedEvent = true,
        .supportsMemoryEvent = true,
        .supportsArgsCanBeInterpretedByShell = true,
        .supportsStartDebuggingRequest = true,
        .supportsANSIStyling = true,
    };
    switch (s.call("initialize", try jsonText(sa, init_args), null)) {
        .ok => |o| {
            defer o.deinit();
            s.mutex.lockUncancelable(s.io);
            if (parseBody(protocol.Capabilities, s.caps_arena.allocator(), o.response.body)) |cp| s.caps_ = cp;
            const cancel = s.caps_.supportsCancelRequest orelse false;
            s.mutex.unlock(s.io);
            c.setSupportsCancel(cancel);
            s.notify(.capabilities);
        },
        .failed => |o| {
            defer o.deinit();
            return s.fail("the debug adapter refused to start: {s}", .{o.errorText()}, null);
        },
        .timeout => return s.fail("the debug adapter did not answer initialize", .{}, null),
        .closed => return s.fail("the debug adapter exited during initialize{s}", .{s.stderrHint(sa)}, null),
    }

    // 5. launch/attach, answered later.
    s.setState(.configuring);
    var start_args = args.object;
    if (s.opts.parent == null) if (spec.normalize) |f| f(sa, s.cfg.request, &start_args) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return s.fail("invalid configuration \"{s}\": {t}", .{ s.cfg.name, e }, null),
    };
    if (s.opts.no_debug) try start_args.put(sa, "noDebug", .{ .bool = true });
    if (s.restart_data) |r| {
        const v = std.json.parseFromSliceLeaky(Value, sa, r, .{}) catch Value{ .bool = true };
        try start_args.put(sa, "__restart", v);
    }
    const launch = try s.gpa.create(LaunchWait);
    launch.* = .{ .gpa = s.gpa, .io = s.io };
    if (!s.send(@tagName(s.cfg.request), try jsonText(sa, Value{ .object = start_args }), .{ .ctx = launch, .func = LaunchWait.done })) {
        s.gpa.destroy(launch);
        return s.fail("the debug adapter exited", .{}, null);
    }
    defer launch.release();

    // 6. initialized, then the breakpoints.
    s.initialized_event.waitTimeout(s.io, .{ .duration = .{ .raw = m.cfg.timeouts.initialized, .clock = .awake } }) catch {
        if (launch.event.isSet() and launch.failedNow()) return s.failLaunch(launch);
        return s.fail("the debug adapter did not send initialized within {d} s", .{@divTrunc(m.cfg.timeouts.initialized.toMilliseconds(), 1000)}, null);
    };
    if (m.cfg.breakpoints) |b| b.sendAll(b.ctx, s);

    // 7. configurationDone.
    if (s.caps().supportsConfigurationDoneRequest orelse false) {
        switch (s.call("configurationDone", null, null)) {
            .ok, .failed => |o| o.deinit(),
            else => {},
        }
    }

    // 8. The launch/attach response.
    if (s.state() == .configuring) s.setState(.launching);
    launch.event.waitUncancelable(s.io);
    if (launch.failedNow()) return s.failLaunch(launch);
    s.mutex.lockUncancelable(s.io);
    const changed = s.state_ == .launching or s.state_ == .configuring;
    if (changed) s.state_ = if (s.table.anyStopped()) .stopped else .running;
    s.mutex.unlock(s.io);
    if (changed) s.notify(.state);
}

/// The launch/attach response, shared with its callback.
const LaunchWait = struct {
    gpa: Allocator,
    io: Io,
    event: Io.Event = .unset,
    result: ?DapConnection.RawResult = null,
    refs: std.atomic.Value(u8) = .init(2),

    fn done(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
        const w: *LaunchWait = @ptrCast(@alignCast(ctx.?));
        w.result = r;
        w.event.set(w.io);
        w.release();
    }

    fn failedNow(w: *const LaunchWait) bool {
        return switch (w.result orelse return false) {
            .ok => false,
            else => true,
        };
    }

    fn release(w: *LaunchWait) void {
        if (w.refs.fetchSub(1, .acq_rel) != 1) return;
        if (w.result) |r| r.deinit();
        w.gpa.destroy(w);
    }
};

fn failLaunch(s: *DebugSession, w: *LaunchWait) void {
    const what = @tagName(s.cfg.request);
    switch (w.result.?) {
        .failed => |o| {
            var url: ?[]const u8 = null;
            if (o.response.error_body) |e| url = e.url;
            s.fail("{s} failed: {s}", .{ what, o.errorText() }, url);
        },
        .timeout => s.fail("{s} timed out", .{what}, null),
        .closed => s.fail("the debug adapter exited during {s}", .{what}, null),
        .ok => {},
    }
}

fn stderrHint(s: *DebugSession, a: Allocator) []const u8 {
    const p = s.proc orelse return "";
    var tail: std.ArrayList(u8) = .empty;
    p.stderrTail(&tail, 5) catch return "";
    if (tail.items.len == 0) return "";
    return std.fmt.allocPrint(a, ": {s}", .{std.mem.trim(u8, tail.items, " \r\n")}) catch "";
}

// ---------------------------------------------------------------------
// Events (on the dispatcher).

fn onEvent(ctx: ?*anyopaque, _: *DapConnection, event: []const u8, body: ?RawJson, _: u32) void {
    const s: *DebugSession = @ptrCast(@alignCast(ctx.?));
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    s.handleEvent(arena.allocator(), event, body) catch {};
}

const ev = struct {
    const Stopped = struct {
        reason: []const u8 = "unknown",
        description: ?[]const u8 = null,
        threadId: ?i64 = null,
        preserveFocusHint: ?bool = null,
        text: ?[]const u8 = null,
        allThreadsStopped: ?bool = null,
        hitBreakpointIds: ?[]const i64 = null,
    };
    const Continued = struct { threadId: ?i64 = null, allThreadsContinued: ?bool = null };
    const Thread = struct { reason: []const u8 = "started", threadId: i64 = 0 };
    const Exited = struct { exitCode: i64 = 0 };
    const Terminated = struct { restart: ?Value = null };
    const Caps = struct { capabilities: protocol.Capabilities = .{} };
    const ProgressStart = struct { progressId: []const u8 = "", title: []const u8 = "", message: ?[]const u8 = null, percentage: ?f64 = null };
    const ProgressUpdate = struct { progressId: []const u8 = "", message: ?[]const u8 = null, percentage: ?f64 = null };
    const ProgressEnd = struct { progressId: []const u8 = "" };
    const Module = struct { reason: []const u8 = "new", module: struct { id: Value = .null, name: []const u8 = "", path: ?[]const u8 = null } = .{} };
    const LoadedSource = struct { reason: []const u8 = "new", source: struct { path: ?[]const u8 = null, name: ?[]const u8 = null } = .{} };
    const Process = struct { name: []const u8 = "", systemProcessId: ?i64 = null };
};

fn handleEvent(s: *DebugSession, a: Allocator, event: []const u8, body: ?RawJson) Allocator.Error!void {
    const E = enum { initialized, stopped, continued, thread, output, exited, terminated, capabilities, progressStart, progressUpdate, progressEnd, module, loadedSource, process, invalidated, memory, breakpoint };
    const kind = std.meta.stringToEnum(E, event) orelse return;
    switch (kind) {
        .initialized => {
            s.mutex.lockUncancelable(s.io);
            s.initialized_count += 1;
            const again = s.initialized_count > 1;
            s.mutex.unlock(s.io);
            s.initialized_event.set(s.io);
            // After a native restart the adapter asks for the
            // configuration again.
            if (again) s.work.spawnLoop(reconfigure, .{s}) catch {};
        },
        .stopped => try s.onStopped(a, parseBody(ev.Stopped, a, body) orelse .{}),
        .continued => {
            const b = parseBody(ev.Continued, a, body) orelse ev.Continued{};
            s.mutex.lockUncancelable(s.io);
            s.table.applyContinued(b.threadId, b.allThreadsContinued orelse true);
            s.generation_ += 1;
            const st_changed = !s.table.anyStopped() and s.state_ == .stopped;
            if (st_changed) s.state_ = .running;
            s.mutex.unlock(s.io);
            s.notify(.continued);
            if (st_changed) s.notify(.state);
        },
        .thread => {
            const b = parseBody(ev.Thread, a, body) orelse return;
            s.mutex.lockUncancelable(s.io);
            try s.table.applyThreadEvent(b.threadId, b.reason);
            s.mutex.unlock(s.io);
            s.notify(.threads);
        },
        .output => {
            const b = parseBody(console_events.OutputBody, a, body) orelse return;
            s.mutex.lockUncancelable(s.io);
            const cat = try s.console.add(b);
            s.mutex.unlock(s.io);
            if (cat != null) s.notify(.output);
        },
        .exited => {
            const b = parseBody(ev.Exited, a, body) orelse ev.Exited{};
            s.mutex.lockUncancelable(s.io);
            s.exit_code_ = b.exitCode;
            s.mutex.unlock(s.io);
            s.notify(.exited);
        },
        .terminated => {
            const b = parseBody(ev.Terminated, a, body) orelse ev.Terminated{};
            s.mutex.lockUncancelable(s.io);
            s.restart_data = if (b.restart) |r| (if (r == .null) null else try jsonText(s.arena.allocator(), r)) else null;
            s.step_in_flight = false;
            s.queued_step = null;
            s.mutex.unlock(s.io);
            s.terminated_event.set(s.io);
            if (!s.stopping.load(.acquire)) s.work.spawnLoop(finishAfterTerminated, .{s}) catch {};
        },
        .capabilities => {
            const b = parseBody(ev.Caps, s.caps_arena.allocator(), body) orelse return;
            s.mutex.lockUncancelable(s.io);
            inline for (std.meta.fields(protocol.Capabilities)) |f| {
                if (@field(b.capabilities, f.name)) |v| @field(s.caps_, f.name) = v;
            }
            const cancel = s.caps_.supportsCancelRequest orelse false;
            s.mutex.unlock(s.io);
            if (s.connection()) |c| c.setSupportsCancel(cancel);
            s.notify(.capabilities);
        },
        .progressStart => {
            const b = parseBody(ev.ProgressStart, a, body) orelse return;
            {
                s.mutex.lockUncancelable(s.io);
                defer s.mutex.unlock(s.io);
                const sa = s.arena.allocator();
                try s.progress_.append(s.gpa, .{ .id = try sa.dupe(u8, b.progressId), .title = try sa.dupe(u8, b.title), .message = if (b.message) |x| try sa.dupe(u8, x) else null, .percentage = b.percentage });
            }
            s.notify(.progress);
        },
        .progressUpdate => {
            const b = parseBody(ev.ProgressUpdate, a, body) orelse return;
            s.mutex.lockUncancelable(s.io);
            for (s.progress_.items) |*p| if (std.mem.eql(u8, p.id, b.progressId)) {
                if (b.message) |x| p.message = try s.arena.allocator().dupe(u8, x);
                if (b.percentage) |x| p.percentage = x;
            };
            s.mutex.unlock(s.io);
            s.notify(.progress);
        },
        .progressEnd => {
            const b = parseBody(ev.ProgressEnd, a, body) orelse return;
            s.mutex.lockUncancelable(s.io);
            for (s.progress_.items, 0..) |p, i| if (std.mem.eql(u8, p.id, b.progressId)) {
                _ = s.progress_.orderedRemove(i);
                break;
            };
            s.mutex.unlock(s.io);
            s.notify(.progress);
        },
        .module => {
            const b = parseBody(ev.Module, a, body) orelse return;
            const id = try jsonText(a, b.module.id);
            s.mutex.lockUncancelable(s.io);
            const sa = s.arena.allocator();
            var idx: ?usize = null;
            for (s.modules_.items, 0..) |mm, i| if (std.mem.eql(u8, mm.id, id)) {
                idx = i;
                break;
            };
            if (std.mem.eql(u8, b.reason, "removed")) {
                if (idx) |i| _ = s.modules_.orderedRemove(i);
            } else {
                const info: ModuleInfo = .{ .id = try sa.dupe(u8, id), .name = try sa.dupe(u8, b.module.name), .path = if (b.module.path) |p| try sa.dupe(u8, p) else null };
                if (idx) |i| s.modules_.items[i] = info else try s.modules_.append(s.gpa, info);
            }
            s.mutex.unlock(s.io);
            s.notify(.modules);
        },
        .loadedSource => {
            const b = parseBody(ev.LoadedSource, a, body) orelse return;
            const key = b.source.path orelse b.source.name orelse return;
            s.mutex.lockUncancelable(s.io);
            var idx: ?usize = null;
            for (s.loaded_sources_.items, 0..) |p, i| if (std.mem.eql(u8, p, key)) {
                idx = i;
                break;
            };
            if (std.mem.eql(u8, b.reason, "removed")) {
                if (idx) |i| _ = s.loaded_sources_.orderedRemove(i);
            } else if (idx == null) try s.loaded_sources_.append(s.gpa, try s.arena.allocator().dupe(u8, key));
            s.mutex.unlock(s.io);
            s.notify(.loaded_sources);
        },
        .process => {
            const b = parseBody(ev.Process, a, body) orelse return;
            s.mutex.lockUncancelable(s.io);
            s.process_ = .{ .name = try s.arena.allocator().dupe(u8, b.name), .pid = b.systemProcessId };
            s.mutex.unlock(s.io);
            s.notify(.process);
        },
        .invalidated => {
            s.mutex.lockUncancelable(s.io);
            s.invalidated_.clearRetainingCapacity();
            s.invalidated_.appendSlice(s.gpa, if (body) |b| b.bytes else "{}") catch {};
            s.mutex.unlock(s.io);
            s.notify(.invalidated);
        },
        .memory => s.notify(.memory),
        .breakpoint => if (s.manager.cfg.breakpoints) |bp| if (bp.onEvent) |f| {
            if (body) |b| f(bp.ctx, s, b.bytes);
        },
    }
}

fn onStopped(s: *DebugSession, a: Allocator, b: ev.Stopped) Allocator.Error!void {
    _ = a;
    s.mutex.lockUncancelable(s.io);
    try s.table.applyStopped(.{
        .reason = b.reason,
        .description = b.description,
        .text = b.text,
        .thread_id = b.threadId,
        .all_threads_stopped = b.allThreadsStopped orelse false,
        .preserve_focus = b.preserveFocusHint orelse false,
        .hit_breakpoint_ids = b.hitBreakpointIds orelse &.{},
    });
    s.generation_ += 1;
    const gen = s.generation_;
    s.step_in_flight = false;
    const queued = s.queued_step;
    s.queued_step = null;
    const temp = s.temp_breakpoint;
    s.temp_breakpoint = false;
    const st_changed = s.state_ == .running or s.state_ == .launching or s.state_ == .configuring;
    if (s.state_ == .running) s.state_ = .stopped;
    s.top_frame_ = null;
    s.top_scopes_ = &.{};
    s.stack_body_ = null;
    s.scopes_body_ = null;
    _ = s.inspect_arena.reset(.retain_capacity);
    const focus = s.table.current;
    s.mutex.unlock(s.io);

    if (temp) if (s.manager.cfg.breakpoints) |bp| if (bp.clearTemp) |f| f(bp.ctx, s);
    s.notify(.stopped);
    if (st_changed) s.notify(.state);
    if (queued) |q| {
        // A step pressed while the last one ran.
        s.stepBy(s.controller(), q.kind, q.thread, q.gran);
        return;
    }
    // Round trip 1: the threads and the stopped thread's stack, in
    // parallel; round trip 2: the top frame's scopes.
    if (Ctx.make(s, gen)) |tc| {
        if (!s.send("threads", null, .{ .ctx = tc, .func = onThreads })) tc.destroy();
    }
    const thread = b.threadId orelse focus orelse return;
    const c = Ctx.make(s, gen) orelse return;
    c.thread = thread;
    var buf: [96]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d},\"startFrame\":0,\"levels\":20}}", .{thread}) catch unreachable;
    if (!s.send("stackTrace", args, .{ .ctx = c, .func = onStackTrace })) c.destroy();
}

fn onThreads(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    defer c.destroy();
    defer r.deinit();
    const s = c.s;
    const o = switch (r) {
        .ok => |o| o,
        else => return,
    };
    const Body = struct { threads: []const struct { id: i64, name: []const u8 = "" } = &.{} };
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const b = parseBody(Body, arena.allocator(), o.response.body) orelse return;
    const items = arena.allocator().alloc(threads_mod.NamedThread, b.threads.len) catch return;
    for (items, b.threads) |*it, t| it.* = .{ .id = t.id, .name = t.name };
    s.mutex.lockUncancelable(s.io);
    s.table.applyThreads(items) catch {};
    s.mutex.unlock(s.io);
    s.notify(.threads);
}

fn onStackTrace(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    defer r.deinit();
    const s = c.s;
    const o = switch (r) {
        .ok => |o| o,
        else => return c.destroy(),
    };
    const Body = struct {
        stackFrames: []const struct {
            id: i64,
            name: []const u8 = "",
            line: i64 = 0,
            column: i64 = 0,
            source: ?struct { path: ?[]const u8 = null, name: ?[]const u8 = null } = null,
        } = &.{},
    };
    s.mutex.lockUncancelable(s.io);
    if (s.generation_ != c.gen) {
        s.mutex.unlock(s.io);
        return c.destroy();
    }
    const ia = s.inspect_arena.allocator();
    const b = parseBody(Body, ia, o.response.body);
    const top = if (b) |bb| (if (bb.stackFrames.len > 0) bb.stackFrames[0] else null) else null;
    if (o.response.body) |body| {
        s.stack_body_ = ia.dupe(u8, body.bytes) catch null;
        s.stack_thread_ = c.thread;
    }
    if (top) |f| s.top_frame_ = .{
        .id = f.id,
        .name = f.name,
        .path = if (f.source) |src| src.path else null,
        .line = @intCast(@max(0, f.line)),
        .column = @intCast(@max(0, f.column)),
    };
    s.mutex.unlock(s.io);
    const f = top orelse {
        s.notify(.stack);
        return c.destroy();
    };
    var buf: [48]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"frameId\":{d}}}", .{f.id}) catch unreachable;
    if (!s.send("scopes", args, .{ .ctx = c, .func = onScopes })) c.destroy();
}

fn onScopes(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    defer c.destroy();
    defer r.deinit();
    const s = c.s;
    const Body = struct { scopes: []const struct { name: []const u8 = "", variablesReference: i64 = 0, expensive: bool = false } = &.{} };
    switch (r) {
        .ok => |o| {
            s.mutex.lockUncancelable(s.io);
            if (s.generation_ == c.gen) {
                const ia = s.inspect_arena.allocator();
                if (o.response.body) |body| s.scopes_body_ = ia.dupe(u8, body.bytes) catch null;
                if (parseBody(Body, ia, o.response.body)) |b| {
                    if (ia.alloc(ScopeInfo, b.scopes.len)) |out| {
                        for (out, b.scopes) |*x, sc| x.* = .{ .name = sc.name, .variables_reference = sc.variablesReference, .expensive = sc.expensive };
                        s.top_scopes_ = out;
                    } else |_| {}
                }
            }
            s.mutex.unlock(s.io);
        },
        else => {},
    }
    s.notify(.stack);
}

/// After a native restart: breakpoints and `configurationDone` again.
fn reconfigure(s: *DebugSession) Io.Cancelable!void {
    if (s.manager.cfg.breakpoints) |b| b.sendAll(b.ctx, s);
    if (s.caps().supportsConfigurationDoneRequest orelse false) switch (s.call("configurationDone", null, null)) {
        .ok, .failed => |o| o.deinit(),
        else => {},
    };
}

fn onClose(ctx: ?*anyopaque, _: *DapConnection) void {
    const s: *DebugSession = @ptrCast(@alignCast(ctx.?));
    // Our own teardown closed it, or a stop or a finisher will end the
    // session.
    if (s.torn_down.load(.acquire) or s.stopping.load(.acquire) or s.terminated_event.isSet()) return;
    s.work.spawnLoop(finishAfterCrash, .{s}) catch {};
}

fn finishAfterCrash(s: *DebugSession) Io.Cancelable!void {
    if (s.stopping.swap(true, .acq_rel)) return;
    const st = s.state();
    s.teardown();
    if (st == .initializing or st == .configuring or st == .launching) {
        // The start worker reports it.
    } else s.endSession(true);
}

/// The adapter said `terminated` by itself: disconnect and end.
fn finishAfterTerminated(s: *DebugSession) Io.Cancelable!void {
    if (s.stopping.swap(true, .acq_rel)) return;
    s.setState(.terminating);
    switch (s.call("disconnect", "{\"restart\":false}", s.manager.cfg.timeouts.stop_grace)) {
        .ok, .failed => |o| o.deinit(),
        else => {},
    }
    s.teardown();
    s.endSession(false);
}

/// Closes the connection and ends the adapter (killing its tree after
/// `stop_grace`). Idempotent. Not from the dispatcher.
fn teardown(s: *DebugSession) void {
    if (s.torn_down.swap(true, .acq_rel)) return;
    if (s.conn) |c| c.close();
    if (s.proc) |p| p.terminate(s.manager.cfg.timeouts.stop_grace);
}

fn endSession(s: *DebugSession, crashed: bool) void {
    child_sessions.stopChildren(s);
    s.breakpointsEnded();
    s.mutex.lockUncancelable(s.io);
    s.table.applyContinued(null, true);
    s.step_in_flight = false;
    s.queued_step = null;
    if (crashed and s.failure == null) s.failure = "the debug adapter exited";
    s.state_ = .terminated;
    s.mutex.unlock(s.io);
    s.notify(.state);
    if (!s.restarting) if (s.cfg.post_debug_task) |label| if (s.manager.cfg.tasks) |th| {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        _ = th.run(th.ctx, label, arena.allocator());
    };
    s.ended_event.set(s.io);
}

// ---------------------------------------------------------------------
// Control.

fn threadOrCurrent(s: *DebugSession, thread: ?i64) ?i64 {
    if (thread) |t| return t;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.table.current) |c| return c;
    if (s.table.list.items.len > 0) return s.table.list.items[0].id;
    return null;
}

/// Marks threads running before the adapter answers; the returned
/// context puts them back if it refuses.
fn optimisticResume(s: *DebugSession, thread: ?i64, all: bool, by: Controller) ?*Ctx {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const c = Ctx.make(s, 0) orelse return null;
    c.snapshot = s.table.snapshot(s.gpa) catch &.{};
    c.all_stopped = s.table.all_stopped;
    s.table.applyContinued(thread, all);
    s.generation_ += 1;
    c.gen = s.generation_;
    s.controller_ = by;
    if (s.state_ == .stopped and !s.table.anyStopped()) s.state_ = .running;
    return c;
}

fn onResumeResult(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    defer c.destroy();
    defer r.deinit();
    const s = c.s;
    const ok = r == .ok;
    s.mutex.lockUncancelable(s.io);
    var changed = false;
    if (!ok) {
        s.step_in_flight = false;
        s.queued_step = null;
        // Put the threads back, unless something happened since.
        if (s.generation_ == c.gen) {
            s.table.restore(c.snapshot, c.all_stopped);
            if (s.table.anyStopped() and s.state_ == .running) s.state_ = .stopped;
            changed = true;
        }
    } else if (std.mem.eql(u8, r.ok.response.command, "continue")) {
        // `allThreadsContinued: false`: only the thread runs.
        const Body = struct { allThreadsContinued: ?bool = null };
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        if (parseBody(Body, arena.allocator(), r.ok.response.body)) |b| if (b.allThreadsContinued == false and s.generation_ == c.gen) {
            for (c.snapshot) |old| if (old.id != c.thread) if (s.table.find(old.id)) |th| {
                th.stopped = old.stopped;
                th.stop_reason = old.stop_reason;
            };
            if (s.table.anyStopped() and s.state_ == .running) s.state_ = .stopped;
            changed = true;
        };
    }
    s.mutex.unlock(s.io);
    if (changed) {
        s.notify(.threads);
        s.notify(.state);
    }
}

pub fn continue_(s: *DebugSession, thread: ?i64) void {
    s.continueBy(.user, thread);
}

pub fn continueBy(s: *DebugSession, by: Controller, thread: ?i64) void {
    const t = s.threadOrCurrent(thread) orelse return;
    const c = s.optimisticResume(null, true, by) orelse return;
    c.thread = t;
    s.notify(.continued);
    s.notify(.state);
    var buf: [48]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{t}) catch unreachable;
    if (!s.send("continue", args, .{ .ctx = c, .func = onResumeResult })) c.destroy();
}

pub fn pause(s: *DebugSession, thread: ?i64) void {
    s.pauseBy(.user, thread);
}

pub fn pauseBy(s: *DebugSession, by: Controller, thread: ?i64) void {
    s.setController(by);
    const t = s.threadOrCurrent(thread) orelse 0;
    var buf: [48]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{t}) catch unreachable;
    _ = s.send("pause", args, null);
}

pub fn step(s: *DebugSession, kind: StepKind, thread: i64, gran: Granularity) void {
    s.stepBy(.user, kind, thread, gran);
}

pub fn stepBy(s: *DebugSession, by: Controller, kind: StepKind, thread: i64, gran: Granularity) void {
    s.mutex.lockUncancelable(s.io);
    if (kind == .back and !(s.caps_.supportsStepBack orelse false)) {
        s.mutex.unlock(s.io);
        return;
    }
    if (s.step_in_flight) {
        // Coalesce: keep one more step, the latest.
        s.queued_step = .{ .kind = kind, .thread = thread, .gran = gran };
        s.controller_ = by;
        s.mutex.unlock(s.io);
        return;
    }
    s.step_in_flight = true;
    const with_gran = s.caps_.supportsSteppingGranularity orelse false;
    s.mutex.unlock(s.io);
    const c = s.optimisticResume(thread, false, by) orelse return;
    c.thread = thread;
    s.notify(.continued);
    const command = switch (kind) {
        .over => "next",
        .into => "stepIn",
        .out => "stepOut",
        .back => "stepBack",
    };
    var buf: [96]u8 = undefined;
    const args = if (with_gran)
        std.fmt.bufPrint(&buf, "{{\"threadId\":{d},\"granularity\":\"{t}\"}}", .{ thread, gran }) catch unreachable
    else
        std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{thread}) catch unreachable;
    if (!s.send(command, args, .{ .ctx = c, .func = onResumeResult })) {
        s.mutex.lockUncancelable(s.io);
        s.step_in_flight = false;
        s.mutex.unlock(s.io);
        c.destroy();
    }
}

/// `reverseContinue` (when `supportsStepBack`).
pub fn reverseContinue(s: *DebugSession, thread: ?i64) void {
    if (!(s.caps().supportsStepBack orelse false)) return;
    const t = s.threadOrCurrent(thread) orelse return;
    const c = s.optimisticResume(null, true, .user) orelse return;
    c.thread = t;
    var buf: [48]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{t}) catch unreachable;
    if (!s.send("reverseContinue", args, .{ .ctx = c, .func = onResumeResult })) c.destroy();
}

pub fn stepInTargets(s: *DebugSession, frame: i64, cb: TargetsCb) void {
    const c = Ctx.make(s, 0) orelse return cb.func(cb.ctx, false, &.{});
    c.targets_cb = cb;
    var buf: [48]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"frameId\":{d}}}", .{frame}) catch unreachable;
    if (!s.send("stepInTargets", args, .{ .ctx = c, .func = onTargets })) {
        c.destroy();
        cb.func(cb.ctx, false, &.{});
    }
}

fn onTargets(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    defer c.destroy();
    defer r.deinit();
    const cb = c.targets_cb.?;
    const o = switch (r) {
        .ok => |o| o,
        else => return cb.func(cb.ctx, false, &.{}),
    };
    const Body = struct { targets: []const StepInTarget = &.{} };
    var arena: std.heap.ArenaAllocator = .init(c.s.gpa);
    defer arena.deinit();
    const b = parseBody(Body, arena.allocator(), o.response.body) orelse return cb.func(cb.ctx, false, &.{});
    cb.func(cb.ctx, true, b.targets);
}

fn sourceJson(a: Allocator, src: SourceRef) Allocator.Error![]u8 {
    var o: ObjectMap = .empty;
    if (src.path) |p| try o.put(a, "path", .{ .string = p });
    if (src.name) |n| try o.put(a, "name", .{ .string = n });
    if (src.source_reference) |r| try o.put(a, "sourceReference", .{ .integer = r });
    return jsonText(a, Value{ .object = o });
}

/// Runs to `line`: a hidden breakpoint (the manager's sink), removed on
/// the next stop, then `continue`. False when there is no sink.
pub fn runToLine(s: *DebugSession, src: SourceRef, line: u32) bool {
    const bp = s.manager.cfg.breakpoints orelse return false;
    const set = bp.setTemp orelse return false;
    if (!set(bp.ctx, s, src, line)) return false;
    s.mutex.lockUncancelable(s.io);
    s.temp_breakpoint = true;
    s.mutex.unlock(s.io);
    s.continue_(null);
    return true;
}

/// Moves `thread` to `line` (`gotoTargets`, then `goto` to the first
/// target).
pub fn gotoLine(s: *DebugSession, thread: i64, src: SourceRef, line: u32, cb: GotoCb) void {
    if (!(s.caps().supportsGotoTargetsRequest orelse false)) return cb.func(cb.ctx, false, "the debug adapter cannot jump to a line");
    const c = Ctx.make(s, 0) orelse return cb.func(cb.ctx, false, "out of memory");
    c.goto_cb = cb;
    c.thread = thread;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = std.fmt.allocPrint(a, "{{\"source\":{s},\"line\":{d}}}", .{ sourceJson(a, src) catch "{}", line }) catch "{}";
    if (!s.send("gotoTargets", args, .{ .ctx = c, .func = onGotoTargets })) {
        c.destroy();
        cb.func(cb.ctx, false, "the debug adapter exited");
    }
}

fn onGotoTargets(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    defer r.deinit();
    const cb = c.goto_cb.?;
    const s = c.s;
    const o = switch (r) {
        .ok => |o| o,
        .failed => |o| {
            c.destroy();
            return cb.func(cb.ctx, false, o.errorText());
        },
        else => {
            c.destroy();
            return cb.func(cb.ctx, false, "no answer");
        },
    };
    const Body = struct { targets: []const struct { id: i64 } = &.{} };
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const b = parseBody(Body, arena.allocator(), o.response.body) orelse Body{};
    if (b.targets.len == 0) {
        c.destroy();
        return cb.func(cb.ctx, false, "no code at that line");
    }
    var buf: [64]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d},\"targetId\":{d}}}", .{ c.thread, b.targets[0].id }) catch unreachable;
    if (!s.send("goto", args, .{ .ctx = c, .func = onGoto })) {
        c.destroy();
        cb.func(cb.ctx, false, "the debug adapter exited");
    }
}

fn onGoto(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    defer c.destroy();
    defer r.deinit();
    const cb = c.goto_cb.?;
    switch (r) {
        .ok => cb.func(cb.ctx, true, null),
        .failed => |o| cb.func(cb.ctx, false, o.errorText()),
        else => cb.func(cb.ctx, false, "no answer"),
    }
}

// ---------------------------------------------------------------------
// Stop, detach, restart.

/// Ends the session (see the file comment for the escalation), and the
/// other members of its `stopAll` compound. Returns at once; `waitEnded`
/// waits.
pub fn stop(s: *DebugSession) void {
    if (s.opts.compound) |r| if (r.stop_all) return compounds.stopMembers(s.manager, r);
    s.stopOne();
}

/// `stop` for this session alone.
pub fn stopOne(s: *DebugSession) void {
    s.work.spawnLoop(stopWorker, .{ s, false }) catch {};
}

/// Stops this session alone and waits until it has ended. Off the UI
/// thread.
pub fn stopAndWait(s: *DebugSession) void {
    s.stopBlocking(false);
}

/// Disconnects, leaving the debuggee running (or suspended, when chosen
/// and supported).
pub fn detach(s: *DebugSession, suspend_debuggee: bool) void {
    s.work.spawnLoop(detachWorker, .{ s, suspend_debuggee }) catch {};
}

fn stopWorker(s: *DebugSession, restart_: bool) Io.Cancelable!void {
    s.stopBlocking(restart_);
}

fn detachWorker(s: *DebugSession, suspend_debuggee: bool) Io.Cancelable!void {
    if (s.stopping.swap(true, .acq_rel)) return;
    s.setState(.terminating);
    const sup = s.caps().supportSuspendDebuggee orelse false;
    const args = if (suspend_debuggee and sup) "{\"restart\":false,\"terminateDebuggee\":false,\"suspendDebuggee\":true}" else "{\"restart\":false,\"terminateDebuggee\":false}";
    switch (s.call("disconnect", args, s.manager.cfg.timeouts.stop_grace)) {
        .ok, .failed => |o| o.deinit(),
        else => {},
    }
    s.teardown();
    s.endSession(false);
}

fn stopBlocking(s: *DebugSession, restart_: bool) void {
    if (s.stopping.swap(true, .acq_rel)) {
        // A stop or finisher is already running: wait for it.
        s.ended_event.waitUncancelable(s.io);
        return;
    }
    s.prompt_answer = .abort;
    s.prompt_event.set(s.io);
    child_sessions.stopChildren(s);
    if (s.torn_down.load(.acquire)) {
        s.endSession(false);
        return;
    }
    s.setState(.terminating);
    const grace = s.manager.cfg.timeouts.stop_grace;
    if (s.cfg.request == .launch) {
        if (!s.terminated_event.isSet() and (s.caps().supportsTerminateRequest orelse false)) {
            _ = s.send("terminate", if (restart_) "{\"restart\":true}" else null, null);
            s.terminated_event.waitTimeout(s.io, .{ .duration = .{ .raw = grace, .clock = .awake } }) catch {};
        }
        const args = if (restart_) "{\"restart\":true,\"terminateDebuggee\":true}" else "{\"restart\":false,\"terminateDebuggee\":true}";
        switch (s.call("disconnect", args, grace)) {
            .ok, .failed => |o| o.deinit(),
            else => {},
        }
    } else {
        switch (s.call("disconnect", "{\"restart\":false,\"terminateDebuggee\":false}", grace)) {
            .ok, .failed => |o| o.deinit(),
            else => {},
        }
    }
    s.teardown();
    s.endSession(false);
}

/// Restarts: the adapter's `restart` when supported, else stop and start
/// again (passing `__restart`). A member of a `stopAll` compound restarts
/// every member.
pub fn restart(s: *DebugSession) void {
    if (s.opts.compound) |r| if (r.stop_all) return compounds.restartMembers(s.manager, r);
    s.restartOne();
}

/// `restart` for this session alone.
pub fn restartOne(s: *DebugSession) void {
    s.work.spawnLoop(restartWorker, .{s}) catch {};
}

fn restartWorker(s: *DebugSession) Io.Cancelable!void {
    const st = s.state();
    const native = (s.caps().supportsRestartRequest orelse false) and !s.torn_down.load(.acquire) and st != .terminated and st != .failed;
    if (native) {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var args: Value = .{ .object = s.cfg.args };
        if (s.opts.start_request_override) |o| args = o;
        args = copyValue(a, args) catch return;
        if (s.manager.cfg.vars) |vars| variables.substituteValue(a, &args, vars, s.opts.inputs) catch {};
        const body = std.fmt.allocPrint(a, "{{\"arguments\":{s}}}", .{jsonText(a, args) catch "{}"}) catch return;
        s.mutex.lockUncancelable(s.io);
        s.table.clear();
        s.generation_ += 1;
        s.step_in_flight = false;
        s.queued_step = null;
        s.mutex.unlock(s.io);
        s.notify(.threads);
        switch (s.call("restart", body, null)) {
            .ok => |o| o.deinit(),
            .failed => |o| {
                defer o.deinit();
                s.fail("restart failed: {s}", .{o.errorText()}, null);
            },
            else => {},
        }
        return;
    }
    // Emulated: stop, then start again.
    s.restarting = true;
    defer s.restarting = false;
    if (!s.ended_event.isSet()) s.stopBlocking(true);
    s.freeAdapter();
    s.mutex.lockUncancelable(s.io);
    s.table.clear();
    s.generation_ += 1;
    s.failure = null;
    s.exit_code_ = null;
    s.initialized_count = 0;
    s.process_ = null;
    s.mutex.unlock(s.io);
    s.notify(.threads);
    try s.run();
}
