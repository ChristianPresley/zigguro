//! Trace capture in the IDE (E14.F02.S01.T02): `--trace=<path>`,
//! `--trace-format=perfetto|chrome`, `ZG_TRACE=startup|<path>|startup:<path>`,
//! `ZG_OS_TRACE=ftrace|etw` and the `perf.trace.*` commands, on top of zg_perf's drain and
//! `TraceSession`; the frame timeline the Host feeds and the performance
//! HUD (`perf.hud.toggle`, E14.F03.S01.T02) and the latency probe square
//! (`perf.latencyProbe.toggle`, E14.F03.S02.T03).
//!
//! Start and the stop request are cheap on the UI thread; the final drain,
//! export and file write run on a worker, which posts a toast back.
//! `ZG_TRACE=startup` stops 2 s after the window opens (the first frame
//! follows within a frame or two) until the present-feedback hook of
//! E14.F05 lands.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_perf = @import("zg_perf");
const zg_gui = @import("zg_gui");
const zg_config = @import("zg_config");
const zg_perf_ui = @import("zg_perf_ui");

const session = zg_perf.trace.session;
const TraceSession = zg_perf.trace.TraceSession;
const log = std.log.scoped(.trace);

/// What the command line and environment asked for.
pub const Request = struct {
    /// Null: a timestamped file in the trace folder.
    path: ?[]const u8 = null,
    format: session.Format = .perfetto,
    startup: bool = false,
};

/// Parses `--trace=<path>`, `--trace-format=<fmt>` and `ZG_TRACE` (the
/// flags win). Null when neither asks for a trace. Slices point into
/// `args` and `zg_trace`.
pub fn parseRequest(args: []const []const u8, zg_trace: ?[]const u8) ?Request {
    var req: Request = .{};
    var want = false;
    if (zg_trace) |v| if (session.parseEnv(v)) |e| {
        want = true;
        req.startup = e.startup;
        req.path = e.path;
    };
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--trace=")) {
            want = true;
            const p = a["--trace=".len..];
            req.path = if (p.len == 0) null else p;
        } else if (std.mem.startsWith(u8, a, "--trace-format=")) {
            if (session.Format.parse(a["--trace-format=".len..])) |f| {
                req.format = f;
            } else log.warn("unknown --trace-format {s} (perfetto or chrome)", .{a["--trace-format=".len..]});
        }
    }
    return if (want) req else null;
}

