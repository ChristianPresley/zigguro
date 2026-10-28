//! Language services in the workbench (E07): one zg_codeintel `Manager`
//! for the working folder, which starts language servers (zls, clangd,
//! ...) as matching files open; the semantic tokens driver, which
//! colours the editors through their `DocumentSyntax` overlays; and the
//! diagnostics driver, whose store the agent's edit tools read back
//! through the settle detector (`agentDiagnostics`) and whose
//! diagnostics the editors draw (squiggles by severity, gutter dots and
//! overview ruler marks, through each editor's decoration store). The
//! agent also gets
//! language-server tools (`agentTools`: diagnostics, hover, definition).
//!
//! Hover, highlights and navigation (E07.F03.S02.T01, E07.F04.S01.T01):
//! the pointer resting on a word for `hover_delay_ms` asks for a hover,
//! shown in a popup above it (`HoverPopup`) until the pointer moves to
//! another word or leaves for longer than `hide_grace_ms` (not into the
//! popup), a key is pressed or the text changes; `showHoverAt` asks from
//! the keyboard. The symbol under the caret has its other occurrences
//! highlighted (read and write occurrences differ). `goTo` asks for a
//! definition, declaration, type definition, implementation or the
//! references; Ctrl+click asks for the definition. The answers go to
//! `nav_hook` (the workbench jumps or offers a list).
//!
//! Completion and signature help (E07.F03.S01): typing an identifier
//! character in code, or a server's trigger character, asks for
//! completions (Ctrl+Space asks anywhere); the list (`CompletionPopup`)
//! opens under the word and follows the typing. Up/Down/PageUp/PageDown/
//! Home/End select, Enter or Tab accepts (Shift+Enter replaces the word
//! after the caret too), a commit character accepts and is typed, Escape
//! or Left/Right close, Ctrl+Space shows or hides the docs. While the
//! list is open the AI ghost text steps aside (`popup_hook`). Snippet
//! items start a snippet session: Tab and Shift+Tab move between its
//! stops, Escape ends it. Signature help opens above the caret on the
//! servers' trigger characters (Ctrl+Shift+Space asks), follows edits,
//! cycles with Up/Down and closes on Escape or when the caret leaves.
//!
//! Rename, code actions and commands (E07.F04.S02.T02, `refactor_ui.zig`):
//! `rename` (F2) and `quickFix` (Ctrl+.) run through the workspace edit
//! engine; a resting caret shows a lightbulb when quick fixes exist.
//! Edits a server sends while an agent's command runs go to review.
//!
//! Formatting (E07.F04.S02.T03): `formatDocument`, `formatSelection`,
//! format on type (`Prefs.format_on_type`), and `beforeSave`, the save
//! pipeline the workbench runs before writing a file (willSaveWaitUntil,
//! code actions on save, format on save, in 1 s). `file_hooks` sends the
//! workspace file-operation requests around the Explorer's operations.
//!
//! Servers run code from the workspace (zls runs `build.zig`), so nothing
//! starts until the folder is trusted: files opened before that are
//! attached when `setTrusted(true)` comes.
//!
//! The workbench calls `open`/`close` as files load and close, `saved`
//! after a save, and `frame` from every build with the current editor.
//! Results from servers wake the UI through a posted call; debounced
//! requests set a window timer.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const zg_codeintel = @import("zg_codeintel");
const zg_ai = @import("zg_ai");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const EditorView = zg_editor.view.EditorView;
const DocumentRegistry = zg_editor.model.api.registry.DocumentRegistry;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Document = zg_editor.model.document.Document;
const DocumentSyntax = zg_editor.model.syntax.DocumentSyntax;
const DecorationStore = zg_editor.model.decorations.store.DecorationStore;
const StyleRef = zg_editor.model.decorations.store.StyleRef;
const Manager = zg_codeintel.Manager;
const SemTokDriver = zg_codeintel.features.SemTokDriver;
const diagnostics = zg_codeintel.diagnostics;
const HoverService = zg_codeintel.features.HoverService;
const HighlightService = zg_codeintel.features.HighlightService;
pub const NavService = zg_codeintel.features.NavService;
const CompletionService = zg_codeintel.features.CompletionService;
const SignatureService = zg_codeintel.features.SignatureService;
const FormatService = zg_codeintel.features.FormatService;
pub const SaveActions = zg_codeintel.features.SaveActions;
pub const FileOpHooks = zg_codeintel.features.FileOpHooks;
const OutlineProvider = zg_codeintel.features.OutlineProvider;
const WorkspaceSymbols = zg_codeintel.features.WorkspaceSymbols;
const LinkedEditingService = zg_codeintel.features.LinkedEditingService;
pub const HierarchyService = zg_codeintel.features.HierarchyService;
const VirtualDocs = zg_codeintel.features.VirtualDocs;
pub const SymbolPickers = @import("symbol_pickers.zig").SymbolPickers;
pub const InlineInfo = @import("lens_ui.zig").InlineInfo;
pub const SmartSelect = @import("smart_select.zig").SmartSelect;
pub const DocLinks = @import("doc_links.zig").DocLinks;
const LinkDriver = @import("doc_links.zig").LinkDriver;
const SnippetStack = zg_codeintel.snippet.Session.Stack;
const HoverPopup = @import("hover_popup.zig").HoverPopup;
const CompletionPopup = @import("completion_popup.zig").CompletionPopup;
const SignaturePopup = @import("signature_popup.zig").SignaturePopup;
const PointerEvent = zg_editor.view.editor_view.PointerEvent;
const Vec2 = zg_gui.core.Vec2;
const Rect = zg_gui.core.Rect;
const WorkspaceEditEngine = zg_codeintel.edits.Engine;
const DiskFs = @import("workspace_fs.zig").DiskFs;
pub const Refactor = @import("refactor_ui.zig").Refactor;
const LspTools = zg_codeintel.agent.tools.ToolExporter(zg_ai.tools.adapters.foreign);

const log = std.log.scoped(.codeintel);

