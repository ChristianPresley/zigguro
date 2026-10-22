//! The workbench until the docking shell (E04.F07) lands: one editor on a
//! file (or an empty buffer) under a header of breadcrumbs and a toolbar,
//! a terminal panel below it, and a status line, driven by the E15 keymap
//! (VS Code preset) and command palette. The breadcrumbs' dropdowns open
//! other files in the same editor (the files opened stay loaded).
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
const TerminalPanel = @import("terminal_panel.zig").TerminalPanel;
const AgentHost = @import("agent/host.zig").AgentHost;
const AgentPanel = @import("agent/panel.zig").AgentPanel;
const path_crumbs = @import("path_crumbs.zig");

const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const EditorView = zg_editor.view.EditorView;
const Document = zg_editor.model.document.Document;
const DocumentRegistry = zg_editor.model.api.registry.DocumentRegistry;
const DocumentSyntax = zg_editor.model.syntax.DocumentSyntax;
const registry = zg_config.commands;
const themes = zg_gui.theme.theme;

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
    /// The other files opened (their views stay loaded).
    others: std.ArrayList(OpenFile) = .empty,
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
    show_terminal: bool = false,
    terminal_node: zg_gui.core.NodeId = .none,
    /// Focus the terminal once it is in the tree.
    focus_terminal: bool = false,
    /// This session's trust in the working folder (until the trust store).
    trust: zg_security.contracts.TrustState = .unknown,
    approvals: zg_security_ui.DialogApprovalPort = undefined,
    /// Created on first show, with the panel.
    agent: ?*AgentHost = null,
    agent_panel: ?*AgentPanel = null,
    show_agent: bool = false,
    focus_agent: bool = false,

    /// One open file: the current one lives in the fields above, the
    /// others in `others`.
    const OpenFile = struct { path: ?[]u8, doc: *Document, view: *EditorView, syntax: ?*DocumentSyntax };

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
        };
        wb.cwd = try std.process.currentPathAlloc(io, gpa);
        const f = try wb.load(path);
        wb.setCurrent(f);

        wb.reg = try registry.CommandRegistry.init(gpa, &wb.keys, .{ .io = io });
        try registry.registerBuiltins(wb.reg);
        try wb.registerCommands();
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
        wb.path = f.path;
        wb.doc = f.doc;
        wb.view = f.view;
        wb.syntax = f.syntax;
        const abs = if (f.path) |p| std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) catch null else null;
        defer if (abs) |a| wb.gpa.free(a);
        if (abs) |a| wb.crumbs.set(wb.cwd, a) catch {} else wb.crumbs.len = 0;
    }

    /// Switches the editor to `abs`, loading it the first time. UI thread,
    /// between frames (the old view stays alive).
    pub fn openFile(wb: *Workbench, abs: []const u8) !void {
        if (wb.path) |p| if (samePath(wb, p, abs)) return;
        const cur: OpenFile = .{ .path = wb.path, .doc = wb.doc, .view = wb.view, .syntax = wb.syntax };
        const next = for (wb.others.items, 0..) |o, i| {
            if (o.path) |p| if (samePath(wb, p, abs)) break wb.others.swapRemove(i);
        } else try wb.load(abs);
        wb.others.append(wb.gpa, cur) catch |e| {
            wb.closeFile(next);
            return e;
        };
        wb.view.on_change = null;
        wb.setCurrent(next);
        if (wb.win != null) wb.view.on_change = .{ .ctx = wb, .f = onViewChange };
    }

    fn samePath(wb: *Workbench, p: []const u8, abs: []const u8) bool {
        const a = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) catch return false;
        defer wb.gpa.free(a);
        return std.mem.eql(u8, a, abs);
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

    /// Unhooks from the window; call while it still exists.
    pub fn detach(wb: *Workbench) void {
        const w = wb.win orelse return;
        // The panel stops the agent first: its tools may be waiting on
        // this thread or on an approval dialog.
        if (wb.agent_panel) |p| p.destroy();
        wb.agent_panel = null;
        if (wb.agent) |a| a.destroy();
        wb.agent = null;
        if (wb.terminal) |t| t.destroy();
        wb.terminal = null;
        wb.approvals.deinit();
        wb.palette.handle.close(w);
        wb.adapter.deinit();
        wb.palette.deinit();
        wb.view.on_change = null;
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
        wb.diags.deinit();
        wb.keys.deinit();
        wb.closeFile(.{ .path = wb.path, .doc = wb.doc, .view = wb.view, .syntax = wb.syntax });
        for (wb.others.items) |f| wb.closeFile(f);
        wb.others.deinit(wb.gpa);
        if (wb.pending_open) |p| wb.gpa.free(p);
        wb.crumbs.deinit();
        wb.docs.deinit();
        wb.langs.deinit(wb.gpa);
        wb.gpa.free(wb.cwd);
    }

    /// Hooks the keymap and the palette into `win` and focuses the editor.
    pub fn attach(wb: *Workbench, win: *Window) !void {
        wb.win = win;
        wb.adapter = .init(wb.gpa, wb.reg, wb.resolver, win);
        wb.adapter.install();
        wb.adapter.on_status = .{ .ctx = wb, .f = onStatus };
        wb.palette = .init(wb.gpa, wb.reg, &wb.adapter);
        try wb.palette.registerCommands();
        wb.view.on_change = .{ .ctx = wb, .f = onViewChange };
        wb.approvals = .init(wb.gpa, wb.io, win);
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
        if (wb.show_terminal) {
            wb.show_terminal = false;
            if (!wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
            return;
        }
        if (wb.terminal == null) {
            const t = try TerminalPanel.create(wb.gpa, wb.io, w.app, wb.env);
            t.on_output = .{ .ctx = wb, .f = onTerminalOutput };
            wb.terminal = t;
            t.start();
        }
        wb.show_terminal = true;
        wb.focus_terminal = true;
        w.markAllDirty();
        w.afterNextFrame(.{ .ctx = wb, .f = focusTerminal });
    }

    /// Shows the agent pane (starting the agent) and focuses its prompt,
    /// or hides it and focuses the editor.
    pub fn toggleAgent(wb: *Workbench) !void {
        const w = wb.win orelse return;
        if (wb.show_agent) {
            wb.show_agent = false;
            if (!wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
            return;
        }
        if (wb.agent_panel == null) {
            const host = try AgentHost.create(wb.rt, wb.env, w.app, &wb.docs, wb.approvals.port());
            errdefer host.destroy();
            host.files.on_edit = .{ .ctx = wb, .f = onAgentEdit };
            const p = try AgentPanel.create(wb.gpa, wb.io, w.app, host.agent);
            p.on_change = .{ .ctx = wb, .f = onTerminalOutput };
            wb.agent = host;
            wb.agent_panel = p;
        }
        wb.show_agent = true;
        wb.focus_agent = true;
        w.markAllDirty();
        w.afterNextFrame(.{ .ctx = wb, .f = focusAgent });
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
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .dir = .column, .bg = .{ .token = .bg_base } } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .grow = 1, .basis = .{ .px = 0 } } });
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } } });
        wb.header(ui);
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "editorFocus editorTextFocus" });
        _ = zg_editor.view.editor(ui, .{ .view = wb.view, .a11y_label = wb.path orelse "Untitled" });
        wb.editor_node = ui.lastNode();
        ui.close();
        ui.close();
        if (wb.show_agent) if (wb.agent_panel) |p| {
            ui.open(.{ .style = .{ .dir = .column, .h = .{ .pct = 100 }, .shrink = 0 }, .key_context = "agentPaneFocus" });
            p.build(ui);
            ui.close();
        };
        ui.close();
        wb.terminal_node = .none;
        if (wb.show_terminal) if (wb.terminal) |t| wb.terminalPanel(ui, t);
        // Focus the editor once it exists.
        if (!wb.focused) {
            wb.focused = true;
            ui.win.afterNextFrame(.{ .ctx = wb, .f = focusEditor });
        }
        wb.statusBar(ui);
    }

    /// The editor's header: breadcrumbs for the file, the toolbar.
    fn header(wb: *Workbench, ui: *Ui) void {
        const w = ui.window();
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .padding = .xy(6, 0), .h = .{ .px = 28 }, .shrink = 0, .bg = .{ .token = .bg_elevated } } });
        defer ui.close();
        const pane_w: f32 = if (wb.show_agent and wb.agent_panel != null) 380 else 0;
        const avail = @max(0, w.size.w - pane_w - 12);
        const crumbs = wb.crumbs.items();
        const untitled = [_]zg_gui.w.Crumb{.{ .label = "Untitled" }};
        const cb: zg_gui.w.menu.ActionCb = .{ .ctx = wb, .f = onChromeAction };
        zg_gui.w.breadcrumbs(ui, if (crumbs.len > 0) crumbs else &untitled, .{ .width = avail * 0.6, .on_action = cb });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        const tools = [_]zg_gui.w.ToolItem{
            .{ .id = "save", .label = "Save", .tooltip = "Save (Ctrl+S)", .action = "file.save", .priority = 1000, .enabled = wb.path != null },
            .{ .id = "terminal", .label = "Terminal", .tooltip = "Toggle Terminal (Ctrl+`)", .action = "terminal.toggle", .toggled = wb.show_terminal, .priority = 10 },
            .{ .id = "agent", .label = "Agent", .tooltip = "Toggle Agent Pane (Ctrl+L)", .action = "agent.togglePane", .toggled = wb.show_agent, .priority = 20 },
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
        ui.open(.{ .style = .{ .dir = .column, .h = .{ .pct = 38 }, .shrink = 0, .bg = .{ .token = .bg_elevated } } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .gap = 12, .padding = .xy(10, 3), .shrink = 0 } });
        ui.text("TERMINAL", .{ .color = .fg_muted, .wrap = false });
        const title = t.term.title.items;
        if (title.len > 0) ui.text(title, .{ .color = .fg_muted, .wrap = false });
        if (t.noteText().len > 0) ui.text(t.noteText(), .{ .color = .warning, .wrap = false });
        ui.close();
        _ = zg_terminal_view.terminal(ui, .{ .view = &t.view, .a11y_label = "Terminal" });
        wb.terminal_node = t.view.node;
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
