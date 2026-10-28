//! Runs tasks (E07.F08.S01.T03): the `depends_on` graph, each task in a
//! terminal (the GUI's `TerminalHost`) or headless with pipes (agents,
//! `apps/zg`), output into the problem matchers, problems to the
//! `ProblemHost`.
//!
//! - `run` checks the graph, copies the tasks and starts a worker; it
//!   does not block, so the UI thread may call it. A bad graph, an
//!   unknown label or a disabled task gives a run that has already
//!   failed, with `message` saying why.
//! - Dependencies: `parallel` starts them together and waits for all,
//!   `sequence` runs them in order; a failure stops the chain. A task
//!   reached twice runs once. A background dependency counts as done at
//!   the end of its first matcher cycle (at once without a background
//!   matcher), and keeps running; a later run that depends on it while
//!   it runs reuses it.
//! - Problems go to the host with owner `task:<id>`: cleared at the
//!   start, then the full list after every problem (or, for background
//!   matchers, at the end of every cycle). A matcher holding a problem
//!   for notes flushes it after 20 ms without output.
//! - Shell tasks run through `shell_quote`; headless `zig build` runs add
//!   `--error-style minimal`.
//! - `${...}` in command, args, cwd and env are substituted with the
//!   runner's `VarContext` when it has one.
//!
//! Runs live until `deinit`. The runner must not move once it ran a task.

const TaskRunner = @This();
const std = @import("std");
const zg_perf = @import("zg_perf");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const Task = @import("Task.zig");
const TaskList = @import("TaskList.zig");
const graph = @import("graph.zig");
const shell_quote = @import("shell_quote.zig");
const headless = @import("headless_exec.zig");
const pm = @import("matcher/ProblemMatcher.zig");
const ansi = @import("matcher/ansi_strip.zig");
const variables = @import("../config/variables.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Subsystem = zg_core.runtime.Subsystem;
const Deadline = zg_core.runtime.Deadline;

pub const SpawnPolicy = zg_lsp.client.ServerProcess.SpawnPolicy;

pub const RunOptions = struct {
    headless: bool = false,
    /// Appended to the root task's arguments.
    extra_args: []const []const u8 = &.{},
    output_tail_lines: u32 = 200,
    /// Past it the run is terminated and reported as timed out.
    deadline: ?Deadline = null,
};

pub const State = enum { pending, running, succeeded, failed, terminated };

/// What a finished run gives an agent or the command line.
pub const TaskRunSummary = struct {
    state: State,
    exit_code: ?u8,
    /// The last lines of the output of every task of the run, without
    /// escape sequences.
    tail: []const u8,
    problems: []const pm.Problem,
    duration_ms: u64,
    timed_out: bool,
    /// Why the run failed before or around its process.
    message: ?[]const u8,
};

pub const TermHandle = u64;

pub const TermSpec = struct {
    title: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map,
    /// Reuse an idle terminal with this key; null: always a new one.
    panel_key: ?[]const u8,
    reveal: @FieldType(Task.Presentation, "reveal"),
    focus: bool,
    clear: bool,
    echo: bool,
};

pub const OutputSink = struct {
    ctx: *anyopaque,
    /// Raw bytes before VT processing.
    bytes: *const fn (ctx: *anyopaque, bytes: []const u8) void,
};

pub const ExitCb = struct {
    ctx: *anyopaque,
    /// Null for a signal or a crash.
    exited: *const fn (ctx: *anyopaque, code: ?u8) void,
};

/// Terminals for tasks; implemented by the GUI (E06).
pub const TerminalHost = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, spec: TermSpec) anyerror!TermHandle,
    tap: *const fn (ctx: *anyopaque, h: TermHandle, sink: OutputSink) void,
    onExit: *const fn (ctx: *anyopaque, h: TermHandle, cb: ExitCb) void,
    /// Kills the terminal's process tree.
    kill: *const fn (ctx: *anyopaque, h: TermHandle) void,
};

/// Where problems go (the diagnostics store); called from workers.
pub const ProblemHost = struct {
    ctx: *anyopaque,
    /// The owner's problems are now `problems` (valid during the call).
    set: *const fn (ctx: *anyopaque, owner: []const u8, problems: []const pm.Problem) void,
    /// `reveal_problems`: show the Problems panel.
    reveal: ?*const fn (ctx: *anyopaque) void = null,
};

