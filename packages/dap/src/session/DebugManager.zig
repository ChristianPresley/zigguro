//! The debug sessions of a workspace (E07.F06.S02.T01): starts them,
//! keeps the active one, and fans their changes out to listeners (the
//! app's mailbox and the agent tools).
//!
//! What a session needs from outside comes through `Config`: how to start
//! an adapter (`AdapterResolver`, normally `RegistryResolver` over the
//! adapter registry), how to run pre-launch and post-debug tasks
//! (`TaskHost`, normally `TaskRunnerHost`), the breakpoint manager
//! (`BreakpointSink`, E07.F06.S03.T01) and where `runInTerminal` starts
//! debuggees (`TerminalLauncher`). Compounds start through
//! `startCompound`. Listeners are called on the
//! connection's dispatcher or a session worker; post to the UI from them
//! and coalesce per frame.

const DebugManager = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const DebugSession = @import("DebugSession.zig");
const DapConnection = @import("../conn/DapConnection.zig");
const LaunchConfig = @import("../config/LaunchConfig.zig");
const variables = @import("../config/variables.zig");
const Registry = @import("../adapters/Registry.zig");
const TaskRunner = @import("../tasks/TaskRunner.zig");
const ConfigSet = @import("../config/ConfigSet.zig");
const run_in_terminal = @import("run_in_terminal.zig");
const compounds_mod = @import("compounds.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ServerProcess = zg_lsp.client.ServerProcess;

pub const StartOptions = DebugSession.StartOptions;
pub const Change = DebugSession.Change;
pub const TerminalLauncher = run_in_terminal.TerminalLauncher;
pub const RunInTerminalSpec = run_in_terminal.RunInTerminalSpec;
pub const CompoundRun = compounds_mod.CompoundRun;
pub const CompoundStart = compounds_mod.StartResult;

/// How to start the adapter for a configuration.
pub const AdapterSpec = struct {
    argv: []const []const u8 = &.{},
    transport: ServerProcess.TransportKind = .stdio,
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    /// `initialize`'s `adapterID`.
    adapter_id: []const u8,
    /// Set when the adapter cannot start (missing, too old): the session
    /// fails with it.
    message: ?[]const u8 = null,
    /// Rewrites the launch/attach arguments for the adapter.
    normalize: ?*const fn (a: Allocator, request: LaunchConfig.Request, args: *std.json.ObjectMap) anyerror!void = null,
};

pub const AdapterResolver = struct {
    ctx: ?*anyopaque,
    /// Allocations in `arena` (valid until the session's adapter starts).
    /// Runs on a session worker.
    resolve: *const fn (ctx: ?*anyopaque, arena: Allocator, cfg: *const LaunchConfig) anyerror!AdapterSpec,
};

pub const TaskOutcome = union(enum) {
    ok,
    /// Why (shown in the prompt).
    failed: []const u8,
};

/// Runs a task to completion (or, for a background task, until its
/// problem matcher's first `endsPattern`). Runs on a session worker.
pub const TaskHost = struct {
    ctx: ?*anyopaque,
    run: *const fn (ctx: ?*anyopaque, label: []const u8, arena: Allocator) TaskOutcome,
};

/// The breakpoint manager, as sessions use it.
pub const BreakpointSink = struct {
    ctx: ?*anyopaque,
    /// Sends every breakpoint to `s` and waits for the answers. Runs on a
    /// session worker after `initialized`.
    sendAll: *const fn (ctx: ?*anyopaque, s: *DebugSession) void,
    /// A `breakpoint` event body (JSON text, valid during the call), on
    /// the dispatcher.
    onEvent: ?*const fn (ctx: ?*anyopaque, s: *DebugSession, body: []const u8) void = null,
    /// Sets the hidden breakpoint of "Run to Line"; false if it cannot.
    setTemp: ?*const fn (ctx: ?*anyopaque, s: *DebugSession, src: DebugSession.SourceRef, line: u32) bool = null,
    /// Removes it (on the next stop, from the dispatcher).
    clearTemp: ?*const fn (ctx: ?*anyopaque, s: *DebugSession) void = null,
    /// The session ended (or failed to start), on a session worker: drop
    /// what is kept for it.
    onEnd: ?*const fn (ctx: ?*anyopaque, s: *DebugSession) void = null,
};

pub const Timeouts = struct {
    /// From the launch/attach request to the `initialized` event.
    initialized: Io.Duration = .fromSeconds(10),
    /// Each stop stage: `terminate` → `disconnect` → killing the adapter.
    stop_grace: Io.Duration = .fromSeconds(2),
};

pub const Config = struct {
    resolver: AdapterResolver,
    tasks: ?TaskHost = null,
    breakpoints: ?BreakpointSink = null,
    /// Where `runInTerminal` starts debuggees (refused without one).
    terminal: ?TerminalLauncher = null,
    /// The workspace is trusted (E16): `runInTerminal` is refused
    /// otherwise.
    trusted: bool = true,
    /// Substitutes `${...}` in configurations when set.
    vars: ?*const variables.VarContext = null,
    policy: ?*const ServerProcess.SpawnPolicy = null,
    conn: DapConnection.Options = .{},
    timeouts: Timeouts = .{},
    locale: ?[]const u8 = null,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, s: *DebugSession, change: Change) void,
};