/// The app's tracing state.
pub const Tracing = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    drain: zg_perf.trace.Drain,
    /// Guards `active` (commands on the UI thread, stops on workers).
    mutex: std.Io.Mutex = .init,
    active: ?*TraceSession = null,
    /// The trace folder (owned), or null when the environment names none.
    dir: ?[]u8 = null,
    format: session.Format = .perfetto,
    app: ?*zg_gui.App = null,
    group: std.Io.Group = .init,
    /// The last finished trace, for the toast (owned).
    last_path: ?[]u8 = null,
    last_summary: ?session.Summary = null,
    /// `ZG_OS_TRACE=ftrace|etw`: zones mirrored to the OS tracer.
    os: zg_perf.os.OsTrace = .{},
    /// Frame records from the Host (pass to `Host.Options.timeline`).
    timeline: ?*zg_perf.frame.FrameTimeline = null,
    hud: ?*zg_perf_ui.Hud = null,
    /// Dumps the last 10 s on slow frames and HUD bar clicks (builds with
    /// zones only, e.g. `-Dprofile=true`).
    recorder: ?*zg_perf.trace.FlightRecorder = null,
    /// The window `perf.hud.toggle` shows the HUD in.
    hud_win: ?*zg_gui.Window = null,
    /// The photodiode square (`perf.latencyProbe.toggle`), created on
    /// first use.
    probe: ?*zg_perf_ui.Probe = null,
    /// The memory sampler (E14.F04.S01.T02); its worker runs only while
    /// the HUD is visible or a report is asked for.
    mem: ?*zg_perf.mem.Sampler = null,
    /// Held while the HUD is visible.
    mem_obs: ?zg_perf.mem.Observation = null,
    /// The `--mem-report` task (cancelled at exit).
    mem_group: std.Io.Group = .init,

    /// Starts the drain; `env` gives the trace folder.
    pub fn init(t: *Tracing, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
        t.* = .{ .gpa = gpa, .io = io, .drain = .init(gpa, io) };
        t.dir = blk: {
            const d = session.defaultTraceDir(gpa, env, builtin.os.tag) catch break :blk null;
            break :blk @constCast(d orelse break :blk null);
        };
        t.drain.start();
        t.initFrames() catch |e| log.warn("frame timeline unavailable: {t}", .{e});
        if (env.get("ZG_OS_TRACE")) |v| {
            if (zg_perf.os.OsTrace.Kind.parse(v)) |kind| {
                t.os.init(kind, io);
                // The UI thread (this one); other threads opt in themselves.
                if (t.os.kind != .none) zg_perf.os.enableForCurrentThread();
            } else log.warn("unknown ZG_OS_TRACE {s} (ftrace, etw or off)", .{v});
        }
    }

    fn initFrames(t: *Tracing) !void {
        const tl = try t.gpa.create(zg_perf.frame.FrameTimeline);
        errdefer t.gpa.destroy(tl);
        tl.* = try .init(t.gpa, 1024);
        errdefer tl.deinit();
        t.mem = zg_perf.mem.Sampler.start(t.gpa, t.io, .{}) catch null;
        const hud = try zg_perf_ui.Hud.init(t.gpa, tl, .{ .sources = .{ .ctx = t, .memory = hudMemory } });
        t.hud = hud;
        t.timeline = tl;
        const dir = t.dir orelse return;
        const fr = zg_perf.trace.FlightRecorder.init(t.gpa, t.io, &t.drain, .{ .dir = dir }) catch |e| {
            log.warn("flight recorder unavailable: {t}", .{e});
            return;
        } orelse return;
        t.recorder = fr;
        tl.setSlowFrameHook(fr.slowFrameHook());
        hud.recorder = .flight(fr);
    }

    /// Hides the HUD; call before its window closes.
    pub fn detachWindow(t: *Tracing) void {
        if (t.hud) |h| if (t.hud_win) |w| h.setVisible(w, false);
        t.syncMemObservation();
        if (t.probe) |p| if (t.hud_win) |w| p.setVisible(w, false);
        t.hud_win = null;
    }

    /// Shows or hides the HUD in the main window.
    pub fn toggleHud(t: *Tracing) !void {
        const h = t.hud orelse return error.NoHud;
        h.toggle(t.hud_win orelse return error.NoWindow);
        t.syncMemObservation();
    }

    /// Keeps the sampler sampling exactly while the HUD is visible.
    fn syncMemObservation(t: *Tracing) void {
        const s = t.mem orelse return;
        const visible = if (t.hud) |h| h.isVisible() else false;
        if (visible and t.mem_obs == null) {
            t.mem_obs = s.observe();
        } else if (!visible) if (t.mem_obs) |o| {
            o.release();
            t.mem_obs = null;
        };
    }

    fn hudMemory(ctx: ?*anyopaque) ?zg_perf_ui.hud_model.Memory {
        const t: *Tracing = @ptrCast(@alignCast(ctx.?));
        const snap = (t.mem orelse return null).latest();
        const p = snap.process orelse return null;
        return .{ .private_bytes = p.private_bytes, .gpu_bytes = if (snap.gpu) |g| g.device_local_used else 0 };
    }

    /// Samples memory now and writes the report table to `w` (blocking:
    /// `--mem-report` and `perf.memory.report`).
    pub fn writeMemReport(t: *Tracing, w: *std.Io.Writer) !void {
        const s = t.mem orelse return error.NoSampler;
        s.sampleSync();
        try zg_perf.mem.writeReport(s.latest(), w);
    }

    /// `perf.memory.report`: the report on stdout and in a toast.
    fn memReport(t: *Tracing) !void {
        var buf: [4096]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&buf);
        try t.writeMemReport(&fw);
        printStdout(t.io, fw.buffered());
        if (t.app) |app| {
            var md: [4200]u8 = undefined;
            const body = std.fmt.bufPrint(&md, "```\n{s}```", .{fw.buffered()}) catch fw.buffered();
            _ = zg_gui.w.toast(app, .{ .title = "Memory report", .body_md = body, .source = "Performance" });
        }
    }

    /// `--mem-report`: prints the report after the first idle period (2 s
    /// without input) or at once with `now`, then exits with `exit`.
    pub fn armMemReport(t: *Tracing, now: bool, exit: bool) void {
        t.mem_group.concurrent(t.io, memReportTask, .{ t, now, exit }) catch {
            log.warn("--mem-report needs a concurrent Io", .{});
        };
    }

    fn memReportTask(t: *Tracing, now: bool, exit: bool) std.Io.Cancelable!void {
        const signal = &zg_perf.runtime.activity.global;
        if (!now) {
            try t.io.sleep(.fromNanoseconds(zg_perf.runtime.activity.ActivitySignal.idle_after_ns), .awake);
            while (signal.level() != .idle) {
                signal.waitUntilNot(t.io, signal.level(), null) catch |e| switch (e) {
                    error.Timeout => {},
                    error.Canceled => return error.Canceled,
                };
            }
        }
        var buf: [4096]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&buf);
        t.writeMemReport(&fw) catch |e| {
            log.warn("memory report failed: {t}", .{e});
            return;
        };
        printStdout(t.io, fw.buffered());
        if (exit) std.process.exit(0);
    }

    fn printStdout(io: std.Io, text: []const u8) void {
        var out_buf: [256]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        out.interface.writeAll(text) catch {};
        out.interface.flush() catch {};
    }

    /// Shows or hides the latency probe square in the main window.
    pub fn toggleProbe(t: *Tracing) !void {
        const w = t.hud_win orelse return error.NoWindow;
        const p = t.probe orelse blk: {
            const p = try zg_perf_ui.Probe.init(t.gpa, .{});
            t.probe = p;
            break :blk p;
        };
        p.toggle(w);
    }

    /// Finishes a running trace (blocking: at exit), then stops the drain.
    pub fn deinit(t: *Tracing) void {
        t.detachWindow();
        if (t.hud) |h| h.destroy();
        if (t.probe) |p| p.destroy();
        t.mem_group.cancel(t.io);
        if (t.mem) |s| s.stop();
        if (t.recorder) |fr| fr.deinit();
        if (t.timeline) |tl| {
            tl.deinit();
            t.gpa.destroy(tl);
        }
        t.group.await(t.io) catch {};
        t.app = null;
        if (t.takeActive()) |s| finish(t, s);
        t.drain.deinit();
        t.os.deinit();
        if (t.dir) |d| t.gpa.free(d);
        if (t.last_path) |p| t.gpa.free(p);
    }

    /// Starts a trace from a command-line request; `startup` traces stop
    /// on their own once `armStartupStop` runs.
    pub fn applyRequest(t: *Tracing, req: Request) void {
        t.format = req.format;
        t.startNamed(req.path, if (req.startup) "startup" else "trace") catch |e| log.err("cannot start the trace: {t}", .{e});
    }

    /// For `ZG_TRACE=startup`: stops the startup trace 2 s from now.
    pub fn armStartupStop(t: *Tracing) void {
        t.group.concurrent(t.io, startupTimer, .{t}) catch {};
    }

    fn startupTimer(t: *Tracing) std.Io.Cancelable!void {
        try t.io.sleep(.fromSeconds(2), .awake);
        if (t.takeActive()) |s| finish(t, s);
    }

    /// Whether a trace is recording.
    pub fn recording(t: *Tracing) bool {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        return t.active != null;
    }

    fn takeActive(t: *Tracing) ?*TraceSession {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const s = t.active;
        t.active = null;
        return s;
    }

    /// Starts recording into `path`, or a timestamped file named after
    /// `prefix` in the trace folder.
    pub fn startNamed(t: *Tracing, path: ?[]const u8, prefix: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const out = path orelse blk: {
            const dir = t.dir orelse return error.NoTraceFolder;
            const ms = std.Io.Clock.real.now(t.io).toMilliseconds();
            break :blk try session.tracePath(arena.allocator(), dir, prefix, ms, t.format);
        };
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        if (t.active != null) return error.SessionActive;
        t.active = try TraceSession.start(t.gpa, t.io, &t.drain, out, .{ .format = t.format, .process_name = "zigguro" });
        log.info("tracing to {s}", .{out});
    }

    /// Requests a stop: the export and write run on a worker.
    pub fn stop(t: *Tracing) void {
        const s = t.takeActive() orelse return;
        t.group.concurrent(t.io, stopTask, .{ t, s }) catch finish(t, s);
    }

    fn stopTask(t: *Tracing, s: *TraceSession) std.Io.Cancelable!void {
        finish(t, s);
    }

    /// Stops and writes `s` on this thread, then reports.
    fn finish(t: *Tracing, s: *TraceSession) void {
        defer s.destroy();
        const sum = s.stop() catch |e| {
            log.err("writing the trace failed: {t}", .{e});
            return;
        };
        log.info("trace written to {s} ({d} events, {d} bytes{s})", .{ sum.path, sum.events, sum.bytes, if (sum.truncated) ", truncated" else "" });
        t.mutex.lockUncancelable(t.io);
        if (t.last_path) |p| t.gpa.free(p);
        t.last_path = t.gpa.dupe(u8, sum.path) catch null;
        t.last_summary = sum;
        if (t.last_path) |p| t.last_summary.?.path = p;
        t.mutex.unlock(t.io);
        if (t.app) |app| app.post(.{ .ctx = t, .f = toastDone }) catch {};
    }

    fn toastDone(ctx: *anyopaque, app: *zg_gui.App) void {
        const t: *Tracing = @ptrCast(@alignCast(ctx));
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const sum = t.last_summary orelse return;
        var title: [96]u8 = undefined;
        var body: [600]u8 = undefined;
        _ = zg_gui.w.toast(app, .{
            .title = std.fmt.bufPrint(&title, "Trace saved ({d} events, {d:.1} s)", .{ sum.events, @as(f64, @floatFromInt(sum.duration_ns)) / 1e9 }) catch "Trace saved",
            .body_md = std.fmt.bufPrint(&body, "{s}{s}", .{ sum.path, if (sum.truncated) " (size cap reached)" else "" }) catch sum.path,
            .source = "Performance",
        });
    }

    /// Starts or stops.
    pub fn toggle(t: *Tracing) !void {
        if (t.recording()) t.stop() else try t.startNamed(null, "trace");
    }

    /// Creates the trace folder and shows where it is.
    pub fn openFolder(t: *Tracing) !void {
        const dir = t.dir orelse return error.NoTraceFolder;
        try std.Io.Dir.cwd().createDirPath(t.io, dir);
        if (t.app) |app| _ = zg_gui.w.toast(app, .{ .title = "Trace folder", .body_md = dir, .source = "Performance" });
    }

    const Cmd = struct { id: []const u8, title: []const u8, run: *const fn (t: *Tracing) anyerror!void };

    const commands = [_]Cmd{
        .{ .id = "perf.trace.start", .title = "Start Performance Trace", .run = cmdStart },
        .{ .id = "perf.trace.stop", .title = "Stop Performance Trace", .run = cmdStop },
        .{ .id = "perf.trace.toggle", .title = "Toggle Performance Trace", .run = toggle },
        .{ .id = "perf.trace.openFolder", .title = "Show Performance Trace Folder", .run = openFolder },
        .{ .id = zg_perf_ui.commands.commands[0].id, .title = zg_perf_ui.commands.commands[0].title, .run = toggleHud },
        .{ .id = zg_perf_ui.commands.commands[1].id, .title = zg_perf_ui.commands.commands[1].title, .run = toggleProbe },
        .{ .id = "perf.memory.report", .title = "Show Memory Report", .run = memReport },
    };

    fn cmdStart(t: *Tracing) !void {
        try t.startNamed(null, "trace");
    }

    fn cmdStop(t: *Tracing) !void {
        t.stop();
    }

    /// Registers the `perf.trace.*` commands, `perf.hud.toggle` and
    /// `perf.latencyProbe.toggle`.
    pub fn registerCommands(t: *Tracing, reg: *zg_config.commands.CommandRegistry) !void {
        inline for (commands) |c| {
            _ = try reg.register(.{
                .id = c.id,
                .title = c.title,
                .category = "Performance",
                .source = .{ .builtin = "zigguro" },
                .handler = .{ .ctx = t, .run = struct {
                    fn f(ctx: ?*anyopaque, _: *zg_config.commands.Invocation) anyerror!void {
                        try c.run(@ptrCast(@alignCast(ctx.?)));
                    }
                }.f },
            });
        }
    }
};

