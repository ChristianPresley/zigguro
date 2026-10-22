//! Tooltips (E04.F05.S03.T01): short text shown next to a node after the
//! pointer rests on it.
//!
//! `tooltip(ui, text, p)` attaches a tooltip to the innermost open
//! container, `tooltipLast` to the node emitted just before it. Both emit
//! a hidden `Slot` leaf that keeps the text; the window's `Tips` finds the
//! nearest slot from the hovered (or keyboard-focused) node upwards.
//!
//! Timing: shown after `delay_ms` (500) of hover, or at once within 300 ms
//! of another tooltip closing (warm-up). Keyboard focus shows it after the
//! same delay when the focus ring is visible. A press, a key or a scroll
//! hides it. Placement is above the node; a node taller than 48 px gets
//! the tooltip 12 px below the pointer instead, so it never covers it.
//! Text wraps at 320 px.
//!
//! Not yet: the fade-in (E04.F08.S03.T01) and rich (Markdown) content.

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const window_mod = @import("../core/window.zig");
const style_mod = @import("../layout/style.zig");
const theme_mod = @import("../theme/theme.zig");
const overlay = @import("overlay.zig");

const NodeId = ids.NodeId;
const Ui = ui_mod.Ui;
const Window = window_mod.Window;

/// Tooltip options.
pub const TooltipProps = struct {
    /// Which side of the node it opens on.
    side: overlay.Side = .above,
    /// Hover time before it shows.
    delay_ms: u32 = default_delay_ms,
};

/// The hover delay.
pub const default_delay_ms: u32 = 500;
/// After a tooltip closes, others show at once for this long.
pub const warmup_ms: u64 = 300;
/// The widest a tooltip gets before its text wraps.
pub const max_width: f32 = 320;
/// Nodes taller than this get the tooltip below the pointer.
pub const large_anchor_h: f32 = 48;
/// Distance below the pointer for large nodes.
pub const pointer_offset: f32 = 12;

/// Holds a tooltip's text in the tree.
pub const Slot = struct {
    /// Shown in snapshots.
    pub const name = "tooltip_slot";

    /// The tooltip.
    pub const Props = struct {
        text: []const u8,
        side: overlay.Side = .above,
        delay_ms: u32 = default_delay_ms,
        /// Belongs to the previous sibling instead of the parent.
        prev: bool = false,
    };

    /// Takes no space.
    pub fn style(_: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return .{ .display = .none };
    }
};

/// Gives the innermost open container a tooltip.
pub fn tooltip(ui: *Ui, text: []const u8, p: TooltipProps) void {
    if (text.len == 0) return;
    _ = ui.leaf(Slot, .{ .text = text, .side = p.side, .delay_ms = p.delay_ms });
}

/// Gives the node emitted just before this call a tooltip.
pub fn tooltipLast(ui: *Ui, text: []const u8, p: TooltipProps) void {
    if (text.len == 0 or ui.lastNode().isNone()) return;
    _ = ui.leaf(Slot, .{ .text = text, .side = p.side, .delay_ms = p.delay_ms, .prev = true });
}

/// The tooltip for `n`: the node it belongs to and its slot.
pub const Found = struct { target: NodeId, slot: *const Slot.Props };

/// The nearest tooltip at or above `n`.
pub fn find(w: *Window, n: NodeId) ?Found {
    const kind = widget.kindOf(Slot);
    const kinds = w.store.hot.items(.kind);
    var p = n;
    while (!p.isNone() and w.store.valid(p)) : (p = w.store.parent(p)) {
        // A slot after `p` names `p`.
        const parent = w.store.parent(p);
        if (!parent.isNone()) {
            var it = w.store.children(parent);
            while (it.next()) |c| if (c.eql(p)) {
                if (it.next()) |s| if (kinds[s.index] == kind) {
                    const sp: *const Slot.Props = @ptrCast(@alignCast(w.store.props(s) orelse break));
                    if (sp.prev) return .{ .target = p, .slot = sp };
                };
                break;
            };
        }
        // A slot inside `p` names `p`.
        var it = w.store.children(p);
        while (it.next()) |c| if (kinds[c.index] == kind) {
            const sp: *const Slot.Props = @ptrCast(@alignCast(w.store.props(c) orelse continue));
            if (!sp.prev) return .{ .target = p, .slot = sp };
        };
    }
    return null;
}

