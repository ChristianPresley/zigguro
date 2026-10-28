//! SettleDetector (E07.F05.S01.T02): decides when the language servers'
//! diagnostics for documents are settled after an edit, for the agent's
//! edit→verify loop (`lsp_wait_for_diagnostics`, and `zg_ai`'s file
//! tools after every edit).
//!
//! The driver records per server and document (`set`, UI thread) the
//! newest version sent and the version the server last reported on (a
//! versioned push; the newest sent when a push has no version; a
//! finished pull), with when; per server its running work-done progress.
//! A document is settled when, for every running server that has it:
//!   1. nothing waits to be sent, and the last report is about the
//!      newest version sent;
//!   2. the server runs no work-done progress;
//!   3. nothing was sent or reported for `quiet` (`build_quiet` for a
//!      server that builds on save, unless a build ended since the send).
//! A server that does not publish again when nothing changed is taken as
//! settled with what it reported before once `quiet` × `silent_factor`
//! passed since the send (`heuristic`). Pull servers are asked at once.
//! With no server, the workspace's check task runs instead
//! (`BuildCheck`, one run at a time; a request during a run gets its
//! result). Waiting never passes the timeout: what is known comes back
//! with the reason.

const SettleDetector = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = @import("Store.zig");
const render = @import("../agent/render.zig");

pub const AgentDiag = render.AgentDiag;

pub const Options = struct {
    /// Give up waiting after this long and report what is known.
    timeout: Io.Duration = .fromSeconds(10),
    /// Settled once nothing was sent or reported for this long.
    quiet: Io.Duration = .fromMilliseconds(300),
    /// `quiet` for a server that builds on save (ZLS): its build's
    /// diagnostics come in a later publish.
    build_quiet: Io.Duration = .fromMilliseconds(1500),
    /// A server that sent nothing for the newest version counts as
    /// settled after `quiet` times this.
    silent_factor: u32 = 3,
    /// An edit sent this long before the call still counts as this edit's
    /// (the UI may flush it after the tool asks).
    slack: Io.Duration = .fromMilliseconds(250),
    poll: Io.Duration = .fromMilliseconds(15),
    /// Diagnostics listed in a summary.
    max_listed: usize = 20,
    /// Wakes the UI thread to send pulls (`takePulls`).
    waker: zg_core.runtime.Waker = .noop,
    clock: Clock = .{},
};

/// Time for the waits (tests drive it).
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    /// `.awake` nanoseconds.
    now: *const fn (ctx: ?*anyopaque, io: Io) i96 = realNow,
    sleep: *const fn (ctx: ?*anyopaque, io: Io, d: Io.Duration) Io.Cancelable!void = realSleep,

    fn realNow(_: ?*anyopaque, io: Io) i96 {
        return Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    }
    fn realSleep(_: ?*anyopaque, io: Io, d: Io.Duration) Io.Cancelable!void {
        return io.sleep(d, .awake);
    }
};

/// One document as one running server knows it.
pub const Row = struct {
    /// Store key (borrowed from the driver while in the table).
    key: []const u8,
    server: u32,
    /// The newest LSP version sent, and when (`.awake` ns).
    sent: i32 = 0,
    sent_ns: i96 = 0,
    /// The version the server last reported on, and when.
    reported: ?i32 = null,
    report_ns: i96 = 0,
    /// The editor has edits not sent to this server yet.
    dirty: bool = false,
};

pub const Status = enum { starting, running, crashed, down };

pub const ServerState = struct {
    id: u32,
    status: Status = .running,
    /// Work-done progress running.
    progress: u32 = 0,
    /// Seen running a build (ZLS build-on-save).
    builds: bool = false,
    /// When its last build progress ended.
    build_end_ns: i96 = 0,
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(s: *const ServerState) []const u8 {
        return s.name_buf[0..s.name_len];
    }

    pub fn setName(s: *ServerState, n: []const u8) void {
        s.name_len = @intCast(@min(n.len, s.name_buf.len));
        @memcpy(s.name_buf[0..s.name_len], n[0..s.name_len]);
    }
};

pub const BuildPolicy = enum { never, if_no_server, always };

