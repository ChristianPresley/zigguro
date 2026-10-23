//! Ghost-text completions in the editor (E12.F07.S01). `Service` picks the
//! provider once per workbench; `EditorCompletions` binds one editor to
//! E12's `CompletionEngine` and `Controller`.
//!
//! Providers, from the environment:
//! - `ZG_COMPLETION_URL` (with `ZG_COMPLETION_KIND` = `llamacpp` (default),
//!   `ollama` or `openai`, `ZG_COMPLETION_MODEL`, `ZG_COMPLETION_TEMPLATE`
//!   for `openai` (default `qwen2.5-coder`) and `ZG_COMPLETION_API_KEY`): a
//!   FIM server. Plain HTTP is allowed only on loopback unless
//!   `ZG_COMPLETION_INSECURE=1`.
//! - Otherwise a chat model through E10 when a provider key is set
//!   (`ANTHROPIC_API_KEY`, ...): `ZG_COMPLETION_MODEL`, else `haiku`.
//! - Otherwise completions are off.
//!
//! Each editor gets its own decoration store (when the view has none) so
//! the ghost can draw, a document listener after the store's, one window
//! timer armed from the engine's next deadline, and posted callbacks that
//! bring provider text back to the UI thread. The workbench forwards caret
//! moves (`onCaret`), keys (`onKey`) and focus.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_ai = @import("zg_ai");
const zg_net = @import("zg_net");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");
const zg_review = @import("zg_review");
const ChatCompletionPort = @import("../agent/chat_completion_port.zig").ChatCompletionPort;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const complete = zg_review.assist.complete;
const model = zg_editor.model;
const Document = model.document.Document;
const DecorationStore = model.decorations.store.DecorationStore;
const EditorView = zg_editor.view.EditorView;
const Window = zg_gui.core.Window;
const log = std.log.scoped(.completions);

