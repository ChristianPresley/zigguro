//! `run_command`, `command_output` and `kill_command` (E10.F06.S03.T02):
//! shell commands in the agent's own terminal.
//!
//! - Each agent gets one terminal session, created on its first command
//!   and visible unless the user turned that off.
//! - A command waits up to `timeout_ms` (default 120 s, at most 600 s).
//!   On timeout it keeps running in the background and the result gives
//!   its handle, except `sleep`, which is stopped. `background: true`
//!   returns the handle at once. Background commands are stopped after
//!   30 minutes.
//! - A non-zero exit code is data, not an error: `is_error` is only set
//!   when the command could not run or was denied.
//! - Committed lines stream to the call's progress sink. Results keep the
//!   last 30,000 characters; earlier lines stay readable with
//!   `command_output`, which pages forward from `since_line`.
//! - Canceling the call interrupts the command (Ctrl+C, SIGTERM, then the
//!   process tree is killed).

const std = @import("std");
const proto = @import("zg_ai_proto");
const deps = @import("../../loop/deps.zig");
const ratelimit = @import("../../provider/ratelimit.zig");
const registry = @import("../registry.zig");
const host_mod = @import("terminal_host.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const TerminalHost = host_mod.TerminalHost;

pub const Config = struct {
    default_timeout_ms: u64 = 120_000,
    max_timeout_ms: u64 = 600_000,
    background_cap_ms: u64 = 30 * std.time.ms_per_min,
    max_output_chars: usize = 30_000,
    max_output_wait_ms: u64 = 60_000,
    /// How long `kill_command` waits for the command to end.
    kill_wait_ms: u64 = 5_000,
    /// Agent terminals are shown to the user (a setting).
    visible: bool = true,
    clock: ratelimit.Clock = .real,
};

/// What E16 decides a command by.
pub const CommandRequest = struct {
    command: []const u8,
    cwd: ?[]const u8,
    session: host_mod.SessionId,
    agent: proto.AgentRef,
};

/// E16's command policy (allowlists, the sandbox); null allows all.
pub const CommandPolicy = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, io: Io, req: CommandRequest) Io.Cancelable!deps.Decision,
};

const Job = struct {
    id: host_mod.JobId,
    agent: proto.AgentRef,
    started_ms: i64,
    /// Lines already returned.
    read_to: usize = 0,
    background: bool = false,
};

const AgentKey = struct { session: u128, agent: u32 };

pub const run_schema =
    \\{"type":"object","properties":{"command":{"type":"string"},"description":{"type":"string","maxLength":120},"cwd":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1000,"maximum":600000},"background":{"type":"boolean","default":false}},"required":["command"],"additionalProperties":false}
;
pub const output_schema =
    \\{"type":"object","properties":{"handle":{"type":"string"},"since_line":{"type":"integer"},"wait_ms":{"type":"integer","maximum":60000}},"required":["handle"]}
;
pub const kill_schema =
    \\{"type":"object","properties":{"handle":{"type":"string"}},"required":["handle"]}
;