pub const Config = struct {
    term: ?TerminalHost = null,
    problems: ?ProblemHost = null,
    policy: ?*const SpawnPolicy = null,
    /// The environment tasks start from; needed when a task or the policy
    /// changes it.
    env: ?*const std.process.Environ.Map = null,
    /// The workspace folder: the default cwd, the base of relative ones.
    root: []const u8,
    vars: ?*const variables.VarContext = null,
    os: std.Target.Os.Tag = builtin.os.tag,
};

/// One task of a run (the run itself is its root task).
pub const TaskRun = struct {
    id: u32,
    label: []const u8,
    state: State = .pending,
    exit_code: ?u8 = null,
    background_active: bool = false,
    problems: u32 = 0,
    /// Why it failed, when not its exit code.
    message: ?[]const u8 = null,

    // The rest is the runner's.
    arena: std.heap.ArenaAllocator,
    task: Task,
    inv: *Invocation,
    owner: []const u8,
    claimed: bool = false,
    ok: std.atomic.Value(bool) = .init(false),
    ready_event: Io.Event = .unset,
    done_event: Io.Event = .unset,
    mutex: Io.Mutex = .init,
    proc: ?*headless.Proc = null,
    term: ?TermHandle = null,
    term_exit: Io.Event = .unset,
    term_code: ?u8 = null,
    matchers: []Matcher = &.{},
    splitter: ?ansi.LineSplitter = null,
    found: std.ArrayList(pm.Problem) = .empty,
    cycle: std.ArrayList(pm.Problem) = .empty,
    in_cycle: bool = false,
    revealed: bool = false,
    last_output: std.atomic.Value(i64) = .init(0),
    terminated: bool = false,

    const Matcher = struct { m: pm.Matcher, background: bool };
};

/// One `run` call: its tasks, shared tail and timing.
const Invocation = struct {
    runner_ptr: *TaskRunner,
    root: *TaskRun,
    nodes: std.StringHashMapUnmanaged(*TaskRun) = .empty,
    opts: RunOptions,
    arena: std.heap.ArenaAllocator,
    tail_mutex: Io.Mutex = .init,
    tail: std.ArrayList(u8) = .empty,
    started: Io.Timestamp,
    finished: ?Io.Timestamp = null,
    timed_out: bool = false,

    fn runner(i: *const Invocation) *TaskRunner {
        return i.runner_ptr;
    }
};

const tail_cap = 256 * 1024;
const max_problems = 10_000;
const quiet_ms = 20;

rt: *zg_core.Runtime,
gpa: Allocator,
io: Io,
list: *const TaskList,
cfg: Config,
mutex: Io.Mutex = .init,
runs: std.ArrayList(*TaskRun) = .empty,
invocations: std.ArrayList(*Invocation) = .empty,
next_id: u32 = 1,
sub: Subsystem,

pub fn init(rt: *zg_core.Runtime, list: *const TaskList, cfg: Config) TaskRunner {
    return .{ .rt = rt, .gpa = rt.gpa, .io = rt.io, .list = list, .cfg = cfg, .sub = .init(rt.io) };
}

/// The list later runs use (after a reload); running tasks keep theirs.
pub fn setList(r: *TaskRunner, list: *const TaskList) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.list = list;
}

pub fn deinit(r: *TaskRunner) void {
    {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.runs.items) |tr| r.killLocked(tr);
    }
    r.sub.join() catch {};
    for (r.runs.items) |tr| {
        if (tr.proc) |p| p.deinit();
        for (tr.matchers) |*m| m.m.deinit();
        if (tr.splitter) |*s| s.deinit(r.gpa);
        tr.found.deinit(r.gpa);
        tr.cycle.deinit(r.gpa);
        tr.arena.deinit();
        r.gpa.destroy(tr);
    }
    r.runs.deinit(r.gpa);
    for (r.invocations.items) |inv| {
        inv.tail.deinit(r.gpa);
        inv.arena.deinit();
        r.gpa.destroy(inv);
    }
    r.invocations.deinit(r.gpa);
}