/// The workbench's completion provider.
pub const Service = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    client: ?*zg_net.http.Client = null,
    http: ?complete.HttpFim = null,
    chat: ?*Chat = null,
    /// Completions are on (`completions.toggle`).
    enabled: bool = true,
    /// What the status bar says the provider is.
    label: []const u8 = "off",
    /// The chat model resolved and its provider is bound.
    chat_ready: bool = false,
    /// A provider that wins over the configured ones (tests).
    fixed: ?complete.FimProvider = null,

    const Chat = struct {
        models: zg_ai.ModelRegistry,
        net: zg_ai.transport.ZgNet,
        limiter: zg_ai.ratelimit.RateLimiter,
        hub: *zg_ai.ProviderHub,
        port: ChatCompletionPort,
        fim: complete.ChatFim,
    };

    pub fn create(rt: *zg_core.Runtime, env: *const std.process.Environ.Map, app: *zg_gui.App) !*Service {
        const gpa = rt.gpa;
        const s = try gpa.create(Service);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = rt.io, .app = app };
        errdefer s.deinitParts();
        if (env.get("ZG_COMPLETION_URL")) |url| {
            s.client = try zg_net.http.Client.init(rt, .{ .environ_map = env });
            const kind = env.get("ZG_COMPLETION_KIND") orelse "llamacpp";
            const mdl = env.get("ZG_COMPLETION_MODEL") orelse "";
            const opts: complete.providers.HttpOptions = if (std.mem.eql(u8, kind, "ollama"))
                .{ .ollama = .{ .base_url = url, .model = mdl } }
            else if (std.mem.eql(u8, kind, "openai"))
                .{ .oai_completions = .{
                    .base_url = url,
                    .model = mdl,
                    .template = complete.fim.find(complete.fim.catalog, env.get("ZG_COMPLETION_TEMPLATE") orelse "qwen2.5-coder") orelse return error.UnknownTemplate,
                } }
            else
                .{ .llamacpp = .{ .base_url = url } };
            s.http = complete.HttpFim.init(gpa, s.client.?, opts, .{
                .api_key = env.get("ZG_COMPLETION_API_KEY"),
                .allow_insecure_http = std.mem.eql(u8, env.get("ZG_COMPLETION_INSECURE") orelse "", "1"),
            }) catch |e| {
                log.warn("completions: {s}: {t}", .{ url, e });
                return s;
            };
            s.label = kind;
            return s;
        }
        if (env.get("ANTHROPIC_API_KEY") == null and env.get("OPENAI_API_KEY") == null and env.get("GEMINI_API_KEY") == null) return s;
        s.client = try zg_net.http.Client.init(rt, .{ .environ_map = env });
        const c = try gpa.create(Chat);
        s.chat = c;
        c.models = .init(gpa, rt.io, zg_ai.models.registry.builtin_catalog);
        c.net = .{ .client = s.client.? };
        c.limiter = .init(gpa, .real);
        c.hub = try zg_ai.ProviderHub.init(gpa, .{
            .secrets = no_secrets,
            .environ = env,
            .transport = c.net.transport(),
            .limiter = &c.limiter,
            .registry = &c.models,
            .notifier = .{ .ctx = s, .warn = warn, .redact = redact },
        });
        try c.hub.onSettingsChanged(rt.io, &.{});
        const name = env.get("ZG_COMPLETION_MODEL") orelse "haiku";
        const info = c.models.resolve(name) orelse return s;
        const p = c.hub.forModel(info) orelse return s;
        c.port = .{ .provider = p };
        c.fim = .{ .opts = .{ .port = c.port.port(), .model = info.id } };
        s.chat_ready = true;
        s.label = "chat";
        return s;
    }

    pub fn destroy(s: *Service) void {
        s.deinitParts();
        s.gpa.destroy(s);
    }

    fn deinitParts(s: *Service) void {
        if (s.chat) |c| {
            c.hub.deinit();
            c.limiter.deinit();
            c.models.deinit();
            s.gpa.destroy(c);
            s.chat = null;
        }
        if (s.client) |c| c.deinit();
        s.client = null;
    }

    /// The provider, or null when completions are not configured.
    pub fn provider(s: *Service) ?complete.FimProvider {
        if (s.fixed) |p| return p;
        if (s.http) |*h| return h.provider();
        if (s.chat) |c| if (s.chat_ready) return c.fim.provider();
        return null;
    }

    fn warn(_: *anyopaque, msg: []const u8) void {
        log.warn("{s}", .{msg});
    }

    fn redact(_: *anyopaque, _: []const u8) void {}
};

const no_secrets: zg_ai.keyref.SecretStore = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .vtable = &.{ .get = getNone, .put = putNone } };

fn getNone(_: *anyopaque, _: Io, _: []const u8) zg_ai.keyref.SecretError!?[]const u8 {
    return null;
}

fn putNone(_: *anyopaque, _: Io, _: []const u8, _: []const u8) zg_ai.keyref.SecretError!void {
    return error.Unavailable;
}

