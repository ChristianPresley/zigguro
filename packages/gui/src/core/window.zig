//! `Window`: one node tree plus its frame loop.
//!
//! Phases per frame: dispatch (input already queued) → effects → build
//! (dirty views only, parents first) → layout (dirty subtrees) → paint
//! (clean nodes replay cached ops; damage = old ∪ new bounds of changed
//! nodes) → present (only when damage is not empty). A frame with nothing
//! dirty does no work at all (idle-zero).

const std = @import("std");
const zg_platform = @import("zg_platform");
const geom = @import("geom.zig");
const ids = @import("ids.zig");
const node_store = @import("node_store.zig");
const widget = @import("widget.zig");
const response_mod = @import("response.zig");
const view_mod = @import("view.zig");
const app_mod = @import("app.zig");
const ui_mod = @import("ui.zig");
const damage_mod = @import("damage.zig");
const canvas = @import("../paint/canvas.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text = @import("../paint/text.zig");
const engine_mod = @import("../layout/engine.zig");
const event = @import("../input/event.zig");
const hit_test = @import("../input/hit_test.zig");
const keys_mod = @import("../input/keys.zig");
const actions = @import("../input/actions.zig");
const box = @import("../widgets/box.zig");
const overlay = @import("../widgets/overlay.zig");
const theme_mod = @import("../theme/theme.zig");

const NodeId = ids.NodeId;
const Rect = geom.Rect;
const Vec2 = geom.Vec2;
const Size = geom.Size;
const Response = response_mod.Response;
const App = app_mod.App;

/// Counters of the last frame.
pub const FrameStats = struct {
    frame_no: u64 = 0,
    /// The frame did no work (nothing dirty).
    idle: bool = true,
    views_built: u32 = 0,
    nodes_emitted: u32 = 0,
    layout: engine_mod.LayoutStats = .{},
    nodes_painted: u32 = 0,
    nodes_replayed: u32 = 0,
    ops: u32 = 0,
    presented: bool = false,
    damage_rects: u32 = 0,
    full_damage: bool = false,
};

/// A view mounted in this window.
pub const ViewEntry = struct {
    view: view_mod.AnyView,
    node: NodeId = .none,
    dirty: bool = true,
    /// Dirtied while building; promoted to `dirty` after the build phase.
    dirty_next: bool = false,
    built_frame: u64 = std.math.maxInt(u64),
    built_once: bool = false,
    alive: bool = true,
    observed: std.ArrayList(view_mod.EntityId) = .empty,
};

/// Views are identified by object address and vtable together: a view
/// embedded as the first field of another has the same address.
const ViewKey = struct { ptr: usize, vt: usize };

const PendingHook = struct { hook: overlay.CloseHook, id: overlay.OverlayId };

fn viewKey(v: view_mod.AnyView) ViewKey {
    return .{ .ptr = @intFromPtr(v.ptr), .vt = @intFromPtr(v.vtable) };
}

const Cmd = union(enum) {
    ops: struct { range: canvas.Range, origin: Vec2 },
    push_clip: struct { r: Rect, radius: f32 },
    pop_clip,
    /// A scrollbar thumb, drawn above the scrolled content.
    thumb: struct { r: Rect, color: geom.Color },
};

/// A window: node tree, views, layout, paint cache and input state.
pub const Window = struct {
    app: *App,
    gpa: std.mem.Allocator,
    store: node_store.NodeStore,
    root: NodeId,
    root_view: ?view_mod.AnyView,
    size: Size,
    scale: f32,
    text_sys: text.TextSystem,
    engine: engine_mod.Engine,
    ui: ui_mod.Ui,
    frame_arena: std.heap.ArenaAllocator,
    frame_no: u64 = 0,
    building: bool = false,
    /// Open overlays (popovers, dialogs) in paint order.
    overlays: overlay.Stack = .{},
    /// Close hooks of overlays closed while building, run after the build.
    close_hooks: std.ArrayList(PendingHook) = .empty,
    needs_frame: bool = true,
    stats: FrameStats = .{},

    views: std.ArrayList(ViewEntry) = .empty,
    view_map: std.AutoHashMapUnmanaged(ViewKey, u16) = .empty,

    ops: [2]canvas.OpList = .{ .{}, .{} },
    cur_ops: u1 = 0,
    cmds: std.ArrayList(Cmd) = .empty,
    damage: damage_mod.Damage = .{},
    canvas: ?canvas.Canvas = null,
    glyph_scratch: std.ArrayList(canvas.GlyphQuad) = .empty,
    z_scratch: std.ArrayList(NodeId) = .empty,
    full_repaint: bool = true,

    hits: hit_test.HitIndex = .{},
    pointer: Vec2 = .{ .x = -1, .y = -1 },
    hot: NodeId = .none,
    active: NodeId = .none,
    focus: NodeId = .none,
    focus_visible: bool = false,
    responses: std.AutoHashMapUnmanaged(u32, Response) = .empty,
    cursor: zg_platform.cursor.CursorShape = .default,
    key_handler: ?keys_mod.KeyHandler = null,
    /// Runs menu (and later palette) actions; see `dispatchAction`.
    action_handler: ?actions.ActionHandler = null,
    /// Sees keys before the focused node while `node` is mounted (the
    /// menubar).
    key_filter: ?struct { node: NodeId, f: keys_mod.KeyFilter } = null,
    /// Drops the text event that follows a character key the key handler
    /// consumed.
    eat_text: bool = false,
    /// Where the last context menu was asked for (window coordinates).
    context_at: Vec2 = .{},
    /// The last context menu was asked for from the keyboard.
    context_keyboard: bool = false,
    /// Counts pointer presses (tells a press that dismissed a menu apart
    /// from a later one).
    press_serial: u32 = 0,
    timers: std.ArrayList(TimerEntry) = .empty,
    next_timer: u32 = 1,
    /// Callbacks for the end of the next frame, and those due this frame.
    after_frame: std.ArrayList(Timer) = .empty,
    after_frame_due: std.ArrayList(Timer) = .empty,
    path_scratch: std.ArrayList(NodeId) = .empty,
    ctx_scratch: std.ArrayList([]const u8) = .empty,

    /// The platform window this window presents to, if any.
    platform_win: ?zg_platform.types.WindowId = null,
    close_requested: bool = false,

    /// How to open a window.
    pub const Options = struct {
        size: Size = .{ .w = 1280, .h = 800 },
        scale: f32 = 1,
        root: ?view_mod.AnyView = null,
        text: text.TextSystem,
        canvas: ?canvas.Canvas = null,
        node_capacity: u32 = 1024,
    };

    /// Creates a window (use `App.openWindow`).
    pub fn create(app: *App, opts: Options) !*Window {
        const gpa = app.gpa;
        const w = try gpa.create(Window);
        errdefer gpa.destroy(w);
        w.* = .{
            .app = app,
            .gpa = gpa,
            .store = try node_store.NodeStore.init(gpa, opts.node_capacity),
            .root = .none,
            .root_view = opts.root,
            .size = opts.size,
            .scale = opts.scale,
            .text_sys = opts.text,
            .engine = undefined,
            .ui = undefined,
            .frame_arena = .init(gpa),
            .canvas = opts.canvas,
        };
        w.engine = .{ .gpa = gpa, .store = &w.store, .mc = .{ .text = opts.text, .theme = app.theme } };
        w.ui = .{ .win = w };
        w.store.on_free = .{ .ctx = w, .f = onFree };
        // View id 0 is "no view".
        try w.views.append(gpa, .{ .view = undefined, .alive = false, .dirty = false });
        w.root = try w.store.alloc(1, .root);
        w.store.coldOf(w.root).style = .{ .display = .flex, .dir = .column };
        w.store.coldOf(w.root).blob = .{};
        const props: box.Root.Props = .{};
        try widget.vtable(.root).retain(gpa, &w.store.coldOf(w.root).blob, &props);
        return w;
    }

    /// Frees the window (use `App.closeWindow`).
    pub fn destroy(w: *Window) void {
        const gpa = w.gpa;
        // Close hooks may own their views.
        while (w.overlays.top()) |e| w.closeOverlay(e.id);
        w.overlays.deinit(gpa);
        w.close_hooks.deinit(gpa);
        w.timers.deinit(gpa);
        for (w.after_frame_due.items) |t| t.f(t.ctx, w);
        for (w.after_frame.items) |t| t.f(t.ctx, w);
        w.after_frame_due.deinit(gpa);
        w.after_frame.deinit(gpa);
        w.store.on_free = null;
        w.ui.deinit();
        w.engine.deinit();
        w.store.deinit();
        w.frame_arena.deinit();
        for (w.views.items) |*v| v.observed.deinit(gpa);
        w.views.deinit(gpa);
        w.view_map.deinit(gpa);
        w.ops[0].deinit(gpa);
        w.ops[1].deinit(gpa);
        w.cmds.deinit(gpa);
        w.glyph_scratch.deinit(gpa);
        w.z_scratch.deinit(gpa);
        w.hits.deinit(gpa);
        w.responses.deinit(gpa);
        w.path_scratch.deinit(gpa);
        w.ctx_scratch.deinit(gpa);
        gpa.destroy(w);
    }

    // -- views --------------------------------------------------------------

    /// The view id of `v` (registering it), bound to boundary `node`.
    pub fn viewFor(w: *Window, v: view_mod.AnyView, node: NodeId) !u16 {
        const gop = try w.view_map.getOrPut(w.gpa, viewKey(v));
        if (!gop.found_existing) {
            if (w.views.items.len >= std.math.maxInt(u16)) return error.OutOfMemory;
            gop.value_ptr.* = @intCast(w.views.items.len);
            w.views.append(w.gpa, .{ .view = v, .node = node }) catch |e| {
                _ = w.view_map.remove(viewKey(v));
                return e;
            };
        }
        const vid = gop.value_ptr.*;
        const entry = &w.views.items[vid];
        if (!entry.node.eql(node)) {
            entry.node = node;
            entry.built_once = false;
            entry.dirty = true;
        }
        entry.view = v;
        entry.alive = true;
        return vid;
    }

    /// The id of a mounted view, or null.
    pub fn viewIdOf(w: *const Window, v: view_mod.AnyView) ?u16 {
        return w.view_map.get(viewKey(v));
    }

    /// Schedules view `vid` for rebuild.
    pub fn markViewDirty(w: *Window, vid: u16) void {
        if (vid == 0 or vid >= w.views.items.len) return;
        const e = &w.views.items[vid];
        if (!e.alive) return;
        if (w.building) e.dirty_next = true else e.dirty = true;
        w.needs_frame = true;
    }

    /// Schedules the whole tree for rebuild.
    pub fn markAllDirty(w: *Window) void {
        for (w.views.items[1..], 1..) |_, i| w.markViewDirty(@intCast(i));
        w.needs_frame = true;
    }

    /// Records that view `vid` observes entity `id`.
    pub fn recordObservation(w: *Window, vid: u16, id: view_mod.EntityId) void {
        const e = &w.views.items[vid];
        for (e.observed.items) |x| {
            if (x.raw() == id.raw()) return;
        }
        e.observed.append(w.gpa, id) catch return;
        w.app.observe(id, .{ .win = w, .view = vid }) catch {};
    }

    /// Drops every observation of view `vid` (before it rebuilds).
    pub fn clearObservations(w: *Window, vid: u16) void {
        const e = &w.views.items[vid];
        for (e.observed.items) |id| w.app.unobserve(id, .{ .win = w, .view = vid });
        e.observed.clearRetainingCapacity();
    }

    fn onFree(ctx: *anyopaque, id: NodeId) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        const fl = w.store.hot.items(.flags)[id.index];
        if (fl.painted) w.damage.add(w.store.absRect(id).outset(ringExtent(w, fl)));
        if (w.hot.eql(id)) w.hot = .none;
        if (w.active.eql(id)) w.active = .none;
        if (w.focus.eql(id)) w.focus = .none;
        _ = w.responses.remove(id.raw());
        if (fl.view_root) {
            var it = w.view_map.iterator();
            while (it.next()) |kv| {
                const e = &w.views.items[kv.value_ptr.*];
                if (e.node.eql(id)) {
                    e.alive = false;
                    e.node = .none;
                    w.clearObservations(kv.value_ptr.*);
                    if (e.view.vtable.deinit) |d| d(e.view.ptr);
                    _ = w.view_map.remove(kv.key_ptr.*);
                    break;
                }
            }
        }
    }

    // -- responses ----------------------------------------------------------

    /// Adds interaction flags for `node` and schedules its view.
    pub fn respond(w: *Window, node: NodeId, r: Response) void {
        const gop = w.responses.getOrPut(w.gpa, node.raw()) catch return;
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.merge(r) else r;
        w.markViewDirty(w.store.hot.items(.view)[node.index]);
    }

    /// The pending flags of `node` (cleared) merged with its live state.
    pub fn takeResponse(w: *Window, node: NodeId) Response {
        var r: Response = .{};
        if (w.responses.fetchRemove(node.raw())) |kv| r = kv.value;
        r.hovered = w.hot.eql(node);
        r.pressed = w.active.eql(node) and w.hot.eql(node);
        r.focused = w.focus.eql(node);
        return r;
    }

    // -- frame --------------------------------------------------------------

    /// True when the next `frame` call would do work.
    pub fn wantsFrame(w: *const Window) bool {
        return w.needs_frame or w.anyDirtyView();
    }

    /// Resizes the window (layout and full repaint next frame).
    pub fn resize(w: *Window, size: Size, scale: f32) void {
        if (size.w == w.size.w and size.h == w.size.h and scale == w.scale) return;
        w.size = size;
        w.scale = scale;
        w.store.markLayout(w.root);
        w.full_repaint = true;
        w.needs_frame = true;
    }

    /// Repaints everything with the app's theme; relayouts when `relayout`.
    pub fn themeChanged(w: *Window, relayout: bool) void {
        w.engine.mc.theme = w.app.theme;
        const fl = w.store.hot.items(.flags);
        for (fl[1..]) |*f| {
            f.paint_dirty = true;
            if (relayout) {
                f.layout_dirty = true;
                f.subtree_dirty = true;
            }
        }
        w.full_repaint = true;
        w.needs_frame = true;
    }

    /// Runs one frame. Returns immediately (stats.idle) when nothing is dirty.
    pub fn frame(w: *Window) FrameStats {
        w.app.flushEffects();
        w.stats = .{ .frame_no = w.frame_no + 1 };
        if (!w.needs_frame and !w.anyDirtyView()) return w.stats;
        w.needs_frame = false;
        w.frame_no += 1;
        w.stats.idle = false;
        std.mem.swap(std.ArrayList(Timer), &w.after_frame, &w.after_frame_due);
        w.engine.mc.theme = w.app.theme;

        // BUILD: dirty views, shallowest first; a parent rebuild builds its
        // dirty children inline.
        w.building = true;
        w.ui.emitted = 0;
        // The root is rebuilt when overlays open or close, which a view's
        // build may do; a few rounds settle it.
        var round: u8 = 0;
        while (round < 4) : (round += 1) {
            if (w.store.hot.items(.first_child)[w.root.index].isNone() or w.overlays.dirty) {
                w.overlays.dirty = false;
                w.ui.buildRoot(w.root);
            }
            while (w.nextDirtyView()) |vid| w.ui.buildInto(vid, w.views.items[vid].node);
            if (!w.overlays.dirty) break;
        }
        w.building = false;
        for (w.close_hooks.items) |c| c.hook.f(c.hook.ctx, c.id);
        w.close_hooks.clearRetainingCapacity();
        for (w.views.items) |*e| {
            if (e.dirty_next) {
                e.dirty_next = false;
                e.dirty = true;
                w.needs_frame = true;
            }
        }
        w.stats.nodes_emitted = w.ui.emitted;
        w.app.flushEffects();

        // LAYOUT.
        const rfl = w.store.flags(w.root);
        if (rfl.subtree_dirty or rfl.layout_dirty) {
            w.engine.run(w.root, w.size);
            w.stats.layout = w.engine.stats;
            // Views that build from a viewport size see the new one next frame.
            for (w.store.resized_views.items) |vid| w.markViewDirty(vid);
            w.store.resized_views.clearRetainingCapacity();
        }

        if (w.overlays.items.items.len > 0) w.placeOverlays();

        // PAINT and PRESENT: a rebuild that changed nothing paints nothing.
        if (w.store.paint_pending or w.full_repaint) {
            w.paintPass();
            w.present();
        }
        _ = w.frame_arena.reset(.retain_capacity);
        if (w.ui.oom or w.engine.oom) {
            w.ui.oom = false;
            w.engine.oom = false;
            w.markAllDirty();
        }
        for (w.after_frame_due.items) |t| t.f(t.ctx, w);
        w.after_frame_due.clearRetainingCapacity();
        return w.stats;
    }

    fn anyDirtyView(w: *const Window) bool {
        for (w.views.items) |e| {
            if (e.alive and e.dirty) return true;
        }
        return false;
    }

    fn nextDirtyView(w: *Window) ?u16 {
        var best: ?u16 = null;
        var best_depth: u16 = std.math.maxInt(u16);
        for (w.views.items, 0..) |e, i| {
            if (!e.alive or !e.dirty or e.node.isNone() or !w.store.valid(e.node)) continue;
            if (e.built_frame == w.frame_no) continue;
            const d = w.store.coldOf(e.node).depth;
            if (d < best_depth) {
                best_depth = d;
                best = @intCast(i);
            }
        }
        return best;
    }

    fn ringExtent(w: *const Window, fl: node_store.NodeFlags) f32 {
        if (!fl.focusable) return 0;
        return w.app.theme.dim(.focus_ring_w) + w.app.theme.dim(.focus_ring_offset);
    }

    fn interaction(w: *const Window, id: NodeId, fl: node_store.NodeFlags) paint_cx.Interaction {
        const focused = w.focus.eql(id);
        return .{
            .hovered = w.hot.eql(id),
            .pressed = w.active.eql(id) and w.hot.eql(id),
            .focused = focused,
            .focus_visible = focused and w.focus_visible,
            .disabled = fl.disabled,
        };
    }

    fn paintPass(w: *Window) void {
        const new = &w.ops[1 - w.cur_ops];
        new.clearRetainingCapacity();
        w.cmds.clearRetainingCapacity();
        w.hits.clear();
        if (w.full_repaint) {
            w.damage.add(.{ .w = w.size.w, .h = w.size.h });
            for (w.store.hot.items(.flags)[1..]) |*f| f.paint_dirty = true;
        }
        const viewport: Rect = .{ .w = w.size.w, .h = w.size.h };
        w.walkPaint(w.root, .{}, viewport, false);
        w.cur_ops = 1 - w.cur_ops;
        w.hits.finish(w.gpa, w.size) catch {};
        w.stats.ops = @intCast(new.ops.items.len);
        w.full_repaint = false;
        w.store.paint_pending = false;
    }

    /// Paints `id` and its subtree. `cull` (children of a scroll
    /// container) skips subtrees whose box lies outside `clip`; content
    /// that overflows its own box there is skipped with it.
    fn walkPaint(w: *Window, id: NodeId, origin: Vec2, clip: Rect, cull: bool) void {
        const s = &w.store;
        const i = id.index;
        var fl = s.hot.items(.flags)[i];
        const old_abs = s.absRect(id);
        if (fl.hidden) {
            if (fl.painted) {
                w.damage.add(old_abs.outset(w.ringExtent(fl)).intersect(clip));
                s.hot.items(.flags)[i].painted = false;
            }
            return;
        }
        const abs = s.relRect(id).translate(origin);
        if (cull) {
            const ext = w.ringExtent(fl);
            if (abs.outset(ext).intersect(clip).isEmpty()) {
                if (fl.painted) {
                    w.damage.add(old_abs.outset(ext).intersect(clip.outset(ext)));
                    s.hot.items(.flags)[i].painted = false;
                }
                return;
            }
        }
        const moved = !fl.painted or !old_abs.eql(abs);
        if (fl.paint_dirty or moved) {
            const ext = w.ringExtent(fl);
            if (fl.painted) w.damage.add(old_abs.outset(ext).intersect(clip.outset(ext)));
            w.damage.add(abs.outset(ext).intersect(clip.outset(ext)));
        }
        const new = &w.ops[1 - w.cur_ops];
        const old = &w.ops[w.cur_ops];
        var range: canvas.Range = undefined;
        if (fl.paint_dirty or !fl.painted) {
            range = new.mark();
            const vt = widget.vtable(s.hot.items(.kind)[i]);
            if (vt.paint) |paint| {
                if (s.props(id)) |props| {
                    var pc: paint_cx.PaintCx = .{
                        .gpa = w.gpa,
                        .ops = new,
                        .theme = w.app.theme,
                        .text_sys = w.text_sys,
                        .size = .{ .w = abs.w, .h = abs.h },
                        .style = &s.cold.items[i].style,
                        .state = w.interaction(id, fl),
                    };
                    const st: *anyopaque = s.hot.items(.state)[i] orelse @ptrCast(&dummy);
                    paint(&pc, props, st);
                    if (pc.oom) w.needs_frame = true;
                }
            }
            range = new.close(range);
            w.stats.nodes_painted += 1;
        } else {
            range = new.copyRange(w.gpa, old, s.hot.items(.paint_range)[i]) catch new.mark();
            w.stats.nodes_replayed += 1;
        }
        fl = s.hot.items(.flags)[i];
        fl.paint_dirty = false;
        fl.painted = true;
        s.hot.items(.flags)[i] = fl;
        s.hot.items(.paint_range)[i] = range;
        s.hot.items(.abs)[i] = abs.toArray();
        if (!range.isEmpty()) w.cmds.append(w.gpa, .{ .ops = .{ .range = range, .origin = .{ .x = abs.x, .y = abs.y } } }) catch {};
        if (fl.hit_testable and !fl.disabled) w.hits.add(w.gpa, abs.intersect(clip), id) catch {};

        const st = &s.cold.items[i].style;
        var child_clip = clip;
        if (fl.clips or st.clip) {
            child_clip = clip.intersect(abs);
            w.cmds.append(w.gpa, .{ .push_clip = .{ .r = abs, .radius = st.radius } }) catch {};
        }
        const scroll = s.cold.items[i].scroll;
        const child_origin: Vec2 = .{ .x = abs.x - scroll.x, .y = abs.y - scroll.y };
        // Children in z order (stable for equal z).
        var needs_sort = false;
        var it = s.children(id);
        while (it.next()) |c| {
            if (s.cold.items[c.index].style.z != 0) {
                needs_sort = true;
                break;
            }
        }
        if (!needs_sort) {
            it = s.children(id);
            while (it.next()) |c| w.walkPaint(c, child_origin, child_clip, st.scrolls());
        } else {
            const start = w.z_scratch.items.len;
            it = s.children(id);
            while (it.next()) |c| w.z_scratch.append(w.gpa, c) catch {};
            const kids = w.z_scratch.items[start..];
            std.sort.insertion(NodeId, kids, s, struct {
                fn lt(store: *node_store.NodeStore, a: NodeId, b: NodeId) bool {
                    return store.cold.items[a.index].style.z < store.cold.items[b.index].style.z;
                }
            }.lt);
            var k: usize = 0;
            while (start + k < w.z_scratch.items.len and k < kids.len) : (k += 1) {
                w.walkPaint(w.z_scratch.items[start + k], child_origin, child_clip, st.scrolls());
            }
            w.z_scratch.shrinkRetainingCapacity(start);
        }
        if (st.scrolls()) w.addThumbs(id, abs);
        if (fl.clips or st.clip) w.cmds.append(w.gpa, .pop_clip) catch {};
    }

    /// Thickness of a scrollbar thumb, logical pixels.
    pub const thumb_size: f32 = 6;

    /// The thumb rectangles of scroll container `id` at `abs`
    /// (null where the content fits).
    pub fn thumbRects(w: *const Window, id: NodeId, abs: Rect) [2]?Rect {
        const c = &w.store.cold.items[id.index];
        const st = &c.style;
        var out: [2]?Rect = .{ null, null };
        const vw = abs.w - st.padding.horizontal() - 2 * st.border_w;
        const vh = abs.h - st.padding.vertical() - 2 * st.border_w;
        if (st.scroll_y and c.content.h > vh + 0.5 and vh > 0) {
            const len = @max(16, abs.h * vh / c.content.h);
            const top = abs.y + (abs.h - len) * (c.scroll.y / (c.content.h - vh));
            out[1] = .{ .x = abs.x + abs.w - thumb_size - 2, .y = top, .w = thumb_size, .h = len };
        }
        if (st.scroll_x and c.content.w > vw + 0.5 and vw > 0) {
            const len = @max(16, abs.w * vw / c.content.w);
            const left = abs.x + (abs.w - len) * (c.scroll.x / (c.content.w - vw));
            out[0] = .{ .x = left, .y = abs.y + abs.h - thumb_size - 2, .w = len, .h = thumb_size };
        }
        return out;
    }

    fn addThumbs(w: *Window, id: NodeId, abs: Rect) void {
        const color = w.app.theme.color(.scrollbar_thumb);
        for (w.thumbRects(id, abs)) |t| if (t) |r| {
            w.cmds.append(w.gpa, .{ .thumb = .{ .r = r, .color = color } }) catch {};
        };
    }

    // -- scrolling ------------------------------------------------------------

    /// The scroll offset of `id` (zero for nodes that do not scroll).
    pub fn scrollOffset(w: *const Window, id: NodeId) Vec2 {
        if (!w.store.valid(id)) return .{};
        return w.store.cold.items[id.index].scroll;
    }

    /// The largest offset `id` can scroll to on each axis.
    pub fn maxScroll(w: *const Window, id: NodeId) Vec2 {
        if (!w.store.valid(id)) return .{};
        const c = &w.store.cold.items[id.index];
        const r = w.store.relRect(id);
        const st = &c.style;
        return .{
            .x = if (st.scroll_x) @max(0, c.content.w - (r.w - st.padding.horizontal() - 2 * st.border_w)) else 0,
            .y = if (st.scroll_y) @max(0, c.content.h - (r.h - st.padding.vertical() - 2 * st.border_w)) else 0,
        };
    }

    /// Scrolls `id` to `to` (clamped); true when the offset changed. The
    /// content repaints at its new position without relayout; a container
    /// opened with `rebuild_on_scroll` also rebuilds its view.
    pub fn scrollTo(w: *Window, id: NodeId, to: Vec2) bool {
        if (!w.store.valid(id) or !w.store.cold.items[id.index].style.scrolls()) return false;
        const max = w.maxScroll(id);
        const c = &w.store.cold.items[id.index];
        const next: Vec2 = .{ .x = std.math.clamp(to.x, 0, max.x), .y = std.math.clamp(to.y, 0, max.y) };
        if (next.x == c.scroll.x and next.y == c.scroll.y) return false;
        c.scroll = next;
        w.store.markPaint(id);
        if (w.store.flags(id).rebuild_on_scroll) w.markViewDirty(w.store.hot.items(.view)[id.index]);
        w.needs_frame = true;
        return true;
    }

    /// Scrolls `id` by `d`; true when the offset changed.
    pub fn scrollBy(w: *Window, id: NodeId, d: Vec2) bool {
        const o = w.scrollOffset(id);
        return w.scrollTo(id, .{ .x = o.x + d.x, .y = o.y + d.y });
    }

    /// Pixels per wheel notch.
    pub const wheel_step: f32 = 48;

    /// Scrolls the innermost container under `from` that can move in the
    /// event's direction (an inner list at its end lets the outer page
    /// scroll).
    fn scrollChain(w: *Window, from: NodeId, sc: event.Scroll) void {
        const k: f32 = if (sc.precise) 1 else wheel_step;
        const d: Vec2 = .{ .x = sc.dx * k, .y = sc.dy * k };
        var n = from;
        while (!n.isNone()) : (n = w.store.parent(n)) {
            if (w.scrollBy(n, d)) return;
        }
    }

    var dummy: u8 = 0;

    fn present(w: *Window) void {
        if (w.damage.isEmpty()) return;
        w.stats.damage_rects = w.damage.len;
        w.stats.full_damage = w.damage.full;
        if (w.canvas) |c| {
            const ops = &w.ops[w.cur_ops];
            c.begin(w.size, w.scale);
            for (w.cmds.items) |cmd| switch (cmd) {
                .ops => |o| ops.replay(o.range, o.origin, c, &w.glyph_scratch, w.gpa),
                .push_clip => |p| c.pushClip(p.r, .all(p.radius)),
                .pop_clip => c.popClip(),
                .thumb => |t| c.rect(t.r, t.color, .all(@min(t.r.w, t.r.h) / 2)),
            };
            if (w.damage.full) c.addDamage(.{ .w = w.size.w, .h = w.size.h }) else for (w.damage.slice()) |r| c.addDamage(r);
            c.end();
        }
        w.stats.presented = true;
        w.damage.clear();
    }

    /// Replays the current frame into `c` (debugging, snapshots).
    pub fn replayInto(w: *Window, c: canvas.Canvas) void {
        const ops = &w.ops[w.cur_ops];
        c.begin(w.size, w.scale);
        for (w.cmds.items) |cmd| switch (cmd) {
            .ops => |o| ops.replay(o.range, o.origin, c, &w.glyph_scratch, w.gpa),
            .push_clip => |p| c.pushClip(p.r, .all(p.radius)),
            .pop_clip => c.popClip(),
            .thumb => |t| c.rect(t.r, t.color, .all(@min(t.r.w, t.r.h) / 2)),
        };
        c.end();
    }

    // -- timers and actions ---------------------------------------------------

    /// A pending timer's handle.
    pub const TimerId = enum(u32) { none = 0, _ };

    /// What a timer runs.
    pub const Timer = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, w: *Window) void,
    };

    const TimerEntry = struct { id: TimerId, at_ms: u64, t: Timer };

    /// Runs `t` once `App.now_ms` reaches `at_ms` (from `tick`, outside
    /// builds). The Host sleeps until the earliest timer.
    pub fn setTimer(w: *Window, at_ms: u64, t: Timer) !TimerId {
        const id: TimerId = @enumFromInt(w.next_timer);
        w.next_timer +%= 1;
        if (w.next_timer == 0) w.next_timer = 1;
        try w.timers.append(w.gpa, .{ .id = id, .at_ms = at_ms, .t = t });
        return id;
    }

    /// Cancels timer `id` (no-op when it already ran).
    pub fn cancelTimer(w: *Window, id: TimerId) void {
        for (w.timers.items, 0..) |e, i| if (e.id == id) {
            _ = w.timers.orderedRemove(i);
            return;
        };
    }

    /// The earliest timer deadline, if any.
    pub fn nextDeadline(w: *const Window) ?u64 {
        var best: ?u64 = null;
        for (w.timers.items) |e| best = if (best) |b| @min(b, e.at_ms) else e.at_ms;
        return best;
    }

    /// Runs the timers due at `now_ms` (earliest first).
    pub fn tick(w: *Window, now_ms: u64) void {
        while (true) {
            var due: ?usize = null;
            for (w.timers.items, 0..) |e, i| {
                if (e.at_ms > now_ms) continue;
                if (due == null or e.at_ms < w.timers.items[due.?].at_ms) due = i;
            }
            const i = due orelse return;
            const e = w.timers.orderedRemove(i);
            w.needs_frame = true;
            e.t.f(e.t.ctx, w);
        }
    }

    /// Runs `t` at the end of the frame after the next one starts, once
    /// nodes removed before now are out of the tree and the hit index (to
    /// free what their props point at). Runs at once if out of memory.
    pub fn afterNextFrame(w: *Window, t: Timer) void {
        w.after_frame.append(w.gpa, t) catch return t.f(t.ctx, w);
        w.needs_frame = true;
    }

    /// Runs `action` through the window's `ActionHandler`; false when there
    /// is none or it did not handle the action.
    pub fn dispatchAction(w: *Window, action: actions.ActionId, arg: ?[]const u8) bool {
        const h = w.action_handler orelse return false;
        return h.call(action, arg);
    }

    /// The nearest node at or above `n` with a context menu.
    fn contextNode(w: *Window, n: NodeId) NodeId {
        var p = n;
        while (!p.isNone() and w.store.valid(p)) : (p = w.store.parent(p)) {
            if (w.store.flags(p).context_menu) return p;
        }
        return .none;
    }

    // -- overlays -------------------------------------------------------------

    /// Opens `view` as an overlay (see `zg_gui.w.overlay`). Opened during a
    /// build, the building view is rebuilt when the overlay closes.
    pub fn openOverlay(w: *Window, view: view_mod.AnyView, opts: overlay.Options) !overlay.OverlayId {
        const id = try w.overlays.push(w.gpa, .{
            .id = .none,
            .view = view,
            .opts = opts,
            .owner_view = if (w.building) w.ui.currentView() else 0,
            .prev_focus = w.focus,
            .wants_focus = opts.modal or opts.take_focus,
        });
        w.needs_frame = true;
        return id;
    }

    /// Closes overlay `id` (no-op when it is not open): restores focus,
    /// rebuilds the view that opened it and runs its close hook.
    pub fn closeOverlay(w: *Window, id: overlay.OverlayId) void {
        const e = w.overlays.remove(id) orelse return;
        w.needs_frame = true;
        if (e.opts.restore_focus) {
            const inside = !e.panel.isNone() and w.store.valid(e.panel) and !w.focus.isNone() and w.store.isAncestor(e.panel, w.focus);
            if (inside or w.focus.isNone()) {
                const back = if (!e.prev_focus.isNone() and w.store.valid(e.prev_focus)) e.prev_focus else NodeId.none;
                w.setFocus(back, w.focus_visible);
            }
        }
        if (e.owner_view != 0 and e.owner_view < w.views.items.len and w.views.items[e.owner_view].alive) w.markViewDirty(e.owner_view);
        if (e.opts.on_close) |h| {
            // A hook may free the overlay's view, which may be building.
            if (w.building) {
                w.close_hooks.append(w.gpa, .{ .hook = h, .id = id }) catch h.f(h.ctx, id);
            } else h.f(h.ctx, id);
        }
    }

    /// True while overlay `id` is open.
    pub fn isOverlayOpen(w: *const Window, id: overlay.OverlayId) bool {
        return w.overlays.indexOf(id) != null;
    }

    /// The rectangle of `id` from the last layout, in window coordinates
    /// (parents' scroll offsets applied).
    pub fn layoutRect(w: *const Window, id: NodeId) Rect {
        var r = w.store.relRect(id);
        var p = w.store.parent(id);
        while (!p.isNone()) : (p = w.store.parent(p)) {
            const pr = w.store.relRect(p);
            const sc = w.store.cold.items[p.index].scroll;
            r.x += pr.x - sc.x;
            r.y += pr.y - sc.y;
        }
        return r;
    }

    /// Positions overlay panels after layout, closes overlays whose anchor
    /// unmounted, and moves focus into newly opened ones.
    fn placeOverlays(w: *Window) void {
        const vp: Rect = .{ .w = w.size.w, .h = w.size.h };
        var i: usize = 0;
        while (i < w.overlays.items.items.len) {
            const e = &w.overlays.items.items[i];
            i += 1;
            if (e.panel.isNone() or !w.store.valid(e.panel)) continue;
            const cur = w.store.relRect(e.panel);
            const size: Size = .{ .w = cur.w, .h = cur.h };
            const target = if (e.opts.anchor) |a| switch (a) {
                .rect => |r| overlay.place(r, size, vp, e.opts.placement),
                .top => |f| overlay.atTop(size, vp, f),
                .corner => |m| overlay.atCorner(size, vp, m),
                .node => |n| blk: {
                    if (!w.store.valid(n) or w.store.flags(n).hidden) {
                        w.closeOverlay(e.id);
                        i -= 1;
                        continue;
                    }
                    break :blk overlay.place(w.layoutRect(n), size, vp, e.opts.placement);
                },
            } else overlay.center(size, vp);
            if (target.x != cur.x or target.y != cur.y) {
                // Paint sees the move and damages the old and new bounds.
                w.store.hot.items(.rect)[e.panel.index] = target.toArray();
                w.store.markPaint(e.panel);
            }
            if (e.wants_focus) {
                e.wants_focus = false;
                const f = w.firstFocusable(e.panel);
                const to = if (!f.isNone()) f else if (e.opts.modal) e.panel else NodeId.none;
                if (!to.isNone()) w.setFocus(to, w.focus_visible);
            }
        }
    }

    /// The first enabled focusable node under `n` in tree order (not `n`).
    fn firstFocusable(w: *Window, n: NodeId) NodeId {
        var it = w.store.children(n);
        while (it.next()) |c| {
            const fl = w.store.flags(c);
            if (fl.hidden) continue;
            if (fl.focusable and !fl.disabled) return c;
            const d = w.firstFocusable(c);
            if (!d.isNone()) return d;
        }
        return .none;
    }

    /// The overlay Escape closes: the topmost that is modal or holds focus.
    fn escapeTarget(w: *const Window) ?overlay.OverlayId {
        var i = w.overlays.items.items.len;
        while (i > 0) {
            i -= 1;
            const e = w.overlays.items.items[i];
            if (e.opts.modal) return e.id;
            if (!w.focus.isNone() and !e.panel.isNone() and w.store.valid(e.panel) and w.store.isAncestor(e.panel, w.focus)) return e.id;
        }
        return null;
    }

    /// Light dismiss for a press at `p`; true when the press is consumed.
    fn dismissOutside(w: *Window, p: Vec2) bool {
        const top = w.overlays.top() orelse return false;
        const h = w.hitTest(p);
        const group = top.opts.group;
        for (w.overlays.items.items) |e| {
            if (e.id != top.id and (group == 0 or e.opts.group != group)) continue;
            if (!e.panel.isNone() and w.store.valid(e.panel) and !h.isNone() and w.store.isAncestor(e.panel, h)) return false;
        }
        if (top.opts.light_dismiss) {
            const consume = top.opts.consume_outside_click;
            w.closeOverlay(top.id);
            // The rest of its group (a menu's open submenus) goes too.
            if (group != 0) {
                var i = w.overlays.items.items.len;
                while (i > 0) {
                    i -= 1;
                    if (i >= w.overlays.items.items.len) continue;
                    const e = w.overlays.items.items[i];
                    if (e.opts.group == group) w.closeOverlay(e.id);
                }
            }
            return consume;
        }
        // The scrim under a modal overlay swallows the press.
        return top.opts.modal;
    }

    /// Closes the light-dismissable popovers and tooltips (window blur).
    pub fn dismissPopovers(w: *Window) void {
        var i = w.overlays.items.items.len;
        while (i > 0) {
            i -= 1;
            const e = w.overlays.items.items[i];
            if (e.opts.light_dismiss and (e.opts.layer == .popover or e.opts.layer == .tooltip)) w.closeOverlay(e.id);
        }
    }

    // -- input --------------------------------------------------------------

    /// The topmost hit-testable node at `p` (window logical coordinates).
    pub fn hitTest(w: *const Window, p: Vec2) NodeId {
        return w.hits.hit(p);
    }

    fn setHot(w: *Window, n: NodeId) void {
        if (w.hot.eql(n)) return;
        const old = w.hot;
        w.hot = n;
        // Hover is paint-only: widgets read it through `PaintCx.state`.
        if (!old.isNone() and w.store.valid(old)) {
            w.store.markPaint(old);
            _ = w.deliver(old, .pointer_leave, false);
        }
        if (!n.isNone()) w.store.markPaint(n);
        w.needs_frame = true;
    }

    /// Moves keyboard focus to `n` (`none` clears it).
    pub fn setFocus(w: *Window, n: NodeId, visible: bool) void {
        w.focus_visible = visible;
        if (w.focus.eql(n)) {
            if (!n.isNone()) w.store.markPaint(n);
            w.needs_frame = true;
            return;
        }
        const old = w.focus;
        w.focus = n;
        if (!old.isNone() and w.store.valid(old)) {
            w.store.markPaint(old);
            w.respond(old, .{ .focus_lost = true });
            _ = w.deliver(old, .focus_lost, false);
        }
        if (!n.isNone()) {
            w.store.markPaint(n);
            w.respond(n, .{ .focus_gained = true });
            _ = w.deliver(n, .focus_gained, false);
        }
        w.needs_frame = true;
    }

    fn sink(w: *Window) event.Sink {
        return .{ .ptr = w, .vtable = &sink_vtable };
    }

    const sink_vtable: event.Sink.VTable = .{
        .respond = sinkRespond,
        .repaint = sinkRepaint,
        .focus = sinkFocus,
        .capture = sinkCapture,
        .release = sinkRelease,
        .setCursor = sinkCursor,
        .nodeRect = sinkRect,
        .relayout = sinkRelayout,
        .textSystem = sinkText,
        .theme = sinkTheme,
        .clipboardGet = sinkClipGet,
        .clipboardSet = sinkClipSet,
        .nowMs = sinkNow,
    };

    fn sinkRespond(p: *anyopaque, n: NodeId, r: Response) void {
        const w: *Window = @ptrCast(@alignCast(p));
        w.respond(n, r);
    }
    fn sinkRepaint(p: *anyopaque, n: NodeId) void {
        const w: *Window = @ptrCast(@alignCast(p));
        w.store.markPaint(n);
        w.needs_frame = true;
    }
    fn sinkFocus(p: *anyopaque, n: NodeId) void {
        const w: *Window = @ptrCast(@alignCast(p));
        w.setFocus(n, false);
    }
    fn sinkCapture(p: *anyopaque, n: NodeId) void {
        const w: *Window = @ptrCast(@alignCast(p));
        w.active = n;
    }
    fn sinkRelease(p: *anyopaque) void {
        const w: *Window = @ptrCast(@alignCast(p));
        w.active = .none;
    }
    fn sinkCursor(p: *anyopaque, shape: zg_platform.cursor.CursorShape) void {
        const w: *Window = @ptrCast(@alignCast(p));
        w.cursor = shape;
    }
    fn sinkRect(p: *anyopaque, n: NodeId) Rect {
        const w: *Window = @ptrCast(@alignCast(p));
        return w.store.absRect(n);
    }
    fn sinkRelayout(p: *anyopaque, n: NodeId) void {
        const w: *Window = @ptrCast(@alignCast(p));
        w.store.markLayout(n);
        w.needs_frame = true;
    }
    fn sinkText(p: *anyopaque) text.TextSystem {
        const w: *Window = @ptrCast(@alignCast(p));
        return w.text_sys;
    }
    fn sinkTheme(p: *anyopaque) *const theme_mod.Theme {
        const w: *Window = @ptrCast(@alignCast(p));
        return w.app.theme;
    }
    fn sinkClipGet(p: *anyopaque) []const u8 {
        const w: *Window = @ptrCast(@alignCast(p));
        return w.app.clipboard.get();
    }
    fn sinkClipSet(p: *anyopaque, s: []const u8) void {
        const w: *Window = @ptrCast(@alignCast(p));
        w.app.clipboard.set(w.gpa, s);
    }
    fn sinkNow(p: *anyopaque) u64 {
        const w: *Window = @ptrCast(@alignCast(p));
        return w.app.now_ms;
    }

    /// Delivers `ev` along the path root → `target` (capture) and back
    /// (target, bubble). Returns true when a widget handled it. With
    /// `bubble` false only the target sees it.
    fn deliver(w: *Window, target: NodeId, ev: event.InputEvent, bubble: bool) bool {
        if (target.isNone() or !w.store.valid(target)) return false;
        const start = w.path_scratch.items.len;
        defer w.path_scratch.shrinkRetainingCapacity(start);
        var p = target;
        while (!p.isNone()) : (p = w.store.parent(p)) {
            w.path_scratch.append(w.gpa, p) catch return false;
            if (!bubble) break;
        }
        const path = w.path_scratch.items[start..];
        // Capture: root → parent of target (widgets opt in by checking phase).
        var k = path.len;
        while (k > 1) {
            k -= 1;
            if (w.callWidget(path[k], target, .capture, &ev)) return true;
        }
        // Target, then bubble.
        for (path, 0..) |n, idx| {
            if (w.callWidget(n, target, if (idx == 0) .target else .bubble, &ev)) return true;
        }
        return false;
    }

    fn callWidget(w: *Window, n: NodeId, target: NodeId, phase: event.Phase, ev: *const event.InputEvent) bool {
        if (!w.store.valid(n)) return false;
        const vt = widget.vtable(w.store.hot.items(.kind)[n.index]);
        const f = vt.event orelse return false;
        const props = w.store.props(n) orelse return false;
        if (phase == .capture and !vt.focusable and !w.store.flags(n).hit_testable) return false;
        var ec: event.EventCx = .{ .sink = w.sink(), .node = n, .target = target, .phase = phase };
        const st: *anyopaque = w.store.hot.items(.state)[n.index] orelse @ptrCast(&dummy);
        const handled = f(&ec, props, st, ev);
        return handled or ec.stopped;
    }

    fn focusableAncestor(w: *Window, n: NodeId) NodeId {
        var p = n;
        while (!p.isNone()) : (p = w.store.parent(p)) {
            const fl = w.store.flags(p);
            if (fl.focusable and !fl.disabled) return p;
        }
        return .none;
    }

    /// Feeds one input event (window logical coordinates).
    pub fn dispatch(w: *Window, ev: event.InputEvent) void {
        w.needs_frame = true;
        switch (ev) {
            .pointer_move => |pm| {
                w.pointer = pm.pos;
                const h = w.hitTest(pm.pos);
                w.setHot(h);
                const target = if (!w.active.isNone()) w.active else h;
                if (!w.active.isNone()) w.respond(w.active, .{ .dragging = true });
                _ = w.deliver(target, ev, true);
            },
            .pointer_down => |pd| {
                w.pointer = pd.pos;
                w.press_serial +%= 1;
                if (w.dismissOutside(pd.pos)) return;
                const h = w.hitTest(pd.pos);
                w.setHot(h);
                if (h.isNone()) return;
                if (pd.button == .left) {
                    w.active = h;
                    w.store.markPaint(h);
                    const f = w.focusableAncestor(h);
                    if (!f.isNone()) w.setFocus(f, false);
                }
                _ = w.deliver(h, ev, true);
            },
            .pointer_up => |pu| {
                w.pointer = pu.pos;
                const h = w.hitTest(pu.pos);
                const target = if (!w.active.isNone()) w.active else h;
                _ = w.deliver(target, ev, true);
                if (pu.button == .left) {
                    const a = w.active;
                    w.active = .none;
                    if (!a.isNone() and w.store.valid(a)) {
                        w.store.markPaint(a);
                        if (!h.isNone() and w.store.isAncestor(a, h)) {
                            w.respond(a, .{ .clicked = true, .double_clicked = pu.clicks == 2 });
                        }
                    }
                } else if (pu.button == .right and !h.isNone()) {
                    w.respond(h, .{ .right_clicked = true });
                    const c = w.contextNode(h);
                    if (!c.isNone()) {
                        w.context_at = pu.pos;
                        w.context_keyboard = false;
                        w.respond(c, .{ .context_menu = true });
                    }
                }
                w.setHot(h);
            },
            .pointer_leave => {
                w.pointer = .{ .x = -1, .y = -1 };
                w.setHot(.none);
            },
            .scroll => |sc| {
                const h = w.hitTest(sc.pos);
                if (!w.deliver(h, ev, true)) w.scrollChain(h, sc);
            },
            .key => |k| w.dispatchKey(k),
            .text => {
                // The text of a key the key handler consumed (a chord's
                // second stroke) is not typed.
                if (w.eat_text) {
                    w.eat_text = false;
                    return;
                }
                if (!w.focus.isNone()) _ = w.deliver(w.focus, ev, true);
            },
            .focus_gained, .focus_lost, .activate => {
                if (!w.focus.isNone()) _ = w.deliver(w.focus, ev, false);
            },
        }
    }

    fn dispatchKey(w: *Window, k: event.KeyPress) void {
        if (w.key_filter) |kf| {
            if (w.store.valid(kf.node)) {
                if (kf.f.filter(kf.f.ptr, k)) return;
            } else w.key_filter = null;
        }
        if (k.action == .release) {
            if (!w.focus.isNone()) _ = w.deliver(w.focus, .{ .key = k }, true);
            if (w.key_handler) |h| _ = h.call(k, w.keyContexts());
            return;
        }
        w.eat_text = false;
        // A chord in progress takes its next stroke before the focused node.
        const chord = if (w.key_handler) |h| h.isPending() else false;
        if (chord and w.key_handler.?.call(k, w.keyContexts())) {
            w.eat_text = k.codepoint != 0;
            return;
        }
        if (!w.focus.isNone() and w.deliver(w.focus, .{ .key = k }, true)) return;
        if ((k.key == .f10 and k.mods.shift and !k.mods.ctrl and !k.mods.alt) or k.key == .context_menu) {
            const c = w.contextNode(w.focus);
            if (!c.isNone()) {
                // Keyboard invocation: at the focused node's bottom-left.
                const r = w.layoutRect(w.focus);
                w.context_at = .{ .x = r.x, .y = r.bottom() };
                w.context_keyboard = true;
                w.respond(c, .{ .context_menu = true });
                return;
            }
        }
        if (w.key_handler) |h| if (!chord) {
            if (h.call(k, w.keyContexts())) {
                w.eat_text = k.codepoint != 0;
                return;
            }
        };
        switch (k.key) {
            .tab => if (!k.mods.ctrl and !k.mods.alt) {
                w.moveFocus(if (k.mods.shift) .prev else .next);
            },
            .enter, .numpad_enter, .space => if (!w.focus.isNone()) {
                if (!w.deliver(w.focus, .activate, false)) w.respond(w.focus, .{ .clicked = true });
            },
            .escape => {
                if (w.escapeTarget()) |id| {
                    w.closeOverlay(id);
                } else if (!w.focus.isNone()) {
                    w.respond(w.focus, .{ .cancelled = true });
                }
            },
            else => {},
        }
    }

    /// The `key_context` strings from the focused node up, innermost first.
    pub fn keyContexts(w: *Window) []const []const u8 {
        w.ctx_scratch.clearRetainingCapacity();
        var p = w.focus;
        while (!p.isNone() and w.store.valid(p)) : (p = w.store.parent(p)) {
            if (w.store.hot.items(.kind)[p.index] != .box) continue;
            const props: *const box.Box.Props = @ptrCast(@alignCast(w.store.props(p) orelse continue));
            if (props.key_context.len > 0) w.ctx_scratch.append(w.gpa, props.key_context) catch break;
        }
        return w.ctx_scratch.items;
    }

    /// Focus traversal direction.
    pub const FocusDir = enum { next, prev };

    /// Moves focus to the next or previous focusable node in tree order
    /// (wrapping), and makes the focus ring visible.
    pub fn moveFocus(w: *Window, dir: FocusDir) void {
        var first: NodeId = .none;
        var last: NodeId = .none;
        var before: NodeId = .none;
        var after: NodeId = .none;
        var passed = false;
        var stack: [512]NodeId = undefined;
        var sp: usize = 0;
        // A modal overlay traps focus.
        stack[0] = if (w.overlays.topModal()) |m| (if (m.panel.isNone() or !w.store.valid(m.panel)) w.root else m.panel) else w.root;
        sp = 1;
        // Pre-order DFS without recursion.
        while (sp > 0) {
            sp -= 1;
            const n = stack[sp];
            const fl = w.store.flags(n);
            if (fl.hidden) continue;
            if (fl.focusable and !fl.disabled and fl.painted) {
                if (first.isNone()) first = n;
                last = n;
                if (n.eql(w.focus)) {
                    passed = true;
                } else if (!passed) {
                    before = n;
                } else if (after.isNone()) {
                    after = n;
                }
            }
            // Push children reversed so the first child pops first.
            const mark = sp;
            var it = w.store.children(n);
            while (it.next()) |c| {
                if (sp < stack.len) {
                    stack[sp] = c;
                    sp += 1;
                }
            }
            std.mem.reverse(NodeId, stack[mark..sp]);
        }
        const target = switch (dir) {
            .next => if (!passed) first else if (after.isNone()) first else after,
            .prev => if (!passed) last else if (before.isNone()) last else before,
        };
        if (!target.isNone()) w.setFocus(target, true);
    }

    // -- platform -----------------------------------------------------------

    /// Translates one platform event for this window. `payload` resolves
    /// event payload slices (`Platform.payload`).
    pub fn handlePlatformEvent(w: *Window, ev: zg_platform.event.Event, payload: anytype) void {
        const inv = 1 / w.scale;
        switch (ev) {
            .window_configure => |c| w.resize(.{ .w = @as(f32, @floatFromInt(c.size.w)) / c.scale.factor, .h = @as(f32, @floatFromInt(c.size.h)) / c.scale.factor }, c.scale.factor),
            .window_close_requested => w.close_requested = true,
            .pointer_move => |p| w.dispatch(.{ .pointer_move = .{ .pos = .{ .x = p.pos_px[0] * inv, .y = p.pos_px[1] * inv }, .mods = p.mods } }),
            .pointer_button => |p| {
                const pt: event.Pointer = .{ .pos = .{ .x = p.pos_px[0] * inv, .y = p.pos_px[1] * inv }, .button = mapButton(p.button), .clicks = p.clicks, .mods = p.mods };
                w.dispatch(if (p.pressed) .{ .pointer_down = pt } else .{ .pointer_up = pt });
            },
            .pointer_enter_leave => |p| if (!p.entered) w.dispatch(.pointer_leave),
            .scroll => |s| w.dispatch(.{ .scroll = .{ .pos = w.pointer, .dx = s.dx, .dy = s.dy, .precise = s.unit == .pixels } }),
            .key => |k| w.dispatch(.{ .key = .{ .key = k.ev.key, .mods = k.ev.mods, .action = k.ev.action, .codepoint = k.ev.codepoint } }),
            .text_input => |t| w.dispatch(.{ .text = payload.payload(t.text) }),
            .window_focus => |f| if (!f.focused) {
                w.setHot(.none);
                w.dismissPopovers();
            },
            .frame => {
                w.needs_frame = true;
            },
            else => {},
        }
    }

    fn mapButton(b: zg_platform.types.Button) event.Button {
        return switch (b) {
            .left => .left,
            .right => .right,
            .middle => .middle,
            .back => .back,
            .forward => .forward,
            else => .left,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