/// Starts `label` and its dependencies.
pub fn run(r: *TaskRunner, label: []const u8, opts: RunOptions) Allocator.Error!*TaskRun {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const inv = try r.gpa.create(Invocation);
    inv.* = .{ .runner_ptr = r, .root = undefined, .opts = opts, .arena = .init(r.gpa), .started = .now(r.io, .awake) };
    try r.invocations.append(r.gpa, inv);
    const a = inv.arena.allocator();
    inv.opts.extra_args = try dupeList(a, opts.extra_args);

    var message: []const u8 = "";
    graph.check(a, r.list, label, &message) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownTask, error.Cycle => {
            const root = try r.newRun(inv, &.{ .label = label, .source = .zon, .command = "" });
            inv.root = root;
            r.finishLocked(root, .failed, try root.arena.allocator().dupe(u8, message));
            return root;
        },
    };
    for (try graph.order(a, r.list, label)) |t| {
        // A background task already running is reused.
        const node = r.activeBackground(t.label) orelse try r.newRun(inv, t);
        try inv.nodes.put(a, node.label, node);
    }
    inv.root = inv.nodes.get(label).?;
    if (inv.root.claimed) {
        // The task is a background task running already.
        return inv.root;
    }
    r.sub.spawnLoop(execRoot, .{ r, inv }) catch {
        r.finishLocked(inv.root, .failed, "no worker is free to run the task");
    };
    return inv.root;
}

fn activeBackground(r: *TaskRunner, label: []const u8) ?*TaskRun {
    for (r.runs.items) |tr| {
        if (tr.task.is_background and tr.state == .running and std.mem.eql(u8, tr.label, label)) return tr;
    }
    return null;
}

fn newRun(r: *TaskRunner, inv: *Invocation, t: *const Task) Allocator.Error!*TaskRun {
    const run_ = try r.gpa.create(TaskRun);
    errdefer r.gpa.destroy(run_);
    run_.* = .{ .id = r.next_id, .label = undefined, .arena = .init(r.gpa), .task = undefined, .inv = inv, .owner = undefined };
    errdefer run_.arena.deinit();
    const a = run_.arena.allocator();
    run_.task = try t.clone(a);
    run_.label = run_.task.label;
    run_.owner = try std.fmt.allocPrint(a, "task:{d}", .{run_.id});
    try r.runs.append(r.gpa, run_);
    r.next_id += 1;
    return run_;
}

fn execRoot(r: *TaskRunner, inv: *Invocation) Io.Cancelable!void {
    _ = r.execNode(inv, inv.root);
}

/// Runs `node` after its dependencies; whether it succeeded (for a
/// background dependency: whether it became ready).
fn execNode(r: *TaskRunner, inv: *Invocation, node: *TaskRun) bool {
    r.mutex.lockUncancelable(r.io);
    if (node.claimed) {
        // Started by another path of the graph (or another run).
        r.mutex.unlock(r.io);
        node.ready_event.waitUncancelable(r.io);
        return node.ok.load(.acquire);
    }
    node.claimed = true;
    node.state = .running;
    r.mutex.unlock(r.io);
    const t = &node.task;
    const deps_ok = switch (t.depends_order) {
        .sequence => blk: {
            for (t.depends_on) |d| {
                if (!r.execNode(inv, inv.nodes.get(d).?)) break :blk false;
            }
            break :blk true;
        },
        .parallel => r.execParallel(inv, t.depends_on),
    };
    if (!deps_ok) return r.finish(node, .failed, "a task it depends on failed");
    if (r.isTerminated(node)) return r.finish(node, .terminated, null);
    if (!t.enabled) return r.finish(node, .failed, t.disabled_reason orelse "the task is disabled");
    if (t.command.len == 0) return r.finish(node, .succeeded, null);

    r.startProcess(inv, node) catch |e| {
        const msg = if (node.message) |m| m else @errorName(e);
        return r.finish(node, .failed, msg);
    };
    if (t.is_background and node != inv.root) {
        // Keep it running; the chain goes on once it is ready.
        r.sub.spawnLoop(monitorLoop, .{ r, node }) catch {
            r.monitor(node);
            return node.ok.load(.acquire);
        };
        node.ready_event.waitUncancelable(r.io);
        return node.ok.load(.acquire);
    }
    r.monitor(node);
    return node.ok.load(.acquire);
}

