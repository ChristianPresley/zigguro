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
//! `editor.selectAll`, `workbench.toggleTheme` and
//! `workbench.floatingAlwaysOnTop`.
//!
//! The document lives in an E05 `DocumentRegistry`, so the agent pane's
//! file tools read and edit it through the editor (agent/editor_files.zig)
//! and their approvals go to the approvals inbox at the top of the review
//! queue (agent/approvals.zig, review/approvals_view.zig).
//!
//! Workspace trust is asked per session until the trust store
//! (E16.F07.S01.T01) persists it; the status line shows Restricted Mode.
//! `approvals` is E12's `ApprovalBroker`, the ApprovalPort for consumers
//! (agents, MCP): a request shows the review queue with its card, and
//! while the window is unfocused a toast;
//! `mcp_input` asks the user when an MCP server needs input mid-call.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_config = @import("zg_config");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const zg_terminal = @import("zg_terminal");
const zg_terminal_view = @import("zg_terminal_view");
const zg_security = @import("zg_security");
const zg_security_ui = @import("zg_security_ui");
const zg_review = @import("zg_review");
const zg_codeintel = @import("zg_codeintel");
const TerminalPanel = @import("terminal_panel.zig").TerminalPanel;
const term_persist = zg_terminal.session.persist;
const TerminalId = zg_terminal_view.panel_model.TerminalId;
const AgentHost = @import("agent/host.zig").AgentHost;
const PendingEdits = @import("agent/pending_edits.zig").PendingEdits;
const AgentPanel = @import("agent/panel.zig").AgentPanel;
const AgentCommands = @import("agent/commands.zig").AgentCommands;
const McpInputDialogs = @import("agent/mcp_input.zig").McpInputDialogs;
const QueuePanel = @import("review/queue_panel.zig").QueuePanel;
const ApprovalsInbox = @import("review/approvals_view.zig").ApprovalsInbox;
const PaneApprovals = @import("agent/pane_approvals.zig").PaneApprovals;
const file_sync = @import("file_sync.zig");
const FileSync = file_sync.FileSync;
const diff_model = zg_editor.model.diff.diff_model;
const scm_base = @import("scm_base.zig");
const ReviewView = @import("review/review_view.zig").ReviewView;
const path_crumbs = @import("path_crumbs.zig");
const completions = @import("review/completions.zig");
const inline_edit_bar = @import("review/inline_edit_bar.zig");
const InlineEditHost = @import("review/inline_edit_host.zig").InlineEditHost;
const CodeIntel = @import("codeintel.zig").CodeIntel;
const InlineInfo = @import("lens_ui.zig").InlineInfo;
const FileOpHooks = @import("codeintel.zig").FileOpHooks;
const NavService = @import("codeintel.zig").NavService;
const settings_mod = @import("settings/service.zig");
const Settings = settings_mod.Settings;
const SettingsView = @import("settings/view.zig").SettingsView;
const ExplorerPanel = @import("explorer/panel.zig").ExplorerPanel;
const ExplorerFileOp = @import("explorer/panel.zig").FileOp;
const problems_panel = @import("problems_panel.zig");
const ProblemsPanel = problems_panel.ProblemsPanel;
const HierarchyPanel = @import("hierarchy_panel.zig").HierarchyPanel;
const doc_links = @import("doc_links.zig");
const HierarchyService = @import("codeintel.zig").HierarchyService;
const NotesService = @import("notes/service.zig").NotesService;
const zg_notes_ui = @import("zg_notes_ui");
const ReviewGlue = @import("agent/review_glue.zig").ReviewGlue;
const WorkspaceTools = @import("agent/workspace_tools.zig").WorkspaceTools;
const scm_panel = @import("scm/panel.zig");
const ScmPanel = scm_panel.ScmPanel;
const fs_tree = @import("explorer/fs_tree.zig");

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
    /// The window had focus at the last build (a regain checks files).
    was_focused: bool = false,
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
    /// The completion provider, while attached to a window.
    completions_svc: ?*completions.Service = null,
    /// The inline edit bar (Ctrl+K Ctrl+I), while open.
    inline_edit: ?*InlineEditHost = null,
    /// Its earlier instructions (created with the first bar).
    inline_history: ?inline_edit_bar.History = null,
    /// A file to switch to at the next build (from a breadcrumb dropdown).
    pending_open: ?[]u8 = null,
    /// The working folder (absolute).
    cwd: [:0]u8 = undefined,
    crumbs: path_crumbs.PathCrumbs,
    keys: zg_config.context.ContextKeyService,
    reg: *registry.CommandRegistry,
    diags: zg_config.diag.Diags,
    keymap_docs: std.ArrayList(zg_config.zon_load.Doc) = .empty,
    /// The app's own bindings (keybindings.zon), under the preset.
    app_keys: ?zg_config.zon_load.Doc = null,
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
    /// The terminals by id (the first one is created on first show), and
    /// their tabs and split groups (E06.F07).
    terminals: std.AutoArrayHashMapUnmanaged(TerminalId, *TerminalPanel) = .empty,
    term_tabs: zg_terminal_view.PanelModel = undefined,
    next_terminal: TerminalId = 1,
    /// The terminals saved when the folder was last closed were looked
    /// for (restored by the first `startTerminal`); until then closing
    /// keeps the saved file as it is.
    terminals_loaded: bool = false,
    /// A tab strip button clicked during the build; runs after the frame.
    term_click: ?TermClick = null,
    /// The active terminal's node.
    terminal_node: zg_gui.core.NodeId = .none,
    /// Focus the terminal once it is in the tree.
    focus_terminal: bool = false,
    /// This session's trust in the working folder (until the trust store).
    trust: zg_security.contracts.TrustState = .unknown,
    approvals: zg_review.approvals.ApprovalBroker = undefined,
    /// The approvals section of the review queue (from `attach`).
    approvals_inbox: ?*ApprovalsInbox = null,
    /// Asks the user when an MCP server needs input during a call (from
    /// `attach`).
    mcp_input: McpInputDialogs = undefined,
    /// Created on first show, with the panel.
    agent: ?*AgentHost = null,
    agent_panel: ?*AgentPanel = null,
    /// Agent edits waiting in their editors (inline review; with the
    /// agent).
    pending_edits: ?*PendingEdits = null,
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
    /// Editors' keys: Vim (`editor.toggleVim`), Emacs
    /// (`editor.toggleEmacs`) or neither.
    key_mode: KeyMode = .standard,
    /// Registers, file marks, the last search and `:set` options every
    /// editor's Vim state shares (created with the first one).
    vim_shared: ?*zg_editor.modes.vim.state.Shared = null,
    /// The Emacs keymap layer while Emacs keys are on.
    emacs_layer: ?zg_config.zon_load.Doc = null,
    /// `:w`, `:q`, `C-x` chords and the like, run after the key that sent
    /// them (the editor that sent `:q` is still handling it).
    mode_queue: std.ArrayList(ModeAction) = .empty,
    mode_posted: bool = false,
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
    /// Where files' undo histories persist (`enableUndoFiles`).
    undo_dir: ?std.Io.Dir = null,
    /// Language servers and semantic colours (from `attach`).
    codeintel: ?*CodeIntel = null,
    /// The user and workspace settings.json (`useSettings`).
    settings: ?*Settings = null,
    /// The settings editor tab, while open.
    settings_view: ?*SettingsView = null,
    settings_ref: ?PanelRef = null,
    /// Polls the settings and keybindings files (live reload).
    settings_timer: Window.TimerId = .none,
    /// The user's keybindings.json, its stamp and parsed layer.
    keys_path: ?[]u8 = null,
    keys_stamp: ?KeysStamp = null,
    keys_doc: ?zg_config.zon_load.Doc = null,
    /// Saves dirty files with `files.autoSave` = afterDelay.
    autosave_timer: Window.TimerId = .none,
    /// Saves the workbench started without asking (no toast for them).
    quiet_saves: std.ArrayList(*FileSync) = .empty,
    /// The file browser (created on first show) and its dock panel.
    explorer: ?*ExplorerPanel = null,
    explorer_ref: ?PanelRef = null,
    /// `pending_open` moves focus to the editor (false: a click in the
    /// explorer keeps it there).
    pending_focus: bool = true,
    /// `pending_open` came from the explorer (`openFromExplorer`).
    pending_explorer: bool = false,
    /// `pending_open` is a language server's URI for a virtual document.
    pending_virtual: bool = false,
    /// The editor the explorer last revealed (`explorer.autoReveal`).
    revealed_panel: ?PanelRef = null,
    /// The Problems panel (created on first show) and its dock panel.
    problems: ?*ProblemsPanel = null,
    problems_ref: ?PanelRef = null,
    /// Call and type hierarchies.
    hierarchy: ?*HierarchyPanel = null,
    hierarchy_ref: ?PanelRef = null,
    /// What the last Show ... Hierarchy asked, for Refresh.
    hierarchy_ask: ?struct { h: zg_editor.model.api.registry.DocHandle, offset: u64 } = null,
    /// Where `pending_open` puts the caret.
    pending_goto: ?Goto = null,
    /// The message of the problem next/previous problem went to, shown
    /// in the status line until the caret leaves it.
    problem_note: std.ArrayList(u8) = .empty,
    problem_note_at: u64 = 0,
    problems_badge: [16]u8 = undefined,
    /// The folder's notes (made on first use) and their dock panels.
    notes: ?*NotesService = null,
    notes_ref: ?PanelRef = null,
    notes_search_ref: ?PanelRef = null,
    /// The bytes `pending_open` selects (a note link or search hit).
    pending_range: ?[2]u32 = null,
    /// The agent's workspace tools (made with the agent; outlive it).
    ws_tools: ?*WorkspaceTools = null,
    /// Back and forward through the places navigation jumped between.
    nav_history: ?NavService.History = null,
    /// The targets the last navigation offered, and their QuickPick rows.
    nav_arena: ?std.heap.ArenaAllocator = null,
    nav_targets: []NavService.Target = &.{},
    nav_items: []zg_gui.w.quick_pick.QpItem = &.{},
    nav_pick: zg_gui.w.quick_pick.QuickPickHandle = .{},
    nav_title: []const u8 = "",
    /// The Git tab (created on first show) and its dock panel.
    scm: ?*ScmPanel = null,
    scm_ref: ?PanelRef = null,
    scm_badge: [12]u8 = undefined,
    /// When `git.autofetch` last fetched.
    scm_fetch_ms: u64 = 0,

    const KeysStamp = struct { size: u64, mtime: i96, missing: bool };

    /// Where a file opened by `pending_open` puts the caret.
    const Goto = union(enum) {
        /// A problem's start.
        problem: problems_panel.Problems.Item,
        /// A language server position (line, column in `enc`).
        pos: struct { line: u32, character: u32, enc: @FieldType(NavService.Target, "enc") },
        /// A byte offset (clamped).
        offset: u64,
    };

    /// Which keys editors use.
    const KeyMode = enum { standard, vim, emacs };

    /// One open file and its dock panel; the current one is mirrored in
    /// the fields above.
    const OpenFile = struct {
        path: ?[]u8,
        doc: *Document,
        view: *EditorView,
        syntax: ?*DocumentSyntax,
        /// The document in `docs`, for files with a path.
        handle: ?zg_editor.model.api.registry.DocHandle = null,
        /// The document's file on disk (null: untitled).
        sync: ?*FileSync = null,
        /// The editor's Vim state while Vim keys are on.
        vim_state: ?*zg_editor.modes.VimState = null,
        /// The editor's Emacs state while Emacs keys are on.
        emacs_state: ?*zg_editor.modes.EmacsState = null,
        /// The document against the file's text, for the gutter's SCM
        /// bar (null: not read from disk).
        diff: ?*diff_model.DiffModel = null,
        /// Ghost-text completions while a window shows the editor.
        completions: ?*completions.EditorCompletions = null,
        /// The decorations the editor draws (ghost text, the inline edit
        /// bar's rows), once something needs them.
        deco: ?*zg_editor.model.decorations.store.DecorationStore = null,
        deco_listener: zg_editor.model.document.ListenerId = undefined,
        panel: PanelRef = undefined,
        /// The editor widget (last build).
        node: zg_gui.core.NodeId = .none,
        /// The document version autosave last saw (it saves once a dirty
        /// file stays unchanged for a delay).
        autosave_seen: u64 = 0,
        /// The version a quiet save failed at (no retry until it changes).
        autosave_failed: u64 = std.math.maxInt(u64),
        /// Opened with one click in the explorer, at this document
        /// version: the next such click replaces the tab while the file
        /// stays unedited (a preview, as in VS Code).
        preview: ?u64 = null,
        /// A virtual document (read-only, from a language server), with
        /// the workbench's own reference.
        virtual: ?zg_editor.model.api.registry.DocHandle = null,
        /// Where the caret goes once the virtual document's text arrives.
        virtual_goto: ?Goto = null,
    };

    /// Dock panel kinds.
    const kind_editor: zg_gui.dock.model.PanelKindId = 1;
    const kind_terminal: zg_gui.dock.model.PanelKindId = 2;
    const kind_agent: zg_gui.dock.model.PanelKindId = 3;
    const kind_review: zg_gui.dock.model.PanelKindId = 4;
    const kind_review_view: zg_gui.dock.model.PanelKindId = 5;
    const kind_settings: zg_gui.dock.model.PanelKindId = 6;
    const kind_explorer: zg_gui.dock.model.PanelKindId = 7;
    const kind_problems: zg_gui.dock.model.PanelKindId = 8;
    const kind_notes: zg_gui.dock.model.PanelKindId = 9;
    const kind_notes_search: zg_gui.dock.model.PanelKindId = 10;
    const kind_scm: zg_gui.dock.model.PanelKindId = 11;
    const kind_hierarchy: zg_gui.dock.model.PanelKindId = 12;
    /// The kinds' names in the saved layout (index = kind - 1).
    const kind_names = [_][]const u8{ "editor", "terminal", "agent", "review", "review.view", "settings", "explorer", "problems", "notes", "notes.search", "scm", "hierarchy" };

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
            .term_tabs = .init(gpa),
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
        var loaded: ?zg_editor.model.buffer.external.Loaded = null;
        if (path) |p| {
            f.path = try gpa.dupe(u8, p);
            // Decoded (encoding, BOM and line ends detected); a missing
            // file opens empty.
            if (zg_editor.model.buffer.external.load(gpa, wb.io, std.Io.Dir.cwd(), p, null, .utf8)) |l| {
                loaded = l;
                bytes = l.text;
            } else |e| switch (e) {
                error.FileNotFound => bytes = try gpa.alloc(u8, 0),
                else => return e,
            }
        }
        const h = if (f.path) |p| blk: {
            const abs = try std.fs.path.resolve(gpa, &.{ wb.cwd, p });
            defer gpa.free(abs);
            break :blk try wb.docs.openFile(abs, bytes);
        } else try wb.docs.openUntitled(bytes);
        f.doc = wb.docs.get(h).?;
        if (f.path != null) f.handle = h;
        f.view = try EditorView.init(gpa, f.doc, wb.editorOptions(null));
        errdefer f.view.deinit();
        wb.setMode(&f, wb.key_mode);
        errdefer wb.setMode(&f, .standard);
        if (f.path) |p| {
            const sync = try FileSync.init(gpa, wb.io, if (wb.win) |w| w.app else null, f.doc, &f.view.undo, std.Io.Dir.cwd(), p, if (loaded) |l| .{ .encoding = l.encoding, .eol = l.eol.style, .disk = l.disk } else .{});
            sync.on_done = .{ .ctx = wb, .f = onFileSync };
            f.sync = sync;
            if (loaded != null) {
                wb.persistUndo(sync, p, bytes);
                if (diff_model.DiffModel.init(gpa, wb.rt, f.doc.snapshot(), f.doc, .{})) |m| {
                    f.diff = m;
                    sync.diff = m;
                    f.view.scm = .of(m);
                    wb.diffAgainstHead(sync, m, p, loaded.?.encoding, loaded.?.eol.style);
                } else |e| log.warn("diff of {s}: {t}", .{ p, e });
            }
        }
        errdefer if (f.diff) |m| m.deinit();
        errdefer if (f.sync) |x| x.destroy();
        if (wb.langs.detect(f.path, bytes[0..@min(bytes.len, 256)])) |id| if (wb.langs.get(id)) |lang| {
            const sx = try gpa.create(DocumentSyntax);
            errdefer gpa.destroy(sx);
            sx.* = try DocumentSyntax.init(gpa, lang, &wb.langs, &f.doc.tree, f.doc.version);
            f.syntax = sx;
            f.view.syntax = sx;
            f.view.opts = wb.editorOptions(lang.name);
        };
        if (wb.codeintel) |ci| if (f.handle) |fh| ci.open(fh, f.syntax, f.view, if (f.syntax != null) wb.ensureDeco(&f) catch null else null);
        return f;
    }

    /// In a git working tree, the change bars compare with the file at
    /// `HEAD` instead of the text on disk.
    fn diffAgainstHead(wb: *Workbench, sync: *FileSync, m: *diff_model.DiffModel, path: []const u8, encoding: zg_editor.model.encoding.Encoding, eol: zg_editor.model.buffer.eol.Eol) void {
        const gpa = wb.gpa;
        const abs = std.fs.path.resolve(gpa, &.{ wb.cwd, path }) catch return;
        defer gpa.free(abs);
        sync.head_commit = scm_base.headCommit(gpa, wb.io, abs) catch null;
        const text = scm_base.headText(gpa, wb.io, abs, encoding, eol) catch |e| {
            log.warn("HEAD version of {s}: {t}", .{ path, e });
            return;
        } orelse return;
        defer gpa.free(text);
        const base = Document.initBytes(gpa, @enumFromInt(0), text) catch return;
        defer base.deinit();
        m.setBase(base.snapshot()) catch |e| {
            log.warn("HEAD diff of {s}: {t}", .{ path, e });
            return;
        };
        sync.diff_head = true;
    }

    fn closeFile(wb: *Workbench, f: OpenFile) void {
        if (wb.inline_edit) |h| if (h.view == f.view) {
            h.destroy();
            wb.inline_edit = null;
        };
        if (wb.pending_edits) |pe| pe.dropView(f.view);
        if (f.completions) |c| c.detach();
        // Before the decoration store goes (diagnostics draw there).
        if (wb.codeintel) |ci| if (f.handle) |h| ci.close(h);
        if (f.deco) |d| {
            f.doc.unsubscribe(f.deco_listener);
            f.view.decorations = null;
            d.deinit();
            wb.gpa.destroy(d);
        }
        var fm = f;
        wb.setMode(&fm, .standard);
        if (f.sync) |x| x.destroy();
        if (f.diff) |m| m.deinit();
        f.view.deinit();
        if (f.syntax) |sx| {
            sx.deinit();
            wb.gpa.destroy(sx);
        }
        if (f.path) |p| wb.gpa.free(p);
        if (f.virtual) |vh| {
            if (wb.codeintel) |ci| ci.virtual.release(vh);
            wb.docs.release(vh);
        }
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
        if (wb.notes) |n| n.setActive(abs);
    }

    /// Keeps `f` and opens it as a tab in the focused center group.
    fn addFile(wb: *Workbench, f: OpenFile) !*OpenFile {
        errdefer wb.closeFile(f);
        try wb.files.append(wb.gpa, f);
        const nf = &wb.files.items[wb.files.items.len - 1];
        nf.panel = try wb.addEditorPanel(nf.*);
        try wb.showEditor(nf);
        if (wb.win != null) {
            nf.view.on_change = .{ .ctx = wb, .f = onViewChange };
            nf.view.on_caret = .{ .ctx = wb, .f = onViewChange };
            wb.attachCompletions(nf);
        }
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
        // The empty buffer a folder opens with gives way to the first file.
        if (wb.files.items.len == 2) {
            const u = &wb.files.items[0];
            if (u.path == null and !u.doc.isDirty() and u.doc.len() == 0) wb.closeFileAt(0);
        }
    }

    /// Opens `abs` for the explorer: one click (`focus` false) opens a
    /// preview that the next click replaces; Enter or a double click
    /// keeps the tab.
    fn openFromExplorer(wb: *Workbench, abs: []const u8, focus: bool) !void {
        const was_open = for (wb.files.items) |f| {
            if (f.path) |p| if (wb.samePath(p, abs)) break true;
        } else false;
        try wb.openFile(abs);
        const cp = wb.cur_panel orelse return;
        const cur = wb.fileOf(cp) orelse return;
        if (focus) {
            cur.preview = null;
            return;
        }
        if (was_open) return;
        cur.preview = cur.doc.version;
        const keep = cur.panel;
        var i: usize = 0;
        while (i < wb.files.items.len) {
            const f = &wb.files.items[i];
            if (f.panel != keep and f.preview != null and f.preview.? == f.doc.version and !f.doc.isDirty()) {
                wb.closeFileAt(i);
                continue;
            }
            i += 1;
        }
        if (wb.fileOf(keep)) |k| wb.setCurrent(k.*);
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
        wb.pending_virtual = false;
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

    /// Keeps open files' undo histories in `<state_dir>/undo` across
    /// sessions (`undo_file`): written on save, restored on open while the
    /// file is unchanged. Call before `loadLayout`, so the files it opens
    /// get theirs back too.
    pub fn enableUndoFiles(wb: *Workbench, state_dir: []const u8) void {
        const sub = std.fs.path.join(wb.gpa, &.{ state_dir, "undo" }) catch return;
        defer wb.gpa.free(sub);
        wb.undo_dir = std.Io.Dir.cwd().createDirPathOpen(wb.io, sub, .{}) catch |e| {
            log.warn("undo folder {s}: {t}", .{ sub, e });
            return;
        };
        // `init` opened a file already: unedited, it can take its history.
        for (wb.files.items) |f| if (f.sync) |fs| if (f.path) |p| if (!f.view.undo.canUndo()) {
            const text = f.doc.tree.copyRange(wb.gpa, .{ .start = 0, .end = f.doc.len() }) catch continue;
            defer wb.gpa.free(text);
            wb.persistUndo(fs, p, text);
        };
    }

    /// Hands `fs` (the file at `path`, just read as `text`) the undo
    /// folder.
    fn persistUndo(wb: *Workbench, fs: *FileSync, path: []const u8, text: []const u8) void {
        const dir = wb.undo_dir orelse return;
        const abs = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, path }) catch return;
        defer wb.gpa.free(abs);
        _ = fs.enableUndoFile(dir, abs, text);
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
                kind_settings => wb.settings_ref = p,
                kind_explorer => wb.explorer_ref = p,
                kind_problems => wb.problems_ref = p,
                kind_notes => wb.notes_ref = p,
                kind_notes_search => wb.notes_search_ref = p,
                kind_scm => wb.scm_ref = p,
                kind_hierarchy => wb.hierarchy_ref = p,
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
        if (wb.win) |w| {
            // The size the window opens at next time: without the
            // invisible resize margins of client-side decorations (or
            // each session grows by them).
            const m = w.chrome.margins(w.scale);
            windows[0].rect = .{ 0, 0, @intFromFloat(@round(@max(0, w.size.w - m.l - m.r))), @intFromFloat(@round(@max(0, w.size.h - m.t - m.b))) };
        }
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
        wb.saveTerminals();
        if (wb.persister) |*p| p.deinit();
        wb.persister = null;
        // Floating panels come home before their windows close.
        if (wb.floater) |*fl| fl.closeAll();
        // The inline edit bar edits through the agent's files.
        if (wb.inline_edit) |h| h.destroy();
        wb.inline_edit = null;
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
        if (wb.settings_timer != .none) w.cancelTimer(wb.settings_timer);
        wb.settings_timer = .none;
        if (wb.autosave_timer != .none) w.cancelTimer(wb.autosave_timer);
        wb.autosave_timer = .none;
        if (wb.review_panel) |p| p.destroy();
        wb.review_panel = null;
        // Waits for running git commands.
        if (wb.scm) |p| p.destroy();
        wb.scm = null;
        if (wb.agent_cmds) |c| c.target = null;
        if (wb.agent) |a| a.destroy();
        wb.agent = null;
        // After the agent (its file tools place changes here), before the
        // editors the changes draw in.
        if (wb.pending_edits) |pe| {
            pe.deinit();
            wb.gpa.destroy(pe);
        }
        wb.pending_edits = null;
        for (wb.terminals.values()) |t| t.destroy();
        wb.terminals.deinit(wb.gpa);
        wb.term_tabs.deinit();
        if (wb.approvals_inbox) |i| i.destroy();
        wb.approvals_inbox = null;
        wb.approvals.deinit();
        wb.mcp_input.deinit();
        wb.palette.handle.close(w);
        wb.adapter.deinit();
        wb.palette.deinit();
        for (wb.files.items) |*f| {
            f.view.on_change = null;
            f.view.on_caret = null;
            if (f.completions) |c| c.detach();
            f.completions = null;
        }
        if (wb.completions_svc) |svc| svc.destroy();
        wb.completions_svc = null;
        if (w.app.on_message) |h| if (h.ctx == @as(*anyopaque, wb)) {
            w.app.on_message = null;
        };
        wb.win = null;
    }

    /// Frees everything (after `detach`).
    pub fn deinit(wb: *Workbench) void {
        wb.detach();
        // Before language services: it holds a diagnostics snapshot.
        if (wb.problems) |pp| {
            pp.deinit();
            wb.gpa.destroy(pp);
        }
        wb.problems = null;
        if (wb.hierarchy) |hp| {
            hp.deinit();
            wb.gpa.destroy(hp);
        }
        wb.hierarchy = null;
        wb.problem_note.deinit(wb.gpa);
        if (wb.notes) |n| n.destroy();
        wb.notes = null;
        if (wb.ws_tools) |x| x.destroy();
        wb.ws_tools = null;
        if (wb.win) |w| wb.nav_pick.close(w);
        if (wb.nav_history) |*h| h.deinit();
        if (wb.nav_arena) |*a| a.deinit();
        // Before the documents: the servers' text sync listens to them.
        if (wb.codeintel) |ci| ci.destroy();
        wb.codeintel = null;
        wb.resolver.deinit();
        if (wb.keymap) |k| k.deinit();
        if (wb.emacs_layer) |*d| d.deinit();
        for (wb.mode_queue.items) |q| if (q == .run) if (q.run.text) |t| wb.gpa.free(t);
        wb.mode_queue.deinit(wb.gpa);
        for (wb.keymap_docs.items) |*d| d.deinit();
        wb.keymap_docs.deinit(wb.gpa);
        if (wb.app_keys) |*d| d.deinit();
        wb.reg.deinit();
        // After the registry: its palette handlers point into it.
        if (wb.agent_cmds) |c| c.deinit();
        wb.diags.deinit();
        if (wb.inline_history) |*h| h.deinit();
        wb.keys.deinit();
        for (wb.files.items) |f| wb.closeFile(f);
        wb.files.deinit(wb.gpa);
        if (wb.vim_shared) |sh| {
            sh.deinit();
            wb.gpa.destroy(sh);
        }
        if (wb.floater) |*fl| fl.deinit();
        wb.dv.deinit();
        wb.dock.deinit();
        if (wb.pending_open) |p| wb.gpa.free(p);
        wb.crumbs.deinit();
        wb.docs.deinit();
        wb.langs.deinit(wb.gpa);
        wb.gpa.free(wb.cwd);
        if (wb.layout_dir) |d| d.close(wb.io);
        if (wb.undo_dir) |d| d.close(wb.io);
        if (wb.settings_view) |v| v.destroy();
        if (wb.explorer) |e| {
            e.deinit();
            wb.gpa.destroy(e);
        }
        if (wb.settings) |st| st.destroy();
        if (wb.keys_doc) |*d| d.deinit();
        if (wb.keys_path) |p| wb.gpa.free(p);
        wb.quiet_saves.deinit(wb.gpa);
    }

    /// Hooks the keymap and the palette into `win` and focuses the editor.
    pub fn attach(wb: *Workbench, win: *Window) !void {
        wb.win = win;
        for (wb.files.items) |f| if (f.sync) |x| {
            x.app = win.app;
        };
        wb.adapter = .init(wb.gpa, wb.reg, wb.resolver, win);
        wb.adapter.install();
        wb.adapter.on_status = .{ .ctx = wb, .f = onStatus };
        wb.palette = .init(wb.gpa, wb.reg, &wb.adapter);
        try wb.palette.registerCommands();
        for (wb.files.items) |f| {
            f.view.on_change = .{ .ctx = wb, .f = onViewChange };
            f.view.on_caret = .{ .ctx = wb, .f = onViewChange };
        }
        wb.completions_svc = completions.Service.create(wb.rt, wb.env, win.app) catch |e| blk: {
            log.err("completions: {t}", .{e});
            break :blk null;
        };
        for (wb.files.items) |*f| wb.attachCompletions(f);
        wb.approvals = .init(wb.gpa, wb.io, .{});
        if (ApprovalsInbox.create(wb.gpa, wb.io, win.app, &wb.approvals)) |inb| {
            inb.win = win;
            inb.on_change = .{ .ctx = wb, .f = onTerminalOutput };
            inb.on_pending = .{ .ctx = wb, .f = onApprovalPending };
            wb.approvals_inbox = inb;
        } else |e| log.err("approvals inbox: {t}", .{e});
        wb.mcp_input = .init(wb.gpa, wb.io, win, wb.cwd);
        if (CodeIntel.create(wb.rt, wb.env, win.app, &wb.docs, wb.cwd)) |ci| {
            ci.win = win;
            ci.nav_hook = .{ .ctx = wb, .done = onNavDone };
            ci.popup_hook = .{ .ctx = wb, .f = onCompletionPopup };
            ci.refactor.notice = .{ .ctx = wb, .f = onRefactorNotice };
            ci.prefs = .{ .ctx = wb, .options = formatOptionsOf, .format_on_type = formatOnTypeOf };
            ci.pickers.host = .{ .ctx = wb, .here = symbolHere, .to = symbolTo, .notice = symbolNotice };
            ci.inline_info.on_action = .{ .ctx = wb, .f = onLensAction };
            ci.popup.on_link = .{ .ctx = wb, .f = onHoverLink };
            ci.link_hook = .{ .ctx = wb, .open = onDocLink };
            wb.codeintel = ci;
            for (wb.files.items) |*f| if (f.handle) |h| ci.open(h, f.syntax, f.view, if (f.syntax != null) wb.ensureDeco(f) catch null else null);
            ci.setTrusted(wb.trust == .trusted);
        } else |e| log.err("language services: {t}", .{e});
        if (win.app.on_message == null) win.app.on_message = .{ .ctx = wb, .f = onAppMessage };
        win.on_close = .{ .ctx = wb, .f = onMainClose };
        if (wb.layout_dir) |dir| {
            wb.persister = .{ .gpa = wb.gpa, .io = wb.io, .app = win.app, .dir = dir, .source = .{ .ctx = wb, .snapshot = layoutSnapshot }, .win = win };
            wb.layout_rev = wb.dock.revision;
        }
        // Panels the restored layout shows start now.
        if (wb.inLayout(wb.terminal_ref)) try wb.startTerminal(win);
        if (wb.inLayout(wb.agent_ref)) try wb.startAgent(win);
        if (wb.inLayout(wb.review_ref)) try wb.startReview(win);
        // The explorer shows until the layout has it (hiding it keeps it
        // there, hidden).
        if (wb.explorer_ref == null and wb.startupExplorer()) try wb.showExplorerPanel(false);
        // Settings that need the window: the theme, auto save, live reload.
        wb.applySettings();
        wb.armSettingsPoll(win);
        if (wb.mode_queue.items.len > 0) wb.postModeQueue();
    }

    /// Whether `p` is in a group (docked or floating) of a shown area.
    fn inLayout(wb: *Workbench, p: ?PanelRef) bool {
        const r = p orelse return false;
        if (wb.dock.groupOf(r) == null) return false;
        return wb.areaOf(r) == null or wb.shown(r);
    }

    fn loadKeymap(wb: *Workbench) !void {
        wb.app_keys = try zg_config.zon_load.loadZon(wb.gpa, @embedFile("keybindings.zon"), &wb.diags);
        for (zg_config.presets.presetLayers(.vscode)) |src| {
            try wb.keymap_docs.append(wb.gpa, try zg_config.zon_load.loadZon(wb.gpa, src, &wb.diags));
        }
        try wb.rebuildKeymap();
    }

    /// Builds the keymap from the preset (plus the Emacs layer while Emacs
    /// keys are on) and swaps it in.
    fn rebuildKeymap(wb: *Workbench) !void {
        var inputs: std.ArrayList(zg_config.keymap.LayerInput) = .empty;
        defer inputs.deinit(wb.gpa);
        if (wb.app_keys) |*d| try inputs.append(wb.gpa, .{ .layer = .builtin_default, .doc = d });
        for (wb.keymap_docs.items) |*d| try inputs.append(wb.gpa, .{ .layer = .preset, .doc = d });
        if (wb.key_mode == .emacs) {
            if (wb.emacs_layer == null) wb.emacs_layer = try zg_config.zon_load.loadZon(wb.gpa, zg_editor.modes.emacs.keymap_source, &wb.diags);
            try inputs.append(wb.gpa, .{ .layer = .mode_layer, .doc = &wb.emacs_layer.? });
        }
        // The user's keybindings.json wins over everything.
        if (wb.keys_doc) |*d| try inputs.append(wb.gpa, .{ .layer = .user, .doc = d, .source_path = wb.keys_path });
        const km = try zg_config.keymap.Keymap.build(wb.gpa, inputs.items, wb.reg, &wb.keys, zg_config.keyspec.Platform.of(@import("builtin").os.tag), &wb.diags);
        const old = wb.keymap;
        wb.keymap = km;
        wb.resolver.reload(km);
        if (old) |k| k.deinit();
    }

    const Cmd = struct { id: []const u8, title: []const u8, category: []const u8, run: *const fn (wb: *Workbench) anyerror!void };

    const commands = [_]Cmd{
        .{ .id = "file.save", .title = "Save", .category = "File", .run = save },
        .{ .id = "file.saveOverwrite", .title = "Save, Overwriting Changes on Disk", .category = "File", .run = saveOverwrite },
        .{ .id = "file.revert", .title = "Revert File (Reload from Disk)", .category = "File", .run = revert },
        .{ .id = "terminal.toggle", .title = "Toggle Terminal", .category = "View", .run = toggleTerminal },
        .{ .id = "terminal.focus", .title = "Focus Terminal", .category = "Terminal", .run = focusTerminalCmd },
        .{ .id = "terminal.new", .title = "Create New Terminal", .category = "Terminal", .run = newTerminalCmd },
        .{ .id = "terminal.split", .title = "Split Terminal", .category = "Terminal", .run = splitTerminal },
        .{ .id = "terminal.kill", .title = "Kill the Active Terminal", .category = "Terminal", .run = killTerminal },
        .{ .id = "terminal.killAll", .title = "Kill All Terminals", .category = "Terminal", .run = killAllTerminals },
        .{ .id = "terminal.focusNext", .title = "Focus Next Terminal", .category = "Terminal", .run = focusNextTerminal },
        .{ .id = "terminal.focusPrevious", .title = "Focus Previous Terminal", .category = "Terminal", .run = focusPreviousTerminal },
        .{ .id = "terminal.find", .title = "Find in Terminal", .category = "Terminal", .run = findInTerminal },
        .{ .id = "terminal.scrollToPrevCommand", .title = "Scroll to Previous Command", .category = "Terminal", .run = scrollToPrevCommand },
        .{ .id = "terminal.scrollToNextCommand", .title = "Scroll to Next Command", .category = "Terminal", .run = scrollToNextCommand },
        .{ .id = "terminal.selectPrevOutput", .title = "Select Previous Command Output", .category = "Terminal", .run = selectPrevOutput },
        .{ .id = "terminal.selectNextOutput", .title = "Select Next Command Output", .category = "Terminal", .run = selectNextOutput },
        .{ .id = "terminal.copyLastCommand", .title = "Copy Last Command", .category = "Terminal", .run = copyLastCommand },
        .{ .id = "terminal.copyLastOutput", .title = "Copy Last Command Output", .category = "Terminal", .run = copyLastOutput },
        .{ .id = "terminal.rerunLastCommand", .title = "Run Last Command Again", .category = "Terminal", .run = rerunLastCommand },
        .{ .id = "agent.togglePane", .title = "Toggle Agent Pane", .category = "Agent", .run = toggleAgent },
        .{ .id = "review.queue.toggle", .title = "Toggle Review Queue", .category = "Review", .run = toggleReview },
        .{ .id = "review.approvals.open", .title = "Show Approvals", .category = "Review", .run = showApprovals },
        .{ .id = "workspace.manageTrust", .title = "Manage Workspace Trust", .category = "Workspaces", .run = manageTrust },
        .{ .id = "editor.undo", .title = "Undo", .category = "Edit", .run = undo },
        .{ .id = "editor.redo", .title = "Redo", .category = "Edit", .run = redo },
        .{ .id = "editor.addCursorAbove", .title = "Add Cursor Above", .category = "Selection", .run = addCursorAbove },
        .{ .id = "editor.addCursorBelow", .title = "Add Cursor Below", .category = "Selection", .run = addCursorBelow },
        .{ .id = "editor.selectAll", .title = "Select All", .category = "Selection", .run = selectAll },
        .{ .id = "workbench.toggleTheme", .title = "Toggle Light/Dark Theme", .category = "Preferences", .run = toggleTheme },
        .{ .id = "editor.toggleVim", .title = "Toggle Vim Mode", .category = "Preferences", .run = toggleVim },
        .{ .id = "editor.toggleEmacs", .title = "Toggle Emacs Mode", .category = "Preferences", .run = toggleEmacs },
        .{ .id = "workbench.closeEditor", .title = "Close Editor", .category = "View", .run = closeEditorCmd },
        .{ .id = "workbench.floatingAlwaysOnTop", .title = "Toggle Floating Windows Always on Top", .category = "View", .run = toggleFloatOnTop },
        .{ .id = "agent.inlineEdit", .title = "Edit Selection Inline", .category = "AI", .run = inlineEditStart },
        .{ .id = "agent.toggleInlineReview", .title = "Toggle Inline Review of Agent Edits", .category = "Agent", .run = toggleInlineReview },
        .{ .id = "agent.acceptChange", .title = "Accept Agent Change", .category = "Agent", .run = acceptAgentChange },
        .{ .id = "agent.rejectChange", .title = "Reject Agent Change", .category = "Agent", .run = rejectAgentChange },
        .{ .id = "agent.acceptAllChanges", .title = "Accept All Agent Changes in File", .category = "Agent", .run = acceptAllAgentChanges },
        .{ .id = "agent.rejectAllChanges", .title = "Reject All Agent Changes in File", .category = "Agent", .run = rejectAllAgentChanges },
        .{ .id = "completions.trigger", .title = "Trigger Inline Completion", .category = "AI", .run = completionTrigger },
        .{ .id = "completions.acceptLine", .title = "Accept Next Line of Inline Completion", .category = "AI", .run = completionAcceptLine },
        .{ .id = "completions.dismiss", .title = "Dismiss Inline Completion", .category = "AI", .run = completionDismiss },
        .{ .id = "completions.snooze", .title = "Snooze Inline Completions (5 Minutes)", .category = "AI", .run = completionSnooze },
        .{ .id = "completions.toggle", .title = "Toggle Inline Completions", .category = "AI", .run = completionToggle },
        .{ .id = "workbench.openSettings", .title = "Open Settings", .category = "Preferences", .run = openSettings },
        .{ .id = "workbench.openSettingsFile", .title = "Open User Settings (JSON)", .category = "Preferences", .run = openUserSettingsFile },
        .{ .id = "workbench.openWorkspaceSettingsFile", .title = "Open Workspace Settings (JSON)", .category = "Preferences", .run = openWorkspaceSettingsFile },
        .{ .id = "workbench.openKeybindingsFile", .title = "Open Keyboard Shortcuts (JSON)", .category = "Preferences", .run = openKeybindingsFile },
        .{ .id = "workbench.showExplorer", .title = "Show Explorer", .category = "View", .run = showExplorer },
        .{ .id = "workbench.showProblems", .title = "Show Problems", .category = "View", .run = showProblems },
        .{ .id = "editor.showCallHierarchy", .title = "Show Call Hierarchy", .category = "Go", .run = showCallHierarchy },
        .{ .id = "editor.showOutgoingCalls", .title = "Show Outgoing Calls", .category = "Go", .run = showOutgoingCalls },
        .{ .id = "editor.showTypeHierarchy", .title = "Show Type Hierarchy", .category = "Go", .run = showTypeHierarchy },
        .{ .id = "editor.showSubtypes", .title = "Show Subtypes", .category = "Go", .run = showSubtypes },
        .{ .id = "editor.nextProblem", .title = "Go to Next Problem (Error, Warning, Info)", .category = "Go", .run = nextProblem },
        .{ .id = "editor.previousProblem", .title = "Go to Previous Problem (Error, Warning, Info)", .category = "Go", .run = previousProblem },
        .{ .id = "editor.nextProblemInFile", .title = "Go to Next Problem in File", .category = "Go", .run = nextProblemInFile },
        .{ .id = "editor.previousProblemInFile", .title = "Go to Previous Problem in File", .category = "Go", .run = previousProblemInFile },
        .{ .id = "problems.open", .title = "Go to Problem", .category = "Problems", .run = problemsOpen },
        .{ .id = "editor.showHover", .title = "Show Hover", .category = "Editor", .run = showHover },
        .{ .id = "editor.goToDefinition", .title = "Go to Definition", .category = "Go", .run = goToDefinition },
        .{ .id = "editor.goToDeclaration", .title = "Go to Declaration", .category = "Go", .run = goToDeclaration },
        .{ .id = "editor.goToTypeDefinition", .title = "Go to Type Definition", .category = "Go", .run = goToTypeDefinition },
        .{ .id = "editor.goToImplementation", .title = "Go to Implementations", .category = "Go", .run = goToImplementation },
        .{ .id = "editor.findReferences", .title = "Go to References", .category = "Go", .run = findReferences },
        .{ .id = "editor.rename", .title = "Rename Symbol", .category = "Editor", .run = renameSymbol },
        .{ .id = "editor.quickFix", .title = "Quick Fix...", .category = "Editor", .run = quickFix },
        .{ .id = "editor.formatDocument", .title = "Format Document", .category = "Editor", .run = formatDocument },
        .{ .id = "quickOpen.symbolsInFile", .title = "Go to Symbol in Editor...", .category = "Go", .run = symbolsInFile },
        .{ .id = "quickOpen.symbols", .title = "Go to Symbol in Workspace...", .category = "Go", .run = symbolsInWorkspace },
        .{ .id = "editor.formatSelection", .title = "Format Selection", .category = "Editor", .run = formatSelection },
        .{ .id = "editor.expandSelection", .title = "Expand Selection", .category = "Selection", .run = expandSelection },
        .{ .id = "editor.shrinkSelection", .title = "Shrink Selection", .category = "Selection", .run = shrinkSelection },
        .{ .id = "navigation.back", .title = "Go Back", .category = "Go", .run = navigateBack },
        .{ .id = "navigation.forward", .title = "Go Forward", .category = "Go", .run = navigateForward },
        .{ .id = "problems.copy", .title = "Copy Problem", .category = "Problems", .run = problemsCopy },
        .{ .id = "problems.copyMessage", .title = "Copy Problem Message", .category = "Problems", .run = problemsCopyMessage },
        .{ .id = "notes.showSidebar", .title = "Show Notes Sidebar", .category = "Notes", .run = showNotesSidebar },
        .{ .id = "notes.search", .title = "Search Notes", .category = "Notes", .run = notesSearch },
        .{ .id = "notes.searchSelection", .title = "Search Notes for Selection", .category = "Notes", .run = notesSearchSelection },
        .{ .id = "notes.saveSearch", .title = "Save Note Search", .category = "Notes", .run = notesSaveSearch },
        .{ .id = "notes.followLink", .title = "Follow Link Under Cursor", .category = "Notes", .run = notesFollowLink },
        .{ .id = "workbench.toggleSidebar", .title = "Toggle Primary Side Bar Visibility", .category = "View", .run = toggleSidebar },
        .{ .id = "workbench.showScm", .title = "Show Git", .category = "View", .run = showScm },
        .{ .id = "scm.refresh", .title = "Refresh", .category = "Git", .run = scmRefresh },
        .{ .id = "scm.commit", .title = "Commit", .category = "Git", .run = scmCommit },
        .{ .id = "scm.commitStaged", .title = "Commit Staged", .category = "Git", .run = scmCommit },
        .{ .id = "scm.commitAll", .title = "Commit All", .category = "Git", .run = scmCommitAll },
        .{ .id = "scm.stage", .title = "Stage Current File", .category = "Git", .run = scmStage },
        .{ .id = "scm.unstage", .title = "Unstage Current File", .category = "Git", .run = scmUnstage },
        .{ .id = "scm.checkout", .title = "Checkout to...", .category = "Git", .run = scmCheckout },
        .{ .id = "scm.openChange", .title = "Open Changes", .category = "Git", .run = showScm },
        .{ .id = "scm.fetch", .title = "Fetch", .category = "Git", .run = scmFetch },
        .{ .id = "scm.pull", .title = "Pull", .category = "Git", .run = scmPull },
        .{ .id = "scm.push", .title = "Push", .category = "Git", .run = scmPush },
        .{ .id = "scm.sync", .title = "Sync", .category = "Git", .run = scmSync },
        .{ .id = "explorer.open", .title = "Open", .category = "Explorer", .run = explorerOpen },
        .{ .id = "explorer.newFile", .title = "New File...", .category = "Explorer", .run = explorerNewFile },
        .{ .id = "explorer.newFolder", .title = "New Folder...", .category = "Explorer", .run = explorerNewFolder },
        .{ .id = "explorer.rename", .title = "Rename...", .category = "Explorer", .run = explorerRename },
        .{ .id = "explorer.delete", .title = "Delete", .category = "Explorer", .run = explorerDelete },
        .{ .id = "explorer.copy", .title = "Copy", .category = "Explorer", .run = explorerCopy },
        .{ .id = "explorer.cut", .title = "Cut", .category = "Explorer", .run = explorerCut },
        .{ .id = "explorer.paste", .title = "Paste", .category = "Explorer", .run = explorerPaste },
        .{ .id = "explorer.copyPath", .title = "Copy Path", .category = "Explorer", .run = explorerCopyPath },
        .{ .id = "explorer.copyRelativePath", .title = "Copy Relative Path", .category = "Explorer", .run = explorerCopyRelativePath },
        .{ .id = "explorer.refresh", .title = "Refresh Explorer", .category = "Explorer", .run = explorerRefresh },
        .{ .id = "explorer.collapseAll", .title = "Collapse Folders in Explorer", .category = "Explorer", .run = explorerCollapseAll },
        .{ .id = "explorer.revealActiveFile", .title = "Reveal Active File in Explorer", .category = "Explorer", .run = explorerRevealActive },
        .{ .id = "workspace.addFolder", .title = "Add Folder to Workspace...", .category = "Workspaces", .run = workspaceAddFolder },
        .{ .id = "workspace.removeFolder", .title = "Remove Folder from Workspace", .category = "Workspaces", .run = workspaceRemoveFolder },
        .{ .id = "workspace.openFolder", .title = "Open Folder in New Window...", .category = "File", .run = workspaceOpenFolder },
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
        wb.notifyActions(severity, &.{}, fmt, args);
    }

    fn notifyActions(wb: *Workbench, severity: zg_gui.w.notification_center.Severity, actions: []const zg_gui.w.notification_center.ToastAction, comptime fmt: []const u8, args: anytype) void {
        const w = wb.win orelse return;
        const s = std.fmt.bufPrint(&wb.message, fmt, args) catch return;
        _ = zg_gui.w.toast(w.app, .{ .severity = severity, .title = s, .source = "Files", .actions = actions, .sticky = actions.len > 0 });
    }

    /// The current file's disk binding, or a notice for an untitled one.
    fn currentSync(wb: *Workbench) ?*FileSync {
        const f = if (wb.cur_panel) |cp| wb.fileOf(cp) else null;
        if (f) |x| if (x.sync) |fs| return fs;
        wb.notify(.warning, "Untitled: start zigguro with a file path to save", .{});
        return null;
    }

    /// Starts writing the document to its file (on a worker; the outcome
    /// is a toast).
    pub fn save(wb: *Workbench) !void {
        wb.startSave(.{});
    }

    /// Saves even though the file changed on disk.
    fn saveOverwrite(wb: *Workbench) !void {
        wb.startSave(.{ .overwrite = true });
    }

    fn startSave(wb: *Workbench, o: file_sync.SaveOptions) void {
        const fs = wb.currentSync() orelse return;
        wb.runSaveActions(fs.doc, .Manual);
        fs.save(o) catch |e| switch (e) {
            error.Busy => wb.notify(.info, "{s} is still being saved", .{std.fs.path.basename(fs.path)}),
            else => wb.notify(.error_, "Save failed: {t}", .{e}),
        };
    }

    /// Reloads the current file from disk, dropping unsaved edits (one
    /// undo step brings them back).
    fn revert(wb: *Workbench) !void {
        const fs = wb.currentSync() orelse return;
        fs.revert() catch |e| wb.notify(.error_, "Revert failed: {t}", .{e});
    }

    /// Looks for changes on disk to every open file (when the window
    /// gains focus, and with the review poll while the agent runs).
    fn checkFiles(wb: *Workbench) void {
        for (wb.files.items) |f| if (f.sync) |fs| {
            fs.check() catch {};
            wb.refreshHead(f, fs);
        };
    }

    /// Diffs `f` against HEAD again when HEAD moved since its base was
    /// read (a commit, checkout or reset, from the terminal or the agent).
    fn refreshHead(wb: *Workbench, f: OpenFile, fs: *FileSync) void {
        const m = f.diff orelse return;
        const path = f.path orelse return;
        const abs = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, path }) catch return;
        defer wb.gpa.free(abs);
        const now = (scm_base.headCommit(wb.gpa, wb.io, abs) catch return) orelse return;
        if (fs.head_commit) |was| if (std.mem.eql(u8, &was, &now)) return;
        wb.diffAgainstHead(fs, m, path, fs.file.encoding, fs.file.eol);
    }

    /// Mailbox messages for the workbench's models: a DiffModel's full
    /// diff finished (ignored when its file closed meanwhile).
    fn onAppMessage(ctx: *anyopaque, _: *zg_gui.App, msg: zg_core.runtime.UiMsg) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (msg.kind == scm_panel.msg_kind) {
            if (wb.scm) |p| _ = p.handleMessage(msg);
            return;
        }
        if (msg.kind != diff_model.ui_msg_kind) return;
        for (wb.files.items) |f| if (f.diff) |m| if (@intFromPtr(m) == msg.a) {
            m.completeFull() catch |e| log.warn("diff: {t}", .{e});
            if (wb.win) |w| w.markAllDirty();
            return;
        };
    }

    fn onFileSync(ctx: *anyopaque, fs: *FileSync, o: file_sync.Outcome) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const name = std.fs.path.basename(fs.path);
        const keep_or_reload = &[_]zg_gui.w.notification_center.ToastAction{
            .{ .label = "Overwrite", .action = "file.saveOverwrite" },
            .{ .label = "Reload", .action = "file.revert", .primary = true },
        };
        switch (o) {
            .saved, .reloaded => if (wb.notes) |n| n.fileChanged(fs.path),
            else => {},
        }
        const quiet = switch (o) {
            .saved, .save_failed => wb.takeQuiet(fs),
            else => false,
        };
        switch (o) {
            .saved => |s| {
                if (wb.codeintel) |ci| ci.saved(fs.doc);
                if (!quiet) wb.notify(.success, "Saved {s} ({d} bytes)", .{ name, s.bytes });
                // A settings or keybindings file applies at once.
                wb.reloadSettings();
                wb.scmAutoRefresh();
            },
            .save_failed => if (quiet) for (wb.files.items) |*f| {
                // An auto save is not retried until the text changes.
                if (f.sync == fs) f.autosave_failed = f.doc.version;
            },
            else => {},
        }
        switch (o) {
            .saved => {},
            .save_failed => |e| switch (e) {
                error.ExternalChangeConflict => wb.notifyActions(.warning, keep_or_reload, "{s} changed on disk; not saved", .{name}),
                error.Unrepresentable => wb.notify(.error_, "{s}: a character has no encoding in {t}; not saved", .{ name, fs.file.encoding }),
                else => wb.notify(.error_, "Saving {s} failed: {t}", .{ name, e }),
            },
            .unchanged => {},
            .reloaded => wb.notify(.info, "Reloaded {s} from disk", .{name}),
            .conflict => wb.notifyActions(.warning, keep_or_reload, "{s} changed on disk and has unsaved edits", .{name}),
            .deleted => wb.notify(.warning, "{s} was deleted on disk", .{name}),
            .check_failed => |e| log.warn("checking {s}: {t}", .{ name, e }),
        }
        if (wb.win) |w| w.markAllDirty();
    }

    fn undo(wb: *Workbench) !void {
        _ = try wb.view.undoStep();
    }

    fn redo(wb: *Workbench) !void {
        _ = try wb.view.redoStep();
    }

    /// The keymap's binding (Shift+Alt+Up/Down on Linux, Ctrl+Alt+Up/Down
    /// elsewhere; the editor also takes Ctrl+Alt itself).
    fn addCursorAbove(wb: *Workbench) !void {
        _ = try wb.view.cursorCommand(.add_above);
    }

    fn addCursorBelow(wb: *Workbench) !void {
        _ = try wb.view.cursorCommand(.add_below);
    }

    /// Vim keys on or off in every editor (saved as
    /// `keyboard.vim.enabled` when settings are on).
    fn toggleVim(wb: *Workbench) !void {
        const on = wb.key_mode != .vim;
        if (on) _ = wb.persistSetting("keyboard.emacs.enabled", .{ .bool = false });
        if (wb.persistSetting("keyboard.vim.enabled", .{ .bool = on })) return;
        wb.setKeyMode(if (on) .vim else .standard);
    }

    /// Emacs keys on or off in every editor (saved as
    /// `keyboard.emacs.enabled` when settings are on).
    fn toggleEmacs(wb: *Workbench) !void {
        const on = wb.key_mode != .emacs;
        if (on) _ = wb.persistSetting("keyboard.vim.enabled", .{ .bool = false });
        if (wb.persistSetting("keyboard.emacs.enabled", .{ .bool = on })) return;
        wb.setKeyMode(if (on) .emacs else .standard);
    }

    fn setKeyMode(wb: *Workbench, m: KeyMode) void {
        const was = wb.key_mode;
        wb.key_mode = m;
        for (wb.files.items) |*f| wb.setMode(f, m);
        // The Emacs layer joins or leaves the keymap after this key.
        if ((was == .emacs) != (m == .emacs)) wb.queueModeAction(.rebuild_keymap);
        if (wb.win) |w| w.markAllDirty();
    }

    /// Gives `f`'s editor the state of mode `m` (dropping another one).
    fn setMode(wb: *Workbench, f: *OpenFile, m: KeyMode) void {
        if (m != .vim) if (f.vim_state) |vs| {
            f.view.mode = null;
            vs.deinit();
            wb.gpa.destroy(vs);
            f.vim_state = null;
        };
        if (m != .emacs) if (f.emacs_state) |es| {
            f.view.mode = null;
            es.deinit();
            wb.gpa.destroy(es);
            f.emacs_state = null;
        };
        f.view.mode_actions = .{ .ctx = wb, .runFn = runModeAction };
        switch (m) {
            .standard => {},
            .vim => if (f.vim_state == null) {
                const sh = wb.vimShared() orelse return;
                const vs = wb.gpa.create(zg_editor.modes.VimState) catch return;
                vs.* = .init(wb.gpa);
                vs.shared = sh;
                f.vim_state = vs;
                f.view.mode = vs.handler();
            },
            .emacs => if (f.emacs_state == null) {
                const es = wb.gpa.create(zg_editor.modes.EmacsState) catch return;
                es.* = .init(wb.gpa);
                es.kill_ring.clipboard = wb.clipboardPort();
                f.emacs_state = es;
                f.view.mode = es.handler();
            },
        }
    }

    fn vimShared(wb: *Workbench) ?*zg_editor.modes.vim.state.Shared {
        if (wb.vim_shared) |sh| return sh;
        const sh = wb.gpa.create(zg_editor.modes.vim.state.Shared) catch return null;
        sh.* = .init(wb.gpa);
        sh.regs.clipboard = wb.clipboardPort();
        wb.vim_shared = sh;
        return sh;
    }

    /// The app's clipboard and primary selection, for Vim's `+` and `*`
    /// registers and the Emacs kill ring.
    fn clipboardPort(wb: *Workbench) zg_editor.modes.mode.ClipboardPort {
        const F = struct {
            fn board(w: *Workbench, which: zg_editor.modes.mode.ClipboardPort.Which) ?*zg_gui.core.app.Clipboard {
                const win = w.win orelse return null;
                return switch (which) {
                    .clipboard => &win.app.clipboard,
                    .primary => if (win.app.has_primary) &win.app.primary else &win.app.clipboard,
                };
            }
            fn get(ctx: *anyopaque, which: zg_editor.modes.mode.ClipboardPort.Which, gpa: std.mem.Allocator) anyerror!?[]u8 {
                const w: *Workbench = @ptrCast(@alignCast(ctx));
                const c = board(w, which) orelse return null;
                if (c.get().len == 0) return null;
                return try gpa.dupe(u8, c.get());
            }
            fn set(ctx: *anyopaque, which: zg_editor.modes.mode.ClipboardPort.Which, text: []const u8) anyerror!void {
                const w: *Workbench = @ptrCast(@alignCast(ctx));
                const c = board(w, which) orelse return;
                c.set(w.gpa, text);
            }
        };
        return .{ .ctx = wb, .getFn = F.get, .setFn = F.set };
    }

    /// A mode's request, kept until after the key that sent it.
    const ModeAction = union(enum) {
        run: struct { action: zg_editor.modes.mode.Action, text: ?[]u8 = null },
        rebuild_keymap,
    };

    /// `Host.actions` of every editor: queues `a` (strings copied).
    fn runModeAction(ctx: *anyopaque, a: zg_editor.modes.mode.Action) anyerror!void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        var copy = a;
        var text: ?[]u8 = null;
        switch (copy) {
            .write => |*x| if (x.path) |p| {
                text = try wb.gpa.dupe(u8, p);
                x.path = text;
            },
            .edit => |*x| if (x.path) |p| {
                text = try wb.gpa.dupe(u8, p);
                x.path = text;
            },
            .command => |*id| {
                text = try wb.gpa.dupe(u8, id.*);
                id.* = text.?;
            },
            .quit, .exit => {},
        }
        errdefer if (text) |t| wb.gpa.free(t);
        try wb.mode_queue.append(wb.gpa, .{ .run = .{ .action = copy, .text = text } });
        wb.postModeQueue();
    }

    fn queueModeAction(wb: *Workbench, a: ModeAction) void {
        wb.mode_queue.append(wb.gpa, a) catch return;
        wb.postModeQueue();
    }

    fn postModeQueue(wb: *Workbench) void {
        if (wb.mode_posted) return;
        const w = wb.win orelse return;
        w.app.post(.{ .ctx = wb, .f = drainModeQueue }) catch return;
        wb.mode_posted = true;
    }

    fn drainModeQueue(ctx: *anyopaque, _: *zg_gui.App) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.mode_posted = false;
        while (wb.mode_queue.items.len > 0) {
            const q = wb.mode_queue.orderedRemove(0);
            switch (q) {
                .rebuild_keymap => wb.rebuildKeymap() catch |e| wb.notify(.error_, "Keymap: {t}", .{e}),
                .run => |r| {
                    defer if (r.text) |t| wb.gpa.free(t);
                    wb.doModeAction(r.action);
                },
            }
        }
        if (wb.win) |w| w.markAllDirty();
    }

    /// Runs a mode's file or workbench command on the current editor.
    fn doModeAction(wb: *Workbench, a: zg_editor.modes.mode.Action) void {
        switch (a) {
            .write => |x| {
                if (x.path) |p| if (wb.path == null or !wb.samePathRel(p, wb.path.?)) {
                    wb.notify(.warning, "Writing to another file isn't supported yet ({s})", .{p});
                    return;
                };
                wb.startSave(.{ .overwrite = x.force });
            },
            .quit => |x| wb.closeEditor(x.force),
            .exit => if (wb.doc.isDirty()) {
                // The save runs on a worker; closing waits for :q.
                wb.startSave(.{});
                wb.notify(.info, "Saving {s}; :q closes it", .{std.fs.path.basename(wb.path orelse "Untitled")});
            } else wb.closeEditor(false),
            .edit => |x| {
                const p = x.path orelse {
                    if (x.force) wb.revert() catch {};
                    return;
                };
                const abs = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) catch return;
                defer wb.gpa.free(abs);
                wb.openFile(abs) catch |e| wb.notify(.error_, "Can't open {s}: {t}", .{ p, e });
            },
            .command => |id| {
                const cid = wb.reg.lookup(id) orelse {
                    wb.notify(.info, "{s} isn't available yet", .{id});
                    return;
                };
                wb.reg.execute(cid, null, .keybinding) catch |e| wb.notify(.error_, "{s}: {t}", .{ id, e });
            },
        }
    }

    /// Whether `p` (relative to the working folder or absolute) names `cur`.
    fn samePathRel(wb: *Workbench, p: []const u8, cur: []const u8) bool {
        const abs = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) catch return false;
        defer wb.gpa.free(abs);
        const cabs = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, cur }) catch return false;
        defer wb.gpa.free(cabs);
        return wb.samePath(cabs, abs);
    }

    /// Ghost-text completions for `f`'s editor (none when no provider is
    /// configured).
    fn attachCompletions(wb: *Workbench, f: *OpenFile) void {
        const svc = wb.completions_svc orelse return;
        const w = wb.win orelse return;
        if (f.completions != null) return;
        const store = wb.ensureDeco(f) catch |e| return log.warn("completions: {t}", .{e});
        f.completions = completions.EditorCompletions.attach(wb.gpa, svc, w, f.view, store, f.path) catch |e| blk: {
            log.warn("completions: {t}", .{e});
            break :blk null;
        };
    }

    /// The current editor's completions.
    fn curCompletions(wb: *Workbench) ?*completions.EditorCompletions {
        for (wb.files.items) |f| if (f.view == wb.view) return f.completions;
        return null;
    }

    fn completionTrigger(wb: *Workbench) !void {
        if (wb.curCompletions()) |c| c.trigger();
    }

    fn completionAcceptLine(wb: *Workbench) !void {
        if (wb.curCompletions()) |c| _ = c.acceptLine();
    }

    fn completionDismiss(wb: *Workbench) !void {
        if (wb.curCompletions()) |c| c.ctl.dismiss(.escape);
    }

    fn completionSnooze(wb: *Workbench) !void {
        if (wb.curCompletions()) |c| c.snooze();
    }

    fn completionToggle(wb: *Workbench) !void {
        const svc = wb.completions_svc orelse return wb.notify(.info, "Inline completions need ZG_COMPLETION_URL or a model API key", .{});
        if (wb.persistSetting("editor.inlineCompletions.enabled", .{ .bool = !svc.enabled })) return;
        wb.setCompletionsEnabled(!svc.enabled);
    }

    fn setCompletionsEnabled(wb: *Workbench, on: bool) void {
        const svc = wb.completions_svc orelse return;
        if (svc.enabled == on) return;
        svc.enabled = on;
        if (!svc.enabled) for (wb.files.items) |f| if (f.completions) |c| c.ctl.dismiss(.escape);
    }

    /// `f`'s decoration store, created on first use (the view draws it).
    fn ensureDeco(wb: *Workbench, f: *OpenFile) !*zg_editor.model.decorations.store.DecorationStore {
        if (f.deco) |d| return d;
        const d = try wb.gpa.create(zg_editor.model.decorations.store.DecorationStore);
        errdefer wb.gpa.destroy(d);
        d.* = .init(wb.gpa, f.doc);
        errdefer d.deinit();
        f.deco_listener = try f.doc.subscribe(d.listener());
        f.deco = d;
        f.view.decorations = d;
        return d;
    }

    /// `agent.inlineEdit`: the inline edit bar over the selection (the
    /// current line when nothing is selected).
    fn inlineEditStart(wb: *Workbench) !void {
        const w = wb.win orelse return;
        const cp = wb.cur_panel orelse return;
        const f = wb.fileOf(cp) orelse return;
        const path = f.path orelse return wb.notify(.info, "Save the file before editing it inline", .{});
        const handle = f.handle orelse return;
        if (wb.inline_edit) |h| {
            h.destroy();
            wb.inline_edit = null;
        }
        try wb.startAgent(w);
        const host = wb.agent.?;
        const name = wb.env.get("ZG_INLINE_MODEL") orelse wb.env.get("ZG_MODEL") orelse "sonnet";
        const info = host.models.resolve(name) orelse return wb.notify(.warning, "Inline edit: unknown model {s}", .{name});
        const provider = host.hub.forModel(info) orelse return wb.notify(.warning, "Inline edit needs a model API key (ANTHROPIC_API_KEY, ...)", .{});
        const store = try wb.ensureDeco(f);
        const sel = f.view.primarySel();
        var region: [2]usize = .{ @intCast(@min(sel.anchor, sel.head)), @intCast(@max(sel.anchor, sel.head)) };
        if (region[0] == region[1]) {
            const lr = f.view.lineRange(f.view.lineOf(region[0]));
            region = .{ @intCast(lr.start), @intCast(lr.end) };
        }
        const abs = try std.fs.path.resolve(wb.gpa, &.{ wb.cwd, path });
        defer wb.gpa.free(abs);
        const rel = try std.fs.path.relative(wb.gpa, wb.cwd, null, host.review.root, abs);
        defer wb.gpa.free(rel);
        if (wb.inline_history == null) wb.inline_history = .init(wb.gpa);
        wb.inline_edit = try InlineEditHost.open(wb.gpa, .{
            .app = w.app,
            .io = wb.io,
            .view = f.view,
            .store = store,
            .path = rel,
            .workspace = host.review.root,
            .language = if (f.syntax) |sx| sx.lang.name else "",
            .q = host.review.q,
            .history = &host.review.history,
            .inner = host.review.recording.files(),
            .edits = &host.files.edits,
            .handle = handle,
            .provider = provider,
            .model = info.id,
            .ref = host.agent.ref,
            .instructions = &wb.inline_history.?,
            .hooks = .{ .ctx = wb, .to_agent = inlineToAgent, .changed = onStatusChanged },
        }, region);
    }

    /// Writes the review queue's decisions to the workspace's review store.
    fn flushReview(wb: *Workbench) void {
        const host = wb.agent orelse return;
        host.review.mutex.lockUncancelable(wb.io);
        defer host.review.mutex.unlock(wb.io);
        host.review.flushLocked();
    }

    /// The inline edit bar handed its selection and instruction over.
    fn inlineToAgent(ctx: *anyopaque, selection: []const u8, instruction: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (!wb.shown(wb.agent_ref)) wb.toggleAgent() catch |e| return log.warn("agent pane: {t}", .{e});
        const p = wb.agent_panel orelse return;
        const text = std.fmt.allocPrint(wb.gpa, "{s}\n\n```\n{s}\n```\n", .{ instruction, selection }) catch return;
        defer wb.gpa.free(text);
        p.input.setText(text) catch |e| log.warn("agent pane: {t}", .{e});
    }

    fn onStatusChanged(ctx: *anyopaque) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    fn closeEditorCmd(wb: *Workbench) !void {
        wb.closeEditor(false);
    }

    /// Closes the current editor's tab; unsaved changes need `force`. The
    /// last editor stays open.
    fn closeEditor(wb: *Workbench, force: bool) void {
        const cp = wb.cur_panel orelse return;
        const i = for (wb.files.items, 0..) |f, i| {
            if (f.panel == cp) break i;
        } else return;
        if (wb.files.items[i].doc.isDirty() and !force) {
            wb.notify(.warning, "{s} has unsaved changes (add ! to discard them)", .{std.fs.path.basename(wb.files.items[i].path orelse "Untitled")});
            return;
        }
        if (wb.files.items.len == 1) {
            wb.notify(.info, "The last editor stays open", .{});
            return;
        }
        const f = wb.files.orderedRemove(i);
        wb.dock.close(f.panel) catch {};
        for (wb.dock.closed.items) |c| if (c.panel.state) |st| wb.gpa.free(st);
        wb.dock.closed.clearRetainingCapacity();
        wb.closeFile(f);
        const next = &wb.files.items[@min(i, wb.files.items.len - 1)];
        wb.showEditor(next) catch {};
        wb.setCurrent(next.*);
    }

    fn selectAll(wb: *Workbench) !void {
        wb.view.selectAll();
    }

    fn toggleFloatOnTop(wb: *Workbench) !void {
        const fl = if (wb.floater) |*fl| fl else return;
        fl.setAlwaysOnTop(!fl.policy.always_on_top);
        wb.notify(.info, "Floating windows {s}", .{if (fl.policy.always_on_top) "stay on top" else "no longer stay on top"});
    }

    /// Switches between the light and dark theme (saved as
    /// `workbench.colorTheme` when settings are on).
    fn toggleTheme(wb: *Workbench) !void {
        const w = wb.win orelse return;
        wb.dark = w.app.theme.kind != .dark and w.app.theme.kind != .hc_dark;
        if (wb.persistSetting("workbench.colorTheme", .{ .string = if (wb.dark) "zigguro-dark" else "zigguro-light" })) return;
        w.app.follow_system = false;
        w.app.setTheme(if (wb.dark) &themes.zigguro_dark else &themes.zigguro_light);
    }

    // -- settings ----------------------------------------------------------

    /// How often settings.json and keybindings.json are checked for
    /// changes made outside the settings editor.
    const settings_poll_ms = 1000;

    const user_settings_template =
        \\// zigguro user settings: JSON with comments. Settings (Ctrl+,) lists every
        \\// key; whatever is set here applies as soon as the file is saved.
        \\{
        \\}
        \\
    ;
    const workspace_settings_template =
        \\// Settings for this folder only; they win over the user settings.
        \\{
        \\}
        \\
    ;
    const keybindings_template =
        \\// zigguro key bindings, on top of the VS Code preset. Each entry looks like
        \\//   { "key": "ctrl+shift+e", "command": "explorer.focus", "when": "editorFocus" }
        \\// Show All Commands (Ctrl+Shift+P) lists the commands.
        \\[
        \\]
        \\
    ;

    /// Turns settings on: the user's settings.json at `user_path` and
    /// keybindings.json at `keys_path` (null: no config folder) and the
    /// working folder's `.zigguro/settings.json`. Call after `init`.
    pub fn useSettings(wb: *Workbench, user_path: ?[]const u8, keys_path: ?[]const u8) !void {
        const st = try Settings.create(wb.gpa, wb.io, user_path, wb.cwd);
        errdefer st.destroy();
        try st.addListener(.{ .ctx = wb, .f = onSettingsChanged });
        st.setTrusted(wb.trust == .trusted);
        wb.settings = st;
        if (keys_path) |k| wb.keys_path = try wb.gpa.dupe(u8, k);
        wb.pollKeybindings();
        wb.applySettings();
    }

    fn onSettingsChanged(ctx: *anyopaque, _: *const zg_config.store.Change) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.applySettings();
    }

    /// Sets `key` in the user settings.json (which applies it). False
    /// when settings are off or the file cannot be written.
    fn persistSetting(wb: *Workbench, key: []const u8, v: zg_config.Value) bool {
        const st = wb.settings orelse return false;
        st.write(.user, key, v) catch |e| {
            wb.notify(.warning, "{s} was not saved to settings.json: {t}", .{ key, e });
            return false;
        };
        return true;
    }

    /// The editor options from the settings, for files of `lang`.
    fn editorOptions(wb: *Workbench, lang: ?[]const u8) zg_editor.view.editor_view.Options {
        const st = wb.settings orelse return .{};
        const tab = st.getFor("editor.tabSize", lang);
        const spaces = st.getFor("editor.insertSpaces", lang);
        const smart = st.getFor("editor.smartTyping", lang);
        return .{
            .font_size = @floatFromInt(std.math.clamp(st.int("editor.fontSize"), 6, 72)),
            .tab_size = if (tab == .int) @intCast(std.math.clamp(tab.int, 1, 16)) else 4,
            .insert_spaces = spaces != .bool or spaces.bool,
            .line_numbers = !std.mem.eql(u8, st.string("editor.lineNumbers"), "off"),
            .smart_typing = smart != .bool or smart.bool,
        };
    }

    /// Applies every setting the workbench reads (at start and after
    /// each change).
    fn applySettings(wb: *Workbench) void {
        const st = wb.settings orelse return;
        if (wb.win) |w| {
            const t = st.string("workbench.colorTheme");
            if (std.mem.eql(u8, t, "zigguro-light") or std.mem.eql(u8, t, "zigguro-dark")) {
                const want: *const zg_gui.theme.theme.Theme = if (t[8] == 'l') &themes.zigguro_light else &themes.zigguro_dark;
                w.app.follow_system = false;
                if (w.app.theme != want) w.app.setTheme(want);
            } else if (!w.app.follow_system) w.app.followSystem();
            wb.dark = w.app.theme.kind == .dark or w.app.theme.kind == .hc_dark;
        }
        for (wb.files.items) |*f| {
            const o = wb.editorOptions(if (f.syntax) |sx| sx.lang.name else null);
            if (!std.meta.eql(o, f.view.opts)) {
                f.view.opts = o;
                f.view.generation +%= 1;
            }
        }
        const want: KeyMode = if (st.boolean("keyboard.vim.enabled")) .vim else if (st.boolean("keyboard.emacs.enabled")) .emacs else .standard;
        if (want != wb.key_mode) wb.setKeyMode(want);
        wb.setCompletionsEnabled(st.boolean("editor.inlineCompletions.enabled"));
        if (wb.codeintel) |ci| {
            const m = st.string("editor.inlayHints.enabled");
            const mode: InlineInfo.Mode = if (std.mem.eql(u8, m, "off")) .off else if (std.mem.eql(u8, m, "onUnlessPressed")) .on_unless_pressed else if (std.mem.eql(u8, m, "offUnlessPressed")) .off_unless_pressed else .on;
            ci.inline_info.configure(mode, st.boolean("editor.codeLens"));
            ci.linked.setEnabled(st.boolean("editor.linkedEditing"));
        }
        wb.armAutosave();
        wb.applyExplorerSettings();
        wb.applyScmSettings();
        if (wb.win) |w| w.markAllDirty();
    }

    /// Re-reads changed settings and keybindings files.
    fn reloadSettings(wb: *Workbench) void {
        if (wb.settings) |st| _ = st.poll();
        wb.pollKeybindings();
        // New, renamed and deleted files show up in the explorer.
        if (wb.explorer) |e| if (e.refresh()) if (wb.win) |w| w.markAllDirty();
    }

    fn armSettingsPoll(wb: *Workbench, w: *Window) void {
        if (wb.settings == null) return;
        wb.settings_timer = w.setTimer(w.app.now_ms + settings_poll_ms, .{ .ctx = wb, .f = pollSettingsTimer }) catch .none;
    }

    fn pollSettingsTimer(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.settings_timer = .none;
        wb.reloadSettings();
        wb.pollScm(w.app.now_ms);
        wb.armSettingsPoll(w);
    }

    /// Loads the user's keybindings.json again when it changed, and
    /// rebuilds the keymap with it.
    fn pollKeybindings(wb: *Workbench) void {
        const p = wb.keys_path orelse return;
        const now: KeysStamp = if (std.Io.Dir.cwd().statFile(wb.io, p, .{})) |st|
            .{ .size = st.size, .mtime = st.mtime.nanoseconds, .missing = false }
        else |_|
            .{ .size = 0, .mtime = 0, .missing = true };
        if (wb.keys_stamp) |old| if (std.meta.eql(old, now)) return;
        const first = wb.keys_stamp == null;
        wb.keys_stamp = now;
        var next: ?zg_config.zon_load.Doc = null;
        if (!now.missing) {
            const src = std.Io.Dir.cwd().readFileAlloc(wb.io, p, wb.gpa, .limited(zg_config.zon_load.max_file_bytes)) catch |e| {
                wb.notify(.warning, "keybindings.json: {t}", .{e});
                return;
            };
            defer wb.gpa.free(src);
            if (std.mem.trim(u8, src, " \t\r\n").len > 0) {
                var diags: zg_config.diag.Diags = .init(wb.gpa);
                defer diags.deinit();
                next = zg_config.jsonc.loadJsonc(wb.gpa, src, &diags) catch {
                    if (diags.items().len > 0) {
                        const d = diags.items()[0];
                        const lc = zg_config.diag.lineCol(src, d.span.start);
                        wb.notify(.warning, "keybindings.json:{d}:{d}: {s}", .{ lc.line, lc.col, d.message });
                    }
                    return;
                };
            }
        }
        // A missing file at startup changes nothing.
        if (first and next == null) return;
        var old = wb.keys_doc;
        wb.keys_doc = next;
        wb.rebuildKeymap() catch |e| wb.notify(.error_, "Keymap: {t}", .{e});
        if (old) |*d| d.deinit();
    }

    pub fn openSettings(wb: *Workbench) !void {
        const w = wb.win orelse return;
        if (wb.settings == null) return wb.notify(.warning, "Settings are not available", .{});
        try wb.ensureSettingsView();
        if (wb.settings_ref == null) wb.settings_ref = try wb.dock.addPanel(kind_settings, null);
        try wb.reveal(wb.settings_ref.?, .center);
        w.markAllDirty();
    }

    fn ensureSettingsView(wb: *Workbench) !void {
        if (wb.settings_view != null) return;
        const st = wb.settings orelse return;
        const v = try SettingsView.create(wb.gpa, st);
        v.open_json = .{ .ctx = wb, .f = openSettingsJson };
        wb.settings_view = v;
    }

    fn openSettingsJson(ctx: *anyopaque, scope: settings_mod.Scope) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.openSettingsFileOf(scope);
    }

    fn openUserSettingsFile(wb: *Workbench) !void {
        wb.openSettingsFileOf(.user);
    }

    fn openWorkspaceSettingsFile(wb: *Workbench) !void {
        wb.openSettingsFileOf(.workspace);
    }

    fn openSettingsFileOf(wb: *Workbench, scope: settings_mod.Scope) void {
        const st = wb.settings orelse return wb.notify(.warning, "Settings are not available", .{});
        const p = st.path(scope) orelse return wb.notify(.warning, "There is no user settings folder (no home directory)", .{});
        wb.openConfigFile(p, if (scope == .user) user_settings_template else workspace_settings_template);
    }

    fn openKeybindingsFile(wb: *Workbench) !void {
        const p = wb.keys_path orelse return wb.notify(.warning, "There is no user settings folder (no home directory)", .{});
        wb.openConfigFile(p, keybindings_template);
    }

    /// Opens `p` in an editor at the next build, creating it from
    /// `template` when it does not exist.
    fn openConfigFile(wb: *Workbench, p: []const u8, template: []const u8) void {
        _ = std.Io.Dir.cwd().statFile(wb.io, p, .{}) catch |e| switch (e) {
            error.FileNotFound => zg_config.json_edit.writeAtomic(wb.io, std.Io.Dir.cwd(), p, template) catch |we| {
                return wb.notify(.error_, "Could not create {s}: {t}", .{ p, we });
            },
            else => {},
        };
        const dup = wb.gpa.dupe(u8, p) catch return;
        if (wb.pending_open) |old| wb.gpa.free(old);
        wb.pending_open = dup;
        wb.pending_virtual = false;
        if (wb.win) |w| w.markAllDirty();
    }

    // -- hover and navigation --------------------------------------------------

    /// `editor.showHover`: the hover at the caret.
    fn showHover(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        const h = wb.currentHandle() orelse return;
        const w = wb.win orelse return;
        if (wb.editor_node.isNone()) return;
        const r = w.layoutRect(wb.editor_node);
        const origin: zg_gui.core.Vec2 = .{ .x = r.x + wb.view.gutter_w - wb.view.scroll.x, .y = r.y - wb.view.scroll.y };
        ci.showHoverAt(wb.view, h, wb.view.primarySel().head, origin) catch
            wb.notify(.info, "No language server for this file", .{});
    }

    /// `editor.rename`: the symbol at the caret.
    fn renameSymbol(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        const h = wb.currentHandle() orelse return wb.notify(.info, "No language server can rename here", .{});
        ci.rename(h, wb.view.primarySel().head);
    }

    /// `editor.quickFix`: code actions at the caret or selection.
    fn quickFix(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        const h = wb.currentHandle() orelse return wb.notify(.info, "No language server offers code actions here", .{});
        const w = wb.win orelse return;
        if (wb.editor_node.isNone()) return;
        const r = w.layoutRect(wb.editor_node);
        const origin: zg_gui.core.Vec2 = .{ .x = r.x + wb.view.gutter_w - wb.view.scroll.x, .y = r.y - wb.view.scroll.y };
        const sel = wb.view.primarySel().range();
        ci.quickFix(wb.view, h, .{ .start = sel.start, .end = sel.end }, origin);
    }

    /// `quickOpen.symbolsInFile` (Ctrl+Shift+O).
    fn symbolsInFile(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        const h = wb.currentHandle() orelse return wb.notify(.info, "This file has no symbols", .{});
        try ci.symbolsInFile(wb.view, h);
    }

    /// `quickOpen.symbols` (Ctrl+T).
    fn symbolsInWorkspace(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        try ci.symbolsInWorkspace();
    }

    fn symbolHere(ctx: *anyopaque, view: *EditorView, sel: zg_editor.model.edit.selection.Selection) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.rememberHere();
        view.setSelection(sel);
        if (wb.win) |w| w.markAllDirty();
    }

    fn symbolTo(ctx: *anyopaque, t: NavService.Target) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.jumpTo(t);
    }

    /// A run or debug code lens. Tasks and debugging (E07.F06, F08) are
    /// not in the app yet.
    fn onLensAction(ctx: *anyopaque, action: InlineInfo.Action, command: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const what = switch (action) {
            .run_task => "Running",
            .debug_launch => "Debugging",
        };
        wb.notify(.info, "{s} from a code lens ({s}) needs tasks and the debugger, which are not available yet", .{ what, command });
    }

    fn symbolNotice(ctx: *anyopaque, msg: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.notify(.info, "{s}", .{msg});
    }

    /// `editor.formatDocument`.
    fn formatDocument(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        const h = wb.currentHandle() orelse return wb.notify(.info, "No language server can format this file", .{});
        ci.formatDocument(h);
    }

    /// `editor.formatSelection` (the whole file without a selection).
    fn formatSelection(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        const h = wb.currentHandle() orelse return wb.notify(.info, "No language server can format this file", .{});
        const sel = wb.view.primarySel().range();
        ci.formatSelection(h, .{ .start = sel.start, .end = sel.end });
    }

    fn openFileOfHandle(wb: *Workbench, h: zg_editor.model.api.registry.DocHandle) ?*OpenFile {
        for (wb.files.items) |*f| if (f.handle) |x| if (std.meta.eql(x, h)) return f;
        return null;
    }

    fn langOfHandle(wb: *Workbench, h: zg_editor.model.api.registry.DocHandle) ?[]const u8 {
        const f = wb.openFileOfHandle(h) orelse return null;
        return if (f.syntax) |sx| sx.lang.name else null;
    }

    fn formatOptionsOf(ctx: *anyopaque, h: zg_editor.model.api.registry.DocHandle) zg_codeintel.protocol.FormattingOptions {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const o = wb.editorOptions(wb.langOfHandle(h));
        return .{ .tabSize = o.tab_size, .insertSpaces = o.insert_spaces };
    }

    fn formatOnTypeOf(ctx: *anyopaque, h: zg_editor.model.api.registry.DocHandle) bool {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const st = wb.settings orelse return false;
        const v = st.getFor("editor.formatOnType", wb.langOfHandle(h));
        return v == .bool and v.bool;
    }

    /// The save pipeline before `doc` is written: willSaveWaitUntil, the
    /// code actions on save, then format on save (1 s in all).
    fn runSaveActions(wb: *Workbench, doc: *Document, reason: zg_codeintel.protocol.TextDocumentSaveReason) void {
        const ci = wb.codeintel orelse return;
        const f = for (wb.files.items) |*x| {
            if (x.doc == doc) break x;
        } else return;
        const h = f.handle orelse return;
        const lang = if (f.syntax) |sx| sx.lang.name else null;
        var kinds: [8][]const u8 = undefined;
        var n: usize = 0;
        var format = false;
        if (wb.settings) |st| {
            const fos = st.getFor("editor.formatOnSave", lang);
            format = fos != .bool or fos.bool;
            const cas = st.getFor("editor.codeActionsOnSave", lang);
            if (cas == .object) for (cas.object) |fl| {
                if (n == kinds.len) break;
                if (fl.value == .bool and fl.value.bool) {
                    kinds[n] = fl.key;
                    n += 1;
                }
            };
        }
        const r = ci.beforeSave(h, .{ .code_actions = kinds[0..n], .format = format, .reason = reason });
        if (r.warn) wb.notify(.warning, "{s}: formatting on save took too long and was skipped", .{std.fs.path.basename(f.path orelse "Untitled")});
    }

    fn onRefactorNotice(ctx: *anyopaque, warning: bool, msg: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.notify(if (warning) .warning else .info, "{s}", .{msg});
    }

    fn navGo(wb: *Workbench, kind: NavService.Kind) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        const h = wb.currentHandle() orelse return wb.notify(.info, "No language server for this file", .{});
        const n = try ci.goTo(kind, h, wb.view.primarySel().head, true);
        if (n == 0) wb.notify(.info, "No language server provides {s} for this file", .{navNoun(kind)});
    }

    fn navNoun(kind: NavService.Kind) []const u8 {
        return switch (kind) {
            .definition => "definitions",
            .declaration => "declarations",
            .type_definition => "type definitions",
            .implementation => "implementations",
            .references => "references",
        };
    }

    fn goToDefinition(wb: *Workbench) !void {
        try wb.navGo(.definition);
    }

    fn goToDeclaration(wb: *Workbench) !void {
        try wb.navGo(.declaration);
    }

    fn goToTypeDefinition(wb: *Workbench) !void {
        try wb.navGo(.type_definition);
    }

    fn goToImplementation(wb: *Workbench) !void {
        try wb.navGo(.implementation);
    }

    fn findReferences(wb: *Workbench) !void {
        try wb.navGo(.references);
    }

    /// A navigation request has its answers: none is a notice, one
    /// definition-like target is jumped to, and anything else is offered
    /// in a QuickPick.
    /// The completion list opened or closed over `view`: the AI ghost
    /// text there steps aside while it shows.
    fn onCompletionPopup(ctx: *anyopaque, view: *EditorView, open: bool) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        for (wb.files.items) |*f| if (f.view == view) if (f.completions) |ec| {
            if (open) ec.popupOpened() else ec.popupClosed();
        };
    }

    fn onNavDone(ctx: *anyopaque, r: NavService.Results) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (r.targets.len == 0) return wb.notify(.info, "No {s} found", .{navNoun(r.kind)});
        if (r.targets.len == 1 and r.kind != .references) return wb.jumpTo(r.targets[0]);
        wb.offerTargets(r) catch |e| wb.notify(.error_, "Could not list {s}: {t}", .{ navNoun(r.kind), e });
    }

    /// Opens `t` (in a tab, loading it the first time) with the caret at
    /// its selection start, remembering where the caret was for Go Back.
    fn jumpTo(wb: *Workbench, t: NavService.Target) void {
        const path = t.path orelse {
            // A location outside the file system: its server's text.
            if (wb.codeintel == null) return wb.notify(.info, "Can't open {s}", .{t.uri});
            wb.rememberHere();
            wb.openAt(t.uri, .{ .pos = .{ .line = t.selection.start.line, .character = t.selection.start.character, .enc = t.enc } });
            wb.pending_virtual = true;
            return;
        };
        wb.rememberHere();
        wb.openAt(path, .{ .pos = .{ .line = t.selection.start.line, .character = t.selection.start.character, .enc = t.enc } });
    }

    /// Opens the virtual document `uri` (a language server's location
    /// outside the file system) read-only in a tab, or shows its tab.
    fn openVirtual(wb: *Workbench, uri: []const u8) !void {
        const ci = wb.codeintel orelse return error.NoLanguageServices;
        for (wb.files.items) |*f| if (f.virtual) |vh| if (std.mem.eql(u8, wb.docs.uri(vh) orelse "", uri)) {
            try wb.showEditor(f);
            wb.setCurrent(f.*);
            return;
        };
        const h = try ci.virtual.open(uri);
        errdefer ci.virtual.release(h);
        // The workbench's reference keeps the document until the tab
        // closes, even after language services stop.
        try wb.docs.retain(h);
        errdefer wb.docs.release(h);
        const gpa = wb.gpa;
        var f: OpenFile = .{ .path = null, .doc = wb.docs.get(h).?, .view = undefined, .syntax = null, .virtual = h };
        const name = wb.docs.name(h) orelse "";
        var opts = wb.editorOptions(null);
        opts.read_only = true;
        f.view = try EditorView.init(gpa, f.doc, opts);
        errdefer f.view.deinit();
        wb.setMode(&f, wb.key_mode);
        if (wb.langs.detect(name, "")) |id| if (wb.langs.get(id)) |lang| {
            const sx = try gpa.create(DocumentSyntax);
            errdefer gpa.destroy(sx);
            sx.* = try DocumentSyntax.init(gpa, lang, &wb.langs, &f.doc.tree, f.doc.version);
            f.syntax = sx;
            f.view.syntax = sx;
            f.view.opts = wb.editorOptions(lang.name);
            f.view.opts.read_only = true;
        };
        const nf = try wb.addFile(f);
        wb.setCurrent(nf.*);
    }

    /// Puts the caret where a virtual document was opened at, once its
    /// text is there (current editor only).
    fn virtualGoto(wb: *Workbench) void {
        const cp = wb.cur_panel orelse return;
        const f = wb.fileOf(cp) orelse return;
        const g = f.virtual_goto orelse return;
        const ci = wb.codeintel orelse {
            f.virtual_goto = null;
            return;
        };
        const e = ci.virtual.entryOf(f.virtual.?) orelse return;
        if (e.state == .loading) return;
        f.virtual_goto = null;
        switch (g) {
            .pos => |p| wb.gotoPos(p.line, p.character, p.enc),
            .offset => |o| wb.gotoOffset(o),
            .problem => |it| wb.gotoProblem(it),
        }
    }

    /// Opens `abs` at the next build with the caret at `g`.
    fn openAt(wb: *Workbench, abs: []const u8, g: Goto) void {
        const copy = wb.gpa.dupe(u8, abs) catch return;
        if (wb.pending_open) |old| wb.gpa.free(old);
        wb.pending_open = copy;
        wb.pending_virtual = false;
        wb.pending_focus = true;
        wb.pending_explorer = false;
        wb.pending_goto = g;
        if (wb.win) |w| w.markAllDirty();
    }

    /// The current file and caret, if it has a path.
    fn here(wb: *Workbench, buf: []u8) ?NavService.History.Loc {
        const path = wb.path orelse return null;
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const abs = std.fs.path.resolve(fba.allocator(), &.{ wb.cwd, path }) catch return null;
        return .{ .path = abs, .offset = wb.view.primarySel().head };
    }

    fn history(wb: *Workbench) *NavService.History {
        if (wb.nav_history == null) wb.nav_history = .init(wb.gpa);
        return &wb.nav_history.?;
    }

    fn rememberHere(wb: *Workbench) void {
        var buf: [std.fs.max_path_bytes * 2]u8 = undefined;
        const loc = wb.here(&buf) orelse return;
        wb.history().push(loc) catch {};
    }

    /// `navigation.back` (Alt+Left).
    fn navigateBack(wb: *Workbench) !void {
        var buf: [std.fs.max_path_bytes * 2]u8 = undefined;
        const loc = wb.here(&buf) orelse return;
        const to = try wb.history().back(loc) orelse return;
        wb.openAt(to.path, .{ .offset = to.offset });
    }

    /// `navigation.forward` (Alt+Right).
    fn navigateForward(wb: *Workbench) !void {
        const to = wb.history().forward() orelse return;
        wb.openAt(to.path, .{ .offset = to.offset });
    }

    /// Puts the caret at line `line`, column `character` (counted in
    /// `enc`) of the current editor.
    fn gotoPos(wb: *Workbench, line: u32, character: u32, enc: @FieldType(NavService.Target, "enc")) void {
        const v = wb.view;
        const l = @min(@as(u64, line), v.lineCount() - 1);
        const lr = v.lineRange(l);
        wb.gotoOffset(lr.start + zg_core.utf8.columnToByte(v.text(lr), character, enc));
    }

    /// Puts the caret at 0-based `line`, byte column `col` of the current
    /// editor (`bench-latency`).
    pub fn gotoLine(wb: *Workbench, line: u32, col: u32) void {
        wb.gotoPos(line, col, .utf8);
    }

    fn gotoOffset(wb: *Workbench, off: u64) void {
        const v = wb.view;
        v.setSelection(.caret(@min(off, wb.doc.len())));
        v.revealPrimary();
        if (wb.win) |w| w.markAllDirty();
    }

    /// Lists the targets of `r` in a QuickPick ("file:line:column" and
    /// the folder); accepting one jumps there.
    fn offerTargets(wb: *Workbench, r: NavService.Results) !void {
        const w = wb.win orelse return;
        wb.nav_pick.close(w);
        if (wb.nav_arena) |*a| a.deinit();
        wb.nav_arena = .init(wb.gpa);
        const a = wb.nav_arena.?.allocator();
        wb.nav_targets = try a.alloc(NavService.Target, r.targets.len);
        wb.nav_items = try a.alloc(zg_gui.w.quick_pick.QpItem, r.targets.len);
        for (r.targets, wb.nav_targets, wb.nav_items, 0..) |t, *dst, *it, i| {
            dst.* = t;
            dst.uri = try a.dupe(u8, t.uri);
            dst.path = if (t.path) |p| try a.dupe(u8, p) else null;
            const full = dst.path orelse dst.uri;
            const rel = if (dst.path != null and std.mem.startsWith(u8, full, wb.cwd) and full.len > wb.cwd.len and std.fs.path.isSep(full[wb.cwd.len])) full[wb.cwd.len + 1 ..] else full;
            it.* = .{
                .id = i,
                .label = try std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ std.fs.path.basename(rel), t.selection.start.line + 1, t.selection.start.character + 1 }),
                .description = std.fs.path.dirname(rel) orelse "",
            };
        }
        wb.nav_title = try std.fmt.allocPrint(a, "{s} ({d})", .{ switch (r.kind) {
            .definition => "Definitions",
            .declaration => "Declarations",
            .type_definition => "Type Definitions",
            .implementation => "Implementations",
            .references => "References",
        }, r.targets.len });
        const provs = [_]zg_gui.w.quick_pick.Provider{.{ .ptr = wb, .vtable = &nav_pick_vtable }};
        wb.nav_pick = try zg_gui.w.quick_pick.openQuickPick(w, .{ .providers = &provs, .title = wb.nav_title, .test_id = "nav-targets" });
    }

    const nav_pick_vtable: zg_gui.w.quick_pick.Provider.VTable = .{
        .placeholder = "Filter by file name",
        .items = navPickItems,
        .accept = navPickAccept,
    };

    fn navPickItems(ptr: ?*anyopaque) []const zg_gui.w.quick_pick.QpItem {
        const wb: *Workbench = @ptrCast(@alignCast(ptr.?));
        return wb.nav_items;
    }

    fn navPickAccept(ptr: ?*anyopaque, items: []const zg_gui.w.quick_pick.QpItem, _: ?[]const u8, _: bool) void {
        const wb: *Workbench = @ptrCast(@alignCast(ptr.?));
        if (items.len == 0 or items[0].id >= wb.nav_targets.len) return;
        wb.jumpTo(wb.nav_targets[@intCast(items[0].id)]);
    }

    /// A link in a hover: files open (with `#L<line>`), allowlisted
    /// commands run, web links are copied (no browser hand-off yet).
    /// A Ctrl+clicked document link: files open in the editor (at the
    /// `#L` line), web links in the browser, allowed commands run.
    fn onDocLink(ctx: *anyopaque, kind: doc_links.LinkDriver.TargetKind, target: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        switch (kind) {
            .web => if (wb.win) |w| w.openUri(target),
            .file => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const t = doc_links.fileTarget(&buf, target) orelse return wb.notify(.info, "Can't open {s}", .{target});
                wb.rememberHere();
                wb.openAt(t.path, .{ .pos = .{ .line = t.line orelse 0, .character = 0, .enc = .utf16 } });
            },
            .command => {
                const rest = target["command:".len..];
                const id = rest[0 .. std.mem.indexOfScalar(u8, rest, '?') orelse rest.len];
                const cid = wb.reg.lookup(id) orelse return wb.notify(.info, "{s} isn't available yet", .{id});
                wb.reg.execute(cid, null, .palette) catch |e| wb.notify(.error_, "{s}: {t}", .{ id, e });
            },
        }
    }

    /// `editor.expandSelection` (Shift+Alt+Right).
    fn expandSelection(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return;
        const h = wb.currentHandle() orelse return;
        ci.expandSelection(wb.view, h);
        if (wb.win) |w| w.markAllDirty();
    }

    /// `editor.shrinkSelection` (Shift+Alt+Left).
    fn shrinkSelection(wb: *Workbench) !void {
        const ci = wb.codeintel orelse return;
        ci.shrinkSelection(wb.view);
        if (wb.win) |w| w.markAllDirty();
    }

    fn onHoverLink(ctx: *anyopaque, target: zg_gui.markdown.view_mod.LinkTarget, _: bool) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const url = switch (target) {
            .url => |u| u,
            else => return,
        };
        if (wb.codeintel) |ci| ci.hideHover();
        if (std.mem.startsWith(u8, url, "command:")) {
            const rest = url["command:".len..];
            const id = rest[0 .. std.mem.indexOfScalar(u8, rest, '?') orelse rest.len];
            for (zg_codeintel.features.HoverService.allowed_commands) |c| if (std.mem.eql(u8, c, id)) {
                const cid = wb.reg.lookup(id) orelse return wb.notify(.info, "{s} isn't available yet", .{id});
                wb.reg.execute(cid, null, .palette) catch |e| wb.notify(.error_, "{s}: {t}", .{ id, e });
                return;
            };
            return;
        }
        if (std.mem.startsWith(u8, url, "file:")) {
            const frag = std.mem.indexOfScalar(u8, url, '#');
            const path = (zg_codeintel.uri.pathFromUri(wb.gpa, url[0 .. frag orelse url.len]) catch null) orelse return wb.notify(.info, "Can't open {s}", .{url});
            defer wb.gpa.free(path);
            var line: u32 = 0;
            if (frag) |i| if (i + 2 < url.len and url[i + 1] == 'L') {
                const digits = url[i + 2 ..];
                const n = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
                line = (std.fmt.parseInt(u32, digits[0..n], 10) catch 1) -| 1;
            };
            wb.rememberHere();
            return wb.openAt(path, .{ .pos = .{ .line = line, .character = 0, .enc = .utf16 } });
        }
        if (wb.win) |w| w.app.clipboard.set(wb.gpa, url);
        wb.notify(.info, "Link copied: {s}", .{url});
    }

    // -- notes -----------------------------------------------------------------

    /// The folder's notes, scanned on first use.
    fn ensureNotes(wb: *Workbench) !void {
        if (wb.notes != null) return;
        const w = wb.win orelse return error.NoWindow;
        const n = try NotesService.create(wb.gpa, wb.io, w.app, wb.cwd, wb.env, .{
            .ctx = wb,
            .open = onNoteOpen,
            .search = onNoteSearch,
            .changed = onNotesChanged,
            .apply = onNotesApply,
            .propose = onNotesPropose,
        });
        wb.notes = n;
        const abs = if (wb.path) |p| std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) catch null else null;
        defer if (abs) |a| wb.gpa.free(a);
        n.setActive(abs);
    }

    /// The notes sidebar or the note search, with the scan's progress.
    fn notesPanel(wb: *Workbench, ui: *Ui, search: bool) void {
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .bg = .{ .token = .bg_elevated } }, .key_context = if (search) "notesSearchFocus" else "notesSidebarFocus" });
        defer ui.close();
        wb.ensureNotes() catch |e| {
            ui.open(.{ .style = .{ .padding = .xy(12, 6) } });
            ui.textf("Notes are not available: {t}", .{e}, .{ .color = .fg_muted });
            ui.close();
            return;
        };
        const n = wb.notes.?;
        switch (n.stateNow()) {
            .scanning => {
                ui.open(.{ .style = .{ .padding = .xy(12, 6) } });
                ui.textf("Indexing notes ({d} so far)...", .{n.noteCount()}, .{ .color = .fg_muted });
                ui.close();
            },
            .failed => {
                ui.open(.{ .style = .{ .padding = .xy(12, 6) } });
                ui.text("Some notes could not be read; see the log.", .{ .color = .warning });
                ui.close();
            },
            .ready => if (n.noteCount() == 0) {
                ui.open(.{ .style = .{ .padding = .xy(12, 6) } });
                ui.text("No Markdown notes in this folder.", .{ .color = .fg_muted });
                ui.close();
            },
        }
        if (search) n.search_view.build(ui) else n.sidebar.build(ui);
    }

    /// `notes.showSidebar`: backlinks, links, properties and tags of the
    /// current note, in the right side area.
    fn showNotesSidebar(wb: *Workbench) !void {
        try wb.ensureNotes();
        if (wb.notes_ref == null) wb.notes_ref = try wb.dock.addPanel(kind_notes, null);
        try wb.reveal(wb.notes_ref.?, .right);
        if (wb.win) |w| w.markAllDirty();
    }

    /// `notes.search` (Ctrl+Shift+N).
    fn notesSearch(wb: *Workbench) !void {
        try wb.showNotesSearch(null);
    }

    /// Shows the note search in the left side area (with `query`) and
    /// focuses its field.
    fn showNotesSearch(wb: *Workbench, query: ?[]const u8) !void {
        try wb.ensureNotes();
        if (query) |q| try wb.notes.?.search_view.setQuery(q);
        if (wb.notes_search_ref == null) wb.notes_search_ref = try wb.dock.addPanel(kind_notes_search, null);
        try wb.reveal(wb.notes_search_ref.?, .left);
        if (wb.win) |w| {
            w.markAllDirty();
            w.afterNextFrame(.{ .ctx = wb, .f = focusNotesSearch });
        }
    }

    fn focusNotesSearch(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.notes) |n| n.search_view.focus(w);
    }

    /// `notes.searchSelection`: searches notes for the selected text (its
    /// first line, as a phrase).
    fn notesSearchSelection(wb: *Workbench) !void {
        const sel = wb.view.primarySel();
        const lo = @min(sel.anchor, sel.head);
        const hi = @max(sel.anchor, sel.head);
        if (lo == hi) return wb.showNotesSearch(null);
        const text = wb.view.text(.{ .start = lo, .end = @min(hi, lo + 200) });
        const line = std.mem.trim(u8, text[0 .. std.mem.indexOfAny(u8, text, "\r\n") orelse text.len], " \t");
        var q: std.ArrayList(u8) = .empty;
        defer q.deinit(wb.gpa);
        try q.append(wb.gpa, '"');
        for (line) |c| {
            if (c == '"' or c == '\\') try q.append(wb.gpa, '\\');
            try q.append(wb.gpa, c);
        }
        try q.append(wb.gpa, '"');
        try wb.showNotesSearch(q.items);
    }

    /// `notes.followLink` (Alt+Enter): opens the target of the note link
    /// at the caret, creating a missing note.
    fn notesFollowLink(wb: *Workbench) !void {
        const path = wb.path orelse return;
        try wb.ensureNotes();
        const abs = try std.fs.path.resolve(wb.gpa, &.{ wb.cwd, path });
        defer wb.gpa.free(abs);
        const text = wb.view.text(.{ .start = 0, .end = wb.doc.len() });
        const at: u32 = @intCast(@min(wb.view.primarySel().head, std.math.maxInt(u32)));
        if (!try wb.notes.?.followLink(abs, text, at)) wb.notify(.info, "No note link at the cursor", .{});
    }

    /// `notes.saveSearch`: keeps the current query in the saved list.
    fn notesSaveSearch(wb: *Workbench) !void {
        const n = wb.notes orelse return;
        n.search_view.saveSearch(wb.io, null) catch |e| wb.notify(.error_, "Saving the search failed: {t}", .{e});
        if (wb.win) |w| w.markAllDirty();
    }

    /// A note link or search hit: open the note at the next build and
    /// select `range` (to the side is not supported yet: same group).
    fn onNoteOpen(ctx: *anyopaque, abs: []const u8, range: ?[2]u32, to_side: bool) void {
        _ = to_side;
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const copy = wb.gpa.dupe(u8, abs) catch return;
        if (wb.pending_open) |old| wb.gpa.free(old);
        wb.pending_open = copy;
        wb.pending_virtual = false;
        wb.pending_focus = true;
        wb.pending_explorer = false;
        wb.pending_goto = null;
        wb.pending_range = range;
        if (wb.win) |w| w.markAllDirty();
    }

    fn onNoteSearch(ctx: *anyopaque, query: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.showNotesSearch(query) catch |e| wb.notify(.error_, "Note search: {t}", .{e});
    }

    fn onNotesChanged(ctx: *anyopaque) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    /// Sidebar edits: one accepted changeset in the review store when the
    /// agent runs (so review history shows and reverts it), else written
    /// directly. Open editors reload the files.
    fn onNotesApply(ctx: *anyopaque, label: []const u8, changes: []const zg_notes_ui.ports.FileChange) anyerror!?u64 {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        defer wb.checkFiles();
        if (wb.agent) |h| {
            const files = try wb.gpa.alloc(ReviewGlue.ProposedFile, changes.len);
            defer wb.gpa.free(files);
            for (changes, files) |c, *f| f.* = .{ .path = c.path, .base = c.base, .new = c.new };
            const id = try h.review.proposeChange(label, .{ .notes = .{ .tx = 0 } }, files, true);
            return if (id) |x| @intFromEnum(x) else 0;
        }
        try wb.notes.?.writeChanges(changes);
        return 0;
    }

    /// The agent's note edits: one changeset, pending review unless the
    /// review mode applies agent edits at once. Any thread.
    fn onNotesPropose(ctx: *anyopaque, label: []const u8, changes: []const zg_notes_ui.ports.FileChange) anyerror!u64 {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const h = wb.agent orelse return error.Unsupported;
        const files = try wb.gpa.alloc(ReviewGlue.ProposedFile, changes.len);
        defer wb.gpa.free(files);
        for (changes, files) |c, *f| f.* = .{ .path = c.path, .base = c.base, .new = c.new };
        const id = try h.review.proposeChange(label, .{ .notes = .{ .tx = 0 } }, files, h.review.mode == .auto_apply);
        return if (id) |x| @intFromEnum(x) else 0;
    }

    /// Selects bytes `r` of the current editor (clamped) and shows them.
    fn selectBytes(wb: *Workbench, r: [2]u32) void {
        const len = wb.doc.len();
        const v = wb.view;
        v.setSelection(.{ .anchor = @min(r[0], len), .head = @min(r[1], len) });
        v.revealPrimary();
    }

    // -- problems --------------------------------------------------------------

    fn ensureProblems(wb: *Workbench) !void {
        if (wb.problems != null) return;
        const ci = wb.codeintel orelse return;
        const pp = try wb.gpa.create(ProblemsPanel);
        errdefer wb.gpa.destroy(pp);
        try pp.init(wb.gpa, &ci.diags, wb.cwd, .{ .ctx = wb, .open = onProblemOpen });
        pp.win = wb.win;
        wb.problems = pp;
    }

    /// The Problems tab's badge: the error count.
    fn problemsBadge(wb: *Workbench) []const u8 {
        const ci = wb.codeintel orelse return "";
        const errs = problems_panel.Problems.totals(&ci.diags)[0];
        if (errs == 0) return "";
        return std.fmt.bufPrint(&wb.problems_badge, "{d}", .{errs}) catch "";
    }

    /// `workbench.showProblems` (Ctrl+Shift+M): shows the Problems panel
    /// in the bottom area and focuses it.
    fn showProblems(wb: *Workbench) !void {
        try wb.ensureProblems();
        if (wb.problems_ref == null) wb.problems_ref = try wb.dock.addPanel(kind_problems, null);
        try wb.reveal(wb.problems_ref.?, .bottom);
        if (wb.win) |w| {
            w.markAllDirty();
            w.afterNextFrame(.{ .ctx = wb, .f = focusProblems });
        }
    }

    fn focusProblems(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.problems) |pp| pp.focus(w);
    }

    // -- call and type hierarchy ---------------------------------------------------

    fn ensureHierarchy(wb: *Workbench) !void {
        if (wb.hierarchy != null) return;
        const ci = wb.codeintel orelse return;
        const hp = try wb.gpa.create(HierarchyPanel);
        errdefer wb.gpa.destroy(hp);
        try hp.init(wb.gpa, &ci.hierarchy, .{ .ctx = wb, .open = onHierarchyOpen, .again = onHierarchyAgain });
        wb.hierarchy = hp;
    }

    /// Asks the hierarchy at the caret and shows the Hierarchy panel in
    /// the bottom area.
    fn showHierarchy(wb: *Workbench, dir: HierarchyService.Direction) !void {
        const ci = wb.codeintel orelse return wb.notify(.info, "Language services are not running", .{});
        const h = wb.currentHandle() orelse return wb.notify(.info, "No language server for this file", .{});
        const offset = wb.view.primarySel().head;
        const n = try ci.showHierarchy(h, offset, dir);
        const types = dir == .supertypes or dir == .subtypes;
        if (n == 0) return wb.notify(.info, "No language server provides {s} hierarchies for this file", .{if (types) "type" else "call"});
        wb.hierarchy_ask = .{ .h = h, .offset = offset };
        try wb.ensureHierarchy();
        if (wb.hierarchy_ref == null) wb.hierarchy_ref = try wb.dock.addPanel(kind_hierarchy, null);
        try wb.reveal(wb.hierarchy_ref.?, .bottom);
        if (wb.win) |w| w.markAllDirty();
    }

    /// `editor.showCallHierarchy` (Shift+Alt+H): who calls the symbol.
    fn showCallHierarchy(wb: *Workbench) !void {
        try wb.showHierarchy(.incoming);
    }

    fn showOutgoingCalls(wb: *Workbench) !void {
        try wb.showHierarchy(.outgoing);
    }

    fn showTypeHierarchy(wb: *Workbench) !void {
        try wb.showHierarchy(.supertypes);
    }

    fn showSubtypes(wb: *Workbench) !void {
        try wb.showHierarchy(.subtypes);
    }

    fn onHierarchyOpen(ctx: *anyopaque, t: NavService.Target, focus: bool) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.jumpTo(t);
        // A click shows the place; the tree keeps the keyboard.
        if (!focus) wb.pending_focus = false;
    }

    /// Refresh: the same position again, in the panel's direction.
    fn onHierarchyAgain(ctx: *anyopaque) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const a = wb.hierarchy_ask orelse return;
        const ci = wb.codeintel orelse return;
        const n = ci.showHierarchy(a.h, a.offset, ci.hierarchy.dir) catch 0;
        if (n == 0) wb.notify(.info, "The file is no longer open in a language server", .{});
    }

    /// The panel shows a problem: open its file at the next build, with
    /// the caret at its start.
    fn onProblemOpen(ctx: *anyopaque, key: []const u8, it: problems_panel.Problems.Item, focus: bool) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const copy = wb.gpa.dupe(u8, key) catch return;
        if (wb.pending_open) |old| wb.gpa.free(old);
        wb.pending_open = copy;
        wb.pending_virtual = false;
        wb.pending_focus = focus;
        wb.pending_explorer = false;
        wb.pending_goto = .{ .problem = it };
        if (wb.win) |w| w.markAllDirty();
    }

    /// Puts the current editor's caret at problem `it`'s start (its byte
    /// range mapped to the current text when it has one, else its line
    /// and UTF-16 column) and remembers its message for the status line.
    fn gotoProblem(wb: *Workbench, it: problems_panel.Problems.Item) void {
        const v = wb.view;
        const off: u64 = blk: {
            if (it.diag.bytes) |b| if (it.version) |ver| if (wb.doc.mapForward(ver, .{ .start = b.start, .end = b.start }, .right)) |r| break :blk r.start;
            const line = @min(@as(u64, it.diag.start.line), v.lineCount() - 1);
            const lr = v.lineRange(line);
            break :blk lr.start + zg_core.utf8.columnToByte(v.text(lr), it.diag.start.character, .utf16);
        };
        v.setSelection(.caret(off));
        v.revealPrimary();
        wb.problem_note.clearRetainingCapacity();
        const msg = it.diag.message[0 .. std.mem.indexOfScalar(u8, it.diag.message, '\n') orelse it.diag.message.len];
        wb.problem_note.print(wb.gpa, "{s}: {s}", .{ it.diag.severity.label(), msg }) catch {};
        wb.problem_note_at = off;
        if (wb.win) |w| w.markAllDirty();
    }

    /// The status line's note of the problem last gone to, while the
    /// caret stays there.
    fn problemNote(wb: *Workbench) ?[]const u8 {
        if (wb.problem_note.items.len == 0) return null;
        if (wb.view.primarySel().head != wb.problem_note_at) {
            wb.problem_note.clearRetainingCapacity();
            return null;
        }
        return wb.problem_note.items;
    }

    /// F8 and Shift+F8: the next or previous problem from the caret, in
    /// the Problems panel's order (wrapping across files; `in_file`:
    /// within the current file).
    fn stepProblem(wb: *Workbench, dir: problems_panel.Problems.Direction, in_file: bool) !void {
        try wb.ensureProblems();
        const pp = wb.problems orelse return wb.notify(.info, "Language services are not running", .{});
        _ = pp.refresh();
        if (pp.model.count() == 0) return wb.notify(.info, "No problems", .{});
        const ci = wb.codeintel.?;
        var key: []u8 = &.{};
        defer wb.gpa.free(key);
        if (wb.path) |path| {
            const abs = try std.fs.path.resolve(wb.gpa, &.{ wb.cwd, path });
            defer wb.gpa.free(abs);
            key = try ci.diags.keyOfPath(wb.gpa, abs);
        }
        const head = wb.view.primarySel().head;
        const line = wb.view.lineOf(head);
        const lr = wb.view.lineRange(line);
        const col = zg_core.utf8.byteToColumn(wb.view.text(lr), @intCast(head - lr.start), .utf16);
        const at: problems_panel.Problems.Pos = .{ .line = @intCast(line), .character = col };
        const l = pp.model.step(key, at, dir, in_file) orelse return wb.notify(.info, "No problems in this file", .{});
        pp.select(l);
        const it = pp.model.item(l);
        if (std.mem.eql(u8, pp.model.files.items[l.file].key, key)) return wb.gotoProblem(it);
        pp.show(l, true);
    }

    fn nextProblem(wb: *Workbench) !void {
        try wb.stepProblem(.next, false);
    }

    fn previousProblem(wb: *Workbench) !void {
        try wb.stepProblem(.prev, false);
    }

    fn nextProblemInFile(wb: *Workbench) !void {
        try wb.stepProblem(.next, true);
    }

    fn previousProblemInFile(wb: *Workbench) !void {
        try wb.stepProblem(.prev, true);
    }

    fn problemsOpen(wb: *Workbench) !void {
        const pp = wb.problems orelse return;
        if (pp.activeItem()) |l| pp.show(l, true);
    }

    fn problemsCopy(wb: *Workbench) !void {
        if (wb.problems) |pp| pp.copyActive(false);
    }

    fn problemsCopyMessage(wb: *Workbench) !void {
        if (wb.problems) |pp| pp.copyActive(true);
        if (wb.win) |w| w.markAllDirty();
    }

    // -- the git tab ---------------------------------------------------------

    /// How often the shown Git tab reads the repository again
    /// (`git.autoRefresh`), and fetches (`git.autofetch`).
    const scm_poll_ms = 3000;
    const scm_fetch_every_ms = 3 * 60 * 1000;

    fn ensureScm(wb: *Workbench) !void {
        if (wb.scm != null) return;
        const w = wb.win orelse return;
        const p = try ScmPanel.create(wb.gpa, wb.io, wb.rt, wb.env, wb.cwd, .{ .ctx = wb, .open = onScmOpen, .changed = onScmChanged });
        p.win = w;
        wb.scm = p;
        wb.applyScmSettings();
        wb.scm_fetch_ms = w.app.now_ms;
    }

    fn applyScmSettings(wb: *Workbench) void {
        const p = wb.scm orelse return;
        const st = wb.settings orelse return;
        const limit: u32 = @intCast(std.math.clamp(st.int("git.logLimit"), 10, 100_000));
        if (limit != p.log_limit) {
            p.log_limit = limit;
            p.refresh();
        }
        p.confirm_sync = st.boolean("git.confirmSync");
    }

    /// The Git tab, created and shown in the editor area.
    fn showScmPanel(wb: *Workbench) !*ScmPanel {
        try wb.ensureScm();
        if (wb.scm_ref == null) wb.scm_ref = try wb.dock.addPanel(kind_scm, null);
        try wb.reveal(wb.scm_ref.?, .center);
        if (wb.win) |w| w.markAllDirty();
        return wb.scm orelse error.NoWindow;
    }

    fn showScm(wb: *Workbench) !void {
        const p = try wb.showScmPanel();
        p.refresh();
    }

    /// Reads the repository again when the tab exists (`git.autoRefresh`).
    fn scmAutoRefresh(wb: *Workbench) void {
        const p = wb.scm orelse return;
        if (wb.settings) |st| if (!st.boolean("git.autoRefresh")) return;
        p.refresh();
    }

    /// The settings poll's tick: refreshes the shown tab and fetches.
    fn pollScm(wb: *Workbench, now_ms: u64) void {
        const p = wb.scm orelse return;
        const st = wb.settings orelse return;
        if (wb.shown(wb.scm_ref) and st.boolean("git.autoRefresh")) p.poll(now_ms, scm_poll_ms);
        if (st.boolean("git.autofetch") and now_ms -| wb.scm_fetch_ms >= scm_fetch_every_ms) {
            wb.scm_fetch_ms = now_ms;
            p.fetch();
        }
    }

    /// The tab's badge: how many files changed.
    fn scmBadge(wb: *Workbench) []const u8 {
        const p = wb.scm orelse return "";
        const s = p.snap orelse return "";
        if (s.status.entries.len == 0) return "";
        return std.fmt.bufPrint(&wb.scm_badge, "{d}", .{s.status.entries.len}) catch "";
    }

    fn onScmOpen(ctx: *anyopaque, abs: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const copy = wb.gpa.dupe(u8, abs) catch return;
        if (wb.pending_open) |old| wb.gpa.free(old);
        wb.pending_open = copy;
        wb.pending_virtual = false;
        wb.pending_focus = true;
        wb.pending_explorer = false;
        wb.pending_goto = null;
        wb.pending_range = null;
        if (wb.win) |w| w.markAllDirty();
    }

    /// A git command changed the working tree: open editors reload and
    /// the explorer shows new and deleted files.
    fn onScmChanged(ctx: *anyopaque) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.checkFiles();
        if (wb.explorer) |e| _ = e.refresh();
        if (wb.win) |w| w.markAllDirty();
    }

    fn scmRefresh(wb: *Workbench) !void {
        (try wb.showScmPanel()).refresh();
    }
    fn scmCommit(wb: *Workbench) !void {
        (try wb.showScmPanel()).commitNow(false);
    }
    fn scmCommitAll(wb: *Workbench) !void {
        (try wb.showScmPanel()).commitNow(true);
    }
    fn scmFetch(wb: *Workbench) !void {
        (try wb.showScmPanel()).fetch();
    }
    fn scmPull(wb: *Workbench) !void {
        (try wb.showScmPanel()).syncCmd(.pull);
    }
    fn scmPush(wb: *Workbench) !void {
        (try wb.showScmPanel()).syncCmd(.push);
    }
    fn scmSync(wb: *Workbench) !void {
        (try wb.showScmPanel()).syncCmd(.sync);
    }
    fn scmCheckout(wb: *Workbench) !void {
        const p = try wb.showScmPanel();
        p.tab = .branches;
    }

    fn scmStage(wb: *Workbench) !void {
        wb.scmCurrentFile("Stage", &.{ "add", "--" });
    }
    fn scmUnstage(wb: *Workbench) !void {
        wb.scmCurrentFile("Unstage", &.{ "restore", "--staged", "--" });
    }

    /// Runs `args` and the current editor's file through the Git tab.
    fn scmCurrentFile(wb: *Workbench, label: []const u8, args: []const []const u8) void {
        const path = wb.path orelse return wb.notify(.info, "{s}: the editor has no file", .{label});
        wb.ensureScm() catch return;
        const p = wb.scm orelse return;
        const abs = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, path }) catch return;
        defer wb.gpa.free(abs);
        var argv: [8][]const u8 = undefined;
        @memcpy(argv[0..args.len], args);
        argv[args.len] = abs;
        p.run(label, &.{argv[0 .. args.len + 1]});
    }

    // -- the explorer --------------------------------------------------------

    /// Whether `workbench.startupView` shows the explorer.
    fn startupExplorer(wb: *Workbench) bool {
        const st = wb.settings orelse return true;
        return std.mem.eql(u8, st.string("workbench.startupView"), "explorer");
    }

    /// The side area the explorer docks into (`workbench.sideBar.location`).
    fn explorerHome(wb: *Workbench) Area {
        const st = wb.settings orelse return .left;
        return if (std.mem.eql(u8, st.string("workbench.sideBar.location"), "right")) .right else .left;
    }

    fn ensureExplorer(wb: *Workbench) !void {
        if (wb.explorer != null) return;
        const e = try wb.gpa.create(ExplorerPanel);
        errdefer wb.gpa.destroy(e);
        try e.init(wb.gpa, wb.io, wb.cwd, .{ .ctx = wb, .open = onExplorerOpen, .moved = onExplorerMoved, .open_folder = onOpenFolder, .file_op = onExplorerFileOp });
        e.win = wb.win;
        wb.explorer = e;
        wb.applyExplorerSettings();
        // Reveal the current file at the next build.
        wb.revealed_panel = null;
        if (wb.win) |w| w.markAllDirty();
    }

    /// Shows the explorer in its side area (`focus`: and focuses its tree).
    fn showExplorerPanel(wb: *Workbench, focus: bool) !void {
        try wb.ensureExplorer();
        if (wb.explorer_ref == null) wb.explorer_ref = try wb.dock.addPanel(kind_explorer, null);
        try wb.reveal(wb.explorer_ref.?, wb.explorerHome());
        if (wb.win) |w| {
            w.markAllDirty();
            if (focus) w.afterNextFrame(.{ .ctx = wb, .f = focusExplorer });
        }
    }

    fn focusExplorer(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const e = wb.explorer orelse return;
        if (!e.tv.node.isNone() and w.store.valid(e.tv.node)) w.setFocus(e.tv.node, true);
    }

    fn showExplorer(wb: *Workbench) !void {
        try wb.showExplorerPanel(true);
    }

    /// Hides the explorer's side area, or shows the explorer.
    fn toggleSidebar(wb: *Workbench) !void {
        if (wb.shown(wb.explorer_ref) and wb.areaOf(wb.explorer_ref) != .center) {
            wb.conceal(wb.explorer_ref.?);
            if (wb.win) |w| if (!wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
            return;
        }
        try wb.showExplorerPanel(false);
    }

    /// Applies the files.* and explorer.* settings, and moves the
    /// explorer to the side `workbench.sideBar.location` names.
    fn applyExplorerSettings(wb: *Workbench) void {
        const e = wb.explorer orelse return;
        const st = wb.settings orelse return;
        var globs: [64][]const u8 = undefined;
        var n: usize = 0;
        if (st.get("files.exclude") == .object) for (st.get("files.exclude").object) |f| {
            if (n == globs.len) break;
            if (f.value == .bool and f.value.bool) {
                globs[n] = f.key;
                n += 1;
            }
        };
        const sort = std.meta.stringToEnum(fs_tree.SortOrder, st.string("explorer.sortOrder")) orelse .foldersFirst;
        e.setOptions(.{ .exclude = globs[0..n], .respect_gitignore = st.boolean("explorer.respectGitIgnore"), .sort = sort });
        e.confirm_delete = st.boolean("explorer.confirmDelete");
        if (wb.explorer_ref) |r| if (wb.areaOf(r)) |a| {
            const home = wb.explorerHome();
            if ((a == .left or a == .right) and a != home) {
                wb.dock.move(r, .{ .area = home }) catch {};
                wb.dock.areaVisible(home, true);
            }
        };
    }

    /// Selects the current editor's file in the explorer when it changes
    /// (`explorer.autoReveal`).
    fn autoReveal(wb: *Workbench) void {
        if (wb.cur_panel == wb.revealed_panel) return;
        wb.revealed_panel = wb.cur_panel;
        const e = wb.explorer orelse return;
        if (wb.settings) |st| if (!st.boolean("explorer.autoReveal")) return;
        const p = wb.path orelse return;
        const abs = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p }) catch return;
        defer wb.gpa.free(abs);
        e.reveal(abs);
    }

    /// The explorer opens a file: at the next build (it runs from event
    /// handling).
    fn onExplorerOpen(ctx: *anyopaque, abs: []const u8, focus: bool) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const copy = wb.gpa.dupe(u8, abs) catch return;
        if (wb.pending_open) |old| wb.gpa.free(old);
        wb.pending_open = copy;
        wb.pending_virtual = false;
        wb.pending_focus = focus;
        wb.pending_explorer = true;
        if (wb.win) |w| w.markAllDirty();
    }

    /// The explorer is about to create, rename or delete files, or has:
    /// language servers hear of it (LSP `workspace/will*Files` first,
    /// whose import updates are applied, then `did*Files`).
    fn onExplorerFileOp(ctx: *anyopaque, phase: ExplorerFileOp.Phase, kind: ExplorerFileOp.Kind, items: []const ExplorerFileOp.Item) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const ci = wb.codeintel orelse return;
        if (!ci.trusted) return;
        const hooks = &ci.file_hooks;
        var arena: std.heap.ArenaAllocator = .init(wb.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        switch (kind) {
            .rename => {
                const pairs = a.alloc(FileOpHooks.Pair, items.len) catch return;
                for (items, pairs) |it, *pr| pr.* = .{ .old = it.path, .new = it.new orelse it.path, .folder = it.folder };
                switch (phase) {
                    .will => hooks.willRename(pairs, ci.save_actions.clock()),
                    .did => hooks.didRename(pairs),
                }
            },
            .create, .delete => {
                const entries = a.alloc(FileOpHooks.Entry, items.len) catch return;
                for (items, entries) |it, *e| e.* = .{ .path = it.path, .folder = it.folder };
                const clk = ci.save_actions.clock();
                switch (phase) {
                    .will => if (kind == .create) hooks.willCreate(entries, clk) else hooks.willDelete(entries, clk),
                    .did => if (kind == .create) hooks.didCreate(entries) else hooks.didDelete(entries),
                }
            },
        }
        if (phase == .will) if (wb.win) |w| w.markAllDirty();
    }

    /// A file or folder was renamed, moved or deleted in the explorer:
    /// open editors of it follow (unsaved ones stay and say so).
    fn onExplorerMoved(ctx: *anyopaque, old: []const u8, new: ?[]const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        // Note links follow (before the editors reopen the files).
        if (wb.notes) |n| n.moved(old, new);
        var i: usize = 0;
        while (i < wb.files.items.len) {
            const f = &wb.files.items[i];
            const path = f.path orelse {
                i += 1;
                continue;
            };
            const abs = std.fs.path.resolve(wb.gpa, &.{ wb.cwd, path }) catch {
                i += 1;
                continue;
            };
            defer wb.gpa.free(abs);
            if (!fs_tree.startsWithPath(abs, old)) {
                i += 1;
                continue;
            }
            if (f.doc.isDirty()) {
                wb.notify(.warning, "{s} has unsaved changes: saving writes it back at its old path", .{std.fs.path.basename(abs)});
                i += 1;
                continue;
            }
            const panel = f.panel;
            const was_current = wb.cur_panel == panel;
            const moved_to = if (new) |n| std.mem.concat(wb.gpa, u8, &.{ n, abs[old.len..] }) catch null else null;
            defer if (moved_to) |m| wb.gpa.free(m);
            // Open the new path first: the last editor never closes.
            // (Opening may close the empty buffer: find the file again.)
            if (moved_to) |m| wb.openFile(m) catch {};
            i = for (wb.files.items, 0..) |x, k| {
                if (x.panel == panel) break k;
            } else continue;
            if (wb.files.items.len > 1) {
                wb.closeFileAt(i);
                if (!was_current) if (wb.cur_panel) |cp| if (wb.fileOf(cp)) |cf| wb.setCurrent(cf.*);
                continue;
            }
            i += 1;
        }
        if (wb.win) |w| w.markAllDirty();
    }

    /// Closes file `i`'s tab and frees it (another file stays open).
    fn closeFileAt(wb: *Workbench, i: usize) void {
        const f = wb.files.orderedRemove(i);
        wb.dock.close(f.panel) catch {};
        for (wb.dock.closed.items) |c| if (c.panel.state) |st| wb.gpa.free(st);
        wb.dock.closed.clearRetainingCapacity();
        const was_current = wb.cur_panel == f.panel;
        wb.closeFile(f);
        if (was_current) {
            const next = &wb.files.items[@min(i, wb.files.items.len - 1)];
            wb.showEditor(next) catch {};
            wb.setCurrent(next.*);
        }
    }

    /// The explorer, shown, for an explorer command.
    fn explorerFor(wb: *Workbench) ?*ExplorerPanel {
        if (!wb.shown(wb.explorer_ref)) wb.showExplorerPanel(false) catch return null;
        return wb.explorer;
    }

    fn explorerOpen(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.openActive();
    }
    fn explorerNewFile(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.startPrompt(.new_file);
    }
    fn explorerNewFolder(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.startPrompt(.new_folder);
    }
    fn explorerRename(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.startPrompt(.rename);
    }
    fn explorerDelete(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.deleteSelection();
    }
    fn explorerCopy(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.copySelection(false);
    }
    fn explorerCut(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.copySelection(true);
    }
    fn explorerPaste(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.paste();
    }
    fn explorerCopyPath(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.copyPath(false);
    }
    fn explorerCopyRelativePath(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.copyPath(true);
    }
    fn explorerRefresh(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| {
            _ = e.refresh();
            e.tree.revision +%= 1;
        }
    }
    fn explorerCollapseAll(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.collapseAll();
    }
    fn explorerRevealActive(wb: *Workbench) !void {
        const e = wb.explorerFor() orelse return;
        const p = wb.path orelse return;
        const abs = try std.fs.path.resolve(wb.gpa, &.{ wb.cwd, p });
        defer wb.gpa.free(abs);
        e.reveal(abs);
        if (wb.win) |w| w.afterNextFrame(.{ .ctx = wb, .f = focusExplorer });
    }
    fn workspaceAddFolder(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.startPrompt(.add_folder);
    }
    fn workspaceRemoveFolder(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.removeFolder();
    }

    /// Asks for a folder (in the explorer's prompt), then opens it in a
    /// new zigguro window.
    fn workspaceOpenFolder(wb: *Workbench) !void {
        if (wb.explorerFor()) |e| e.startPrompt(.open_folder);
    }

    fn onOpenFolder(ctx: *anyopaque, abs: []const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const exe = std.process.executablePathAlloc(wb.io, wb.gpa) catch |e| return wb.notify(.error_, "Could not start zigguro: {t}", .{e});
        defer wb.gpa.free(exe);
        _ = std.process.spawn(wb.io, .{ .argv = &.{ exe, abs }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |e|
            wb.notify(.error_, "Could not start zigguro: {t}", .{e});
    }

    // -- auto save -----------------------------------------------------------

    /// Runs the afterDelay timer while `files.autoSave` asks for it.
    fn armAutosave(wb: *Workbench) void {
        const w = wb.win orelse return;
        const st = wb.settings orelse return;
        if (!std.mem.eql(u8, st.string("files.autoSave"), "afterDelay")) {
            if (wb.autosave_timer != .none) w.cancelTimer(wb.autosave_timer);
            wb.autosave_timer = .none;
            return;
        }
        if (wb.autosave_timer != .none) return;
        const delay: u64 = @intCast(std.math.clamp(st.int("files.autoSaveDelay"), 100, 600_000));
        wb.autosave_timer = w.setTimer(w.app.now_ms + delay, .{ .ctx = wb, .f = autosaveTick }) catch .none;
    }

    /// Saves files that stayed dirty and unchanged since the last tick.
    fn autosaveTick(ctx: *anyopaque, _: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.autosave_timer = .none;
        for (wb.files.items) |*f| {
            if (f.sync == null or !f.doc.isDirty()) continue;
            if (f.doc.version != f.autosave_seen) {
                f.autosave_seen = f.doc.version;
                continue;
            }
            wb.quietSave(f);
        }
        wb.armAutosave();
    }

    /// `files.autoSave` = onFocusChange: the window lost focus.
    fn autosaveOnBlur(wb: *Workbench) void {
        const st = wb.settings orelse return;
        if (!std.mem.eql(u8, st.string("files.autoSave"), "onFocusChange")) return;
        for (wb.files.items) |*f| if (f.sync != null and f.doc.isDirty()) wb.quietSave(f);
    }

    /// Saves `f` without a toast unless it fails.
    fn quietSave(wb: *Workbench, f: *OpenFile) void {
        const fs = f.sync orelse return;
        if (f.doc.version == f.autosave_failed) return;
        wb.runSaveActions(f.doc, .AfterDelay);
        fs.save(.{}) catch return;
        wb.quiet_saves.append(wb.gpa, fs) catch {};
    }

    /// Whether `fs`'s save was a quiet one (forgotten once asked).
    fn takeQuiet(wb: *Workbench, fs: *FileSync) bool {
        for (wb.quiet_saves.items, 0..) |q, i| if (q == fs) {
            _ = wb.quiet_saves.swapRemove(i);
            return true;
        };
        return false;
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
        try wb.showTerminal(w);
    }

    /// Shows the terminal panel and focuses the active terminal.
    fn showTerminal(wb: *Workbench, w: *Window) !void {
        if (wb.terminal_ref == null) wb.terminal_ref = try wb.dock.addPanel(kind_terminal, null);
        try wb.reveal(wb.terminal_ref.?, .bottom);
        wb.focus_terminal = true;
        w.markAllDirty();
        w.afterNextFrame(.{ .ctx = wb, .f = focusTerminal });
    }

    /// The terminal the panel shows focused.
    pub fn activeTerminal(wb: *const Workbench) ?*TerminalPanel {
        return wb.terminals.get(wb.term_tabs.activeId() orelse return null);
    }

    /// Creates the first terminal and starts its shell, once: the
    /// terminals saved when the folder was last closed, else a new one.
    fn startTerminal(wb: *Workbench, w: *Window) !void {
        if (!wb.terminals_loaded) {
            wb.terminals_loaded = true;
            if (wb.terminals.count() == 0) wb.restoreTerminals(w);
        }
        if (wb.terminals.count() == 0) try wb.newTerminal(w, false);
    }

    fn persistentSessions(wb: *const Workbench) bool {
        const st = wb.settings orelse return true;
        return st.boolean("terminal.integrated.persistentSessions.enabled");
    }

    /// Reopens the terminals `saveTerminals` kept: their tabs and splits,
    /// what they showed (above a "Restored session" line) and a fresh
    /// shell in the folder each was in. Agent terminals come back as
    /// history only.
    fn restoreTerminals(wb: *Workbench, w: *Window) void {
        const dir = wb.layout_dir orelse return;
        if (!wb.persistentSessions()) return term_persist.remove(wb.io, dir);
        var snap = (term_persist.read(wb.gpa, wb.io, dir) catch null) orelse return;
        defer snap.deinit();
        var sep_buf: [128]u8 = undefined;
        const sep = term_persist.separator(&sep_buf, snap.saved_s);
        var group: ?u32 = null;
        for (snap.terminals) |*r| {
            const split = group != null and group.? == r.group;
            group = r.group;
            wb.openTerminal(w, split, .{ .record = r, .separator = sep }) catch |e| {
                log.warn("terminal {d} not restored: {t}", .{ r.id, e });
            };
        }
        if (wb.term_tabs.groups.items.len > 0) wb.term_tabs.active = 0;
    }

    /// Saves every terminal (`terminals.zgts` beside the layout) for
    /// `restoreTerminals`; with none open, or the setting off, deletes it.
    fn saveTerminals(wb: *Workbench) void {
        const dir = wb.layout_dir orelse return;
        if (!wb.terminals_loaded) return;
        if (!wb.persistentSessions() or wb.terminals.count() == 0) return term_persist.remove(wb.io, dir);
        var arena_state: std.heap.ArenaAllocator = .init(wb.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var recs: std.ArrayList(term_persist.TerminalRecord) = .empty;
        for (wb.term_tabs.groups.items, 0..) |g, gi| for (g.terminals.items) |id| {
            const t = wb.terminals.get(id) orelse continue;
            var content: std.ArrayList(u8) = .empty;
            term_persist.capture(arena, &t.term, if (t.view.blocks) |b| b else null, .{}, &content) catch continue;
            recs.append(arena, .{
                .id = id,
                .group = @intCast(gi),
                .cols = t.term.cols(),
                .rows = t.term.rows(),
                .owner = if (wb.term_tabs.sectionOf(id) == .agents) .agent else .user,
                .cwd = t.view.cwd.items,
                .title = t.term.title.items,
                .name = wb.term_tabs.nameOf(id) orelse "",
                .content = content.items,
            }) catch return;
        };
        const now: i64 = @intCast(@divFloor(std.Io.Clock.real.now(wb.io).nanoseconds, std.time.ns_per_s));
        term_persist.write(wb.gpa, wb.io, dir, &.{ .saved_s = now, .terminals = recs.items }) catch |e| log.warn("terminals not saved: {t}", .{e});
    }

    /// Creates a terminal and starts its shell: a new tab, or (`split`)
    /// beside the active terminal in its group.
    fn newTerminal(wb: *Workbench, w: *Window, split: bool) !void {
        return wb.openTerminal(w, split, null);
    }

    const Restore = struct { record: *const term_persist.TerminalRecord, separator: []const u8 };

    /// `newTerminal`, showing `restore`'s saved content first and
    /// starting the shell in its folder.
    fn openTerminal(wb: *Workbench, w: *Window, split: bool, restore: ?Restore) !void {
        const t = try TerminalPanel.create(wb.gpa, wb.io, w.app, wb.env);
        errdefer t.destroy();
        const id = wb.next_terminal;
        try wb.terminals.put(wb.gpa, id, t);
        errdefer _ = wb.terminals.swapRemove(id);
        const agent = if (restore) |r| r.record.owner == .agent else false;
        if (split and wb.term_tabs.activeId() != null)
            try wb.term_tabs.split(wb.term_tabs.activeId().?, id)
        else
            try wb.term_tabs.add(id, if (agent) .agents else .user);
        wb.next_terminal += 1;
        t.on_output = .{ .ctx = wb, .f = onTerminalOutput };
        t.view.on_open_link = .{ .ctx = wb, .f = onTerminalLink };
        if (restore) |r| {
            if (r.record.name.len > 0) wb.term_tabs.rename(id, r.record.name) catch {};
            t.view.feed(r.record.content);
            t.view.feed(r.separator);
            // History only: an agent's shell is not started again.
            if (agent) return t.setNote("saved agent terminal", .{});
            if (r.record.cwd.len > 0 and std.fs.path.isAbsolute(r.record.cwd) and exists(wb.io, r.record.cwd)) t.start_cwd = r.record.cwd;
        }
        defer t.start_cwd = null;
        const st = wb.settings orelse return t.start();
        var args: [32][]const u8 = undefined;
        var n: usize = 0;
        if (st.get("terminal.integrated.shellArgs") == .array) for (st.get("terminal.integrated.shellArgs").array) |a| {
            if (a != .string or n == args.len) continue;
            args[n] = a.string;
            n += 1;
        };
        t.shell_integration = st.boolean("terminal.integrated.shellIntegration.enabled");
        t.term.opts.graphics.allow_file_media = st.boolean("terminal.graphics.allowFileMedia");
        t.term.opts.graphics.sixel = st.boolean("terminal.graphics.sixel");
        t.startShell(st.string("terminal.integrated.shell"), args[0..n]);
    }

    fn focusTerminalCmd(wb: *Workbench) !void {
        const w = wb.win orelse return;
        try wb.startTerminal(w);
        try wb.showTerminal(w);
    }

    fn newTerminalCmd(wb: *Workbench) !void {
        const w = wb.win orelse return;
        try wb.newTerminal(w, false);
        try wb.showTerminal(w);
    }

    fn splitTerminal(wb: *Workbench) !void {
        const w = wb.win orelse return;
        try wb.newTerminal(w, true);
        try wb.showTerminal(w);
    }

    /// Ends the active terminal's shell and closes it; the panel hides
    /// with the last one.
    fn killTerminal(wb: *Workbench) !void {
        const id = wb.term_tabs.activeId() orelse return;
        wb.closeTerminal(id);
        try wb.afterTerminalClosed();
    }

    fn killAllTerminals(wb: *Workbench) !void {
        while (wb.term_tabs.activeId()) |id| wb.closeTerminal(id);
        try wb.afterTerminalClosed();
    }

    fn closeTerminal(wb: *Workbench, id: TerminalId) void {
        wb.term_tabs.remove(id);
        const kv = wb.terminals.fetchSwapRemove(id) orelse return;
        // The view's node gets a focus-lost event: move focus while the
        // view is still alive.
        if (wb.win) |w| if (!kv.value.view.node.isNone() and w.focus.eql(kv.value.view.node)) {
            w.setFocus(wb.editor_node, false);
            w.markAllDirty();
        };
        kv.value.destroy();
    }

    fn afterTerminalClosed(wb: *Workbench) !void {
        const w = wb.win orelse return;
        if (wb.terminals.count() > 0) return wb.showTerminal(w);
        if (wb.terminal_ref) |r| if (wb.areaOf(r) != .center) wb.conceal(r);
        if (!wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
        w.markAllDirty();
    }

    /// A Ctrl+clicked terminal link. Web links open in the browser; a
    /// local `file:` URI or a file reference that exists opens in the
    /// editor at its line and column (relative paths against the shell's
    /// folder, then the workspace); other links are copied.
    fn onTerminalLink(ctx: *anyopaque, v: *zg_terminal_view.TerminalView, target: zg_terminal_view.links.Target) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        switch (target) {
            .uri => |u| {
                if (std.ascii.startsWithIgnoreCase(u, "http://") or std.ascii.startsWithIgnoreCase(u, "https://")) {
                    if (wb.win) |w| w.openUri(u);
                    return;
                }
                if (std.ascii.startsWithIgnoreCase(u, "file://")) {
                    const rest = u["file://".len..];
                    const local = std.mem.startsWith(u8, rest, "/") or std.ascii.startsWithIgnoreCase(rest, "localhost/");
                    if (!local) return wb.notify(.warning, "Not opening {s}: it is on another machine", .{u});
                    const path = if (rest[0] == '/') rest else rest["localhost".len..];
                    return wb.openTerminalFile(v, .{ .path = path });
                }
                if (wb.win) |w| w.app.clipboard.set(wb.gpa, u);
                wb.notify(.info, "Copied {s} (only web and file links open)", .{u});
            },
            .file => |f| wb.openTerminalFile(v, f),
        }
    }

    fn openTerminalFile(wb: *Workbench, v: *zg_terminal_view.TerminalView, f: zg_terminal_view.links.Target.File) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const bases = [_][]const u8{ v.cwd.items, wb.cwd };
        const path: ?[]const u8 = if (std.fs.path.isAbsolute(f.path))
            (if (exists(wb.io, f.path)) f.path else null)
        else for (bases) |b| {
            if (b.len == 0) continue;
            const p = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ b, std.fs.path.sep, f.path }) catch continue;
            if (exists(wb.io, p)) break p;
        } else null;
        const abs = path orelse return wb.notify(.warning, "{s} was not found", .{f.path});
        wb.rememberHere();
        wb.openAt(abs, .{ .pos = .{ .line = (f.line orelse 1) -| 1, .character = (f.col orelse 1) -| 1, .enc = .utf8 } });
    }

    fn exists(io: std.Io, path: []const u8) bool {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }

    /// Opens the active terminal's find bar (seeded with the selected
    /// text) and focuses it.
    fn findInTerminal(wb: *Workbench) !void {
        const w = wb.win orelse return;
        try wb.startTerminal(w);
        const t = wb.activeTerminal() orelse return;
        const seed = t.view.selectionText(wb.gpa) catch null;
        defer if (seed) |s| wb.gpa.free(s);
        t.find.show(seed);
        if (t.find.field.len() > 0) t.find.refresh(&t.view);
        if (wb.terminal_ref == null) wb.terminal_ref = try wb.dock.addPanel(kind_terminal, null);
        try wb.reveal(wb.terminal_ref.?, .bottom);
        w.markAllDirty();
        w.afterNextFrame(.{ .ctx = wb, .f = focusFindField });
    }

    // -- command blocks (shell integration) --------------------------------

    fn blockNav(wb: *Workbench, comptime select: bool, dir: zg_terminal_view.TerminalView.Direction) !void {
        const t = wb.activeTerminal() orelse return;
        const moved = if (select) t.view.selectOutput(dir) else t.view.scrollToCommand(dir);
        if (!moved and t.view.blocks != null and t.view.blocks.?.items().len == 0)
            wb.notify(.info, "No commands yet: the shell does not report them (shell integration supports bash, zsh, fish and PowerShell).", .{});
        if (wb.win) |w| w.markAllDirty();
    }

    fn scrollToPrevCommand(wb: *Workbench) !void {
        try wb.blockNav(false, .previous);
    }

    fn scrollToNextCommand(wb: *Workbench) !void {
        try wb.blockNav(false, .next);
    }

    fn selectPrevOutput(wb: *Workbench) !void {
        try wb.blockNav(true, .previous);
    }

    fn selectNextOutput(wb: *Workbench) !void {
        try wb.blockNav(true, .next);
    }

    fn copyToClipboard(wb: *Workbench, text: []const u8) void {
        const w = wb.win orelse return;
        w.app.clipboard.set(wb.gpa, text);
    }

    fn copyLastCommand(wb: *Workbench) !void {
        const t = wb.activeTerminal() orelse return;
        const last = t.view.lastCommand() orelse return wb.notify(.info, "No command to copy yet.", .{});
        wb.copyToClipboard(t.view.blocks.?.commandText(last.id));
    }

    fn copyLastOutput(wb: *Workbench) !void {
        const t = wb.activeTerminal() orelse return;
        const last = t.view.lastCommand() orelse return wb.notify(.info, "No command output to copy yet.", .{});
        const text = try t.view.outputText(wb.gpa, last.id) orelse return wb.notify(.info, "The last command printed nothing.", .{});
        defer wb.gpa.free(text);
        wb.copyToClipboard(text);
    }

    fn rerunLastCommand(wb: *Workbench) !void {
        const t = wb.activeTerminal() orelse return;
        switch (t.view.rerunLast()) {
            .sent => {},
            .no_command => wb.notify(.info, "No command to run again yet.", .{}),
            .untrusted => wb.notify(.warning, "The last command line was not reported by the shell itself, so it is not run again automatically.", .{}),
            .busy => wb.notify(.info, "The shell is busy or something is typed at the prompt.", .{}),
        }
    }

    fn focusFindField(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const t = wb.activeTerminal() orelse return;
        if (!t.find.focus_pending or t.find.field_node.isNone()) return;
        t.find.focus_pending = false;
        w.setFocus(t.find.field_node, false);
    }

    fn focusNextTerminal(wb: *Workbench) !void {
        const w = wb.win orelse return;
        _ = wb.term_tabs.focusNext(.next) orelse return;
        try wb.showTerminal(w);
    }

    fn focusPreviousTerminal(wb: *Workbench) !void {
        const w = wb.win orelse return;
        _ = wb.term_tabs.focusNext(.prev) orelse return;
        try wb.showTerminal(w);
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
        const host = try AgentHost.create(wb.rt, wb.env, w.app, &wb.docs, &wb.approvals);
        errdefer host.destroy();
        host.files.on_edit = .{ .ctx = wb, .f = onAgentEdit };
        // Edit results carry the language servers' diagnostics.
        if (wb.codeintel) |ci| {
            host.file_tools.diagnostics = ci.agentDiagnostics();
            host.addLanguageTools(ci.agentTools()) catch |e| log.warn("language tools: {t}", .{e});
        }
        // list_dir, glob, find_files and grep over the folder.
        if (wb.ws_tools == null) wb.ws_tools = WorkspaceTools.create(wb.gpa, wb.io, wb.cwd) catch |e| blk: {
            log.warn("workspace tools: {t}", .{e});
            break :blk null;
        };
        if (wb.ws_tools) |x| host.addWorkspaceTools(x.exporter()) catch |e| log.warn("workspace tools: {t}", .{e});
        // The notes tools (the folder's notes are scanned from now on).
        if (wb.ensureNotes()) {
            host.addNotesTools(wb.notes.?.agentTools()) catch |e| log.warn("notes tools: {t}", .{e});
        } else |e| log.warn("notes: {t}", .{e});
        const pe = try wb.gpa.create(PendingEdits);
        pe.* = .init(wb.gpa, .{ .ctx = wb, .view = viewOfDoc, .store = decoOfDoc });
        pe.on_change = .{ .ctx = wb, .f = onPendingChange };
        wb.pending_edits = pe;
        host.files.bindPending(pe);
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
        // The session's approvals also show in the pane.
        p.approvals = PaneApprovals.create(wb.gpa, w.app, &wb.approvals, host.agent.ref.session) catch |e| blk: {
            log.err("agent pane approvals: {t}", .{e});
            break :blk null;
        };
        p.attachChildren(&host.children);
        // Rewinding code goes through E12's checkpoints.
        p.restore = host.review.restore();
        if (wb.agent_cmds) |c| {
            c.target = .{ .agent = host.agent, .plan_mode = &host.plan_mode, .agent_tools = &host.agent_tools, .subagents = host.subagents.defs, .context = &host.context };
            p.commands = c;
        }
        host.plans.on_change = .{ .ctx = wb, .f = onTerminalOutput };
        host.mcp.broker = wb.mcp_input.broker();
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
        p.inbox = wb.approvals_inbox;
        wb.review_panel = p;
        wb.review_timer = w.setTimer(w.app.now_ms + review_poll_ms, .{ .ctx = wb, .f = pollReview }) catch .none;
    }

    /// Shows the review queue, whose top lists the approvals.
    pub fn showApprovals(wb: *Workbench) !void {
        if (wb.shown(wb.review_ref) and wb.areaOf(wb.review_ref) != .center) return;
        try wb.toggleReview();
    }

    /// A request waits for approval (UI thread).
    fn onApprovalPending(ctx: *anyopaque) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.showApprovals() catch |e| log.err("approvals: cannot show the review queue: {t}", .{e});
        if (wb.win) |w| w.markAllDirty();
    }

    /// Takes in what `zg review` or another window decided, then polls
    /// again.
    fn pollReview(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        wb.review_timer = .none;
        const host = wb.agent orelse return;
        if (host.review.refresh()) w.markAllDirty();
        // Accepted review changes land on disk: open files pick them up
        // (a stat per file when nothing changed).
        wb.checkFiles();
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
    /// The editor of an open document (`PendingEdits`).
    fn viewOfDoc(ctx: *anyopaque, h: zg_editor.model.api.registry.DocHandle) ?*EditorView {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        for (wb.files.items) |f| if (f.handle) |fh| if (std.meta.eql(fh, h)) return f.view;
        return null;
    }

    /// The decoration store of an open document's editor (`PendingEdits`).
    fn decoOfDoc(ctx: *anyopaque, h: zg_editor.model.api.registry.DocHandle) ?*zg_editor.model.decorations.store.DecorationStore {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        for (wb.files.items) |*f| if (f.handle) |fh| if (std.meta.eql(fh, h)) return wb.ensureDeco(f) catch null;
        return null;
    }

    fn onPendingChange(ctx: *anyopaque) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    /// Turns inline review of agent edits on or off (this session).
    fn toggleInlineReview(wb: *Workbench) !void {
        const w = wb.win orelse return;
        try wb.startAgent(w);
        const host = wb.agent orelse return;
        host.files.inline_review = !host.files.inline_review;
        if (host.files.inline_review)
            wb.notify(.info, "Agent edits to open files now wait in the editor: Accept or Reject Agent Change at the cursor", .{})
        else
            wb.notify(.info, "Agent edits to open files apply directly again", .{});
    }

    fn pendingResult(wb: *Workbench, res: PendingEdits.Result) void {
        switch (res) {
            .done => {},
            .none => wb.notify(.info, "No agent change in this file", .{}),
            .conflicted => wb.notify(.warning, "You changed this text since the agent's edit: reject the change or ask the agent again", .{}),
        }
    }

    fn acceptAgentChange(wb: *Workbench) !void {
        const pe = wb.pending_edits orelse return wb.pendingResult(.none);
        wb.pendingResult(pe.acceptAt(wb.view));
    }

    fn rejectAgentChange(wb: *Workbench) !void {
        const pe = wb.pending_edits orelse return wb.pendingResult(.none);
        wb.pendingResult(pe.rejectAt(wb.view));
    }

    fn acceptAllAgentChanges(wb: *Workbench) !void {
        const pe = wb.pending_edits orelse return wb.pendingResult(.none);
        wb.pendingResult(pe.acceptAll(wb.view));
    }

    fn rejectAllAgentChanges(wb: *Workbench) !void {
        const pe = wb.pending_edits orelse return wb.pendingResult(.none);
        wb.pendingResult(pe.rejectAll(wb.view));
    }

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
        // Restricted workspace settings (shells, executables) apply.
        if (wb.settings) |st| st.setTrusted(wb.trust == .trusted);
        // A trusted folder's MCP servers may start.
        if (wb.trust == .trusted) if (wb.agent) |a| a.connectMcp(wb.rt, wb.env);
        // So may its language servers.
        if (wb.codeintel) |ci| ci.setTrusted(wb.trust == .trusted);
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

    fn onViewChange(ctx: *anyopaque, v: *EditorView) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        for (wb.files.items) |f| if (f.view == v) if (f.completions) |c| c.onCaret();
        if (wb.win) |w| w.markAllDirty();
    }

    pub fn build(wb: *Workbench, ui: *Ui) void {
        if (wb.inline_edit) |h| if (h.done) {
            h.destroy();
            wb.inline_edit = null;
            // An accepted or rejected inline edit goes to the review store.
            wb.flushReview();
        };
        // Back in the window: files may have changed on disk.
        const focused = ui.win.chrome.focused;
        if (focused and !wb.was_focused) {
            wb.checkFiles();
            wb.reloadSettings();
            wb.scmAutoRefresh();
        }
        if (!focused and wb.was_focused) wb.autosaveOnBlur();
        wb.was_focused = focused;
        if (wb.pending_open) |p| {
            wb.pending_open = null;
            defer wb.gpa.free(p);
            const focus = wb.pending_focus;
            const from_explorer = wb.pending_explorer;
            wb.pending_focus = true;
            wb.pending_explorer = false;
            const goto = wb.pending_goto;
            wb.pending_goto = null;
            const range = wb.pending_range;
            wb.pending_range = null;
            const virtual = wb.pending_virtual;
            wb.pending_virtual = false;
            if (if (virtual) wb.openVirtual(p) else if (from_explorer) wb.openFromExplorer(p, focus) else wb.openFile(p)) {
                if (virtual) if (goto) |g| if (wb.cur_panel) |cp| if (wb.fileOf(cp)) |f| {
                    // The text may still be on its way.
                    f.virtual_goto = g;
                    wb.virtualGoto();
                };
                if (!virtual) if (goto) |g| switch (g) {
                    .problem => |it| wb.gotoProblem(it),
                    .pos => |p_| wb.gotoPos(p_.line, p_.character, p_.enc),
                    .offset => |o| wb.gotoOffset(o),
                };
                if (range) |r| wb.selectBytes(r);
                if (focus) ui.win.afterNextFrame(.{ .ctx = wb, .f = focusOpened });
            } else |e| wb.notify(.error_, "Could not open {s}: {t}", .{ std.fs.path.basename(p), e });
        }
        wb.virtualGoto();
        wb.followFocus();
        wb.autoReveal();
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
        if (wb.codeintel) |ci| ci.frame(wb.currentHandle(), wb.view);
        if (wb.persister) |*p| if (wb.dock.revision != wb.layout_rev and !wb.layout_final) {
            wb.layout_rev = wb.dock.revision;
            p.markDirty();
        };
    }

    /// The current editor's document, when it has a path.
    fn currentHandle(wb: *Workbench) ?zg_editor.model.api.registry.DocHandle {
        const cp = wb.cur_panel orelse return null;
        const f = wb.fileOf(cp) orelse return null;
        return f.handle;
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
            .title = if (f.path) |path| std.fs.path.basename(path) else if (f.virtual) |vh| wb.docs.name(vh) orelse "Untitled" else "Untitled",
            .dirty = f.doc.isDirty(),
            .tooltip = f.path orelse if (f.virtual) |vh| wb.docs.uri(vh) else null,
        };
        return switch (wb.kindOf(p) orelse 0) {
            kind_terminal => .{ .title = "Terminal", .badge = if (wb.activeTerminal()) |t| t.noteText() else "" },
            kind_agent => .{ .title = "Agent" },
            kind_review => .{ .title = "Review", .badge = if (wb.review_panel) |r| r.badge(&wb.review_badge) else "" },
            kind_review_view => .{ .title = if (wb.review_view) |v| v.title else "Review" },
            kind_settings => .{ .title = "Settings" },
            kind_explorer => .{ .title = "Explorer" },
            kind_problems => .{ .title = "Problems", .badge = wb.problemsBadge() },
            kind_notes => .{ .title = "Notes" },
            kind_notes_search => .{ .title = "Search Notes" },
            kind_scm => .{ .title = "Git", .badge = wb.scmBadge() },
            kind_hierarchy => .{ .title = "Hierarchy" },
            else => .{ .title = "?" },
        };
    }

    fn panelBuild(ctx: *anyopaque, ui: *Ui, p: PanelRef) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.fileOf(p)) |f| {
            ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "editorFocus editorTextFocus" });
            defer ui.close();
            _ = zg_editor.view.editor(ui, .{ .view = f.view, .a11y_label = f.path orelse "Untitled" });
            const editor_node = ui.lastNode();
            if (wb.inline_edit) |h| if (h.view == f.view and ui.window() == wb.win) h.build(ui);
            // Focus helpers act on the main window's nodes only.
            f.node = if (ui.window() == wb.win) editor_node else .none;
            return;
        }
        switch (wb.kindOf(p) orelse 0) {
            kind_terminal => wb.terminalPanel(ui),
            kind_agent => if (wb.agent_panel) |a| {
                ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "agentPaneFocus" });
                defer ui.close();
                a.build(ui);
            },
            kind_review => if (wb.review_panel) |r| r.build(ui),
            kind_review_view => if (wb.review_view) |v| v.build(ui),
            kind_settings => {
                // A restored layout shows the tab before anything opened it.
                wb.ensureSettingsView() catch {};
                if (wb.settings_view) |v| v.build(ui);
            },
            kind_explorer => {
                wb.ensureExplorer() catch {};
                if (wb.explorer) |e| e.build(ui);
            },
            kind_problems => {
                wb.ensureProblems() catch {};
                if (wb.problems) |pp| pp.build(ui) else {
                    ui.open(.{ .style = .{ .padding = .xy(12, 6) } });
                    ui.text("Language services are not running.", .{ .color = .fg_muted });
                    ui.close();
                }
            },
            kind_notes, kind_notes_search => wb.notesPanel(ui, wb.kindOf(p) == kind_notes_search),
            kind_scm => {
                wb.ensureScm() catch |e| log.warn("git tab: {t}", .{e});
                if (wb.scm) |g| g.build(ui);
            },
            kind_hierarchy => {
                wb.ensureHierarchy() catch {};
                if (wb.hierarchy) |hp| hp.build(ui) else {
                    ui.open(.{ .style = .{ .padding = .xy(12, 6) } });
                    ui.text("Language services are not running.", .{ .color = .fg_muted });
                    ui.close();
                }
            },
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
        if (p == wb.settings_ref) {
            wb.settings_ref = null;
            return true;
        }
        if (p == wb.scm_ref) {
            if (wb.areaOf(p)) |a| if (a != .center) {
                wb.dock.areaVisible(a, false);
                return false;
            };
            wb.scm_ref = null;
            return true;
        }
        if (p == wb.terminal_ref or p == wb.agent_ref or p == wb.review_ref or p == wb.explorer_ref or p == wb.problems_ref or p == wb.hierarchy_ref or p == wb.notes_ref or p == wb.notes_search_ref) {
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
            .{ .id = "explorer", .label = "Explorer", .tooltip = "Show Explorer (Ctrl+Shift+E)", .action = "workbench.toggleSidebar", .toggled = wb.shown(wb.explorer_ref), .priority = 30 },
            .{ .id = "git", .label = "Git", .tooltip = "Show Git (Ctrl+Shift+G)", .action = "workbench.showScm", .toggled = wb.scm_ref != null and wb.shown(wb.scm_ref), .priority = 25 },
            .{ .id = "settings", .label = "Settings", .tooltip = "Open Settings (Ctrl+,)", .action = "workbench.openSettings", .priority = 2, .toggled = if (wb.settings_ref) |r| wb.dock.groupOf(r) != null else false },
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

    const TermClick = union(enum) { select: TerminalId, new, split, kill };

    /// A terminal's tab label: its rename, its title, else "Terminal N".
    fn terminalLabel(wb: *const Workbench, ui: *Ui, id: TerminalId) []const u8 {
        if (wb.term_tabs.nameOf(id)) |n| return n;
        if (wb.terminals.get(id)) |t| if (t.term.title.items.len > 0) return t.term.title.items;
        return std.fmt.allocPrint(ui.arena(), "Terminal {d}", .{id}) catch "Terminal";
    }

    /// The tab strip (one tab per group; New, Split, Kill), then the
    /// active group's terminals side by side.
    fn terminalPanel(wb: *Workbench, ui: *Ui) void {
        const main = ui.window() == wb.win;
        // Clicking into a split terminal makes it the active one (unless a
        // command just picked another and focus has yet to follow).
        if (main and !wb.focus_terminal) if (wb.term_tabs.activeGroup()) |g| for (g.terminals.items) |id| {
            const t = wb.terminals.get(id) orelse continue;
            if (!t.view.node.isNone() and ui.window().focus.eql(t.view.node)) wb.term_tabs.select(id);
        };
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .bg = .{ .token = .bg_elevated } } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .gap = 4, .padding = .xy(6, 2), .shrink = 0, .align_items = .center }, .role = .tablist, .label = "Terminals" });
        for (wb.term_tabs.groups.items, 0..) |g, gi| {
            var label: std.ArrayList(u8) = .empty;
            for (g.terminals.items, 0..) |id, i| {
                if (i > 0) label.appendSlice(ui.arena(), " | ") catch {};
                label.appendSlice(ui.arena(), wb.terminalLabel(ui, id)) catch {};
            }
            ui.id(g.id);
            const active = gi == wb.term_tabs.active;
            if (zg_gui.w.button(ui, .{ .label = label.items, .variant = if (active) .primary else .ghost }).clicked)
                wb.clickTerminal(ui, .{ .select = g.activeId() });
        }
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (wb.activeTerminal()) |t| if (t.noteText().len > 0) ui.text(t.noteText(), .{ .color = .warning, .wrap = false });
        if (zg_gui.w.button(ui, .{ .label = "New", .variant = .ghost }).clicked) wb.clickTerminal(ui, .new);
        if (zg_gui.w.button(ui, .{ .label = "Split", .variant = .ghost }).clicked) wb.clickTerminal(ui, .split);
        if (zg_gui.w.button(ui, .{ .label = "Kill", .variant = .ghost, .disabled = wb.terminals.count() == 0 }).clicked) wb.clickTerminal(ui, .kill);
        ui.close();

        if (main) wb.terminal_node = .none;
        const g = wb.term_tabs.activeGroup() orelse return;
        // The active terminal's find bar; closing it gives focus back.
        if (wb.activeTerminal()) |t| {
            if (t.find.open) zg_terminal_view.find_bar.findBar(ui, &t.find, &t.view);
            if (t.find.closed and main) {
                t.find.closed = false;
                wb.focus_terminal = true;
                ui.window().afterNextFrame(.{ .ctx = wb, .f = focusTerminal });
            }
        }
        ui.open(.{ .style = .{ .dir = .row, .grow = 1, .basis = .{ .px = 0 }, .gap = 1, .align_items = .stretch } });
        defer ui.close();
        for (g.terminals.items) |id| {
            const t = wb.terminals.get(id) orelse continue;
            ui.id(id);
            ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .bg = .{ .token = .bg_base } } });
            defer ui.close();
            _ = zg_terminal_view.terminal(ui, .{ .view = &t.view, .a11y_label = wb.terminalLabel(ui, id) });
            if (main and id == g.activeId()) wb.terminal_node = t.view.node;
        }
    }

    /// Runs a tab strip click once the frame is built (it may add or close
    /// terminals, and hide the panel).
    fn clickTerminal(wb: *Workbench, ui: *Ui, c: TermClick) void {
        wb.term_click = c;
        ui.window().afterNextFrame(.{ .ctx = wb, .f = runTermClick });
    }

    fn runTermClick(ctx: *anyopaque, _: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const c = wb.term_click orelse return;
        wb.term_click = null;
        const r = switch (c) {
            .select => |id| blk: {
                wb.term_tabs.select(id);
                break :blk wb.focusTerminalCmd();
            },
            .new => wb.newTerminalCmd(),
            .split => wb.splitTerminal(),
            .kill => wb.killTerminal(),
        };
        r catch |e| wb.notify(.error_, "Terminal: {t}", .{e});
    }

    fn statusBar(wb: *Workbench, ui: *Ui) void {
        const name = if (wb.path) |p| std.fs.path.basename(p) else "Untitled";
        const head = wb.view.primarySel().head;
        const line = wb.view.lineOf(head);
        const col = head - wb.view.lineRange(line).start;
        const pos = if (wb.view.selections().len > 1)
            std.fmt.bufPrint(&wb.pos_text, "Ln {d}, Col {d} ({d} selections)", .{ line + 1, col + 1, wb.view.selections().len }) catch ""
        else
            std.fmt.bufPrint(&wb.pos_text, "Ln {d}, Col {d}", .{ line + 1, col + 1 }) catch "";
        var items: [16]zg_gui.w.StatusItem = undefined;
        var n: usize = 0;
        items[n] = .{ .id = "file", .text = if (wb.doc.isDirty()) "" else name, .priority = 1000 };
        n += 1;
        items[n] = .{ .id = "position", .text = pos, .priority = 100 };
        n += 1;
        if (wb.view.mode != null) {
            const ms = wb.view.modeStatus();
            const emacs = wb.key_mode == .emacs;
            items[n] = .{
                .id = "mode",
                .text = if (ms.len > 0) ms else if (emacs) "Emacs" else "Vim",
                .priority = 200,
                .tooltip = if (emacs) "Emacs keys are on: Toggle Emacs Mode turns them off" else "Vim keys are on: Toggle Vim Mode turns them off",
                .action = if (emacs) "editor.toggleEmacs" else "editor.toggleVim",
            };
            n += 1;
        }
        if (wb.trust != .trusted) {
            items[n] = .{ .id = "trust", .text = "Restricted Mode", .side = .right, .priority = 900, .tone = .warning, .tooltip = "This folder is not trusted: click to manage workspace trust", .action = "workspace.manageTrust" };
            n += 1;
        }
        if (wb.syntax) |sx| {
            items[n] = .{ .id = "language", .text = sx.lang.name, .side = .right, .priority = 50 };
            n += 1;
        }
        var probs_buf: [48]u8 = undefined;
        if (wb.codeintel) |ci| {
            const tot = problems_panel.Problems.totals(&ci.diags);
            items[n] = .{ .id = "problems", .text = std.fmt.bufPrint(&probs_buf, "\u{2297} {d}  \u{26a0} {d}", .{ tot[0], tot[1] }) catch "", .priority = 90, .tooltip = "Errors and warnings: click to show Problems", .action = "workbench.showProblems" };
            n += 1;
        }
        if (wb.problemNote()) |note| {
            items[n] = .{ .id = "problem.note", .text = note, .priority = 80 };
            n += 1;
        }
        var ab: [32]u8 = undefined;
        const waiting = wb.approvals.pendingCount(.{});
        if (waiting > 0) {
            items[n] = .{ .id = "approvals", .text = std.fmt.bufPrint(&ab, "\u{2691} {d} approval{s}", .{ waiting, if (waiting == 1) "" else "s" }) catch "", .side = .right, .priority = 950, .tone = .warning, .tooltip = "Requests wait for your approval: click to show them", .action = "review.approvals.open" };
            n += 1;
        }
        var pb: [32]u8 = undefined;
        const pending = if (wb.pending_edits) |pe| pe.count() else 0;
        if (pending > 0) {
            items[n] = .{ .id = "agent.pending", .text = std.fmt.bufPrint(&pb, "{d} agent change{s}", .{ pending, if (pending == 1) "" else "s" }) catch "", .side = .right, .priority = 940, .tone = .warning, .tooltip = "Agent edits wait in the editor: click to accept the one at the cursor", .action = "agent.acceptChange" };
            n += 1;
        }
        if (wb.curCompletions()) |c| {
            items[n] = .{ .id = "completions", .text = c.statusText(), .side = .right, .priority = 40, .tooltip = "Inline completions: click to turn them on or off", .action = "completions.toggle" };
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

test "workbench: undo history survives the session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "abc\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.txt" });
    defer gpa.free(a);
    const state = try std.fs.path.join(gpa, &.{ root, "state" });
    defer gpa.free(state);

    {
        var wb: Workbench = undefined;
        try wb.init(&rt, &env, a);
        defer wb.deinit();
        wb.enableUndoFiles(state);
        const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 600 }, .root = .of(&wb) });
        defer t.deinit();
        try wb.attach(t.win);
        defer wb.detach();
        _ = t.settle();
        t.typeText("x");
        _ = t.settle();
        try std.testing.expect(wb.doc.isDirty());
        try wb.save();
        _ = t.settle();
        try std.testing.expect(!wb.doc.isDirty());
    }
    {
        var wb: Workbench = undefined;
        try wb.init(&rt, &env, a);
        defer wb.deinit();
        try std.testing.expect(!wb.files.items[0].view.undo.canUndo());
        wb.enableUndoFiles(state);
        const u = &wb.files.items[0].view.undo;
        try std.testing.expect(u.canUndo());
        try std.testing.expect(u.isAtSaved());
    }
}