/// Ghost-text completions for one editor.
pub const EditorCompletions = struct {
    gpa: Allocator,
    svc: *Service,
    win: *Window,
    view: *EditorView,
    doc: *Document,
    path: []u8,
    store: ?*DecorationStore = null,
    engine: complete.CompletionEngine,
    ctl: complete.Controller,
    store_listener: ?model.document.ListenerId = null,
    listener: model.document.ListenerId = undefined,
    timer: ?Window.TimerId = null,
    last_head: u64 = 0,
    last_version: u64 = 0,

    const doc_id = 1;

    /// Null when no provider is configured or the view draws another
    /// decoration store.
    pub fn attach(gpa: Allocator, svc: *Service, win: *Window, view: *EditorView, path: ?[]const u8) !?*EditorCompletions {
        const p = svc.provider() orelse return null;
        if (view.decorations != null) return null;
        const ec = try gpa.create(EditorCompletions);
        errdefer gpa.destroy(ec);
        const doc = view.doc;
        const store = try gpa.create(DecorationStore);
        errdefer gpa.destroy(store);
        store.* = .init(gpa, doc);
        errdefer store.deinit();
        const owner = try store.registerOwner("ai.ghost", 20);
        ec.* = .{
            .gpa = gpa,
            .svc = svc,
            .win = win,
            .view = view,
            .doc = doc,
            .path = try gpa.dupe(u8, path orelse "untitled"),
            .store = store,
            .engine = undefined,
            .ctl = undefined,
            .last_head = view.primarySel().head,
            .last_version = doc.version,
        };
        errdefer gpa.free(ec.path);
        ec.engine = .init(gpa, svc.io, p, ec.host(), .{}, 1);
        errdefer ec.engine.deinit();
        try ec.engine.open(doc_id, doc.version);
        ec.ctl = .init(gpa, doc, doc_id, store, owner, &ec.engine, .{});
        ec.store_listener = try doc.subscribe(store.listener());
        errdefer doc.unsubscribe(ec.store_listener.?);
        ec.listener = try doc.subscribe(.{ .ctx = ec, .onChange = onChange });
        view.decorations = store;
        return ec;
    }

    pub fn detach(ec: *EditorCompletions) void {
        if (ec.timer) |t| ec.win.cancelTimer(t);
        ec.doc.unsubscribe(ec.listener);
        ec.ctl.deinit();
        ec.engine.deinit();
        if (ec.store) |s| {
            if (ec.view.decorations == s) ec.view.decorations = null;
            if (ec.store_listener) |l| ec.doc.unsubscribe(l);
            s.deinit();
            ec.gpa.destroy(s);
        }
        ec.gpa.free(ec.path);
        ec.gpa.destroy(ec);
    }

    fn nowNs(ec: *const EditorCompletions) u64 {
        return ec.win.app.now_ms * std.time.ns_per_ms;
    }

    fn language(ec: *const EditorCompletions) []const u8 {
        const ext = std.fs.path.extension(ec.path);
        return if (ext.len > 1) ext[1..] else "";
    }

    /// Keys for the ghost: Tab accepts (false: not handled, so Tab indents),
    /// Ctrl/Cmd+Right accepts a word, Escape dismisses, Alt+\ asks now.
    pub fn onKey(ec: *EditorCompletions, k: zg_gui.input.event.KeyPress) bool {
        const now = ec.nowNs();
        const ctrl = k.mods.ctrl or k.mods.super;
        const handled = switch (k.key) {
            .tab => !k.mods.shift and !ctrl and (ec.ctl.accept(.all, now) catch false),
            .arrow_right => ctrl and !k.mods.shift and (ec.ctl.accept(.word, now) catch false),
            .escape => blk: {
                if (!ec.ctl.visible()) break :blk false;
                ec.ctl.dismiss(.escape);
                break :blk true;
            },
            .backslash => blk: {
                if (!k.mods.alt) break :blk false;
                ec.trigger();
                break :blk true;
            },
            else => false,
        };
        if (handled) ec.changed();
        return handled;
    }

    /// `completions.trigger`.
    pub fn trigger(ec: *EditorCompletions) void {
        ec.engine.invoke(doc_id, ec.nowNs());
        ec.rearm();
    }

    /// `completions.snooze`.
    pub fn snooze(ec: *EditorCompletions) void {
        ec.ctl.snooze(ec.nowNs());
        ec.changed();
    }

    /// `completions.acceptLine`.
    pub fn acceptLine(ec: *EditorCompletions) bool {
        const ok = ec.ctl.accept(.line, ec.nowNs()) catch false;
        if (ok) ec.changed();
        return ok;
    }

    /// Focus left the editor.
    pub fn blur(ec: *EditorCompletions) void {
        ec.ctl.dismiss(.focus_lost);
        ec.changed();
    }

    /// The status bar's text.
    pub fn statusText(ec: *const EditorCompletions) []const u8 {
        if (!ec.svc.enabled) return "AI: off";
        return switch (ec.ctl.status(ec.nowNs())) {
            .ready => "AI",
            .requesting => "AI …",
            .snoozed => "AI: snoozed",
            .disabled_language => "AI: off here",
            .unhealthy => "AI: unavailable",
        };
    }

    /// The caret moved (the view's `on_caret`). A move that an edit made
    /// is not a cursor move.
    pub fn onCaret(ec: *EditorCompletions) void {
        const head = ec.view.primarySel().head;
        defer ec.last_head = head;
        if (ec.doc.version != ec.last_version) {
            ec.last_version = ec.doc.version;
            return;
        }
        if (head == ec.last_head) return;
        ec.ctl.onCursorMove(ec.sameLine(ec.last_head, head), ec.nowNs());
        ec.rearm();
    }

    fn sameLine(ec: *EditorCompletions, a: u64, b: u64) bool {
        const lo = @min(a, b);
        const hi = @max(a, b);
        if (hi - lo > 4096) return false;
        var buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const t = ec.doc.tree.copyRange(fba.allocator(), .{ .start = lo, .end = hi }) catch return false;
        return std.mem.indexOfScalar(u8, t, '\n') == null;
    }

    fn onChange(ctx: *anyopaque, ev: *const model.document.ChangeEvent) void {
        const ec: *EditorCompletions = @ptrCast(@alignCast(ctx));
        ec.ctl.onChange(ev, ec.nowNs()) catch |e| log.warn("completions: {t}", .{e});
        ec.rearm();
    }

    /// The gate for a request now.
    fn gateNow(ec: *EditorCompletions) complete.Gate {
        const sels = ec.view.selections();
        const sel = ec.view.primarySel();
        var after_buf: [256]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&after_buf);
        const end = @min(ec.doc.len(), sel.head + after_buf.len);
        const after_raw = ec.doc.tree.copyRange(fba.allocator(), .{ .start = sel.head, .end = end }) catch "";
        const after = after_raw[0 .. std.mem.indexOfScalar(u8, after_raw, '\n') orelse after_raw.len];
        return ec.engine.gate(.{
            .language_disabled = !ec.svc.enabled,
            .snoozed = ec.ctl.snoozed(ec.nowNs()),
            .carets = @intCast(sels.len),
            .selection = sel.anchor != sel.head,
            .doc_bytes = ec.doc.len(),
            .after = after,
        });
    }

    /// Arms the window timer for the engine's next deadline.
    fn rearm(ec: *EditorCompletions) void {
        if (ec.timer) |t| ec.win.cancelTimer(t);
        ec.timer = null;
        const at_ns = ec.engine.nextDeadline() orelse return;
        const at_ms = (at_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        ec.timer = ec.win.setTimer(at_ms, .{ .ctx = ec, .f = onTimer }) catch null;
    }

    fn onTimer(ctx: *anyopaque, _: *Window) void {
        const ec: *EditorCompletions = @ptrCast(@alignCast(ctx));
        ec.timer = null;
        if (ec.gateNow() != .ok) {
            ec.engine.dismiss(doc_id);
        } else {
            ec.engine.tick(ec.nowNs()) catch |e| log.warn("completions: {t}", .{e});
        }
        ec.rearm();
    }

    fn changed(ec: *EditorCompletions) void {
        ec.win.markAllDirty();
        ec.rearm();
    }

    // -- engine host ----------------------------------------------------------

    fn host(ec: *EditorCompletions) complete.engine.Host {
        return .{ .ctx = ec, .snapshot = snapshot, .post = post, .deliver = deliver, .failed = failed };
    }

    fn snapshot(ctx: *anyopaque, _: u64, arena: Allocator) anyerror!?complete.engine.Snapshot {
        const ec: *EditorCompletions = @ptrCast(@alignCast(ctx));
        const text = try ec.doc.tree.copyRange(arena, .{ .start = 0, .end = ec.doc.len() });
        return .{
            .text = text,
            .cursor = @intCast(ec.view.primarySel().head),
            .version = ec.doc.version,
            .options = .{ .path = try arena.dupe(u8, ec.path), .language = try arena.dupe(u8, ec.language()) },
        };
    }

    fn post(ctx: *anyopaque, arg: *anyopaque) void {
        const ec: *EditorCompletions = @ptrCast(@alignCast(ctx));
        ec.win.app.post(.{ .ctx = arg, .f = runPosted }) catch log.warn("completions: mailbox full", .{});
    }

    fn runPosted(arg: *anyopaque, _: *zg_gui.App) void {
        complete.CompletionEngine.runPosted(arg);
    }

    fn deliver(ctx: *anyopaque, d: complete.engine.Delivery) void {
        const ec: *EditorCompletions = @ptrCast(@alignCast(ctx));
        ec.ctl.onDelivery(d, ec.nowNs()) catch |e| log.warn("completions: {t}", .{e});
        ec.changed();
    }

    fn failed(ctx: *anyopaque, err: anyerror) void {
        const ec: *EditorCompletions = @ptrCast(@alignCast(ctx));
        log.info("completion failed: {t}", .{err});
        ec.ctl.onFailed();
        ec.changed();
    }
};