fn execParallel(r: *TaskRunner, inv: *Invocation, deps: []const []const u8) bool {
    if (deps.len == 0) return true;
    if (deps.len == 1) return r.execNode(inv, inv.nodes.get(deps[0]).?);
    const results = r.gpa.alloc(bool, deps.len) catch return r.execSequence(inv, deps);
    defer r.gpa.free(results);
    var group: Io.Group = .init;
    const Each = struct {
        fn run(rr: *TaskRunner, i: *Invocation, n: *TaskRun, out: *bool) Io.Cancelable!void {
            out.* = rr.execNode(i, n);
        }
    };
    for (deps, results) |d, *out| {
        const n = inv.nodes.get(d).?;
        group.concurrent(r.io, Each.run, .{ r, inv, n, out }) catch {
            out.* = r.execNode(inv, n);
        };
    }
    group.await(r.io) catch {};
    for (results) |ok| if (!ok) return false;
    return true;
}

fn execSequence(r: *TaskRunner, inv: *Invocation, deps: []const []const u8) bool {
    for (deps) |d| if (!r.execNode(inv, inv.nodes.get(d).?)) return false;
    return true;
}

fn isTerminated(r: *TaskRunner, node: *TaskRun) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return node.terminated or node.inv.root.terminated;
}

fn finish(r: *TaskRunner, node: *TaskRun, state: State, message: ?[]const u8) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.finishLocked(node, state, message);
    return state == .succeeded;
}

fn finishLocked(r: *TaskRunner, node: *TaskRun, state: State, message: ?[]const u8) void {
    node.state = if (node.terminated and state != .succeeded) .terminated else state;
    if (message) |m| if (node.message == null) {
        node.message = node.arena.allocator().dupe(u8, m) catch null;
    };
    node.background_active = false;
    node.ok.store(state == .succeeded, .release);
    if (node == node.inv.root) node.inv.finished = .now(r.io, .awake);
    node.claimed = true;
    node.ready_event.set(r.io);
    node.done_event.set(r.io);
}

// ------------------------------------------------------------ starting

