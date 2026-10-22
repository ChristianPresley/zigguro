//! QuickPick (E04.F05.S04.T01): the picker behind the command palette
//! (E15), Go to File (E08), Go to Symbol (E05/E07) and the agent session
//! and model pickers (E10).
//!
//! An overlay near the top of the window holds a text input and a
//! virtualised result list with match highlights, descriptions, details,
//! group labels and keybinding keycaps.
//!
//! - **Providers** are routed by prefix: the longest provider prefix the
//!   input starts with wins (">" commands, "@" symbols); the rest goes to
//!   the default provider. Switching keeps the picker open and the text.
//! - **Static providers** are scored on the UI thread with the picker's
//!   matcher (`SubsequenceMatcher` by default), MRU first on an empty
//!   query and on ties.
//! - **Async providers** run `query` on a worker (`App.spawn`). Results
//!   stream back in batches (one UI message per drain) and are merged in
//!   score order. A keystroke cancels the running query. The previous
//!   results stay up (dimmed after 150 ms) until the new query's first
//!   batch, and a progress bar shows until it finishes. The active row
//!   follows its item if the user moved it, else stays on the top result.
//!
//! Keyboard (APG combobox: focus stays in the input): Up/Down, Page
//! Up/Down and Ctrl+Home/End move the active row, Enter accepts (Ctrl+Enter
//! with the alternate flag), Escape closes. In a multi-select picker Space
//! toggles the active row while the input is empty, Ctrl+Space always.
//!
//! Not yet: icons, persisting MRU lists (E04.F07.S03.T01), provider cycling
//! with Tab.

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const window_mod = @import("../core/window.zig");
const app_mod = @import("../core/app.zig");
const style_mod = @import("../layout/style.zig");
const measure_mod = @import("../layout/measure.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const event_mod = @import("../input/event.zig");
const theme_mod = @import("../theme/theme.zig");
const controls = @import("controls.zig");
const overlay = @import("overlay.zig");
const scroll = @import("scroll.zig");
const text_field = @import("text_field/root.zig");
const provider_mod = @import("quick_pick/provider.zig");
const matcher_mod = @import("quick_pick/matcher.zig");
const mru_mod = @import("quick_pick/mru.zig");

pub const QpItem = provider_mod.QpItem;
pub const Provider = provider_mod.Provider;
pub const ResultSink = provider_mod.ResultSink;
pub const Matcher = matcher_mod.Matcher;
pub const SubsequenceMatcher = matcher_mod.SubsequenceMatcher;
pub const Mru = mru_mod.Mru;

const Rect = geom.Rect;
const Size = geom.Size;
const NodeId = ids.NodeId;
const Ui = ui_mod.Ui;
const Window = window_mod.Window;
const App = app_mod.App;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;
const TextBuffer = text_field.TextBuffer;

/// Row heights.
pub const row_h: f32 = 22;
pub const row_h_detail: f32 = 44;
/// When stale results dim.
pub const dim_after_ms: u64 = 150;

/// What a QuickPick shows and does.
pub const QuickPickProps = struct {
    /// At least one; the one with prefix "" is the default.
    providers: []const Provider = &.{},
    initial: []const u8 = "",
    multi: bool = false,
    /// Enter with no result accepts the typed text.
    allow_free_text: bool = false,
    title: ?[]const u8 = null,
    /// Recently accepted ids (owned by the caller, updated on accept).
    mru: ?*Mru = null,
    matcher: ?Matcher = null,
    width: f32 = 600,
    /// The list's maximum height as a fraction of the window's.
    max_height_frac: f32 = 0.6,
    test_id: []const u8 = "quick_pick",
};

/// An open QuickPick; stale (and harmless) once it closes.
pub const QuickPickHandle = struct {
    id: overlay.OverlayId = .none,
    qp: ?*QuickPick = null,

    /// True while it is open.
    pub fn isOpen(h: QuickPickHandle, win: *const Window) bool {
        return h.id != .none and win.isOverlayOpen(h.id);
    }

    /// Closes it.
    pub fn close(h: QuickPickHandle, win: *Window) void {
        if (h.isOpen(win)) win.closeOverlay(h.id);
    }
};

/// Opens a QuickPick in `win`.
pub fn openQuickPick(win: *Window, p: QuickPickProps) !QuickPickHandle {
    std.debug.assert(p.providers.len > 0);
    const gpa = win.gpa;
    const qp = try gpa.create(QuickPick);
    errdefer gpa.destroy(qp);
    qp.* = .{
        .gpa = gpa,
        .win = win,
        .props = p,
        .buffer = try .init(gpa, p.initial),
        .hl_arena = .init(gpa),
        .picked_arena = .init(gpa),
    };
    errdefer qp.buffer.deinit();
    qp.props.providers = try gpa.dupe(Provider, p.providers);
    errdefer gpa.free(qp.props.providers);
    qp.props.title = if (p.title) |t| try gpa.dupe(u8, t) else null;
    qp.props.test_id = try gpa.dupe(u8, p.test_id);
    qp.id = try win.openOverlay(.of(qp), .{
        .layer = .popover,
        .anchor = .{ .top = 0.12 },
        .take_focus = true,
        .role = .dialog,
        .label = qp.props.title orelse "Quick pick",
        .test_id = qp.props.test_id,
        .width = @min(p.width, win.size.w - 2 * overlay.viewport_margin),
        .on_close = .{ .ctx = qp, .f = QuickPick.onClose },
    });
    return .{ .id = qp.id, .qp = qp };
}

/// A running async query.
const Job = struct {
    gpa: std.mem.Allocator,
    app: *App,
    /// Cleared by the UI when the picker stops listening.
    qp: ?*QuickPick,
    gen: u32,
    /// The worker's and the picker's (plus one per posted delivery).
    refs: std.atomic.Value(u32) = .init(2),
    cancel: std.atomic.Value(bool) = .init(false),
    posted: std.atomic.Value(bool) = .init(false),
    query: []u8,
    provider: Provider,
    sink: ResultSink,

    fn unref(j: *Job) void {
        if (j.refs.fetchSub(1, .acq_rel) != 1) return;
        j.sink.deinit();
        j.gpa.free(j.query);
        j.gpa.destroy(j);
    }

    /// Worker side.
    fn run(j: *Job) void {
        j.provider.vtable.query.?(j.provider.ptr, j.query, &j.sink, &j.cancel);
        j.sink.done();
        j.unref();
    }

    /// Any thread: make sure a delivery is queued.
    fn schedule(ctx: *anyopaque) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        if (j.posted.swap(true, .acq_rel)) return;
        _ = j.refs.fetchAdd(1, .acq_rel);
        j.app.post(.{ .ctx = j, .f = deliver }) catch {
            j.posted.store(false, .release);
            j.unref();
        };
    }

    /// UI thread.
    fn deliver(ctx: *anyopaque, _: *App) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        j.posted.store(false, .release);
        var b = j.sink.take();
        if (j.qp) |qp| qp.onBatch(j, &b);
        b.deinit(j.gpa);
        j.unref();
    }
};

