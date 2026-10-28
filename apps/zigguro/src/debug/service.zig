//! Debugging in the workbench (E07.F07.S01.T01): the workspace's debug
//! sessions (zg_dap's `DebugManager`), its breakpoints, its launch
//! configurations and an inspection model per session, behind the Run
//! and Debug panel and the `debug.*` commands.
//!
//! - Made on first use (a debug command, F9 or the panel), so a window
//!   that never debugs reads no debug files.
//! - Adapters come from the adapter registry (guarded here: it is not
//!   thread-safe and both session workers and the generated
//!   configurations' worker use it). Pre-launch tasks run through the
//!   task service's runner; the generated configurations' tasks ("zig
//!   build" and the test build of the current file) run here.
//! - Session changes arrive from the manager's listener on any thread and
//!   the inspection models' results from the sessions' dispatchers; both
//!   reach a ref-counted `Inbox` that wakes the UI thread once per batch.
//!   There each session's `Inspector` applies them, and `generation`
//!   bumps for the views.
//! - An ended session leaves the views at once and is freed on a worker.
//! - Breakpoints show in the gutter of every open editor and follow its
//!   edits (zg_codeintel's `BreakpointGutter`, flushed by `onFrame`); the
//!   saved ones are read on a worker.
//! - While paused, an expression under the pointer shows its value
//!   (`hover.zig`, ahead of the language hover).
//! - State: `.zigguro/debug/breakpoints.zon`, `watches.zon` and
//!   `repl_history.zon` under the workspace (written on change).
//!
//! UI thread only, except where noted.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_dap = @import("zg_dap");
const zg_editor = @import("zg_editor");
const zg_codeintel = @import("zg_codeintel");
const configs_mod = @import("configs.zig");
const call_stack = @import("call_stack.zig");
const toolbar = @import("toolbar.zig");
const var_tree = @import("var_tree.zig");
const bp_view = @import("bp_view.zig");
const hover_mod = @import("hover.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const DebugManager = zg_dap.session.DebugManager;
const DebugSession = zg_dap.session.DebugSession;
const BreakpointManager = zg_dap.breakpoints.BreakpointManager;
const ConfigSet = zg_dap.config.ConfigSet;
const LaunchConfig = zg_dap.config.LaunchConfig;
const zig_autoconfig = zg_dap.config.zig_autoconfig;
const Registry = zg_dap.adapters.Registry;
const TaskRunner = zg_dap.tasks.TaskRunner;
const Inspector = zg_dap.inspect.Inspector;
const Watches = zg_dap.inspect.Watches;
const variables = zg_dap.variables;
const quick_pick = zg_gui.w.quick_pick;
const Severity = zg_gui.w.notification_center.Severity;
const ToastAction = zg_gui.w.notification_center.ToastAction;
const Window = zg_gui.Window;
const BreakpointGutter = zg_codeintel.debug.BreakpointGutter;
const Document = zg_editor.model.document.Document;
const DecorationStore = zg_editor.model.decorations.store.DecorationStore;
const EditorView = zg_editor.view.EditorView;
const PointerEvent = zg_editor.view.editor_view.PointerEvent;
const log = std.log.scoped(.debug_ui);

/// Where the debug state lives, under the workspace.
pub const state_dir = ".zigguro";

/// What the service needs from the workbench (UI thread).
pub const Host = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, severity: Severity, actions: []const ToastAction, text: []const u8) void,
    /// Something to repaint.
    changed: *const fn (ctx: *anyopaque) void,
    /// The active editor's file (absolute) and 1-based caret line and
    /// column; null without one.
    cursor: *const fn (ctx: *anyopaque, buf: []u8) ?Cursor,
    /// Shows `path` at the 1-based line and column (`focus`: and moves
    /// focus there).
    reveal: *const fn (ctx: *anyopaque, path: []const u8, line: u32, column: u32, focus: bool) void,
    /// Brings the Run and Debug panel up.
    show_panel: *const fn (ctx: *anyopaque) void,
};

pub const Cursor = struct { path: []const u8, line: u32, column: u32 };

pub const Options = struct {
    trusted: bool = false,
    /// `zig.path` (null: `zig` on PATH).
    zig_exe: ?[]const u8 = null,
    /// The task service's runner, for pre-launch and post-debug tasks.
    runner: ?*TaskRunner = null,
    /// Look for the generated configurations now (tests leave it off).
    autos: bool = true,
    /// The gutter's breakpoint and execution pointer styles (null: the
    /// editor's defaults).
    gutter_styles: ?BreakpointGutter.Styles = null,
};

const no_style: zg_editor.model.decorations.store.StyleRef = @enumFromInt(0);
const default_gutter_styles: BreakpointGutter.Styles = .{
    .enabled = no_style,
    .disabled = no_style,
    .unverified = no_style,
    .warning = no_style,
    .anchor = no_style,
    .exec_top = no_style,
    .exec_selected = no_style,
};

/// One session as the views see it.
pub const Entry = struct {
    s: *DebugSession,
    id: u32,
    insp: Inspector,
    /// The user took this session from the agent.
    taken: bool = false,
};

/// What the open picker is for.
const PickKind = enum { config, start, session, targets };