fn startProcess(r: *TaskRunner, inv: *Invocation, node: *TaskRun) !void {
    const a = node.arena.allocator();
    const t = &node.task;
    const is_root = node == inv.root;

    var command = t.command;
    var args = t.args;
    var cwd: []const u8 = r.cfg.root;
    var env_pairs = t.env;
    if (r.cfg.vars) |vars| {
        command = try r.subst(node, a, command, vars);
        const out = try a.alloc([]const u8, args.len);
        for (args, out) |s, *o| o.* = try r.subst(node, a, s, vars);
        args = out;
        if (t.cwd) |c| cwd = try r.subst(node, a, c, vars);
        const env = try a.alloc([2][]const u8, env_pairs.len);
        for (env_pairs, env) |kv, *o| o.* = .{ kv[0], try r.subst(node, a, kv[1], vars) };
        env_pairs = env;
    } else if (t.cwd) |c| cwd = c;
    if (!std.fs.path.isAbsolute(cwd)) cwd = try std.fs.path.join(a, &.{ r.cfg.root, cwd });

    // Headless zig builds print less for agents.
    if (inv.opts.headless and t.source == .zig and args.len > 0 and std.mem.eql(u8, args[0], "build")) {
        const out = try a.alloc([]const u8, args.len + 2);
        out[0] = "build";
        out[1] = "--error-style";
        out[2] = "minimal";
        @memcpy(out[3..], args[1..]);
        args = out;
    }
    if (is_root and inv.opts.extra_args.len > 0) {
        const out = try a.alloc([]const u8, args.len + inv.opts.extra_args.len);
        @memcpy(out[0..args.len], args);
        @memcpy(out[args.len..], inv.opts.extra_args);
        args = out;
    }
    var argv: []const []const u8 = switch (t.kind) {
        .process => blk: {
            const out = try a.alloc([]const u8, args.len + 1);
            out[0] = command;
            @memcpy(out[1..], args);
            break :blk out;
        },
        .shell => blk: {
            const exe: ?[]const u8 = if (t.shell) |s| s.executable else null;
            const style = shell_quote.styleOf(exe, r.cfg.os);
            const line = try shell_quote.commandLine(a, command, args, style);
            const sargs: ?[]const []const u8 = if (t.shell) |s| (if (s.args.len > 0) s.args else null) else null;
            break :blk try shell_quote.shellArgv(a, line, exe, sargs, r.cfg.os);
        },
    };

    var rules: SpawnPolicy.Rules = .{};
    if (r.cfg.policy) |p| switch (p.decide(argv, cwd)) {
        .allow => |x| rules = x,
        .deny => |reason| {
            node.message = try a.dupe(u8, reason);
            return error.SpawnDenied;
        },
    };
    if (rules.wrapper_argv) |w| {
        const out = try a.alloc([]const u8, w.len + argv.len);
        @memcpy(out[0..w.len], w);
        @memcpy(out[w.len..], argv);
        argv = out;
    }
    const env = try r.buildEnv(node, a, env_pairs, rules);

    // Matchers.
    var matchers: std.ArrayList(TaskRun.Matcher) = .empty;
    for (t.problem_matchers) |*ref| {
        const def: *const pm.MatcherDef = switch (ref.*) {
            .named => |n| pm.builtinNamed(n) orelse {
                r.appendTail(inv, try std.fmt.allocPrint(a, "zigguro: unknown problem matcher '{s}'", .{n}));
                continue;
            },
            .inline_def => |*d| d,
        };
        var d = def;
        if (r.cfg.vars) |vars| if (fileBase(def.*)) |base| if (std.mem.indexOf(u8, base, "${") != null) {
            const copy = try a.create(pm.MatcherDef);
            copy.* = def.*;
            const b2 = try r.subst(node, a, base, vars);
            copy.file_location = switch (def.file_location) {
                .relative => .{ .relative = b2 },
                .auto_detect => .{ .auto_detect = b2 },
                .absolute => .absolute,
            };
            d = copy;
        };
        const m = pm.Matcher.init(r.gpa, d, cwd, .{ .style = if (r.cfg.os == .windows) .windows else .posix }) catch |e| {
            r.appendTail(inv, try std.fmt.allocPrint(a, "zigguro: problem matcher of '{s}' does not compile ({t})", .{ t.label, e }));
            continue;
        };
        try matchers.append(a, .{ .m = m, .background = d.background != null });
    }
    node.matchers = matchers.items;
    node.splitter = try .init(r.gpa);
    // Only tasks with matchers own problems.
    if (node.matchers.len > 0) r.publish(node, &.{});
    node.last_output.store(nowMs(r.io), .release);
    if (t.presentation.reveal_problems == .always) r.reveal(node);

    if (r.cfg.term != null and !inv.opts.headless) {
        const host = r.cfg.term.?;
        const key: ?[]const u8 = switch (t.presentation.panel) {
            .shared => try std.fmt.allocPrint(a, "tasks:{t}", .{if (t.group) |g| g.kind else .none}),
            .dedicated => try std.fmt.allocPrint(a, "task:{s}", .{t.label}),
            .new => null,
        };
        const h = try host.open(host.ctx, .{
            .title = t.label,
            .argv = argv,
            .cwd = cwd,
            .env = env,
            .panel_key = key,
            .reveal = t.presentation.reveal,
            .focus = t.presentation.focus,
            .clear = t.presentation.clear,
            .echo = t.presentation.echo,
        });
        node.term = h;
        host.tap(host.ctx, h, .{ .ctx = node, .bytes = termOutput });
        host.onExit(host.ctx, h, .{ .ctx = node, .exited = termExited });
    } else {
        node.proc = try headless.Proc.start(r.gpa, r.io, .{ .argv = argv, .cwd = cwd, .env = env }, .{ .ctx = node, .output = procOutput });
    }
    if (t.is_background) {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        node.background_active = true;
        // Without a background matcher it is ready once started.
        const has_bg = for (node.matchers) |m| {
            if (m.background) break true;
        } else false;
        if (!has_bg) {
            node.ok.store(true, .release);
            node.ready_event.set(r.io);
        }
    }
}

fn fileBase(d: pm.MatcherDef) ?[]const u8 {
    return switch (d.file_location) {
        .absolute => null,
        .relative => |b| b,
        .auto_detect => |b| b,
    };
}

