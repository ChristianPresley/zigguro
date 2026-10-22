//! Overlays (E04.F05.S03.T01): per-window layers of floating views
//! (popovers, dialogs, toasts, tooltips) above the main tree.
//!
//! Each open overlay is a child of the window root after the main view, in
//! (layer, open order), so it paints above everything before it and is hit
//! first. It is laid out with the window as the viewport and placed after
//! layout: next to an anchor (flipped to the other side when it does not
//! fit, shifted to stay 8 px inside the window) or centred. A modal
//! overlay puts a scrim under itself that swallows pointer input, traps Tab
//! inside itself and takes focus; closing restores focus.
//!
//! Light dismiss: a pointer press outside the topmost overlay closes it
//! (and is consumed) when it is light-dismissable. Escape closes the
//! topmost overlay that is modal or holds focus. Losing window focus
//! closes popovers.
//!
//! Not yet: enter/exit animations (waiting on E04.F08.S03.T01), tooltips
//! (they need timers), a11y hiding of the inert tree (E04.F09).

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const view_mod = @import("../core/view.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const style_mod = @import("../layout/style.zig");
const theme_mod = @import("../theme/theme.zig");

const Rect = geom.Rect;
const Size = geom.Size;
const NodeId = ids.NodeId;
const AnyView = view_mod.AnyView;
const Ui = ui_mod.Ui;

/// Overlay layers, bottom to top.
pub const Layer = enum(u8) { popover = 1, dialog = 2, toast = 3, tooltip = 4, drag = 5 };

/// Which side of the anchor an overlay opens on.
pub const Side = enum(u8) { below, above, right, left };

/// Alignment along the anchor's edge.
pub const Align = enum(u8) { start, center, end };

/// What an overlay is placed against.
pub const Anchor = union(enum) {
    /// A node, followed every frame; the overlay closes if it unmounts.
    node: NodeId,
    /// A fixed rectangle in window coordinates (context menus at the
    /// pointer).
    rect: Rect,
};

/// Placement next to the anchor.
pub const Placement = struct {
    side: Side = .below,
    alignment: Align = .start,
    /// Distance from the anchor.
    gap: f32 = 4,
};

/// Called when an overlay closes, for any reason.
pub const CloseHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, id: OverlayId) void,
};

/// How an overlay behaves.
pub const Options = struct {
    layer: Layer = .popover,
    /// Null centres the overlay in the window.
    anchor: ?Anchor = null,
    placement: Placement = .{},
    modal: bool = false,
    /// Close on a press outside, Escape, or window blur (popovers).
    light_dismiss: bool = true,
    /// Swallow the press that light-dismissed the overlay.
    consume_outside_click: bool = true,
    /// Give focus back to where it was on close.
    restore_focus: bool = true,
    /// Move focus into the overlay when it opens (modal overlays always do).
    take_focus: bool = false,
    /// Draw the panel (background, border, shadow, padding).
    chrome: bool = true,
    role: widget.Role = .none,
    /// Accessible name and test-query name of the panel.
    label: []const u8 = "",
    test_id: []const u8 = "",
    /// Heading drawn above the content (dialogs).
    title: []const u8 = "",
    /// Panel width; null sizes to content.
    width: ?f32 = null,
    /// Overlays sharing a non-zero group (a menu and its submenus) count as
    /// one for light dismiss: a press inside any of them is inside, and a
    /// press outside closes them all.
    group: u32 = 0,
    on_close: ?CloseHook = null,
};

/// An open overlay's handle.
pub const OverlayId = enum(u32) {
    none = 0,
    _,
};

/// One open overlay.
pub const Entry = struct {
    id: OverlayId,
    view: AnyView,
    opts: Options,
    /// The view whose build opened it (rebuilt when it closes), or 0.
    owner_view: u16 = 0,
    /// Focus when it opened.
    prev_focus: NodeId = .none,
    /// The panel node (set by the root build).
    panel: NodeId = .none,
    /// Focus still has to move in (after its first layout).
    wants_focus: bool = false,
};