test "workbench: the gutter shows edits against the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.txt" });
    defer gpa.free(a);

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, a);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 600 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    const m = wb.files.items[0].diff.?;
    // The full diff's message, as the mailbox would deliver it.
    Workbench.onAppMessage(&wb, &t.app, .{ .kind = diff_model.ui_msg_kind, .a = @intFromPtr(m) });
    try std.testing.expect(!m.fullPending());
    try std.testing.expect(wb.view.scm != null);
    try std.testing.expectEqual(@as(usize, 0), m.hunks().len);
    _ = t.settle();
    t.typeText("x");
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 1), m.hunks().len);
    try wb.save();
    _ = t.settle();
    Workbench.onAppMessage(&wb, &t.app, .{ .kind = diff_model.ui_msg_kind, .a = @intFromPtr(m) });
    try std.testing.expectEqual(@as(usize, 0), m.hunks().len);
}

test "workbench: the saved window size leaves out decoration margins" {
    const gpa = std.testing.allocator;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var wb: Workbench = undefined;
    try wb.init(&rt, &env, null);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 600 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    t.win.chrome.client = true;
    t.win.chrome.margins_px = .{ 12, 12, 12, 12 };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const file = try Workbench.layoutSnapshot(&wb, arena.allocator());
    try std.testing.expectEqual(@as(i32, 876), file.windows[0].rect[2]);
    try std.testing.expectEqual(@as(i32, 576), file.windows[0].rect[3]);
}

