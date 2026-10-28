//! The debug session tests' harness: a `DebugManager` whose resolver
//! starts `fake_dap_adapter` with scripts from testdata/sessions/, a
//! listener that counts changes, and a breakpoint manager stand-in.

const std = @import("std");
const zg_core = @import("zg_core");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const DebugManager = @import("DebugManager.zig");
const DebugSession = @import("DebugSession.zig");
const LaunchConfig = @import("../config/LaunchConfig.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Io = std.Io;
const fake = test_exes.fake_dap_adapter;

/// Counts what listeners hear.
pub const Log = struct {
    mutex: Io.Mutex = .init,
    counts: [@typeInfo(DebugSession.Change).@"enum".fields.len]u32 = @splat(0),
    states: std.ArrayList(DebugSession.SessionState) = .empty,
    changed: Io.Event = .unset,

    pub fn on(ctx: ?*anyopaque, s: *DebugSession, change: DebugSession.Change) void {
        const l: *Log = @ptrCast(@alignCast(ctx.?));
        const st = if (change == .state) s.state() else null;
        l.mutex.lockUncancelable(testing.io);
        defer l.mutex.unlock(testing.io);
        l.counts[@intFromEnum(change)] += 1;
        if (st) |x| l.states.append(gpa, x) catch {};
        l.changed.set(testing.io);
    }

    pub fn count(l: *Log, change: DebugSession.Change) u32 {
        l.mutex.lockUncancelable(testing.io);
        defer l.mutex.unlock(testing.io);
        return l.counts[@intFromEnum(change)];
    }

    pub fn sawState(l: *Log, st: DebugSession.SessionState) bool {
        l.mutex.lockUncancelable(testing.io);
        defer l.mutex.unlock(testing.io);
        return std.mem.indexOfScalar(DebugSession.SessionState, l.states.items, st) != null;
    }
};

/// The breakpoint manager stand-in.
pub const Bps = struct {
    calls: std.atomic.Value(u32) = .init(0),
    initialized_first: std.atomic.Value(bool) = .init(true),
    temp_set: std.atomic.Value(u32) = .init(0),
    temp_cleared: std.atomic.Value(u32) = .init(0),

    pub fn sink(b: *Bps) DebugManager.BreakpointSink {
        return .{ .ctx = b, .sendAll = sendAll, .setTemp = setTemp, .clearTemp = clearTemp };
    }

    pub fn sendAll(ctx: ?*anyopaque, s: *DebugSession) void {
        const b: *Bps = @ptrCast(@alignCast(ctx.?));
        if (!s.initialized_event.isSet()) b.initialized_first.store(false, .release);
        _ = b.calls.fetchAdd(1, .acq_rel);
    }

    pub fn setTemp(ctx: ?*anyopaque, _: *DebugSession, _: DebugSession.SourceRef, _: u32) bool {
        const b: *Bps = @ptrCast(@alignCast(ctx.?));
        _ = b.temp_set.fetchAdd(1, .acq_rel);
        return true;
    }

    pub fn clearTemp(ctx: ?*anyopaque, _: *DebugSession) void {
        const b: *Bps = @ptrCast(@alignCast(ctx.?));
        _ = b.temp_cleared.fetchAdd(1, .acq_rel);
    }
};

pub const Harness = struct {
    rt: zg_core.Runtime,
    m: DebugManager,
    scripts: []const []const u8,
    spawns: std.atomic.Value(u32) = .init(0),
    log: Log = .{},
    bps: Bps = .{},
    cfg_args: std.json.ObjectMap = .empty,
    arena: std.heap.ArenaAllocator,
    opts: Opts,

    pub const Opts = struct {
        timeouts: DebugManager.Timeouts = .{ .stop_grace = .fromMilliseconds(500) },
        tasks: ?DebugManager.TaskHost = null,
        terminal: ?DebugManager.TerminalLauncher = null,
        /// Instead of the stand-in.
        breakpoints: ?DebugManager.BreakpointSink = null,
        trusted: bool = true,
        /// `{configuration name, script}`: picked by name before the
        /// spawn order.
        named: []const [2][]const u8 = &.{},
        /// The first adapter listens on TCP and serves a second
        /// connection (a child session) with this script.
        tcp_child: ?[]const u8 = null,
    };

    pub fn init(h: *Harness, scripts: []const []const u8, o: Opts) !void {
        h.* = .{ .rt = undefined, .m = undefined, .scripts = scripts, .arena = .init(gpa), .opts = o };
        h.rt.initTesting();
        h.m = .init(&h.rt, .{
            .resolver = .{ .ctx = h, .resolve = resolve },
            .tasks = o.tasks,
            .breakpoints = o.breakpoints orelse h.bps.sink(),
            .terminal = o.terminal,
            .trusted = o.trusted,
            .timeouts = o.timeouts,
            .conn = .{ .timeouts = .{ .launch = .fromSeconds(10) } },
        });
        try h.m.subscribe(.{ .ctx = &h.log, .func = Log.on });
    }

    pub fn deinit(h: *Harness) void {
        h.m.deinit();
        h.log.states.deinit(gpa);
        h.arena.deinit();
        _ = h.rt.deinit();
    }

    fn scriptPath(a: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "{s}/testdata/sessions/{s}", .{ options.package_root, name });
    }

    pub fn resolve(ctx: ?*anyopaque, a: std.mem.Allocator, cfg: *const LaunchConfig) anyerror!DebugManager.AdapterSpec {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        const name = for (h.opts.named) |nm| {
            if (std.mem.eql(u8, nm[0], cfg.name)) break nm[1];
        } else blk: {
            const n = h.spawns.fetchAdd(1, .acq_rel);
            break :blk h.scripts[@min(n, h.scripts.len - 1)];
        };
        const path = try scriptPath(a, name);
        if (h.opts.tcp_child) |child| return .{
            .argv = try a.dupe([]const u8, &.{ fake, "--script", path, "--workspace", "/w", "--tcp", "{port}", "--child-script", try scriptPath(a, child) }),
            .transport = .tcp_listen_child,
            .adapter_id = "fake",
        };
        return .{ .argv = try a.dupe([]const u8, &.{ fake, "--script", path, "--workspace", "/w" }), .adapter_id = "fake" };
    }

    pub fn config(h: *Harness, request: LaunchConfig.Request) !LaunchConfig {
        return h.configNamed("app", request);
    }

    pub fn configNamed(h: *Harness, name: []const u8, request: LaunchConfig.Request) !LaunchConfig {
        const a = h.arena.allocator();
        var args: std.json.ObjectMap = .empty;
        if (request == .launch) try args.put(a, "program", .{ .string = "/w/app" }) else try args.put(a, "pid", .{ .integer = 4242 });
        return .{ .name = name, .type = "fake", .request = request, .args = args, .source = .zon };
    }

    pub fn start(h: *Harness, request: LaunchConfig.Request) !*DebugSession {
        const c = try h.config(request);
        return h.m.start(&c, .{});
    }

    /// Waits up to 10 s for `cond`.
    pub fn waitFor(h: *Harness, s: *DebugSession, comptime cond: fn (*Harness, *DebugSession) bool) !void {
        const deadline = Io.Timestamp.now(testing.io, .awake).addDuration(.fromSeconds(10));
        while (!cond(h, s)) {
            if (Io.Timestamp.now(testing.io, .awake).nanoseconds > deadline.nanoseconds) {
                std.debug.print("timed out; state {t}\n", .{s.state()});
                h.dumpStderr(s);
                return error.Timeout;
            }
            h.log.changed.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
            h.log.changed.reset();
        }
    }

    pub fn dumpStderr(_: *Harness, s: *DebugSession) void {
        const p = s.proc orelse return;
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(gpa);
        p.stderrTail(&tail, 20) catch return;
        std.debug.print("fake adapter stderr:\n{s}\n", .{tail.items});
    }

    pub fn ended(_: *Harness, s: *DebugSession) bool {
        return s.ended_event.isSet();
    }

    /// The fake's exit: 0 when the client followed the script.
    pub fn expectScriptPassed(h: *Harness, s: *DebugSession) !void {
        const term = s.proc.?.exitStatus() orelse return error.NotExited;
        if (term != .exited or term.exited != 0) {
            h.dumpStderr(s);
            std.debug.print("fake adapter ended with {any}\n", .{term});
            return error.ScriptFailed;
        }
    }
};
