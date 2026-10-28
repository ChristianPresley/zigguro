//! Debug sessions against `fake_dap_adapter` scripts
//! (testdata/sessions/): the start choreography, events, threads and
//! focus, stepping, stop escalation, detach, restart, pre-launch tasks and
//! the console. The thread table's rules are also tested on their own.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const DebugManager = @import("DebugManager.zig");
const DebugSession = @import("DebugSession.zig");
const threads = @import("threads.zig");
const console_events = @import("console_events.zig");
const LaunchConfig = @import("../config/LaunchConfig.zig");
const TaskList = @import("../tasks/TaskList.zig");
const TaskRunner = @import("../tasks/TaskRunner.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Io = std.Io;
const fake = test_exes.fake_dap_adapter;

/// Counts what listeners hear.
const Log = struct {
    mutex: Io.Mutex = .init,
    counts: [@typeInfo(DebugSession.Change).@"enum".fields.len]u32 = @splat(0),
    states: std.ArrayList(DebugSession.SessionState) = .empty,
    changed: Io.Event = .unset,

    fn on(ctx: ?*anyopaque, s: *DebugSession, change: DebugSession.Change) void {
        const l: *Log = @ptrCast(@alignCast(ctx.?));
        const st = if (change == .state) s.state() else null;
        l.mutex.lockUncancelable(testing.io);
        defer l.mutex.unlock(testing.io);
        l.counts[@intFromEnum(change)] += 1;
        if (st) |x| l.states.append(gpa, x) catch {};
        l.changed.set(testing.io);
    }

    fn count(l: *Log, change: DebugSession.Change) u32 {
        l.mutex.lockUncancelable(testing.io);
        defer l.mutex.unlock(testing.io);
        return l.counts[@intFromEnum(change)];
    }

    fn sawState(l: *Log, st: DebugSession.SessionState) bool {
        l.mutex.lockUncancelable(testing.io);
        defer l.mutex.unlock(testing.io);
        return std.mem.indexOfScalar(DebugSession.SessionState, l.states.items, st) != null;
    }
};

/// The breakpoint manager stand-in.
const Bps = struct {
    calls: std.atomic.Value(u32) = .init(0),
    initialized_first: std.atomic.Value(bool) = .init(true),
    temp_set: std.atomic.Value(u32) = .init(0),
    temp_cleared: std.atomic.Value(u32) = .init(0),

    fn sink(b: *Bps) DebugManager.BreakpointSink {
        return .{ .ctx = b, .sendAll = sendAll, .setTemp = setTemp, .clearTemp = clearTemp };
    }

    fn sendAll(ctx: ?*anyopaque, s: *DebugSession) void {
        const b: *Bps = @ptrCast(@alignCast(ctx.?));
        if (!s.initialized_event.isSet()) b.initialized_first.store(false, .release);
        _ = b.calls.fetchAdd(1, .acq_rel);
    }

    fn setTemp(ctx: ?*anyopaque, _: *DebugSession, _: DebugSession.SourceRef, _: u32) bool {
        const b: *Bps = @ptrCast(@alignCast(ctx.?));
        _ = b.temp_set.fetchAdd(1, .acq_rel);
        return true;
    }

    fn clearTemp(ctx: ?*anyopaque, _: *DebugSession) void {
        const b: *Bps = @ptrCast(@alignCast(ctx.?));
        _ = b.temp_cleared.fetchAdd(1, .acq_rel);
    }
};

const Harness = struct {
    rt: zg_core.Runtime,
    m: DebugManager,
    scripts: []const []const u8,
    spawns: std.atomic.Value(u32) = .init(0),
    log: Log = .{},
    bps: Bps = .{},
    cfg_args: std.json.ObjectMap = .empty,
    arena: std.heap.ArenaAllocator,

    const Opts = struct {
        timeouts: DebugManager.Timeouts = .{ .stop_grace = .fromMilliseconds(500) },
        tasks: ?DebugManager.TaskHost = null,
    };

    fn init(h: *Harness, scripts: []const []const u8, o: Opts) !void {
        h.* = .{ .rt = undefined, .m = undefined, .scripts = scripts, .arena = .init(gpa) };
        h.rt.initTesting();
        h.m = .init(&h.rt, .{
            .resolver = .{ .ctx = h, .resolve = resolve },
            .tasks = o.tasks,
            .breakpoints = h.bps.sink(),
            .timeouts = o.timeouts,
            .conn = .{ .timeouts = .{ .launch = .fromSeconds(10) } },
        });
        try h.m.subscribe(.{ .ctx = &h.log, .func = Log.on });
    }

    fn deinit(h: *Harness) void {
        h.m.deinit();
        h.log.states.deinit(gpa);
        h.arena.deinit();
        _ = h.rt.deinit();
    }

    fn resolve(ctx: ?*anyopaque, a: std.mem.Allocator, _: *const LaunchConfig) anyerror!DebugManager.AdapterSpec {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        const n = h.spawns.fetchAdd(1, .acq_rel);
        const name = h.scripts[@min(n, h.scripts.len - 1)];
        const path = try std.fmt.allocPrint(a, "{s}/testdata/sessions/{s}", .{ options.package_root, name });
        return .{ .argv = try a.dupe([]const u8, &.{ fake, "--script", path, "--workspace", "/w" }), .adapter_id = "fake" };
    }

    fn config(h: *Harness, request: LaunchConfig.Request) !LaunchConfig {
        const a = h.arena.allocator();
        var args: std.json.ObjectMap = .empty;
        if (request == .launch) try args.put(a, "program", .{ .string = "/w/app" }) else try args.put(a, "pid", .{ .integer = 4242 });
        return .{ .name = "app", .type = "fake", .request = request, .args = args, .source = .zon };
    }

    fn start(h: *Harness, request: LaunchConfig.Request) !*DebugSession {
        const c = try h.config(request);
        return h.m.start(&c, .{});
    }

    /// Waits up to 10 s for `cond`.
    fn waitFor(h: *Harness, s: *DebugSession, comptime cond: fn (*Harness, *DebugSession) bool) !void {
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

    fn dumpStderr(_: *Harness, s: *DebugSession) void {
        const p = s.proc orelse return;
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(gpa);
        p.stderrTail(&tail, 20) catch return;
        std.debug.print("fake adapter stderr:\n{s}\n", .{tail.items});
    }

    fn ended(_: *Harness, s: *DebugSession) bool {
        return s.ended_event.isSet();
    }

    /// The fake's exit: 0 when the client followed the script.
    fn expectScriptPassed(h: *Harness, s: *DebugSession) !void {
        const term = s.proc.?.exitStatus() orelse return error.NotExited;
        if (term != .exited or term.exited != 0) {
            h.dumpStderr(s);
            std.debug.print("fake adapter ended with {any}\n", .{term});
            return error.ScriptFailed;
        }
    }
};

const skip_windows = builtin.os.tag == .windows;

test "session: init order golden" {
    var h: Harness = undefined;
    try h.init(&.{"init_order.txt"}, .{});
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, Harness.ended);
    try h.expectScriptPassed(s);
    try testing.expectEqual(.terminated, s.state());
    try testing.expectEqual(@as(?[]u8, null), try s.failureMessage(gpa));
    // Breakpoints went out once, after initialized.
    try testing.expectEqual(@as(u32, 1), h.bps.calls.load(.acquire));
    try testing.expect(h.bps.initialized_first.load(.acquire));
    try testing.expect(h.log.sawState(.configuring));
    try testing.expect(h.log.sawState(.terminating));
    // The model events.
    try testing.expectEqual(@as(?i64, 3), s.exitCode());
    try testing.expectEqual(@as(?i64, 4242), s.process().?.pid);
    try testing.expectEqualStrings("app", s.process().?.name);
    try testing.expectEqual(@as(usize, 1), s.modulesCount());
    try testing.expectEqual(@as(usize, 1), s.loadedSourcesCount());
    try testing.expectEqual(@as(usize, 1), s.progressCount());
    // Capabilities: from initialize, merged with the event.
    const c = s.caps();
    try testing.expect(c.supportsConfigurationDoneRequest.?);
    try testing.expect(c.supportsStepBack.?);
}

test "session: initialized timeout -> failed" {
    var h: Harness = undefined;
    try h.init(&.{"initialized_timeout.txt"}, .{ .timeouts = .{ .initialized = .fromMilliseconds(200), .stop_grace = .fromMilliseconds(200) } });
    defer h.deinit();
    const t0 = Io.Timestamp.now(testing.io, .awake);
    const s = try h.start(.launch);
    try h.waitFor(s, Harness.ended);
    try testing.expectEqual(.failed, s.state());
    const msg = (try s.failureMessage(gpa)).?;
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "initialized") != null);
    // The sleeping adapter was killed rather than waited for.
    try testing.expect(t0.durationTo(Io.Timestamp.now(testing.io, .awake)).toMilliseconds() < 5000);
    try testing.expectEqual(@as(u32, 0), h.bps.calls.load(.acquire));
}