test "workbench: Vim mode toggles for every editor and shows its mode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "abc\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.txt" });
    defer gpa.free(a);

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, a);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 600 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();
    try Workbench.toggleVim(&wb);
    _ = t.settle();
    try std.testing.expect(wb.view.mode != null);
    try std.testing.expect(t.find(.{ .name = "Vim" }) != null);
    try t.click(.{ .role = .textbox });
    wb.view.setSelection(.caret(0));
    t.typeText("i");
    _ = t.settle();
    try std.testing.expect(t.find(.{ .name = "-- INSERT --" }) != null);
    t.typeText("z");
    _ = t.settle();
    const text = try wb.view.allText(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("zabc\n", text);
    try Workbench.toggleVim(&wb);
    try std.testing.expect(wb.view.mode == null);
    try std.testing.expect(wb.files.items[0].vim_state == null);
}

test "workbench: Vim and Emacs reach files, editors and the clipboard" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "abc\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "bee\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.txt" });
    defer gpa.free(a);

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, a);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 600 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();
    try Workbench.toggleVim(&wb);
    _ = t.settle();
    try t.click(.{ .role = .textbox });
    wb.view.setSelection(.caret(0));

    // "+yy copies the line to the system clipboard.
    t.typeText("\"+yy");
    _ = t.settle();
    try std.testing.expectEqualStrings("abc\n", t.app.clipboard.get());

    // :q refuses unsaved changes; :e opens another file; :q closes it.
    t.typeText("x");
    _ = t.settle();
    t.typeText(":q");
    t.press(.enter, .{});
    _ = t.settle();
    try std.testing.expect(t.find(.{ .name_contains = "unsaved changes" }) != null);
    try std.testing.expectEqual(@as(usize, 1), wb.files.items.len);
    t.typeText(":e b.txt");
    t.press(.enter, .{});
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 2), wb.files.items.len);
    try std.testing.expectEqualStrings("b.txt", std.fs.path.basename(wb.path.?));
    // Both editors share registers.
    try std.testing.expect(wb.files.items[1].vim_state.?.shared == wb.vim_shared.?);
    try t.click(.{ .role = .textbox });
    t.typeText(":q");
    t.press(.enter, .{});
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 1), wb.files.items.len);
    try std.testing.expectEqualStrings("a.txt", std.fs.path.basename(wb.path.?));

    // Emacs: the toggle replaces Vim, the layer joins the keymap, and a
    // kill reaches the clipboard.
    try Workbench.toggleEmacs(&wb);
    _ = t.settle();
    try std.testing.expect(wb.files.items[0].vim_state == null);
    try std.testing.expect(wb.files.items[0].emacs_state != null);
    try std.testing.expect(wb.emacs_layer != null);
    try std.testing.expect(t.find(.{ .name = "Emacs" }) != null);
    try t.click(.{ .role = .textbox });
    wb.view.setSelection(.caret(0));
    t.press(.key_k, .{ .ctrl = true });
    _ = t.settle();
    try std.testing.expectEqualStrings("bc", t.app.clipboard.get());
    try Workbench.toggleEmacs(&wb);
    _ = t.settle();
    try std.testing.expect(wb.view.mode == null);
}

