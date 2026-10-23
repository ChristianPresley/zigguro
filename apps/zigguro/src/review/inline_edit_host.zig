//! Hosts the inline edit bar (E12.F06.S01.T02) in an editor: a
//! `block_above` decoration at the selection's first line reserves the
//! rows, and the bar is placed over them (`build`, absolute, at the
//! view's `blockRect`). The decoration follows the line through edits.
//!
//! The session's changeset lands in the review queue; accepting it writes
//! the open file through E05's `AgentEditSession` (one undo step, rebased
//! over the user's typing), other paths through `inner` (the review
//! glue's recording files). Edits to the document while the bar is open
//! go to the session (`documentEdited`), which cancels it when they touch
//! the region.
//!
//! UI thread only. When the bar closes, `done` is set: the workbench
//! destroys the host at its next build.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");
const zg_review = @import("zg_review");
const bar_mod = @import("inline_edit_bar.zig");
const InlineModel = @import("../agent/inline_model.zig").InlineModel;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const model = zg_editor.model;
const Document = model.document.Document;
const DecorationStore = model.decorations.store.DecorationStore;
const OwnerId = model.decorations.store.OwnerId;
const DecorationId = model.decorations.store.DecorationId;
const EditorView = zg_editor.view.EditorView;
const AgentEditSession = model.api.agent_edit.AgentEditSession;
const DocHandle = model.api.registry.DocHandle;
const Files = zg_review.apply.files.Files;
const Entry = zg_review.apply.files.Entry;
const InlineEditBar = bar_mod.InlineEditBar;
const log = std.log.scoped(.inline_edit);

/// Rows the bar takes above the selection.
pub const bar_rows = 3;

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Hand the selection and instruction to the agent pane.
    to_agent: *const fn (ctx: *anyopaque, selection: []const u8, instruction: []const u8) void,
    /// Repaint (stream events arrive off a build).
    changed: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    app: *zg_gui.App,
    io: Io,
    view: *EditorView,
    /// The editor's decoration store (the view draws it).
    store: *DecorationStore,
    /// Workspace-relative, '/'-separated.
    path: []const u8,
    workspace: []const u8,
    language: []const u8 = "",
    q: *zg_review.model.Queue,
    history: *zg_review.model.History,
    /// Files other than the open one.
    inner: Files,
    edits: *AgentEditSession,
    handle: DocHandle,
    provider: zg_ai.Provider,
    /// Borrowed; outlives the host.
    model: []const u8,
    ref: zg_ai.proto.AgentRef,
    instructions: *bar_mod.History,
    hooks: Hooks,
};