fn subst(r: *TaskRunner, node: *TaskRun, a: Allocator, s: []const u8, vars: *const variables.VarContext) ![]const u8 {
    _ = r;
    if (std.mem.indexOf(u8, s, "${") == null) return s;
    return variables.substituteString(a, s, vars, &.{}) catch |e| {
        node.message = try std.fmt.allocPrint(a, "cannot substitute the variables in '{s}' ({t})", .{ s, e });
        return error.Substitution;
    };
}

fn buildEnv(r: *TaskRunner, node: *TaskRun, a: Allocator, pairs: []const [2][]const u8, rules: SpawnPolicy.Rules) !?*const std.process.Environ.Map {
    if (pairs.len == 0 and rules.env_set.len == 0 and rules.env_allow == null) return r.cfg.env;
    const base = r.cfg.env orelse {
        node.message = "the task sets environment variables but the runner has no base environment";
        return error.MissingBaseEnv;
    };
    const env = try a.create(std.process.Environ.Map);
    env.* = try base.clone(a);
    if (rules.env_allow) |allow| {
        var i: usize = 0;
        while (i < env.count()) {
            const key = env.keys()[i];
            const keep = for (allow) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false;
            if (keep) i += 1 else _ = env.swapRemove(key);
        }
    }
    for (pairs) |kv| try env.put(kv[0], kv[1]);
    for (rules.env_set) |kv| try env.put(kv[0], kv[1]);
    return env;
}

// -------------------------------------------------------------- output

fn procOutput(ctx: *anyopaque, bytes: []const u8) void {
    const node: *TaskRun = @ptrCast(@alignCast(ctx));
    output(node, bytes);
}

fn termOutput(ctx: *anyopaque, bytes: []const u8) void {
    const node: *TaskRun = @ptrCast(@alignCast(ctx));
    output(node, bytes);
}

fn termExited(ctx: *anyopaque, code: ?u8) void {
    const node: *TaskRun = @ptrCast(@alignCast(ctx));
    const r = runnerOf(node);
    node.term_code = code;
    node.term_exit.set(r.io);
}

/// The runner, through the run's invocation's root (set at `run`).
fn runnerOf(node: *TaskRun) *TaskRunner {
    return node.inv.runner();
}

fn output(node: *TaskRun, bytes: []const u8) void {
    const r = runnerOf(node);
    node.last_output.store(nowMs(r.io), .release);
    node.mutex.lockUncancelable(r.io);
    defer node.mutex.unlock(r.io);
    const sink = problemSink(node);
    for (node.matchers) |*m| m.m.feedBytes(bytes, sink);
    if (node.splitter) |*s| s.feed(bytes, node, onLine);
}

fn onLine(node: *TaskRun, line: []const u8, _: bool) void {
    runnerOf(node).appendTail(node.inv, line);
}

fn appendTail(r: *TaskRunner, inv: *Invocation, line: []const u8) void {
    inv.tail_mutex.lockUncancelable(r.io);
    defer inv.tail_mutex.unlock(r.io);
    if (inv.tail.items.len + line.len + 1 > tail_cap) {
        // Drop the older half, at a line start.
        const half = inv.tail.items.len / 2;
        const cut = if (std.mem.indexOfScalarPos(u8, inv.tail.items, half, '\n')) |i| i + 1 else inv.tail.items.len;
        const rest = inv.tail.items.len - cut;
        std.mem.copyForwards(u8, inv.tail.items[0..rest], inv.tail.items[cut..]);
        inv.tail.shrinkRetainingCapacity(rest);
    }
    const n = @min(line.len, tail_cap - 1);
    inv.tail.appendSlice(r.gpa, line[0..n]) catch return;
    inv.tail.append(r.gpa, '\n') catch {};
}

fn problemSink(node: *TaskRun) pm.ProblemSink {
    return .{ .ctx = node, .problem = onProblem, .cycle = onCycle };
}