/// The overlays of one window in paint order.
pub const Stack = struct {
    items: std.ArrayList(Entry) = .empty,
    next_id: u32 = 1,
    /// The root must be rebuilt (an overlay opened or closed).
    dirty: bool = false,

    /// Frees the list.
    pub fn deinit(s: *Stack, gpa: std.mem.Allocator) void {
        s.items.deinit(gpa);
        s.* = .{};
    }

    /// Adds an overlay above the others of its layer.
    pub fn push(s: *Stack, gpa: std.mem.Allocator, e: Entry) !OverlayId {
        var entry = e;
        entry.id = @enumFromInt(s.next_id);
        s.next_id +%= 1;
        if (s.next_id == 0) s.next_id = 1;
        // After every overlay of the same or a lower layer.
        var at: usize = s.items.items.len;
        while (at > 0 and @intFromEnum(s.items.items[at - 1].opts.layer) > @intFromEnum(entry.opts.layer)) at -= 1;
        try s.items.insert(gpa, at, entry);
        s.dirty = true;
        return entry.id;
    }

    /// The index of `id`, or null when it is not open.
    pub fn indexOf(s: *const Stack, id: OverlayId) ?usize {
        for (s.items.items, 0..) |e, i| if (e.id == id) return i;
        return null;
    }

    /// Removes and returns `id`'s entry.
    pub fn remove(s: *Stack, id: OverlayId) ?Entry {
        const i = s.indexOf(id) orelse return null;
        s.dirty = true;
        return s.items.orderedRemove(i);
    }

    /// The topmost overlay.
    pub fn top(s: *const Stack) ?*Entry {
        if (s.items.items.len == 0) return null;
        return &s.items.items[s.items.items.len - 1];
    }

    /// The topmost modal overlay.
    pub fn topModal(s: *const Stack) ?*Entry {
        var i = s.items.items.len;
        while (i > 0) {
            i -= 1;
            if (s.items.items[i].opts.modal) return &s.items.items[i];
        }
        return null;
    }
};

/// Keeps overlays this far from the window edges.
pub const viewport_margin: f32 = 8;

/// Where an overlay of `size` goes next to `anchor` inside `viewport`:
/// on `p.side` when it fits, else on the opposite side when that has more
/// room; aligned to the anchor's other edge when it would overflow; then
/// shifted to stay `viewport_margin` inside the viewport.
pub fn place(anchor: Rect, size: Size, viewport: Rect, p: Placement) Rect {
    const vp = viewport.inset(.all(viewport_margin));
    var x: f32 = 0;
    var y: f32 = 0;
    switch (p.side) {
        .below, .above => {
            const below_y = anchor.bottom() + p.gap;
            const above_y = anchor.y - p.gap - size.h;
            const room_below = vp.bottom() - below_y;
            const room_above = anchor.y - p.gap - vp.y;
            const want_below = p.side == .below;
            const fits = if (want_below) room_below >= size.h else room_above >= size.h;
            const other_more = if (want_below) room_above > room_below else room_below > room_above;
            const below = if (fits or !other_more) want_below else !want_below;
            y = if (below) below_y else above_y;
            x = switch (p.alignment) {
                .start => anchor.x,
                .center => anchor.x + (anchor.w - size.w) / 2,
                .end => anchor.right() - size.w,
            };
            // Overflowing an edge: align to the anchor's other edge instead
            // (a context menu at the pointer opens leftwards).
            if (p.alignment == .start and x + size.w > vp.right() and anchor.right() - size.w >= vp.x) x = anchor.right() - size.w;
            if (p.alignment == .end and x < vp.x and anchor.x + size.w <= vp.right()) x = anchor.x;
        },
        .right, .left => {
            const right_x = anchor.right() + p.gap;
            const left_x = anchor.x - p.gap - size.w;
            const room_right = vp.right() - right_x;
            const room_left = anchor.x - p.gap - vp.x;
            const want_right = p.side == .right;
            const fits = if (want_right) room_right >= size.w else room_left >= size.w;
            const other_more = if (want_right) room_left > room_right else room_right > room_left;
            const right = if (fits or !other_more) want_right else !want_right;
            x = if (right) right_x else left_x;
            y = switch (p.alignment) {
                .start => anchor.y,
                .center => anchor.y + (anchor.h - size.h) / 2,
                .end => anchor.bottom() - size.h,
            };
            if (p.alignment == .start and y + size.h > vp.bottom() and anchor.bottom() - size.h >= vp.y) y = anchor.bottom() - size.h;
            if (p.alignment == .end and y < vp.y and anchor.y + size.h <= vp.bottom()) y = anchor.y;
        },
    }
    x = @max(vp.x, @min(x, vp.right() - size.w));
    y = @max(vp.y, @min(y, vp.bottom() - size.h));
    return .{ .x = x, .y = y, .w = size.w, .h = size.h };
}