rt: *zg_core.Runtime,
gpa: Allocator,
cfg: Config,
mutex: Io.Mutex = .init,
list: std.ArrayList(*DebugSession) = .empty,
listeners: std.ArrayList(Listener) = .empty,
active_: ?*DebugSession = null,
next_id: u32 = 1,
compounds: std.ArrayList(*CompoundRun) = .empty,
/// The fallback from an external to the integrated terminal was logged.
external_fallback_logged: std.atomic.Value(bool) = .init(false),

pub fn init(rt: *zg_core.Runtime, cfg: Config) DebugManager {
    return .{ .rt = rt, .gpa = rt.gpa, .cfg = cfg };
}

/// Stops every session and frees them. Off the UI thread: stopping
/// waits for adapters.
pub fn deinit(m: *DebugManager) void {
    // Children first: they belong to their parents' adapters.
    var i = m.list.items.len;
    while (i > 0) {
        i -= 1;
        m.list.items[i].deinit();
    }
    m.list.deinit(m.gpa);
    for (m.compounds.items) |r| r.deinit(m.gpa);
    m.compounds.deinit(m.gpa);
    m.listeners.deinit(m.gpa);
    m.* = undefined;
}

pub fn subscribe(m: *DebugManager, l: Listener) Allocator.Error!void {
    m.mutex.lockUncancelable(m.rt.io);
    defer m.mutex.unlock(m.rt.io);
    try m.listeners.append(m.gpa, l);
}

pub fn notify(m: *DebugManager, s: *DebugSession, change: Change) void {
    var copy: [16]Listener = undefined;
    m.mutex.lockUncancelable(m.rt.io);
    const n = @min(copy.len, m.listeners.items.len);
    @memcpy(copy[0..n], m.listeners.items[0..n]);
    m.mutex.unlock(m.rt.io);
    for (copy[0..n]) |l| l.func(l.ctx, s, change);
}

/// Starts a session for `cfg` and returns it at once; the start sequence
/// runs on the session's worker (watch its state through a listener).
pub fn start(m: *DebugManager, cfg: *const LaunchConfig, opts: StartOptions) !*DebugSession {
    m.mutex.lockUncancelable(m.rt.io);
    const id = m.next_id;
    m.next_id += 1;
    m.mutex.unlock(m.rt.io);
    const s = try DebugSession.create(m, id, cfg, opts);
    errdefer s.deinit();
    {
        m.mutex.lockUncancelable(m.rt.io);
        defer m.mutex.unlock(m.rt.io);
        try m.list.ensureUnusedCapacity(m.gpa, 1);
        if (opts.compound) |r| try r.members.ensureUnusedCapacity(m.gpa, 1);
        if (opts.parent) |p| try p.children_.append(m.gpa, s);
        if (opts.compound) |r| r.members.appendAssumeCapacity(s);
        m.list.appendAssumeCapacity(s);
        m.active_ = s;
    }
    try s.work.spawnLoop(DebugSession.run, .{s});
    return s;
}

/// The sessions, oldest first. Read on the thread that starts and
/// removes sessions.
pub fn sessions(m: *const DebugManager) []const *DebugSession {
    return m.list.items;
}

pub fn active(m: *DebugManager) ?*DebugSession {
    m.mutex.lockUncancelable(m.rt.io);
    defer m.mutex.unlock(m.rt.io);
    return m.active_;
}

pub fn setActive(m: *DebugManager, s: ?*DebugSession) void {
    m.mutex.lockUncancelable(m.rt.io);
    defer m.mutex.unlock(m.rt.io);
    m.active_ = s;
}

