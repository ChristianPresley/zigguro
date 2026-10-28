//! Tasks in the workbench (E07.F08.S01.T04): the workspace's tasks
//! (`zig build` steps, `.zigguro/tasks.zon`, `.vscode/tasks.json`), run in
//! terminal tabs, their problems in the editor and the Problems panel.
//!
//! - The list loads on a worker (listing the build steps runs `zig build
//!   -l`) and reloads after one of its files is saved, when the window
//!   gets focus back, and when trust changes. A command given before the
//!   first load runs once it is done.
//! - The runner (`zg_dap.tasks.TaskRunner`) calls the terminal host on
//!   its workers: a task terminal is opened, tapped and started on the UI
//!   thread once the runner has hooked its output and exit (so no output
//!   is missed). A finished task's tab is reused by the next run with the
//!   same panel (`presentation.panel`).
//! - Problems come from the runner's workers, are copied and applied on
//!   the UI thread, one store owner per run; a new run of a task replaces
//!   the previous run's problems.
//! - `task_run` and `task_list` for agents, and the settle detector's
//!   check task (the `check` step) for files no language server has.
//!
//! Posted work reaches a ref-counted `Inbox` that outlives the service,
//! like the terminal panel's `Poster`.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_dap = @import("zg_dap");
const zg_ai = @import("zg_ai");
const zg_codeintel = @import("zg_codeintel");
const TerminalPanel = @import("terminal_panel.zig").TerminalPanel;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Task = zg_dap.tasks.Task;
const TaskList = zg_dap.tasks.TaskList;
const TaskRunner = zg_dap.tasks.TaskRunner;
const pm = zg_dap.tasks.matcher;
const variables = zg_dap.variables;
const Store = zg_codeintel.diagnostics.Store;
const Driver = zg_codeintel.diagnostics.Driver;
const SettleDetector = zg_codeintel.diagnostics.SettleDetector;
const quick_pick = zg_gui.w.quick_pick;
const Severity = zg_gui.w.notification_center.Severity;
const Window = zg_gui.Window;
const log = std.log.scoped(.tasks);

pub const ToolExporter = zg_dap.tasks.agent_tool.ToolExporter(zg_ai.tools.adapters.foreign);

/// What the service needs from the workbench (UI thread).
pub const Host = struct {
    ctx: *anyopaque,
    /// A new terminal tab named `title`, not started; null when none
    /// could open. `show`: bring the terminal panel up, `focus`: and
    /// focus it.
    open_terminal: *const fn (ctx: *anyopaque, title: []const u8, show: bool, focus: bool) ?*TerminalPanel,
    close_terminal: *const fn (ctx: *anyopaque, panel: *TerminalPanel) void,
    notify: *const fn (ctx: *anyopaque, severity: Severity, text: []const u8) void,
    open_file: *const fn (ctx: *anyopaque, path: []const u8) void,
    show_problems: *const fn (ctx: *anyopaque) void,
    /// Something to repaint.
    changed: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    /// `zig.path` (null: `zig` on PATH).
    zig_exe: ?[]const u8 = null,
    trusted: bool = false,
    /// Load the list now (tests load it themselves with `waitLoaded`).
    load: bool = true,
};

/// What a command does once the list is loaded.
const Action = enum { pick, build, @"test" };

/// What the open picker is for.
const PickKind = enum { run, terminate, restart };

