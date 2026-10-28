//! Inlay hints and code lenses in the editors (E07.F03.S02.T03): the
//! hints of what an editor shows go into its decorations as inline text
//! (owner `lsp.inlay`), and the lenses as a row above their line (owner
//! `lsp.lens`) that this file paints: each lens title, separated by `|`,
//! clickable. Rows of lenses not resolved yet stay empty, so resolving
//! never moves the text.
//!
//! `editor.inlayHints.enabled` (on, off, onUnlessPressed,
//! offUnlessPressed) decides whether hints show; Ctrl+Alt is "pressed"
//! from the key press until the next key or pointer move without both.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const EditorView = zg_editor.view.EditorView;
const BlockInfo = zg_editor.view.editor_view.BlockInfo;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const store = zg_editor.model.decorations.store;
const DecorationStore = store.DecorationStore;
const StyleRef = store.StyleRef;
const Manager = zg_codeintel.Manager;
pub const InlayService = zg_codeintel.features.InlayService;
pub const CodeLensService = zg_codeintel.features.CodeLensService;
const CommandService = zg_codeintel.features.CommandService;

pub const InlineInfo = struct {
    pub const Mode = InlayService.Mode;
    pub const Action = CodeLensService.lens_commands.Action;

    gpa: Allocator,
    inlay: InlayService = undefined,
    lens: CodeLensService = undefined,
    /// The style of hint text.
    style: StyleRef,
    /// Per editor: the painter's context.
    views: std.ArrayList(*ViewCtx) = .empty,
    inlay_seen: u64 = std.math.maxInt(u64),
    lens_seen: u64 = std.math.maxInt(u64),
    /// Where each title was painted, for clicks.
    hits: std.ArrayList(Hit) = .empty,
    scratch: std.ArrayList(store.Decoration) = .empty,
    rows: std.ArrayList(u64) = .empty,
    text: std.ArrayList(u8) = .empty,
    /// `editor.codeLens`.
    lens_enabled: bool = true,
    /// Lens commands zigguro runs (a run or debug lens), for the host.
    on_action: ?ActionHook = null,

    pub const ActionHook = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, action: CodeLensService.lens_commands.Action, command: []const u8) void,
    };

    const Hit = struct { view: *EditorView, line: u64, x0: f32, x1: f32, id: CodeLensService.LensId };

    const ViewCtx = struct {
        ii: *InlineInfo,
        view: *EditorView,
        h: DocHandle,
        deco: *DecorationStore,
        inlay_owner: store.OwnerId,
        lens_owner: store.OwnerId,
    };

    /// `ii` must not move once initialized.
    pub fn init(ii: *InlineInfo, gpa: Allocator, mgr: *Manager, waker: zg_core.runtime.Waker, style: StyleRef) !void {
        ii.* = .{ .gpa = gpa, .style = style };
        try ii.inlay.init(mgr, waker, .{});
        try ii.lens.init(mgr, .{ .waker = waker });
    }

    /// Before the editors go; the services after `Manager.deinit`
    /// (`deinitServices`).
    pub fn release(ii: *InlineInfo) void {
        for (ii.views.items) |c| ii.unhookCtx(c);
        ii.views.clearRetainingCapacity();
    }

    pub fn deinitServices(ii: *InlineInfo) void {
        ii.inlay.deinit();
        ii.lens.deinit();
        ii.views.deinit(ii.gpa);
        ii.hits.deinit(ii.gpa);
        ii.scratch.deinit(ii.gpa);
        ii.rows.deinit(ii.gpa);
        ii.text.deinit(ii.gpa);
    }

    fn ctxOf(ii: *InlineInfo, view: *EditorView) ?*ViewCtx {
        for (ii.views.items) |c| if (c.view == view) return c;
        return null;
    }

    fn unhookCtx(ii: *InlineInfo, c: *ViewCtx) void {
        c.deco.clearOwner(c.inlay_owner);
        c.deco.clearOwner(c.lens_owner);
        _ = c.view.setOwnerPainter(c.lens_owner, null);
        ii.gpa.destroy(c);
    }

    /// `view` shows lines `[first, end)` of `h`, drawn with `deco`.
    pub fn viewport(ii: *InlineInfo, h: DocHandle, view: *EditorView, deco: *DecorationStore, first: u64, end: u64, now_ms: u64) void {
        if (ii.ctxOf(view)) |c| if (!std.meta.eql(c.h, h) or c.deco != deco) {
            ii.forgetView(view);
        };
        if (ii.ctxOf(view) == null) {
            const c = ii.gpa.create(ViewCtx) catch return;
            c.* = .{
                .ii = ii,
                .view = view,
                .h = h,
                .deco = deco,
                .inlay_owner = deco.ownerByName("lsp.inlay") orelse deco.registerOwner("lsp.inlay", 5) catch return ii.gpa.destroy(c),
                .lens_owner = deco.ownerByName("lsp.lens") orelse deco.registerOwner("lsp.lens", 5) catch return ii.gpa.destroy(c),
            };
            if (!view.setOwnerPainter(c.lens_owner, .{ .ctx = c, .paint = paintLens })) return ii.gpa.destroy(c);
            ii.views.append(ii.gpa, c) catch return ii.unhookCtx(c);
            // New editors get their decorations on the next apply.
            ii.inlay_seen = std.math.maxInt(u64);
            ii.lens_seen = std.math.maxInt(u64);
        }
        ii.inlay.onViewport(h, .{ .first = first, .end = end }, now_ms) catch {};
        if (ii.lens_enabled) ii.lens.onViewport(h, .{ .first = first, .end = end }) catch {};
    }

    /// `view` closed or shows another file.
    pub fn forgetView(ii: *InlineInfo, view: *EditorView) void {
        for (ii.views.items, 0..) |c, i| if (c.view == view) {
            _ = ii.views.swapRemove(i);
            ii.unhookCtx(c);
            return;
        };
    }

    /// `h` closed.
    pub fn forget(ii: *InlineInfo, h: DocHandle, view: *EditorView) void {
        ii.forgetView(view);
        ii.inlay.forget(h);
        ii.lens.forget(h);
    }

    /// `editor.inlayHints.enabled` and `editor.codeLens`.
    pub fn configure(ii: *InlineInfo, mode: InlayService.Mode, lenses: bool) void {
        ii.inlay.setMode(mode);
        if (lenses == ii.lens_enabled) return;
        ii.lens_enabled = lenses;
        if (!lenses) for (ii.views.items) |c| ii.lens.forget(c.h);
        ii.lens_seen = std.math.maxInt(u64);
    }

    /// Ctrl+Alt state from the latest input.
    pub fn modifiers(ii: *InlineInfo, ctrl: bool, alt: bool) void {
        ii.inlay.setPressed(ctrl and alt);
    }

    /// Takes answers, sends due requests and redraws what changed; true
    /// when an editor needs painting.
    pub fn tick(ii: *InlineInfo, now_ms: u64) bool {
        _ = ii.inlay.tick(now_ms);
        _ = ii.lens.tick();
        var changed = false;
        if (ii.inlay.generation != ii.inlay_seen) {
            ii.inlay_seen = ii.inlay.generation;
            for (ii.views.items) |c| ii.applyInlays(c);
            changed = true;
        }
        if (ii.lens.generation != ii.lens_seen) {
            ii.lens_seen = ii.lens.generation;
            for (ii.views.items) |c| ii.applyLenses(c);
            changed = true;
        }
        return changed;
    }

    pub fn nextDue(ii: *const InlineInfo) ?u64 {
        return ii.inlay.nextDue();
    }

    pub fn lensDue(ii: *const InlineInfo) ?i96 {
        return ii.lens.nextDue();
    }

    fn applyInlays(ii: *InlineInfo, c: *ViewCtx) void {
        if (!ii.inlay.shown()) return c.deco.clearOwner(c.inlay_owner);
        const doc = c.view.doc;
        const hs = ii.inlay.hints(c.h);
        ii.scratch.clearRetainingCapacity();
        ii.text.clearRetainingCapacity();
        // Labels first (the list may grow), then the decorations.
        for (hs) |x| {
            if (x.pad_left) ii.text.append(ii.gpa, ' ') catch return;
            ii.text.appendSlice(ii.gpa, x.label) catch return;
            if (x.pad_right) ii.text.append(ii.gpa, ' ') catch return;
        }
        var at: usize = 0;
        for (hs) |x| {
            const n = x.label.len + @intFromBool(x.pad_left) + @intFromBool(x.pad_right);
            const t = ii.text.items[at .. at + n];
            at += n;
            ii.scratch.append(ii.gpa, .{
                .range = .{ .start = x.offset, .end = x.offset },
                .owner = c.inlay_owner,
                .stick = .point_right,
                .kind = .{ .inline_before = .{ .text = t, .style = ii.style } },
                .hover = x.id,
            }) catch return;
        }
        c.deco.setOwnerDecorations(c.inlay_owner, doc.version, ii.scratch.items) catch {};
    }

    fn applyLenses(ii: *InlineInfo, c: *ViewCtx) void {
        if (!ii.lens_enabled) return c.deco.clearOwner(c.lens_owner);
        const doc = c.view.doc;
        ii.lens.lines(c.h, ii.gpa, &ii.rows) catch return;
        ii.scratch.clearRetainingCapacity();
        for (ii.rows.items) |line| {
            const at = doc.tree.lineStart(line);
            ii.scratch.append(ii.gpa, .{
                .range = .{ .start = at, .end = at },
                .owner = c.lens_owner,
                .stick = .point_left,
                .kind = .{ .block_above = .{ .rows = 1, .payload = line } },
            }) catch return;
        }
        c.deco.setOwnerDecorations(c.lens_owner, doc.version, ii.scratch.items) catch {};
    }

    /// The hint under the pointer at `offset` (the hint's anchor, or just
    /// before it).
    pub fn hintNear(ii: *InlineInfo, h: DocHandle, offset: u64) ?*const InlayService.Hint {
        if (!ii.inlay.shown()) return null;
        return ii.inlay.hintAt(h, offset) orelse ii.inlay.hintAt(h, offset + 1);
    }

    /// A click on a lens row of `view`: runs the lens under it; true when
    /// it hit one.
    pub fn click(ii: *InlineInfo, view: *EditorView, b: BlockInfo, x: f32, cmds: *CommandService) bool {
        const c = ii.ctxOf(view) orelse return false;
        if (b.owner != c.lens_owner) return false;
        for (ii.hits.items) |hit| {
            if (hit.view != view or hit.line != b.payload or x < hit.x0 or x >= hit.x1) continue;
            const out = ii.lens.execute(c.h, hit.id, cmds) catch return true;
            switch (out) {
                .action => |a| if (ii.on_action) |hk| hk.f(hk.ctx, a.action, a.command),
                .server, .none => {},
            }
            return true;
        }
        return false;
    }

    fn paintLens(ctx: ?*anyopaque, pc: *zg_gui.paint.PaintCx, rect: zg_gui.core.Rect, b: BlockInfo) void {
        const c: *ViewCtx = @ptrCast(@alignCast(ctx.?));
        const ii = c.ii;
        const v = c.view;
        const st = v.textStyle();
        const m = pc.text_sys.metrics(st);
        const base = (v.lineHeight() - (m.ascent + m.descent)) / 2 + m.ascent;
        // Drop this row's old hit boxes.
        var k: usize = 0;
        for (ii.hits.items) |hit| if (!(hit.view == v and hit.line == b.payload)) {
            ii.hits.items[k] = hit;
            k += 1;
        };
        ii.hits.shrinkRetainingCapacity(k);
        // Under the line's indentation.
        const doc = v.doc;
        var x = rect.x + 4 - v.scroll.x;
        if (b.payload < doc.tree.lineCount()) {
            var it = doc.tree.chunks(doc.tree.lineStart(b.payload));
            var indent: f32 = 0;
            const space = pc.text_sys.advance(st, ' ');
            scan: while (it.next()) |chunk| for (chunk) |ch| switch (ch) {
                ' ' => indent += space,
                '\t' => indent += space * 4,
                else => break :scan,
            };
            x += indent;
        }
        const fg = pc.color(.fg_muted);
        var first = true;
        for (ii.lens.lenses(c.h)) |l| {
            if (l.line != b.payload) continue;
            const title = l.title orelse continue;
            if (!first) {
                pc.textLine(" | ", st, fg.fade(0.6), .{ .x = x, .y = rect.y + base });
                x += pc.text_sys.measure(st, " | ", null).w;
            }
            first = false;
            const w = pc.text_sys.measure(st, title, null).w;
            pc.textLine(title, st, fg, .{ .x = x, .y = rect.y + base });
            ii.hits.append(ii.gpa, .{ .view = v, .line = b.payload, .x0 = x - rect.x, .x1 = x - rect.x + w, .id = l.id }) catch {};
            x += w;
        }
    }
};