pub const Request = struct {
    /// Absolute paths.
    paths: []const []const u8,
    timeout: ?Io.Duration = null,
    quiet: ?Io.Duration = null,
    build_check: BuildPolicy = .if_no_server,
};

pub const Reason = enum { timeout_indexing, timeout_no_publish, no_server, server_crashed };

/// A run of the workspace's check task.
pub const BuildSummary = struct {
    /// What ran (`zig build check`).
    label: []const u8,
    ok: bool,
    exit_code: ?u8 = null,
    duration_ns: u64 = 0,
    timed_out: bool = false,
    /// Why it could not run.
    err: ?[]const u8 = null,
};

/// Runs the workspace's check task within `timeout`, putting its
/// problems into the store (under a task owner) before it returns.
pub const BuildCheck = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, timeout: Io.Duration) anyerror!BuildSummary,
};

pub const Result = struct {
    /// Every server with the documents answered for their newest text.
    settled: bool = false,
    reason: ?Reason = null,
    /// A server sent nothing new; its earlier report stands.
    heuristic: bool = false,
    /// The server that crashed (`.server_crashed`).
    crashed: ?[]const u8 = null,
    /// Errors and warnings, by path, line, severity and column.
    diags: []const AgentDiag = &.{},
    errors: usize = 0,
    warnings: usize = 0,
    build: ?BuildSummary = null,
    waited_ns: u64 = 0,
};

gpa: Allocator,
io: Io,
store: *Store,
opts: Options,
/// The check task for documents no server has (null: none).
build: ?BuildCheck = null,
mutex: Io.Mutex = .init,
rows: std.ArrayList(Row) = .empty,
servers: std.ArrayList(ServerState) = .empty,
/// Store keys that want a pull now (owned).
pulls: std.ArrayList([]u8) = .empty,
build_running: bool = false,
build_gen: u64 = 0,
build_last: BuildSummary = .{ .label = "", .ok = false },
build_label: [64]u8 = undefined,
build_err: [64]u8 = undefined,

pub fn init(gpa: Allocator, io: Io, store: *Store, opts: Options) SettleDetector {
    return .{ .gpa = gpa, .io = io, .store = store, .opts = opts };
}

pub fn deinit(sd: *SettleDetector) void {
    sd.rows.deinit(sd.gpa);
    sd.servers.deinit(sd.gpa);
    for (sd.pulls.items) |k| sd.gpa.free(k);
    sd.pulls.deinit(sd.gpa);
}

/// Replaces the tables (UI thread). Row keys stay borrowed until the next
/// call.
pub fn set(sd: *SettleDetector, rows: []const Row, servers: []const ServerState) Allocator.Error!void {
    sd.mutex.lockUncancelable(sd.io);
    defer sd.mutex.unlock(sd.io);
    sd.rows.clearRetainingCapacity();
    try sd.rows.appendSlice(sd.gpa, rows);
    sd.servers.clearRetainingCapacity();
    try sd.servers.appendSlice(sd.gpa, servers);
}

/// Moves the keys that want a pull now into `out` (UI thread; the caller
/// frees them with the detector's allocator).
pub fn takePulls(sd: *SettleDetector, out: *std.ArrayList([]u8)) Allocator.Error!void {
    sd.mutex.lockUncancelable(sd.io);
    defer sd.mutex.unlock(sd.io);
    try out.appendSlice(sd.gpa, sd.pulls.items);
    sd.pulls.clearRetainingCapacity();
}

fn askPulls(sd: *SettleDetector, keys: []const []const u8) Allocator.Error!void {
    {
        sd.mutex.lockUncancelable(sd.io);
        defer sd.mutex.unlock(sd.io);
        try sd.pulls.ensureUnusedCapacity(sd.gpa, keys.len);
        for (keys) |k| sd.pulls.appendAssumeCapacity(try sd.gpa.dupe(u8, k));
    }
    sd.opts.waker.wake();
}

fn now(sd: *const SettleDetector, io: Io) i96 {
    return sd.opts.clock.now(sd.opts.clock.ctx, io);
}

