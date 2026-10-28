//! A task process without a terminal (agents, `apps/zg`, tests): argv
//! spawned with stdin ignored and stdout and stderr piped, in its own
//! process group on POSIX so the whole tree can be killed.
//!
//! - Two reader loops forward output to one sink, a line at a time under
//!   one lock, so stdout and stderr lines arrive in the order they were
//!   read (lines over 64 KiB go in pieces; the last line may lack a
//!   newline).
//! - A watcher reaps the process and sets the exit event; `wait` then
//!   gives the readers 500 ms to drain (a grandchild may hold the pipes
//!   open) before canceling them.
//! - Windows: only the process itself is killed until the E01 Job Object
//!   helper lands (as in zg_lsp's ServerProcess).
//!
//! Every call blocks; none may run on the UI thread.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Subsystem = zg_core.runtime.Subsystem;
const is_windows = builtin.os.tag == .windows;

pub const Spec = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// Null inherits ours.
    env: ?*const std.process.Environ.Map = null,
};

pub const Sink = struct {
    ctx: *anyopaque,
    /// One or more whole lines (or the last piece of the output).
    output: *const fn (ctx: *anyopaque, bytes: []const u8) void,
};

pub const Proc = struct {
    gpa: Allocator,
    io: Io,
    sink: Sink,
    child: std.process.Child,
    child_id: ?std.process.Child.Id,
    pgid: ?std.posix.pid_t = null,
    out_file: ?Io.File,
    err_file: ?Io.File,
    readers: Subsystem,
    watcher: Subsystem,
    out_mutex: Io.Mutex = .init,
    exit_mutex: Io.Mutex = .init,
    exit_event: Io.Event = .unset,
    readers_event: Io.Event = .unset,
    readers_left: std.atomic.Value(u8) = .init(2),
    term: ?std.process.Child.Term = null,
    started: Io.Timestamp,

    pub fn start(gpa: Allocator, io: Io, spec: Spec, sink: Sink) !*Proc {
        const p = try gpa.create(Proc);
        errdefer gpa.destroy(p);
        var child = try std.process.spawn(io, .{
            .argv = spec.argv,
            .cwd = if (spec.cwd) |c| .{ .path = c } else .inherit,
            .environ_map = spec.env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (is_windows) null else 0,
            .create_no_window = true,
        });
        p.* = .{
            .gpa = gpa,
            .io = io,
            .sink = sink,
            .child = child,
            .child_id = child.id,
            .out_file = child.stdout,
            .err_file = child.stderr,
            .readers = .init(io),
            .watcher = .init(io),
            .started = .now(io, .awake),
        };
        if (!is_windows) p.pgid = child.id;
        // Ours to close: reaping (which closes Child's files) must not race
        // with the readers.
        p.child.stdout = null;
        p.child.stderr = null;
        child = undefined;
        p.watcher.spawnLoop(watchExit, .{p}) catch |e| {
            p.killTree();
            _ = p.child.wait(io) catch {};
            p.closeFiles();
            return e;
        };
        inline for (.{ "out_file", "err_file" }) |field| {
            p.readers.spawnLoop(readLoop, .{ p, @field(p, field).? }) catch {
                // Without a loop nobody reads this pipe: count it drained.
                p.readerDone();
            };
        }
        return p;
    }

    fn readLoop(p: *Proc, f: Io.File) Io.Cancelable!void {
        defer p.readerDone();
        var buf: [64 * 1024]u8 = undefined;
        var len: usize = 0;
        while (true) {
            const n = f.readStreaming(p.io, &.{buf[len..]}) catch |e| {
                if (len > 0) p.emit(buf[0..len]);
                return if (e == error.Canceled) error.Canceled else {};
            };
            len += n;
            // Forward the whole lines; keep a partial one unless the
            // buffer is full.
            const end = if (std.mem.lastIndexOfScalar(u8, buf[0..len], '\n')) |i| i + 1 else if (len == buf.len) len else 0;
            if (end > 0) {
                p.emit(buf[0..end]);
                std.mem.copyForwards(u8, buf[0 .. len - end], buf[end..len]);
                len -= end;
            }
        }
    }

    fn emit(p: *Proc, bytes: []const u8) void {
        p.out_mutex.lockUncancelable(p.io);
        defer p.out_mutex.unlock(p.io);
        p.sink.output(p.sink.ctx, bytes);
    }

    fn readerDone(p: *Proc) void {
        if (p.readers_left.fetchSub(1, .acq_rel) == 1) p.readers_event.set(p.io);
    }

    fn watchExit(p: *Proc) Io.Cancelable!void {
        if (is_windows) {
            // Wait without reaping, so `killTree` never uses a closed
            // handle: reaping happens under `exit_mutex`.
            const infinite: std.os.windows.LARGE_INTEGER = std.math.minInt(std.os.windows.LARGE_INTEGER);
            _ = std.os.windows.ntdll.NtWaitForSingleObject(p.child_id.?, .FALSE, &infinite);
        }
        p.exit_mutex.lockUncancelable(p.io);
        defer p.exit_mutex.unlock(p.io);
        const prev = p.io.swapCancelProtection(.blocked);
        defer _ = p.io.swapCancelProtection(prev);
        p.term = p.child.wait(p.io) catch .{ .unknown = 0 };
        p.exit_event.set(p.io);
    }

    /// Whether the process has exited.
    pub fn exited(p: *const Proc) bool {
        return p.exit_event.isSet();
    }

    /// Waits up to `timeout` for the exit (null: forever). Null when it
    /// timed out.
    pub fn waitExit(p: *Proc, timeout: ?Io.Duration) ?std.process.Child.Term {
        if (timeout) |t| {
            // waitTimeout may wake early: wait out the deadline.
            const deadline = zg_core.runtime.Deadline.after(p.io, t);
            while (!p.exit_event.isSet()) {
                if (deadline.expired(p.io)) return null;
                p.exit_event.waitTimeout(p.io, deadline.timeout()) catch {};
            }
        } else {
            p.exit_event.waitUncancelable(p.io);
        }
        return p.term.?;
    }

    /// Waits for the exit and the end of the output.
    pub fn wait(p: *Proc) std.process.Child.Term {
        const term = p.waitExit(null).?;
        p.drainOutput();
        return term;
    }

    /// After the exit: lets the readers finish, then cancels them.
    pub fn drainOutput(p: *Proc) void {
        p.readers_event.waitTimeout(p.io, .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } }) catch {};
        p.readers.shutdown();
    }

    /// The exit code of a normal exit (null for a signal or a crash).
    pub fn exitCode(term: std.process.Child.Term) ?u8 {
        return switch (term) {
            .exited => |c| c,
            else => null,
        };
    }

    /// Kills the process and (POSIX) everything in its group.
    pub fn killTree(p: *Proc) void {
        if (is_windows) {
            p.exit_mutex.lockUncancelable(p.io);
            defer p.exit_mutex.unlock(p.io);
            if (p.exit_event.isSet()) return;
            if (p.child_id) |h| _ = std.os.windows.ntdll.NtTerminateProcess(h, @enumFromInt(1));
        } else if (p.pgid) |g| {
            std.posix.kill(-g, .KILL) catch {};
        }
    }

    /// Kills what is left of the tree, waits and frees everything.
    pub fn deinit(p: *Proc) void {
        // Children of a process that exited may still run in its group.
        p.killTree();
        _ = p.waitExit(null);
        p.watcher.join() catch {};
        p.drainOutput();
        p.closeFiles();
        p.gpa.destroy(p);
    }

    fn closeFiles(p: *Proc) void {
        if (p.out_file) |f| f.close(p.io);
        if (p.err_file) |f| f.close(p.io);
        p.out_file = null;
        p.err_file = null;
    }
};
