//! Tabs (E04.F07.S01.T02): the tab widget shared by the generic `tabs`
//! row (settings pages, panel sub-tabs) and the dock's tab strips.
//!
//! WAI-ARIA APG Tabs with automatic activation: Left/Right/Home/End move
//! focus along the tab list (roving) and the focused tab becomes active.
//! A dock tab also closes on Delete, a middle click or its close button,
//! and asks for its context menu on Shift+F10 or the Menu key; those come
//! back through the tab's `Response` (`cancelled` = close,
//! `context_menu`).

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const geom = @import("../core/geom.zig");
const event_mod = @import("../input/event.zig");
const measure_mod = @import("../layout/measure.zig");
const style_mod = @import("../layout/style.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const theme_mod = @import("../theme/theme.zig");
const tokens = @import("../theme/tokens.zig");
const roving = @import("roving.zig");
const Response = @import("../core/response.zig").Response;

const Ui = ui_mod.Ui;
const Size = geom.Size;
const Rect = geom.Rect;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;
const Theme = theme_mod.Theme;
const Roving = roving.Roving;

/// One tab.
pub const Tab = struct {
    /// Shown in snapshots.
    pub const name = "tab";
    /// Tabs take focus.
    pub const focusable = true;

    /// Tab props.
    pub const Props = struct {
        group: *Roving,
        title: []const u8,
        active: bool = false,
        /// Draw the accent line on the active tab (its group has focus).
        accent: bool = false,
        dirty: bool = false,
        preview: bool = false,
        pinned: bool = false,
        closable: bool = false,
        /// A short status after the title ("running").
        badge: []const u8 = "",
        /// Size limits (dock tabs: 80..240).
        min_w: f32 = 0,
        max_w: f32 = 1e9,
        /// Dock tabs sit on a strip of this height; generic tabs use the
        /// control height.
        height: f32 = 0,
    };

    /// Padding; dock tabs get their strip height.
    pub fn style(props: *const Props, th: *const Theme) style_mod.Style {
        return .{ .padding = .xy(pad, 0), .shrink = 0, .min_h = if (props.height > 0) props.height else th.dim(.control_h) };
    }

    /// Title, badge and close area, within the limits.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = titleStyle(mc.theme, props.preview);
        var w = mc.text.width(st, props.title);
        if (props.badge.len > 0) w += gap + mc.text.width(badgeStyle(mc.theme), props.badge);
        if (props.closable) w += gap + close_w;
        w = std.math.clamp(w + 2 * pad, props.min_w, props.max_w) - 2 * pad;
        return .{ .w = w, .h = mc.text.metrics(st).line_h };
    }

    /// Background, accent, title, badge, close or dirty mark, focus ring.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const hovered = pc.state.hovered;
        pc.fill(r, if (props.active) .bg_base else if (hovered) .hover_bg else .bg_elevated, 0);
        if (props.active and props.accent) pc.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = 2 }, .accent, 0);
        const st = titleStyle(pc.theme, props.preview);
        const lh = pc.text_sys.metrics(st).line_h;
        var tr = r.inset(.xy(pad, (r.h - lh) / 2));
        if (props.closable) tr.w -= gap + close_w;
        if (props.badge.len > 0) {
            const bs = badgeStyle(pc.theme);
            const bw = pc.text_sys.width(bs, props.badge);
            pc.textBox(props.badge, bs, pc.color(.accent), .{ .x = tr.right() - bw, .y = tr.y, .w = bw, .h = tr.h }, false, .start);
            tr.w -= bw + gap;
        }
        pc.textBox(props.title, st, pc.color(if (props.active) .fg else .fg_muted), tr, false, .start);
        if (props.closable) {
            const cr = closeRect(r);
            if (props.dirty and !hovered) {
                pc.textBox("\u{25cf}", st, pc.color(.fg_muted), cr, false, .center);
            } else if (hovered or props.active) {
                pc.textBox("\u{00d7}", st, pc.color(.fg_muted), cr, false, .center);
            }
        }
        pc.focusRing(r, 0);
    }

    /// Keys along the list, close and context requests.
    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        switch (ev.*) {
            .pointer_down => |p| {
                if (p.button == .middle and props.closable) {
                    ec.respond(.{ .cancelled = true });
                    return true;
                }
                if (p.button == .left and props.closable and closeRect(ec.rect()).contains(p.pos)) {
                    ec.respond(.{ .cancelled = true });
                    return true;
                }
                return false;
            },
            .key => |k| {
                if (k.action == .release) return false;
                if (k.key == .delete and props.closable and !k.mods.ctrl and !k.mods.alt) {
                    ec.respond(.{ .cancelled = true });
                    return true;
                }
                if ((k.key == .f10 and k.mods.shift) or k.key == .context_menu) {
                    ec.respond(.{ .context_menu = true });
                    return true;
                }
                return props.group.onKey(ec.node, k);
            },
            else => return false,
        }
    }

    /// A tab, selected when active.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .tab, .name = props.title, .checked = props.active };
    }
};

const pad: f32 = 10;
const gap: f32 = 6;
const close_w: f32 = 16;

fn closeRect(r: Rect) Rect {
    return .{ .x = r.right() - pad - close_w, .y = r.y, .w = close_w, .h = r.h };
}

fn titleStyle(th: *const Theme, italic: bool) text_mod.TextStyle {
    return .{ .font = .ui, .size = th.dim(.font_size), .italic = italic };
}

fn badgeStyle(th: *const Theme) text_mod.TextStyle {
    return .{ .font = .ui, .size = th.dim(.font_size_sm) };
}

/// Generic tabs options.
pub const TabsProps = struct {
    label: []const u8 = "Tabs",
    test_id: []const u8 = "tabs",
};

/// A row of tabs over `labels`; `active` follows clicks and keyboard
/// focus. Returns `.changed` when it moved.
pub fn tabs(ui: *Ui, labels: []const []const u8, active: *u32, p: TabsProps) Response {
    ui.open(.{ .style = .{ .shrink = 0 }, .test_id = p.test_id });
    defer ui.close();
    const group = ui.begin(roving.Group, .{ .role = .tablist, .label = p.label });
    defer ui.end(roving.Group);
    group.reset(ui.window());
    var out: Response = .{};
    for (labels, 0..) |l, i| {
        ui.id(i);
        const r = ui.leaf(Tab, .{ .group = group, .title = l, .active = i == active.*, .accent = true });
        group.add(ui.lastNode());
        if ((r.clicked or r.focus_gained) and active.* != i) {
            active.* = @intCast(i);
            out.changed = true;
            ui.window().markViewDirty(ui.currentView());
        }
    }
    return out;
}

test {
    std.testing.refAllDecls(@This());
}