fn sleep(sd: *const SettleDetector, io: Io, d: Io.Duration) Io.Cancelable!void {
    return sd.opts.clock.sleep(sd.opts.clock.ctx, io, d);
}

// ------------------------------------------------------------- waiting

const Eval = struct {
    settled: bool = true,
    heuristic: bool = false,
    /// An unsettled server is running progress.
    indexing: bool = false,
    /// Some document has no server.
    no_server: bool = false,
    crashed: ?u32 = null,
};

/// Whether `keys` are settled at `t` (the wait began at `t0`); `seen`
/// gathers the servers that had them.
fn evaluate(sd: *SettleDetector, arena: Allocator, keys: []const []const u8, seen: *std.AutoArrayHashMapUnmanaged(u32, void), t0: i96, t: i96, quiet: Io.Duration) Allocator.Error!Eval {
    sd.mutex.lockUncancelable(sd.io);
    defer sd.mutex.unlock(sd.io);
    var e: Eval = .{};
    for (keys) |key| {
        var any = false;
        for (sd.rows.items) |r| {
            if (!std.mem.eql(u8, r.key, key)) continue;
            const s = sd.server(r.server) orelse continue;
            if (s.status != .running) continue;
            any = true;
            try seen.put(arena, r.server, {});
            switch (rowState(sd.opts, r, s.*, t0, t, quiet)) {
                .settled => {},
                .heuristic => e.heuristic = true,
                .waiting => {
                    e.settled = false;
                    if (s.progress > 0) e.indexing = true;
                },
            }
        }
        if (any) continue;
        // A server still starting may take the document.
        for (sd.servers.items) |s| {
            if (s.status != .starting) continue;
            e.settled = false;
            e.indexing = true;
            break;
        } else {
            e.no_server = true;
        }
    }
    for (seen.keys()) |id| if (sd.server(id)) |s| if (s.status == .crashed) {
        e.crashed = id;
    };
    return e;
}

fn server(sd: *SettleDetector, id: u32) ?*ServerState {
    for (sd.servers.items) |*s| if (s.id == id) return s;
    return null;
}

const RowState = enum { settled, heuristic, waiting };

/// One server's answer for one document (rules 1-3 above).
pub fn rowState(o: Options, r: Row, s: ServerState, t0: i96, t: i96, quiet: Io.Duration) RowState {
    if (r.dirty or s.progress > 0) return .waiting;
    // An edit made just before the call may not have gone out yet.
    if (r.sent_ns + o.slack.nanoseconds < t0 and t < t0 + o.slack.nanoseconds) return .waiting;
    const last = @max(r.sent_ns, r.report_ns);
    if (r.reported != null and r.reported.? >= r.sent) {
        if (t - last < quiet.nanoseconds) return .waiting;
        if (s.builds and t - last < o.build_quiet.nanoseconds and s.build_end_ns <= r.sent_ns) return .waiting;
        return .settled;
    }
    if (t - last >= quiet.nanoseconds * o.silent_factor) return .heuristic;
    return .waiting;
}

/// Waits for `req.paths` to settle (or the timeout), runs the check task
/// when the policy asks, and returns their errors and warnings. Any
/// thread but the UI's.
pub fn wait(sd: *SettleDetector, io: Io, arena: Allocator, req: Request) (Allocator.Error || Io.Cancelable)!Result {
    const t0 = sd.now(io);
    const timeout = req.timeout orelse sd.opts.timeout;
    const quiet = req.quiet orelse sd.opts.quiet;
    const deadline = t0 + timeout.nanoseconds;
    const keys = try arena.alloc([]const u8, req.paths.len);
    for (keys, req.paths) |*k, p| k.* = try sd.store.keyOfPath(arena, p);
    try sd.askPulls(keys);

    var seen: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    var r: Result = .{};
    var e: Eval = undefined;
    var t = t0;
    while (true) {
        t = sd.now(io);
        e = try sd.evaluate(arena, keys, &seen, t0, t, quiet);
        if (e.crashed) |id| {
            r.reason = .server_crashed;
            sd.mutex.lockUncancelable(sd.io);
            defer sd.mutex.unlock(sd.io);
            r.crashed = if (sd.server(id)) |s| try arena.dupe(u8, s.name()) else "the language server";
            break;
        }
        if (e.settled) {
            r.settled = true;
            r.heuristic = e.heuristic;
            break;
        }
        if (t >= deadline) {
            r.reason = if (e.indexing) .timeout_indexing else .timeout_no_publish;
            break;
        }
        try sd.sleep(io, sd.opts.poll);
    }
    if (r.reason == null and e.no_server) r.reason = .no_server;
    const run_build = switch (req.build_check) {
        .never => false,
        .always => true,
        .if_no_server => e.no_server,
    };
    if (run_build) {
        const left: i96 = @max(deadline - sd.now(io), sd.opts.poll.nanoseconds);
        r.build = try sd.buildCheck(io, arena, .fromNanoseconds(left));
    }
    try sd.collect(arena, keys, req.paths, &r);
    r.waited_ns = @intCast(@max(0, sd.now(io) - t0));
    return r;
}