pub const InlineEditHost = struct {
    gpa: Allocator,
    view: *EditorView,
    doc: *Document,
    store: *DecorationStore,
    owner: OwnerId,
    deco: ?DecorationId = null,
    /// The document when the bar opened (the bar borrows it).
    text: []u8,
    path: []u8,
    files: DocFiles,
    applier: zg_review.apply.Applier,
    model: InlineModel,
    bar: *InlineEditBar,
    hooks: Hooks,
    listener: model.document.ListenerId = undefined,
    /// The bar closed: destroy the host (not from inside its build).
    done: bool = false,
    /// Focus the field after the next frame.
    focus_pending: bool = true,

    /// Opens the bar over `region` (byte offsets, ordered).
    pub fn open(gpa: Allocator, o: Options, region: [2]usize) !*InlineEditHost {
        const h = try gpa.create(InlineEditHost);
        errdefer gpa.destroy(h);
        const doc = o.view.doc;
        const text = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
        errdefer gpa.free(text);
        const path = try gpa.dupe(u8, o.path);
        errdefer gpa.free(path);
        const owner = o.store.ownerByName("ai.inline_edit") orelse try o.store.registerOwner("ai.inline_edit", 30);
        h.* = .{
            .gpa = gpa,
            .view = o.view,
            .doc = doc,
            .store = o.store,
            .owner = owner,
            .text = text,
            .path = path,
            .files = .{ .path = path, .doc = doc, .edits = o.edits, .handle = o.handle, .inner = o.inner },
            .applier = undefined,
            .model = .init(gpa, o.io, o.app, o.provider, .{ .model = o.model }),
            .bar = undefined,
            .hooks = o.hooks,
        };
        errdefer h.model.deinit();
        h.applier = .init(gpa, o.io, o.q, h.files.files(), o.history);
        h.bar = try InlineEditBar.create(gpa, o.q, &h.applier, h.model.port(), .{
            .path = path,
            .language = o.language,
            .text = text,
            .region = region,
            .ref = o.ref,
            .workspace = o.workspace,
        }, o.instructions, .{ .ctx = h, .to_agent = toAgent, .closed = closed, .changed = changed });
        errdefer h.bar.destroy();
        h.bar.model_label = o.model;
        const line = o.view.lineOf(region[0]);
        const at = o.view.lineRange(line).start;
        h.deco = try o.store.add(.{
            .range = .{ .start = at, .end = at },
            .owner = owner,
            .stick = .point_left,
            .kind = .{ .block_above = .{ .rows = bar_rows, .payload = 1 } },
        });
        errdefer o.store.remove(h.deco.?);
        h.listener = try doc.subscribe(.{ .ctx = h, .onChange = onChange });
        o.view.revealRange(.{ .start = region[0], .end = region[1] });
        return h;
    }

    /// Cancels a running stream; a ready edit stays in the review queue.
    pub fn destroy(h: *InlineEditHost) void {
        h.doc.unsubscribe(h.listener);
        if (h.deco) |d| h.store.remove(d);
        h.bar.destroy();
        h.model.deinit();
        h.gpa.free(h.text);
        h.gpa.free(h.path);
        h.gpa.destroy(h);
    }

    /// The bar, over its rows; call right after the editor widget, in the
    /// editor's container.
    pub fn build(h: *InlineEditHost, ui: *Ui) void {
        if (h.done) return;
        const r = h.view.blockRect(h.owner, 1) orelse return;
        if (r.y + r.h < 0 or r.y > h.view.viewport.h) return;
        ui.open(.{ .style = .{ .position = .absolute, .inset = .{ .l = r.x, .t = r.y }, .w = .{ .px = @max(r.w - 16, 200) }, .dir = .column } });
        h.bar.build(ui);
        ui.close();
        if (h.focus_pending) if (h.bar.field_node) |n| {
            h.focus_pending = false;
            ui.win.afterNextFrame(.{ .ctx = h, .f = focusField });
            _ = n;
        };
    }

    fn focusField(ctx: *anyopaque, w: *zg_gui.Window) void {
        const h: *InlineEditHost = @ptrCast(@alignCast(ctx));
        const n = h.bar.field_node orelse return;
        if (w.store.valid(n)) w.setFocus(n, false);
    }

    fn onChange(ctx: *anyopaque, ev: *const model.document.ChangeEvent) void {
        const h: *InlineEditHost = @ptrCast(@alignCast(ctx));
        // The accept itself.
        if (h.files.applying) return;
        // Ranges are in the coordinates before the event, in order: shift
        // each by what the earlier ones changed.
        var delta: i64 = 0;
        for (ev.changes.replaces) |r| {
            const from: usize = @intCast(@as(i64, @intCast(r.range.start)) + delta);
            const len = r.range.end - r.range.start;
            h.bar.documentEdited(from, from + len, r.text.len) catch |e| log.warn("inline edit: {t}", .{e});
            delta += @as(i64, @intCast(r.text.len)) - @as(i64, @intCast(len));
        }
    }

    fn toAgent(ctx: *anyopaque, selection: []const u8, instruction: []const u8) void {
        const h: *InlineEditHost = @ptrCast(@alignCast(ctx));
        h.hooks.to_agent(h.hooks.ctx, selection, instruction);
    }

    fn closed(ctx: *anyopaque) void {
        const h: *InlineEditHost = @ptrCast(@alignCast(ctx));
        h.done = true;
        h.view.focusEditor();
        h.hooks.changed(h.hooks.ctx);
    }

    fn changed(ctx: *anyopaque) void {
        const h: *InlineEditHost = @ptrCast(@alignCast(ctx));
        h.hooks.changed(h.hooks.ctx);
    }
};

/// Review's `Files` with the open document in place of its file on disk.
pub const DocFiles = struct {
    path: []const u8,
    doc: *Document,
    edits: *AgentEditSession,
    handle: DocHandle,
    inner: Files,
    /// Inside our own edit of the document.
    applying: bool = false,

    pub fn files(d: *DocFiles) Files {
        return .{ .ctx = d, .vtable = &.{ .read = read, .write = write, .delete = delete } };
    }

    fn read(ctx: *anyopaque, arena: Allocator, path: []const u8) anyerror!?Entry {
        const d: *DocFiles = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, path, d.path)) return d.inner.read(arena, path);
        return .{ .bytes = try d.doc.tree.copyRange(arena, .{ .start = 0, .end = d.doc.len() }), .executable = false };
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8, executable: ?bool) anyerror!void {
        const d: *DocFiles = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, path, d.path)) return d.inner.write(path, bytes, executable);
        d.applying = true;
        defer d.applying = false;
        var out = try d.edits.propose(d.handle, .{ .whole_file = .{ .text = bytes } }, "inline_edit");
        defer out.deinit(d.edits.gpa);
        if (out != .applied) return error.EditRejected;
    }

    fn delete(ctx: *anyopaque, path: []const u8) anyerror!void {
        const d: *DocFiles = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, path, d.path)) return error.AccessDenied;
        return d.inner.delete(path);
    }
};