pub const RunTools = struct {
    gpa: Allocator,
    io: Io,
    host: TerminalHost,
    cfg: Config,
    policy: ?CommandPolicy = null,
    mutex: Io.Mutex = .init,
    sessions: std.AutoHashMapUnmanaged(AgentKey, host_mod.SessionId) = .empty,
    /// Handle `cmd_<i+1>` is `jobs[i]`.
    jobs: std.ArrayList(Job) = .empty,
    spec_buf: [3]proto.ToolSpec = undefined,

    pub fn init(gpa: Allocator, io: Io, host: TerminalHost, cfg: Config) RunTools {
        return .{ .gpa = gpa, .io = io, .host = host, .cfg = cfg };
    }

    pub fn deinit(r: *RunTools) void {
        r.sessions.deinit(r.gpa);
        r.jobs.deinit(r.gpa);
    }

    /// The three specs; they point at `r`.
    pub fn specs(r: *RunTools) []const proto.ToolSpec {
        r.spec_buf = .{
            .{
                .name = "run_command",
                .description = "Runs a shell command in your terminal and returns its output and exit code. The working directory persists between commands. Waits up to timeout_ms (default 120000); a command still running then keeps running in the background and you get a handle for command_output. Set background to start a long-running command (a server, a watcher) and return at once.",
                .input_schema_json = run_schema,
                .read_only = false,
                .effects = .{ .executes = true },
                .permission = .execute,
                .handler = .{ .ctx = r, .call = runCommand },
            },
            .{
                .name = "command_output",
                .description = "Returns new output lines and the status of a command started by run_command, by handle. since_line re-reads from that line; wait_ms waits for the command to finish first (at most 60000).",
                .input_schema_json = output_schema,
                .read_only = true,
                .effects = .{ .read_only = true },
                .handler = .{ .ctx = r, .call = commandOutput },
            },
            .{
                .name = "kill_command",
                .description = "Stops a command started by run_command, by handle, along with the processes it started.",
                .input_schema_json = kill_schema,
                .read_only = false,
                .permission = .control,
                .handler = .{ .ctx = r, .call = killCommand },
            },
        };
        return &r.spec_buf;
    }

    /// A built-in tool source with the three tools.
    pub fn source(r: *RunTools) registry.ToolSource {
        return .{ .name = "run", .ctx = r, .list = listSpecs, .kind = .builtin };
    }

    fn listSpecs(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const r: *RunTools = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, r.specs());
    }

    fn sessionFor(r: *RunTools, agent: proto.AgentRef) host_mod.Error!host_mod.SessionId {
        const key: AgentKey = .{ .session = agent.session, .agent = agent.agent };
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.sessions.get(key)) |s| return s;
        const s = try r.host.create(r.io, agent, r.cfg.visible);
        try r.sessions.put(r.gpa, key, s);
        return s;
    }

    fn addJob(r: *RunTools, j: Job) Allocator.Error!usize {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        try r.jobs.append(r.gpa, j);
        return r.jobs.items.len;
    }

    /// A copy of the job behind `handle`, if it belongs to `agent`.
    fn jobFor(r: *RunTools, handle: []const u8, agent: proto.AgentRef) ?struct { n: usize, job: Job } {
        if (!std.mem.startsWith(u8, handle, "cmd_")) return null;
        const n = std.fmt.parseInt(usize, handle[4..], 10) catch return null;
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (n == 0 or n > r.jobs.items.len) return null;
        const j = r.jobs.items[n - 1];
        if (j.agent.session != agent.session or j.agent.agent != agent.agent) return null;
        return .{ .n = n, .job = j };
    }

    fn update(r: *RunTools, n: usize, read_to: ?usize, background: ?bool) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const j = &r.jobs.items[n - 1];
        if (read_to) |x| j.read_to = x;
        if (background) |b| j.background = b;
    }

    /// Stops background commands past the 30-minute cap.
    pub fn reap(r: *RunTools) void {
        const now = r.cfg.clock.now(r.io);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.jobs.items) |j| {
            if (!j.background or r.host.status(j.id) != .running) continue;
            if (now - j.started_ms >= @as(i64, @intCast(r.cfg.background_cap_ms))) r.host.interrupt(r.io, j.id);
        }
    }

    fn runCommand(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const r: *RunTools = @ptrCast(@alignCast(ctx));
        const a = c.arena;
        r.reap();
        const command = str(c.input, "command") orelse return errOut(a, "run_command needs a \"command\" string.");
        if (std.mem.trim(u8, command, " \t\r\n").len == 0) return errOut(a, "The command is empty.");
        const cwd = str(c.input, "cwd");
        const timeout_ms: u64 = if (int(c.input, "timeout_ms")) |t| std.math.clamp(@as(u64, @intCast(@max(t, 0))), 1000, r.cfg.max_timeout_ms) else r.cfg.default_timeout_ms;
        const background = if (c.input == .object) if (c.input.object.get("background")) |v| v == .bool and v.bool else false else false;

        const session = r.sessionFor(c.agent) catch |e| return errOut(a, try std.fmt.allocPrint(a, "Could not open a terminal: {s}", .{@errorName(e)}));
        if (r.policy) |p| switch (p.check(p.ctx, c.io, .{ .command = command, .cwd = cwd, .session = session, .agent = c.agent }) catch return error.Canceled) {
            .allow => {},
            .deny => |why| return errOut(a, try std.fmt.allocPrint(a, "Permission denied: {s}", .{why})),
        };
        const id = r.host.start(c.io, session, command, cwd) catch |e| return errOut(a, try std.fmt.allocPrint(a, "Could not start the command: {s}", .{@errorName(e)}));
        const n = try r.addJob(.{ .id = id, .agent = c.agent, .started_ms = r.cfg.clock.now(r.io), .background = background });
        const handle = try std.fmt.allocPrint(a, "cmd_{d}", .{n});
        if (background) return textOut(a, try std.fmt.allocPrint(a, "Started in the background. Handle: {s}. Use command_output to read its output and kill_command to stop it.", .{handle}));

        var prog: Progress = .{ .sink = c.progress, .arena = a };
        const st = r.host.wait(c.io, id, timeout_ms, if (c.progress != null) prog.lineSink() else null) catch {
            r.host.interrupt(r.io, id);
            return error.Canceled;
        };
        const lines = try r.host.lines(a, id, 0);
        r.update(n, lines.len, null);
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        if (st == .running) {
            if (startsWithSleep(command)) {
                r.host.interrupt(r.io, id);
                _ = r.host.wait(r.io, id, r.cfg.kill_wait_ms, null) catch {};
                return textOut(a, try std.fmt.allocPrint(a, "Command did not complete within its {d}s timeout and was stopped.", .{timeout_ms / 1000}));
            }
            r.update(n, null, true);
            w.print("Command did not complete within its {d}s timeout and was moved to the background. Handle: {s}. Output so far:\n", .{ timeout_ms / 1000, handle }) catch return error.OutOfMemory;
            writeBounded(w, lines, 0, r.cfg.max_output_chars, handle) catch return error.OutOfMemory;
            return textOut(a, out.written());
        }
        if (st == .failed) return errOut(a, try std.fmt.allocPrint(a, "The command could not run: {s}", .{st.failed}));
        writeBounded(w, lines, 0, r.cfg.max_output_chars, handle) catch return error.OutOfMemory;
        writeStatus(w, st) catch return error.OutOfMemory;
        var o = try textOut(a, out.written());
        o.ui_hint = .terminal;
        return o;
    }

    fn commandOutput(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const r: *RunTools = @ptrCast(@alignCast(ctx));
        const a = c.arena;
        r.reap();
        const handle = str(c.input, "handle") orelse return errOut(a, "command_output needs a \"handle\" string.");
        const found = r.jobFor(handle, c.agent) orelse return errOut(a, try std.fmt.allocPrint(a, "Unknown handle: {s}", .{handle}));
        if (int(c.input, "wait_ms")) |ms| if (ms > 0 and r.host.status(found.job.id) == .running) {
            _ = r.host.wait(c.io, found.job.id, @min(@as(u64, @intCast(ms)), r.cfg.max_output_wait_ms), null) catch return error.Canceled;
        };
        const since: usize = if (int(c.input, "since_line")) |s| @intCast(@max(s, 0)) else found.job.read_to;
        const st = r.host.status(found.job.id);
        const lines = try r.host.lines(a, found.job.id, since);
        // Pages forward from `since`: the first lines that fit.
        var shown: usize = 0;
        var total: usize = 0;
        while (shown < lines.len and (shown == 0 or total + lines[shown].len + 1 <= r.cfg.max_output_chars)) : (shown += 1) total += lines[shown].len + 1;
        r.update(found.n, since + shown, null);
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        writeBounded(w, lines[0..shown], since, std.math.maxInt(usize), handle) catch return error.OutOfMemory;
        if (shown < lines.len) {
            w.print("[{d} more lines follow]\n", .{lines.len - shown}) catch return error.OutOfMemory;
        } else if (st == .running) {
            w.writeAll("Status: running\n") catch return error.OutOfMemory;
        } else writeStatus(w, st) catch return error.OutOfMemory;
        w.print("Next since_line: {d}", .{since + shown}) catch return error.OutOfMemory;
        return textOut(a, out.written());
    }

    fn killCommand(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const r: *RunTools = @ptrCast(@alignCast(ctx));
        const a = c.arena;
        const handle = str(c.input, "handle") orelse return errOut(a, "kill_command needs a \"handle\" string.");
        const found = r.jobFor(handle, c.agent) orelse return errOut(a, try std.fmt.allocPrint(a, "Unknown handle: {s}", .{handle}));
        if (r.host.status(found.job.id) != .running) return textOut(a, try std.fmt.allocPrint(a, "{s} has already finished.", .{handle}));
        r.host.interrupt(c.io, found.job.id);
        const st = r.host.wait(c.io, found.job.id, r.cfg.kill_wait_ms, null) catch return error.Canceled;
        if (st == .running) return textOut(a, try std.fmt.allocPrint(a, "Sent a stop request to {s}; it is still running.", .{handle}));
        return textOut(a, try std.fmt.allocPrint(a, "Stopped {s}.", .{handle}));
    }
};

