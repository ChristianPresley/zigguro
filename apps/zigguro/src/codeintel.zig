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
const HoverPopup = @import("hover_popup.zig").HoverPopup;
const PointerEvent = zg_editor.view.editor_view.PointerEvent;
const Vec2 = zg_gui.core.Vec2;
const Rect = zg_gui.core.Rect;
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
    /// A wake call is in the mailbox.
    wake_posted: std.atomic.Value(bool) = .init(false),
    timer: Window.TimerId = .none,
    /// The editor last reported visible.
    shown: ?DocHandle = null,
    hover: HoverService = undefined,
    highlight: HighlightService = undefined,
    nav: NavService = undefined,
    popup: HoverPopup,
    /// Where the pointer rests: a hover is asked at `due_ms`.
    rest: ?struct { h: DocHandle, view: *EditorView, offset: u64, origin: Vec2, due_ms: u64 } = null,
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
        };
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
        ci.popup.deinit();
        ci.mgr.deinit();
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
        if (f.deco) |d| if (ci.diag.keyOfDoc(f.h)) |k| ci.decor.attach(k, d) catch {};
        f.attached = true;
    }

    /// The file closes (before its view and syntax are freed).
    pub fn close(ci: *CodeIntel, h: DocHandle) void {
        for (ci.files.items, 0..) |f, i| if (std.meta.eql(f.h, h)) {
            if (f.attached) {
                if (f.deco) |d| ci.decor.detach(d);
                ci.semtok.untrack(h);
                ci.mgr.closeDoc(h);
            }
            if (f.listener) |l| f.doc.unsubscribe(l);
            ci.unhook(f.view);
            if (f.deco != null and f.deco == ci.hl_deco) ci.clearHighlights();
            if (ci.hover_at) |a| if (a.view == f.view) ci.hideHover();
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
        }
        const sel = view.primarySel();
        ci.highlight.onCursor(if (ci.fileOf(current)) |f| if (f.view == view and sel.anchor == sel.head) f.h else null else null, sel.head);
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
            .move => ci.pointerAt(f, e),
            .leave => {
                ci.rest = null;
                if (ci.hover.current() != null and ci.hover.current().?.source == .mouse) ci.hide_due_ms = ci.nowMs() + hide_grace_ms;
                ci.tick();
            },
            .click => {
                const off = e.offset orelse return false;
                if (!ci.nav.available(.definition, f.h)) return false;
                ci.hideHover();
                _ = ci.goTo(.definition, f.h, off, false) catch return false;
                return true;
            },
            .key => {
                const k = e.key orelse return false;
                if (isModifier(k.key)) return false;
                const showing = ci.popup.isOpen() or ci.hover.pending != null or ci.rest != null;
                if (!showing) return false;
                ci.hideHover();
                return k.key == .escape;
            },
        }
        return false;
    }

    fn isModifier(k: @FieldType(zg_gui.input.event.KeyPress, "key")) bool {
        return switch (k) {
            .shift_left, .shift_right, .control_left, .control_right, .alt_left, .alt_right, .meta_left, .meta_right => true,
            else => false,
        };
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
        for ([_]?i96{ ci.semtok.nextDue(), ci.diag.nextDue(), ci.highlight.nextDue() }) |due| if (due) |d| {
            const ms: u64 = @intCast(@max(1, @divFloor(d - now, std.time.ns_per_ms) + 1));
            wait = if (wait) |x| @min(x, ms) else ms;
        };
        for ([_]?u64{ if (ci.rest) |r| r.due_ms else null, ci.hide_due_ms }) |due| if (due) |d| {
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

    fn waker(ci: *CodeIntel) zg_core.runtime.Waker {
        return .{ .ctx = ci, .wakeFn = wake };
    }

    /// Any thread: a server answered; tick on the UI thread.
    fn wake(ctx: ?*anyopaque) void {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx.?));
        if (ci.wake_posted.swap(true, .acq_rel)) return;
        ci.app.post(.{ .ctx = ci, .f = onWake }) catch ci.wake_posted.store(false, .release);
    }

    fn onWake(ctx: *anyopaque, _: *zg_gui.App) void {
        const ci: *CodeIntel = @ptrCast(@alignCast(ctx));
        ci.wake_posted.store(false, .release);
        if (ci.trusted) ci.tick();
    }

    fn onDocChange(ctx: *anyopaque, _: *const zg_editor.model.document.ChangeEvent) void {
        wake(ctx);
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
    ci.close(h);
    try testing.expect(view.pointer_hook == null);
}