test "workbench: F8 goes through problems across files; the Problems panel and status line show them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const a = 1;\nconst x = é2;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const b = 2;\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.zig" });
    defer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ root, "b.zig" });
    defer gpa.free(b);

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, a);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 600 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();

    // As if a server reported them (no byte ranges: line and UTF-16
    // column; the é is one UTF-16 unit, two bytes).
    const Store = zg_codeintel.diagnostics.Store;
    const st = &wb.codeintel.?.diags;
    const o: Store.Owner = .{ .server = 0 };
    inline for (.{ .{ a, 1, 11, "unexpected token" }, .{ b, 0, 6, "unused b" } }) |d| {
        const set = try Store.Set.create(gpa, o);
        set.diags = try set.allocator().dupe(Store.Diagnostic, &.{.{ .start = .{ .line = d[1], .character = d[2] }, .end = .{ .line = d[1], .character = d[2] + 1 }, .message = d[3], .source = "zls" }});
        set.finish();
        const key = try st.keyOfPath(gpa, d[0]);
        defer gpa.free(key);
        try st.replace(key, o, set);
    }
    st.commit();
    t.win.markAllDirty();
    _ = t.settle();
    try std.testing.expect(t.find(.{ .name = "\u{2297} 2  \u{26a0} 0" }) != null);

    wb.view.setSelection(.caret(0));
    try Workbench.nextProblem(&wb);
    // Line 2, after "const x = é" (12 bytes).
    try std.testing.expectEqual(@as(u64, 13 + 12), wb.view.primarySel().head);
    _ = t.settle();
    try std.testing.expect(t.find(.{ .name = "error: unexpected token" }) != null);
    // On to the next file, opened with the caret at its problem.
    try Workbench.nextProblem(&wb);
    _ = t.settle();
    try std.testing.expectEqualStrings("b.zig", std.fs.path.basename(wb.path.?));
    try std.testing.expectEqual(@as(u64, 6), wb.view.primarySel().head);
    // And around, backwards.
    try Workbench.previousProblem(&wb);
    _ = t.settle();
    try std.testing.expectEqualStrings("a.zig", std.fs.path.basename(wb.path.?));

    try Workbench.showProblems(&wb);
    _ = t.settle();
    try std.testing.expect(wb.shown(wb.problems_ref));
    try std.testing.expect(t.find(.{ .name = "error: unused b, b.zig line 1" }) != null);
}

