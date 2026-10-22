//! The seam between the command tools and the terminal that runs the
//! commands. In the IDE it is E06's `TerminalService` (a visible,
//! agent-owned terminal with shell integration); `zg agent` uses
//! `ProcessHost`, which runs each command as a child process; tests use
//! `FakeHost`. zg_ai cannot import zg_terminal (same layer), so the app
//! passes the service in.
//!
//! A host keeps every line a job printed, numbered from 0, until it is
//! freed: lines are logical (wrapped lines joined), with ANSI sequences
//! stripped and progress-bar redraws collapsed to their last state.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const SessionId = u32;
pub const JobId = u32;

pub const Status = union(enum) {
    running,
    exited: i32,
    /// Stopped by `interrupt` or a signal.
    killed,
    /// The command could not be run (static text).
    failed: []const u8,
};

/// Receives committed lines while `wait` blocks.
pub const LineSink = struct {
    ctx: *anyopaque,
    line: *const fn (ctx: *anyopaque, text: []const u8) void,
};

pub const Error = error{ Unavailable, OutOfMemory, SpawnFailed };

pub const TerminalHost = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// A terminal session owned by `owner`; shown to the user when
        /// `visible`. The working directory persists across its commands.
        create: *const fn (ctx: *anyopaque, io: Io, owner: proto.AgentRef, visible: bool) Error!SessionId,
        /// Starts `command` in the session's shell (in `cwd` if given).
        start: *const fn (ctx: *anyopaque, io: Io, session: SessionId, command: []const u8, cwd: ?[]const u8) Error!JobId,
        /// Blocks until the job ends or `timeout_ms` passes, passing lines
        /// committed meanwhile to `sink`. Returns `.running` on timeout.
        wait: *const fn (ctx: *anyopaque, io: Io, job: JobId, timeout_ms: u64, sink: ?LineSink) Io.Cancelable!Status,
        /// Copies lines `since..` into `arena`.
        lines: *const fn (ctx: *anyopaque, arena: Allocator, job: JobId, since: usize) Allocator.Error![]const []const u8,
        status: *const fn (ctx: *anyopaque, job: JobId) Status,
        /// Ctrl+C, then SIGTERM, then kills the process tree. Returns at
        /// once; `wait` sees the end.
        interrupt: *const fn (ctx: *anyopaque, io: Io, job: JobId) void,
    };

    pub fn create(h: TerminalHost, io: Io, owner: proto.AgentRef, visible: bool) Error!SessionId {
        return h.vtable.create(h.ctx, io, owner, visible);
    }
    pub fn start(h: TerminalHost, io: Io, session: SessionId, command: []const u8, cwd: ?[]const u8) Error!JobId {
        return h.vtable.start(h.ctx, io, session, command, cwd);
    }
    pub fn wait(h: TerminalHost, io: Io, job: JobId, timeout_ms: u64, sink: ?LineSink) Io.Cancelable!Status {
        return h.vtable.wait(h.ctx, io, job, timeout_ms, sink);
    }
    pub fn lines(h: TerminalHost, arena: Allocator, job: JobId, since: usize) Allocator.Error![]const []const u8 {
        return h.vtable.lines(h.ctx, arena, job, since);
    }
    pub fn status(h: TerminalHost, job: JobId) Status {
        return h.vtable.status(h.ctx, job);
    }
    pub fn interrupt(h: TerminalHost, io: Io, job: JobId) void {
        h.vtable.interrupt(h.ctx, io, job);
    }
};

/// Splits terminal output into logical lines: strips CSI, OSC and other
/// escape sequences, keeps only the text after the last `\r` of a line
/// (progress bars), and drops other control characters.
pub const LineCleaner = struct {
    cur: std.ArrayList(u8) = .empty,
    state: enum { text, esc, csi, osc, osc_esc } = .text,
    /// A `\r` not yet known to be part of `\r\n`.
    cr: bool = false,

    pub fn deinit(c: *LineCleaner, gpa: Allocator) void {
        c.cur.deinit(gpa);
    }

    /// Feeds `bytes`; calls `emit` for each finished line.
    pub fn feed(c: *LineCleaner, gpa: Allocator, bytes: []const u8, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const u8) Allocator.Error!void) Allocator.Error!void {
        for (bytes) |b| switch (c.state) {
            .text => {
                if (c.cr and b != '\n' and b != '\r') c.cur.clearRetainingCapacity();
                c.cr = false;
                switch (b) {
                    0x1b => c.state = .esc,
                    '\n' => {
                        const line = std.mem.trimEnd(u8, c.cur.items, " ");
                        try emit(ctx, line);
                        c.cur.clearRetainingCapacity();
                    },
                    '\r' => c.cr = true,
                    '\t' => try c.cur.append(gpa, b),
                    else => if (b >= 0x20 and b != 0x7f) try c.cur.append(gpa, b) else if (b == 0x08 and c.cur.items.len > 0) {
                        c.cur.items.len -= 1;
                    },
                }
            },
            .esc => c.state = switch (b) {
                '[' => .csi,
                ']' => .osc,
                else => .text,
            },
            .csi => if (b >= 0x40 and b <= 0x7e) {
                c.state = .text;
            },
            .osc => switch (b) {
                0x07 => c.state = .text,
                0x1b => c.state = .osc_esc,
                else => {},
            },
            .osc_esc => c.state = .text,
        };
    }

    /// Emits the unterminated last line, if any.
    pub fn finish(c: *LineCleaner, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const u8) Allocator.Error!void) Allocator.Error!void {
        const line = std.mem.trimEnd(u8, c.cur.items, " ");
        if (line.len > 0) try emit(ctx, line);
        c.cur.clearRetainingCapacity();
        c.cr = false;
    }
};