/// A window's tooltip: at most one is pending or shown.
pub const Tips = struct {
    /// The node whose tooltip is pending or shown.
    target: NodeId = .none,
    timer: ?Window.TimerId = null,
    open: overlay.OverlayId = .none,
    /// When the last shown tooltip closed (for the warm-up).
    closed_ms: ?u64 = null,
    /// The shown text (owned).
    text: std.ArrayList(u8) = .empty,
    view: TipView = .{},
    win: ?*Window = null,
    /// Pending placement.
    side: overlay.Side = .above,
    /// Pointer position when the hover started (large anchors).
    at: geom.Vec2 = .{},
    keyboard: bool = false,

    /// Frees the text (the window closes the overlay first).
    pub fn deinit(t: *Tips, gpa: std.mem.Allocator) void {
        t.text.deinit(gpa);
        t.* = .{};
    }

    /// The pointer moved onto `n` (`none`: left the window).
    pub fn onHover(t: *Tips, w: *Window, n: NodeId) void {
        const f = if (n.isNone()) null else find(w, n);
        if (f) |x| if (x.target.eql(t.target) and !t.keyboard) return;
        const was_open = t.open != .none;
        t.hide(w);
        if (was_open) t.closed_ms = w.app.now_ms;
        const x = f orelse return;
        t.schedule(w, x, w.pointer, false);
    }

    /// Focus moved to `n`; `visible` is the focus ring.
    pub fn onFocus(t: *Tips, w: *Window, n: NodeId, visible: bool) void {
        if (!visible or n.isNone()) return;
        const x = find(w, n) orelse return;
        t.hide(w);
        t.schedule(w, x, w.pointer, true);
    }

    /// Hides the tooltip and drops a pending one (press, key, scroll).
    pub fn hide(t: *Tips, w: *Window) void {
        if (t.timer) |id| w.cancelTimer(id);
        t.timer = null;
        if (t.open != .none) {
            const id = t.open;
            t.open = .none;
            w.closeOverlay(id);
        }
        t.target = .none;
        t.keyboard = false;
    }

    /// True while a tooltip shows.
    pub fn isShown(t: *const Tips) bool {
        return t.open != .none;
    }

    fn schedule(t: *Tips, w: *Window, x: Found, at: geom.Vec2, keyboard: bool) void {
        t.win = w;
        t.target = x.target;
        t.side = x.slot.side;
        t.at = at;
        t.keyboard = keyboard;
        t.text.clearRetainingCapacity();
        t.text.appendSlice(w.gpa, x.slot.text) catch return;
        const now = w.app.now_ms;
        const warm = !keyboard and if (t.closed_ms) |c| now -| c <= warmup_ms else false;
        if (warm) return t.show(w);
        t.timer = w.setTimer(now + x.slot.delay_ms, .{ .ctx = t, .f = onTimer }) catch null;
    }

    fn onTimer(ctx: *anyopaque, w: *Window) void {
        const t: *Tips = @ptrCast(@alignCast(ctx));
        t.timer = null;
        t.show(w);
    }

    fn show(t: *Tips, w: *Window) void {
        if (t.target.isNone() or !w.store.valid(t.target)) return;
        const r = w.layoutRect(t.target);
        const large = !t.keyboard and r.h > large_anchor_h;
        const anchor: overlay.Anchor = if (large) .{ .rect = .{ .x = t.at.x, .y = t.at.y, .w = 0, .h = 0 } } else .{ .node = t.target };
        const placement: overlay.Placement = if (large) .{ .side = .below, .gap = pointer_offset } else .{ .side = t.side, .alignment = .start, .gap = 6 };
        const th = w.app.theme;
        const tw = w.text_sys.width(.{ .size = th.dim(.font_size_sm) }, t.text.items);
        t.view = .{ .tips = t };
        t.open = w.openOverlay(.of(&t.view), .{
            .layer = .tooltip,
            .anchor = anchor,
            .placement = placement,
            .light_dismiss = false,
            .restore_focus = false,
            .role = .tooltip,
            .label = t.text.items,
            .test_id = "tooltip",
            .width = if (tw + 2 * pad > max_width) max_width else null,
            .on_close = .{ .ctx = t, .f = onClosed },
        }) catch .none;
    }

    fn onClosed(ctx: *anyopaque, id: overlay.OverlayId) void {
        const t: *Tips = @ptrCast(@alignCast(ctx));
        if (t.open == id) t.open = .none;
    }
};

const pad: f32 = 16;

/// The tooltip's content.
const TipView = struct {
    tips: ?*Tips = null,

    pub fn build(v: *TipView, ui: *Ui) void {
        const t = v.tips orelse return;
        ui.text(t.text.items, .{ .style = .{ .size = ui.theme().dim(.font_size_sm) }, .theme_size = false, .color = .fg });
    }
};

test {
    std.testing.refAllDecls(@This());
}
