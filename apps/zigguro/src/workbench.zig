//! The workbench on the docking shell (E04.F07): editors, the terminal
//! and the agent are dock panels (`zg_gui.dock`), under a header of
//! breadcrumbs and a toolbar and over a status line, driven by the E15
//! keymap (VS Code preset) and command palette. Editors open as tabs in
//! the center (the breadcrumbs' dropdowns open other files there; files
//! stay loaded once opened), the terminal docks in the bottom area and
//! the agent in the agent area. Tabs can be dragged to split groups or
//! to dock into the side areas. The active editor of the focused group
//! is the one the header, status line and editor commands act on.
//!
//! Commands: `file.save` (Ctrl+S), `workbench.showCommands`
//! (Ctrl+Shift+P, F1), `terminal.toggle` (Ctrl+`), `agent.togglePane`
//! (Ctrl+L), `workspace.manageTrust`, `editor.undo`, `editor.redo`,
//! `editor.selectAll` and `workbench.toggleTheme`.
//!
//! The document lives in an E05 `DocumentRegistry`, so the agent pane's
//! file tools read and edit it through the editor (agent/editor_files.zig)
//! and their approvals come up as dialogs (agent/approvals.zig).
//!
//! Workspace trust is asked per session until the trust store
//! (E16.F07.S01.T01) persists it; the status line shows Restricted Mode.
//! `approvals` is the dialog ApprovalPort for consumers (agents, MCP).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_config = @import("zg_config");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const zg_terminal_view = @import("zg_terminal_view");
const zg_security = @import("zg_security");
const zg_security_ui = @import("zg_security_ui");
const zg_review = @import("zg_review");
const TerminalPanel = @import("terminal_panel.zig").TerminalPanel;
const AgentHost = @import("agent/host.zig").AgentHost;
const AgentPanel = @import("agent/panel.zig").AgentPanel;
const AgentCommands = @import("agent/commands.zig").AgentCommands;
const QueuePanel = @import("review/queue_panel.zig").QueuePanel;
const ReviewView = @import("review/review_view.zig").ReviewView;
const path_crumbs = @import("path_crumbs.zig");

const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const EditorView = zg_editor.view.EditorView;
const Document = zg_editor.model.document.Document;
const DocumentRegistry = zg_editor.model.api.registry.DocumentRegistry;
const DocumentSyntax = zg_editor.model.syntax.DocumentSyntax;
const registry = zg_config.commands;
const themes = zg_gui.theme.theme;
const PanelRef = zg_gui.dock.model.PanelRef;
const PanelKindId = zg_gui.dock.model.PanelKindId;
const Area = zg_gui.dock.model.Area;
const persist = zg_gui.dock.persist;
const log = std.log.scoped(.workbench);

/// How often the review panel looks for other processes' decisions.
const review_poll_ms = 1000;