/// See the module doc.
pub const Tasks = struct {
    gpa: Allocator,
    io: Io,
    rt: *zg_core.Runtime,
    app: *zg_gui.App,
    win: ?*Window = null,
    host: Host,
    env: *const std.process.Environ.Map,
    root: []u8,
    zig_exe: []u8,
    /// The store the problems go to (from the language services).
    diags: ?*Driver = null,

    /// Guards `cache` (the loader holds it while `zig build -l` runs).
    cache_mutex: Io.Mutex = .init,
    cache: TaskList.Cache,
    /// The list before the first load.
    empty: TaskList,
    list: std.atomic.Value(*const TaskList),
    loaded: std.atomic.Value(bool) = .init(false),
    /// Files changed and trust, for the loader (guarded by `pending_mutex`).
    pending_mutex: Io.Mutex = .init,
    pending_paths: std.ArrayList([]u8) = .empty,
    pending_trust: ?bool = null,
    loading: bool = false,
    load_done: Io.Event = .is_set,
    after_load: ?Action = null,

    vars: variables.VarContext,
    runner: TaskRunner,
    tool: ToolExporter = undefined,
    inbox: *Inbox,

    terms_mutex: Io.Mutex = .init,
    terms: std.AutoArrayHashMapUnmanaged(TaskRunner.TermHandle, *Term) = .empty,
    next_term: TaskRunner.TermHandle = 1,

    /// UI thread: the runs started here, the store owner of each task's
    /// last run (by label), the labels run last first.
    started: std.ArrayList(*TaskRunner.TaskRun) = .empty,
    owners: std.StringHashMapUnmanaged(u32) = .empty,
    recent: std.ArrayList([]u8) = .empty,

    pick: quick_pick.QuickPickHandle = .{},
    pick_arena: std.heap.ArenaAllocator,
    pick_items: []quick_pick.QpItem = &.{},
    pick_labels: [][]const u8 = &.{},
    pick_runs: []*TaskRunner.TaskRun = &.{},
    pick_kind: PickKind = .run,
    pick_title: []const u8 = "",

    pub fn create(rt: *zg_core.Runtime, app: *zg_gui.App, env: *const std.process.Environ.Map, root: []const u8, host: Host, opts: Options) !*Tasks {
        const gpa = rt.gpa;
        const t = try gpa.create(Tasks);
        errdefer gpa.destroy(t);
        const root_copy = try gpa.dupe(u8, root);
        errdefer gpa.free(root_copy);
        const zig_copy = try gpa.dupe(u8, opts.zig_exe orelse "zig");
        errdefer gpa.free(zig_copy);
        const inbox = try gpa.create(Inbox);
        errdefer gpa.destroy(inbox);
        inbox.* = .{ .gpa = gpa, .io = rt.io, .app = app, .tasks = t };
        t.* = .{
            .gpa = gpa,
            .io = rt.io,
            .rt = rt,
            .app = app,
            .host = host,
            .env = env,
            .root = root_copy,
            .zig_exe = zig_copy,
            .cache = .init(gpa, .{ .root = root_copy, .trusted = opts.trusted }, builtin.os.tag, .{ .exe_path = zig_copy, .env = env }),
            .empty = undefined,
            .list = undefined,
            .vars = undefined,
            .runner = undefined,
            .inbox = inbox,
            .pick_arena = .init(gpa),
        };
        t.empty = try TaskList.fromSources(gpa, .{ .os = builtin.os.tag, .trusted = opts.trusted });
        t.list = .init(&t.empty);
        t.vars = .{
            .workspace_folder = root_copy,
            .file = null,
            .line = null,
            .column = null,
            .selected_text = null,
            .cwd = root_copy,
            .exec_path = "",
            .user_home = env.get("HOME") orelse env.get("USERPROFILE") orelse "",
            .default_build_task = null,
            .os = builtin.os.tag,
            .env = env,
            .config = noConfig,
            .command = noCommand,
            .input = noInput,
            .ctx = t,
        };
        t.runner = .init(rt, &t.empty, .{
            .term = .{ .ctx = t, .open = termOpen, .tap = termTap, .onExit = termOnExit, .kill = termKill },
            .problems = .{ .ctx = t, .set = problemsSet, .reveal = problemsReveal },
            .env = env,
            .root = root_copy,
            .vars = &t.vars,
        });
        t.tool = .{ .runner = &t.runner };
        if (opts.load) t.reload();
        return t;
    }

    /// UI thread. Ends the running tasks (their terminals close) and
    /// waits for the loader.
    pub fn destroy(t: *Tasks) void {
        const gpa = t.gpa;
        if (t.win) |w| t.pick.close(w);
        t.waitLoaded();
        // The runner's workers wait for the terminals' exits: terminals
        // not started yet end now, the open ones close.
        t.inbox.shutDown();
        while (true) {
            const panel = blk: {
                t.terms_mutex.lockUncancelable(t.io);
                defer t.terms_mutex.unlock(t.io);
                for (t.terms.values()) |rec| if (rec.panel) |p| break :blk p;
                break :blk null;
            } orelse break;
            panel.kill(.kill_tree);
            t.host.close_terminal(t.host.ctx, panel);
            // A host that could not close it: unhook it here.
            if (t.recOfPanel(panel)) |rec| onPanelDestroy(rec);
        }
        t.runner.deinit();
        t.inbox.release();
        for (t.terms.values()) |rec| rec.destroy();
        t.terms.deinit(gpa);
        for (t.pending_paths.items) |p| gpa.free(p);
        t.pending_paths.deinit(gpa);
        t.started.deinit(gpa);
        var it = t.owners.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        t.owners.deinit(gpa);
        for (t.recent.items) |l| gpa.free(l);
        t.recent.deinit(gpa);
        t.pick_arena.deinit();
        t.cache.deinit();
        t.empty.deinit();
        gpa.free(t.zig_exe);
        gpa.free(t.root);
        gpa.destroy(t);
    }

    fn recOfPanel(t: *Tasks, panel: *TerminalPanel) ?*Term {
        t.terms_mutex.lockUncancelable(t.io);
        defer t.terms_mutex.unlock(t.io);
        for (t.terms.values()) |rec| if (rec.panel == panel) return rec;
        return null;
    }

    /// The tasks as last loaded (valid until `destroy`).
    pub fn current(t: *const Tasks) *const TaskList {
        return t.list.load(.acquire);
    }

    /// The agent tools (`task_run`, `task_list`).
    pub fn exporter(t: *Tasks) zg_ai.tools.adapters.foreign.Exporter {
        return t.tool.exporter();
    }

    /// The settle detector's check task (the `check` step).
    pub fn buildCheck(t: *Tasks) SettleDetector.BuildCheck {
        return .{ .ctx = t, .run = runBuildCheck };
    }

    // ------------------------------------------------------------ loading

    /// A file was saved or changed (absolute): reloads when the list
    /// depends on it.
    pub fn fileChanged(t: *Tasks, path: []const u8) void {
        if (!dependsOn(t.root, path)) return;
        {
            t.pending_mutex.lockUncancelable(t.io);
            defer t.pending_mutex.unlock(t.io);
            const copy = t.gpa.dupe(u8, path) catch return;
            t.pending_paths.append(t.gpa, copy) catch t.gpa.free(copy);
        }
        t.reload();
    }

    /// The window got focus back: files may have changed outside.
    pub fn recheck(t: *Tasks) void {
        for (TaskList.watched) |w| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ t.root, w }) catch continue;
            t.fileChanged(p);
        }
    }

    pub fn setTrusted(t: *Tasks, trusted: bool) void {
        {
            t.pending_mutex.lockUncancelable(t.io);
            defer t.pending_mutex.unlock(t.io);
            t.pending_trust = trusted;
        }
        t.reload();
    }

    fn dependsOn(root: []const u8, path: []const u8) bool {
        var rel = path;
        if (std.mem.startsWith(u8, rel, root)) rel = std.mem.trimStart(u8, rel[root.len..], "/\\");
        for (TaskList.watched) |w| {
            if (rel.len != w.len) continue;
            for (rel, w) |a, b| {
                if ((if (a == '\\') '/' else a) != b) break;
            } else return true;
        }
        return false;
    }

    /// Starts the loader unless it runs (it then loads again).
    fn reload(t: *Tasks) void {
        t.pending_mutex.lockUncancelable(t.io);
        defer t.pending_mutex.unlock(t.io);
        if (t.loading) return;
        t.loading = true;
        t.load_done.reset();
        t.app.spawn(loadWork, .{t});
    }

    /// Waits for the loader (tests, `destroy`).
    pub fn waitLoaded(t: *Tasks) void {
        t.load_done.waitUncancelable(t.io);
    }

    fn loadWork(t: *Tasks) void {
        while (true) {
            var paths: std.ArrayList([]u8) = .empty;
            var trust: ?bool = null;
            {
                t.pending_mutex.lockUncancelable(t.io);
                defer t.pending_mutex.unlock(t.io);
                std.mem.swap(std.ArrayList([]u8), &paths, &t.pending_paths);
                trust = t.pending_trust;
                t.pending_trust = null;
                if (paths.items.len == 0 and trust == null and t.loaded.load(.acquire)) {
                    t.loading = false;
                    t.load_done.set(t.io);
                    return;
                }
            }
            defer {
                for (paths.items) |p| t.gpa.free(p);
                paths.deinit(t.gpa);
            }
            t.cache_mutex.lockUncancelable(t.io);
            if (trust) |on| t.cache.setTrusted(on);
            for (paths.items) |p| _ = t.cache.fileChanged(p);
            const before = t.cache.list;
            const got = t.cache.get(t.io);
            t.cache_mutex.unlock(t.io);
            const l = got catch |e| {
                log.warn("tasks not loaded: {t}", .{e});
                t.loaded.store(true, .release);
                t.inbox.push(.list_changed);
                continue;
            };
            if (before != t.cache.list or !t.loaded.load(.acquire)) {
                t.list.store(l, .release);
                t.runner.setList(l);
                t.loaded.store(true, .release);
                t.inbox.push(.list_changed);
            }
        }
    }

    /// UI thread: the loader finished a load.
    fn onListChanged(t: *Tasks) void {
        if (t.after_load) |a| {
            t.after_load = null;
            t.act(a);
        }
        if (t.win) |w| if (t.pick.isOpen(w) and t.pick_kind == .run) t.openRunPicker(null) catch {};
        t.host.changed(t.host.ctx);
    }

    // ----------------------------------------------------------- commands

    /// Tasks: Run Task.
    pub fn runTaskCmd(t: *Tasks) void {
        t.act(.pick);
    }

    /// Tasks: Run Build Task (Ctrl+Shift+B).
    pub fn runBuildCmd(t: *Tasks) void {
        t.act(.build);
    }

    /// Tasks: Run Test Task.
    pub fn runTestCmd(t: *Tasks) void {
        t.act(.@"test");
    }

    fn act(t: *Tasks, a: Action) void {
        if (!t.loaded.load(.acquire)) {
            t.after_load = a;
            return t.say(.info, "Loading the tasks...", .{});
        }
        switch (a) {
            .pick => t.openRunPicker(null) catch |e| log.warn("task picker: {t}", .{e}),
            .build, .@"test" => {
                const kind: Task.GroupKind = if (a == .build) .build else .@"test";
                const l = t.current();
                if (l.defaultFor(if (a == .build) .build else .@"test")) |task| return t.start(task.label);
                const any = for (l.all()) |*task| {
                    if (task.group) |g| if (g.kind == kind) break true;
                } else false;
                if (!any) return t.say(.info, "No {s} task: add one with Tasks: Configure Task", .{if (kind == .build) "build" else "test"});
                t.openRunPicker(kind) catch |e| log.warn("task picker: {t}", .{e});
            },
        }
    }

    /// Runs task `label` (UI thread).
    pub fn start(t: *Tasks, label: []const u8) void {
        const r = t.runner.run(label, .{}) catch |e| return t.say(.error_, "Task '{s}' did not start: {t}", .{ label, e });
        if (r.message) |m| return t.say(.warning, "Task '{s}' did not start: {s}", .{ label, m });
        t.started.append(t.gpa, r) catch {};
        t.remember(label);
    }

    fn remember(t: *Tasks, label: []const u8) void {
        for (t.recent.items, 0..) |l, i| if (std.mem.eql(u8, l, label)) {
            const x = t.recent.orderedRemove(i);
            t.recent.insert(t.gpa, 0, x) catch t.gpa.free(x);
            return;
        };
        const copy = t.gpa.dupe(u8, label) catch return;
        t.recent.insert(t.gpa, 0, copy) catch t.gpa.free(copy);
        if (t.recent.items.len > 20) t.gpa.free(t.recent.pop().?);
    }

    /// The runs started here that still run (background ones included).
    fn running(t: *Tasks, out: *std.ArrayList(*TaskRunner.TaskRun), a: Allocator) !void {
        for (t.started.items) |r| {
            const s = t.runner.status(r);
            if (s.state == .running or s.state == .pending or s.background_active) try out.append(a, r);
        }
    }

    /// Tasks: Terminate Task.
    pub fn terminateCmd(t: *Tasks) void {
        t.pickRunning(.terminate);
    }

    /// Tasks: Restart Running Task.
    pub fn restartCmd(t: *Tasks) void {
        t.pickRunning(.restart);
    }

    fn pickRunning(t: *Tasks, kind: PickKind) void {
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        var runs: std.ArrayList(*TaskRunner.TaskRun) = .empty;
        t.running(&runs, arena.allocator()) catch return;
        if (runs.items.len == 0) return t.say(.info, "No task is running", .{});
        if (runs.items.len == 1) return t.onRunning(kind, runs.items[0]);
        t.openRunningPicker(kind, runs.items) catch |e| log.warn("task picker: {t}", .{e});
    }

    fn onRunning(t: *Tasks, kind: PickKind, r: *TaskRunner.TaskRun) void {
        t.runner.terminate(r);
        if (kind == .restart) t.start(r.label);
    }

    /// Tasks: Configure Task: opens `.zigguro/tasks.zon`, written from
    /// the template first when the workspace has none.
    pub fn configureCmd(t: *Tasks) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.zigguro/tasks.zon", .{t.root}) catch return;
        t.writeTemplate() catch |e| return t.say(.error_, "Could not write .zigguro/tasks.zon: {t}", .{e});
        t.host.open_file(t.host.ctx, path);
    }

    fn writeTemplate(t: *Tasks) !void {
        var root = try Io.Dir.cwd().openDir(t.io, t.root, .{});
        defer root.close(t.io);
        root.access(t.io, ".zigguro/tasks.zon", .{}) catch |e| switch (e) {
            error.FileNotFound => {
                try root.createDirPath(t.io, ".zigguro");
                try root.writeFile(t.io, .{ .sub_path = ".zigguro/tasks.zon", .data = zg_dap.tasks.commands.configure_template });
                var full: [std.fs.max_path_bytes]u8 = undefined;
                t.fileChanged(std.fmt.bufPrint(&full, "{s}/.zigguro/tasks.zon", .{t.root}) catch return);
                return;
            },
            else => return e,
        };
    }

    fn say(t: *Tasks, severity: Severity, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        t.host.notify(t.host.ctx, severity, s);
    }

    // ------------------------------------------------------------- pickers

    const run_vtable: quick_pick.Provider.VTable = .{
        .placeholder = "Select the task to run",
        .items = pickItems,
        .accept = pickAccept,
    };

    /// The task picker: every task (`group`: that group's), the ones run
    /// last first; disabled ones say why.
    fn openRunPicker(t: *Tasks, group: ?Task.GroupKind) !void {
        const w = t.win orelse return;
        t.pick.close(w);
        _ = t.pick_arena.reset(.retain_capacity);
        const a = t.pick_arena.allocator();
        const l = t.current();
        var tasks_: std.ArrayList(*const Task) = .empty;
        for (t.recent.items) |label| if (l.byLabel(label)) |task| if (inGroup(task, group)) try tasks_.append(a, task);
        for (l.all()) |*task| {
            if (!inGroup(task, group)) continue;
            const seen = for (t.recent.items) |label| {
                if (std.mem.eql(u8, label, task.label)) break true;
            } else false;
            if (!seen) try tasks_.append(a, task);
        }
        t.pick_items = try a.alloc(quick_pick.QpItem, tasks_.items.len);
        t.pick_labels = try a.alloc([]const u8, tasks_.items.len);
        const recent_n = @min(t.recent.items.len, tasks_.items.len);
        for (tasks_.items, t.pick_items, t.pick_labels, 0..) |task, *it, *lab, i| {
            lab.* = task.label;
            it.* = .{
                .id = i,
                .label = task.label,
                .description = try describe(a, task),
                .detail = if (!task.enabled) try std.fmt.allocPrint(a, "Cannot run: {s}", .{task.disabled_reason orelse "disabled"}) else task.detail orelse "",
                .group = if (i < recent_n and recentHas(t, task.label)) "recently used" else sourceName(task.source),
            };
        }
        t.pick_kind = .run;
        t.pick_title = if (group) |g| switch (g) {
            .build => "Run Build Task",
            .@"test" => "Run Test Task",
            .none => "Run Task",
        } else if (t.pick_items.len == 0) "Run Task (no tasks: Tasks: Configure Task adds some)" else "Run Task";
        const provs = [_]quick_pick.Provider{.{ .ptr = t, .vtable = &run_vtable }};
        t.pick = try quick_pick.openQuickPick(w, .{ .providers = &provs, .title = t.pick_title, .test_id = "task-picker" });
    }

    fn recentHas(t: *const Tasks, label: []const u8) bool {
        for (t.recent.items) |l| if (std.mem.eql(u8, l, label)) return true;
        return false;
    }

    fn inGroup(task: *const Task, group: ?Task.GroupKind) bool {
        const g = group orelse return true;
        const tg = task.group orelse return false;
        return tg.kind == g;
    }

    fn sourceName(s: Task.Source) []const u8 {
        return switch (s) {
            .zig => "zig build",
            .zon => ".zigguro/tasks.zon",
            .vscode => ".vscode/tasks.json",
        };
    }

    fn describe(a: Allocator, task: *const Task) ![]const u8 {
        if (task.group) |g| if (g.kind != .none) {
            return std.fmt.allocPrint(a, "{s}{s}", .{ if (g.is_default) "default " else "", if (g.kind == .build) "build" else "test" });
        };
        return if (task.is_background) "background" else "";
    }

    fn openRunningPicker(t: *Tasks, kind: PickKind, runs: []const *TaskRunner.TaskRun) !void {
        const w = t.win orelse return;
        t.pick.close(w);
        _ = t.pick_arena.reset(.retain_capacity);
        const a = t.pick_arena.allocator();
        t.pick_items = try a.alloc(quick_pick.QpItem, runs.len);
        t.pick_runs = try a.dupe(*TaskRunner.TaskRun, runs);
        for (runs, t.pick_items, 0..) |r, *it, i| it.* = .{ .id = i, .label = try a.dupe(u8, r.label) };
        t.pick_kind = kind;
        t.pick_title = if (kind == .terminate) "Terminate Task" else "Restart Task";
        const provs = [_]quick_pick.Provider{.{ .ptr = t, .vtable = &run_vtable }};
        t.pick = try quick_pick.openQuickPick(w, .{ .providers = &provs, .title = t.pick_title, .test_id = "task-picker" });
    }

    fn pickItems(ptr: ?*anyopaque) []const quick_pick.QpItem {
        const t: *Tasks = @ptrCast(@alignCast(ptr.?));
        return t.pick_items;
    }

    fn pickAccept(ptr: ?*anyopaque, items: []const quick_pick.QpItem, _: ?[]const u8, _: bool) void {
        const t: *Tasks = @ptrCast(@alignCast(ptr.?));
        if (items.len == 0) return;
        const i: usize = @intCast(items[0].id);
        switch (t.pick_kind) {
            .run => {
                if (i >= t.pick_labels.len) return;
                const label = t.pick_labels[i];
                if (t.current().byLabel(label)) |task| if (!task.enabled)
                    return t.say(.warning, "'{s}' cannot run: {s}", .{ label, task.disabled_reason orelse "disabled" });
                t.start(label);
            },
            .terminate, .restart => if (i < t.pick_runs.len) t.onRunning(t.pick_kind, t.pick_runs[i]),
        }
    }

    // ------------------------------------------------------------ problems

    /// Runner worker: a copy goes to the UI thread.
    fn problemsSet(ctx: *anyopaque, owner: []const u8, label: []const u8, problems: []const pm.Problem) void {
        const t: *Tasks = @ptrCast(@alignCast(ctx));
        const id = std.fmt.parseInt(u32, owner["task:".len..], 10) catch return;
        const box = t.gpa.create(ProblemsMsg) catch return;
        box.* = .{ .arena = .init(t.gpa), .owner = id, .label = undefined, .problems = undefined };
        const a = box.arena.allocator();
        copy: {
            box.label = a.dupe(u8, label) catch break :copy;
            const ps = a.alloc(pm.Problem, problems.len) catch break :copy;
            for (problems, ps) |*p, *q| {
                q.* = p.*;
                q.file = a.dupe(u8, p.file) catch break :copy;
                q.message = a.dupe(u8, p.message) catch break :copy;
                q.code = a.dupe(u8, p.code) catch break :copy;
                q.source = a.dupe(u8, p.source) catch break :copy;
                q.related = &.{};
            }
            box.problems = ps;
            return t.inbox.push(.{ .problems = box });
        }
        box.destroy(t.gpa);
    }

    fn problemsReveal(ctx: *anyopaque) void {
        const t: *Tasks = @ptrCast(@alignCast(ctx));
        t.inbox.push(.reveal_problems);
    }

    /// UI thread: a run's problems replace its earlier ones (and those
    /// of the task's previous run).
    fn applyProblems(t: *Tasks, m: *const ProblemsMsg) !void {
        const d = t.diags orelse return;
        const st = d.store;
        const owner: Store.Owner = .{ .task = m.owner };
        if (t.owners.getPtr(m.label)) |old| {
            if (old.* != m.owner) try st.clearOwner(.{ .task = old.* });
            old.* = m.owner;
        } else {
            const key = try t.gpa.dupe(u8, m.label);
            errdefer t.gpa.free(key);
            try t.owners.put(t.gpa, key, m.owner);
        }
        try st.clearOwner(owner);
        // By file, in the order they came.
        var done: std.ArrayList(bool) = .empty;
        defer done.deinit(t.gpa);
        try done.appendNTimes(t.gpa, false, m.problems.len);
        for (m.problems, 0..) |first, i| {
            if (done.items[i]) continue;
            const set = try Store.Set.create(t.gpa, owner);
            var ok = false;
            defer if (!ok) set.destroy();
            var diags: std.ArrayList(Store.Diagnostic) = .empty;
            const sa = set.allocator();
            for (m.problems[i..], i..) |*p, j| {
                if (done.items[j] or !std.mem.eql(u8, p.file, first.file)) continue;
                done.items[j] = true;
                try diags.append(sa, try toDiagnostic(sa, p));
            }
            set.diags = diags.items;
            set.finish();
            const key = try st.keyOfPath(t.gpa, first.file);
            defer t.gpa.free(key);
            ok = true;
            try d.replaceExternal(key, owner, set, .utf8);
        }
        t.host.changed(t.host.ctx);
    }

    fn toDiagnostic(a: Allocator, p: *const pm.Problem) !Store.Diagnostic {
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

    // ----------------------------------------------------------- terminals

    /// Runner worker: a record now, the terminal once hooked up.
    fn termOpen(ctx: *anyopaque, spec: TaskRunner.TermSpec) anyerror!TaskRunner.TermHandle {
        const t: *Tasks = @ptrCast(@alignCast(ctx));
        const rec = try t.gpa.create(Term);
        errdefer t.gpa.destroy(rec);
        rec.* = .{ .tasks = t, .arena = .init(t.gpa), .spec = undefined };
        errdefer rec.arena.deinit();
        const a = rec.arena.allocator();
        var s = spec;
        s.title = try a.dupe(u8, spec.title);
        const argv = try a.alloc([]const u8, spec.argv.len);
        for (spec.argv, argv) |x, *y| y.* = try a.dupe(u8, x);
        s.argv = argv;
        s.cwd = try a.dupe(u8, spec.cwd);
        s.panel_key = if (spec.panel_key) |k| try a.dupe(u8, k) else null;
        if (spec.env) |e| if (e != t.env) {
            rec.env = try e.clone(t.gpa);
            s.env = &rec.env.?;
        };
        rec.spec = s;
        t.terms_mutex.lockUncancelable(t.io);
        defer t.terms_mutex.unlock(t.io);
        try t.terms.ensureUnusedCapacity(t.gpa, 1);
        rec.handle = t.next_term;
        t.next_term += 1;
        t.terms.putAssumeCapacity(rec.handle, rec);
        return rec.handle;
    }

    fn recOf(t: *Tasks, h: TaskRunner.TermHandle) ?*Term {
        t.terms_mutex.lockUncancelable(t.io);
        defer t.terms_mutex.unlock(t.io);
        return t.terms.get(h);
    }

    fn termTap(ctx: *anyopaque, h: TaskRunner.TermHandle, sink: TaskRunner.OutputSink) void {
        const t: *Tasks = @ptrCast(@alignCast(ctx));
        const rec = t.recOf(h) orelse return;
        rec.mutex.lockUncancelable(t.io);
        defer rec.mutex.unlock(t.io);
        rec.sink = sink;
    }

    /// The runner's last call for a terminal: start it on the UI thread.
    fn termOnExit(ctx: *anyopaque, h: TaskRunner.TermHandle, cb: TaskRunner.ExitCb) void {
        const t: *Tasks = @ptrCast(@alignCast(ctx));
        const rec = t.recOf(h) orelse return cb.exited(cb.ctx, null);
        {
            rec.mutex.lockUncancelable(t.io);
            defer rec.mutex.unlock(t.io);
            rec.exit = cb;
        }
        t.inbox.push(.{ .start = rec });
    }

    fn termKill(ctx: *anyopaque, h: TaskRunner.TermHandle) void {
        const t: *Tasks = @ptrCast(@alignCast(ctx));
        const rec = t.recOf(h) orelse return;
        rec.mutex.lockUncancelable(t.io);
        defer rec.mutex.unlock(t.io);
        rec.killed = true;
        if (rec.panel) |p| p.kill(.kill_tree);
    }

    /// UI thread: opens the record's terminal and starts the task in it.
    fn startTerm(t: *Tasks, rec: *Term) void {
        if (rec.isKilled()) return rec.reportExit(null);
        const s = rec.spec;
        // A finished terminal of the same panel makes room.
        if (s.panel_key) |key| while (t.finishedPanel(key, rec)) |old| t.host.close_terminal(t.host.ctx, old);
        const panel = t.host.open_terminal(t.host.ctx, s.title, s.reveal == .always, s.focus) orelse {
            t.say(.error_, "No terminal for task '{s}'", .{s.title});
            return rec.reportExit(null);
        };
        panel.transient = true;
        panel.shell_integration = false;
        if (s.env) |e| panel.env = e;
        panel.start_cwd = s.cwd;
        panel.on_bytes = .{ .ctx = rec, .f = onPanelBytes };
        panel.on_exit = .{ .ctx = rec, .f = onPanelExit };
        panel.on_destroy = .{ .ctx = rec, .f = onPanelDestroyHook };
        if (s.echo) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(t.gpa);
            line.appendSlice(t.gpa, "\x1b[1m> Executing task: ") catch {};
            for (s.argv, 0..) |arg, i| {
                if (i > 0) line.append(t.gpa, ' ') catch {};
                line.appendSlice(t.gpa, arg) catch {};
            }
            line.appendSlice(t.gpa, " <\x1b[0m\r\n\r\n") catch {};
            panel.view.feed(line.items);
        }
        {
            rec.mutex.lockUncancelable(t.io);
            defer rec.mutex.unlock(t.io);
            rec.panel = panel;
        }
        if (s.argv.len == 0 or s.argv.len > 33) {
            panel.setNote("too many arguments", .{});
            return rec.reportExit(null);
        }
        panel.startShell(s.argv[0], s.argv[1..]);
        if (panel.pty == null) rec.reportExit(null);
        t.host.changed(t.host.ctx);
    }

    /// A terminal of panel `key` whose task ended (other than `except`).
    fn finishedPanel(t: *Tasks, key: []const u8, except: *Term) ?*TerminalPanel {
        t.terms_mutex.lockUncancelable(t.io);
        defer t.terms_mutex.unlock(t.io);
        for (t.terms.values()) |rec| {
            if (rec == except) continue;
            const k = rec.spec.panel_key orelse continue;
            if (!std.mem.eql(u8, k, key)) continue;
            rec.mutex.lockUncancelable(t.io);
            defer rec.mutex.unlock(t.io);
            if (rec.exit == null) if (rec.panel) |p| return p;
        }
        return null;
    }

    /// Reader thread.
    fn onPanelBytes(ctx: *anyopaque, bytes: []const u8) void {
        const rec: *Term = @ptrCast(@alignCast(ctx));
        const sink = blk: {
            rec.mutex.lockUncancelable(rec.tasks.io);
            defer rec.mutex.unlock(rec.tasks.io);
            break :blk rec.sink;
        } orelse return;
        sink.bytes(sink.ctx, bytes);
    }

    fn onPanelExit(ctx: *anyopaque, code: ?u8) void {
        const rec: *Term = @ptrCast(@alignCast(ctx));
        rec.reportExit(code);
        rec.tasks.host.changed(rec.tasks.host.ctx);
    }

    fn onPanelDestroyHook(ctx: *anyopaque) void {
        onPanelDestroy(@ptrCast(@alignCast(ctx)));
    }

    /// The tab closed: the task ends with it.
    fn onPanelDestroy(rec: *Term) void {
        {
            rec.mutex.lockUncancelable(rec.tasks.io);
            defer rec.mutex.unlock(rec.tasks.io);
            if (rec.panel) |p| {
                p.on_bytes = null;
                p.on_exit = null;
                p.on_destroy = null;
            }
            rec.panel = null;
        }
        rec.reportExit(null);
    }

    // ---------------------------------------------------------- the check

    /// Agent thread: runs the `check` task headless and waits until its
    /// problems are in the store.
    fn runBuildCheck(ctx: *anyopaque, io: Io, arena: Allocator, timeout: Io.Duration) anyerror!SettleDetector.BuildSummary {
        const t: *Tasks = @ptrCast(@alignCast(ctx));
        const task = t.current().tagged("check") orelse return .{ .label = "zig build check", .ok = false, .err = "the workspace has no check step" };
        const r = try t.runner.run(task.label, .{ .headless = true, .deadline = zg_core.runtime.Deadline.after(io, timeout) });
        const s = try t.runner.wait(r, arena);
        t.flushProblems(io);
        return .{
            .label = try arena.dupe(u8, task.label),
            .ok = s.state == .succeeded,
            .exit_code = s.exit_code,
            .duration_ns = s.duration_ms * std.time.ns_per_ms,
            .timed_out = s.timed_out,
            .err = if (s.message) |m| try arena.dupe(u8, m) else null,
        };
    }

    /// Any thread but the UI's: waits (up to 2 s) until the problems
    /// queued so far are applied.
    fn flushProblems(t: *Tasks, io: Io) void {
        if (t.rt.isUiThread()) return t.inbox.drain();
        var ev: Io.Event = .unset;
        t.inbox.push(.{ .fence = &ev });
        const deadline = zg_core.runtime.Deadline.after(io, .fromSeconds(2));
        while (!ev.isSet() and !deadline.expired(io)) ev.waitTimeout(io, deadline.timeout()) catch {};
        // Gone without running: the event must not be set later.
        if (!ev.isSet()) t.inbox.cancelFence(&ev);
    }

    // ---------------------------------------------------- variable hooks

    fn noConfig(_: *anyopaque, _: []const u8, _: Allocator) ?[]const u8 {
        return null;
    }

    fn noCommand(_: *anyopaque, _: []const u8, _: Allocator) anyerror!?[]const u8 {
        return error.CommandNotAllowed;
    }

    fn noInput(_: *anyopaque, def: *const variables.InputDef, _: Allocator) anyerror!?[]const u8 {
        return def.default;
    }
};