test "session: launch failure shows the adapter's message and link" {
    var h: Harness = undefined;
    try h.init(&.{"launch_failed.txt"}, .{});
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, Harness.ended);
    try testing.expectEqual(.failed, s.state());
    const msg = (try s.failureMessage(gpa)).?;
    defer gpa.free(msg);
    try testing.expectEqualStrings("launch failed: program not found: /w/app", msg);
    try testing.expectEqualStrings("https://example.com/help", s.failure_url.?);
}

fn stack1(_: *Harness, s: *DebugSession) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const top = (s.topFrame(arena.allocator()) catch return false) orelse return false;
    return top.frame.id == 1000 and top.scopes.len == 2;
}

fn stack2(_: *Harness, s: *DebugSession) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const top = (s.topFrame(arena.allocator()) catch return false) orelse return false;
    return top.frame.id == 2000 and s.state() == .stopped;
}

test "session: stopped allThreadsStopped and focus rules" {
    var h: Harness = undefined;
    try h.init(&.{"stop_focus.txt"}, .{});
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, stack1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const ts = try s.threads(a);
        try testing.expectEqual(@as(usize, 2), ts.len);
        try testing.expectEqualStrings("main", ts[0].name);
        // allThreadsStopped: the worker listed afterwards is stopped too.
        for (ts) |t| {
            try testing.expect(t.stopped);
            try testing.expectEqualStrings("breakpoint", t.stop_reason.?.reason);
        }
        try testing.expectEqualSlices(i64, &.{4}, ts[0].stop_reason.?.hit_breakpoint_ids);
        try testing.expectEqual(@as(?i64, 1), s.currentThread());
        try testing.expectEqual(.stopped, s.state());
        const top = (try s.topFrame(a)).?;
        try testing.expectEqualStrings("/w/src/main.zig", top.frame.path.?);
        try testing.expectEqual(@as(u32, 5), top.frame.line);
        try testing.expectEqualStrings("Locals", top.scopes[0].name);
        try testing.expect(top.scopes[1].expensive);
    }
    const gen = s.generation();
    s.continue_(null);
    try testing.expect(s.generation() > gen);
    // The next stop keeps the focus (preserveFocusHint) on thread 1.
    try h.waitFor(s, stack2);
    {
        const ts = try s.threads(a);
        try testing.expectEqual(@as(?i64, 1), s.currentThread());
        try testing.expect(!ts[0].stopped);
        try testing.expect(ts[1].stopped);
        try testing.expectEqualStrings("panic", ts[1].stop_reason.?.text.?);
    }
    // Only thread 1 continues (allThreadsContinued: false), then a
    // `continued` event without the flag resumes everything.
    s.continue_(null);
    s.pause(1);
    try h.waitFor(s, Harness.ended);
    try h.expectScriptPassed(s);
}