test "workbench: go to definition jumps, Back and Forward return; several targets are listed; hover links" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const a = 1;\nconst \u{e9} = a;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "pub const b = 2;\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.zig" });
    defer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ root, "b.zig" });
    defer gpa.free(b);

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, a);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 600 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();

    const h = wb.currentHandle().?;
    const in_b: NavService.Target = .{ .uri = "file:///b.zig", .path = b, .selection = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 11 } }, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 16 } }, .enc = .utf16 };
    // "é" is one UTF-16 unit and two bytes: column 8 is byte 9.
    const in_a: NavService.Target = .{ .uri = "file:///a.zig", .path = a, .selection = .{ .start = .{ .line = 1, .character = 8 }, .end = .{ .line = 1, .character = 9 } }, .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 12 } }, .enc = .utf16 };

    // One definition: jump there.
    wb.view.setSelection(.caret(5));
    Workbench.onNavDone(&wb, .{ .kind = .definition, .origin = h, .targets = &.{in_b}, .complete = true });
    _ = t.settle();
    try std.testing.expectEqualStrings("b.zig", std.fs.path.basename(wb.path.?));
    try std.testing.expectEqual(@as(u64, 10), wb.view.primarySel().head);
    // Back to where the caret was, and forward again.
    try Workbench.navigateBack(&wb);
    _ = t.settle();
    try std.testing.expectEqualStrings("a.zig", std.fs.path.basename(wb.path.?));
    try std.testing.expectEqual(@as(u64, 5), wb.view.primarySel().head);
    try Workbench.navigateForward(&wb);
    _ = t.settle();
    try std.testing.expectEqualStrings("b.zig", std.fs.path.basename(wb.path.?));
    try std.testing.expectEqual(@as(u64, 10), wb.view.primarySel().head);

    // References: a list, even of one; accepting a row jumps.
    Workbench.onNavDone(&wb, .{ .kind = .references, .origin = h, .targets = &.{ in_a, in_b }, .complete = true });
    _ = t.settle();
    try std.testing.expect(wb.nav_pick.isOpen(t.win));
    try std.testing.expectEqualStrings("a.zig:2:9", wb.nav_items[0].label);
    try std.testing.expectEqualStrings("References (2)", wb.nav_title);
    Workbench.navPickAccept(&wb, wb.nav_items[0..1], null, false);
    wb.nav_pick.close(t.win);
    _ = t.settle();
    try std.testing.expectEqualStrings("a.zig", std.fs.path.basename(wb.path.?));
    try std.testing.expectEqual(@as(u64, 13 + 9), wb.view.primarySel().head);

    // Nothing found: a notice, no jump.
    Workbench.onNavDone(&wb, .{ .kind = .implementation, .origin = h, .targets = &.{}, .complete = true });
    _ = t.settle();
    try std.testing.expectEqualStrings("a.zig", std.fs.path.basename(wb.path.?));

    // Hover links: a file link with a line opens it; web links are
    // copied; other commands than the allowlisted ones do nothing.
    const link = try std.fmt.allocPrint(gpa, "file://{s}#L1", .{b});
    defer gpa.free(link);
    Workbench.onHoverLink(&wb, .{ .url = link }, false);
    _ = t.settle();
    try std.testing.expectEqualStrings("b.zig", std.fs.path.basename(wb.path.?));
    try std.testing.expectEqual(@as(u64, 0), wb.view.primarySel().head);
    Workbench.onHoverLink(&wb, .{ .url = "https://ziglang.org/documentation/" }, false);
    try std.testing.expectEqualStrings("https://ziglang.org/documentation/", t.win.app.clipboard.get());
    Workbench.onHoverLink(&wb, .{ .url = "command:workbench.action.quit" }, false);
    _ = t.settle();
}

