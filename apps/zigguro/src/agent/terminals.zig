//! `AgentTerminals`: the IDE's `TerminalHost` (E06.F07.S01.T01). An
//! agent's commands run in a visible terminal of its own, in the panel's
//! Agents section, with shell integration on: the command is typed at
//! the prompt (bracketed when the shell asked for it), bound to the
//! command block the shell reports next, and its output and exit code
//! come from that block (`zg_terminal.agent.Run`). The shell lives on,
//! so `cd` and exported variables carry over between commands.
//!
//! - A session's terminal opens on `create`, which waits (up to
//!   `ready_timeout_ms`) for the shell's first prompt. A shell without
//!   integration (turned off, or one zigguro has no script for) never
//!   reports one; its terminal is closed and the session's commands run
//!   as child processes (`fallback`, the `ProcessHost`), as do sessions
//!   created with `visible` off.
//! - `start` types the command at an empty prompt. If the terminal is
//!   busy (a background command still runs, or the user is typing) for
//!   `busy_timeout_ms`, or its shell has ended, the session moves to a
//!   new terminal in the same folder.
//! - `interrupt` types Ctrl+C, then after `grace_ms` ends the shell and
//!   everything it started; the job ends as killed.
//! - Closing an agent's terminal ends its running command as killed.
//!
//! The terminals belong to the UI thread: every look at one goes through
//! `Ui.run`, which posts to the UI thread and waits. Block events arrive
//! on the UI thread and update the job under `mutex`; tool calls on agent
//! threads read jobs under it. Never call the host's functions on the UI
//! thread (they would wait for themselves).

const std = @import("std");
const builtin = @import("builtin");
const zg_ai = @import("zg_ai");
const zg_ai_proto = zg_ai.proto;
const zg_terminal = @import("zg_terminal");
const TerminalPanel = @import("../terminal_panel.zig").TerminalPanel;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const host_mod = zg_ai.tools.builtin.terminal_host;
const TerminalHost = host_mod.TerminalHost;
const Status = host_mod.Status;
const Run = zg_terminal.agent.Run;
const Blocks = zg_terminal.shell.Blocks;
const BlockEvent = zg_terminal.shell.BlockEvent;
const ShellKind = zg_terminal.shell.inject.ShellKind;

/// What the host needs from the workbench.
pub const Ui = struct {
    ctx: *anyopaque,
    /// Runs `f(arg)` on the UI thread and waits for it; false when it
    /// cannot be posted.
    run: *const fn (ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) bool,
    /// UI thread: opens a terminal in the Agents section and starts its
    /// shell (in `cwd`, else the workspace folder).
    open: *const fn (ctx: *anyopaque, cwd: ?[]const u8) ?*TerminalPanel,
    /// UI thread: closes a terminal `open` returned.
    close: *const fn (ctx: *anyopaque, panel: *TerminalPanel) void,
};

/// A terminal the host opened. Freed with the host.
const Term = struct {
    host: *AgentTerminals,
    /// UI thread only; null once the panel is destroyed.
    panel: ?*TerminalPanel,
    prev_output: ?TerminalPanel.Hook,
    /// The shell ended or the panel closed (under `mutex`).
    gone: bool = false,
    /// The job typed into the shell and not yet ended (under `mutex`).
    job: ?*Job = null,
};

const Session = struct {
    term: ?*Term = null,
    /// Set when the session's commands run as child processes.
    fallback: ?host_mod.SessionId = null,
};

const Job = struct {
    run: Run,
    status: Status = .running,
    interrupted: bool = false,
    term: ?*Term = null,
    /// The `fallback` job, when the session runs child processes.
    fallback: ?host_mod.JobId = null,
};