/// Called with `node.mutex` held.
fn onProblem(ctx: *anyopaque, p: *const pm.Problem) void {
    const node: *TaskRun = @ptrCast(@alignCast(ctx));
    const r = runnerOf(node);
    const copy = copyProblem(node.arena.allocator(), p) catch return;
    if (node.in_cycle) {
        if (node.cycle.items.len < max_problems) node.cycle.append(r.gpa, copy) catch {};
        return;
    }
    if (node.found.items.len >= max_problems) return;
    node.found.append(r.gpa, copy) catch return;
    node.problems = @intCast(node.found.items.len);
    r.publish(node, node.found.items);
    if (node.task.presentation.reveal_problems == .on_problem) r.reveal(node);
}

fn onCycle(ctx: *anyopaque, ev: pm.Cycle) void {
    const node: *TaskRun = @ptrCast(@alignCast(ctx));
    const r = runnerOf(node);
    switch (ev) {
        .begin => {
            node.in_cycle = true;
            node.cycle.clearRetainingCapacity();
        },
        .end => {
            node.in_cycle = false;
            node.found.clearRetainingCapacity();
            node.found.appendSlice(r.gpa, node.cycle.items) catch {};
            node.problems = @intCast(node.found.items.len);
            r.publish(node, node.found.items);
            if (node.found.items.len > 0 and node.task.presentation.reveal_problems == .on_problem) r.reveal(node);
            // The first cycle makes a background task ready.
            node.ok.store(true, .release);
            node.ready_event.set(r.io);
        },
    }
}

fn publish(r: *TaskRunner, node: *TaskRun, problems: []const pm.Problem) void {
    if (r.cfg.problems) |h| h.set(h.ctx, node.owner, problems);
}

fn reveal(r: *TaskRunner, node: *TaskRun) void {
    if (node.revealed) return;
    node.revealed = true;
    if (r.cfg.problems) |h| if (h.reveal) |f| f(h.ctx);
}

fn copyProblem(a: Allocator, p: *const pm.Problem) Allocator.Error!pm.Problem {
    var c = p.*;
    c.file = try a.dupe(u8, p.file);
    c.code = try a.dupe(u8, p.code);
    c.message = try a.dupe(u8, p.message);
    c.source = try a.dupe(u8, p.source);
    const rel = try a.alloc(pm.Related, p.related.len);
    for (p.related, rel) |x, *y| y.* = .{ .file = try a.dupe(u8, x.file), .line = x.line, .column = x.column, .message = try a.dupe(u8, x.message) };
    c.related = rel;
    return c;
}

// ------------------------------------------------------------- waiting

fn monitorLoop(r: *TaskRunner, node: *TaskRun) Io.Cancelable!void {
    r.monitor(node);
}

/// Waits for the node's process, flushing held problems while output is
/// quiet and enforcing the run's deadline; then finishes the node.
fn monitor(r: *TaskRunner, node: *TaskRun) void {
    const inv = node.inv;
    var code: ?u8 = null;
    while (true) {
        if (node.proc) |p| {
            const exited = p.waitExit(.fromMilliseconds(quiet_ms + 5));
            zg_perf.idle.noteWake("dap.task.monitor", .timer);
            if (exited) |term| {
                p.drainOutput();
                code = headless.Proc.exitCode(term);
                break;
            }
        } else {
            node.term_exit.waitTimeout(r.io, .{ .duration = .{ .raw = .fromMilliseconds(quiet_ms + 5), .clock = .awake } }) catch {};
            zg_perf.idle.noteWake("dap.task.monitor", .timer);
            if (node.term_exit.isSet()) {
                code = node.term_code;
                break;
            }
        }
        if (nowMs(r.io) - node.last_output.load(.acquire) >= quiet_ms) {
            node.mutex.lockUncancelable(r.io);
            defer node.mutex.unlock(r.io);
            const sink = problemSink(node);
            for (node.matchers) |*m| m.m.idle(sink);
        }
        if (inv.opts.deadline) |d| if (d.expired(r.io) and !inv.timed_out) {
            inv.timed_out = true;
            r.terminate(inv.root);
        };
    }
    {
        node.mutex.lockUncancelable(r.io);
        defer node.mutex.unlock(r.io);
        const sink = problemSink(node);
        for (node.matchers) |*m| m.m.finish(sink);
        if (node.splitter) |*s| s.finish(node, onLine);
        if (!node.in_cycle and node.matchers.len > 0) r.publish(node, node.found.items);
    }
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    node.exit_code = code;
    const state: State = if (node.terminated) .terminated else if (code == 0) .succeeded else .failed;
    r.finishLocked(node, state, null);
}