/// A task's terminal: the runner's handle, its spec and hooks, and the
/// panel once open. Freed with the service.
const Term = struct {
    tasks: *Tasks,
    handle: TaskRunner.TermHandle = 0,
    arena: std.heap.ArenaAllocator,
    spec: TaskRunner.TermSpec,
    env: ?std.process.Environ.Map = null,
    /// Guards the fields below.
    mutex: Io.Mutex = .init,
    sink: ?TaskRunner.OutputSink = null,
    /// Null once reported.
    exit: ?TaskRunner.ExitCb = null,
    panel: ?*TerminalPanel = null,
    killed: bool = false,

    fn destroy(rec: *Term) void {
        const gpa = rec.tasks.gpa;
        if (rec.env) |*e| e.deinit();
        rec.arena.deinit();
        gpa.destroy(rec);
    }

    fn isKilled(rec: *Term) bool {
        rec.mutex.lockUncancelable(rec.tasks.io);
        defer rec.mutex.unlock(rec.tasks.io);
        return rec.killed;
    }

    /// Tells the runner once.
    fn reportExit(rec: *Term, code: ?u8) void {
        const cb = blk: {
            rec.mutex.lockUncancelable(rec.tasks.io);
            defer rec.mutex.unlock(rec.tasks.io);
            const cb = rec.exit;
            rec.exit = null;
            rec.sink = null;
            break :blk cb;
        } orelse return;
        cb.exited(cb.ctx, code);
    }
};