/// See the module doc.
pub const Workbench = struct {
    rt: *zg_core.Runtime,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// The file being edited, or null for an untitled buffer.
    path: ?[]u8 = null,
    /// The open documents (owns `doc`).
    docs: DocumentRegistry,
    doc: *Document,
    view: *EditorView,
    langs: zg_syntax.Registry,
    syntax: ?*DocumentSyntax = null,
    /// Every file opened, the current one included (views stay loaded).
    files: std.ArrayList(OpenFile) = .empty,
    /// The docking layout and its view.
    dock: zg_gui.dock.DockModel,
    dv: zg_gui.dock.DockView = undefined,
    /// Torn-off panels' windows (`enableFloating`).
    floater: ?zg_gui.dock.floating.Floater = null,
    /// The dock panels of the terminal and the agent, once created.
    terminal_ref: ?PanelRef = null,
    agent_ref: ?PanelRef = null,
    review_ref: ?PanelRef = null,
    /// The hunk-by-hunk review tab (editor area), while open.
    review_view_ref: ?PanelRef = null,
    /// The current file's panel.
    cur_panel: ?PanelRef = null,
    /// A file to switch to at the next build (from a breadcrumb dropdown).
    pending_open: ?[]u8 = null,
    /// The working folder (absolute).
    cwd: [:0]u8 = undefined,
    crumbs: path_crumbs.PathCrumbs,
    keys: zg_config.context.ContextKeyService,
    reg: *registry.CommandRegistry,
    diags: zg_config.diag.Diags,
    keymap_docs: std.ArrayList(zg_config.zon_load.Doc) = .empty,
    keymap: ?*zg_config.keymap.Keymap = null,
    resolver: *zg_config.resolver.Resolver,
    adapter: zg_config.ui.KeymapAdapter = undefined,
    palette: zg_config.ui.PaletteProvider = undefined,
    win: ?*Window = null,
    /// Scratch for the toast text of a save.
    message: [96]u8 = undefined,
    /// Scratch for the status bar's position item.
    pos_text: [48]u8 = undefined,
    dark: bool = true,
    editor_node: zg_gui.core.NodeId = .none,
    focused: bool = false,
    /// Created on first show.
    terminal: ?*TerminalPanel = null,
    terminal_node: zg_gui.core.NodeId = .none,
    /// Focus the terminal once it is in the tree.
    focus_terminal: bool = false,
    /// This session's trust in the working folder (until the trust store).
    trust: zg_security.contracts.TrustState = .unknown,
    approvals: zg_security_ui.DialogApprovalPort = undefined,
    /// Created on first show, with the panel.
    agent: ?*AgentHost = null,
    agent_panel: ?*AgentPanel = null,
    /// Code block colours in the agent's replies (with the panel).
    md_highlight: ?zg_editor.view.MarkdownHighlighter = null,
    /// Slash commands and skills, in the palette and the agent prompt.
    agent_cmds: ?*AgentCommands = null,
    focus_agent: bool = false,
    /// The review queue (needs the agent), created on first show.
    review_panel: ?*QueuePanel = null,
    /// The last review view; kept after its tab closes until the next
    /// one opens.
    review_view: ?*ReviewView = null,
    /// Scratch for the review tab's badge.
    review_badge: [12]u8 = undefined,
    /// Polls the review store for other processes' records (`zg review`)
    /// while the review panel exists.
    review_timer: Window.TimerId = .none,
    /// This working folder's saved layout (`loadLayout`), and its saver
    /// (from `attach`).
    layout_dir: ?std.Io.Dir = null,
    persister: ?persist.Persister = null,
    /// The dock revision the saver last saw.
    layout_rev: u64 = 0,
    /// The layout was saved on close; later changes (floating panels
    /// docking back) are not saved.
    layout_final: bool = false,

    /// One open file and its dock panel; the current one is mirrored in
    /// the fields above.
    const OpenFile = struct {
        path: ?[]u8,
        doc: *Document,
        view: *EditorView,
        syntax: ?*DocumentSyntax,
        panel: PanelRef = undefined,
        /// The editor widget (last build).
        node: zg_gui.core.NodeId = .none,
    };

    /// Dock panel kinds.
    const kind_editor: zg_gui.dock.model.PanelKindId = 1;
    const kind_terminal: zg_gui.dock.model.PanelKindId = 2;
    const kind_agent: zg_gui.dock.model.PanelKindId = 3;
    const kind_review: zg_gui.dock.model.PanelKindId = 4;
    const kind_review_view: zg_gui.dock.model.PanelKindId = 5;
    /// The kinds' names in the saved layout (index = kind - 1).
    const kind_names = [_][]const u8{ "editor", "terminal", "agent", "review", "review.view" };

    /// Loads `path` (a missing file opens as a new empty one) and sets up
    /// commands and key bindings. Call `attach` once the window exists.
    /// `wb` must not move afterwards.
    pub fn init(wb: *Workbench, rt: *zg_core.Runtime, env: *const std.process.Environ.Map, path: ?[]const u8) !void {
        const gpa = rt.gpa;
        const io = rt.io;
        wb.* = .{
            .rt = rt,
            .gpa = gpa,
            .io = io,
            .env = env,
            .docs = .init(gpa, .native),
            .doc = undefined,
            .view = undefined,
            .langs = try zg_syntax.defaultRegistry(gpa),
            .keys = .init(gpa),
            .reg = undefined,
            .diags = .init(gpa),
            .resolver = undefined,
            .crumbs = .init(gpa, io),
            .dock = try .init(gpa),
        };
        wb.dv = .init(gpa, &wb.dock, wb.panelHost());
        wb.cwd = try std.process.currentPathAlloc(io, gpa);
        const f = try wb.addFile(try wb.load(path));
        wb.setCurrent(f.*);

        wb.reg = try registry.CommandRegistry.init(gpa, &wb.keys, .{ .io = io });
        try registry.registerBuiltins(wb.reg);
        try wb.registerCommands();
        const ac = try AgentCommands.init(gpa, io, wb.cwd);
        wb.agent_cmds = ac;
        ac.on_palette = .{ .ctx = wb, .f = runAgentCommand };
        try ac.registerPalette(wb.reg);
        wb.resolver = try zg_config.resolver.Resolver.init(gpa, &wb.keys, &zg_config.keys.us_layout, .{});
        try wb.loadKeymap();
    }

    /// Reads and opens `path` (relative to the working folder; null: an
    /// untitled buffer).
    fn load(wb: *Workbench, path: ?[]const u8) !OpenFile {
        const gpa = wb.gpa;
        var bytes: []u8 = &.{};
        defer gpa.free(bytes);
        var f: OpenFile = .{ .path = null, .doc = undefined, .view = undefined, .syntax = null };
        errdefer if (f.path) |p| gpa.free(p);
        if (path) |p| {
            f.path = try gpa.dupe(u8, p);
            bytes = std.Io.Dir.cwd().readFileAlloc(wb.io, p, gpa, .limited(256 << 20)) catch |e| switch (e) {
                error.FileNotFound => try gpa.alloc(u8, 0),
                else => return e,
            };
        }
        const h = if (f.path) |p| blk: {
            const abs = try std.fs.path.resolve(gpa, &.{ wb.cwd, p });
            defer gpa.free(abs);
            break :blk try wb.docs.openFile(abs, bytes);
        } else try wb.docs.openUntitled(bytes);
        f.doc = wb.docs.get(h).?;
        f.view = try EditorView.init(gpa, f.doc, .{});
        errdefer f.view.deinit();
        if (wb.langs.detect(f.path, bytes[0..@min(bytes.len, 256)])) |id| if (wb.langs.get(id)) |lang| {
            const sx = try gpa.create(DocumentSyntax);
            errdefer gpa.destroy(sx);
            sx.* = try DocumentSyntax.init(gpa, lang, &wb.langs, &f.doc.tree, f.doc.version);
            f.syntax = sx;
            f.view.syntax = sx;
        };
        return f;
    }

    fn closeFile(wb: *Workbench, f: OpenFile) void {
        f.view.deinit();
        if (f.syntax) |sx| {
            sx.deinit();
            wb.gpa.destroy(sx);
        }
        if (f.path) |p| wb.gpa.free(p);
    }

    /// Makes `f` the edited file and points the breadcrumbs at it.
    fn setCurrent(wb: *Workbench, f: OpenFile) void {
        wb.cur_panel = f.panel;
        wb.path = f.path;
        wb.doc = f.doc;
        wb.view = f.view;
        wb.syntax = f.syntax;
        const abs = if (f.path) |p| std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) catch null else null;
        defer if (abs) |a| wb.gpa.free(a);
        if (abs) |a| wb.crumbs.set(wb.cwd, a) catch {} else wb.crumbs.len = 0;
    }

    /// Keeps `f` and opens it as a tab in the focused center group.
    fn addFile(wb: *Workbench, f: OpenFile) !*OpenFile {
        errdefer wb.closeFile(f);
        try wb.files.append(wb.gpa, f);
        const nf = &wb.files.items[wb.files.items.len - 1];
        nf.panel = try wb.addEditorPanel(nf.*);
        try wb.showEditor(nf);
        if (wb.win != null) nf.view.on_change = .{ .ctx = wb, .f = onViewChange };
        return nf;
    }

    /// A dock panel for `f`; its state is the file's absolute path (what
    /// the saved layout reopens).
    fn addEditorPanel(wb: *Workbench, f: OpenFile) !PanelRef {
        const abs = if (f.path) |p| try std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) else null;
        defer if (abs) |a| wb.gpa.free(a);
        return wb.dock.addPanel(kind_editor, abs);
    }

    /// Opens `f`'s tab (again, if it was closed) and activates it.
    fn showEditor(wb: *Workbench, f: *OpenFile) !void {
        if (!wb.dock.panels.contains(f.panel)) f.panel = try wb.addEditorPanel(f.*);
        if (wb.dock.groupOf(f.panel)) |g| {
            try wb.dock.openIn(f.panel, g, null, .{});
            return;
        }
        try wb.dock.openIn(f.panel, wb.editorGroup(), null, .{});
    }

    /// Where new editors open: the focused group when it is in the
    /// center, else the center's first group.
    fn editorGroup(wb: *Workbench) zg_gui.dock.model.GroupId {
        if (wb.dock.focused) |g| if (wb.dock.ownerOf(.{ .group = g })) |o| if (o == .area and o.area == .center) return g;
        return wb.dock.firstGroup(wb.dock.areas[@intFromEnum(Area.center)].root).?;
    }

    /// Switches the editor to `abs` in a tab, loading it the first time.
    /// UI thread, between frames.
    pub fn openFile(wb: *Workbench, abs: []const u8) !void {
        for (wb.files.items) |*f| if (f.path) |p| if (samePath(wb, p, abs)) {
            try wb.showEditor(f);
            wb.setCurrent(f.*);
            return;
        };
        const f = try wb.addFile(try wb.load(abs));
        wb.setCurrent(f.*);
    }

    fn fileOf(wb: *Workbench, p: PanelRef) ?*OpenFile {
        for (wb.files.items) |*f| if (f.panel == p) return f;
        return null;
    }

    fn kindOf(wb: *Workbench, p: PanelRef) ?zg_gui.dock.model.PanelKindId {
        return if (wb.dock.panels.get(p)) |v| v.kind else null;
    }

    /// The side area showing `p`, if any.
    fn areaOf(wb: *Workbench, p: ?PanelRef) ?Area {
        const r = p orelse return null;
        const g = wb.dock.groupOf(r) orelse return null;
        const o = wb.dock.ownerOf(.{ .group = g }) orelse return null;
        return if (o == .area) o.area else null;
    }

    /// Whether `p` is in the layout and its area is shown.
    fn shown(wb: *Workbench, p: ?PanelRef) bool {
        const a = wb.areaOf(p) orelse return false;
        return wb.dock.areas[@intFromEnum(a)].visible;
    }

    /// Shows `p` in its area (docking it into `home` when it is not in the
    /// layout) and activates its tab.
    fn reveal(wb: *Workbench, p: PanelRef, home: Area) !void {
        if (wb.dock.groupOf(p) == null) try wb.dock.move(p, .{ .area = home });
        if (wb.areaOf(p)) |a| wb.dock.areaVisible(a, true);
        if (wb.dock.groupOf(p)) |g| try wb.dock.openIn(p, g, null, .{});
    }

    /// Hides `p`: its side area hides (an editor-area tab stays).
    fn conceal(wb: *Workbench, p: PanelRef) void {
        const a = wb.areaOf(p) orelse return;
        if (a != .center) wb.dock.areaVisible(a, false);
    }

    fn samePath(wb: *Workbench, p: []const u8, abs: []const u8) bool {
        const a = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) catch return false;
        defer wb.gpa.free(a);
        return std.mem.eql(u8, a, abs);
    }

    /// Opens changeset `cs` hunk by hunk in an editor-area tab (one at a
    /// time).
    fn openReview(ctx: *anyopaque, cs: zg_review.model.ChangesetId) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.showReview(cs) catch |e| wb.notify(.error_, "Could not open the review: {t}", .{e});
    }

    fn showReview(wb: *Workbench, cs: zg_review.model.ChangesetId) !void {
        const w = wb.win orelse return;
        const host = wb.agent orelse return;
        const v = try ReviewView.create(wb.gpa, wb.io, w.app, host.review, .{ .changeset = cs });
        v.on_change = .{ .ctx = wb, .f = onTerminalOutput };
        if (wb.review_view) |old| old.destroy();
        wb.review_view = v;
        if (wb.review_view_ref == null) wb.review_view_ref = try wb.dock.addPanel(kind_review_view, null);
        try wb.reveal(wb.review_view_ref.?, .center);
        w.markAllDirty();
    }

    /// Whether the review root's `rel` is open in an editor (the review
    /// panel leaves those files alone).
    fn reviewFileOpen(ctx: *anyopaque, rel: []const u8) bool {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const host = wb.agent orelse return false;
        const abs = std.fs.path.resolve(wb.gpa, &.{ host.review.root, rel }) catch return true;
        defer wb.gpa.free(abs);
        for (wb.files.items) |f| if (f.path) |p| if (wb.samePath(p, abs)) return true;
        return false;
    }

    /// Breadcrumb dropdowns run `file.open` from event handling: switch
    /// at the next build.
    fn onChromeAction(ctx: ?*anyopaque, action: zg_gui.w.menu.ActionId, arg: ?[]const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.eql(u8, action, path_crumbs.open_action)) {
            if (wb.win) |w| _ = w.dispatchAction(action, arg);
            return;
        }
        const a = arg orelse return;
        const copy = wb.gpa.dupe(u8, a) catch return;
        if (wb.pending_open) |old| wb.gpa.free(old);
        wb.pending_open = copy;
        if (wb.win) |w| w.markAllDirty();
    }

    fn panelHost(wb: *Workbench) zg_gui.dock.PanelHost {
        return .{ .ctx = wb, .tab = panelTab, .build = panelBuild, .empty = emptyGroup, .can_close = canClose };
    }

    /// Lets tabs tear off into their own windows, opened by `opener`
    /// (after `attach`).
    pub fn enableFloating(wb: *Workbench, opener: zg_gui.dock.floating.WindowOpener) void {
        const w = wb.win orelse return;
        wb.floater = .init(wb.gpa, &wb.dock, wb.panelHost(), opener, .{});
        wb.floater.?.attachMain(w, &wb.dv);
        // Saves the layout before floating panels dock back.
        w.on_close = .{ .ctx = wb, .f = onMainClose };
        // Restored floating panels get their windows.
        wb.floater.?.sync() catch |e| log.warn("floating panels not restored: {t}", .{e});
    }

    // -- the saved layout ------------------------------------------------

    fn kindName(_: ?*anyopaque, k: PanelKindId) ?[]const u8 {
        return if (k >= 1 and k <= kind_names.len) kind_names[k - 1] else null;
    }

    fn kindId(_: ?*anyopaque, name: []const u8) ?PanelKindId {
        for (kind_names, 1..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        return null;
    }

    const layout_kinds: persist.Kinds = .{ .name = kindName, .id = kindId };

    /// Restores the layout saved for the working folder (in
    /// `<state_dir>/layouts/<hash of the folder>`): editors reopen their
    /// files and the terminal, agent and review panels come back where
    /// they were (started by `attach` when shown). Returns the main
    /// window's saved size. Call after `init`, before `attach`; without
    /// it nothing is saved.
    pub fn loadLayout(wb: *Workbench, state_dir: []const u8) ?zg_gui.core.geom.Size {
        const sep = std.fs.path.sep;
        const sub = std.fmt.allocPrint(wb.gpa, "{s}{c}layouts{c}{x:0>16}", .{ state_dir, sep, sep, std.hash.Wyhash.hash(0, wb.cwd) }) catch return null;
        defer wb.gpa.free(sub);
        const dir = std.Io.Dir.cwd().createDirPathOpen(wb.io, sub, .{}) catch |e| {
            log.warn("layout folder {s}: {t}", .{ sub, e });
            return null;
        };
        wb.layout_dir = dir;
        var r = persist.load(wb.gpa, wb.io, dir);
        defer r.deinit();
        const l: *persist.Loaded = switch (r) {
            .ok, .migrated => |*l| l,
            else => return null,
        };
        const m = persist.toModel(wb.gpa, &l.file, layout_kinds) catch |e| {
            log.warn("the saved layout was not used: {t}", .{e});
            return null;
        };
        wb.adoptLayout(m) catch |e| log.warn("the saved layout was not fully restored: {t}", .{e});
        for (l.file.windows) |win| if (std.mem.eql(u8, win.id, "main") and win.rect[2] > 0 and win.rect[3] > 0) {
            return .{ .w = @floatFromInt(win.rect[2]), .h = @floatFromInt(win.rect[3]) };
        };
        return null;
    }

    /// Replaces the dock with `restored` and matches its panels to files
    /// and panels; what cannot come back closes.
    fn adoptLayout(wb: *Workbench, restored: zg_gui.dock.DockModel) !void {
        wb.dock.deinit();
        wb.dock = restored;
        wb.dock.history = false;
        defer wb.dock.history = true;
        // `init` opened one file, in the old layout.
        var first_placed = false;
        var stale: std.ArrayList(PanelRef) = .empty;
        defer stale.deinit(wb.gpa);
        const refs = try wb.gpa.dupe(PanelRef, wb.dock.panels.keys());
        defer wb.gpa.free(refs);
        for (refs) |p| {
            const v = wb.dock.panels.get(p) orelse continue;
            switch (v.kind) {
                kind_editor => {
                    const abs = v.state orelse {
                        try stale.append(wb.gpa, p);
                        continue;
                    };
                    const first = &wb.files.items[0];
                    if (!first_placed) if (first.path) |fp| if (wb.samePath(fp, abs)) {
                        first.panel = p;
                        first_placed = true;
                        continue;
                    };
                    // A file that is gone stays closed.
                    _ = std.Io.Dir.cwd().statFile(wb.io, abs, .{}) catch {
                        try stale.append(wb.gpa, p);
                        continue;
                    };
                    var f = wb.load(abs) catch {
                        try stale.append(wb.gpa, p);
                        continue;
                    };
                    f.panel = p;
                    wb.files.append(wb.gpa, f) catch |e| {
                        wb.closeFile(f);
                        return e;
                    };
                },
                kind_terminal => wb.terminal_ref = p,
                kind_agent => wb.agent_ref = p,
                kind_review => wb.review_ref = p,
                // Review views are not kept; unknown kinds stay as they are.
                kind_review_view => try stale.append(wb.gpa, p),
                else => {},
            }
        }
        for (stale.items) |p| try wb.dock.close(p);
        // The closed list is for panels the user closed.
        for (wb.dock.closed.items) |c| if (c.panel.state) |st| wb.gpa.free(st);
        wb.dock.closed.clearRetainingCapacity();
        if (!first_placed) {
            if (wb.files.items[0].path == null and wb.files.items.len > 1) {
                // An untitled buffer gives way to the restored editors.
                wb.closeFile(wb.files.orderedRemove(0));
            } else {
                const f = &wb.files.items[0];
                f.panel = try wb.addEditorPanel(f.*);
                try wb.showEditor(f);
            }
        }
        wb.setCurrent(wb.files.items[0]);
        wb.followFocus();
    }

    /// The layout as saved (a `Persister` source).
    fn layoutSnapshot(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!persist.LayoutFile {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        var windows: [1]persist.WindowLayout = .{.{ .id = "main" }};
        if (wb.win) |w| windows[0].rect = .{ 0, 0, @intFromFloat(@max(0, w.size.w)), @intFromFloat(@max(0, w.size.h)) };
        return persist.fromModel(arena, &wb.dock, layout_kinds, &windows, &.{});
    }

    /// Saves the layout now, once (closing).
    fn saveLayoutNow(wb: *Workbench) void {
        if (wb.layout_final) return;
        const p = if (wb.persister) |*p| p else return;
        wb.layout_final = true;
        p.saveNow() catch |e| log.warn("layout not saved: {t}", .{e});
    }

    /// The main window is closing: save the layout, then bring floating
    /// panels home.
    fn onMainClose(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.saveLayoutNow();
        if (wb.floater) |*fl| fl.closeAll();
        w.close_requested = true;
    }

    /// Whether the terminal, agent or review panel is shown (`kind` is
    /// one of "terminal", "agent", "review").
    pub fn panelShown(wb: *Workbench, comptime kind: []const u8) bool {
        return wb.shown(@field(wb, kind ++ "_ref"));
    }

    /// Unhooks from the window; call while it still exists.
    pub fn detach(wb: *Workbench) void {
        const w = wb.win orelse return;
        wb.saveLayoutNow();
        if (wb.persister) |*p| p.deinit();
        wb.persister = null;
        // Floating panels come home before their windows close.
        if (wb.floater) |*fl| fl.closeAll();
        // The panel stops the agent first: its tools may be waiting on
        // this thread or on an approval dialog.
        if (wb.agent_panel) |p| p.destroy();
        wb.agent_panel = null;
        if (wb.md_highlight) |*h| h.deinit(wb.gpa);
        wb.md_highlight = null;
        if (wb.review_view) |v| v.destroy();
        wb.review_view = null;
        if (wb.review_timer != .none) w.cancelTimer(wb.review_timer);
        wb.review_timer = .none;
        if (wb.review_panel) |p| p.destroy();
        wb.review_panel = null;
        if (wb.agent_cmds) |c| c.target = null;
        if (wb.agent) |a| a.destroy();
        wb.agent = null;
        if (wb.terminal) |t| t.destroy();
        wb.terminal = null;
        wb.approvals.deinit();
        wb.palette.handle.close(w);
        wb.adapter.deinit();
        wb.palette.deinit();
        for (wb.files.items) |f| f.view.on_change = null;
        wb.win = null;
    }

    /// Frees everything (after `detach`).
    pub fn deinit(wb: *Workbench) void {
        wb.detach();
        wb.resolver.deinit();
        if (wb.keymap) |k| k.deinit();
        for (wb.keymap_docs.items) |*d| d.deinit();
        wb.keymap_docs.deinit(wb.gpa);
        wb.reg.deinit();
        // After the registry: its palette handlers point into it.
        if (wb.agent_cmds) |c| c.deinit();
        wb.diags.deinit();
        wb.keys.deinit();
        for (wb.files.items) |f| wb.closeFile(f);
        wb.files.deinit(wb.gpa);
        if (wb.floater) |*fl| fl.deinit();
        wb.dv.deinit();
        wb.dock.deinit();
        if (wb.pending_open) |p| wb.gpa.free(p);
        wb.crumbs.deinit();
        wb.docs.deinit();
        wb.langs.deinit(wb.gpa);
        wb.gpa.free(wb.cwd);
        if (wb.layout_dir) |d| d.close(wb.io);
    }

    /// Hooks the keymap and the palette into `win` and focuses the editor.
    pub fn attach(wb: *Workbench, win: *Window) !void {
        wb.win = win;
        wb.adapter = .init(wb.gpa, wb.reg, wb.resolver, win);
        wb.adapter.install();
        wb.adapter.on_status = .{ .ctx = wb, .f = onStatus };
        wb.palette = .init(wb.gpa, wb.reg, &wb.adapter);
        try wb.palette.registerCommands();
        for (wb.files.items) |f| f.view.on_change = .{ .ctx = wb, .f = onViewChange };
        wb.approvals = .init(wb.gpa, wb.io, win);
        win.on_close = .{ .ctx = wb, .f = onMainClose };
        if (wb.layout_dir) |dir| {
            wb.persister = .{ .gpa = wb.gpa, .io = wb.io, .app = win.app, .dir = dir, .source = .{ .ctx = wb, .snapshot = layoutSnapshot }, .win = win };
            wb.layout_rev = wb.dock.revision;
        }
        // Panels the restored layout shows start now.
        if (wb.inLayout(wb.terminal_ref)) try wb.startTerminal(win);
        if (wb.inLayout(wb.agent_ref)) try wb.startAgent(win);
        if (wb.inLayout(wb.review_ref)) try wb.startReview(win);
    }

    /// Whether `p` is in a group (docked or floating) of a shown area.
    fn inLayout(wb: *Workbench, p: ?PanelRef) bool {
        const r = p orelse return false;
        if (wb.dock.groupOf(r) == null) return false;
        return wb.areaOf(r) == null or wb.shown(r);
    }

    fn loadKeymap(wb: *Workbench) !void {
        for (zg_config.presets.presetLayers(.vscode)) |src| {
            try wb.keymap_docs.append(wb.gpa, try zg_config.zon_load.loadZon(wb.gpa, src, &wb.diags));
        }
        var inputs: std.ArrayList(zg_config.keymap.LayerInput) = .empty;
        defer inputs.deinit(wb.gpa);
        for (wb.keymap_docs.items) |*d| try inputs.append(wb.gpa, .{ .layer = .preset, .doc = d });
        wb.keymap = try zg_config.keymap.Keymap.build(wb.gpa, inputs.items, wb.reg, &wb.keys, zg_config.keyspec.Platform.of(@import("builtin").os.tag), &wb.diags);
        wb.resolver.reload(wb.keymap.?);
    }

    const Cmd = struct { id: []const u8, title: []const u8, category: []const u8, run: *const fn (wb: *Workbench) anyerror!void };

    const commands = [_]Cmd{
        .{ .id = "file.save", .title = "Save", .category = "File", .run = save },
        .{ .id = "terminal.toggle", .title = "Toggle Terminal", .category = "View", .run = toggleTerminal },
        .{ .id = "agent.togglePane", .title = "Toggle Agent Pane", .category = "Agent", .run = toggleAgent },
        .{ .id = "review.queue.toggle", .title = "Toggle Review Queue", .category = "Review", .run = toggleReview },
        .{ .id = "workspace.manageTrust", .title = "Manage Workspace Trust", .category = "Workspaces", .run = manageTrust },
        .{ .id = "editor.undo", .title = "Undo", .category = "Edit", .run = undo },
        .{ .id = "editor.redo", .title = "Redo", .category = "Edit", .run = redo },
        .{ .id = "editor.selectAll", .title = "Select All", .category = "Selection", .run = selectAll },
        .{ .id = "workbench.toggleTheme", .title = "Toggle Light/Dark Theme", .category = "Preferences", .run = toggleTheme },
    };

    fn registerCommands(wb: *Workbench) !void {
        inline for (commands) |c| {
            _ = try wb.reg.register(.{
                .id = c.id,
                .title = c.title,
                .category = c.category,
                .source = .{ .builtin = "zigguro" },
                .handler = .{ .ctx = wb, .run = struct {
                    fn f(ctx: ?*anyopaque, _: *registry.Invocation) anyerror!void {
                        const self: *Workbench = @ptrCast(@alignCast(ctx.?));
                        try c.run(self);
                        if (self.win) |w| w.markAllDirty();
                    }
                }.f },
            });
        }
    }

    fn notify(wb: *Workbench, severity: zg_gui.w.notification_center.Severity, comptime fmt: []const u8, args: anytype) void {
        const w = wb.win orelse return;
        const s = std.fmt.bufPrint(&wb.message, fmt, args) catch return;
        _ = zg_gui.w.toast(w.app, .{ .severity = severity, .title = s, .source = "Files" });
    }

    /// Writes the document to its file.
    pub fn save(wb: *Workbench) !void {
        const p = wb.path orelse {
            wb.notify(.warning, "Untitled: start zigguro with a file path to save", .{});
            return;
        };
        const bytes = try wb.view.allText(wb.gpa);
        defer wb.gpa.free(bytes);
        std.Io.Dir.cwd().writeFile(wb.io, .{ .sub_path = p, .data = bytes }) catch |e| {
            wb.notify(.error_, "Save failed: {t}", .{e});
            return e;
        };
        wb.doc.saved_version = wb.doc.version;
        wb.notify(.success, "Saved {s} ({d} bytes)", .{ std.fs.path.basename(p), bytes.len });
    }

    fn undo(wb: *Workbench) !void {
        _ = try wb.view.undoStep();
    }

    fn redo(wb: *Workbench) !void {
        _ = try wb.view.redoStep();
    }

    fn selectAll(wb: *Workbench) !void {
        wb.view.selectAll();
    }

    fn toggleTheme(wb: *Workbench) !void {
        const w = wb.win orelse return;
        wb.dark = !wb.dark;
        w.app.follow_system = false;
        w.app.setTheme(if (wb.dark) &themes.zigguro_dark else &themes.zigguro_light);
    }

    /// Shows the terminal panel (starting its shell) and focuses it, or
    /// hides it and focuses the editor.
    pub fn toggleTerminal(wb: *Workbench) !void {
        const w = wb.win orelse return;
        if (wb.shown(wb.terminal_ref) and wb.areaOf(wb.terminal_ref) != .center) {
            wb.conceal(wb.terminal_ref.?);
            if (!wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
            return;
        }
        try wb.startTerminal(w);
        if (wb.terminal_ref == null) wb.terminal_ref = try wb.dock.addPanel(kind_terminal, null);
        try wb.reveal(wb.terminal_ref.?, .bottom);
        wb.focus_terminal = true;
        w.markAllDirty();
        w.afterNextFrame(.{ .ctx = wb, .f = focusTerminal });
    }

    /// Creates the terminal and starts its shell, once.
    fn startTerminal(wb: *Workbench, w: *Window) !void {
        if (wb.terminal != null) return;
        const t = try TerminalPanel.create(wb.gpa, wb.io, w.app, wb.env);
        t.on_output = .{ .ctx = wb, .f = onTerminalOutput };
        wb.terminal = t;
        t.start();
    }

    /// Shows the agent pane (starting the agent) and focuses its prompt,
    /// or hides it and focuses the editor.
    pub fn toggleAgent(wb: *Workbench) !void {
        const w = wb.win orelse return;
        if (wb.shown(wb.agent_ref) and wb.areaOf(wb.agent_ref) != .center) {
            wb.conceal(wb.agent_ref.?);
            if (!wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
            return;
        }
        try wb.startAgent(w);
        if (wb.agent_ref == null) wb.agent_ref = try wb.dock.addPanel(kind_agent, null);
        try wb.reveal(wb.agent_ref.?, .agent);
        wb.focus_agent = true;
        w.markAllDirty();
        w.afterNextFrame(.{ .ctx = wb, .f = focusAgent });
    }

    /// Creates the agent and its panel, once.
    fn startAgent(wb: *Workbench, w: *Window) !void {
        if (wb.agent_panel != null) return;
        const host = try AgentHost.create(wb.rt, wb.env, w.app, &wb.docs, wb.approvals.port());
        errdefer host.destroy();
        host.files.on_edit = .{ .ctx = wb, .f = onAgentEdit };
        const p = try AgentPanel.create(wb.gpa, wb.io, w.app, host.agent);
        p.on_change = .{ .ctx = wb, .f = onTerminalOutput };
        if (wb.md_highlight == null) wb.md_highlight = zg_editor.view.MarkdownHighlighter.init(wb.gpa) catch null;
        if (wb.md_highlight) |*h| p.highlighter = h.highlighter();
        // Pasted images go to the project's .zigguro/attachments.
        if (std.fs.path.join(wb.gpa, &.{ wb.cwd, ".zigguro", "attachments" })) |dir| {
            defer wb.gpa.free(dir);
            p.enableImagePaste(dir) catch {};
        } else |_| {}
        p.plans = &host.plans;
        p.plan_mode = &host.plan_mode;
        p.attachChildren(&host.children);
        // Rewinding code goes through E12's checkpoints.
        p.restore = host.review.restore();
        if (wb.agent_cmds) |c| {
            c.target = .{ .agent = host.agent, .plan_mode = &host.plan_mode, .agent_tools = &host.agent_tools, .subagents = host.subagents.defs, .context = &host.context };
            p.commands = c;
        }
        host.plans.on_change = .{ .ctx = wb, .f = onTerminalOutput };
        if (wb.trust == .trusted) host.connectMcp(wb.rt, wb.env);
        wb.agent = host;
        wb.agent_panel = p;
    }

    /// Shows the review queue in the left area (starting the agent, whose
    /// edits it lists), or hides it.
    pub fn toggleReview(wb: *Workbench) !void {
        const w = wb.win orelse return;
        if (wb.shown(wb.review_ref) and wb.areaOf(wb.review_ref) != .center) {
            wb.conceal(wb.review_ref.?);
            return;
        }
        if (wb.agent == null) try wb.toggleAgent();
        try wb.startReview(w);
        if (wb.review_ref == null) wb.review_ref = try wb.dock.addPanel(kind_review, null);
        try wb.reveal(wb.review_ref.?, .left);
        w.markAllDirty();
    }

    /// Creates the review queue (and the agent it needs), once.
    fn startReview(wb: *Workbench, w: *Window) !void {
        if (wb.review_panel != null) return;
        try wb.startAgent(w);
        const host = wb.agent orelse return;
        const p = try QueuePanel.create(wb.gpa, wb.io, w.app, host.review);
        p.on_change = .{ .ctx = wb, .f = onTerminalOutput };
        p.is_open = .{ .ctx = wb, .f = reviewFileOpen };
        p.open_review = .{ .ctx = wb, .f = openReview };
        wb.review_panel = p;
        wb.review_timer = w.setTimer(w.app.now_ms + review_poll_ms, .{ .ctx = wb, .f = pollReview }) catch .none;
    }

    /// Takes in what `zg review` or another window decided, then polls
    /// again.
    fn pollReview(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.review_timer = .none;
        const host = wb.agent orelse return;
        if (host.review.refresh()) w.markAllDirty();
        wb.review_timer = w.setTimer(w.app.now_ms + review_poll_ms, .{ .ctx = wb, .f = pollReview }) catch .none;
    }

    /// A palette "AI: /name" command: opens the agent pane and runs
    /// `/name`, or for one that takes arguments, puts `/name ` in the
    /// prompt.
    fn runAgentCommand(ctx: *anyopaque, name: []const u8, takes_args: bool) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (!wb.shown(wb.agent_ref) or wb.areaOf(wb.agent_ref) == .center) wb.toggleAgent() catch |e| {
            wb.notify(.error_, "Could not start the agent: {t}", .{e});
            return;
        };
        const p = wb.agent_panel orelse return;
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "/{s}{s}", .{ name, if (takes_args) " " else "" }) catch return;
        if (takes_args) {
            p.input.setText(line) catch {};
        } else p.submit(line) catch |e| wb.notify(.error_, "/{s} failed: {t}", .{ name, e });
    }

    fn focusAgent(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.focus_agent) if (wb.agent_panel) |p| if (!p.input_node.isNone()) w.setFocus(p.input_node, false);
        wb.focus_agent = false;
    }

    /// An agent edit landed in the open document (the view follows the
    /// document's changes): repaint.
    fn onAgentEdit(ctx: *anyopaque, _: zg_editor.model.api.registry.DocHandle, _: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    /// Asks whether to trust the working folder.
    pub fn manageTrust(wb: *Workbench) !void {
        const w = wb.win orelse return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(wb.io, &buf) catch return;
        const folder = buf[0..n];
        const parent = zg_security_ui.trustableParent(folder, wb.env.get("HOME") orelse wb.env.get("USERPROFILE"));
        _ = try zg_security_ui.askTrust(w, .{ .folder = folder, .parent = parent }, .{ .ctx = wb, .f = onTrust });
    }

    fn onTrust(ctx: ?*anyopaque, c: zg_security_ui.TrustChoice) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx.?));
        wb.trust = if (c == .restricted) .restricted else .trusted;
        // A trusted folder's MCP servers may start.
        if (wb.trust == .trusted) if (wb.agent) |a| a.connectMcp(wb.rt, wb.env);
        if (wb.win) |w| w.markAllDirty();
    }

    fn focusTerminal(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.focus_terminal and !wb.terminal_node.isNone()) w.setFocus(wb.terminal_node, false);
        wb.focus_terminal = false;
    }

    fn onTerminalOutput(ctx: *anyopaque) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    fn onStatus(ctx: *anyopaque, _: ?[]const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    fn onViewChange(ctx: *anyopaque, _: *EditorView) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    pub fn build(wb: *Workbench, ui: *Ui) void {
        if (wb.pending_open) |p| {
            wb.pending_open = null;
            defer wb.gpa.free(p);
            if (wb.openFile(p)) {
                ui.win.afterNextFrame(.{ .ctx = wb, .f = focusOpened });
            } else |e| wb.notify(.error_, "Could not open {s}: {t}", .{ std.fs.path.basename(p), e });
        }
        wb.followFocus();
        wb.dv.beginFrame(ui);
        // At the window origin: the chrome (title bar and frame when the
        // platform asks us to draw them), then the dock's drop preview.
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .dir = .column } });
        defer ui.close();
        defer wb.dv.dropOverlay(ui);
        zg_gui.dock.chrome.begin(ui, .{ .title = "zigguro" });
        defer zg_gui.dock.chrome.end(ui);
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .dir = .column, .bg = .{ .token = .bg_base } } });
        defer ui.close();
        wb.header(ui);
        wb.terminal_node = .none;
        ui.open(.{ .style = .{ .dir = .row, .grow = 1, .basis = .{ .px = 0 }, .align_items = .stretch } });
        wb.sideArea(ui, .left, .{ .w = .{ .px = wb.areaSize(.left) }, .shrink = 0 });
        wb.sash(ui, .left);
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .align_items = .stretch } });
        wb.sideArea(ui, .center, .{ .grow = 1, .basis = .{ .px = 0 } });
        wb.sash(ui, .bottom);
        wb.sideArea(ui, .bottom, .{ .h = .{ .px = wb.areaSize(.bottom) }, .shrink = 0 });
        ui.close();
        wb.sash(ui, .right);
        wb.sideArea(ui, .right, .{ .w = .{ .px = wb.areaSize(.right) }, .shrink = 0 });
        wb.sash(ui, .agent);
        wb.sideArea(ui, .agent, .{ .w = .{ .px = wb.areaSize(.agent) }, .shrink = 0 });
        ui.close();
        if (wb.cur_panel) |cp| if (wb.fileOf(cp)) |f| {
            wb.editor_node = f.node;
        };
        // Focus the editor once it exists.
        if (!wb.focused) {
            wb.focused = true;
            ui.win.afterNextFrame(.{ .ctx = wb, .f = focusEditor });
        }
        wb.statusBar(ui);
        if (wb.persister) |*p| if (wb.dock.revision != wb.layout_rev and !wb.layout_final) {
            wb.layout_rev = wb.dock.revision;
            p.markDirty();
        };
    }

    /// The room the center keeps when a side area grows.
    const center_min: f32 = 160;

    fn areaSize(wb: *const Workbench, area: Area) f32 {
        return wb.dock.areas[@intFromEnum(area)].size;
    }

    fn areaShown(wb: *const Workbench, area: Area) bool {
        const a = wb.dock.areas[@intFromEnum(area)];
        return a.visible and a.root != null;
    }

    /// The resize handle on `area`'s inner edge, when it is shown. The
    /// area may grow until the center keeps `center_min`.
    fn sash(wb: *Workbench, ui: *Ui, area: Area) void {
        if (!wb.areaShown(area)) return;
        const win = ui.win.size;
        const t = zg_gui.dock.splitter.thickness;
        var others: f32 = 0;
        const avail = if (area == .bottom) win.h - 120 else blk: {
            for ([_]Area{ .left, .right, .agent }) |o| {
                if (o != area and wb.areaShown(o)) others += wb.areaSize(o) + t;
            }
            break :blk win.w - others - t;
        };
        zg_gui.dock.area_sash.areaSash(ui, .{
            .dock = &wb.dock,
            .area = area,
            .min_px = if (area == .bottom) 80 else 170,
            .max_px = avail - center_min,
        });
    }

    /// `area` in a box styled `st`, when shown.
    fn sideArea(wb: *Workbench, ui: *Ui, area: Area, st: zg_gui.Style) void {
        const a = wb.dock.areas[@intFromEnum(area)];
        if (!a.visible or a.root == null) return;
        var style = st;
        style.dir = .column;
        style.align_items = .stretch;
        if (area != .center) style.bg = .{ .token = .bg_elevated };
        ui.id(@intFromEnum(area));
        ui.open(.{ .style = style, .test_id = @tagName(area) });
        defer ui.close();
        wb.dv.dockArea(ui, area);
    }

    /// The focused group's active editor becomes the current file.
    fn followFocus(wb: *Workbench) void {
        const g = wb.dock.focused orelse return;
        const gr = wb.dock.group(g) orelse return;
        if (gr.active >= gr.tabs.items.len) return;
        const f = wb.fileOf(gr.tabs.items[gr.active]) orelse return;
        if (wb.cur_panel != f.panel) wb.setCurrent(f.*);
    }

    fn panelTab(ctx: *anyopaque, p: PanelRef) zg_gui.dock.view.TabInfo {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.fileOf(p)) |f| return .{
            .title = if (f.path) |path| std.fs.path.basename(path) else "Untitled",
            .dirty = f.doc.isDirty(),
            .tooltip = f.path,
        };
        return switch (wb.kindOf(p) orelse 0) {
            kind_terminal => .{ .title = "Terminal", .badge = if (wb.terminal) |t| t.noteText() else "" },
            kind_agent => .{ .title = "Agent" },
            kind_review => .{ .title = "Review", .badge = if (wb.review_panel) |r| r.badge(&wb.review_badge) else "" },
            kind_review_view => .{ .title = if (wb.review_view) |v| v.title else "Review" },
            else => .{ .title = "?" },
        };
    }

    fn panelBuild(ctx: *anyopaque, ui: *Ui, p: PanelRef) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.fileOf(p)) |f| {
            ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "editorFocus editorTextFocus" });
            defer ui.close();
            _ = zg_editor.view.editor(ui, .{ .view = f.view, .a11y_label = f.path orelse "Untitled" });
            // Focus helpers act on the main window's nodes only.
            f.node = if (ui.window() == wb.win) ui.lastNode() else .none;
            return;
        }
        switch (wb.kindOf(p) orelse 0) {
            kind_terminal => if (wb.terminal) |t| wb.terminalPanel(ui, t),
            kind_agent => if (wb.agent_panel) |a| {
                ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "agentPaneFocus" });
                defer ui.close();
                a.build(ui);
            },
            kind_review => if (wb.review_panel) |r| r.build(ui),
            kind_review_view => if (wb.review_view) |v| v.build(ui),
            else => {},
        }
    }

    fn emptyGroup(_: *anyopaque, ui: *Ui) void {
        ui.open(.{ .style = .{ .grow = 1, .justify = .center, .align_items = .center } });
        defer ui.close();
        ui.text("No open editors", .{ .color = .fg_muted, .wrap = false });
    }

    /// Unsaved editors stay open; closing the terminal or the agent
    /// hides its area (they keep running).
    fn canClose(ctx: *anyopaque, p: PanelRef) bool {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.fileOf(p)) |f| {
            if (!f.doc.isDirty()) return true;
            wb.notify(.warning, "{s} has unsaved changes: save it first", .{if (f.path) |path| std.fs.path.basename(path) else "Untitled"});
            return false;
        }
        // The review view's tab closes; the view stays until the next one.
        if (p == wb.review_view_ref) {
            wb.review_view_ref = null;
            return true;
        }
        if (p == wb.terminal_ref or p == wb.agent_ref or p == wb.review_ref) {
            if (wb.areaOf(p)) |a| if (a != .center) {
                wb.dock.areaVisible(a, false);
                return false;
            };
        }
        return true;
    }

    /// The editor's header: breadcrumbs for the file, the toolbar.
    fn header(wb: *Workbench, ui: *Ui) void {
        const w = ui.window();
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .padding = .xy(6, 0), .h = .{ .px = 28 }, .shrink = 0, .bg = .{ .token = .bg_elevated } } });
        defer ui.close();
        const avail = @max(0, w.size.w - 12);
        const crumbs = wb.crumbs.items();
        const untitled = [_]zg_gui.w.Crumb{.{ .label = "Untitled" }};
        const cb: zg_gui.w.menu.ActionCb = .{ .ctx = wb, .f = onChromeAction };
        zg_gui.w.breadcrumbs(ui, if (crumbs.len > 0) crumbs else &untitled, .{ .width = avail * 0.6, .on_action = cb });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        const tools = [_]zg_gui.w.ToolItem{
            .{ .id = "save", .label = "Save", .tooltip = "Save (Ctrl+S)", .action = "file.save", .priority = 1000, .enabled = wb.path != null },
            .{ .id = "terminal", .label = "Terminal", .tooltip = "Toggle Terminal (Ctrl+`)", .action = "terminal.toggle", .toggled = wb.shown(wb.terminal_ref), .priority = 10 },
            .{ .id = "agent", .label = "Agent", .tooltip = "Toggle Agent Pane (Ctrl+L)", .action = "agent.togglePane", .toggled = wb.shown(wb.agent_ref), .priority = 20 },
            .{ .id = "review", .label = "Review", .tooltip = "Toggle Review Queue", .action = "review.queue.toggle", .toggled = wb.shown(wb.review_ref), .priority = 15 },
            .{ .id = "theme", .label = "Theme", .tooltip = "Toggle Light/Dark Theme", .action = "workbench.toggleTheme", .priority = 1 },
        };
        zg_gui.w.toolbar(ui, &tools, .{ .label = "Editor actions", .width = avail * 0.4, .test_id = "editor_toolbar" });
    }

    fn focusOpened(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (!wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
    }

    fn focusEditor(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (w.focus.isNone() and !wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
    }

    fn terminalPanel(wb: *Workbench, ui: *Ui, t: *TerminalPanel) void {
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .bg = .{ .token = .bg_elevated } } });
        defer ui.close();
        const title = t.term.title.items;
        if (title.len > 0 or t.noteText().len > 0) {
            ui.open(.{ .style = .{ .dir = .row, .gap = 12, .padding = .xy(10, 3), .shrink = 0 } });
            if (title.len > 0) ui.text(title, .{ .color = .fg_muted, .wrap = false });
            if (t.noteText().len > 0) ui.text(t.noteText(), .{ .color = .warning, .wrap = false });
            ui.close();
        }
        _ = zg_terminal_view.terminal(ui, .{ .view = &t.view, .a11y_label = "Terminal" });
        if (ui.window() == wb.win) wb.terminal_node = t.view.node;
    }

    fn statusBar(wb: *Workbench, ui: *Ui) void {
        const name = if (wb.path) |p| std.fs.path.basename(p) else "Untitled";
        const head = wb.view.primarySel().head;
        const line = wb.view.lineOf(head);
        const col = head - wb.view.lineRange(line).start;
        const pos = if (wb.view.sels.items.len > 1)
            std.fmt.bufPrint(&wb.pos_text, "Ln {d}, Col {d} ({d} selections)", .{ line + 1, col + 1, wb.view.sels.items.len }) catch ""
        else
            std.fmt.bufPrint(&wb.pos_text, "Ln {d}, Col {d}", .{ line + 1, col + 1 }) catch "";
        var items: [7]zg_gui.w.StatusItem = undefined;
        var n: usize = 0;
        items[n] = .{ .id = "file", .text = if (wb.doc.isDirty()) "" else name, .priority = 1000 };
        n += 1;
        items[n] = .{ .id = "position", .text = pos, .priority = 100 };
        n += 1;
        if (wb.trust != .trusted) {
            items[n] = .{ .id = "trust", .text = "Restricted Mode", .side = .right, .priority = 900, .tone = .warning, .tooltip = "This folder is not trusted: click to manage workspace trust", .action = "workspace.manageTrust" };
            n += 1;
        }
        if (wb.syntax) |sx| {
            items[n] = .{ .id = "language", .text = sx.lang.name, .side = .right, .priority = 50 };
            n += 1;
        }
        items[n] = .{ .id = "terminal", .text = "Terminal", .side = .right, .priority = 10, .action = "terminal.toggle" };
        n += 1;
        items[n] = .{ .id = "agent", .text = "Agent", .side = .right, .priority = 11, .action = "agent.togglePane" };
        n += 1;
        // A dirty file shows a dot after its name.
        var name_buf: [128]u8 = undefined;
        if (wb.doc.isDirty()) items[0].text = std.fmt.bufPrint(&name_buf, "{s} \u{25cf}", .{name}) catch name;
        zg_gui.w.statusBar(ui, items[0..n], .{ .chord = wb.adapter.status() });
    }
};