/// The errors and warnings of `keys` (shown as `paths`), sorted.
fn collect(sd: *SettleDetector, arena: Allocator, keys: []const []const u8, paths: []const []const u8, r: *Result) Allocator.Error!void {
    const snap = sd.store.acquire();
    defer snap.release();
    var all: std.ArrayList(*const Store.Diagnostic) = .empty;
    var out: std.ArrayList(AgentDiag) = .empty;
    for (keys, paths) |k, p| {
        all.clearRetainingCapacity();
        try snap.forKey(k, arena, &all);
        for (all.items) |d| {
            switch (d.severity) {
                .err => r.errors += 1,
                .warning => r.warnings += 1,
                else => continue,
            }
            try out.append(arena, .{
                .path = p,
                .line = d.start.line,
                .column = d.start.character,
                .severity = d.severity.label(),
                .message = d.message,
                .source = d.source,
                .code = d.code,
            });
        }
    }
    std.mem.sort(AgentDiag, out.items, {}, lessDiag);
    r.diags = out.items;
}

fn lessDiag(_: void, a: AgentDiag, b: AgentDiag) bool {
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.line != b.line) return a.line < b.line;
    const ra = render.severityRank(a.severity);
    const rb = render.severityRank(b.severity);
    if (ra != rb) return ra < rb;
    return a.column < b.column;
}

/// Runs the check task, or waits for the run in progress and takes its
/// result; null without one.
fn buildCheck(sd: *SettleDetector, io: Io, arena: Allocator, timeout: Io.Duration) (Allocator.Error || Io.Cancelable)!?BuildSummary {
    const bc = sd.build orelse return null;
    sd.mutex.lockUncancelable(sd.io);
    if (sd.build_running) {
        const gen = sd.build_gen;
        sd.mutex.unlock(sd.io);
        const deadline = sd.now(io) + timeout.nanoseconds;
        while (true) {
            try sd.sleep(io, sd.opts.poll);
            {
                sd.mutex.lockUncancelable(sd.io);
                defer sd.mutex.unlock(sd.io);
                if (sd.build_gen != gen) {
                    var s = sd.build_last;
                    s.label = try arena.dupe(u8, s.label);
                    if (s.err) |x| s.err = try arena.dupe(u8, x);
                    return s;
                }
            }
            if (sd.now(io) >= deadline) return .{ .label = "the check task", .ok = false, .timed_out = true };
        }
    }
    sd.build_running = true;
    sd.mutex.unlock(sd.io);
    var s = bc.run(bc.ctx, io, arena, timeout) catch |err| s: {
        if (err == error.Canceled) {
            sd.finishBuild(null);
            return error.Canceled;
        }
        break :s BuildSummary{ .label = "the check task", .ok = false, .err = @errorName(err) };
    };
    s.label = try arena.dupe(u8, s.label);
    sd.finishBuild(s);
    return s;
}

/// Ends a check-task run (null: canceled); waiting requests take it.
pub fn finishBuild(sd: *SettleDetector, s: ?BuildSummary) void {
    sd.mutex.lockUncancelable(sd.io);
    defer sd.mutex.unlock(sd.io);
    sd.build_running = false;
    sd.build_gen += 1;
    // Waiters copy it out; its texts live in the detector.
    const v = s orelse BuildSummary{ .label = "the check task", .ok = false, .err = "Canceled" };
    sd.build_last = v;
    sd.build_last.label = keep(&sd.build_label, v.label);
    sd.build_last.err = if (v.err) |x| keep(&sd.build_err, x) else null;
}