fn stoppedAfterSteps(h: *Harness, s: *DebugSession) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const top = (s.topFrame(arena.allocator()) catch return false) orelse return false;
    return top.frame.id == 3 and h.log.count(.stack) >= 2;
}

fn firstStop(_: *Harness, s: *DebugSession) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const top = (s.topFrame(arena.allocator()) catch return false) orelse return false;
    return top.frame.id == 1;
}

fn stoppedAgain(_: *Harness, s: *DebugSession) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ts = s.threads(arena.allocator()) catch return false;
    return ts.len == 1 and ts[0].stopped and s.state() == .stopped;
}

test "session: step coalescing" {
    var h: Harness = undefined;
    try h.init(&.{"step_coalesce.txt"}, .{});
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, firstStop);
    // Three presses while the first step runs: one more is kept.
    s.step(.over, 1, .line);
    s.step(.over, 1, .line);
    s.step(.over, 1, .line);
    try h.waitFor(s, stoppedAfterSteps);
    // A refused step puts the thread back to stopped.
    s.step(.into, 1, .line);
    try h.waitFor(s, stoppedAgain);
    // stepBack is not supported by this adapter: nothing is sent.
    s.step(.back, 1, .line);
    try h.waitFor(s, Harness.ended);
    try h.expectScriptPassed(s);
}