test "workbench: Go to Symbol in File lists the outline, previews, restores on Escape and jumps on Enter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = "class C:\n    def f(self):\n        pass\n\n\ndef g():\n    pass\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.py" });
    defer gpa.free(a);

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, a);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 600 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();

    wb.view.setSelection(.caret(0));
    // No language server: the syntax layer's outline stands in.
    try Workbench.symbolsInFile(&wb);
    _ = t.settle();
    const pk = &wb.codeintel.?.pickers;
    try std.testing.expect(pk.doc_pick.isOpen(t.win));
    try std.testing.expect(pk.items.items.len >= 3);
    try std.testing.expectEqualStrings("C", pk.items.items[0].label);
    try std.testing.expectEqualStrings("  f", pk.items.items[1].label);
    // The first row previews: C's name is selected.
    try std.testing.expectEqual(@as(u64, 6), wb.view.primarySel().start());
    t.press(.arrow_down, .{});
    _ = t.settle();
    try std.testing.expectEqual(@as(u64, 17), wb.view.primarySel().start());
    t.press(.escape, .{});
    _ = t.settle();
    try std.testing.expectEqual(@as(u64, 0), wb.view.primarySel().head);
    try std.testing.expect(wb.view.primarySel().isCaret());

    // Enter jumps; Go Back returns.
    try Workbench.symbolsInFile(&wb);
    _ = t.settle();
    t.typeText("g");
    _ = t.settle();
    t.press(.enter, .{});
    _ = t.settle();
    try std.testing.expectEqual(@as(u64, 45), wb.view.primarySel().head);
    try Workbench.navigateBack(&wb);
    _ = t.settle();
    try std.testing.expectEqual(@as(u64, 0), wb.view.primarySel().head);

    // The workspace picker needs a server.
    try Workbench.symbolsInWorkspace(&wb);
    try std.testing.expect(!pk.ws_pick.isOpen(t.win));
}

