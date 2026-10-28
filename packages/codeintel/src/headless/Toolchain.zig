//! The language tooling composed without a GUI (E07.F05.S01.T04), for
//! `zg lsp` and the built-in MCP servers: the server manager, the
//! diagnostics store and driver with its settle detector, background
//! documents and the agents' `CodeIntel`, plus the check task when a
//! `HeadlessTasks` is given.
//!
//! There is no UI thread: the thread that calls the tools is it. Every
//! hop `CodeIntel` makes to the UI thread runs inline after a `pump`
//! (manager tick, then diagnostics tick), and the settle detector's
//! polling sleep pumps first, so waits make progress on that one thread.
//!
//! Servers start lazily, when a file of their language is first used,
//! and `deinit` shuts them all down. An untrusted workspace still gets
//! the built-in servers (workspace server commands are not read here at
//! all), but ZLS does not build on save and no check task runs.
//!
//! Must not move once `init` returned.

const Toolchain = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_perf = @import("zg_perf");
const zg_syntax = @import("zg_syntax");
const zg_editor = @import("zg_editor");
const zg_dap = @import("zg_dap");
const Manager = @import("../Manager.zig");
const Registry = @import("../registry/Registry.zig");
const Store = @import("../diagnostics/Store.zig");
const Driver = @import("../diagnostics/Driver.zig");
const SettleDetector = @import("../diagnostics/settle.zig");
const ZlsSupport = @import("../features/zls_support.zig");
const CodeIntel = @import("../agent/CodeIntel.zig");
const BackgroundDocs = @import("../agent/background_docs.zig");
const tools = @import("../agent/tools.zig");
const language = @import("../language.zig");
const HeadlessHost = @import("HeadlessHost.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const DocumentRegistry = zg_editor.model.api.registry.DocumentRegistry;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const HeadlessTasks = zg_dap.headless.HeadlessTasks;
const Problem = zg_dap.tasks.matcher.Problem;

pub const Options = struct {
    /// Workspace folders, absolute; the first is the root.
    roots: []const []const u8,
    env: ?*const std.process.Environ.Map = null,
    /// Server messages and questions (null: none shown, none answered).
    host: ?*HeadlessHost = null,
    trusted: bool = true,
    /// `zig.path` (null: `zig` on PATH).
    zig_exe: ?[]const u8 = null,
    /// Runs the check task for files no server checks (null: none).
    tasks: ?*HeadlessTasks = null,
    /// Server definitions over the built-ins (tests).
    overrides: []const Registry.Override = &.{},
    init_timeout: Io.Duration = .fromSeconds(30),
    /// How long a tool call may take.
    timeout: Io.Duration = .fromSeconds(15),
};

gpa: Allocator,
rt: *zg_core.Runtime,
opts: Options,
reg: Registry,
docs: DocumentRegistry,
store: Store,
mgr: Manager,
driver: Driver,
zls: ZlsSupport,
langs: ?zg_syntax.Registry,
bg: BackgroundDocs,
ci: CodeIntel,
/// Documents opened by `open`, released at `deinit`.
held: std.ArrayList(DocHandle) = .empty,
/// The store owner of the check task's last run.
check_owner: ?u32 = null,

pub fn init(tc: *Toolchain, rt: *zg_core.Runtime, opts: Options) !void {
    const gpa = rt.gpa;
    tc.* = .{
        .gpa = gpa,
        .rt = rt,
        .opts = opts,
        .reg = try .init(gpa, .{ .overrides = opts.overrides }),
        .docs = .init(gpa, .native),
        .store = undefined,
        .mgr = undefined,
        .driver = undefined,
        .zls = .init(gpa, rt.io, opts.env),
        .langs = zg_syntax.defaultRegistry(gpa) catch null,
        .bg = undefined,
        .ci = undefined,
    };
    errdefer {
        if (tc.langs) |*l| l.deinit(gpa);
        tc.zls.deinit();
        tc.docs.deinit();
        tc.reg.deinit();
    }
    tc.store = try .init(gpa, rt.io, .native);
    errdefer tc.store.deinit();
    const no_build: []const @import("../registry/zls.zig").Option = &.{.{ .name = "enable_build_on_save", .value = .{ .bool = false } }};
    _ = try tc.zls.setSettings(.{ .zig_path = opts.zig_exe, .zls = if (opts.trusted) &.{} else no_build });
    tc.mgr.init(rt, &tc.reg, &tc.docs, .{
        .workspace_folders = opts.roots,
        .env = opts.env,
        .init_timeout = opts.init_timeout,
        .client_version = "0.0.0",
    });
    errdefer tc.mgr.deinit();
    tc.mgr.config_provider = tc.zls.provider();
    if (opts.host) |h| tc.mgr.ui_host = h.clientHost();
    try tc.driver.init(&tc.mgr, &tc.store, .{ .settle = .{ .clock = .{ .ctx = tc, .sleep = pumpSleep } } });
    errdefer tc.driver.deinit();
    if (opts.tasks != null and opts.trusted) tc.driver.settleDetector().build = .{ .ctx = tc, .run = runCheck };
    tc.bg = .init(&tc.mgr, .{ .ctx = tc, .read = readFile, .language = languageOf }, BackgroundDocs.awakeClock(&rt.io), .{});
    tc.ci = .{
        .mgr = &tc.mgr,
        .store = &tc.store,
        .roots = opts.roots,
        .ui = .{ .ctx = tc, .run = runHere },
        .timeout = opts.timeout,
        .bg = &tc.bg,
        .settle = tc.driver.settleDetector(),
    };
}

/// Shuts the servers down and frees everything.
pub fn deinit(tc: *Toolchain) void {
    for (tc.held.items) |h| tc.bg.release(h);
    tc.held.deinit(tc.gpa);
    tc.ci.deinit();
    tc.bg.deinit();
    tc.mgr.deinit();
    tc.driver.deinit();
    tc.store.deinit();
    tc.docs.deinit();
    tc.reg.deinit();
    tc.zls.deinit();
    if (tc.langs) |*l| l.deinit(tc.gpa);
    tc.* = undefined;
}

/// The UI thread's work: server messages, then diagnostics.
pub fn pump(tc: *Toolchain) void {
    tc.mgr.tick();
    _ = tc.driver.tick();
}

/// Runs an agent tool (`lsp_*`) as agent 0: the same text, structured
/// content and status the agents get.
pub fn tool(tc: *Toolchain, arena: Allocator, name: []const u8, input_json: []const u8, out: *tools.Output) !bool {
    return tools.runAs(&tc.ci, 0, tc.rt.io, arena, name, input_json, out);
}

/// Opens `path` (absolute) in the background so its servers start and
/// check it; held until `deinit`. Error.NoLanguage when no server is for
/// its language.
pub fn open(tc: *Toolchain, path: []const u8) !void {
    try tc.held.ensureUnusedCapacity(tc.gpa, 1);
    const h = try tc.bg.acquire(path);
    tc.held.appendAssumeCapacity(h);
    // Its server definitions resolve on a worker: until then the settle
    // detector would see no server for it.
    const io = tc.rt.io;
    const deadline = zg_core.runtime.Deadline.after(io, tc.opts.init_timeout);
    while (!deadline.expired(io)) {
        tc.pump();
        const od = tc.mgr.open.get(h) orelse return;
        if (od.pending == 0) return;
        try io.sleep(.fromMilliseconds(2), .awake);
        zg_perf.idle.noteWake("codeintel.headless.resolve", .timer);
    }
}

/// Pumps until no server is starting (at most the init timeout).
pub fn waitStarted(tc: *Toolchain) Io.Cancelable!void {
    const io = tc.rt.io;
    const deadline = zg_core.runtime.Deadline.after(io, tc.opts.init_timeout);
    while (!deadline.expired(io)) {
        tc.pump();
        const starting = for (tc.mgr.serverList()) |s| {
            if (s.status == .starting) break true;
        } else false;
        if (!starting) return;
        try io.sleep(.fromMilliseconds(5), .awake);
        zg_perf.idle.noteWake("codeintel.headless.start", .timer);
    }
}

/// Servers started so far.
pub fn serverCount(tc: *const Toolchain) usize {
    return tc.mgr.serverList().len;
}

/// The check task (the `check`-tagged task), run on this thread with no
/// paths: its problems go into the store. Null when there is none.
pub fn runCheckNow(tc: *Toolchain, arena: Allocator, timeout: Io.Duration) !?SettleDetector.BuildSummary {
    const t = tc.opts.tasks orelse return null;
    if (!tc.opts.trusted) return null;
    const l = t.load() catch return null;
    if (l.tagged("check") == null) return null;
    return try runCheck(tc, tc.rt.io, arena, timeout);
}

fn runHere(ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) bool {
    const tc: *Toolchain = @ptrCast(@alignCast(ctx));
    tc.pump();
    f(arg);
    return true;
}

fn pumpSleep(ctx: ?*anyopaque, io: Io, d: Io.Duration) Io.Cancelable!void {
    const tc: *Toolchain = @ptrCast(@alignCast(ctx.?));
    tc.pump();
    try io.sleep(d, .awake);
    zg_perf.idle.noteWake("codeintel.headless.settle", .timer);
}

fn readFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror![]u8 {
    const tc: *Toolchain = @ptrCast(@alignCast(ctx));
    return Io.Dir.cwd().readFileAlloc(tc.rt.io, path, gpa, .limited(tc.bg.opts.max_bytes + 1));
}

fn languageOf(ctx: *anyopaque, path: []const u8, head: []const u8) ?[]const u8 {
    const tc: *Toolchain = @ptrCast(@alignCast(ctx));
    const langs = &(tc.langs orelse return null);
    const id = langs.detect(path, head) orelse return null;
    const lang = langs.get(id) orelse return null;
    if (lang.id == .plain) return null;
    return language.lspId(lang);
}

/// The settle detector's check task: runs it headless and puts its
/// problems into the store under the run's owner (replacing the last
/// run's). Called on this thread.
fn runCheck(ctx: *anyopaque, io: Io, arena: Allocator, timeout: Io.Duration) anyerror!SettleDetector.BuildSummary {
    const tc: *Toolchain = @ptrCast(@alignCast(ctx));
    const t = tc.opts.tasks.?;
    const l = t.load() catch |e| return .{ .label = "zig build check", .ok = false, .err = @errorName(e) };
    const task = l.tagged("check") orelse return .{ .label = "zig build check", .ok = false, .err = "the workspace has no check step" };
    const r = try t.runner.run(task.label, .{ .headless = true, .deadline = zg_core.runtime.Deadline.after(io, timeout) });
    const s = try t.runner.wait(r, arena);
    try tc.applyProblems(r.id, s.problems);
    return .{
        .label = try arena.dupe(u8, task.label),
        .ok = s.state == .succeeded,
        .exit_code = s.exit_code,
        .duration_ns = s.duration_ms * std.time.ns_per_ms,
        .timed_out = s.timed_out,
        .err = if (s.message) |m| try arena.dupe(u8, m) else null,
    };
}

fn applyProblems(tc: *Toolchain, run_id: u32, problems: []const Problem) !void {
    const owner: Store.Owner = .{ .task = run_id };
    if (tc.check_owner) |old| try tc.store.clearOwner(.{ .task = old });
    tc.check_owner = run_id;
    // By file, in the order they came.
    const done = try tc.gpa.alloc(bool, problems.len);
    defer tc.gpa.free(done);
    @memset(done, false);
    for (problems, 0..) |first, i| {
        if (done[i]) continue;
        const set = try Store.Set.create(tc.gpa, owner);
        var ok = false;
        defer if (!ok) set.destroy();
        var diags: std.ArrayList(Store.Diagnostic) = .empty;
        const sa = set.allocator();
        for (problems[i..], i..) |*p, j| {
            if (done[j] or !std.mem.eql(u8, p.file, first.file)) continue;
            done[j] = true;
            try diags.append(sa, try toDiagnostic(sa, p));
        }
        set.diags = diags.items;
        set.finish();
        const key = try tc.store.keyOfPath(tc.gpa, first.file);
        defer tc.gpa.free(key);
        ok = true;
        try tc.driver.replaceExternal(key, owner, set, .utf8);
    }
    tc.store.commit();
}

fn toDiagnostic(a: Allocator, p: *const Problem) !Store.Diagnostic {
    const line = p.line -| 1;
    const col = p.column -| 1;
    const end: Store.Pos = if (p.end_line > 0)
        .{ .line = p.end_line - 1, .character = if (p.end_column > 0) p.end_column - 1 else col + 1 }
    else
        .{ .line = line, .character = if (p.column > 0) col + 1 else 0 };
    return .{
        .start = .{ .line = line, .character = col },
        .end = end,
        .severity = switch (p.severity) {
            .err => .err,
            .warning => .warning,
            .info => .information,
            .hint => .hint,
        },
        .message = try a.dupe(u8, p.message),
        .source = try a.dupe(u8, p.source),
        .code = try a.dupe(u8, p.code),
    };
}