/// The centred rectangle for an unanchored overlay (a little above the
/// middle, as dialogs sit).
pub fn center(size: Size, viewport: Rect) Rect {
    const vp = viewport.inset(.all(viewport_margin));
    const x = vp.x + @max(0, (vp.w - size.w) / 2);
    const y = vp.y + @max(0, (vp.h - size.h) * 0.4);
    return .{ .x = x, .y = y, .w = size.w, .h = size.h };
}

/// Emits the window's overlays under the root (called by `Ui.buildRoot`
/// after the main view).
pub fn build(ui: *Ui, stack: *Stack) void {
    const th = ui.theme();
    for (stack.items.items) |*e| {
        const key: u64 = @intFromEnum(e.id);
        if (e.opts.modal) {
            ui.id(key * 2);
            ui.open(.{
                .style = .{ .position = .absolute, .inset = .{ .l = 0, .t = 0, .r = 0, .b = 0 }, .bg = .{ .token = .overlay_scrim } },
                .hit = true,
                .test_id = "overlay.scrim",
            });
            ui.close();
        }
        ui.id(key * 2 + 1);
        const pad = th.dim(.space_md);
        ui.open(.{
            .style = .{
                .position = .absolute,
                .inset = .{ .l = 0, .t = 0 },
                .dir = .column,
                .gap = if (e.opts.title.len > 0) pad else 0,
                .w = if (e.opts.width) |wd| .{ .px = wd } else .auto,
                .max_w = ui.window().size.w - 2 * viewport_margin,
                .max_h = ui.window().size.h - 2 * viewport_margin,
                .padding = if (e.opts.chrome) .all(if (e.opts.layer == .dialog) pad * 2 else th.dim(.space_xs)) else .{},
                .bg = if (e.opts.chrome) .{ .token = .bg_overlay } else .none,
                .border = if (e.opts.chrome) .{ .token = .border } else .none,
                .border_w = if (e.opts.chrome) th.dim(.border_w) else 0,
                .radius = if (e.opts.chrome) th.dim(.radius_lg) else 0,
                .clip = true,
            },
            .role = if (e.opts.role != .none) e.opts.role else if (e.opts.layer == .dialog) .dialog else .group,
            .label = e.opts.label,
            .test_id = e.opts.test_id,
            .hit = true,
            .focusable = e.opts.modal,
        });
        e.panel = ui.current();
        if (e.opts.title.len > 0) ui.text(e.opts.title, .{ .style = .{ .size = th.dim(.font_size_lg), .weight = 600 }, .theme_size = false });
        ui.mount(e.view);
        ui.close();
    }
}

/// Popover options.
pub const PopoverProps = struct {
    placement: Placement = .{},
    label: []const u8 = "",
    test_id: []const u8 = "",
    width: ?f32 = null,
    modal: bool = false,
    take_focus: bool = true,
};

/// Remembers which overlay a `popover` call opened.
const PopoverSlot = struct {
    pub const name = "popover_slot";
    pub const Props = struct {};
    pub const State = struct { id: OverlayId = .none };

    pub fn style(_: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return .{ .display = .none };
    }
};

/// Keeps overlay `opts` showing `content` while `open.*` is true. When the
/// overlay is dismissed (outside press, Escape), `open.*` turns false on
/// the owning view's next build.
pub fn bound(ui: *Ui, open: *bool, content: AnyView, opts: Options) void {
    _ = ui.leaf(PopoverSlot, .{});
    const st = ui.lastState(PopoverSlot) orelse return;
    const w = ui.window();
    if (st.id != .none and !w.isOverlayOpen(st.id)) {
        // Dismissed since the last build.
        st.id = .none;
        open.* = false;
    }
    if (open.* and st.id == .none) {
        st.id = w.openOverlay(content, opts) catch .none;
    } else if (!open.* and st.id != .none) {
        w.closeOverlay(st.id);
        st.id = .none;
    }
}

/// Shows `content` next to `anchor` while `open.*` is true.
pub fn popover(ui: *Ui, open: *bool, anchor: NodeId, content: AnyView, p: PopoverProps) void {
    bound(ui, open, content, .{
        .layer = .popover,
        .anchor = .{ .node = anchor },
        .placement = p.placement,
        .modal = p.modal,
        .label = p.label,
        .test_id = p.test_id,
        .width = p.width,
        .take_focus = p.take_focus,
    });
}

test {
    std.testing.refAllDecls(@This());
}