const testing = std.testing;

test "completions: provider from the environment" {
    const gpa = testing.allocator;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var app = zg_gui.App.init(gpa);
    defer app.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    const off = try Service.create(&rt, &env, &app);
    defer off.destroy();
    try testing.expect(off.provider() == null);
    try testing.expectEqualStrings("off", off.label);

    try env.put("ZG_COMPLETION_URL", "http://127.0.0.1:8012");
    try env.put("ZG_COMPLETION_KIND", "ollama");
    try env.put("ZG_COMPLETION_MODEL", "qwen2.5-coder:1.5b");
    const fim = try Service.create(&rt, &env, &app);
    defer fim.destroy();
    try testing.expect(fim.provider() != null);
    try testing.expectEqualStrings("ollama", fim.label);

    // Plain HTTP off loopback is refused: completions stay off.
    try env.put("ZG_COMPLETION_URL", "http://example.com:8012");
    const remote = try Service.create(&rt, &env, &app);
    defer remote.destroy();
    try testing.expect(remote.provider() == null);
}

/// Answers every request with `text`.
const Canned = struct {
    text: []const u8,
    calls: std.atomic.Value(u32) = .init(0),

    fn provider(c: *Canned) complete.FimProvider {
        return .{ .ctx = c, .vtable = &.{ .complete = run }, .caps = .{ .server_side_template = true } };
    }

    fn run(ctx: *anyopaque, _: Io, _: Allocator, _: *const complete.CompletionRequest, sink: complete.providers.Sink) anyerror!void {
        const c: *Canned = @ptrCast(@alignCast(ctx));
        _ = c.calls.fetchAdd(1, .monotonic);
        try sink.text(sink.ctx, c.text);
    }
};