test "workbench: opening the terminal focuses it; the Agent button shows and hides the pane" {
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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fs.path.join(gpa, &.{ root, "a.zig" });
    defer gpa.free(a);

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, a);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 700 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();

    try wb.toggleTerminal();
    _ = t.settle();
    _ = t.settle();
    try std.testing.expect(!wb.terminal_node.isNone());
    try std.testing.expect(t.win.focus.eql(wb.terminal_node));

    try t.click(.{ .role = .button, .name = "Agent" });
    _ = t.settle();
    try std.testing.expect(wb.shown(wb.agent_ref));
    try t.click(.{ .role = .button, .name = "Agent" });
    _ = t.settle();
    try std.testing.expect(!wb.shown(wb.agent_ref));
}

test "workbench: terminals open as tabs and splits, cycle, and close" {
    const gpa = std.testing.allocator;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, null);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 700 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();

    // The terminal keys parse.
    try std.testing.expectEqual(@as(usize, 0), wb.diags.errorCount());

    try wb.toggleTerminal();
    _ = t.settle();
    try wb.newTerminalCmd();
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 2), wb.term_tabs.groups.items.len);
    try std.testing.expectEqual(@as(?TerminalId, 2), wb.term_tabs.activeId());

    // Split beside terminal 2, from the tab strip; focus follows.
    try t.click(.{ .role = .button, .name = "Split" });
    _ = t.settle();
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 2), wb.term_tabs.groups.items.len);
    try std.testing.expectEqual(@as(usize, 2), wb.term_tabs.activeGroup().?.terminals.items.len);
    try std.testing.expectEqual(@as(?TerminalId, 3), wb.term_tabs.activeId());
    try std.testing.expect(t.win.focus.eql(wb.activeTerminal().?.view.node));

    // Cycling wraps from the split back to the first tab, and focus moves.
    try wb.focusNextTerminal();
    _ = t.settle();
    _ = t.settle();
    try std.testing.expectEqual(@as(?TerminalId, 1), wb.term_tabs.activeId());
    try std.testing.expect(t.win.focus.eql(wb.terminals.get(1).?.view.node));
    try wb.focusPreviousTerminal();
    _ = t.settle();
    try std.testing.expectEqual(@as(?TerminalId, 3), wb.term_tabs.activeId());

    // The first tab's button shows it again.
    try t.click(.{ .role = .button, .name = "Terminal 1" });
    _ = t.settle();
    _ = t.settle();
    try std.testing.expectEqual(@as(?TerminalId, 1), wb.term_tabs.activeId());

    try t.click(.{ .role = .button, .name = "Kill" });
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 2), wb.terminals.count());
    try std.testing.expect(wb.terminals.get(1) == null);
    try std.testing.expect(wb.shown(wb.terminal_ref));

    try wb.killAllTerminals();
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 0), wb.terminals.count());
    try std.testing.expect(!wb.shown(wb.terminal_ref));
}

