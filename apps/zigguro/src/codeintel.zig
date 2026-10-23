//! Language services in the workbench (E07): one zg_codeintel `Manager`
//! for the working folder, which starts language servers (zls, clangd,
//! ...) as matching files open; the semantic tokens driver, which
//! colours the editors through their `DocumentSyntax` overlays; and the
//! diagnostics driver, whose store the agent's edit tools read back
//! through the settle detector (`agentDiagnostics`). The agent also gets
//! language-server tools (`agentTools`: diagnostics, hover, definition).
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
const Manager = zg_codeintel.Manager;
const SemTokDriver = zg_codeintel.features.SemTokDriver;
const diagnostics = zg_codeintel.diagnostics;
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
    lsp_tools: LspTools = undefined,
    files: std.ArrayList(File) = .empty,
    trusted: bool = false,
    /// A wake call is in the mailbox.
    wake_posted: std.atomic.Value(bool) = .init(false),
    timer: Window.TimerId = .none,
    /// The editor last reported visible.
    shown: ?DocHandle = null,

    const File = struct {
        h: DocHandle,
        doc: *Document,
        syntax: *DocumentSyntax,
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
        try ci.semtok.init(&ci.mgr, &ci.names, .{ .ctx = ci, .get = syntaxOf }, .{ .waker = ci.waker() });
        ci.lsp_tools = .{ .src = .{ .mgr = &ci.mgr, .store = &ci.diags, .roots = (&ci.cwd)[0..1], .ui = .{ .ctx = ci, .run = runOnUi } } };
        return ci;
    }

    /// Shuts the servers down (blocks briefly) and frees everything. Call
    /// before the documents and their syntax go away.
    pub fn destroy(ci: *CodeIntel) void {
        if (ci.win) |w| if (ci.timer != .none) w.cancelTimer(ci.timer);
        for (ci.files.items) |f| if (f.listener) |l| f.doc.unsubscribe(l);
        ci.mgr.deinit();
        ci.diag.deinit();
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

    /// A file with highlighting opened in `view` (files without a known
    /// language get no language services).
    pub fn open(ci: *CodeIntel, h: DocHandle, syntax: ?*DocumentSyntax, view: *EditorView) void {
        const sx = syntax orelse return;
        view.hl_names = &ci.names;
        for (ci.files.items) |f| if (std.meta.eql(f.h, h)) return;
        ci.files.append(ci.gpa, .{ .h = h, .doc = ci.docs.get(h) orelse return, .syntax = sx }) catch return;
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
        f.attached = true;
    }

    /// The file closes (before its view and syntax are freed).
    pub fn close(ci: *CodeIntel, h: DocHandle) void {
        for (ci.files.items, 0..) |f, i| if (std.meta.eql(f.h, h)) {
            if (f.attached) {
                ci.semtok.untrack(h);
                ci.mgr.closeDoc(h);
            }
            if (f.listener) |l| f.doc.unsubscribe(l);
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
        ci.tick();
    }

    fn tick(ci: *CodeIntel) void {
        ci.mgr.tick();
        const changed = ci.semtok.tick();
        _ = ci.diag.tick();
        const w = ci.win orelse return;
        if (changed) w.markAllDirty();
        if (ci.timer != .none) {
            w.cancelTimer(ci.timer);
            ci.timer = .none;
        }
        const a = ci.semtok.nextDue();
        const b = ci.diag.nextDue();
        const due = if (a != null and b != null) @min(a.?, b.?) else a orelse b orelse return;
        const now = std.Io.Clock.Timestamp.now(ci.semtok.io, .awake).raw.nanoseconds;
        const ms: u64 = @intCast(@max(1, @divFloor(due - now, std.time.ns_per_ms) + 1));
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

    const ci = try CodeIntel.create(&rt, &env, &app, &docs, std.fs.path.dirname(path).?);
    defer ci.destroy();
    ci.open(h, &sx, view);
    try testing.expect(view.hl_names == ci.highlightNames());
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
    ci.close(h);
}