test "session: terminate then disconnect escalation" {
    if (skip_windows) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(&.{"stop_escalation.txt"}, .{ .timeouts = .{ .stop_grace = .fromMilliseconds(150) } });
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, running);
    const t0 = Io.Timestamp.now(testing.io, .awake);
    s.stop();
    try h.waitFor(s, Harness.ended);
    const ms = t0.durationTo(Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    // Three grace periods (terminate, disconnect, kill), not the
    // adapter's 20 s sleep.
    try testing.expect(ms >= 300);
    try testing.expect(ms < 5000);
    try testing.expectEqual(.terminated, s.state());
    // Killed, not a clean exit.
    const term = s.proc.?.exitStatus().?;
    try testing.expect(!(term == .exited and term.exited == 0));
}

fn running(_: *Harness, s: *DebugSession) bool {
    return s.state() == .running;
}

test "session: attach disconnect leaves debuggee" {
    var h: Harness = undefined;
    try h.init(&.{"attach_detach.txt"}, .{});
    defer h.deinit();
    const s = try h.start(.attach);
    try h.waitFor(s, running);
    s.stop();
    try h.waitFor(s, Harness.ended);
    try h.expectScriptPassed(s);
    try testing.expectEqual(.terminated, s.state());
}

fn twoConfigs(h: *Harness, _: *DebugSession) bool {
    return h.bps.calls.load(.acquire) >= 2;
}

test "session: restart native and emulated with __restart" {
    {
        var h: Harness = undefined;
        try h.init(&.{"restart_native.txt"}, .{});
        defer h.deinit();
        const s = try h.start(.launch);
        try h.waitFor(s, running);
        s.restart();
        // The breakpoints are sent again after the new initialized.
        try h.waitFor(s, twoConfigs);
        try h.waitFor(s, Harness.ended);
        try h.expectScriptPassed(s);
        try testing.expectEqual(@as(u32, 1), h.spawns.load(.acquire));
    }
    {
        var h: Harness = undefined;
        try h.init(&.{ "restart_emulated_1.txt", "restart_emulated_2.txt" }, .{});
        defer h.deinit();
        const s = try h.start(.launch);
        try h.waitFor(s, Harness.ended);
        try h.expectScriptPassed(s);
        try testing.expectEqualStrings("{\"token\":42}", s.restart_data.?);
        s.restart();
        try h.waitFor(s, twoConfigs);
        try h.waitFor(s, Harness.ended);
        try h.expectScriptPassed(s);
        try testing.expectEqual(@as(u32, 2), h.spawns.load(.acquire));
        try testing.expectEqual(.terminated, s.state());
    }
}