pub const CodeIntel = struct {
    gpa: Allocator,
    app: *zg_gui.App,
    win: ?*Window = null,
    docs: *DocumentRegistry,
    cwd: []const u8,
    reg: zg_codeintel.registry.Registry,
    mgr: Manager = undefined,
    names: zg_syntax.HighlightNames,
    semtok: SemTokDriver = undefined,
    diags: diagnostics.Store,
    diag: diagnostics.Driver = undefined,
    decor: diagnostics.Decorator = undefined,
    lsp_tools: LspTools = undefined,
    files: std.ArrayList(File) = .empty,
    trusted: bool = false,
    /// What wakes post (it outlives `destroy` while a wake is queued).
    wake_box: *WakeBox = undefined,
    timer: Window.TimerId = .none,
    /// The editor last reported visible.
    shown: ?DocHandle = null,
    hover: HoverService = undefined,
    highlight: HighlightService = undefined,
    nav: NavService = undefined,
    popup: HoverPopup,
    /// Where the pointer rests: a hover is asked at `due_ms`.
    rest: ?struct { h: DocHandle, view: *EditorView, offset: u64, origin: Vec2, due_ms: u64 } = null,
    /// The inlay hint under the pointer (its tooltip shows).
    inlay_hover: ?struct { h: DocHandle, id: u64, view: *EditorView, origin: Vec2, shown: bool = false } = null,
    /// The editor and text origin the hover asked or shown is placed by.
    hover_at: ?struct { view: *EditorView, origin: Vec2 } = null,
    hover_seen: u64 = 0,
    /// The pointer left: hide the mouse's hover then, unless it is over
    /// the popup.
    hide_due_ms: ?u64 = null,
    /// The decoration store holding the document highlights.
    hl_deco: ?*DecorationStore = null,
    hl_owner: zg_editor.model.decorations.store.OwnerId = undefined,
    hl_seen: u64 = 0,
    /// A navigation request waits for its answers.
    nav_waiting: bool = false,
    nav_hook: ?NavHook = null,
    completion: CompletionService = undefined,
    signature: SignatureService = undefined,
    snippets: SnippetStack,
    cpopup: CompletionPopup,
    spopup: SignaturePopup,
    /// The editor completion and signature help are for, and its text
    /// origin in the window (from its last key or typing).
    comp_view: ?*EditorView = null,
    comp_origin: Vec2 = .{},
    comp_seen: u64 = 0,
    sig_seen: u64 = 0,
    /// The list was showing (for `popup_hook`).
    comp_shown: bool = false,
    /// The caret and version last seen, so `frame` follows edits and
    /// moves that were not typing.
    last_caret: ?struct { view: *EditorView, head: u64, version: u64 } = null,
    /// Told when the completion list opens or closes over an editor (the
    /// workbench hides the AI ghost text meanwhile).
    popup_hook: ?PopupHook = null,
    /// Applies workspace edits (server `workspace/applyEdit` now; rename,
    /// code actions and formatting through it).
    fs: DiskFs = undefined,
    engine: WorkspaceEditEngine = undefined,
    /// Rename, code actions and the lightbulb.
    refactor: Refactor = undefined,
    /// Formatting, the save pipeline and the file-operation hooks the
    /// Explorer's operations call (`file_hooks`).
    format: FormatService = undefined,
    save_actions: SaveActions = undefined,
    file_hooks: FileOpHooks = undefined,
    prefs: ?Prefs = null,
    /// Document outlines and workspace symbols, and their pickers.
    outline: OutlineProvider = undefined,
    ws_symbols: WorkspaceSymbols = undefined,
    pickers: SymbolPickers = undefined,
    /// Inlay hints and code lenses.
    inline_info: InlineInfo = undefined,
    /// Linked editing (`editor.linkedEditing`): the session's editor and
    /// decorations.
    linked: LinkedEditingService = undefined,
    linked_seen: u64 = 0,
    linked_view: ?*EditorView = null,
    linked_deco: ?*DecorationStore = null,
    linked_owner: zg_editor.model.decorations.store.OwnerId = undefined,
    /// Call and type hierarchies (the Hierarchy panel's tree).
    hierarchy: HierarchyService = undefined,
    /// Read-only documents for servers' non-file locations.
    virtual: VirtualDocs = undefined,
    /// Expand and shrink selection.
    smart: SmartSelect = undefined,
    smart_seen: u64 = 0,
    /// Document links: underlined, Ctrl+click follows (`link_hook`).
    links: DocLinks = undefined,
    link_hook: ?LinkHook = null,

    /// Rest time before a hover is asked.
    pub const hover_delay_ms = 500;
    /// How long a hover stays after the pointer leaves the editor.
    pub const hide_grace_ms = 300;

    /// Told when a navigation request (`goTo`, Ctrl+click) has all its
    /// answers.
    pub const NavHook = struct {
        ctx: *anyopaque,
        done: *const fn (ctx: *anyopaque, r: NavService.Results) void,
    };

    /// Per-file formatting settings (the workbench's).
    pub const Prefs = struct {
        ctx: *anyopaque,
        options: *const fn (ctx: *anyopaque, h: DocHandle) zg_codeintel.protocol.FormattingOptions,
        format_on_type: *const fn (ctx: *anyopaque, h: DocHandle) bool,
    };

    /// Follows a document link (`file:` in the editor, web in the
    /// browser, an allowed `command:`).
    pub const LinkHook = struct {
        ctx: *anyopaque,
        open: *const fn (ctx: *anyopaque, kind: LinkDriver.TargetKind, target: []const u8) void,
    };

    pub const PopupHook = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, view: *EditorView, open: bool) void,
    };

    const File = struct {
        h: DocHandle,
        doc: *Document,
        syntax: *DocumentSyntax,
        view: *EditorView,
        /// The editor's decorations (diagnostics are drawn there).
        deco: ?*DecorationStore = null,
        /// Attached to the manager (once trusted).
        attached: bool = false,
        /// Edits ask for a tick, so they reach the servers even when no
        /// frame follows (agent edits to files not shown).
        listener: ?zg_editor.model.document.ListenerId = null,
    };

    /// Language services for the folder `cwd` (absolute; must outlive
    /// the result). Nothing starts until `setTrusted(true)`.
    pub fn create(rt: *zg_core.Runtime, env: *const std.process.Environ.Map, app: *zg_gui.App, docs: *DocumentRegistry, cwd: []const u8) !*CodeIntel {
        const gpa = rt.gpa;
        const ci = try gpa.create(CodeIntel);
        errdefer gpa.destroy(ci);
        const box = try gpa.create(WakeBox);
        errdefer gpa.destroy(box);
        box.* = .{ .ci = ci, .gpa = gpa };
        ci.* = .{
            .gpa = gpa,
            .app = app,
            .docs = docs,
            .cwd = cwd,
            // Server settings (`lsp.servers`) are not read yet: built-in
            // definitions only, so no workspace command can apply.
            .reg = try .init(gpa, .{}),
            .names = .init(gpa),
            .diags = try .init(gpa, rt.io, docs.style),
            .popup = .init(gpa),
            .snippets = .init(gpa),
            .cpopup = .init(gpa),
            .spopup = .init(gpa),
            .wake_box = box,
        };
        ci.cpopup.on_pick = .{ .ctx = ci, .f = onPick };
        errdefer ci.diags.deinit();
        errdefer ci.reg.deinit();
        ci.mgr.init(rt, &ci.reg, docs, .{
            .workspace_folders = (&ci.cwd)[0..1],
            .env = env,
            .waker = ci.waker(),
            .client_version = "0.0.0",
        });
        errdefer ci.mgr.deinit();
        try ci.diag.init(&ci.mgr, &ci.diags, .{ .pull = .{ .waker = ci.waker() } });
        errdefer ci.diag.deinit();
        try ci.decor.init(gpa, &ci.diags, .{ .severity = .{ style.err, style.warning, style.info, style.hint }, .faded = style.faded });
        errdefer ci.decor.deinit();
        try ci.semtok.init(&ci.mgr, &ci.names, .{ .ctx = ci, .get = syntaxOf }, .{ .waker = ci.waker() });
        ci.hover = .init(&ci.mgr, &ci.diags, ci.waker());
        ci.highlight = .init(&ci.mgr, ci.waker(), .{});
        ci.nav.init(&ci.mgr, ci.waker());
        ci.completion = .init(&ci.mgr, ci.waker(), .{});
        ci.signature = .init(&ci.mgr, ci.waker());
        ci.fs = .{ .io = rt.io, .trash_root = try std.fs.path.join(gpa, &.{ cwd, ".zigguro", "trash" }) };
        ci.engine = .init(gpa, docs, ci.fs.ops(), .{});
        ci.engine.editors = .{ .ctx = ci, .f = editorOf };
        ci.mgr.apply_edit_hook = .{ .ctx = ci, .f = onApplyEdit };
        ci.refactor.init(&ci.mgr, &ci.engine, &ci.diags, ci.waker(), .{ style.bulb, style.bulb_preferred });
        ci.refactor.decos = .{ .ctx = ci, .f = decoOf };
        ci.format = .init(&ci.mgr, &ci.engine, ci.waker());
        ci.format.options = .{ .ctx = ci, .f = formatOptions };
        ci.save_actions = .init(&ci.mgr, &ci.engine, &ci.refactor.commands);
        ci.save_actions.options = ci.format.options;
        ci.file_hooks = .init(&ci.mgr, &ci.engine);
        ci.outline = .init(&ci.mgr, ci.waker(), .{});
        ci.outline.structure = .{ .ctx = ci, .f = structureOf };
        ci.ws_symbols = .init(&ci.mgr, ci.waker(), .{});
        ci.pickers = .init(gpa, &ci.outline, &ci.ws_symbols);
        try ci.outline.subscribe(.{ .ctx = ci, .f = onOutline });
        try ci.inline_info.init(gpa, &ci.mgr, ci.waker(), style.inlay);
        ci.linked = .init(&ci.mgr, ci.waker(), .{});
        ci.hierarchy = .init(&ci.mgr, ci.waker());
        try ci.virtual.init(&ci.mgr, ci.waker());
        ci.smart = .init(gpa, &ci.mgr, ci.waker());
        ci.smart.structure = .{ .ctx = ci, .f = selectionStructureOf };
        ci.links.init(gpa, &ci.mgr, ci.waker(), .{ .ctx = ci, .open = onLinkOpen }, style.link);
        ci.lsp_tools = .{ .src = .{ .mgr = &ci.mgr, .store = &ci.diags, .roots = (&ci.cwd)[0..1], .ui = .{ .ctx = ci, .run = runOnUi } } };
        return ci;
    }

    /// Shuts the servers down (blocks briefly) and frees everything. Call
    /// before the documents and their syntax go away.
    pub fn destroy(ci: *CodeIntel) void {
        if (ci.win) |w| if (ci.timer != .none) w.cancelTimer(ci.timer);
        for (ci.files.items) |f| {
            if (f.listener) |l| f.doc.unsubscribe(l);
            ci.unhook(f.view);
        }
        ci.clearHighlights();
        ci.clearLinked();
        ci.refactor.close();
        ci.pickers.deinit();
        ci.inline_info.release();
        ci.smart.release();
        ci.links.release();
        ci.popup.deinit();
        ci.cpopup.release();
        ci.spopup.release();
        ci.snippets.deinit();
        ci.mgr.deinit();
        ci.refactor.deinit();
        ci.format.deinit();
        ci.save_actions.deinit();
        ci.file_hooks.deinit();
        ci.outline.deinit();
        ci.ws_symbols.deinit();
        ci.inline_info.deinitServices();
        ci.linked.deinit();
        ci.hierarchy.deinit();
        ci.virtual.deinit();
        ci.smart.deinitDriver();
        ci.links.deinitDriver();
        ci.engine.deinit();
        ci.gpa.free(ci.fs.trash_root);
        ci.completion.deinit();
        ci.signature.deinit();
        ci.hover.deinit();
        ci.highlight.deinit();
        ci.nav.deinit();
        ci.diag.deinit();
        ci.decor.deinit();
        ci.semtok.deinit();
        ci.diags.deinit();
        ci.files.deinit(ci.gpa);
        ci.names.deinit();
        ci.reg.deinit();
        // No thread wakes any more (the servers are gone): a queued wake
        // frees the box when it runs.
        const box = ci.wake_box;
        box.app = ci.app;
        box.ci = null;
        if (!box.posted.load(.acquire)) ci.gpa.destroy(box);
        ci.gpa.destroy(ci);
    }

    /// The highlight names semantic tokens use; editors resolve colours
    /// through them (`EditorView.hl_names`).
    pub fn highlightNames(ci: *CodeIntel) *const zg_syntax.HighlightNames {
        return &ci.names;
    }

    /// The agent's after-edit diagnostics (`zg_ai`'s
    /// `FileTools.diagnostics`): waits for the servers to answer an edit,
    /// then summarizes the file's errors and warnings. Valid until
    /// `destroy`.
    pub fn agentDiagnostics(ci: *CodeIntel) zg_ai.tools.builtin.files.Diagnostics {
        return .{ .ctx = ci.diag.settleDetector(), .after_edit = diagnostics.SettleDetector.afterEdit };
    }

    /// The agent's language-server tools (`zg_ai`'s foreign exporter for
    /// `Services.lsp`). Valid until `destroy`; destroy the agent first.
    pub fn agentTools(ci: *CodeIntel) zg_ai.tools.adapters.foreign.Exporter {
        return ci.lsp_tools.exporter();
    }

    /// Agent task: runs `f(arg)` on the UI thread and waits for it.
    fn runOnUi(ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) bool {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        const Job = struct {
            f: *const fn (arg: *anyopaque) void,
            arg: *anyopaque,
            io: std.Io,
            done: std.Io.Event = .unset,
            fn run(c: *anyopaque, _: *zg_gui.App) void {
                const j: *@This() = @ptrCast(@alignCast(c));
                j.f(j.arg);
                j.done.set(j.io);
            }
        };
        var job: Job = .{ .f = f, .arg = arg, .io = ci.mgr.rt.io };
        ci.app.post(.{ .ctx = &job, .f = Job.run }) catch return false;
        job.done.waitUncancelable(job.io);
        return true;
    }

    /// Starts (or, when false, keeps holding) the language servers.
    /// Distrusting a folder later needs a restart of the app.
    pub fn setTrusted(ci: *CodeIntel, on: bool) void {
        if (!on or ci.trusted) return;
        ci.trusted = true;
        for (ci.files.items) |*f| ci.attach(f);
    }

    /// The decoration styles of diagnostics (`styleColor` resolves them).
    pub const style = struct {
        pub const err: StyleRef = @enumFromInt(0x0702_0001);
        pub const warning: StyleRef = @enumFromInt(0x0702_0002);
        pub const info: StyleRef = @enumFromInt(0x0702_0003);
        pub const hint: StyleRef = @enumFromInt(0x0702_0004);
        pub const faded: StyleRef = @enumFromInt(0x0702_0005);
        /// Document highlights: other occurrences, reads, writes.
        pub const occurrence: StyleRef = @enumFromInt(0x0702_0006);
        pub const read: StyleRef = @enumFromInt(0x0702_0007);
        pub const write: StyleRef = @enumFromInt(0x0702_0008);
        /// The code action lightbulb, and with a preferred fix.
        pub const bulb: StyleRef = @enumFromInt(0x0702_0009);
        pub const bulb_preferred: StyleRef = @enumFromInt(0x0702_000a);
        /// Inlay hint text.
        pub const inlay: StyleRef = @enumFromInt(0x0702_000b);
        /// Ranges edited together (linked editing).
        pub const linked: StyleRef = @enumFromInt(0x0702_000c);
        /// Document link underlines.
        pub const link: StyleRef = @enumFromInt(0x0702_000d);
    };

    /// `EditorView.styles` for the diagnostic styles, from the app's
    /// current theme (other owners' styles fall back to the view's
    /// defaults).
    fn styleColor(ctx: ?*anyopaque, s: StyleRef) ?zg_gui.core.Color {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx.?));
        const th = ci.app.theme;
        return switch (s) {
            style.err => th.color(.danger),
            style.warning => th.color(.warning),
            style.info => th.color(.info),
            style.hint => th.color(.fg_muted),
            style.faded => th.color(.bg_base).fade(0.45),
            style.occurrence, style.read => th.color(.selection_bg).fade(0.5),
            style.write => th.color(.accent).fade(0.3),
            style.bulb => th.color(.fg_muted),
            style.bulb_preferred => th.color(.warning),
            style.inlay => th.color(.fg_muted),
            style.linked => th.color(.accent).fade(0.18),
            style.link => th.color(.fg_link),
            else => null,
        };
    }

    /// A file with highlighting opened in `view` (files without a known
    /// language get no language services). Diagnostics are drawn into
    /// `deco`, the editor's decoration store, when given (it must
    /// outlive `close(h)`).
    pub fn open(ci: *CodeIntel, h: DocHandle, syntax: ?*DocumentSyntax, view: *EditorView, deco: ?*DecorationStore) void {
        const sx = syntax orelse return;
        view.hl_names = &ci.names;
        if (deco != null) view.styles = .{ .ctx = ci, .color = styleColor };
        for (ci.files.items) |f| if (std.meta.eql(f.h, h)) return;
        ci.files.append(ci.gpa, .{ .h = h, .doc = ci.docs.get(h) orelse return, .syntax = sx, .view = view, .deco = deco }) catch return;
        if (view.pointer_hook == null) view.pointer_hook = .{ .ctx = ci, .f = onPointer };
        if (ci.trusted) ci.attach(&ci.files.items[ci.files.items.len - 1]);
    }

    fn attach(ci: *CodeIntel, f: *File) void {
        if (f.attached) return;
        ci.mgr.openDoc(f.h, zg_codeintel.language.lspId(f.syntax.lang)) catch |e| {
            log.warn("language services: {t}", .{e});
            return;
        };
        f.listener = f.doc.subscribe(.{ .ctx = ci, .onChange = onDocChange }) catch null;
        ci.semtok.track(f.h) catch {};
        ci.links.track(f.h, f.deco);
        if (f.deco) |d| if (ci.diag.keyOfDoc(f.h)) |k| ci.decor.attach(k, d) catch {};
        f.attached = true;
    }

    /// The file closes (before its view and syntax are freed).
    pub fn close(ci: *CodeIntel, h: DocHandle) void {
        for (ci.files.items, 0..) |f, i| if (std.meta.eql(f.h, h)) {
            if (f.attached) {
                if (f.deco) |d| ci.decor.detach(d);
                ci.semtok.untrack(h);
                ci.links.untrack(h);
                ci.mgr.closeDoc(h);
            }
            if (f.listener) |l| f.doc.unsubscribe(l);
            ci.unhook(f.view);
            if (f.deco != null and f.deco == ci.hl_deco) ci.clearHighlights();
            if (f.deco) |d| ci.refactor.forget(d);
            ci.save_actions.forget(h);
            ci.outline.forget(h);
            ci.inline_info.forget(h, f.view);
            ci.smart.forgetView(f.view);
            if (ci.linked_view == f.view) {
                ci.linked.end();
                ci.clearLinked();
            }
            if (ci.inlay_hover) |ih| if (ih.view == f.view) {
                ci.inlay_hover = null;
            };
            if (ci.hover_at) |a| if (a.view == f.view) ci.hideHover();
            if (ci.comp_view == f.view) {
                ci.closeCompletion();
                ci.closeSignature();
                ci.comp_view = null;
            }
            if (ci.snippets.top()) |t| if (t.view == f.view) ci.snippets.endAll();
            if (ci.last_caret) |lc| if (lc.view == f.view) {
                ci.last_caret = null;
            };
            if (ci.rest) |r| if (r.view == f.view) {
                ci.rest = null;
            };
            _ = ci.files.swapRemove(i);
            if (ci.shown) |s| if (std.meta.eql(s, h)) {
                ci.shown = null;
            };
            return;
        };
    }

    /// `doc` was saved.
    pub fn saved(ci: *CodeIntel, doc: *const Document) void {
        for (ci.files.items) |f| if (f.doc == doc and f.attached) ci.mgr.saved(f.h);
    }

    /// Per build: sends pending edits, applies results, requests tokens.
    /// `current` is the visible editor, if it has a document here.
    pub fn frame(ci: *CodeIntel, current: ?DocHandle, view: *EditorView) void {
        if (!ci.trusted) return;
        if (ci.shown) |s| if (current == null or !std.meta.eql(s, current.?)) ci.semtok.onHidden(s);
        ci.shown = current;
        if (current) |h| {
            const vis = view.visibleLines();
            ci.semtok.onViewport(h, .{ .first = vis[0], .end = vis[1] + 1 });
            if (ci.fileOf(h)) |f| if (f.view == view and f.attached) if (f.deco) |d| {
                ci.inline_info.viewport(h, view, d, vis[0], vis[1] + 1, ci.nowMs());
            };
        }
        const sel = view.primarySel();
        ci.highlight.onCursor(if (ci.fileOf(current)) |f| if (f.view == view and sel.anchor == sel.head) f.h else null else null, sel.head);
        ci.followCaret(current, view);
        if (ci.fileOf(current)) |f| if (f.view == view and f.attached) {
            const r = sel.range();
            ci.refactor.caret(f.h, .{ .start = r.start, .end = r.end }, f.doc.version, ci.nowMs());
            if (sel.isCaret()) ci.linked.onCursor(f.h, sel.head, ci.nowMs()) else ci.linked.end();
            // Edits since may have ended the session.
            _ = ci.linked.active(f.h);
        };
        // A shown hover goes with an edit, and a keyboard hover when the
        // caret leaves its word.
        if (ci.hover.current()) |r| {
            const doc = ci.docs.get(r.h);
            const caret_away = r.source == .keyboard and (sel.head < r.range.start or sel.head > r.range.end);
            if (doc == null or doc.?.version != r.version or caret_away) ci.hideHover();
        }
        ci.tick();
    }

    fn fileOf(ci: *CodeIntel, h: ?DocHandle) ?*File {
        const d = h orelse return null;
        for (ci.files.items) |*f| if (std.meta.eql(f.h, d)) return f;
        return null;
    }

    fn editorOf(ctx: *anyopaque, h: DocHandle) ?*EditorView {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        return if (ci.fileOf(h)) |f| f.view else null;
    }

    fn decoOf(ctx: *anyopaque, h: DocHandle) ?*DecorationStore {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        return if (ci.fileOf(h)) |f| f.deco else null;
    }

    /// A server's `workspace/applyEdit`: applied through the engine, as
    /// the user's, or to review while an agent's command runs there.
    fn onApplyEdit(ctx: *anyopaque, s: *Manager.Server, params: *const zg_codeintel.protocol.ApplyWorkspaceEditParams, reply: Manager.ApplyEditCb) void {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        const r = ci.engine.serverEdit(s, params, s.agent_command);
        if (!r.applied) log.info("workspace edit from {s} not applied: {s}", .{ s.def.id, r.failure_reason orelse "" });
        reply.call(r);
    }

    fn fileOfView(ci: *CodeIntel, v: *EditorView) ?*File {
        for (ci.files.items) |*f| if (f.view == v) return f;
        return null;
    }

    fn unhook(ci: *CodeIntel, v: *EditorView) void {
        if (v.pointer_hook) |hk| if (hk.ctx == @as(*anyopaque, ci)) {
            v.pointer_hook = null;
        };
    }

    fn nowMs(ci: *CodeIntel) u64 {
        return ci.app.now_ms;
    }

    /// The editor's pointer hook: hovers on rest, definitions on
    /// Ctrl+click, Escape hides a hover.
    fn onPointer(ctx: *anyopaque, v: *EditorView, e: PointerEvent) bool {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        const f = ci.fileOfView(v) orelse return false;
        if (!ci.trusted or !f.attached) return false;
        switch (e.kind) {
            .move => {
                ci.inline_info.modifiers(e.mods.ctrl, e.mods.alt);
                if (ci.inlayHover(f, e)) return false;
                if (ci.inlay_hover != null) {
                    ci.inlay_hover = null;
                    if (ci.hover.current() == null) ci.popup.hide();
                }
                ci.pointerAt(f, e);
            },
            .block => {
                const b = e.block orelse return false;
                if (!ci.inline_info.click(v, b, e.block_x, &ci.refactor.commands)) return false;
                ci.tick();
                return true;
            },
            .leave => {
                ci.rest = null;
                ci.inlay_hover = null;
                if (ci.hover.current() != null and ci.hover.current().?.source == .mouse) ci.hide_due_ms = ci.nowMs() + hide_grace_ms;
                ci.tick();
            },
            .click => {
                const off = e.offset orelse return false;
                if (ci.inlayClick(f, off)) return true;
                if (ci.links.click(f.h, off)) {
                    ci.hideHover();
                    ci.tick();
                    return true;
                }
                if (!ci.nav.available(.definition, f.h)) return false;
                ci.hideHover();
                _ = ci.goTo(.definition, f.h, off, false) catch return false;
                return true;
            },
            .text => return ci.onText(f, e.text),
            .typed => {
                ci.comp_origin = e.origin;
                ci.afterTyped(f, e.text);
            },
            .key => {
                const k = e.key orelse return false;
                const ctrl_key = k.key == .control_left or k.key == .control_right;
                const alt_key = k.key == .alt_left or k.key == .alt_right;
                ci.inline_info.modifiers(k.mods.ctrl or ctrl_key, k.mods.alt or alt_key);
                if (ci.inline_info.tick(ci.nowMs())) if (ci.win) |w| w.markAllDirty();
                if (isModifier(k.key)) return false;
                if (k.key == .escape and ci.linked_view == v) {
                    ci.linked.end();
                    ci.tick();
                    return true;
                }
                ci.comp_origin = e.origin;
                if (ci.completionKey(f, k)) return true;
                const showing = ci.popup.isOpen() or ci.hover.pending != null or ci.rest != null;
                if (!showing) return false;
                ci.hideHover();
                return k.key == .escape;
            },
        }
        return false;
    }

    /// The pointer over an inlay hint: its tooltip shows (resolved
    /// first); true when it is over one.
    fn inlayHover(ci: *CodeIntel, f: *File, e: PointerEvent) bool {
        const off = e.offset orelse return false;
        const hint = ci.inline_info.hintNear(f.h, off) orelse return false;
        ci.rest = null;
        if (ci.inlay_hover) |ih| if (ih.id == hint.id) return true;
        if (hint.raw != null) ci.inline_info.inlay.resolve(f.h, hint.id) catch {};
        ci.inlay_hover = .{ .h = f.h, .id = hint.id, .view = f.view, .origin = e.origin };
        ci.showInlayTooltip();
        ci.tick();
        return true;
    }

    fn showInlayTooltip(ci: *CodeIntel) void {
        if (ci.inlay_hover == null) return;
        const ih = &ci.inlay_hover.?;
        if (ih.shown) return;
        const hint = for (ci.inline_info.inlay.hints(ih.h)) |*x| {
            if (x.id == ih.id) break x;
        } else return;
        const tip = hint.tooltip orelse for (hint.parts) |p| {
            if (p.tooltip) |t| break t;
        } else return;
        const p0 = ih.view.posOf(hint.offset);
        ci.popup.win = ci.win;
        ci.popup.show(tip, .{ .x = ih.origin.x + p0.x, .y = ih.origin.y + p0.y, .w = 8, .h = ih.view.lineHeight() }) catch return;
        ih.shown = true;
    }

    /// Ctrl+click on an inlay hint part with a location goes there.
    fn inlayClick(ci: *CodeIntel, f: *File, off: u64) bool {
        const hint = ci.inline_info.hintNear(f.h, off) orelse return false;
        const loc = for (hint.parts) |p| {
            if (p.location) |l| break l;
        } else return false;
        const host = ci.pickers.host orelse return false;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const path = zg_codeintel.protocol_uri.pathFromUri(fba.allocator(), loc.uri) catch null;
        ci.hideHover();
        host.to(host.ctx, .{ .uri = loc.uri, .path = path, .selection = loc.range, .range = loc.range, .enc = loc.enc });
        return true;
    }

    fn isModifier(k: @FieldType(zg_gui.input.event.KeyPress, "key")) bool {
        return switch (k) {
            .shift_left, .shift_right, .control_left, .control_right, .alt_left, .alt_right, .meta_left, .meta_right => true,
            else => false,
        };
    }

    /// Keys for the completion list, signature help and snippet
    /// sessions; true when taken.
    fn completionKey(ci: *CodeIntel, f: *File, k: zg_gui.input.event.KeyPress) bool {
        const ctrl = k.mods.ctrl or k.mods.super;
        const plain = !ctrl and !k.mods.alt;
        if (ci.completionOpen(f.view)) {
            const ses = ci.completion.active().?;
            const n: u32 = @intCast(ses.list().len);
            const sel = ses.selected orelse 0;
            const page: u32 = @import("completion_popup.zig").max_rows - 1;
            const to: ?u32 = if (!plain or k.mods.shift) null else switch (k.key) {
                .arrow_down => (sel + 1) % n,
                .arrow_up => (sel + n - 1) % n,
                .page_down => @min(n - 1, sel + page),
                .page_up => sel -| page,
                .home => 0,
                .end => n - 1,
                else => null,
            };
            if (to) |t| {
                ci.completion.select(t);
                ci.tick();
                return true;
            }
            switch (k.key) {
                .enter, .numpad_enter => if (plain) {
                    ci.acceptCompletion(f, sel, if (k.mods.shift) .replace else .insert, null);
                    return true;
                },
                .tab => if (plain and !k.mods.shift) {
                    ci.acceptCompletion(f, sel, .insert, null);
                    return true;
                },
                .escape => {
                    ci.closeCompletion();
                    return true;
                },
                .arrow_left, .arrow_right => ci.closeCompletion(),
                .space => if (ctrl and !k.mods.shift) {
                    ci.cpopup.toggleDocs();
                    return true;
                },
                else => {},
            }
            return false;
        }
        if (k.key == .space and ctrl and !k.mods.alt) {
            if (!ci.trusted or !f.attached) return false;
            const head = f.view.primarySel().head;
            ci.comp_view = f.view;
            if (k.mods.shift) {
                ci.signature.invoke(f.h, head) catch {};
            } else {
                _ = ci.completion.start(f.h, head, .invoked) catch false;
            }
            ci.rememberCaret(f);
            ci.tick();
            return true;
        }
        if (ci.signature.current()) |st| if (ci.comp_view == f.view) {
            if (plain and !k.mods.shift and st.signatures.len > 1 and (k.key == .arrow_up or k.key == .arrow_down)) {
                _ = ci.signature.cycle(k.key == .arrow_down);
                ci.tick();
                return true;
            }
            if (k.key == .escape) {
                ci.closeSignature();
                return true;
            }
        };
        if (ci.snippets.top()) |t| if (t.view == f.view) {
            if (k.key == .tab and !ctrl and !k.mods.alt) {
                const ok = (if (k.mods.shift) ci.snippets.prev() else ci.snippets.next()) catch false;
                ci.rememberCaret(f);
                return ok;
            }
            if (k.key == .escape and plain) return ci.snippets.escape();
        };
        return false;
    }

    fn completionOpen(ci: *const CodeIntel, v: *EditorView) bool {
        const ses = ci.completion.active() orelse return false;
        return ci.comp_view == v and ses.list().len > 0;
    }

    /// Text about to be typed: a commit character accepts the selected
    /// item first (and is typed by the accept).
    fn onText(ci: *CodeIntel, f: *File, t: []const u8) bool {
        if (!ci.completionOpen(f.view)) return false;
        const ses = ci.completion.active().?;
        const sel = ses.selected orelse return false;
        if (!ci.completion.isCommit(sel, t)) return false;
        ci.acceptCompletion(f, sel, .insert, t);
        return true;
    }

    /// Text was typed into `f`: follow or start completion and
    /// signature help.
    fn afterTyped(ci: *CodeIntel, f: *File, t: []const u8) void {
        if (!ci.trusted or !f.attached or t.len == 0) return;
        const head = f.view.primarySel().head;
        var cp: u21 = t[t.len - 1];
        if (std.unicode.Utf8View.init(t)) |uv| {
            var it = uv.iterator();
            while (it.nextCodepoint()) |c| cp = c;
        } else |_| {}
        ci.comp_view = f.view;
        var is_open = ci.completion.active() != null;
        if (is_open) {
            const act = ci.completion.update(f.h, head) catch .close;
            is_open = act != .close;
        }
        if (!is_open) if (ci.completion.shouldTrigger(f.h, cp, ci.tokenClass(f, head))) |trig| {
            _ = ci.completion.start(f.h, head, trig) catch false;
        };
        ci.signature.onType(f.h, cp, head) catch {};
        if (ci.prefs) |p| if (p.format_on_type(p.ctx, f.h)) ci.format.onType(f.h, cp, head) catch {};
        ci.rememberCaret(f);
        ci.tick();
    }

    fn formatOptions(ctx: *anyopaque, h: DocHandle) zg_codeintel.protocol.FormattingOptions {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        return if (ci.prefs) |p| p.options(p.ctx, h) else FormatService.default_options;
    }

    fn structureOf(ctx: *anyopaque, h: DocHandle, gpa: Allocator) ?zg_syntax.Structure {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        const f = ci.fileOf(h) orelse return null;
        if (f.syntax.version != f.doc.version) return null;
        return f.syntax.fallbackStructure(gpa, &f.doc.tree) catch null;
    }

    /// The structure expand selection walks: the language's parser
    /// (node spans) where it has one, the fallback otherwise. Parsed
    /// here, on the UI thread: it runs on a key press.
    fn selectionStructureOf(ctx: *anyopaque, h: DocHandle, gpa: Allocator) ?zg_syntax.Structure {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        const f = ci.fileOf(h) orelse return null;
        const parse = f.syntax.lang.structure orelse return structureOf(ctx, h, gpa);
        const text = f.doc.tree.copyRange(gpa, .{ .start = 0, .end = f.doc.len() }) catch return null;
        defer gpa.free(text);
        return parse(gpa, text, f.doc.version) catch null;
    }

    fn onOutline(ctx: *anyopaque, h: DocHandle) void {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        ci.pickers.outlineChanged(h);
    }

    /// `quickOpen.symbolsInFile` over `view` showing `h`.
    pub fn symbolsInFile(ci: *CodeIntel, view: *EditorView, h: DocHandle) !void {
        const w = ci.win orelse return;
        try ci.pickers.openDocument(w, view, h, ci.nowMs());
        ci.tick();
    }

    /// `quickOpen.symbols`.
    pub fn symbolsInWorkspace(ci: *CodeIntel) !void {
        const w = ci.win orelse return;
        ci.pickers.now_ms = ci.nowMs();
        try ci.pickers.openWorkspace(w);
    }

    /// `editor.formatDocument`.
    pub fn formatDocument(ci: *CodeIntel, h: DocHandle) void {
        ci.refactor.win = ci.win;
        if (!ci.format.canFormat(h)) return ci.refactor.say(false, "No language server can format this file", .{});
        ci.format.document(h, .user) catch |e| ci.refactor.say(true, "Format failed: {t}", .{e});
        ci.tick();
    }

    /// `editor.formatSelection`: bytes `range` of `h` (the whole file
    /// when empty).
    pub fn formatSelection(ci: *CodeIntel, h: DocHandle, range: zg_codeintel.features.position.ByteRange) void {
        if (range.start == range.end) return ci.formatDocument(h);
        ci.refactor.win = ci.win;
        if (!ci.format.canFormatRanges(h)) return ci.refactor.say(false, "No language server can format a selection of this file", .{});
        ci.format.ranges(h, &.{range}, .user) catch |e| ci.refactor.say(true, "Format failed: {t}", .{e});
        ci.tick();
    }

    /// Runs the save pipeline for `h` (blocks for `plan.budget_ms` at
    /// most); a document with no attached server returns at once.
    pub fn beforeSave(ci: *CodeIntel, h: DocHandle, plan: SaveActions.Plan) SaveActions.Result {
        const f = ci.fileOf(h) orelse return .{};
        if (!ci.trusted or !f.attached) return .{};
        ci.format.cancel();
        const r = ci.save_actions.beforeSave(h, plan, ci.save_actions.clock());
        if (ci.win) |w| if (r.edited > 0) w.markAllDirty();
        return r;
    }

    fn tokenClass(_: *CodeIntel, f: *File, head: u64) CompletionService.TokenClass {
        if (head == 0) return .code;
        var q: zg_editor.model.syntax.SyntaxTokens = .{ .ds = f.syntax, .tree = &f.doc.tree };
        return switch (q.query().kindAt(head - 1)) {
            .comment => .comment,
            .string, .char, .regex => .string,
            .code => .code,
        };
    }

    fn rememberCaret(ci: *CodeIntel, f: *File) void {
        ci.last_caret = .{ .view = f.view, .head = f.view.primarySel().head, .version = f.doc.version };
    }

    /// Per frame: edits and caret moves that were not typing (deleting,
    /// arrows, clicks) refilter or close the list and the help.
    fn followCaret(ci: *CodeIntel, current: ?DocHandle, view: *EditorView) void {
        const f = ci.fileOf(current) orelse return;
        if (f.view != view) return;
        const head = view.primarySel().head;
        const lc = ci.last_caret;
        ci.rememberCaret(f);
        const same_view = lc != null and lc.?.view == view;
        if (same_view and lc.?.head == head and lc.?.version == f.doc.version) return;
        ci.snippets.cursorMoved();
        if (ci.comp_view != view) return;
        const edited = same_view and lc.?.version != f.doc.version;
        if (ci.completion.active() != null) _ = ci.completion.update(f.h, head) catch ci.completion.close();
        if (edited) ci.signature.onEdit(f.h, head) catch {} else ci.signature.cursorMoved(f.h, head);
    }

    fn acceptCompletion(ci: *CodeIntel, f: *File, pos: u32, mode: CompletionService.AcceptMode, commit: ?[]const u8) void {
        var vars: zg_codeintel.snippet.variables.Context = .{
            .io = ci.mgr.rt.io,
            .file_path = ci.docs.name(f.h),
            .workspace_folder = ci.cwd,
        };
        _ = ci.completion.accept(f.view, pos, mode, commit, &ci.snippets, vars.resolver()) catch |e| log.debug("completion accept: {t}", .{e});
        if (commit) |c| ci.afterTyped(f, c) else {
            ci.rememberCaret(f);
            ci.tick();
        }
        if (ci.win) |w| w.markAllDirty();
    }

    /// A row of the list was clicked.
    fn onPick(ctx: *anyopaque, pos: u32) void {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        const v = ci.comp_view orelse return;
        const f = ci.fileOfView(v) orelse return;
        ci.acceptCompletion(f, pos, .insert, null);
    }

    pub fn closeCompletion(ci: *CodeIntel) void {
        ci.completion.close();
        ci.showCompletion();
    }

    pub fn closeSignature(ci: *CodeIntel) void {
        ci.signature.close();
        ci.sig_seen = ci.signature.generation;
        ci.spopup.hide();
    }

    /// Whether the completion list shows (the AI ghost text waits).
    pub fn completionVisible(ci: *const CodeIntel) bool {
        return ci.comp_shown;
    }

    /// Opens, moves or closes the list after the engine changed.
    fn showCompletion(ci: *CodeIntel) void {
        ci.comp_seen = ci.completion.generation;
        ci.cpopup.win = ci.win;
        const v = ci.comp_view;
        const shown = blk: {
            const ses = ci.completion.active() orelse break :blk false;
            const view = v orelse break :blk false;
            if (ses.list().len == 0) break :blk false;
            if (ci.fileOf(ses.h)) |f| {
                if (f.view != view) break :blk false;
                ci.cpopup.lang = zg_codeintel.language.lspId(f.syntax.lang);
            }
            const p0 = view.posOf(ses.start);
            const rect: Rect = .{ .x = ci.comp_origin.x + p0.x, .y = ci.comp_origin.y + p0.y, .w = 1, .h = view.lineHeight() };
            ci.cpopup.editor_w = view.viewport.w;
            ci.cpopup.show(.{ .items = ses.items.items, .ranked = ses.list(), .ranker = &ses.ranker, .selected = ses.selected }, rect) catch |e| {
                log.warn("completion popup: {t}", .{e});
                break :blk false;
            };
            break :blk true;
        };
        if (!shown) ci.cpopup.hide();
        if (shown != ci.comp_shown) {
            ci.comp_shown = shown;
            if (v) |view| if (ci.popup_hook) |hk| hk.f(hk.ctx, view, shown);
        }
    }

    fn showSignature(ci: *CodeIntel) void {
        ci.sig_seen = ci.signature.generation;
        ci.spopup.win = ci.win;
        const st = ci.signature.current() orelse return ci.spopup.hide();
        const view = ci.comp_view orelse return ci.spopup.hide();
        const p0 = view.posOf(view.primarySel().head);
        const rect: Rect = .{ .x = ci.comp_origin.x + p0.x, .y = ci.comp_origin.y + p0.y, .w = 1, .h = view.lineHeight() };
        ci.spopup.show(st, rect) catch |e| log.warn("signature popup: {t}", .{e});
    }

    /// The pointer moved over `f`'s text.
    fn pointerAt(ci: *CodeIntel, f: *File, e: PointerEvent) void {
        ci.hide_due_ms = null;
        const off = e.offset orelse {
            ci.rest = null;
            if (ci.hover.current()) |r| if (r.source == .mouse) ci.hideHover();
            return;
        };
        // Still on the word shown (or being asked about): keep it.
        if (ci.hover.current()) |r| if (std.meta.eql(r.h, f.h) and off >= r.range.start and off < @max(r.range.end, r.range.start + 1)) return;
        const word = HoverService.wordAt(f.doc, off);
        if (ci.rest) |r| if (std.meta.eql(r.h, f.h)) {
            const rw = HoverService.wordAt(f.doc, r.offset);
            if (rw.start == word.start and rw.end == word.end) return;
        };
        if (ci.hover.current() != null or ci.hover.pending != null) ci.hideHover();
        ci.rest = .{ .h = f.h, .view = f.view, .offset = off, .origin = e.origin, .due_ms = ci.nowMs() + hover_delay_ms };
        ci.tick();
    }

    /// Asks for the hover at `offset` of `h` from the keyboard; `origin`
    /// is `view`'s text origin in window coordinates.
    pub fn showHoverAt(ci: *CodeIntel, view: *EditorView, h: DocHandle, offset: u64, origin: Vec2) !void {
        const f = ci.fileOf(h) orelse return error.NoLanguageServer;
        if (!ci.trusted or !f.attached) return error.NoLanguageServer;
        ci.hideHover();
        try ci.askHover(h, offset, .keyboard, view, origin);
        ci.tick();
    }

    fn askHover(ci: *CodeIntel, h: DocHandle, offset: u64, source: HoverService.Source, view: *EditorView, origin: Vec2) !void {
        ci.hover_at = .{ .view = view, .origin = origin };
        try ci.hover.request(h, offset, ci.diag.keyOfDoc(h), source);
    }

    /// `editor.rename` at byte `offset` of `h`.
    pub fn rename(ci: *CodeIntel, h: DocHandle, offset: u64) void {
        ci.refactor.win = ci.win;
        ci.refactor.startRename(h, offset);
        ci.tick();
    }

    /// `editor.quickFix` over `range` of `h` in `view`, whose text origin
    /// in the window is `origin`: the menu opens below the range's start.
    pub fn quickFix(ci: *CodeIntel, view: *EditorView, h: DocHandle, range: zg_codeintel.features.position.ByteRange, origin: Vec2) void {
        ci.hideHover();
        ci.refactor.win = ci.win;
        const p0 = view.posOf(range.start);
        const rect: Rect = .{ .x = origin.x + p0.x, .y = origin.y + p0.y, .w = 1, .h = view.lineHeight() };
        ci.refactor.quickFix(h, range, rect);
        ci.tick();
    }

    /// Hides the hover and forgets any asked.
    pub fn hideHover(ci: *CodeIntel) void {
        ci.hover.cancel();
        ci.hover_seen = ci.hover.generation;
        ci.popup.hide();
        ci.rest = null;
        ci.hide_due_ms = null;
        ci.hover_at = null;
    }

    /// Shows the current hover (or hides the popup when there is none).
    fn showHover(ci: *CodeIntel) void {
        ci.hover_seen = ci.hover.generation;
        const r = ci.hover.current() orelse return ci.popup.hide();
        const at = ci.hover_at orelse return;
        const v = at.view;
        const p0 = v.posOf(r.range.start);
        const p1 = v.posOf(r.range.end);
        const w = if (p1.y == p0.y and p1.x > p0.x) p1.x - p0.x else 8;
        const rect: Rect = .{ .x = at.origin.x + p0.x, .y = at.origin.y + p0.y, .w = w, .h = v.lineHeight() };
        ci.popup.win = ci.win;
        ci.popup.show(r.markdown, rect) catch |e| log.warn("hover: {t}", .{e});
    }

    /// Asks for `kind` at byte `offset` of `h` (references include the
    /// declaration when `include_decl`); `nav_hook` hears the answers.
    /// Returns the servers asked (0: none provides it).
    pub fn goTo(ci: *CodeIntel, kind: NavService.Kind, h: DocHandle, offset: u64, include_decl: bool) !u8 {
        const f = ci.fileOf(h) orelse return 0;
        if (!ci.trusted or !f.attached) return 0;
        const n = try ci.nav.go(kind, h, offset, include_decl);
        ci.nav_waiting = n > 0;
        ci.tick();
        return n;
    }

    /// Starts a hierarchy for the symbol at byte `offset` of `h`, listing
    /// `dir`. Returns the servers asked (0: none provides it).
    pub fn showHierarchy(ci: *CodeIntel, h: DocHandle, offset: u64, dir: HierarchyService.Direction) !u8 {
        const f = ci.fileOf(h) orelse return 0;
        if (!ci.trusted or !f.attached) return 0;
        const kind: HierarchyService.Kind = switch (dir) {
            .incoming, .outgoing => .calls,
            .supertypes, .subtypes => .types,
        };
        if (!ci.hierarchy.available(kind, h)) return 0;
        const n = try ci.hierarchy.prepare(h, offset, dir);
        ci.tick();
        return n;
    }

    /// `editor.expandSelection`: grows the selections of `view` (showing
    /// `h`) to the next syntax range around them.
    pub fn expandSelection(ci: *CodeIntel, view: *EditorView, h: DocHandle) void {
        ci.smart.expand(view, h);
        if (ci.trusted) ci.tick();
    }

    /// `editor.shrinkSelection`: back to the selection before the last
    /// expand.
    pub fn shrinkSelection(ci: *CodeIntel, view: *EditorView) void {
        ci.smart.shrink(view);
    }

    fn onLinkOpen(ctx: *anyopaque, kind: LinkDriver.TargetKind, target: []const u8) void {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        const hk = ci.link_hook orelse return;
        hk.open(hk.ctx, kind, target);
    }

    /// Puts the highlights for the caret's document into its editor's
    /// decorations.
    fn applyHighlights(ci: *CodeIntel) void {
        ci.hl_seen = ci.highlight.generation;
        const f = ci.fileOf(ci.highlight.marks_doc) orelse return ci.clearHighlights();
        const d = f.deco orelse return ci.clearHighlights();
        if (ci.hl_deco != null and ci.hl_deco != d) ci.clearHighlights();
        if (ci.hl_deco == null) {
            ci.hl_owner = d.ownerByName("lsp.highlight") orelse d.registerOwner("lsp.highlight", -10) catch return;
            ci.hl_deco = d;
        }
        const marks = ci.highlight.marksFor(f.h);
        var list: std.ArrayList(zg_editor.model.decorations.store.Decoration) = .empty;
        defer list.deinit(ci.gpa);
        list.ensureTotalCapacity(ci.gpa, marks.len * 2) catch return;
        for (marks) |m| {
            const st = switch (m.kind) {
                .text => style.occurrence,
                .read => style.read,
                .write => style.write,
            };
            list.appendAssumeCapacity(.{ .range = m.range, .owner = ci.hl_owner, .kind = .{ .highlight = st } });
            list.appendAssumeCapacity(.{ .range = m.range, .owner = ci.hl_owner, .kind = .{ .overview = .{ .lane = 1, .style = st } } });
        }
        d.setOwnerDecorations(ci.hl_owner, ci.highlight.marks_version, list.items) catch {};
    }

    /// A linked editing session started or ended: a caret in every range
    /// (the primary's column), drawn with `style.linked`; ending leaves
    /// the primary caret.
    fn applyLinked(ci: *CodeIntel) void {
        ci.linked_seen = ci.linked.generation;
        const ses = ci.linked.session orelse {
            if (ci.linked_view) |v| if (v.sels.items.items.len > 1) v.setSelection(.caret(v.primarySel().head));
            return ci.clearLinked();
        };
        const f = ci.fileOf(ses.h) orelse return ci.clearLinked();
        const rs = ci.linked.active(ses.h) orelse return ci.clearLinked();
        const p = ci.linked.primary();
        const head = f.view.primarySel().head;
        const col = head -| rs[p].start;
        var sels: std.ArrayList(zg_editor.model.edit.selection.Selection) = .empty;
        defer sels.deinit(ci.gpa);
        for (rs) |r| sels.append(ci.gpa, .caret(@min(r.start + col, r.end))) catch return;
        f.view.setSelections(sels.items, p) catch return;
        ci.linked_view = f.view;
        const d = f.deco orelse return;
        if (ci.linked_deco != null and ci.linked_deco != d) ci.clearLinked();
        ci.linked_view = f.view;
        if (ci.linked_deco == null) {
            ci.linked_owner = d.ownerByName("lsp.linked") orelse d.registerOwner("lsp.linked", -5) catch return;
            ci.linked_deco = d;
        }
        var list: std.ArrayList(zg_editor.model.decorations.store.Decoration) = .empty;
        defer list.deinit(ci.gpa);
        for (rs) |r| list.append(ci.gpa, .{ .range = .{ .start = r.start, .end = r.end }, .owner = ci.linked_owner, .stick = .grow_both, .kind = .{ .highlight = style.linked } }) catch return;
        d.setOwnerDecorations(ci.linked_owner, f.doc.version, list.items) catch {};
    }

    fn clearLinked(ci: *CodeIntel) void {
        ci.linked_view = null;
        const d = ci.linked_deco orelse return;
        d.clearOwner(ci.linked_owner);
        ci.linked_deco = null;
    }

    fn clearHighlights(ci: *CodeIntel) void {
        const d = ci.hl_deco orelse return;
        d.clearOwner(ci.hl_owner);
        ci.hl_deco = null;
    }

    fn tick(ci: *CodeIntel) void {
        ci.mgr.tick();
        var changed = ci.semtok.tick();
        _ = ci.diag.tick();
        changed = (ci.decor.flush() catch false) or changed;
        const now_ms = ci.nowMs();
        if (ci.rest) |r| if (now_ms >= r.due_ms) {
            ci.rest = null;
            ci.askHover(r.h, r.offset, .mouse, r.view, r.origin) catch {};
        };
        if (ci.hide_due_ms) |d| if (now_ms >= d) {
            const over = if (ci.win) |w| ci.popup.contains(w.hot) else false;
            if (over) ci.hide_due_ms = now_ms + hide_grace_ms else ci.hideHover();
        };
        if (ci.hover.tick() or ci.hover.generation != ci.hover_seen) ci.showHover();
        if (ci.highlight.tick() or ci.highlight.generation != ci.hl_seen) {
            ci.applyHighlights();
            changed = true;
        }
        if (ci.completion.tick() or ci.completion.generation != ci.comp_seen) ci.showCompletion();
        if (ci.signature.tick() or ci.signature.generation != ci.sig_seen) ci.showSignature();
        ci.refactor.win = ci.win;
        const refactor_due = ci.refactor.tick(now_ms);
        if (ci.outline.tick(now_ms)) changed = true;
        if (ci.linked.tick(now_ms) or ci.linked.generation != ci.linked_seen) {
            ci.applyLinked();
            changed = true;
        }
        if (ci.inline_info.tick(now_ms)) {
            changed = true;
            ci.showInlayTooltip();
        }
        _ = ci.ws_symbols.tick(now_ms);
        // The Hierarchy panel follows the service when it builds.
        if (ci.hierarchy.tick()) changed = true;
        if (ci.virtual.tick()) changed = true;
        ci.smart.tick();
        if (ci.smart.generation != ci.smart_seen) {
            ci.smart_seen = ci.smart.generation;
            changed = true;
        }
        if (ci.links.tick()) changed = true;
        ci.pickers.win = ci.win;
        ci.pickers.tick(now_ms);
        if (ci.format.tick()) {
            if (ci.format.failure.items.len > 0) ci.refactor.say(false, "{s}", .{ci.format.failure.items});
            changed = true;
        }
        if (ci.nav.tick() and ci.nav_waiting) if (ci.nav.results()) |r| if (r.complete) {
            ci.nav_waiting = false;
            if (ci.nav_hook) |hk| hk.done(hk.ctx, r);
        };
        const w = ci.win orelse return;
        if (changed) w.markAllDirty();
        if (ci.timer != .none) {
            w.cancelTimer(ci.timer);
            ci.timer = .none;
        }
        // The next due time, in ms from now.
        const now = std.Io.Clock.Timestamp.now(ci.semtok.io, .awake).raw.nanoseconds;
        var wait: ?u64 = null;
        for ([_]?i96{ ci.semtok.nextDue(), ci.diag.nextDue(), ci.highlight.nextDue(), ci.completion.nextDue(), ci.inline_info.lensDue(), ci.links.nextDue() }) |due| if (due) |d| {
            const ms: u64 = @intCast(@max(1, @divFloor(d - now, std.time.ns_per_ms) + 1));
            wait = if (wait) |x| @min(x, ms) else ms;
        };
        for ([_]?u64{ if (ci.rest) |r| r.due_ms else null, ci.hide_due_ms, refactor_due, ci.outline.nextDue(), ci.ws_symbols.nextDue(), ci.inline_info.nextDue(), ci.linked.nextDue() }) |due| if (due) |d| {
            const ms = @max(1, d -| now_ms);
            wait = if (wait) |x| @min(x, ms) else ms;
        };
        const ms = wait orelse return;
        ci.timer = w.setTimer(w.app.now_ms + ms, .{ .ctx = ci, .f = onTimer }) catch .none;
    }

    fn onTimer(ctx: *anyopaque, _: *Window) void {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        ci.timer = .none;
        ci.tick();
    }

    /// The target of posted wakes: `destroy` clears `ci`, and a wake
    /// still queued then frees the box when it runs.
    const WakeBox = struct {
        ci: ?*CodeIntel,
        gpa: Allocator,
        app: ?*zg_gui.App = null,
        /// A wake call is in the mailbox.
        posted: std.atomic.Value(bool) = .init(false),
    };

    fn waker(ci: *CodeIntel) zg_core.runtime.Waker {
        return .{ .ctx = ci.wake_box, .wakeFn = wake };
    }

    /// Any thread: a server answered; tick on the UI thread.
    fn wake(ctx: ?*anyopaque) void {
        const box: *WakeBox = @ptrCast(@alignCast(ctx.?));
        if (box.posted.swap(true, .acq_rel)) return;
        const app = box.app orelse (box.ci orelse return).app;
        app.post(.{ .ctx = box, .f = onWake }) catch box.posted.store(false, .release);
    }

    fn onWake(ctx: *anyopaque, _: *zg_gui.App) void {
        const box: *WakeBox = @ptrCast(@alignCast(ctx));
        box.posted.store(false, .release);
        const ci = box.ci orelse return box.gpa.destroy(box);
        if (ci.trusted) ci.tick();
    }

    fn onDocChange(ctx: *anyopaque, _: *const zg_editor.model.document.ChangeEvent) void {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        wake(ci.wake_box);
    }

    fn syntaxOf(ctx: *anyopaque, h: DocHandle) ?*DocumentSyntax {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        for (ci.files.items) |f| if (std.meta.eql(f.h, h)) return f.syntax;
        return null;
    }
};