/// The picker (the overlay's view).
pub const QuickPick = struct {
    gpa: std.mem.Allocator,
    win: *Window,
    props: QuickPickProps,
    buffer: TextBuffer,
    id: overlay.OverlayId = .none,
    closed: bool = false,
    /// The provider serving the input, or none yet.
    provider: ?usize = null,
    /// The input text the results are for.
    seen: std.ArrayList(u8) = .empty,
    /// The input text has never been queried.
    fresh: bool = true,
    gen: u32 = 0,
    results: std.ArrayList(QpItem) = .empty,
    /// Strings of async results; highlights of scored static items.
    batches: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    hl_arena: std.heap.ArenaAllocator,
    hl_scratch: std.ArrayList([2]u32) = .empty,
    /// The results are the previous query's (kept until the first batch).
    stale: bool = false,
    dim: bool = false,
    dim_timer: Window.TimerId = .none,
    streaming: bool = false,
    /// The caret was put after the initial text.
    caret_placed: bool = false,
    job: ?*Job = null,
    active: usize = 0,
    /// The user moved the active row (it then follows its item).
    user_moved: bool = false,
    picked: std.AutoArrayHashMapUnmanaged(u64, QpItem) = .empty,
    picked_arena: std.heap.ArenaAllocator,
    list: NodeId = .none,
    /// Queries cancelled before they finished (tests, stats).
    cancelled: u32 = 0,

    fn current(qp: *const QuickPick) ?Provider {
        const i = qp.provider orelse return null;
        return qp.props.providers[i];
    }

    fn matcher(qp: *const QuickPick) Matcher {
        return qp.props.matcher orelse SubsequenceMatcher.matcher();
    }

    /// Row height: taller when any item has a detail line.
    pub fn rowHeight(qp: *const QuickPick) f32 {
        for (qp.results.items) |it| if (it.detail.len > 0) return row_h_detail;
        return row_h;
    }

    fn markDirty(qp: *QuickPick) void {
        if (qp.win.viewIdOf(.of(qp))) |vid| qp.win.markViewDirty(vid);
    }

    // -- lifecycle ------------------------------------------------------------

    fn onClose(ctx: *anyopaque, _: overlay.OverlayId) void {
        const qp: *QuickPick = @ptrCast(@alignCast(ctx));
        qp.closed = true;
        qp.detachJob();
        if (qp.dim_timer != .none) qp.win.cancelTimer(qp.dim_timer);
        qp.dim_timer = .none;
        // Rows may still be in the hit index until the next frame.
        qp.win.afterNextFrame(.{ .ctx = qp, .f = free });
    }

    fn free(ctx: *anyopaque, _: *Window) void {
        const qp: *QuickPick = @ptrCast(@alignCast(ctx));
        const gpa = qp.gpa;
        qp.clearResults();
        qp.results.deinit(gpa);
        qp.batches.deinit(gpa);
        qp.hl_arena.deinit();
        qp.hl_scratch.deinit(gpa);
        qp.picked.deinit(gpa);
        qp.picked_arena.deinit();
        qp.seen.deinit(gpa);
        qp.buffer.deinit();
        gpa.free(qp.props.providers);
        if (qp.props.title) |t| gpa.free(t);
        gpa.free(qp.props.test_id);
        gpa.destroy(qp);
    }

    /// Stops listening to the running query and cancels it.
    fn detachJob(qp: *QuickPick) void {
        const j = qp.job orelse return;
        qp.job = null;
        if (qp.streaming) qp.cancelled += 1;
        j.cancel.store(true, .release);
        j.qp = null;
        j.unref();
    }

    fn clearResults(qp: *QuickPick) void {
        qp.results.clearRetainingCapacity();
        for (qp.batches.items) |a| {
            a.deinit();
            qp.gpa.destroy(a);
        }
        qp.batches.clearRetainingCapacity();
        _ = qp.hl_arena.reset(.retain_capacity);
    }

    // -- querying -------------------------------------------------------------

    /// Re-queries when the input changed since the last build.
    fn sync(qp: *QuickPick) void {
        const text = qp.buffer.slice();
        if (!qp.fresh and std.mem.eql(u8, text, qp.seen.items)) return;
        qp.fresh = false;
        qp.seen.clearRetainingCapacity();
        qp.seen.appendSlice(qp.gpa, text) catch {};
        // The longest matching prefix wins; "" is the default.
        var best: ?usize = null;
        var best_len: usize = 0;
        for (qp.props.providers, 0..) |p, i| {
            const pre = p.prefix();
            if (pre.len == 0) {
                if (best == null) best = i;
            } else if (std.mem.startsWith(u8, text, pre) and pre.len >= best_len) {
                best = i;
                best_len = pre.len;
            }
        }
        const pi = best orelse 0;
        const q = text[@min(text.len, qp.props.providers[pi].prefix().len)..];
        qp.provider = pi;
        qp.gen +%= 1;
        qp.user_moved = false;
        qp.active = 0;
        qp.detachJob();
        const p = qp.props.providers[pi];
        if (p.vtable.items) |items_fn| {
            qp.scoreStatic(items_fn(p.ptr), q);
            return;
        }
        qp.startJob(p, q);
    }

    fn mruRank(qp: *const QuickPick, id: u64) u32 {
        const m = qp.props.mru orelse return std.math.maxInt(u32);
        return m.rank(id) orelse std.math.maxInt(u32);
    }

    /// Orders by score, then recency.
    fn before(qp: *const QuickPick, a: QpItem, b: QpItem) bool {
        if (a.score != b.score) return a.score > b.score;
        return qp.mruRank(a.id) < qp.mruRank(b.id);
    }

    fn lessThan(qp: *const QuickPick, a: QpItem, b: QpItem) bool {
        return qp.before(a, b);
    }

    /// The UI-thread path for static items.
    fn scoreStatic(qp: *QuickPick, items: []const QpItem, q: []const u8) void {
        qp.clearResults();
        qp.stale = false;
        qp.dim = false;
        qp.streaming = false;
        const gpa = qp.gpa;
        const m = qp.matcher();
        const a = qp.hl_arena.allocator();
        qp.results.ensureTotalCapacity(gpa, items.len) catch return;
        for (items) |it| {
            if (q.len == 0) {
                var c = it;
                c.score = 0;
                c.highlights = &.{};
                qp.results.appendAssumeCapacity(c);
                continue;
            }
            qp.hl_scratch.clearRetainingCapacity();
            const sc = m.score(q, it.label, &qp.hl_scratch, gpa) orelse continue;
            var c = it;
            c.score = sc;
            c.highlights = a.dupe([2]u32, qp.hl_scratch.items) catch &.{};
            qp.results.appendAssumeCapacity(c);
        }
        // Stable: equal items keep the provider's order.
        std.sort.block(QpItem, qp.results.items, qp, lessThan);
        qp.markDirty();
    }

    fn startJob(qp: *QuickPick, p: Provider, q: []const u8) void {
        const gpa = qp.gpa;
        const app = qp.win.app;
        const query = gpa.dupe(u8, q) catch return;
        const j = gpa.create(Job) catch {
            gpa.free(query);
            return;
        };
        j.* = .{
            .gpa = gpa,
            .app = app,
            .qp = qp,
            .gen = qp.gen,
            .query = query,
            .provider = p,
            .sink = undefined,
        };
        j.sink = .{
            .gpa = gpa,
            .io = if (app.rt) |rt| rt.io else null,
            .cancel = &j.cancel,
            .notify = .{ .ctx = j, .f = Job.schedule },
        };
        qp.job = j;
        qp.streaming = true;
        // Keep the old results up until the first batch.
        qp.stale = qp.results.items.len > 0;
        if (qp.stale) {
            if (qp.dim_timer != .none) qp.win.cancelTimer(qp.dim_timer);
            qp.dim_timer = qp.win.setTimer(app.now_ms + dim_after_ms, .{ .ctx = qp, .f = onDimTimer }) catch .none;
        }
        qp.markDirty();
        app.spawn(Job.run, .{j});
    }

    fn onDimTimer(ctx: *anyopaque, _: *Window) void {
        const qp: *QuickPick = @ptrCast(@alignCast(ctx));
        qp.dim_timer = .none;
        if (qp.closed or !qp.stale) return;
        qp.dim = true;
        qp.markDirty();
    }

    /// Merges a batch from `j` (UI thread).
    fn onBatch(qp: *QuickPick, j: *Job, b: *provider_mod.Batch) void {
        if (qp.closed or j != qp.job or j.gen != qp.gen) return;
        const active_id: ?u64 = if (qp.user_moved and qp.active < qp.results.items.len) qp.results.items[qp.active].id else null;
        if (qp.stale and (b.items.items.len > 0 or b.finished)) {
            qp.clearResults();
            qp.stale = false;
            qp.dim = false;
            if (qp.dim_timer != .none) qp.win.cancelTimer(qp.dim_timer);
            qp.dim_timer = .none;
        }
        if (b.items.items.len > 0) {
            // The strings now belong to the results.
            if (b.arena) |a| {
                qp.batches.append(qp.gpa, a) catch {};
                b.arena = null;
            }
            const items = b.items.items;
            if (items.len > 1000) {
                qp.results.appendSlice(qp.gpa, items) catch {};
                std.sort.block(QpItem, qp.results.items, qp, lessThan);
            } else for (items) |it| {
                // After every result that ranks before or equal to it.
                var lo: usize = 0;
                var hi: usize = qp.results.items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (qp.before(it, qp.results.items[mid])) hi = mid else lo = mid + 1;
                }
                qp.results.insert(qp.gpa, lo, it) catch {};
            }
        }
        if (b.finished) {
            qp.streaming = false;
            qp.detachFinished();
        }
        // The active row follows its item if the user moved it.
        qp.active = 0;
        if (active_id) |id| {
            for (qp.results.items, 0..) |it, i| if (it.id == id) {
                qp.active = i;
                break;
            };
        }
        qp.markDirty();
    }

    /// The running job finished: release it.
    fn detachFinished(qp: *QuickPick) void {
        const j = qp.job orelse return;
        qp.job = null;
        j.qp = null;
        j.unref();
    }

    // -- interaction ----------------------------------------------------------

    fn moveActive(qp: *QuickPick, to: usize) void {
        const n = qp.results.items.len;
        if (n == 0) return;
        qp.active = @min(to, n - 1);
        qp.user_moved = true;
        if (!qp.list.isNone() and qp.win.store.valid(qp.list)) {
            scroll.scrollToRow(qp.win, qp.list, .{ .count = n, .row_h = qp.rowHeight() }, qp.active);
        }
        qp.markDirty();
    }

    fn pageRows(qp: *const QuickPick) usize {
        if (qp.list.isNone() or !qp.win.store.valid(qp.list)) return 10;
        const h = qp.win.store.relRect(qp.list).h;
        return @max(1, @as(usize, @intFromFloat(@floor(h / qp.rowHeight()))) -| 1);
    }

    fn togglePicked(qp: *QuickPick) void {
        if (qp.active >= qp.results.items.len) return;
        const it = qp.results.items[qp.active];
        if (qp.picked.swapRemove(it.id)) {
            qp.markDirty();
            return;
        }
        const a = qp.picked_arena.allocator();
        var c = it;
        c.label = a.dupe(u8, it.label) catch return;
        c.description = a.dupe(u8, it.description) catch return;
        c.detail = a.dupe(u8, it.detail) catch return;
        c.keybinding = null;
        c.group = null;
        c.highlights = &.{};
        c.picked = true;
        qp.picked.put(qp.gpa, it.id, c) catch return;
        qp.markDirty();
    }

    fn isPicked(qp: *const QuickPick, it: QpItem) bool {
        return qp.picked.contains(it.id);
    }

    /// Accepts the active row (or the picked rows, or the typed text).
    fn accept(qp: *QuickPick, alt: bool) void {
        const p = qp.current() orelse return;
        var one: [1]QpItem = undefined;
        var sel: []const QpItem = &.{};
        if (qp.props.multi and qp.picked.count() > 0) {
            sel = qp.picked.values();
        } else if (qp.active < qp.results.items.len and !qp.stale) {
            one[0] = qp.results.items[qp.active];
            sel = &one;
        }
        const text = qp.buffer.slice();
        const q = text[@min(text.len, p.prefix().len)..];
        const free_text: ?[]const u8 = if (sel.len == 0 and qp.props.allow_free_text and q.len > 0) q else null;
        if (sel.len == 0 and free_text == null) return;
        if (qp.props.mru) |m| for (sel) |it| m.touch(it.id);
        p.vtable.accept(p.ptr, sel, free_text, alt);
        qp.win.closeOverlay(qp.id);
    }

    fn onKey(qp: *QuickPick, k: event_mod.KeyPress) bool {
        if (qp.closed or k.action == .release) return false;
        const n = qp.results.items.len;
        switch (k.key) {
            .arrow_down => qp.moveActive(if (n == 0 or qp.active + 1 >= n) 0 else qp.active + 1),
            .arrow_up => qp.moveActive(if (qp.active == 0) n -| 1 else qp.active - 1),
            .page_down => qp.moveActive(qp.active + qp.pageRows()),
            .page_up => qp.moveActive(qp.active -| qp.pageRows()),
            .home => {
                if (!k.mods.ctrl) return false;
                qp.moveActive(0);
            },
            .end => {
                if (!k.mods.ctrl) return false;
                qp.moveActive(n -| 1);
            },
            .enter, .numpad_enter => qp.accept(k.mods.ctrl),
            .escape => qp.win.closeOverlay(qp.id),
            .space => {
                if (!qp.props.multi or !(k.mods.ctrl or qp.buffer.len() == 0)) return false;
                qp.togglePicked();
            },
            else => return false,
        }
        return true;
    }

    fn clickRow(qp: *QuickPick, i: usize) void {
        if (qp.closed or i >= qp.results.items.len) return;
        qp.active = i;
        qp.user_moved = true;
        if (qp.props.multi) {
            qp.togglePicked();
        } else qp.accept(false);
    }

    // -- view -----------------------------------------------------------------

    pub fn build(qp: *QuickPick, ui: *Ui) void {
        qp.sync();
        const th = ui.theme();
        _ = ui.begin(Keys, .{ .qp = qp });
        defer ui.end(Keys);
        const p = qp.current();
        _ = text_field.textField(ui, .{
            .buffer = &qp.buffer,
            .placeholder = if (p) |x| x.vtable.placeholder else "",
            .a11y_label = qp.props.title orelse "Quick pick",
        });
        if (!qp.caret_placed) {
            if (ui.lastState(text_field.TextField)) |st| st.sel = .caret(qp.buffer.len());
            qp.caret_placed = true;
        }
        if (qp.streaming) controls.progress(ui, 1) else {
            // Keeps the list from jumping when the bar comes and goes.
            ui.open(.{ .style = .{ .h = .{ .px = th.dim(.space_xs) }, .shrink = 0 } });
            ui.close();
        }
        const n = qp.results.items.len;
        if (n == 0) {
            if (!qp.streaming and qp.seen.items.len > 0 and !qp.props.allow_free_text) {
                ui.text("No matching results", .{ .color = .fg_muted, .wrap = false });
            }
            qp.list = .none;
            return;
        }
        const rh = qp.rowHeight();
        const max_h = @max(rh, qp.win.size.h * qp.props.max_height_frac);
        const h = @min(@as(f32, @floatFromInt(n)) * rh, max_h);
        const vis = scroll.virtualList(ui, .{
            .count = n,
            .row_h = rh,
            .style = .{ .h = .{ .px = h }, .shrink = 0 },
            .test_id = "quick_pick.list",
        }, qp, row);
        qp.list = vis.node;
    }

    fn row(qp: *QuickPick, ui: *Ui, i: usize) void {
        const it = qp.results.items[i];
        const prev_group: ?[]const u8 = if (i > 0) qp.results.items[i - 1].group else null;
        const show_group = it.group != null and (prev_group == null or !std.mem.eql(u8, prev_group.?, it.group.?));
        _ = ui.leaf(Row, .{
            .qp = qp,
            .index = @intCast(i),
            .label = it.label,
            .description = it.description,
            .detail = it.detail,
            .keybinding = it.keybinding orelse "",
            .group = if (show_group) it.group.? else "",
            .first_of_group = show_group and i > 0,
            .highlights = it.highlights,
            .active = i == qp.active,
            .multi = qp.props.multi,
            .picked = qp.isPicked(it),
            .dim = qp.dim,
        });
    }
};