/// A task host that fails `build` and records what ran.
const Tasks = struct {
    mutex: Io.Mutex = .init,
    ran: std.ArrayList(u8) = .empty,

    fn host(t: *Tasks) DebugManager.TaskHost {
        return .{ .ctx = t, .run = run };
    }

    fn run(ctx: ?*anyopaque, label: []const u8, _: std.mem.Allocator) DebugManager.TaskOutcome {
        const t: *Tasks = @ptrCast(@alignCast(ctx.?));
        t.mutex.lockUncancelable(testing.io);
        defer t.mutex.unlock(testing.io);
        t.ran.appendSlice(gpa, label) catch {};
        t.ran.append(gpa, ';') catch {};
        if (std.mem.eql(u8, label, "build")) return .{ .failed = "exit code 1" };
        return .ok;
    }
};

fn prompted(_: *Harness, s: *DebugSession) bool {
    return s.prompt() != null;
}

test "session: preLaunchTask failure prompt model" {
    var tasks: Tasks = .{};
    defer tasks.ran.deinit(gpa);
    var h: Harness = undefined;
    try h.init(&.{"pre_launch.txt"}, .{ .tasks = tasks.host() });
    defer h.deinit();
    var c = try h.config(.launch);
    c.pre_launch_task = "build";
    c.post_debug_task = "cleanup";

    // Abort: the session fails and no adapter starts.
    const s1 = try h.m.start(&c, .{});
    try h.waitFor(s1, prompted);
    const p = s1.prompt().?;
    try testing.expectEqual(.pre_launch_task_failed, p.kind);
    try testing.expectEqualStrings("build", p.task);
    try testing.expectEqualStrings("exit code 1", p.message);
    s1.answerPrompt(.abort);
    try h.waitFor(s1, Harness.ended);
    try testing.expectEqual(.failed, s1.state());
    try testing.expectEqual(@as(u32, 0), h.spawns.load(.acquire));

    // Debug Anyway: it starts, and the post-debug task runs at the end.
    const s2 = try h.m.start(&c, .{});
    try h.waitFor(s2, prompted);
    s2.answerPrompt(.debug_anyway);
    try h.waitFor(s2, Harness.ended);
    try h.expectScriptPassed(s2);
    try testing.expectEqualStrings("build;build;cleanup;", tasks.ran.items);
}

test "session: background preLaunchTask is ready at its end pattern" {
    if (skip_windows) return error.SkipZigTest;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, test_exes.fake_task, gpa);
    defer gpa.free(exe);
    const zon = try std.fmt.allocPrint(gpa,
        \\.{{ .tasks = .{{
        \\    .{{ .label = "watch", .command = "{s}", .is_background = true, .problem_matcher = "$zig-watch",
        \\       .args = .{{ "--out", "watching", "--sleep-ms", "100", "--out", "Build Summary: 3/3 steps succeeded", "--sleep-ms", "60000" }} }},
        \\    .{{ .label = "fails", .command = "{s}", .args = .{{ "--exit", "2" }} }},
        \\}} }}
    , .{ exe, exe });
    defer gpa.free(zon);
    const z = try gpa.dupeZ(u8, zon);
    defer gpa.free(z);
    var list = try TaskList.fromSources(gpa, .{ .tasks_zon = z, .os = builtin.os.tag, .trusted = true });
    defer list.deinit();
    var runner: TaskRunner = .init(&rt, &list, .{ .root = "/tmp" });
    defer runner.deinit();
    var host: DebugManager.TaskRunnerHost = .{ .runner = &runner };
    const th = host.host();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const t0 = Io.Timestamp.now(testing.io, .awake);
    try testing.expectEqual(DebugManager.TaskOutcome.ok, th.run(th.ctx, "watch", arena.allocator()));
    // Ready after the first cycle, long before the task exits.
    try testing.expect(t0.durationTo(Io.Timestamp.now(testing.io, .awake)).toMilliseconds() < 30_000);
    const failed = th.run(th.ctx, "fails", arena.allocator());
    try testing.expectEqualStrings("\"fails\" exited with code 2", failed.failed);
    const missing = th.run(th.ctx, "nope", arena.allocator());
    try testing.expectEqualStrings("there is no task \"nope\"", missing.failed);
    for (runner.runs.items) |r| if (std.mem.eql(u8, r.label, "watch")) runner.terminate(r);
}