test "tracing: parse request" {
    try std.testing.expect(parseRequest(&.{ "zigguro", "x.zig" }, null) == null);
    const a = parseRequest(&.{ "zigguro", "--trace=/tmp/a.json", "--trace-format=chrome" }, null).?;
    try std.testing.expectEqualStrings("/tmp/a.json", a.path.?);
    try std.testing.expectEqual(session.Format.chrome, a.format);
    try std.testing.expect(!a.startup);
    const b = parseRequest(&.{"zigguro"}, "startup").?;
    try std.testing.expect(b.startup and b.path == null);
    // The flag's path wins over ZG_TRACE's.
    const c = parseRequest(&.{ "zigguro", "--trace=/x.pftrace" }, "startup:/y.pftrace").?;
    try std.testing.expect(c.startup);
    try std.testing.expectEqualStrings("/x.pftrace", c.path.?);
    try std.testing.expect(parseRequest(&.{"zigguro"}, "") == null);
}

test "tracing: start, toggle and stop write a trace" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var buf: [256]u8 = undefined;
    const state = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/state", .{&tmp.sub_path});
    try env.put("XDG_STATE_HOME", state);
    try env.put("LOCALAPPDATA", state);
    var t: Tracing = undefined;
    t.init(gpa, io, &env);
    defer t.deinit();
    try t.toggle();
    try std.testing.expect(t.recording());
    try std.testing.expectError(error.SessionActive, t.startNamed(null, "trace"));
    try t.toggle();
    t.group.await(io) catch {};
    try std.testing.expect(!t.recording());
    const path = t.last_path.?;
    try std.testing.expect(std.mem.endsWith(u8, path, ".pftrace"));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try std.testing.expect(bytes.len > 0);
}