test "completions: an editor shows ghost text, Tab accepts it" {
    const gpa = testing.allocator;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const t = try zg_gui.testing.TestApp.init(gpa, .{});
    defer t.deinit();
    t.app.rt = &rt;
    t.app.now_ms = 1000;

    var canned: Canned = .{ .text = "turn 1;\n}" };
    var svc: Service = .{ .gpa = gpa, .io = testing.io, .app = &t.app, .fixed = canned.provider(), .label = "test" };
    const text0 = "fn f() u32 {\n    re\n}\n";
    const doc = try Document.initBytes(gpa, @enumFromInt(1), text0);
    defer doc.deinit();
    const view = try EditorView.init(gpa, doc, .{});
    defer view.deinit();
    view.setSelection(.{ .anchor = 19, .head = 19 });

    const ec = (try EditorCompletions.attach(gpa, &svc, t.win, view, "a.zig")).?;
    defer ec.detach();
    try testing.expect(view.decorations != null);
    // Tab with nothing showing falls through.
    try testing.expect(!ec.onKey(.{ .key = .tab }));

    ec.trigger();
    t.advance(1);
    var i: usize = 0;
    while (!ec.ctl.visible() and i < 2000) : (i += 1) {
        _ = t.app.drainMessages();
        if (!ec.ctl.visible()) try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqualStrings("turn 1;", ec.ctl.text());
    try testing.expectEqualStrings("AI", ec.statusText());

    try testing.expect(ec.onKey(.{ .key = .tab }));
    const got = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
    defer gpa.free(got);
    try testing.expectEqualStrings("fn f() u32 {\n    return 1;\n}\n", got);
    try testing.expect(!ec.ctl.visible());

    ec.snooze();
    try testing.expectEqualStrings("AI: snoozed", ec.statusText());
    svc.enabled = false;
    try testing.expectEqualStrings("AI: off", ec.statusText());
}