/// `sleep` commands are stopped on timeout instead of moved to the
/// background.
fn startsWithSleep(command: []const u8) bool {
    const t = std.mem.trimStart(u8, command, " \t");
    return std.mem.startsWith(u8, t, "sleep") and (t.len == 5 or t[5] == ' ' or t[5] == '\t');
}

/// Writes `lines` (numbered from `first`), keeping the tail that fits in
/// `max_chars` and naming what was left out.
fn writeBounded(w: *std.Io.Writer, lines: []const []const u8, first: usize, max_chars: usize, handle: []const u8) std.Io.Writer.Error!void {
    var keep: usize = lines.len;
    var total: usize = 0;
    while (keep > 0) {
        const len = lines[keep - 1].len + 1;
        if (total + len > max_chars) break;
        total += len;
        keep -= 1;
    }
    if (keep > 0) try w.print("[{d} earlier lines omitted; read them with command_output handle {s} since_line {d}]\n", .{ keep, handle, first });
    for (lines[keep..]) |l| {
        try w.writeAll(l);
        try w.writeByte('\n');
    }
}

fn writeStatus(w: *std.Io.Writer, st: host_mod.Status) std.Io.Writer.Error!void {
    switch (st) {
        .running => {},
        .exited => |code| try w.print("Exit code: {d}\n", .{code}),
        .killed => try w.writeAll("The command was stopped.\n"),
        .failed => |msg| try w.print("The command could not run: {s}\n", .{msg}),
    }
}

/// Forwards committed lines to the call's progress sink.
const Progress = struct {
    sink: ?proto.tool.ProgressSink,
    arena: Allocator,

    fn lineSink(p: *Progress) host_mod.LineSink {
        return .{ .ctx = p, .line = line };
    }

    fn line(ctx: *anyopaque, text: []const u8) void {
        const p: *Progress = @ptrCast(@alignCast(ctx));
        const s = p.sink orelse return;
        var buf: [4096]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = '\n';
        s.emit(s.ctx, buf[0 .. n + 1]);
    }
};

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn int(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(std.math.clamp(f, -1e15, 1e15)) else null,
        else => null,
    };
}

fn textOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, false) catch error.OutOfMemory;
}

fn errOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, true) catch error.OutOfMemory;
}