/// The picker's body: catches navigation keys before the input sees them.
const Keys = struct {
    pub const name = "quick_pick";

    pub const Props = struct { qp: *QuickPick };

    pub fn style(_: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .dir = .column, .gap = th.dim(.space_xs) };
    }

    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        if (ec.phase != .capture) return false;
        return switch (ev.*) {
            .key => |k| props.qp.onKey(k),
            else => false,
        };
    }
};

/// One result row.
pub const Row = struct {
    pub const name = "quick_pick_item";

    pub const Props = struct {
        qp: *QuickPick,
        index: u32,
        label: []const u8,
        description: []const u8 = "",
        detail: []const u8 = "",
        keybinding: []const u8 = "",
        group: []const u8 = "",
        first_of_group: bool = false,
        highlights: []const [2]u32 = &.{},
        active: bool = false,
        multi: bool = false,
        picked: bool = false,
        dim: bool = false,
    };

    fn body(th: *const theme_mod.Theme) text_mod.TextStyle {
        return .{ .size = th.dim(.font_size) };
    }

    fn small(th: *const theme_mod.Theme) text_mod.TextStyle {
        return .{ .size = th.dim(.font_size_sm) };
    }

    pub fn style(_: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return .{ .grow = 1, .align_self = .stretch };
    }

    pub fn measure(_: *MeasureCx, _: *const Props, _: *widget.NoState, _: ?f32) Size {
        return .{ .w = 0, .h = 0 };
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const th = pc.theme;
        const st = body(th);
        const m = pc.text_sys.metrics(st);
        const pad = pc.dim(.space_sm);
        if (props.active) pc.fill(r, .selection_bg, pc.dim(.radius_sm));
        if (props.first_of_group) pc.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, .border, 0);
        const fg = pc.color(if (props.dim) .fg_muted else .fg);
        const muted = pc.color(.fg_muted);
        const line_y = r.y + if (props.detail.len > 0) (r.h / 2 - m.line_h) / 2 + 2 else (r.h - m.line_h) / 2;
        const baseline = line_y + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
        var x = r.x + pad;
        if (props.multi) {
            const box: Rect = .{ .x = x, .y = r.y + (r.h - 14) / 2, .w = 14, .h = 14 };
            if (props.picked) {
                pc.fill(box, .control_checked, 3);
                pc.textLine("\u{2713}", small(th), pc.color(.fg_on_accent), .{ .x = box.x + 2, .y = box.bottom() - 3 });
            } else pc.border(box, 1, pc.color(.control_border), 3);
            x += 22;
        }
        // The label, with matched runs bold in the highlight colour.
        const hl_color = pc.color(.quick_input_highlight);
        const bold: text_mod.TextStyle = .{ .size = st.size, .weight = 700 };
        var pos: usize = 0;
        for (props.highlights) |h| {
            const s = @min(h[0], props.label.len);
            const e = @min(h[1], props.label.len);
            if (s < pos or e <= s) continue;
            if (s > pos) {
                const seg = props.label[pos..s];
                pc.textLine(seg, st, fg, .{ .x = x, .y = baseline });
                x += pc.text_sys.width(st, seg);
            }
            const seg = props.label[s..e];
            pc.textLine(seg, bold, hl_color, .{ .x = x, .y = baseline });
            x += pc.text_sys.width(bold, seg);
            pos = e;
        }
        if (pos < props.label.len) {
            const seg = props.label[pos..];
            pc.textLine(seg, st, fg, .{ .x = x, .y = baseline });
            x += pc.text_sys.width(st, seg);
        }
        if (props.description.len > 0) {
            x += 6;
            pc.textLine(props.description, small(th), muted, .{ .x = x, .y = baseline });
        }
        // Right side: keycaps, then the group label.
        var rx = r.right() - pad;
        if (props.keybinding.len > 0) rx = keycaps(pc, props.keybinding, rx, r, small(th));
        if (props.group.len > 0) {
            const gw = pc.text_sys.width(small(th), props.group);
            pc.textLine(props.group, small(th), muted, .{ .x = rx - gw, .y = baseline });
        }
        if (props.detail.len > 0) {
            const sm = pc.text_sys.metrics(small(th));
            const dy = r.y + r.h / 2 + (r.h / 2 - sm.line_h) / 2 + sm.ascent;
            pc.textLine(props.detail, small(th), muted, .{ .x = r.x + pad + if (props.multi) @as(f32, 22) else 0, .y = dy });
        }
    }

    /// Draws "Ctrl+Shift+P" as keycaps ending at `right`; returns the left
    /// edge minus a gap.
    fn keycaps(pc: *PaintCx, kb: []const u8, right: f32, r: Rect, st: text_mod.TextStyle) f32 {
        const m = pc.text_sys.metrics(st);
        const cap_h = m.line_h + 2;
        const y = r.y + (r.h - cap_h) / 2;
        // Lay out right to left.
        var x = right;
        var parts = std.mem.splitBackwardsScalar(u8, kb, '+');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const w = pc.text_sys.width(st, part) + 8;
            x -= w;
            const cap: Rect = .{ .x = x, .y = y, .w = w, .h = cap_h };
            pc.fill(cap, .badge_bg, 3);
            pc.border(cap, 1, pc.color(.border), 3);
            pc.textLine(part, st, pc.color(.badge_fg), .{ .x = x + 4, .y = y + 1 + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent });
            x -= 3;
        }
        return x - 6;
    }

    pub fn event(_: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        switch (ev.*) {
            .pointer_up => |p| if (p.button == .left) {
                props.qp.clickRow(props.index);
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .listitem, .name = props.label, .checked = if (props.multi) props.picked else null };
    }
};

test {
    std.testing.refAllDecls(@This());
}