pub const Debug = struct {
    gpa: Allocator,
    io: Io,
    rt: *zg_core.Runtime,
    app: *zg_gui.App,
    win: ?*Window = null,
    host: Host,
    env: *const std.process.Environ.Map,
    root: []u8,
    zig_exe: []u8,
    root_dir: ?Io.Dir,
    trusted: bool,
    runner: ?*TaskRunner,

    reg_mutex: Io.Mutex = .init,
    reg: Registry,
    reg_resolver: DebugManager.RegistryResolver = undefined,
    bps: BreakpointManager,
    /// Breakpoint lines in open editors, and their gutter marks.
    gutter: BreakpointGutter,
    /// The `generation` the execution pointer was drawn at.
    exec_seen: u64 = 0,
    /// The models the views show without a session: the watch list
    /// (saved to `watches.zon`; each session starts with a copy).
    no_session: Inspector = undefined,
    /// The editors' debug hover, and the `generation` it was read at.
    hover: hover_mod.DebugHover = undefined,
    hover_seen: u64 = 0,
    mgr: DebugManager = undefined,
    vars: variables.VarContext = undefined,
    file_buf: [std.fs.max_path_bytes]u8 = undefined,
    configs: ConfigSet.Cache,

    /// The generated configurations (from a worker; `autos_arena` owns
    /// them).
    autos: []const LaunchConfig = &.{},
    autos_arena: ?*std.heap.ArenaAllocator = null,
    /// Replaced lists, kept until `destroy`: a session worker may still
    /// read one (`runTask`).
    retired_autos: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    autos_loading: bool = false,
    /// The configuration F5 starts (`kind` and name), null until chosen.
    selected: ?struct { kind: configs_mod.Kind, name: []u8 } = null,

    entries: std.ArrayList(*Entry) = .empty,
    /// Ids of sessions that ended (their late changes are dropped).
    dropped: std.AutoHashMapUnmanaged(u32, void) = .empty,
    active_id: ?u32 = null,
    /// Bumps when anything the views show changed.
    generation: u64 = 1,
    /// A session whose stop the call stack should reveal (its stopped
    /// thread, once the frames are there).
    reveal_req: ?u32 = null,
    /// The next frame reveal also focuses the editor.
    focus_reveal: bool = false,
    /// Workers that use the service (removals, compounds, the
    /// generated configurations); `destroy` waits for `idle`.
    busy_mutex: Io.Mutex = .init,
    busy: u32 = 0,
    idle: Io.Event = .is_set,
    compound_busy: bool = false,

    inbox: *Inbox,

    pick: quick_pick.QuickPickHandle = .{},
    pick_arena: std.heap.ArenaAllocator,
    pick_items: []quick_pick.QpItem = &.{},
    pick_entries: []configs_mod.Entry = &.{},
    pick_ids: []u32 = &.{},
    pick_targets: []i64 = &.{},
    pick_target_session: u32 = 0,
    pick_target_thread: i64 = 0,
    pick_kind: PickKind = .config,

    pub fn create(rt: *zg_core.Runtime, app: *zg_gui.App, env: *const std.process.Environ.Map, root: []const u8, host: Host, opts: Options) !*Debug {
        const gpa = rt.gpa;
        const d = try gpa.create(Debug);
        errdefer gpa.destroy(d);
        const root_copy = try gpa.dupe(u8, root);
        errdefer gpa.free(root_copy);
        const zig_copy = try gpa.dupe(u8, opts.zig_exe orelse "zig");
        errdefer gpa.free(zig_copy);
        const inbox = try gpa.create(Inbox);
        errdefer gpa.destroy(inbox);
        inbox.* = .{ .gpa = gpa, .io = rt.io, .app = app, .debug = d };
        var reg = try Registry.init(gpa, .{ .trusted = opts.trusted });
        errdefer reg.deinit();
        const root_dir = Io.Dir.cwd().openDir(rt.io, root, .{}) catch null;
        d.* = .{
            .gpa = gpa,
            .io = rt.io,
            .rt = rt,
            .app = app,
            .host = host,
            .env = env,
            .root = root_copy,
            .zig_exe = zig_copy,
            .root_dir = root_dir,
            .trusted = opts.trusted,
            .runner = opts.runner,
            .reg = reg,
            .bps = .init(gpa, rt.io, .{ .persist = if (root_dir) |rd| .{
                .dir = rd,
                .path = state_dir ++ "/" ++ zg_dap.breakpoints.persist.sub_path,
                .workspace_root = root_copy,
            } else null }),
            .gutter = .init(gpa, rt.io, opts.gutter_styles orelse default_gutter_styles),
            .configs = .init(gpa, .{ .root = root_copy, .trusted = opts.trusted }, builtin.os.tag),
            .inbox = inbox,
            .pick_arena = .init(gpa),
        };
        inbox.debug_ptr = d;
        d.bps.opts.host = d.gutter.host();
        try d.gutter.bind(&d.bps);
        try d.no_session.init(gpa, rt.io, null, .none, .{});
        try d.hover.init(gpa, d.varHooks());
        d.hover.target_of = hoverTargetOf;
        if (root_dir) |rd| d.no_session.watches.persist_to = .{ .dir = rd, .path = state_dir ++ "/" ++ Watches.sub_path };
        d.reg_resolver = .{ .reg = &d.reg, .io = rt.io, .env = env };
        d.vars = .{
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
            .ctx = d,
        };
        d.mgr = .init(rt, .{
            .resolver = .{ .ctx = d, .resolve = resolveLocked },
            .tasks = .{ .ctx = d, .run = runTask },
            .breakpoints = d.bps.sink(),
            .trusted = opts.trusted,
            .vars = &d.vars,
        });
        try d.mgr.subscribe(.{ .ctx = inbox, .func = Inbox.onSession });
        try d.bps.subscribe(.{ .ctx = inbox, .func = Inbox.onBreakpoints });
        d.spawnWork(loadWork, .{});
        if (opts.autos) d.findAutos();
        return d;
    }

    /// Ends every session (waiting for their adapters) and frees the
    /// service.
    pub fn destroy(d: *Debug) void {
        const gpa = d.gpa;
        if (d.win) |w| d.pick.close(w);
        d.inbox.shutDown();
        for (d.entries.items) |e| e.s.stop();
        while (d.entries.items.len > 0) d.dropEntry(d.entries.items[d.entries.items.len - 1], false);
        d.hover.deinit();
        d.idle.waitUncancelable(d.io);
        // Freeing sessions waits for their adapters: on a worker.
        var done: Io.Event = .unset;
        d.app.spawnLoop(teardown, .{ d, &done }) catch teardown(d, &done);
        done.waitUncancelable(d.io);
        d.bps.saveNow() catch {};
        d.bps.deinit();
        d.gutter.deinit();
        d.no_session.deinit();
        d.inbox.release();
        d.entries.deinit(gpa);
        d.dropped.deinit(gpa);
        if (d.selected) |s| gpa.free(s.name);
        if (d.autos_arena) |a| freeArena(gpa, a);
        for (d.retired_autos.items) |a| freeArena(gpa, a);
        d.retired_autos.deinit(gpa);
        d.pick_arena.deinit();
        d.configs.deinit();
        d.reg.deinit();
        if (d.root_dir) |*rd| rd.close(d.io);
        gpa.free(d.zig_exe);
        gpa.free(d.root);
        gpa.destroy(d);
    }

    fn teardown(d: *Debug, done: *Io.Event) void {
        d.mgr.deinit();
        done.set(d.io);
    }

    fn freeArena(gpa: Allocator, a: *std.heap.ArenaAllocator) void {
        a.deinit();
        gpa.destroy(a);
    }

    fn say(d: *Debug, severity: Severity, comptime fmt: []const u8, args: anytype) void {
        d.sayActions(severity, &.{}, fmt, args);
    }

    fn sayActions(d: *Debug, severity: Severity, actions: []const ToastAction, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        d.host.notify(d.host.ctx, severity, actions, s);
    }

    /// Starts `func(q, args...)` on a worker that `destroy` waits for.
    fn spawnWork(d: *Debug, comptime func: anytype, args: anytype) void {
        {
            d.busy_mutex.lockUncancelable(d.io);
            defer d.busy_mutex.unlock(d.io);
            if (d.busy == 0) d.idle.reset();
            d.busy += 1;
        }
        d.inbox.retain();
        // Never inline on the UI thread (freeing a session blocks), unless
        // there are no workers at all.
        d.app.spawnLoop(func, .{d.inbox} ++ args) catch d.app.spawn(func, .{d.inbox} ++ args);
    }

    /// The end of a `spawnWork` worker.
    fn workDone(q: *Inbox) void {
        const d = q.debug_ptr;
        {
            d.busy_mutex.lockUncancelable(d.io);
            defer d.busy_mutex.unlock(d.io);
            d.busy -= 1;
            if (d.busy == 0) d.idle.set(d.io);
        }
        q.release();
    }

    fn changed(d: *Debug) void {
        d.generation += 1;
        d.host.changed(d.host.ctx);
    }

    // ------------------------------------------------------------ files

    /// Reads the saved breakpoints (a worker; the manager is
    /// thread-safe). The open editors track them once they are in.
    fn loadWork(q: *Inbox) void {
        defer workDone(q);
        const d = q.debug_ptr;
        const dir = d.root_dir orelse return;
        if (dir.readFileAlloc(d.io, state_dir ++ "/" ++ Watches.sub_path, d.gpa, .limited(1 << 20))) |text| {
            q.push(.{ .watches = text });
        } else |_| {}
        const path = state_dir ++ "/" ++ zg_dap.breakpoints.persist.sub_path;
        const text = dir.readFileAlloc(d.io, path, d.gpa, .limited(16 << 20)) catch return;
        defer d.gpa.free(text);
        d.bps.load(text) catch |e| return log.warn("{s}: {t}", .{ path, e });
        q.push(.loaded);
    }

    /// The saved watch list arrived (UI thread): sessions already running
    /// get it too.
    fn onWatchesLoaded(d: *Debug, text: []const u8) void {
        if (d.no_session.watches.results().len > 0) return; // edited meanwhile
        const keep = d.no_session.watches.persist_to;
        d.no_session.watches.persist_to = null;
        defer d.no_session.watches.persist_to = keep;
        d.no_session.watches.load(text) catch |e| return log.warn("{s}: {t}", .{ Watches.sub_path, e });
        for (d.entries.items) |e| for (d.no_session.watches.results()) |w| e.insp.watches.add(w.expr);
    }

    // ------------------------------------------------------------ hover

    /// The session the hover evaluates in: the active one, paused.
    fn hoverTarget(d: *Debug) ?hover_mod.Target {
        const e = d.active() orelse return null;
        if (!e.insp.stopped()) return null;
        return .{ .insp = &e.insp, .id = e.id };
    }

    fn hoverTargetOf(h: *hover_mod.DebugHover) ?hover_mod.Target {
        const d: *Debug = @alignCast(@fieldParentPtr("hover", h));
        return d.hoverTarget();
    }

    /// An expression of `doc` in `v`: the selection the offset is in, or
    /// the expression around it.
    const HoverSpot = struct { range: hover_mod.Range, anchor: zg_gui.core.Rect };

    fn hoverSpot(v: *EditorView, doc: *const Document, off: u64, origin: zg_gui.core.Vec2) ?HoverSpot {
        const sel = v.primarySel();
        const lo = @min(sel.anchor, sel.head);
        const hi = @max(sel.anchor, sel.head);
        const range: hover_mod.Range = if (hi > lo and off >= lo and off < hi and hi - lo <= 256 and v.lineOf(lo) == v.lineOf(hi -| 1))
            .{ .start = lo, .end = hi }
        else
            hover_mod.expressionAt(doc, off) orelse return null;
        const p0 = v.posOf(range.start);
        const p1 = v.posOf(range.end);
        const w = if (p1.y == p0.y and p1.x > p0.x) p1.x - p0.x else 8;
        return .{ .range = range, .anchor = .{ .x = origin.x + p0.x, .y = origin.y + p0.y, .w = w, .h = v.lineHeight() } };
    }

    /// `range` of `doc` as text (in `buf`).
    fn spotText(doc: *const Document, range: hover_mod.Range, buf: []u8) []const u8 {
        var n: usize = 0;
        var it = doc.tree.slice(.{ .start = range.start, .end = @min(range.end, range.start + buf.len) });
        while (it.next()) |c| {
            @memcpy(buf[n..][0..c.len], c);
            n += c.len;
        }
        return std.mem.trim(u8, buf[0..n], " \t\r\n");
    }

    /// The editors' first pointer hook (`EditorView.priority_hook`):
    /// true when the debug hover takes the pointer (or the key).
    pub fn hoverPointer(d: *Debug, v: *EditorView, doc: *const Document, e: PointerEvent) bool {
        const h = &d.hover;
        h.win = d.win;
        const now = d.app.now_ms;
        switch (e.kind) {
            .move => {
                if (d.hoverTarget() == null) {
                    if (h.busy()) h.close();
                    return false;
                }
                const off = e.offset orelse {
                    h.away(now);
                    return false;
                };
                const spot = hoverSpot(v, doc, off, e.origin) orelse {
                    h.away(now);
                    return false;
                };
                var buf: [256]u8 = undefined;
                const expr = spotText(doc, spot.range, &buf);
                if (expr.len == 0) {
                    h.away(now);
                    return false;
                }
                h.restOn(v, spot.range, expr, spot.anchor, now);
                return true;
            },
            .leave => h.away(now),
            .key => {
                if (!h.busy()) return false;
                const k = e.key orelse return false;
                switch (k.key) {
                    .shift_left, .shift_right, .control_left, .control_right, .alt_left, .alt_right, .meta_left, .meta_right => return false,
                    else => {},
                }
                h.close();
                return k.key == .escape;
            },
            else => {},
        }
        return false;
    }

    /// The debug hover at the caret of `v` (`editor.showHover` while
    /// paused); false when there is no paused session or no expression.
    pub fn showHoverAt(d: *Debug, v: *EditorView, doc: *const Document, origin: zg_gui.core.Vec2) bool {
        const t = d.hoverTarget() orelse return false;
        d.hover.win = d.win;
        const sel = v.primarySel();
        const off = if (sel.head > sel.anchor) sel.head - 1 else sel.head;
        const spot = hoverSpot(v, doc, off, origin) orelse return false;
        var buf: [256]u8 = undefined;
        const expr = spotText(doc, spot.range, &buf);
        if (expr.len == 0) return false;
        d.hover.showNow(t, v, spot.range, expr, spot.anchor);
        return true;
    }

    // ---------------------------------------------------------- watches

    /// The models the Variables and Watch views show: the active
    /// session's, else the no-session ones (the watch list alone).
    pub fn viewInspector(d: *Debug) *Inspector {
        if (d.active()) |e| return &e.insp;
        return &d.no_session;
    }

    pub fn varHooks(d: *Debug) var_tree.Hooks {
        return .{ .ctx = d, .changed = varsChanged, .watch_add = watchAdd, .watch_edit = watchEdit, .watch_remove = watchRemove, .value_set = valueSet };
    }

    /// A value was set: the active session's watches are evaluated again.
    fn valueSet(ctx: *anyopaque) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        const e = d.active() orelse return;
        const frame = e.insp.vars.frame_id orelse return;
        e.insp.watches.reevaluate(frame);
        d.changed();
    }

    fn varsChanged(ctx: *anyopaque) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        d.changed();
    }

    /// Every list gets the change; the no-session one saves it.
    pub fn watchAdd(ctx: *anyopaque, expr: []const u8) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        d.no_session.watches.add(expr);
        for (d.entries.items) |e| e.insp.watches.add(expr);
        d.changed();
    }

    fn watchEdit(ctx: *anyopaque, i: u32, expr: []const u8) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        d.no_session.watches.edit(i, expr);
        for (d.entries.items) |e| e.insp.watches.edit(i, expr);
        d.changed();
    }

    pub fn watchRemove(ctx: *anyopaque, i: u32) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        d.no_session.watches.remove(i);
        for (d.entries.items) |e| e.insp.watches.remove(i);
        d.changed();
    }

    pub fn removeAllWatchesCmd(d: *Debug) void {
        var n = d.no_session.watches.results().len;
        while (n > 0) : (n -= 1) watchRemove(d, @intCast(n - 1));
    }

    /// Values in hexadecimal, or back (when the adapter can).
    pub fn toggleHexCmd(d: *Debug) void {
        const e = d.active() orelse return d.say(.info, "Hexadecimal values need a debug session", .{});
        const on = !e.insp.vars.hex;
        e.insp.vars.setHex(on);
        if (e.insp.vars.hex != on) return d.say(.info, "The debugger cannot show values in hexadecimal", .{});
        d.changed();
    }

    /// The saved breakpoints are in: the open editors track theirs.
    fn onLoaded(d: *Debug) void {
        for (d.gutter.docs.items) |doc| d.bps.docOpened(doc.path);
    }

    /// A file was saved or changed (absolute).
    pub fn fileChanged(d: *Debug, path: []const u8) void {
        if (d.configs.fileChanged(path)) d.changed();
        d.gutter.saved(path);
    }

    /// `path` (absolute) is open in an editor showing `store`: its
    /// breakpoints follow the edits there and draw in its gutter.
    pub fn docOpened(d: *Debug, path: []const u8, doc: *const Document, store: *DecorationStore) void {
        if (d.gutter.attached(path)) return;
        d.gutter.attach(path, doc, store) catch return;
        d.bps.docOpened(path);
    }

    /// `path`'s editor closes (before its decoration store goes).
    pub fn docClosed(d: *Debug, path: []const u8) void {
        if (!d.gutter.attached(path)) return;
        d.bps.docClosed(path);
        d.gutter.detach(path);
    }

    /// Once per frame, before the editors paint: the gutter marks and the
    /// execution pointer.
    pub fn onFrame(d: *Debug) void {
        const vi = d.viewInspector();
        if (vi.watches.pendingCount() > 0 and vi.watches.tick(Io.Timestamp.now(d.io, .awake))) d.changed();
        if (d.exec_seen != d.generation) {
            d.exec_seen = d.generation;
            d.updateExec();
        }
        if (d.hover.shown != null and (d.hover_seen != d.generation or d.hover.tree.insp == null)) {
            d.hover_seen = d.generation;
            d.hover.refresh(d.hoverTarget());
        }
        d.gutter.flush();
    }

    /// The top frame of the active session's stopped thread and, when
    /// another frame is selected, that one.
    fn updateExec(d: *Debug) void {
        var top: ?zg_dap.breakpoints.decorate.FramePos = null;
        var sel: ?zg_dap.breakpoints.decorate.FramePos = null;
        if (d.active()) |e| if (e.insp.stopped()) {
            const thread = if (e.insp.stack.selected()) |x| x.thread else e.s.currentThread();
            if (thread) |t| {
                const rows = e.insp.stack.frames(t);
                if (rows.len > 0) top = framePos(&rows[0]);
                if (e.insp.stack.selectedRow()) |r| if (rows.len == 0 or r.id != rows[0].id) {
                    sel = framePos(r);
                };
            }
        };
        d.gutter.setExec(top, sel) catch {};
    }

    fn framePos(row: *const Inspector.FrameRow) ?zg_dap.breakpoints.decorate.FramePos {
        const src = row.source orelse return null;
        const path = src.path orelse return null;
        return .{ .path = path, .line = @max(row.line, 1) };
    }

    pub fn setTrusted(d: *Debug, trusted: bool) void {
        if (d.trusted == trusted) return;
        d.trusted = trusted;
        d.configs.setTrusted(trusted);
        d.mgr.cfg.trusted = trusted;
        d.changed();
    }

    /// The launch configurations (reloaded when one of the files
    /// changed).
    pub fn configSet(d: *Debug) ?*const ConfigSet {
        return d.configs.get(d.io) catch |e| {
            d.say(.error_, "Cannot read the launch configurations: {t}", .{e});
            return null;
        };
    }

    // ------------------------------------------------- generated configs

    /// Looks for the configurations of a Zig project on a worker
    /// (resolving adapters probes executables).
    fn findAutos(d: *Debug) void {
        if (d.autos_loading) return;
        d.autos_loading = true;
        d.spawnWork(autosWork, .{});
    }

    fn autosWork(q: *Inbox) void {
        defer workDone(q);
        const d = q.debug_ptr;
        const root = d.root;
        const zig_exe = d.zig_exe;
        const env = d.env;
        const arena = q.gpa.create(std.heap.ArenaAllocator) catch return;
        arena.* = .init(q.gpa);
        const a = arena.allocator();
        const io = q.io;
        const has_build = if (Io.Dir.cwd().openDir(io, root, .{})) |dir| blk: {
            var dd = dir;
            defer dd.close(io);
            dd.access(io, "build.zig", .{}) catch break :blk false;
            break :blk true;
        } else |_| false;
        const steps: []const zg_dap.tasks.zig_build.Step = if (has_build) &.{.{ .name = "install", .description = "" }} else &.{};
        const state = std.fs.path.join(a, &.{ root, state_dir }) catch return freeArena(q.gpa, arena);
        const found = blk: {
            if (!has_build) break :blk &.{};
            d.reg_mutex.lockUncancelable(io);
            defer d.reg_mutex.unlock(io);
            break :blk zig_autoconfig.autoConfigsForZig(a, io, root, steps, &d.reg, env, .{ .state_dir = state, .zig_exe = zig_exe }) catch &.{};
        };
        q.push(.{ .autos = .{ .arena = arena, .configs = found } });
    }

    fn applyAutos(d: *Debug, arena: *std.heap.ArenaAllocator, found: []const LaunchConfig) void {
        {
            d.reg_mutex.lockUncancelable(d.io);
            defer d.reg_mutex.unlock(d.io);
            if (d.autos_arena) |old| d.retired_autos.append(d.gpa, old) catch freeArena(d.gpa, old);
            d.autos_arena = arena;
            d.autos = found;
        }
        d.autos_loading = false;
        if (d.win) |w| if (d.pick.isOpen(w) and (d.pick_kind == .config or d.pick_kind == .start)) d.openConfigPicker(d.pick_kind == .start) catch {};
        d.changed();
    }

    // -------------------------------------------------------- adapters

    fn resolveLocked(ctx: ?*anyopaque, a: Allocator, cfg: *const LaunchConfig) anyerror!DebugManager.AdapterSpec {
        const d: *Debug = @ptrCast(@alignCast(ctx.?));
        d.reg_mutex.lockUncancelable(d.io);
        defer d.reg_mutex.unlock(d.io);
        const r = d.reg_resolver.resolver();
        return r.resolve(r.ctx, a, cfg);
    }

    /// Session worker: a pre-launch or post-debug task.
    fn runTask(ctx: ?*anyopaque, label: []const u8, arena: Allocator) DebugManager.TaskOutcome {
        const d: *Debug = @ptrCast(@alignCast(ctx.?));
        if (d.runner) |r| {
            var h: DebugManager.TaskRunnerHost = .{ .runner = r };
            const th = h.host();
            if (r.list.byLabel(label) != null) return th.run(th.ctx, label, arena);
            // The generated "Debug zig build run" builds with the
            // project's install step.
            if (std.mem.eql(u8, label, zig_autoconfig.build_task) and r.list.byLabel("zig build install") != null)
                return th.run(th.ctx, "zig build install", arena);
        }
        const generated = blk: {
            d.reg_mutex.lockUncancelable(d.io);
            defer d.reg_mutex.unlock(d.io);
            for (d.autos) |c| if (c.generated_task) |g| if (std.mem.eql(u8, g.label, label)) break :blk g;
            break :blk null;
        };
        if (generated) |g| return d.runGenerated(g, arena);
        if (std.mem.eql(u8, label, zig_autoconfig.build_task)) return d.runArgv(&.{ d.zig_exe, "build" }, d.root, arena);
        return .{ .failed = std.fmt.allocPrint(arena, "there is no task \"{s}\"", .{label}) catch "no such task" };
    }

    fn runGenerated(d: *Debug, g: LaunchConfig.GeneratedTask, arena: Allocator) DebugManager.TaskOutcome {
        const argv = arena.alloc([]const u8, g.args.len + 1) catch return .{ .failed = "out of memory" };
        argv[0] = g.command;
        for (g.args, argv[1..]) |s, *o| o.* = variables.substituteString(arena, s, &d.vars, &.{}) catch |e|
            return .{ .failed = std.fmt.allocPrint(arena, "cannot fill in \"{s}\": {t}", .{ s, e }) catch "bad arguments" };
        const cwd = if (g.cwd) |c| variables.substituteString(arena, c, &d.vars, &.{}) catch d.root else d.root;
        if (std.fs.path.dirname(argv[argv.len - 1])) |_| {
            // `-femit-bin=<dir>/tests`: the folder must exist.
            const last = argv[argv.len - 1];
            if (std.mem.startsWith(u8, last, "-femit-bin=")) if (std.fs.path.dirname(last["-femit-bin=".len..])) |dir|
                Io.Dir.cwd().createDirPath(d.io, dir) catch {};
        }
        return d.runArgv(argv, cwd, arena);
    }

    fn runArgv(d: *Debug, argv: []const []const u8, cwd: []const u8, arena: Allocator) DebugManager.TaskOutcome {
        const r = std.process.run(arena, d.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = d.env,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(600), .clock = .awake } },
        }) catch |e| return .{ .failed = std.fmt.allocPrint(arena, "cannot run {s}: {t}", .{ argv[0], e }) catch "cannot run" };
        switch (r.term) {
            .exited => |c| if (c == 0) return .ok,
            else => {},
        }
        const err = std.mem.trim(u8, r.stderr, " \r\n");
        const first = if (std.mem.indexOfScalar(u8, err, '\n')) |i| err[0..i] else err;
        return .{ .failed = if (first.len > 0) first else "the build failed" };
    }

    fn noConfig(_: *anyopaque, _: []const u8, _: Allocator) ?[]const u8 {
        return null;
    }

    fn noCommand(_: *anyopaque, _: []const u8, _: Allocator) anyerror!?[]const u8 {
        return error.CommandNotAllowed;
    }

    fn noInput(_: *anyopaque, def: *const variables.InputDef, _: Allocator) anyerror!?[]const u8 {
        return def.default;
    }

    // -------------------------------------------------------- sessions

    pub fn entryById(d: *const Debug, id: u32) ?*Entry {
        for (d.entries.items) |e| if (e.id == id) return e;
        return null;
    }

    /// The session the toolbar and commands act on.
    pub fn active(d: *const Debug) ?*Entry {
        if (d.active_id) |id| if (d.entryById(id)) |e| return e;
        return if (d.entries.items.len > 0) d.entries.items[d.entries.items.len - 1] else null;
    }

    pub fn sessionCount(d: *const Debug) usize {
        return d.entries.items.len;
    }

    fn addEntry(d: *Debug, s: *DebugSession) !*Entry {
        const e = try d.gpa.create(Entry);
        errdefer d.gpa.destroy(e);
        e.* = .{ .s = s, .id = s.id, .insp = undefined };
        try e.insp.initSession(d.gpa, d.io, s, .{ .host = .{ .ctx = d, .reveal = revealFrame } });
        errdefer e.insp.deinit();
        e.insp.ch.setWaker(.{ .ctx = d.inbox, .func = Inbox.wake });
        // The workspace's watch list (the no-session one saves it).
        for (d.no_session.watches.results()) |w| e.insp.watches.add(w.expr);
        try d.entries.append(d.gpa, e);
        return e;
    }

    /// Drops `e` (and the entries of its children) from the views; the
    /// session is freed on a worker (`free`) or by `destroy`.
    fn dropEntry(d: *Debug, e: *Entry, free: bool) void {
        var i: usize = d.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (i >= d.entries.items.len) continue;
            const c = d.entries.items[i];
            if (c.s.opts.parent == e.s) d.dropEntry(c, free);
        }
        for (d.entries.items, 0..) |x, j| if (x == e) {
            _ = d.entries.orderedRemove(j);
            break;
        };
        d.dropped.put(d.gpa, e.id, {}) catch {};
        if (d.active_id == e.id) d.active_id = null;
        if (d.hover.shown) |sh| if (sh.session == e.id) d.hover.close();
        if (d.hover.tree.insp == &e.insp) d.hover.close();
        e.insp.ch.setWaker(null);
        e.insp.deinit();
        const s = e.s;
        d.gpa.destroy(e);
        // Children go with their parent.
        if (!free or s.opts.parent != null) return;
        d.spawnWork(removeWork, .{s});
    }

    fn removeWork(q: *Inbox, s: *DebugSession) void {
        defer workDone(q);
        q.debug_ptr.mgr.remove(s);
    }

    /// A change of `s` (UI thread, from the inbox).
    fn onSessionChange(d: *Debug, s: *DebugSession, id: u32, change: DebugSession.Change) void {
        if (d.dropped.contains(id)) return;
        const e = d.entryById(id) orelse d.addEntry(s) catch |err| {
            log.warn("debug session {d}: {t}", .{ id, err });
            return;
        };
        e.insp.onChange(s, change);
        switch (change) {
            .state => switch (s.state()) {
                .failed => {
                    const msg = s.failureMessage(d.gpa) catch null;
                    defer if (msg) |m| d.gpa.free(m);
                    d.say(.error_, "{s}: {s}", .{ s.cfg.name, msg orelse "the debug session failed" });
                    d.dropEntry(e, true);
                },
                .terminated => d.dropEntry(e, true),
                else => {},
            },
            .stopped => {
                d.active_id = id;
                d.reveal_req = id;
                d.host.show_panel(d.host.ctx);
            },
            .prompt => if (s.prompt()) |p| switch (p.kind) {
                .pre_launch_task_failed => {
                    d.active_id = id;
                    d.sayActions(.error_, &.{
                        .{ .label = "Debug Anyway", .action = "debug.debugAnyway" },
                        .{ .label = "Abort", .action = "debug.abortStart", .primary = true },
                    }, "The pre-launch task \"{s}\" failed", .{p.task});
                },
            },
            else => {},
        }
    }

    /// Applies the inspection models' results.
    fn pumpAll(d: *Debug) void {
        for (d.entries.items) |e| _ = e.insp.pump();
    }

    fn revealFrame(ctx: ?*anyopaque, row: *const Inspector.FrameRow) void {
        const d: *Debug = @ptrCast(@alignCast(ctx.?));
        const focus = d.focus_reveal;
        d.focus_reveal = false;
        const src = row.source orelse return;
        const path = src.path orelse return;
        d.host.reveal(d.host.ctx, path, @max(row.line, 1), @max(row.column, 1), focus);
    }

    /// Each session, its threads and their frames, for the call stack
    /// (in `a`).
    pub fn snapshot(d: *Debug, a: Allocator) Allocator.Error![]call_stack.SessionIn {
        const out = try a.alloc(call_stack.SessionIn, d.entries.items.len);
        for (d.entries.items, out) |e, *o| {
            const ts = try e.s.threads(a);
            const threads = try a.alloc(call_stack.ThreadIn, ts.len);
            for (ts, threads) |t, *ti| ti.* = .{
                .id = t.id,
                .name = t.name,
                .stopped = t.stopped and e.insp.stopped(),
                .reason = if (t.stop_reason) |r| r.description orelse r.reason else null,
                .frames = e.insp.stack.frames(t.id),
                .complete = e.insp.stack.complete(t.id),
            };
            o.* = .{
                .id = e.id,
                .name = e.s.cfg.name,
                .state = e.s.state(),
                .parent = if (e.s.opts.parent) |p| p.id else null,
                .threads = threads,
            };
        }
        return out;
    }

    /// The thread to reveal for session `id`: the selected frame's, else
    /// the current one.
    pub fn revealThread(d: *const Debug, id: u32) ?i64 {
        const e = d.entryById(id) orelse return null;
        if (e.insp.stack.selected()) |sel| return sel.thread;
        return e.s.currentThread();
    }

    /// The selected frame of the active session.
    pub fn selectedFrame(d: *const Debug) ?call_stack.Selected {
        const e = d.active() orelse return null;
        const sel = e.insp.stack.selected() orelse return null;
        return .{ .session = e.id, .thread = sel.thread, .frame = sel.frame };
    }

    /// The call stack's hooks.
    pub fn stackHooks(d: *Debug) call_stack.Hooks {
        return .{ .ctx = d, .select_frame = selectFrame, .load_more = loadMore };
    }

    fn selectFrame(ctx: *anyopaque, session: u32, thread: i64, frame: i64, focus: bool) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        const e = d.entryById(session) orelse return;
        d.active_id = session;
        e.s.setCurrentThread(thread);
        d.focus_reveal = focus;
        e.insp.stack.select(thread, frame);
        d.focus_reveal = false;
        d.changed();
    }

    fn loadMore(ctx: *anyopaque, session: u32, thread: i64) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        const e = d.entryById(session) orelse return;
        e.insp.stack.loadMore(thread, e.insp.opts.page);
    }

    /// The toolbar for the active session.
    pub fn toolbarState(d: *const Debug) toolbar.State {
        const e = d.active() orelse return toolbar.compute(.{ .state = null });
        return toolbar.compute(.{
            .state = e.s.state(),
            .request = e.s.cfg.request,
            .step_back = e.s.caps().supportsStepBack orelse false,
            .controller = e.s.controller(),
            .taken = e.taken,
            .sessions = d.entries.items.len,
        });
    }

    // -------------------------------------------------------- starting

    /// The configuration F5 starts, by name.
    pub fn selectedName(d: *const Debug) ?[]const u8 {
        return if (d.selected) |s| s.name else null;
    }

    pub fn selectConfig(d: *Debug, kind: configs_mod.Kind, name: []const u8) void {
        const copy = d.gpa.dupe(u8, name) catch return;
        if (d.selected) |s| d.gpa.free(s.name);
        d.selected = .{ .kind = kind, .name = copy };
        d.changed();
    }

    /// `debug.start` / `debug.runWithoutDebugging`: the selected
    /// configuration, or a picker when none is.
    pub fn startCmd(d: *Debug, no_debug: bool) void {
        const sel = d.selected orelse return d.openConfigPicker(true) catch {};
        d.startNamed(sel.kind, sel.name, no_debug);
    }

    fn startNamed(d: *Debug, kind: configs_mod.Kind, name: []const u8, no_debug: bool) void {
        const set = d.configSet() orelse return;
        switch (kind) {
            .config => {
                const c = set.find(name) orelse return d.say(.warning, "There is no configuration \"{s}\" any more", .{name});
                d.launch(c, no_debug);
            },
            .auto => for (d.autos) |*c| {
                if (std.mem.eql(u8, c.name, name)) return d.launch(c, no_debug);
            } else d.say(.warning, "\"{s}\" is not available any more", .{name}),
            .compound => {
                const c = set.findCompound(name) orelse return d.say(.warning, "There is no compound \"{s}\" any more", .{name});
                d.startCompound(set, c);
            },
            .add => d.addConfigurationCmd(),
        }
    }

    fn setFileVars(d: *Debug) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (d.host.cursor(d.host.ctx, &buf)) |c| {
            const n = @min(c.path.len, d.file_buf.len);
            @memcpy(d.file_buf[0..n], c.path[0..n]);
            d.vars.file = d.file_buf[0..n];
            d.vars.line = c.line;
            d.vars.column = c.column;
        } else {
            d.vars.file = null;
            d.vars.line = null;
            d.vars.column = null;
        }
    }

    fn launch(d: *Debug, c: *const LaunchConfig, no_debug: bool) void {
        if (!c.enabled) return d.say(.warning, "\"{s}\" cannot start: {s}", .{ c.name, c.disabled_reason orelse "disabled" });
        // Sessions still starting read the variables: change them only
        // when none is.
        if (!d.anyStarting()) d.setFileVars();
        const s = d.mgr.start(c, .{ .no_debug = no_debug }) catch |e| return d.say(.error_, "Cannot start \"{s}\": {t}", .{ c.name, e });
        d.active_id = s.id;
        _ = d.addEntry(s) catch {};
        d.host.show_panel(d.host.ctx);
        d.changed();
    }

    fn anyStarting(d: *const Debug) bool {
        for (d.entries.items) |e| switch (e.s.state()) {
            .initializing, .configuring, .launching => return true,
            else => {},
        };
        return false;
    }

    fn startCompound(d: *Debug, set: *const ConfigSet, c: *const ConfigSet.Compound) void {
        if (d.compound_busy) return d.say(.info, "A compound is still starting", .{});
        d.compound_busy = true;
        if (!d.anyStarting()) d.setFileVars();
        d.spawnWork(compoundWork, .{ set, c });
        d.host.show_panel(d.host.ctx);
    }

    fn compoundWork(q: *Inbox, set: *const ConfigSet, c: *const ConfigSet.Compound) void {
        defer workDone(q);
        const d = q.debug_ptr;
        var arena: std.heap.ArenaAllocator = .init(q.gpa);
        defer arena.deinit();
        const r = d.mgr.startCompound(c, set, arena.allocator()) catch {
            q.push(.{ .compound_done = null });
            return;
        };
        const msg: ?[]u8 = if (r.errors.len == 0) null else std.mem.join(q.gpa, "; ", r.errors) catch null;
        q.push(.{ .compound_done = msg });
    }

    /// The prompt after a failed pre-launch task.
    pub fn answerPrompt(d: *Debug, choice: DebugSession.Prompt.Choice) void {
        for (d.entries.items) |e| if (e.s.prompt() != null) e.s.answerPrompt(choice);
    }

    // -------------------------------------------------------- controls

    /// The active session, unless the agent drives it (then says so).
    fn controllable(d: *Debug) ?*Entry {
        const e = d.active() orelse return null;
        if (e.s.controller() == .agent) {
            d.sayActions(.info, &.{.{ .label = "Take Control", .action = "debug.takeControl", .primary = true }}, "The agent controls this debug session", .{});
            return null;
        }
        return e;
    }

    /// The thread commands act on: the selected frame's, else the
    /// session's current one.
    fn threadOf(e: *Entry) ?i64 {
        if (e.insp.stack.selected()) |sel| return sel.thread;
        return e.s.currentThread();
    }

    pub fn continueCmd(d: *Debug) void {
        const e = d.controllable() orelse return;
        e.s.continue_(threadOf(e));
    }

    pub fn pauseCmd(d: *Debug) void {
        const e = d.controllable() orelse return;
        e.s.pause(threadOf(e));
    }

    pub fn stepCmd(d: *Debug, kind: DebugSession.StepKind) void {
        const e = d.controllable() orelse return;
        const t = threadOf(e) orelse return;
        e.s.step(kind, t, .statement);
    }

    pub fn reverseContinueCmd(d: *Debug) void {
        const e = d.controllable() orelse return;
        e.s.reverseContinue(threadOf(e));
    }

    /// Stop (or Disconnect for an attach session).
    pub fn stopCmd(d: *Debug) void {
        const e = d.active() orelse return;
        if (e.s.cfg.request == .attach) e.s.detach(false) else e.s.stop();
    }

    pub fn restartCmd(d: *Debug) void {
        const e = d.controllable() orelse return d.startCmd(false);
        e.s.restart();
    }

    /// A toolbar button.
    pub fn press(d: *Debug, b: toolbar.Button) void {
        switch (b) {
            .@"continue" => d.continueCmd(),
            .pause => d.pauseCmd(),
            .step_over => d.stepCmd(.over),
            .step_into => d.stepCmd(.into),
            .step_out => d.stepCmd(.out),
            .step_back => d.stepCmd(.back),
            .reverse_continue => d.reverseContinueCmd(),
            .restart => d.restartCmd(),
            .stop, .disconnect => d.stopCmd(),
        }
    }

    pub fn takeControlCmd(d: *Debug) void {
        const e = d.active() orelse return;
        if (e.s.controller() != .agent) return;
        e.s.setController(.user);
        e.taken = true;
        d.changed();
    }

    pub fn handBackCmd(d: *Debug) void {
        const e = d.active() orelse return;
        if (!e.taken) return;
        e.s.setController(.agent);
        e.taken = false;
        d.changed();
    }

    pub fn runToCursorCmd(d: *Debug) void {
        const e = d.controllable() orelse return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const c = d.host.cursor(d.host.ctx, &buf) orelse return;
        if (!e.s.runToLine(.{ .path = c.path }, c.line)) d.say(.warning, "Cannot run to the cursor in this session", .{});
    }

    pub fn jumpToCursorCmd(d: *Debug) void {
        const e = d.controllable() orelse return;
        if (!(e.s.caps().supportsGotoTargetsRequest orelse false)) return d.say(.info, "This debugger cannot jump to a line", .{});
        const t = threadOf(e) orelse return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const c = d.host.cursor(d.host.ctx, &buf) orelse return;
        d.inbox.retain();
        e.s.gotoLine(t, .{ .path = c.path }, c.line, .{ .ctx = d.inbox, .func = Inbox.onGoto });
    }

    /// A request whose answer the stop or the next stop shows.
    const ignored: zg_dap.conn.DapConnection.RawRespCb = .{ .ctx = null, .func = dropResult };

    fn dropResult(_: ?*anyopaque, r: zg_dap.conn.DapConnection.RawResult) void {
        r.deinit();
    }

    pub fn restartFrameCmd(d: *Debug) void {
        const e = d.controllable() orelse return;
        if (!(e.s.caps().supportsRestartFrame orelse false)) return d.say(.info, "This debugger cannot restart a frame", .{});
        const sel = e.insp.stack.selected() orelse return;
        var buf: [48]u8 = undefined;
        const args = std.fmt.bufPrint(&buf, "{{\"frameId\":{d}}}", .{sel.frame}) catch return;
        _ = e.s.sendRequest("restartFrame", args, ignored);
    }

    pub fn stepIntoTargetCmd(d: *Debug) void {
        const e = d.controllable() orelse return;
        if (!(e.s.caps().supportsStepInTargetsRequest orelse false)) return d.stepCmd(.into);
        const sel = e.insp.stack.selected() orelse return;
        d.pick_target_session = e.id;
        d.pick_target_thread = sel.thread;
        d.inbox.retain();
        e.s.stepInTargets(sel.frame, .{ .ctx = d.inbox, .func = Inbox.onTargets });
    }

    fn openTargets(d: *Debug, m: *TargetsMsg) !void {
        const w = d.win orelse return;
        if (m.ids.len == 0) return d.say(.info, "There is nothing to step into here", .{});
        d.pick.close(w);
        _ = d.pick_arena.reset(.retain_capacity);
        const a = d.pick_arena.allocator();
        d.pick_items = try a.alloc(quick_pick.QpItem, m.ids.len);
        d.pick_targets = try a.dupe(i64, m.ids);
        for (m.labels, d.pick_items, 0..) |l, *it, i| it.* = .{ .id = i, .label = try a.dupe(u8, l) };
        d.pick_kind = .targets;
        const provs = [_]quick_pick.Provider{.{ .ptr = d, .vtable = &pick_vtable }};
        d.pick = try quick_pick.openQuickPick(w, .{ .providers = &provs, .title = "Step Into Target", .test_id = "debug-targets" });
    }

    fn stepIntoTarget(d: *Debug, target: i64) void {
        const e = d.entryById(d.pick_target_session) orelse return;
        var buf: [96]u8 = undefined;
        const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d},\"targetId\":{d}}}", .{ d.pick_target_thread, target }) catch return;
        _ = e.s.sendRequest("stepIn", args, ignored);
    }

    // ----------------------------------------------------- breakpoints

    /// F9: the gutter shows the result.
    pub fn toggleBreakpointCmd(d: *Debug) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const c = d.host.cursor(d.host.ctx, &buf) orelse return d.say(.info, "Open a file to set a breakpoint", .{});
        d.toggleBreakpointAt(c.path, c.line);
    }

    /// A breakpoint on 1-based `line` of `path` (absolute), or none where
    /// there was one (a click in the gutter).
    pub fn toggleBreakpointAt(d: *Debug, path: []const u8, line: u32) void {
        _ = d.bps.toggleLine(path, line) catch |e| d.say(.error_, "Cannot set the breakpoint: {t}", .{e});
    }

    pub fn removeAllBreakpointsCmd(d: *Debug) void {
        const views = d.bps.list(d.gpa) catch return;
        defer d.gpa.free(views);
        for (views) |v| d.bps.remove(v.bp.id);
    }

    pub fn setAllBreakpointsCmd(d: *Debug, on: bool) void {
        d.bps.setEnabledAll(on);
    }

    /// Enables every breakpoint, or disables them all when they all are
    /// (the Breakpoints view's toolbar).
    pub fn toggleAllBreakpointsCmd(d: *Debug) void {
        const views = d.bps.list(d.gpa) catch return;
        defer d.gpa.free(views);
        var all = true;
        for (views) |v| all = all and v.bp.enabled;
        d.bps.setEnabledAll(!all);
    }

    /// The breakpoint on the caret's line, made when there is none (for
    /// Add Conditional Breakpoint and Add Logpoint).
    pub fn breakpointAtCursor(d: *Debug) ?BreakpointManager.BpId {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const c = d.host.cursor(d.host.ctx, &buf) orelse {
            d.say(.info, "Open a file to set a breakpoint", .{});
            return null;
        };
        var arena: std.heap.ArenaAllocator = .init(d.gpa);
        defer arena.deinit();
        const here = d.bps.inSource(arena.allocator(), c.path) catch return null;
        for (here) |v| if (v.bp.kind.source.line == c.line) return v.bp.id;
        return d.bps.add(.{ .kind = .{ .source = .{ .path = c.path, .line = c.line } } }) catch null;
    }

    /// The Breakpoints view's rows (in `a`): the active session's
    /// exception filters and every breakpoint.
    pub fn bpSnapshot(d: *Debug, a: Allocator) Allocator.Error!bp_view.Snapshot {
        const filters = if (d.active()) |e| try d.bps.exceptionFilters(a, e.s) else &.{};
        return .{ .filters = filters, .bps = try d.bps.list(a) };
    }

    pub fn bpHooks(d: *Debug) bp_view.Hooks {
        return .{
            .ctx = d,
            .set_enabled = bpSetEnabled,
            .set_filter = bpSetFilter,
            .remove = bpRemove,
            .reveal = bpReveal,
            .set_text = bpSetText,
            .add_function = bpAddFunction,
        };
    }

    fn bpSetEnabled(ctx: *anyopaque, id: BreakpointManager.BpId, on: bool) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        d.bps.update(id, .{ .enabled = on }) catch {};
    }

    fn bpSetFilter(ctx: *anyopaque, filter: []const u8, enabled: bool, condition: ?[]const u8) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        const e = d.active() orelse return;
        d.bps.setExceptionFilter(e.s.cfg.type, filter, enabled, condition) catch {};
    }

    pub fn bpRemove(ctx: *anyopaque, id: BreakpointManager.BpId) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        d.bps.remove(id);
    }

    fn bpReveal(ctx: *anyopaque, path: []const u8, line: u32) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        d.host.reveal(d.host.ctx, path, line, 1, false);
    }

    fn bpSetText(ctx: *anyopaque, id: BreakpointManager.BpId, field: bp_view.Field, text: ?[]const u8) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        const patch: BreakpointManager.Patch = switch (field) {
            .log_message => .{ .log_message = text },
            else => .{ .condition = text },
        };
        d.bps.update(id, patch) catch |e| d.say(.error_, "Cannot change the breakpoint: {t}", .{e});
    }

    fn bpAddFunction(ctx: *anyopaque, name: []const u8) void {
        const d: *Debug = @ptrCast(@alignCast(ctx));
        _ = d.bps.add(.{ .kind = .{ .function = .{ .name = name } } }) catch |e| d.say(.error_, "Cannot add the breakpoint: {t}", .{e});
    }

    // ---------------------------------------------------------- pickers

    const pick_vtable: quick_pick.Provider.VTable = .{
        .placeholder = "Select a debug configuration",
        .items = pickItems,
        .accept = pickAccept,
    };

    /// The configuration picker (`start`: start what is picked).
    pub fn openConfigPicker(d: *Debug, start: bool) !void {
        const w = d.win orelse return;
        const set = d.configSet() orelse return;
        d.pick.close(w);
        _ = d.pick_arena.reset(.retain_capacity);
        const a = d.pick_arena.allocator();
        d.pick_entries = try configs_mod.entries(a, set, d.autos);
        d.pick_items = try a.alloc(quick_pick.QpItem, d.pick_entries.len);
        for (d.pick_entries, d.pick_items, 0..) |en, *it, i| it.* = .{
            .id = i,
            .label = en.name,
            .description = en.description,
            .detail = if (en.disabled_reason) |r| try std.fmt.allocPrint(a, "Cannot start: {s}", .{r}) else "",
            .group = if (en.group.len > 0) en.group else null,
        };
        d.pick_kind = if (start) .start else .config;
        const title = if (d.autos_loading and set.configs.len == 0) "Select a Debug Configuration (looking for a debugger\u{2026})" else "Select a Debug Configuration";
        const provs = [_]quick_pick.Provider{.{ .ptr = d, .vtable = &pick_vtable }};
        d.pick = try quick_pick.openQuickPick(w, .{ .providers = &provs, .title = title, .test_id = "debug-config-picker" });
    }

    /// `debug.selectSession`.
    pub fn openSessionPicker(d: *Debug) !void {
        const w = d.win orelse return;
        if (d.entries.items.len == 0) return d.say(.info, "No debug sessions", .{});
        d.pick.close(w);
        _ = d.pick_arena.reset(.retain_capacity);
        const a = d.pick_arena.allocator();
        d.pick_items = try a.alloc(quick_pick.QpItem, d.entries.items.len);
        d.pick_ids = try a.alloc(u32, d.entries.items.len);
        for (d.entries.items, d.pick_items, d.pick_ids, 0..) |e, *it, *id, i| {
            id.* = e.id;
            it.* = .{ .id = i, .label = e.s.cfg.name, .description = call_stack.CallStack.stateText(e.s.state()) };
        }
        d.pick_kind = .session;
        const provs = [_]quick_pick.Provider{.{ .ptr = d, .vtable = &pick_vtable }};
        d.pick = try quick_pick.openQuickPick(w, .{ .providers = &provs, .title = "Select Debug Session", .test_id = "debug-session-picker" });
    }

    fn pickItems(ptr: ?*anyopaque) []const quick_pick.QpItem {
        const d: *Debug = @ptrCast(@alignCast(ptr.?));
        return d.pick_items;
    }

    fn pickAccept(ptr: ?*anyopaque, items: []const quick_pick.QpItem, _: ?[]const u8, _: bool) void {
        const d: *Debug = @ptrCast(@alignCast(ptr.?));
        if (items.len == 0) return;
        const i: usize = @intCast(items[0].id);
        switch (d.pick_kind) {
            .config, .start => {
                if (i >= d.pick_entries.len) return;
                const en = d.pick_entries[i];
                if (en.kind == .add) return d.addConfigurationCmd();
                if (en.disabled_reason) |r| return d.say(.warning, "\"{s}\" cannot start: {s}", .{ en.name, r });
                d.selectConfig(en.kind, en.name);
                if (d.pick_kind == .start) d.startNamed(en.kind, d.selected.?.name, false);
            },
            .session => if (i < d.pick_ids.len) {
                d.active_id = d.pick_ids[i];
                d.changed();
            },
            .targets => if (i < d.pick_targets.len) d.stepIntoTarget(d.pick_targets[i]),
        }
    }

    /// `debug.addConfiguration`: opens `.zigguro/launch.zon`, writing a
    /// starting configuration first when there is none.
    pub fn addConfigurationCmd(d: *Debug) void {
        const dir = d.root_dir orelse return;
        const rel = zg_dap.config.launch_zon.path;
        dir.access(d.io, rel, .{}) catch {
            zg_dap.breakpoints.persist.writeAtomic(d.io, dir, rel, configs_mod.template) catch |e|
                return d.say(.error_, "Cannot write {s}: {t}", .{ rel, e });
            _ = d.configs.fileChanged(rel);
        };
        const abs = std.fs.path.join(d.gpa, &.{ d.root, rel }) catch return;
        defer d.gpa.free(abs);
        d.host.reveal(d.host.ctx, abs, 1, 1, true);
    }

    /// The configuration row's text: the selected configuration, or
    /// what F5 does without one.
    pub fn configLabel(d: *const Debug) []const u8 {
        return d.selectedName() orelse "No Configuration";
    }
};