pub const AgentTerminals = struct {
    gpa: Allocator,
    io: Io,
    ui: Ui,
    fallback: TerminalHost,
    ready_timeout_ms: u64 = 10_000,
    busy_timeout_ms: u64 = 5_000,
    grace_ms: u64 = 2_000,
    /// Between looks at a terminal while waiting for a prompt.
    poll_ms: u64 = 50,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    sessions: std.ArrayList(Session) = .empty,
    jobs: std.ArrayList(*Job) = .empty,
    terms: std.ArrayList(*Term) = .empty,
    tasks: Io.Group = .init,
    closing: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, io: Io, ui: Ui, fallback: TerminalHost) AgentTerminals {
        return .{ .gpa = gpa, .io = io, .ui = ui, .fallback = fallback };
    }

    /// UI thread. The terminals stay open (as the user's history).
    pub fn deinit(h: *AgentTerminals) void {
        h.closing.store(true, .release);
        h.tasks.cancel(h.io);
        for (h.terms.items) |t| {
            if (t.panel) |p| detach(t, p);
            h.gpa.destroy(t);
        }
        h.terms.deinit(h.gpa);
        for (h.jobs.items) |j| {
            j.run.deinit();
            h.gpa.destroy(j);
        }
        h.jobs.deinit(h.gpa);
        h.sessions.deinit(h.gpa);
    }

    pub fn host(h: *AgentTerminals) TerminalHost {
        return .{ .ctx = h, .vtable = &.{
            .create = create,
            .start = start,
            .wait = wait,
            .lines = lines,
            .status = status,
            .interrupt = interrupt,
        } };
    }

    // -- the vtable (agent threads) -------------------------------------------

    fn create(ctx: *anyopaque, io: Io, owner: zg_ai_proto.AgentRef, visible: bool) host_mod.Error!host_mod.SessionId {
        const h: *AgentTerminals = @ptrCast(@alignCast(ctx));
        var s: Session = .{};
        if (visible) s.term = h.openReady(null) catch null;
        if (s.term == null) s.fallback = try h.fallback.create(io, owner, false);
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        try h.sessions.append(h.gpa, s);
        return @intCast(h.sessions.items.len - 1);
    }

    fn start(ctx: *anyopaque, io: Io, sid: host_mod.SessionId, command: []const u8, cwd: ?[]const u8) host_mod.Error!host_mod.JobId {
        const h: *AgentTerminals = @ptrCast(@alignCast(ctx));
        const s = blk: {
            h.mutex.lockUncancelable(h.io);
            defer h.mutex.unlock(h.io);
            break :blk h.sessions.items[sid];
        };
        const j = try h.gpa.create(Job);
        j.* = .{ .run = Run.init(h.gpa, command) catch |e| {
            h.gpa.destroy(j);
            return e;
        } };
        errdefer {
            j.run.deinit();
            h.gpa.destroy(j);
        }
        if (s.fallback) |fs| {
            j.fallback = try h.fallback.start(io, fs, command, cwd);
        } else {
            const t = try h.readyTerm(sid, s.term.?);
            j.term = t;
            var w: Write = .{ .h = h, .t = t, .j = j, .cwd = cwd };
            if (!(h.onUi(uiWrite, .{&w}) orelse false)) return error.Unavailable;
        }
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        try h.jobs.append(h.gpa, j);
        return @intCast(h.jobs.items.len - 1);
    }

    fn wait(ctx: *anyopaque, io: Io, id: host_mod.JobId, timeout_ms: u64, sink: ?host_mod.LineSink) Io.Cancelable!Status {
        const h: *AgentTerminals = @ptrCast(@alignCast(ctx));
        const j = h.job(id);
        if (j.fallback) |f| return h.fallback.wait(io, f, timeout_ms, sink);
        var timer: Timer = .{ .h = h };
        var task = io.concurrent(Timer.run, .{ &timer, timeout_ms }) catch null;
        defer if (task) |*f| f.cancel(io);
        h.mutex.lockUncancelable(h.io);
        var sent = j.run.lines.items.len;
        while (true) {
            while (sent < j.run.lines.items.len) : (sent += 1) {
                // A line's bytes stay put while the job lives.
                const l = j.run.lines.items[sent];
                if (sink) |s| {
                    h.mutex.unlock(h.io);
                    s.line(s.ctx, l);
                    h.mutex.lockUncancelable(h.io);
                }
            }
            if (j.status != .running or timer.fired or task == null) break;
            h.cond.wait(h.io, &h.mutex) catch |e| {
                h.mutex.unlock(h.io);
                return e;
            };
        }
        const st = j.status;
        h.mutex.unlock(h.io);
        return st;
    }

    const Timer = struct {
        h: *AgentTerminals,
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
        const h: *AgentTerminals = @ptrCast(@alignCast(ctx));
        const j = h.job(id);
        if (j.fallback) |f| return h.fallback.lines(arena, f, since);
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const all = j.run.lines.items;
        if (since >= all.len) return &.{};
        const out = try arena.alloc([]const u8, all.len - since);
        for (out, all[since..]) |*o, l| o.* = try arena.dupe(u8, l);
        return out;
    }

    fn status(ctx: *anyopaque, id: host_mod.JobId) Status {
        const h: *AgentTerminals = @ptrCast(@alignCast(ctx));
        const j = h.job(id);
        if (j.fallback) |f| return h.fallback.status(f);
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        return j.status;
    }

    fn interrupt(ctx: *anyopaque, io: Io, id: host_mod.JobId) void {
        const h: *AgentTerminals = @ptrCast(@alignCast(ctx));
        const j = h.job(id);
        if (j.fallback) |f| return h.fallback.interrupt(io, f);
        {
            h.mutex.lockUncancelable(h.io);
            defer h.mutex.unlock(h.io);
            if (j.status != .running or j.interrupted) return;
            j.interrupted = true;
        }
        const t = j.term.?;
        _ = h.onUi(uiSend, .{ t, "\x03" });
        h.tasks.concurrent(h.io, escalate, .{ h, j }) catch h.endShell(j);
    }

    fn escalate(h: *AgentTerminals, j: *Job) Io.Cancelable!void {
        try h.io.sleep(.fromMilliseconds(@intCast(h.grace_ms)), .awake);
        h.endShell(j);
    }

    /// Ends the job's shell if the job still runs; the job ends killed.
    fn endShell(h: *AgentTerminals, j: *Job) void {
        {
            h.mutex.lockUncancelable(h.io);
            defer h.mutex.unlock(h.io);
            if (j.status != .running) return;
        }
        if (h.closing.load(.acquire)) return;
        _ = h.onUi(uiKill, .{j.term.?});
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.end(j, .killed);
    }

    fn job(h: *AgentTerminals, id: host_mod.JobId) *Job {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        return h.jobs.items[id];
    }

    // -- terminals ------------------------------------------------------------

    /// Opens a terminal and waits for its first prompt; null when the
    /// shell reports none in time (its terminal is closed again).
    fn openReady(h: *AgentTerminals, cwd: ?[]const u8) !?*Term {
        const t = (h.onUi(uiOpen, .{ h, cwd }) orelse return null) orelse return null;
        var waited: u64 = 0;
        while (waited < h.ready_timeout_ms) : (waited += h.poll_ms) {
            switch (h.onUi(uiState, .{t}) orelse return null) {
                .ready, .busy => return t,
                .gone => return null,
                .inactive => {},
            }
            try h.io.sleep(.fromMilliseconds(@intCast(h.poll_ms)), .awake);
        }
        _ = h.onUi(uiClose, .{t});
        return null;
    }

    /// The session's terminal once it is at an empty prompt, or a new
    /// one (in the old one's folder) when it stays busy or has ended.
    fn readyTerm(h: *AgentTerminals, sid: host_mod.SessionId, first: *Term) host_mod.Error!*Term {
        var waited: u64 = 0;
        const cwd: ?[]u8 = while (true) : (waited += h.poll_ms) {
            switch (h.onUi(uiState, .{first}) orelse return error.Unavailable) {
                .ready => return first,
                .gone, .inactive => break null,
                .busy => if (waited >= h.busy_timeout_ms) break h.onUi(uiCwd, .{first}) orelse null,
            }
            h.io.sleep(.fromMilliseconds(@intCast(h.poll_ms)), .awake) catch return error.Unavailable;
        };
        defer if (cwd) |c| h.gpa.free(c);
        const t = (h.openReady(cwd) catch return error.Unavailable) orelse return error.Unavailable;
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.sessions.items[sid].term = t;
        return t;
    }

    /// Runs `func(args)` on the UI thread; null when it cannot be posted.
    fn onUi(h: *AgentTerminals, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) ?@typeInfo(@TypeOf(func)).@"fn".return_type.? {
        const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Call = struct {
            args: @TypeOf(args),
            out: R = undefined,
            fn go(p: *anyopaque) void {
                const c: *@This() = @ptrCast(@alignCast(p));
                c.out = @call(.auto, func, c.args);
            }
        };
        var c: Call = .{ .args = args };
        if (!h.ui.run(h.ui.ctx, Call.go, &c)) return null;
        return c.out;
    }

    /// Under `mutex`: ends `j` and wakes its waiters.
    fn end(h: *AgentTerminals, j: *Job, st: Status) void {
        if (j.status != .running) return;
        j.status = st;
        if (j.term) |t| if (t.job == j) {
            t.job = null;
        };
        h.cond.broadcast(h.io);
    }

    // -- the UI thread --------------------------------------------------------

    const State = enum { ready, busy, inactive, gone };

    fn uiOpen(h: *AgentTerminals, cwd: ?[]const u8) ?*Term {
        const p = h.ui.open(h.ui.ctx, cwd) orelse return null;
        const blocks = p.view.blocks orelse {
            h.ui.close(h.ui.ctx, p);
            return null;
        };
        const t = h.gpa.create(Term) catch {
            h.ui.close(h.ui.ctx, p);
            return null;
        };
        t.* = .{ .host = h, .panel = p, .prev_output = p.on_output };
        blocks.addListener(.{ .ctx = t, .onEvent = onBlockEvent }) catch {
            h.gpa.destroy(t);
            h.ui.close(h.ui.ctx, p);
            return null;
        };
        p.on_output = .{ .ctx = t, .f = onOutput };
        p.on_destroy = .{ .ctx = t, .f = onDestroy };
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.terms.append(h.gpa, t) catch {
            detach(t, p);
            h.gpa.destroy(t);
            h.ui.close(h.ui.ctx, p);
            return null;
        };
        return t;
    }

    fn uiClose(t: *Term) void {
        const p = t.panel orelse return;
        t.host.ui.close(t.host.ui.ctx, p);
    }

    fn uiState(t: *Term) State {
        const p = t.panel orelse return .gone;
        if (p.ended.load(.acquire) or p.pty == null) return .gone;
        return switch (zg_terminal.agent.readiness(p.view.blocks orelse return .inactive)) {
            .ready => .ready,
            .busy => .busy,
            .inactive => .inactive,
        };
    }

    fn uiCwd(t: *Term) ?[]u8 {
        const p = t.panel orelse return null;
        if (p.view.cwd.items.len == 0) return null;
        return t.host.gpa.dupe(u8, p.view.cwd.items) catch null;
    }

    const Write = struct { h: *AgentTerminals, t: *Term, j: *Job, cwd: ?[]const u8 };

    /// Types the job's command (after a `cd` to its folder) at the prompt.
    fn uiWrite(w: *Write) bool {
        const h = w.h;
        const p = w.t.panel orelse return false;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(h.gpa);
        if (w.cwd) |dir|
            withCd(h.gpa, p.kind, dir, w.j.run.command, &line) catch return false
        else
            line.appendSlice(h.gpa, w.j.run.command) catch return false;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(h.gpa);
        zg_terminal.agent.commandBytes(h.gpa, &p.term, line.items, &bytes) catch return false;
        {
            h.mutex.lockUncancelable(h.io);
            defer h.mutex.unlock(h.io);
            w.t.job = w.j;
        }
        p.view.send(bytes.items);
        return true;
    }

    fn uiSend(t: *Term, bytes: []const u8) void {
        const p = t.panel orelse return;
        p.view.send(bytes);
    }

    fn uiKill(t: *Term) void {
        const p = t.panel orelse return;
        p.kill(.kill_tree);
    }

    fn onBlockEvent(ctx: *anyopaque, ev: BlockEvent) void {
        const t: *Term = @ptrCast(@alignCast(ctx));
        const p = t.panel orelse return;
        const blocks = p.view.blocks orelse return;
        const h = t.host;
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const j = t.job orelse return;
        if (!j.run.onEvent(blocks, ev)) return;
        switch (j.run.state) {
            .pending, .running => h.cond.broadcast(h.io),
            .finished => h.end(j, if (j.interrupted)
                .killed
            else if (j.run.exit) |code|
                .{ .exited = code }
            else
                .{ .failed = "the shell did not report an exit code" }),
            .abandoned => h.end(j, .killed),
        }
    }

    fn onOutput(ctx: *anyopaque) void {
        const t: *Term = @ptrCast(@alignCast(ctx));
        if (t.panel) |p| if (p.ended.load(.acquire)) t.host.lose(t);
        if (t.prev_output) |o| o.f(o.ctx);
    }

    fn onDestroy(ctx: *anyopaque) void {
        const t: *Term = @ptrCast(@alignCast(ctx));
        t.host.lose(t);
        t.panel = null;
    }

    /// The terminal's shell ended or its panel closed: a command still
    /// running there is killed.
    fn lose(h: *AgentTerminals, t: *Term) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        t.gone = true;
        if (t.job) |j| h.end(j, .killed);
    }

    fn detach(t: *Term, p: *TerminalPanel) void {
        if (p.view.blocks) |b| b.removeListener(t);
        p.on_output = t.prev_output;
        p.on_destroy = null;
    }
};