fn keep(buf: []u8, text: []const u8) []const u8 {
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

// ------------------------------------------------------------ rendering

/// The result for an agent: "2 errors, 1 warning:" and one line each
/// (paths relative to `root`), or "No errors or warnings in a.zig.", then
/// what the wait could not tell.
pub fn renderResult(sd: *const SettleDetector, arena: Allocator, r: Result, paths: []const []const u8, root: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var names: std.ArrayList(u8) = .empty;
    for (paths, 0..) |p, i| {
        if (i > 0) try names.appendSlice(arena, ", ");
        try names.appendSlice(arena, try render.shownPath(arena, root, p));
    }
    if (r.diags.len == 0) {
        try out.print(arena, "No errors or warnings in {s}.", .{names.items});
    } else {
        try out.print(arena, "{d} error{s}, {d} warning{s}:\n", .{ r.errors, plural(r.errors), r.warnings, plural(r.warnings) });
        const n = @min(r.diags.len, sd.opts.max_listed);
        try out.appendSlice(arena, try render.renderDiagnostics(arena, r.diags[0..n], .{ .root = root }));
        if (r.diags.len > n) try out.print(arena, "\n… and {d} more (lsp_diagnostics lists them)", .{r.diags.len - n});
    }
    if (r.heuristic) try out.appendSlice(arena, "\n(A server sent nothing new for this version; its last report is shown.)");
    if (r.reason) |why| switch (why) {
        .timeout_indexing => try out.print(arena, "\nTimed out after {d:.1} s while the language server was still busy (indexing); this may be out of date.", .{seconds(r.waited_ns)}),
        .timeout_no_publish => try out.print(arena, "\nTimed out after {d:.1} s with no new diagnostics; this may be out of date.", .{seconds(r.waited_ns)}),
        .server_crashed => try out.print(arena, "\n{s} crashed while checking; this is what it reported before.", .{r.crashed orelse "The language server"}),
        .no_server => if (r.build == null) try out.print(arena, "\nNo language server checks {s}, and there is no check task to run.", .{names.items}),
    };
    if (r.build) |b| {
        try out.print(arena, "\nRan {s}: ", .{b.label});
        if (b.timed_out) {
            try out.appendSlice(arena, "timed out");
        } else if (b.err) |e| {
            try out.print(arena, "could not run ({s})", .{e});
        } else if (b.ok) {
            try out.appendSlice(arena, "passed");
        } else if (b.exit_code) |c| {
            try out.print(arena, "failed (exit {d})", .{c});
        } else {
            try out.appendSlice(arena, "failed");
        }
        if (b.duration_ns > 0) try out.print(arena, " in {d:.1} s", .{seconds(b.duration_ns)});
        try out.append(arena, '.');
    }
    return out.items;
}

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// Waits for the servers to settle on `abs` (an absolute path) after an
/// edit, then summarizes its errors and warnings; null when there are
/// none and nothing is in doubt. Any thread but the UI's.
pub fn afterAgentEdit(sd: *SettleDetector, io: Io, arena: Allocator, abs: []const u8) (Allocator.Error || Io.Cancelable)!?[]const u8 {
    const paths = try arena.dupe([]const u8, &.{abs});
    const r = try sd.wait(io, arena, .{ .paths = paths });
    const quiet = r.reason == null or (r.reason.? == .no_server and r.build == null);
    if (r.diags.len == 0 and !r.heuristic and quiet) return null;
    return try sd.renderResult(arena, r, paths, std.fs.path.dirname(abs) orelse "");
}

/// For `zg_ai.tools.builtin.files.Diagnostics.after_edit` (`ctx` is the
/// detector).
pub fn afterEdit(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8) anyerror!?[]const u8 {
    const sd: *SettleDetector = @ptrCast(@alignCast(ctx));
    return sd.afterAgentEdit(io, arena, abs);
}