test "codeintel: servers wait for trust; missing servers are reported" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var app = zg_gui.App.init(gpa);
    defer app.deinit();
    var docs: DocumentRegistry = .init(gpa, .native);
    defer docs.deinit();
    var langs = try zg_syntax.defaultRegistry(gpa);
    defer langs.deinit(gpa);
    const path = if (@import("builtin").os.tag == .windows) "C:\\w\\main.zig" else "/w/main.zig";
    const h = try docs.openFile(path, "const a = 1;\n");
    defer docs.release(h);
    const doc = docs.get(h).?;
    var sx = try DocumentSyntax.init(gpa, langs.get(.zig).?, &langs, &doc.tree, doc.version);
    defer sx.deinit();
    const view = try EditorView.init(gpa, doc, .{});
    defer view.deinit();
    // No PATH: zls cannot be found.
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    var deco: DecorationStore = .init(gpa, doc);
    defer deco.deinit();

    const ci = try CodeIntel.create(&rt, &env, &app, &docs, std.fs.path.dirname(path).?);
    defer ci.destroy();
    ci.open(h, &sx, view, &deco);
    try testing.expect(view.hl_names == ci.highlightNames());
    // Expand selection works without a server, on the editor's own
    // structure; shrink steps back to where it started.
    view.setSelection(.caret(6));
    ci.expandSelection(view, h);
    const s1 = view.primarySel();
    try testing.expect(!s1.isCaret() and s1.start() <= 6 and s1.end() >= 6);
    ci.expandSelection(view, h);
    const s2 = view.primarySel();
    try testing.expect(s2.start() <= s1.start() and s2.end() >= s1.end() and (s2.start() < s1.start() or s2.end() > s1.end()));
    ci.shrinkSelection(view);
    try testing.expect(view.primarySel().start() == s1.start() and view.primarySel().end() == s1.end());
    ci.shrinkSelection(view);
    try testing.expect(view.primarySel().isCaret() and view.primarySel().head == 6);
    // Nothing more to shrink.
    ci.shrinkSelection(view);
    try testing.expect(view.primarySel().isCaret() and view.primarySel().head == 6);
    // Hovers and Ctrl+click go through the view's pointer hook; nothing
    // is asked before the folder is trusted.
    const hk = view.pointer_hook.?;
    try testing.expect(!hk.f(hk.ctx, view, .{ .kind = .click, .offset = 6 }));
    _ = hk.f(hk.ctx, view, .{ .kind = .move, .offset = 6 });
    try testing.expect(ci.rest == null);
    // Diagnostic styles take the theme's colours; others the view's.
    const sc = view.styles.?;
    try testing.expectEqual(app.theme.color(.danger), sc.color(sc.ctx, CodeIntel.style.err).?);
    try testing.expect(sc.color(sc.ctx, @enumFromInt(0)) == null);
    ci.frame(h, view);
    try testing.expectEqual(@as(usize, 0), ci.mgr.serverList().len);

    ci.setTrusted(true);
    var i: usize = 0;
    while (ci.mgr.serverList().len == 0 and i < 1000) : (i += 1) {
        _ = app.drainMessages();
        ci.frame(h, view);
        try rt.io.sleep(.fromMilliseconds(2), .awake);
    }
    try testing.expectEqual(Manager.Status.missing, ci.mgr.serverList()[0].status);
    try testing.expectEqualStrings("zls", ci.mgr.serverList()[0].def.id);
    // No server has the file: the agent's edit result gets nothing, at
    // once.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ad = ci.agentDiagnostics();
    try testing.expect((try ad.after_edit(ad.ctx, rt.io, arena.allocator(), path)) == null);
    // The language tools: three read-only tools; the store answers
    // diagnostics without the UI thread.
    const tools = ci.agentTools();
    try testing.expectEqual(@as(usize, 3), (try tools.list(tools.ctx, arena.allocator())).len);
    const r = try tools.call(tools.ctx, rt.io, arena.allocator(), "lsp_diagnostics", "{\"path\": \"main.zig\"}");
    try testing.expect(std.mem.indexOf(u8, r.json, "No diagnostics for main.zig") != null);
    // Trusted, but no server: the pointer resting still waits for a
    // hover (diagnostics alone can make one); no definition provider.
    _ = hk.f(hk.ctx, view, .{ .kind = .move, .offset = 6 });
    try testing.expect(ci.rest != null);
    try testing.expect(!hk.f(hk.ctx, view, .{ .kind = .click, .offset = 6 }));
    try testing.expectEqual(@as(u8, 0), try ci.goTo(.definition, h, 6, false));
    _ = hk.f(hk.ctx, view, .{ .kind = .leave });
    try testing.expect(ci.rest == null);
    // No server renames or offers actions: a notice, no box or menu, and
    // no lightbulb wait.
    const Notices = struct {
        last: [128]u8 = undefined,
        len: usize = 0,
        fn f(ctx: *anyopaque, _: bool, msg: []const u8) void {
            const n: *@This() = @ptrCast(@alignCast(ctx));
            n.len = @min(msg.len, n.last.len);
            @memcpy(n.last[0..n.len], msg[0..n.len]);
        }
    };
    var notices: Notices = .{};
    ci.refactor.notice = .{ .ctx = &notices, .f = Notices.f };
    ci.rename(h, 6);
    try testing.expectEqualStrings("No language server can rename here", notices.last[0..notices.len]);
    ci.quickFix(view, h, .{ .start = 6, .end = 6 }, .{});
    try testing.expectEqualStrings("No language server offers code actions here", notices.last[0..notices.len]);
    try testing.expect(ci.refactor.rest == null and ci.refactor.menu_at == null);
    try testing.expectEqual(app.theme.color(.warning), sc.color(sc.ctx, CodeIntel.style.bulb_preferred).?);
    ci.formatDocument(h);
    try testing.expectEqualStrings("No language server can format this file", notices.last[0..notices.len]);
    ci.formatSelection(h, .{ .start = 0, .end = 5 });
    try testing.expectEqualStrings("No language server can format a selection of this file", notices.last[0..notices.len]);
    // Not attached: the save pipeline returns at once.
    const sr = ci.beforeSave(h, .{ .format = true });
    try testing.expect(!sr.timed_out and sr.edited == 0);
    ci.close(h);
    try testing.expect(view.pointer_hook == null);
}