/// Stops (if needed) and frees `s` and its children. Off the UI thread.
pub fn remove(m: *DebugManager, s: *DebugSession) void {
    for (s.children_.items) |c| m.remove(c);
    s.children_.clearRetainingCapacity();
    {
        m.mutex.lockUncancelable(m.rt.io);
        defer m.mutex.unlock(m.rt.io);
        for (m.list.items, 0..) |x, i| if (x == s) {
            _ = m.list.orderedRemove(i);
            break;
        };
        if (m.active_ == s) m.active_ = if (m.list.items.len > 0) m.list.items[m.list.items.len - 1] else null;
        for (m.list.items) |p| for (p.children_.items, 0..) |c, i| if (c == s) {
            _ = p.children_.orderedRemove(i);
            break;
        };
        if (s.opts.compound) |r| for (r.members.items, 0..) |x, i| if (x == s) {
            _ = r.members.orderedRemove(i);
            break;
        };
    }
    s.deinit();
}

/// Starts the configurations of compound `c` (see compounds.zig). Off the
/// UI thread.
pub fn startCompound(m: *DebugManager, c: *const ConfigSet.Compound, set: *const ConfigSet, arena: Allocator) Allocator.Error!CompoundStart {
    return compounds_mod.startCompound(m, c, set, arena);
}

/// Starts adapters through the adapter registry.
pub const RegistryResolver = struct {
    reg: *Registry,
    io: Io,
    env: *const std.process.Environ.Map,

    pub fn resolver(r: *RegistryResolver) AdapterResolver {
        return .{ .ctx = r, .resolve = resolve };
    }

    fn resolve(ctx: ?*anyopaque, a: Allocator, cfg: *const LaunchConfig) anyerror!AdapterSpec {
        const r: *RegistryResolver = @ptrCast(@alignCast(ctx.?));
        const def = r.reg.get(cfg.type) orelse return .{ .adapter_id = cfg.type, .message = try std.fmt.allocPrint(a, "No adapter for type \"{s}\"", .{cfg.type}) };
        const st = try r.reg.resolve(r.io, def, r.env);
        return switch (st) {
            .ok => |res| .{
                .argv = try dupeArgv(a, res.argv),
                .transport = switch (def.transport) {
                    .stdio => .stdio,
                    .tcp_listen_child => .tcp_listen_child,
                },
                .env = r.env,
                .adapter_id = def.type,
                .normalize = def.normalize,
            },
            else => .{ .adapter_id = def.type, .message = try st.message(a, def) },
        };
    }

    fn dupeArgv(a: Allocator, argv: []const []const u8) Allocator.Error![]const []const u8 {
        const out = try a.alloc([]const u8, argv.len);
        for (out, argv) |*o, s| o.* = try a.dupe(u8, s);
        return out;
    }
};

/// Runs tasks through a `TaskRunner`: waits for the exit (code 0 is
/// success) or, for a background task, for its first finished cycle.
pub const TaskRunnerHost = struct {
    runner: *TaskRunner,

    pub fn host(h: *TaskRunnerHost) TaskHost {
        return .{ .ctx = h, .run = run };
    }

    fn run(ctx: ?*anyopaque, label: []const u8, arena: Allocator) TaskOutcome {
        const h: *TaskRunnerHost = @ptrCast(@alignCast(ctx.?));
        const r = h.runner;
        if (r.list.byLabel(label) == null) return .{ .failed = std.fmt.allocPrint(arena, "there is no task \"{s}\"", .{label}) catch "no such task" };
        const tr = r.run(label, .{}) catch return .{ .failed = "out of memory" };
        if (tr.task.is_background) {
            r.waitBackgroundReady(tr);
            const st = r.status(tr);
            return switch (st.state) {
                .failed, .terminated => .{ .failed = describe(arena, label, st.exit_code) },
                else => .ok,
            };
        }
        const sum = r.wait(tr, arena) catch return .{ .failed = "out of memory" };
        if (sum.state == .succeeded) return .ok;
        return .{ .failed = sum.message orelse describe(arena, label, sum.exit_code) };
    }

    fn describe(a: Allocator, label: []const u8, code: ?u8) []const u8 {
        if (code) |c| return std.fmt.allocPrint(a, "\"{s}\" exited with code {d}", .{ label, c }) catch "the task failed";
        return std.fmt.allocPrint(a, "\"{s}\" did not finish", .{label}) catch "the task failed";
    }
};
