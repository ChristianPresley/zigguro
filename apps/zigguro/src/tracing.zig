//! Trace capture in the IDE (E14.F02.S01.T02): `--trace=<path>`,
//! `--trace-format=perfetto|chrome`, `ZG_TRACE=startup|<path>|startup:<path>`
//! and the `perf.trace.*` commands, on top of zg_perf's drain and
//! `TraceSession`.
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

    /// Starts the drain; `env` gives the trace folder.
    pub fn init(t: *Tracing, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
        t.* = .{ .gpa = gpa, .io = io, .drain = .init(gpa, io) };
        t.dir = blk: {
            const d = session.defaultTraceDir(gpa, env, builtin.os.tag) catch break :blk null;
            break :blk @constCast(d orelse break :blk null);
        };
        t.drain.start();
    }

    /// Finishes a running trace (blocking: at exit), then stops the drain.
    pub fn deinit(t: *Tracing) void {
        t.group.await(t.io) catch {};
        t.app = null;
        if (t.takeActive()) |s| finish(t, s);
        t.drain.deinit();
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
    };

    fn cmdStart(t: *Tracing) !void {
        try t.startNamed(null, "trace");
    }

    fn cmdStop(t: *Tracing) !void {
        t.stop();
    }

    /// Registers the `perf.trace.*` commands.
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