/// Waits for the run's root task and summarizes the run in `arena`.
pub fn wait(r: *TaskRunner, run_: *TaskRun, arena: Allocator) Allocator.Error!TaskRunSummary {
    const inv = run_.inv;
    if (inv.root == run_ and inv.opts.deadline != null and run_.task.is_background) {
        // A background root never exits by itself: wait for its deadline.
        while (!run_.done_event.isSet()) {
            if (inv.opts.deadline.?.expired(r.io)) {
                inv.timed_out = true;
                r.terminate(run_);
                break;
            }
            run_.done_event.waitTimeout(r.io, inv.opts.deadline.?.timeout()) catch {};
        }
    }
    run_.done_event.waitUncancelable(r.io);
    return r.summary(run_, arena);
}

/// Waits until a background task is ready (its first cycle ended), or
/// the task finished.
pub fn waitBackgroundReady(r: *TaskRunner, run_: *TaskRun) void {
    run_.ready_event.waitUncancelable(r.io);
}

pub fn summary(r: *TaskRunner, run_: *TaskRun, arena: Allocator) Allocator.Error!TaskRunSummary {
    const inv = run_.inv;
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    var problems: std.ArrayList(pm.Problem) = .empty;
    var it = inv.nodes.valueIterator();
    while (it.next()) |n| {
        n.*.mutex.lockUncancelable(r.io);
        defer n.*.mutex.unlock(r.io);
        for (n.*.found.items) |*p| try problems.append(arena, try copyProblem(arena, p));
    }
    std.mem.sort(pm.Problem, problems.items, {}, problemLess);
    const tail = blk: {
        inv.tail_mutex.lockUncancelable(r.io);
        defer inv.tail_mutex.unlock(r.io);
        break :blk try arena.dupe(u8, lastLines(inv.tail.items, inv.opts.output_tail_lines));
    };
    const end = inv.finished orelse Io.Timestamp.now(r.io, .awake);
    return .{
        .state = run_.state,
        .exit_code = run_.exit_code,
        .tail = tail,
        .problems = problems.items,
        .duration_ms = @intCast(@max(0, inv.started.durationTo(end).toMilliseconds())),
        .timed_out = inv.timed_out,
        .message = if (run_.message) |m| try arena.dupe(u8, m) else null,
    };
}

fn problemLess(_: void, a: pm.Problem, b: pm.Problem) bool {
    const o = std.mem.order(u8, a.file, b.file);
    if (o != .eq) return o == .lt;
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

pub fn lastLines(text: []const u8, n: u32) []const u8 {
    if (n == 0) return "";
    var end = text.len;
    if (end > 0 and text[end - 1] == '\n') end -= 1;
    var count: u32 = 0;
    var i = end;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '\n') {
            count += 1;
            if (count == n) return text[i..];
        }
    }
    return text;
}

/// Kills the run's processes (every task of a run started for it, and
/// dependencies still running).
pub fn terminate(r: *TaskRunner, run_: *TaskRun) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    run_.terminated = true;
    r.killLocked(run_);
    if (run_.inv.root == run_) {
        var it = run_.inv.nodes.valueIterator();
        while (it.next()) |n| if (n.*.inv == run_.inv) {
            n.*.terminated = true;
            r.killLocked(n.*);
        };
    }
}

fn killLocked(r: *TaskRunner, node: *TaskRun) void {
    if (node.proc) |p| if (!p.exited()) p.killTree();
    if (node.term) |h| if (!node.term_exit.isSet()) if (r.cfg.term) |host| host.kill(host.ctx, h);
}

/// A copy of the run's status fields, taken under the runner's lock.
pub fn status(r: *TaskRunner, run_: *const TaskRun) struct { state: State, exit_code: ?u8, background_active: bool, problems: u32 } {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return .{ .state = run_.state, .exit_code = run_.exit_code, .background_active = run_.background_active, .problems = run_.problems };
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn dupeList(a: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |s, *o| o.* = try a.dupe(u8, s);
    return out;
}