test "workbench: the layout comes back in the next session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const b = 2;\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.zig" });
    defer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ root, "b.zig" });
    defer gpa.free(b);
    const state = try std.fs.path.join(gpa, &.{ root, "state" });
    defer gpa.free(state);

    {
        var wb: Workbench = undefined;
        try wb.init(&rt, &env, a);
        defer wb.deinit();
        try std.testing.expect(wb.loadLayout(state) == null);
        const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 600 }, .root = .of(&wb) });
        defer t.deinit();
        try wb.attach(t.win);
        defer wb.detach();
        try wb.openFile(b);
        wb.dock.setAreaSizeLive(.bottom, 333);
        _ = t.settle();
    }
    {
        // Untitled: the restored editors replace the empty buffer.
        var wb: Workbench = undefined;
        try wb.init(&rt, &env, null);
        defer wb.deinit();
        const size = wb.loadLayout(state).?;
        try std.testing.expectEqual(@as(f32, 900), size.w);
        try std.testing.expectEqual(@as(usize, 2), wb.files.items.len);
        try std.testing.expectEqualStrings("a.zig", std.fs.path.basename(wb.files.items[0].path.?));
        try std.testing.expectEqualStrings("b.zig", std.fs.path.basename(wb.files.items[1].path.?));
        try std.testing.expectEqual(@as(f32, 333), wb.dock.areas[@intFromEnum(Area.bottom)].size);
        for (wb.files.items) |f| try std.testing.expect(wb.dock.groupOf(f.panel) != null);
        try wb.dock.validate();
    }
}