fn outputDone(_: *Harness, s: *DebugSession) bool {
    return s.ended_event.isSet();
}

test "session: output categories routed" {
    var h: Harness = undefined;
    try h.init(&.{"output.txt"}, .{});
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, outputDone);
    try h.expectScriptPassed(s);
    const Check = struct {
        fn run(_: void, c: *const console_events.Console) void {
            check(c) catch |e| std.debug.panic("console check failed: {t}", .{e});
        }
        fn check(c: *const console_events.Console) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            try testing.expectEqualStrings("out 1\ninside\nout 2\n", try c.text(a, .stdout));
            try testing.expectEqualStrings("err 1\n", try c.text(a, .stderr));
            try testing.expectEqualStrings("no category\nconsole\ngroup\n", try c.text(a, .console));
            try testing.expectEqualStrings("important\n", try c.text(a, .important));
            try testing.expectEqual(@as(u64, 1), c.telemetry_dropped);
            for (c.entries.items) |e| {
                if (std.mem.eql(u8, e.text, "inside\n")) {
                    try testing.expectEqual(@as(u16, 1), e.depth);
                    try testing.expectEqual(@as(?i64, 12), e.variables_reference);
                }
                if (std.mem.eql(u8, e.text, "out 2\n")) try testing.expectEqual(@as(u16, 0), e.depth);
                if (std.mem.eql(u8, e.text, "err 1\n")) {
                    try testing.expectEqualStrings("/w/src/main.zig", e.source_path.?);
                    try testing.expectEqual(@as(?u32, 4), e.line);
                }
            }
        }
    };
    s.withConsole({}, Check.run);
}

test "threads: stopped, continued and thread events" {
    var t: threads.Table = .init(gpa);
    defer t.deinit();
    try t.applyThreads(&.{ .{ .id = 1, .name = "main" }, .{ .id = 2, .name = "worker" } });
    // A single-thread stop focuses it.
    try t.applyStopped(.{ .reason = "breakpoint", .thread_id = 2 });
    try testing.expectEqual(@as(?i64, 2), t.current);
    try testing.expect(!t.find(1).?.stopped);
    try testing.expect(t.find(2).?.stopped);
    // preserveFocusHint keeps the focus.
    try t.applyStopped(.{ .reason = "pause", .thread_id = 1, .preserve_focus = true });
    try testing.expectEqual(@as(?i64, 2), t.current);
    // `continued` without allThreadsContinued resumes every thread.
    t.applyContinued(1, true);
    try testing.expect(!t.anyStopped());
    // allThreadsStopped: every thread, and threads that start later.
    try t.applyStopped(.{ .reason = "exception", .thread_id = 1, .all_threads_stopped = true });
    try testing.expectEqual(@as(?i64, 1), t.current);
    try testing.expect(t.find(2).?.stopped);
    try t.applyThreadEvent(3, "started");
    try testing.expect(t.find(3).?.stopped);
    try testing.expectEqualStrings("Thread 3", t.find(3).?.name);
    // Only one thread continues.
    t.applyContinued(1, false);
    try testing.expect(!t.find(1).?.stopped);
    try testing.expect(t.find(2).?.stopped);
    // The focused thread exits: the focus moves to a stopped one.
    try t.applyThreadEvent(1, "exited");
    try testing.expectEqual(@as(?i64, 2), t.current);
    // A stop without a thread id focuses the first stopped thread only
    // when nothing has the focus.
    t.current = null;
    try t.applyStopped(.{ .reason = "pause", .all_threads_stopped = true });
    try testing.expectEqual(@as(?i64, 2), t.current);
}