test "workbench: terminals come back after a restart with their output, splits and names" {
    const gpa = std.testing.allocator;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const state = try std.fs.path.join(gpa, &.{ root, "state" });
    defer gpa.free(state);

    {
        var wb: Workbench = undefined;
        try wb.init(&rt, &env, null);
        defer wb.deinit();
        _ = wb.loadLayout(state);
        const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 700 }, .root = .of(&wb) });
        defer t.deinit();
        try wb.attach(t.win);
        defer wb.detach();
        try wb.toggleTerminal();
        try wb.splitTerminal();
        try wb.newTerminalCmd();
        _ = t.settle();
        wb.terminals.get(1).?.view.feed("\x1b[1mhello-from-one\x1b[0m\r\n");
        wb.terminals.get(2).?.view.feed("hello-from-two\r\n");
        try wb.term_tabs.rename(3, "build");
    }
    {
        var wb: Workbench = undefined;
        try wb.init(&rt, &env, null);
        defer wb.deinit();
        _ = wb.loadLayout(state);
        const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 700 }, .root = .of(&wb) });
        defer t.deinit();
        try wb.attach(t.win);
        defer wb.detach();
        try wb.focusTerminalCmd();
        _ = t.settle();
        try std.testing.expectEqual(@as(usize, 3), wb.terminals.count());
        try std.testing.expectEqual(@as(usize, 2), wb.term_tabs.groups.items.len);
        try std.testing.expectEqual(@as(usize, 2), wb.term_tabs.groups.items[0].terminals.items.len);
        try std.testing.expectEqualStrings("build", wb.term_tabs.nameOf(wb.term_tabs.groups.items[1].terminals.items[0]).?);
        const want = [_][]const u8{ "hello-from-one", "hello-from-two" };
        for (want, wb.term_tabs.groups.items[0].terminals.items) |text, id| {
            const d = try wb.terminals.get(id).?.term.dump(gpa);
            defer gpa.free(d);
            try std.testing.expect(std.mem.indexOf(u8, d, text) != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "Restored session, saved") != null);
        }
    }
}

test "workbench: Find in Terminal opens the bar on the selection and Escape returns focus" {
    const gpa = std.testing.allocator;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, null);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 700 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();

    try wb.toggleTerminal();
    _ = t.settle();
    const term = wb.activeTerminal().?;
    term.view.feed("build failed\r\nok\r\nfailed again\r\n");
    term.view.beginSelection(term.view.pointAt(.{ 6, 0 }), .word);
    try wb.findInTerminal();
    _ = t.settle();
    _ = t.settle();
    try std.testing.expect(term.find.open);
    try std.testing.expectEqualStrings("failed", term.find.field.slice());
    try std.testing.expectEqual(@as(usize, 2), term.view.search.matches.items.len);
    try std.testing.expect(t.win.focus.eql(term.find.field_node));

    t.press(.escape, .{});
    _ = t.settle();
    _ = t.settle();
    try std.testing.expect(!term.find.open);
    try std.testing.expect(t.win.focus.eql(wb.terminal_node));
}

test "workbench: Ctrl+click on a file reference in the terminal opens it at the line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const a = 1;\nconst b = 2;\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, null);
    defer wb.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 700 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();

    try wb.toggleTerminal();
    _ = t.settle();
    const term = wb.activeTerminal().?;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.print(gpa, "\x1b]7;file://localhost{s}\x07b.zig:2:7: error: x\r\nmissing.zig:1\r\n", .{root});
    term.view.feed(line.items);
    try std.testing.expect(term.view.openLinkAt(term.view.pointAt(.{ 1, 0 })));
    _ = t.settle();
    _ = t.settle();
    try std.testing.expect(std.mem.endsWith(u8, wb.path.?, "b.zig"));
    try std.testing.expectEqual(@as(u32, 1), wb.view.lineOf(wb.view.primarySel().head));
    // A file that does not exist only warns.
    try std.testing.expect(term.view.openLinkAt(term.view.pointAt(.{ 1, 1 })));
    _ = t.settle();
    try std.testing.expect(std.mem.endsWith(u8, wb.path.?, "b.zig"));
}

test "workbench: the notes sidebar follows the editor; note search opens a hit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "# Alpha\n\nSee [[b]] about zebras.\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.md", .data = "# Bravo\n\nStripes.\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const b = try std.fs.path.join(gpa, &.{ root, "b.md" });
    defer gpa.free(b);

    var wb: Workbench = undefined;
    try wb.init(&rt, &env, b);
    defer wb.deinit();
    // The folder is the test's, not the process's.
    gpa.free(wb.cwd);
    wb.cwd = try gpa.dupeZ(u8, root);
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1200, .h = 800 }, .root = .of(&wb) });
    defer t.deinit();
    try wb.attach(t.win);
    defer wb.detach();
    _ = t.settle();

    // The sidebar shows what links to the current note.
    try Workbench.showNotesSidebar(&wb);
    _ = t.settle();
    try std.testing.expect(wb.shown(wb.notes_ref));
    try std.testing.expect(t.find(.{ .role = .link, .name = "Alpha" }) != null);
    try std.testing.expect(t.find(.{ .name = "Linked from Alpha: See [[b]] about zebras." }) != null);

    // Ctrl+Shift+N: the search finds a by its text; Enter opens it with
    // the hit selected, and the sidebar follows.
    try Workbench.notesSearch(&wb);
    _ = t.settle();
    try std.testing.expect(wb.shown(wb.notes_search_ref));
    const n = wb.notes.?;
    n.search_model.o.debounce_ms = 0;
    try n.search_view.setQuery("zebras");
    t.win.markAllDirty();
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 1), n.search_model.rows().len);
    n.search_model.openSelected(false);
    _ = t.settle();
    try std.testing.expectEqualStrings("a.md", std.fs.path.basename(wb.path.?));
    const sel = wb.view.primarySel();
    try std.testing.expect(sel.anchor != sel.head);
    try n.sidebar_model.sync();
    try std.testing.expectEqualStrings("Alpha", n.sidebar_model.title);

    // Alt+Enter on the link follows it to b.
    t.win.setFocus(wb.editor_node, false);
    wb.view.setSelection(.caret(15));
    t.press(.enter, .{ .alt = true });
    _ = t.settle();
    try std.testing.expectEqualStrings("b.md", std.fs.path.basename(wb.path.?));

    // Saving a note indexes it again.
    try tmp.dir.writeFile(io, .{ .sub_path = "c.md", .data = "# Charlie\n\n[[a]]\n" });
    const c = try std.fs.path.join(gpa, &.{ root, "c.md" });
    defer gpa.free(c);
    n.fileChanged(c);
    try n.sidebar_model.sync();
    try std.testing.expectEqual(@as(usize, 1), n.sidebar_model.backlinks.len);
}
