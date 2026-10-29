//! The debugger tools for the workbench's agents (E07.F05.S02.T01):
//! zg_dap's `debug_tools` over the debug service. The tools run on agent
//! workers; what touches the service runs on the UI thread through
//! `RunOnUi`, and the service is made on first use. Sessions the tools
//! read stay alive until the call ends (`Debug.agentAcquire`).

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_dap = @import("zg_dap");
const service = @import("service.zig");

const Allocator = std.mem.Allocator;
const Debug = service.Debug;
const DebugSession = zg_dap.session.DebugSession;
const BreakpointManager = zg_dap.breakpoints.BreakpointManager;
const debug_tools = zg_dap.agent.debug_tools;

pub const Exporter = debug_tools.ToolExporter(zg_ai.tools.adapters.foreign);

/// Runs `f(arg)` on the UI thread and waits; false when it could not.
pub const RunOnUi = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) bool,
};

/// The debug service, made when missing (UI thread; null: unavailable).
pub const Ensure = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque) ?*Debug,
};

pub const DebugAgentTools = struct {
    ui: RunOnUi,
    ensure: Ensure,
    /// The service once made (read on workers after a UI hop).
    debug: std.atomic.Value(?*Debug) = .init(null),
    x: Exporter = undefined,

    /// `t` must not move afterwards.
    pub fn init(t: *DebugAgentTools, io: std.Io, root: []const u8, ui: RunOnUi, ensure: Ensure) void {
        t.* = .{ .ui = ui, .ensure = ensure };
        t.x = .{ .host = .{
            .ctx = t,
            .configs = configs,
            .start = start,
            .acquire = acquire,
            .release = release,
            .breakpoints = breakpoints,
            .trusted = trusted,
            .root = root,
            .io = io,
        } };
    }

    pub fn exporter(t: *DebugAgentTools) zg_ai.tools.adapters.foreign.Exporter {
        return t.x.exporter();
    }

    fn self(ctx: *anyopaque) *DebugAgentTools {
        return @ptrCast(@alignCast(ctx));
    }

    /// Runs `f(debug, job)` on the UI thread; false without a service.
    fn onUi(t: *DebugAgentTools, comptime Job: type, job: *Job) bool {
        const Hop = struct {
            t: *DebugAgentTools,
            job: *Job,
            ok: bool = false,
            fn run(arg: *anyopaque) void {
                const h: *@This() = @ptrCast(@alignCast(arg));
                const d = h.t.ensure.get(h.t.ensure.ctx) orelse return;
                h.t.debug.store(d, .release);
                h.job.run(d);
                h.ok = true;
            }
        };
        var hop: Hop = .{ .t = t, .job = job };
        if (!t.ui.run(t.ui.ctx, Hop.run, &hop)) return false;
        return hop.ok;
    }

    fn configs(ctx: *anyopaque, arena: Allocator) anyerror![]const debug_tools.ConfigInfo {
        const Job = struct {
            arena: Allocator,
            out: anyerror![]const debug_tools.ConfigInfo = &.{},
            fn run(j: *@This(), d: *Debug) void {
                j.out = d.agentConfigs(j.arena);
            }
        };
        var job: Job = .{ .arena = arena };
        if (!self(ctx).onUi(Job, &job)) return error.DebuggerUnavailable;
        return job.out;
    }

    fn start(ctx: *anyopaque, name: []const u8) anyerror!*DebugSession {
        const Job = struct {
            name: []const u8,
            out: anyerror!*DebugSession = error.DebuggerUnavailable,
            fn run(j: *@This(), d: *Debug) void {
                j.out = d.agentStart(j.name);
            }
        };
        var job: Job = .{ .name = name };
        if (!self(ctx).onUi(Job, &job)) return error.DebuggerUnavailable;
        return job.out;
    }

    fn acquire(ctx: *anyopaque) ?*DebugSession {
        const Job = struct {
            out: ?*DebugSession = null,
            fn run(j: *@This(), d: *Debug) void {
                j.out = d.agentAcquire();
            }
        };
        var job: Job = .{};
        if (!self(ctx).onUi(Job, &job)) return null;
        return job.out;
    }

    fn release(ctx: *anyopaque, _: *DebugSession) void {
        const d = self(ctx).debug.load(.acquire) orelse return;
        d.agentRelease();
    }

    fn breakpoints(ctx: *anyopaque) ?*BreakpointManager {
        const Job = struct {
            out: ?*BreakpointManager = null,
            fn run(j: *@This(), d: *Debug) void {
                // Thread-safe; it lives as long as the service.
                j.out = &d.bps;
            }
        };
        var job: Job = .{};
        if (!self(ctx).onUi(Job, &job)) return null;
        return job.out;
    }

    fn trusted(ctx: *anyopaque) bool {
        const Job = struct {
            out: bool = false,
            fn run(j: *@This(), d: *Debug) void {
                j.out = d.trusted;
            }
        };
        var job: Job = .{};
        if (!self(ctx).onUi(Job, &job)) return false;
        return job.out;
    }
};
