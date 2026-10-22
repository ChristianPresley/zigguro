//! `ProcessHost`: a `TerminalHost` that runs each command as a child
//! process, for `zg agent` and tests. The IDE uses E06's terminals.
//!
//! - Commands run under `/bin/sh -c` (POSIX) or `cmd.exe /d /c`
//!   (Windows), with stdin closed and stdout and stderr captured as lines.
//! - The working directory of a session is the last `cwd` given; there is
//!   no interactive shell, so `cd` inside a command does not carry over.
//! - Process trees: on POSIX each command leads its own process group, and
//!   `interrupt` sends SIGINT, then SIGTERM after 2 s, then SIGKILL after
//!   2 s more, to the whole group. On Windows the command runs in a job
//!   object that `interrupt` terminates (processes started before the
//!   assignment, in the first instant, can escape it).
//! - A job keeps at most `max_lines` lines; later output is dropped and
//!   noted once.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("zg_ai_proto");
const host_mod = @import("terminal_host.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Status = host_mod.Status;
const windows = std.os.windows;

pub const max_lines = 200_000;

const Job = struct {
    arena: std.heap.ArenaAllocator,
    lines: std.ArrayList([]const u8) = .empty,
    dropped: bool = false,
    status: Status = .running,
    interrupted: bool = false,
    pid: if (builtin.os.tag == .windows) void else std.posix.pid_t = undefined,
    win_job: if (builtin.os.tag == .windows) ?windows.HANDLE else void = if (builtin.os.tag == .windows) null else {},
};

const Session = struct { cwd: ?[]const u8 = null };

pub const ProcessHost = struct {
    gpa: Allocator,
    io: Io,
    /// The child environment; null inherits.
    environ: ?*const std.process.Environ.Map = null,
    /// Between SIGINT, SIGTERM and SIGKILL.
    grace_ms: u64 = 2_000,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    sessions: std.ArrayList(Session) = .empty,
    jobs: std.ArrayList(*Job) = .empty,
    names: std.heap.ArenaAllocator,
    tasks: Io.Group = .init,

    pub fn init(gpa: Allocator, io: Io) ProcessHost {
        return .{ .gpa = gpa, .io = io, .names = .init(gpa) };
    }

    /// Kills whatever is still running.
    pub fn deinit(h: *ProcessHost) void {
        for (h.jobs.items) |j| if (j.status == .running) h.signal(j, .kill);
        h.tasks.cancel(h.io);
        for (h.jobs.items) |j| {
            if (builtin.os.tag == .windows) if (j.win_job) |wj| windows.CloseHandle(wj);
            j.arena.deinit();
            h.gpa.destroy(j);
        }
        h.jobs.deinit(h.gpa);
        h.sessions.deinit(h.gpa);
        h.names.deinit();
    }

    pub fn host(h: *ProcessHost) host_mod.TerminalHost {
        return .{ .ctx = h, .vtable = &.{
            .create = create,
            .start = start,
            .wait = wait,
            .lines = lines,
            .status = status,
            .interrupt = interrupt,
        } };
    }

    fn create(ctx: *anyopaque, _: Io, _: proto.AgentRef, _: bool) host_mod.Error!host_mod.SessionId {
        const h: *ProcessHost = @ptrCast(@alignCast(ctx));
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        try h.sessions.append(h.gpa, .{});
        return @intCast(h.sessions.items.len - 1);
    }

    fn start(ctx: *anyopaque, _: Io, session: host_mod.SessionId, command: []const u8, cwd: ?[]const u8) host_mod.Error!host_mod.JobId {
        const h: *ProcessHost = @ptrCast(@alignCast(ctx));
        const io = h.io;
        const dir = blk: {
            h.mutex.lockUncancelable(io);
            defer h.mutex.unlock(io);
            const s = &h.sessions.items[session];
            if (cwd) |c| s.cwd = try h.names.allocator().dupe(u8, c);
            break :blk s.cwd;
        };
        const argv: []const []const u8 = if (builtin.os.tag == .windows)
            &.{ "cmd.exe", "/d", "/c", command }
        else
            &.{ "/bin/sh", "-c", command };
        var child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (dir) |d| .{ .path = d } else .inherit,
            .environ_map = h.environ,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
            .create_no_window = true,
        }) catch return error.SpawnFailed;

        const j = h.gpa.create(Job) catch |e| {
            child.kill(io);
            return e;
        };
        j.* = .{ .arena = .init(h.gpa) };
        if (builtin.os.tag == .windows) {
            j.win_job = CreateJobObjectW(null, null);
            if (j.win_job) |wj| _ = AssignProcessToJobObject(wj, child.id.?);
        } else j.pid = child.id.?;

        const id = blk: {
            h.mutex.lockUncancelable(io);
            defer h.mutex.unlock(io);
            h.jobs.append(h.gpa, j) catch |e| {
                child.kill(io);
                j.arena.deinit();
                h.gpa.destroy(j);
                return e;
            };
            break :blk h.jobs.items.len - 1;
        };
        h.tasks.concurrent(io, pump, .{ h, j, child }) catch {
            // No concurrency: the job cannot be watched.
            var c = child;
            c.kill(io);
            h.finish(j, .{ .failed = "the command could not be watched" });
        };
        return @intCast(id);
    }

    fn finish(h: *ProcessHost, j: *Job, st: Status) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        j.status = st;
        h.cond.broadcast(h.io);
    }

    fn pump(h: *ProcessHost, j: *Job, child_in: std.process.Child) Io.Cancelable!void {
        var child = child_in;
        const io = h.io;
        var err_task = io.concurrent(readAll, .{ h, j, child.stderr.? }) catch null;
        readAll(h, j, child.stdout.?) catch {
            if (err_task) |*t| t.cancel(io) catch {};
            child.kill(io);
            return error.Canceled;
        };
        if (err_task) |*t| t.await(io) catch {};
        const term = child.wait(io) catch |e| {
            if (e == error.Canceled) child.kill(io);
            h.finish(j, .killed);
            return;
        };
        h.finish(j, switch (term) {
            .exited => |code| if (j.interrupted and builtin.os.tag == .windows) .killed else .{ .exited = code },
            .signal, .stopped => .killed,
            .unknown => |code| .{ .exited = @bitCast(code) },
        });
    }

    fn readAll(h: *ProcessHost, j: *Job, file: Io.File) Io.Cancelable!void {
        var cleaner: host_mod.LineCleaner = .{};
        defer cleaner.deinit(h.gpa);
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = file.readStreaming(h.io, &.{&buf}) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => break,
            };
            if (n == 0) break;
            cleaner.feed(h.gpa, buf[0..n], LineCtx{ .h = h, .j = j }, LineCtx.emit) catch break;
        }
        cleaner.finish(LineCtx{ .h = h, .j = j }, LineCtx.emit) catch {};
    }

    const LineCtx = struct {
        h: *ProcessHost,
        j: *Job,

        fn emit(c: LineCtx, line: []const u8) Allocator.Error!void {
            c.h.mutex.lockUncancelable(c.h.io);
            defer c.h.mutex.unlock(c.h.io);
            if (c.j.lines.items.len >= max_lines) {
                if (!c.j.dropped) {
                    c.j.dropped = true;
                    try c.j.lines.append(c.j.arena.allocator(), "[output limit reached; later lines were dropped]");
                    c.h.cond.broadcast(c.h.io);
                }
                return;
            }
            const a = c.j.arena.allocator();
            try c.j.lines.append(a, try a.dupe(u8, line));
            c.h.cond.broadcast(c.h.io);
        }
    };

    fn wait(ctx: *anyopaque, io: Io, id: host_mod.JobId, timeout_ms: u64, sink: ?host_mod.LineSink) Io.Cancelable!Status {
        const h: *ProcessHost = @ptrCast(@alignCast(ctx));
        const j = h.jobs.items[id];
        var timer: Timer = .{ .h = h };
        var t = io.concurrent(Timer.run, .{ &timer, timeout_ms }) catch null;
        defer if (t) |*f| f.cancel(io);
        h.mutex.lockUncancelable(io);
        var sent = j.lines.items.len;
        while (true) {
            while (sent < j.lines.items.len) : (sent += 1) {
                const l = j.lines.items[sent];
                if (sink) |s| {
                    h.mutex.unlock(io);
                    s.line(s.ctx, l);
                    h.mutex.lockUncancelable(io);
                }
            }
            if (j.status != .running or timer.fired or t == null) break;
            h.cond.wait(io, &h.mutex) catch |e| {
                h.mutex.unlock(io);
                return e;
            };
        }
        const st = j.status;
        h.mutex.unlock(io);
        return st;
    }

    const Timer = struct {
        h: *ProcessHost,
        fired: bool = false,

        fn run(t: *Timer, ms: u64) void {
            t.h.io.sleep(.fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64)))), .awake) catch return;
            t.h.mutex.lockUncancelable(t.h.io);
            defer t.h.mutex.unlock(t.h.io);
            t.fired = true;
            t.h.cond.broadcast(t.h.io);
        }
    };

    fn lines(ctx: *anyopaque, arena: Allocator, id: host_mod.JobId, since: usize) Allocator.Error![]const []const u8 {
        const h: *ProcessHost = @ptrCast(@alignCast(ctx));
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const all = h.jobs.items[id].lines.items;
        if (since >= all.len) return &.{};
        const out = try arena.alloc([]const u8, all.len - since);
        for (out, all[since..]) |*o, l| o.* = try arena.dupe(u8, l);
        return out;
    }

    fn status(ctx: *anyopaque, id: host_mod.JobId) Status {
        const h: *ProcessHost = @ptrCast(@alignCast(ctx));
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        return h.jobs.items[id].status;
    }

    fn interrupt(ctx: *anyopaque, _: Io, id: host_mod.JobId) void {
        const h: *ProcessHost = @ptrCast(@alignCast(ctx));
        const j = blk: {
            h.mutex.lockUncancelable(h.io);
            defer h.mutex.unlock(h.io);
            const j = h.jobs.items[id];
            if (j.status != .running or j.interrupted) return;
            j.interrupted = true;
            break :blk j;
        };
        if (builtin.os.tag == .windows) {
            h.signal(j, .kill);
            return;
        }
        h.signal(j, .int);
        h.tasks.concurrent(h.io, escalate, .{ h, j }) catch h.signal(j, .kill);
    }

    fn escalate(h: *ProcessHost, j: *Job) Io.Cancelable!void {
        inline for (.{ .term, .kill }) |sig| {
            try h.io.sleep(.fromMilliseconds(@intCast(h.grace_ms)), .awake);
            h.mutex.lockUncancelable(h.io);
            const running = j.status == .running;
            h.mutex.unlock(h.io);
            if (!running) return;
            h.signal(j, sig);
        }
    }

    const Sig = enum { int, term, kill };

    /// Signals the job's whole process tree.
    fn signal(_: *ProcessHost, j: *Job, sig: Sig) void {
        if (builtin.os.tag == .windows) {
            if (j.win_job) |wj| _ = TerminateJobObject(wj, 1);
            return;
        }
        const s: std.posix.SIG = switch (sig) {
            .int => .INT,
            .term => .TERM,
            .kill => .KILL,
        };
        std.posix.kill(-j.pid, s) catch {};
    }
};

extern "kernel32" fn CreateJobObjectW(attrs: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, code: windows.UINT) callconv(.winapi) windows.BOOL;