/// `command` run in `dir` (only if changing to it worked), in `kind`'s
/// syntax.
pub fn withCd(gpa: Allocator, kind: ShellKind, dir: []const u8, command: []const u8, out: *std.ArrayList(u8)) !void {
    switch (kind) {
        .cmd => {
            try out.appendSlice(gpa, "cd /d \"");
            for (dir) |c| if (c != '"') try out.append(gpa, c);
            try out.print(gpa, "\" && {s}", .{command});
        },
        .pwsh, .powershell => {
            try out.appendSlice(gpa, "Set-Location -LiteralPath '");
            for (dir) |c| {
                if (c == '\'') try out.append(gpa, '\'');
                try out.append(gpa, c);
            }
            try out.print(gpa, "'; if ($?) {{ {s} }}", .{command});
        },
        else => {
            try out.appendSlice(gpa, "cd -- '");
            for (dir) |c| if (c == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, c);
            try out.print(gpa, "' && {s}", .{command});
        },
    }
}

test "agent terminals: commands in a folder quote it for each shell" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try withCd(gpa, .bash, "/tmp/it's here", "ls", &out);
    try std.testing.expectEqualStrings("cd -- '/tmp/it'\\''s here' && ls", out.items);
    out.clearRetainingCapacity();
    try withCd(gpa, .cmd, "C:\\a b", "dir", &out);
    try std.testing.expectEqualStrings("cd /d \"C:\\a b\" && dir", out.items);
    out.clearRetainingCapacity();
    try withCd(gpa, .pwsh, "C:\\it's", "ls", &out);
    try std.testing.expectEqualStrings("Set-Location -LiteralPath 'C:\\it''s'; if ($?) { ls }", out.items);
}