const ProblemsMsg = struct {
    arena: std.heap.ArenaAllocator,
    owner: u32,
    label: []const u8,
    problems: []const pm.Problem,

    fn destroy(m: *ProblemsMsg, gpa: Allocator) void {
        m.arena.deinit();
        gpa.destroy(m);
    }
};

const Msg = union(enum) {
    problems: *ProblemsMsg,
    start: *Term,
    list_changed,
    reveal_problems,
    fence: *Io.Event,
};

/// Messages for the UI thread; outlives the service while a run of it is
/// queued.
const Inbox = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    refs: std.atomic.Value(u32) = .init(1),
    posted: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Msg) = .empty,
    /// Null once the service is going (guarded by `mutex`).
    tasks: ?*Tasks,

    fn push(q: *Inbox, m: Msg) void {
        const queued = blk: {
            q.mutex.lockUncancelable(q.io);
            defer q.mutex.unlock(q.io);
            if (q.tasks == null) break :blk false;
            q.items.append(q.gpa, m) catch break :blk false;
            break :blk true;
        };
        // Going (or no memory): dropped, a terminal ends unstarted.
        if (!queued) return q.freeMsg(m);
        if (q.posted.swap(true, .acq_rel)) return;
        _ = q.refs.fetchAdd(1, .monotonic);
        q.app.post(.{ .ctx = q, .f = run }) catch {
            q.posted.store(false, .release);
            _ = q.refs.fetchSub(1, .monotonic);
        };
    }

    fn freeMsg(q: *Inbox, m: Msg) void {
        const gpa = q.gpa;
        switch (m) {
            .problems => |p| p.destroy(gpa),
            .start => |rec| rec.reportExit(null),
            .fence => |ev| ev.set(q.io),
            .list_changed, .reveal_problems => {},
        }
    }

    fn run(ctx: *anyopaque, _: *zg_gui.App) void {
        const q: *Inbox = @ptrCast(@alignCast(ctx));
        q.posted.store(false, .release);
        q.drain();
        q.release();
    }

    /// UI thread.
    fn drain(q: *Inbox) void {
        var items: std.ArrayList(Msg) = .empty;
        defer items.deinit(q.gpa);
        const t = blk: {
            q.mutex.lockUncancelable(q.io);
            defer q.mutex.unlock(q.io);
            std.mem.swap(std.ArrayList(Msg), &items, &q.items);
            break :blk q.tasks;
        };
        for (items.items) |m| {
            const tk = t orelse {
                q.freeMsg(m);
                continue;
            };
            switch (m) {
                .problems => |p| {
                    tk.applyProblems(p) catch |e| log.warn("task problems: {t}", .{e});
                    p.destroy(q.gpa);
                },
                .start => |rec| tk.startTerm(rec),
                .list_changed => tk.onListChanged(),
                .reveal_problems => tk.host.show_problems(tk.host.ctx),
                .fence => |ev| ev.set(q.io),
            }
        }
    }

    /// A fence that timed out: drop it.
    fn cancelFence(q: *Inbox, ev: *Io.Event) void {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        var i: usize = q.items.items.len;
        while (i > 0) {
            i -= 1;
            if (q.items.items[i] == .fence and q.items.items[i].fence == ev) _ = q.items.orderedRemove(i);
        }
    }

    /// UI thread: the service is going. What is queued is dropped, and
    /// so is what comes later (a terminal ends without starting).
    fn shutDown(q: *Inbox) void {
        var items: std.ArrayList(Msg) = .empty;
        {
            q.mutex.lockUncancelable(q.io);
            defer q.mutex.unlock(q.io);
            q.tasks = null;
            std.mem.swap(std.ArrayList(Msg), &items, &q.items);
        }
        for (items.items) |m| q.freeMsg(m);
        items.deinit(q.gpa);
    }

    fn release(q: *Inbox) void {
        if (q.refs.fetchSub(1, .acq_rel) == 1) q.gpa.destroy(q);
    }
};