const testing = std.testing;

test "inline edit host: the bar's rows sit above the selection; accept edits the open document" {
    const gpa = testing.allocator;
    const zg_core = @import("zg_core");
    const scripted = zg_ai.scripted;
    const ReviewGlue = @import("../agent/review_glue.zig").ReviewGlue;
    const EditorFiles = @import("../agent/editor_files.zig").EditorFiles;
    const DocumentRegistry = model.api.registry.DocumentRegistry;

    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    rt.bindUiThread(.noop);
    const t = try zg_gui.testing.TestApp.init(gpa, .{});
    defer t.deinit();
    t.app.attachRuntime(&rt);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = "function f() {\n  let x = 1;\n  return x;\n}\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = file });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    const abs = try std.fs.path.join(gpa, &.{ root, "a.ts" });
    defer gpa.free(abs);

    const glue = try ReviewGlue.create(gpa, testing.io, root, .{});
    defer glue.destroy();
    var reg: DocumentRegistry = .init(gpa, .native);
    defer reg.deinit();
    const handle = try reg.openFile(abs, file);
    const doc = reg.get(handle).?;
    var ef: EditorFiles = .init(gpa, &t.app, root, &reg, 1);
    defer ef.deinit();
    const view = try EditorView.init(gpa, doc, .{});
    defer view.deinit();
    var store: DecorationStore = .init(gpa, doc);
    defer store.deinit();
    _ = try doc.subscribe(store.listener());
    view.decorations = &store;

    const sp = try scripted.ScriptedProvider.init(gpa, &.{&.{
        .{ .event = .{ .message_start = .{ .id = "msg", .model = "m" } } },
        .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } },
        .{ .event = .{ .text_delta = .{ .index = 0, .text = "<rewrite>\n  const x" } } },
        .{ .event = .{ .text_delta = .{ .index = 0, .text = " = 1;\n</rewrite>" } } },
        .{ .event = .{ .block_stop = .{ .index = 0 } } },
        .{ .event = .{ .stop = .end_turn } },
    }}, .{});
    defer sp.destroy();

    const Hooked = struct {
        changed: u32 = 0,
        fn toAgent(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn changedFn(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.changed += 1;
        }
    };
    var hooked: Hooked = .{};
    var instructions: bar_mod.History = .init(gpa);
    defer instructions.deinit();
    const h = try InlineEditHost.open(gpa, .{
        .app = &t.app,
        .io = testing.io,
        .view = view,
        .store = &store,
        .path = "a.ts",
        .workspace = root,
        .language = "typescript",
        .q = glue.q,
        .history = &glue.history,
        .inner = glue.recording.files(),
        .edits = &ef.edits,
        .handle = handle,
        .provider = sp.provider(),
        .model = "m",
        .ref = .{ .session = 1 },
        .instructions = &instructions,
        .hooks = .{ .ctx = &hooked, .to_agent = Hooked.toAgent, .changed = Hooked.changedFn },
    }, .{ 15, 28 });
    var destroyed = false;
    defer if (!destroyed) h.destroy();

    // Three rows above line 1, where the selection starts.
    const r = view.blockRect(h.owner, 1).?;
    try testing.expectEqual(view.lineHeight() * 1, r.y);
    try testing.expectEqual(view.lineHeight() * bar_rows, r.h);

    try h.bar.field.setText("make it const");
    try h.bar.run(.submit);
    var spins: u32 = 0;
    while (h.bar.state().? == .streaming) : (spins += 1) {
        try testing.expect(spins < 5000);
        _ = t.app.drainMessages();
        testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expectEqual(zg_review.assist.inline_edit.session.State.ready, h.bar.state().?);
    try testing.expect(hooked.changed > 0);

    try h.bar.run(.accept);
    const got = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
    defer gpa.free(got);
    try testing.expectEqualStrings("function f() {\n  const x = 1;\n  return x;\n}\n", got);
    // The editor took the edit; the file on disk is unchanged until saved.
    const disk = try tmp.dir.readFileAlloc(testing.io, "a.ts", gpa, .limited(256));
    defer gpa.free(disk);
    try testing.expectEqualStrings(file, disk);
    try testing.expect(h.done);
    h.destroy();
    destroyed = true;
    try testing.expectEqual(@as(usize, 0), store.ownerCount(view.decorations.?.ownerByName("ai.inline_edit").?));
}