/// The targets of `stepInTargets`, copied for the UI thread.
const TargetsMsg = struct {
    arena: std.heap.ArenaAllocator,
    ids: []i64,
    labels: [][]const u8,
};

const Msg = union(enum) {
    session: struct { s: *DebugSession, id: u32, change: DebugSession.Change },
    /// Inspection results arrived.
    pump,
    breakpoints,
    /// The saved breakpoints were read.
    loaded,
    /// The saved watch list (owned).
    watches: []u8,
    autos: struct { arena: *std.heap.ArenaAllocator, configs: []const LaunchConfig },
    targets: *TargetsMsg,
    goto_failed: ?[]u8,
    compound_done: ?[]u8,
};

/// Messages for the UI thread; outlives the service while a worker or a
/// callback holds a reference.
const Inbox = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    refs: std.atomic.Value(u32) = .init(1),
    posted: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Msg) = .empty,
    /// Null once the service is going (guarded by `mutex`).
    debug: ?*Debug,
    /// The service, for the workers `destroy` waits for.
    debug_ptr: *Debug = undefined,

    fn retain(q: *Inbox) void {
        _ = q.refs.fetchAdd(1, .monotonic);
    }

    fn release(q: *Inbox) void {
        if (q.refs.fetchSub(1, .acq_rel) == 1) {
            for (q.items.items) |m| q.freeMsg(m);
            q.items.deinit(q.gpa);
            q.gpa.destroy(q);
        }
    }

    fn push(q: *Inbox, m: Msg) void {
        const queued = blk: {
            q.mutex.lockUncancelable(q.io);
            defer q.mutex.unlock(q.io);
            if (q.debug == null) break :blk false;
            // Coalesce: one of each change per session, one pump.
            for (q.items.items) |x| switch (m) {
                .session => |a| if (x == .session and x.session.id == a.id and x.session.change == a.change) break :blk true,
                .pump, .breakpoints => if (std.meta.activeTag(x) == std.meta.activeTag(m)) break :blk true,
                else => {},
            };
            q.items.append(q.gpa, m) catch break :blk false;
            break :blk true;
        };
        if (!queued) return q.freeMsg(m);
        if (q.posted.swap(true, .acq_rel)) return;
        q.retain();
        q.app.post(.{ .ctx = q, .f = run }) catch {
            q.posted.store(false, .release);
            _ = q.refs.fetchSub(1, .monotonic);
        };
    }

    fn freeMsg(q: *Inbox, m: Msg) void {
        switch (m) {
            .autos => |x| Debug.freeArena(q.gpa, x.arena),
            .targets => |t| {
                t.arena.deinit();
                q.gpa.destroy(t);
            },
            .goto_failed, .compound_done => |s| if (s) |x| q.gpa.free(x),
            .watches => |text| q.gpa.free(text),
            else => {},
        }
    }

    /// The manager's listener (any thread).
    fn onSession(ctx: ?*anyopaque, s: *DebugSession, change: DebugSession.Change) void {
        const q: *Inbox = @ptrCast(@alignCast(ctx.?));
        switch (change) {
            // The console and the other views come later (E07.F07.S01.T03).
            .output, .progress, .process, .modules, .loaded_sources, .memory, .exited => return,
            else => {},
        }
        q.push(.{ .session = .{ .s = s, .id = s.id, .change = change } });
    }

    fn onBreakpoints(ctx: ?*anyopaque, _: BreakpointManager.Change) void {
        const q: *Inbox = @ptrCast(@alignCast(ctx.?));
        q.push(.breakpoints);
    }

    /// An inspection result arrived (any thread, the channel's lock held).
    fn wake(ctx: ?*anyopaque) void {
        const q: *Inbox = @ptrCast(@alignCast(ctx.?));
        q.push(.pump);
    }

    fn onTargets(ctx: ?*anyopaque, ok: bool, targets: []const DebugSession.StepInTarget) void {
        const q: *Inbox = @ptrCast(@alignCast(ctx.?));
        defer q.release();
        const m = q.gpa.create(TargetsMsg) catch return;
        m.* = .{ .arena = .init(q.gpa), .ids = &.{}, .labels = &.{} };
        copy: {
            if (!ok) break :copy;
            const a = m.arena.allocator();
            m.ids = a.alloc(i64, targets.len) catch break :copy;
            m.labels = a.alloc([]const u8, targets.len) catch break :copy;
            for (targets, m.ids, m.labels) |t, *id, *l| {
                id.* = t.id;
                l.* = a.dupe(u8, t.label) catch break :copy;
            }
        }
        q.push(.{ .targets = m });
    }

    fn onGoto(ctx: ?*anyopaque, ok: bool, message: ?[]const u8) void {
        const q: *Inbox = @ptrCast(@alignCast(ctx.?));
        defer q.release();
        if (ok) return;
        q.push(.{ .goto_failed = q.gpa.dupe(u8, message orelse "the debugger refused") catch null });
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
        const d = blk: {
            q.mutex.lockUncancelable(q.io);
            defer q.mutex.unlock(q.io);
            std.mem.swap(std.ArrayList(Msg), &items, &q.items);
            break :blk q.debug;
        };
        const dd = d orelse {
            for (items.items) |m| q.freeMsg(m);
            return;
        };
        q.apply(dd, items.items);
    }

    fn apply(q: *Inbox, d: *Debug, items: []const Msg) void {
        var touched = false;
        for (items) |m| {
            switch (m) {
                .session => |x| d.onSessionChange(x.s, x.id, x.change),
                .pump, .breakpoints => {},
                .loaded => d.onLoaded(),
                .watches => |text| {
                    d.onWatchesLoaded(text);
                    q.gpa.free(text);
                },
                .autos => |x| d.applyAutos(x.arena, x.configs),
                .targets => |t| {
                    d.openTargets(t) catch {};
                    t.arena.deinit();
                    q.gpa.destroy(t);
                },
                .goto_failed => |msg| {
                    d.say(.warning, "Cannot jump there: {s}", .{msg orelse "out of memory"});
                    if (msg) |x| q.gpa.free(x);
                },
                .compound_done => |msg| {
                    d.compound_busy = false;
                    if (msg) |x| {
                        d.say(.error_, "The compound did not start: {s}", .{x});
                        q.gpa.free(x);
                    }
                },
            }
            touched = true;
        }
        d.pumpAll();
        if (touched) d.changed();
    }

    /// UI thread: the service is going.
    fn shutDown(q: *Inbox) void {
        var items: std.ArrayList(Msg) = .empty;
        {
            q.mutex.lockUncancelable(q.io);
            defer q.mutex.unlock(q.io);
            q.debug = null;
            std.mem.swap(std.ArrayList(Msg), &items, &q.items);
        }
        for (items.items) |m| q.freeMsg(m);
        items.deinit(q.gpa);
    }
};
