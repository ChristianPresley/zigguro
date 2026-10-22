//! The toolbar (E04.F05.S04.T02): a row of command buttons with roving
//! focus (WAI-ARIA APG toolbar: Left/Right, Home/End) and an overflow
//! "⋯" menu.
//!
//! When the items do not fit, the lowest priority goes first (ties: the
//! rightmost) into the "⋯" menu at the end; priority ≥ 1000 is pinned.
//! Toggle items (`toggled` set) draw pressed while on and show as checkbox
//! items in the overflow menu. Actions run through `on_action` or the
//! window's `ActionHandler`.
//!
//! Icons are text glyphs until the icon set lands (E04.F08); an item shows
//! its `icon` when set, else its label, and is always named by its label.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const geom = @import("../core/geom.zig");
const actions = @import("../input/actions.zig");
const event_mod = @import("../input/event.zig");
const measure_mod = @import("../layout/measure.zig");
const style_mod = @import("../layout/style.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const theme_mod = @import("../theme/theme.zig");
const tokens = @import("../theme/tokens.zig");
const menu = @import("menu.zig");
const roving = @import("roving.zig");

const Ui = ui_mod.Ui;
const Size = geom.Size;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;
const Theme = theme_mod.Theme;
const Roving = roving.Roving;

/// One toolbar command.
pub const ToolItem = struct {
    id: []const u8,
    /// A short glyph shown instead of the label; empty shows the label.
    icon: []const u8 = "",
    label: []const u8,
    action: actions.ActionId,
    arg: ?[]const u8 = null,
    /// Non-null makes a toggle button.
    toggled: ?bool = null,
    /// Higher stays longer; ≥ `pinned_priority` never overflows.
    priority: i32 = 0,
    enabled: bool = true,
};

/// Items at or above this priority never overflow.
pub const pinned_priority: i32 = 1000;
/// The most items a toolbar lays out.
pub const max_items = roving.max_items - 1;

/// Toolbar options.
pub const ToolbarProps = struct {
    /// Accessible name.
    label: []const u8 = "Toolbar",
    /// The width to fit into; null uses the window's.
    width: ?f32 = null,
    /// Receives actions instead of the window's `ActionHandler`.
    on_action: ?menu.ActionCb = null,
    test_id: []const u8 = "toolbar",
};

/// A toolbar button.
pub const ToolButton = struct {
    /// Shown in snapshots.
    pub const name = "tool_button";
    /// Buttons take focus.
    pub const focusable = true;

    /// Button props.
    pub const Props = struct {
        group: *Roving,
        text: []const u8,
        label: []const u8,
        toggled: ?bool = null,
        disabled: bool = false,
    };

    /// Square-ish padding at the control height.
    pub fn style(_: *const Props, th: *const Theme) style_mod.Style {
        return .{ .padding = .xy(pad, 0), .min_h = th.dim(.control_h), .shrink = 0 };
    }

    /// The shown text.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = textStyle(mc.theme);
        return .{ .w = mc.text.width(st, props.text), .h = mc.text.metrics(st).line_h };
    }

    /// Hover/pressed/toggled background, text and focus ring.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const s = pc.state;
        const rad = pc.dim(.radius_sm);
        const on = props.toggled orelse false;
        const bg: ?tokens.Token = if (s.pressed and !props.disabled) .button_bg_pressed else if (on) .selection_bg else if (s.hovered and !props.disabled) .hover_bg else null;
        if (bg) |t| pc.fill(r, t, rad);
        if (on) pc.border(r, pc.dim(.border_w), pc.color(.accent), rad);
        const st = textStyle(pc.theme);
        const lh = pc.text_sys.metrics(st).line_h;
        const fg = pc.color(if (props.disabled) .fg_disabled else .fg);
        pc.textBox(props.text, st, fg, r.inset(.xy(pad, (r.h - lh) / 2)), false, .center);
        pc.focusRing(r, rad);
    }

    /// Arrow keys move along the toolbar.
    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        return switch (ev.*) {
            .key => |k| props.group.onKey(ec.node, k),
            else => false,
        };
    }

    /// A button (pressed state for toggles) named by its label.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .button, .name = props.label, .checked = props.toggled, .disabled = props.disabled };
    }
};

const pad: f32 = 6;

fn textStyle(th: *const Theme) text_mod.TextStyle {
    return .{ .font = .ui, .size = th.dim(.font_size) };
}

fn shownText(it: ToolItem) []const u8 {
    return if (it.icon.len > 0) it.icon else it.label;
}

/// Which items fit in `avail` pixels given each one's width; the rest
/// overflow. `more_w` is the width of the "⋯" button.
pub fn fit(items: []const ToolItem, widths: []const f32, avail: f32, more_w: f32, shown: []bool) void {
    var total: f32 = 0;
    for (widths, shown) |w, *s| {
        total += w;
        s.* = true;
    }
    var more = false;
    while (total + (if (more) more_w else 0) > avail) {
        // The lowest priority shown and not pinned; ties: the rightmost.
        var pick: ?usize = null;
        for (items, 0..) |it, i| {
            if (!shown[i] or it.priority >= pinned_priority) continue;
            if (pick == null or it.priority <= items[pick.?].priority) pick = i;
        }
        const i = pick orelse return;
        shown[i] = false;
        total -= widths[i];
        more = true;
    }
}

/// Adds a toolbar (see the module doc). `items` are read during the build
/// only; the overflow menu copies what it shows.
pub fn toolbar(ui: *Ui, items: []const ToolItem, p: ToolbarProps) void {
    const w = ui.window();
    const th = ui.theme();
    const st = textStyle(th);
    const n = @min(items.len, max_items);
    var widths: [max_items]f32 = undefined;
    for (items[0..n], 0..) |it, i| widths[i] = w.text_sys.width(st, shownText(it)) + 2 * pad;
    const more_w = w.text_sys.width(st, more_text) + 2 * pad;
    var shown: [max_items]bool = undefined;
    fit(items[0..n], widths[0..n], p.width orelse w.size.w, more_w, shown[0..n]);

    ui.open(.{ .style = .{ .shrink = 0 }, .test_id = p.test_id });
    defer ui.close();
    const group = ui.begin(roving.Group, .{ .role = .toolbar, .label = p.label, .gap = 2 });
    defer ui.end(roving.Group);
    group.reset(w);
    var hidden: [max_items]menu.MenuItem = undefined;
    var nh: usize = 0;
    for (items[0..n], shown[0..n]) |it, vis| {
        if (!vis) {
            hidden[nh] = .{ .action = .{ .label = it.label, .action = it.action, .arg = it.arg, .enabled = it.enabled, .checked = it.toggled } };
            nh += 1;
            continue;
        }
        ui.id(it.id);
        const r = ui.leaf(ToolButton, .{ .group = group, .text = shownText(it), .label = it.label, .toggled = it.toggled, .disabled = !it.enabled });
        group.add(ui.lastNode());
        if (r.clicked and it.enabled) run(w, p, it.action, it.arg);
    }
    if (nh == 0) return;
    ui.id("\u{22ef}");
    const r = ui.leaf(ToolButton, .{ .group = group, .text = more_text, .label = "More actions" });
    group.add(ui.lastNode());
    if (r.clicked) _ = menu.openMenu(w, hidden[0..nh], .{ .node = ui.lastNode() }, .{ .on_action = p.on_action, .keyboard = w.focus_visible, .test_id = "toolbar_overflow" }) catch {};
}

const more_text = "\u{22ef}";

fn run(w: anytype, p: ToolbarProps, action: actions.ActionId, arg: ?[]const u8) void {
    if (p.on_action) |cb| return cb.f(cb.ctx, action, arg);
    _ = w.dispatchAction(action, arg);
}

const testing = std.testing;

test "toolbar: overflow drops the lowest priority, rightmost first" {
    const items = [_]ToolItem{
        .{ .id = "a", .label = "a", .action = "a", .priority = 5 },
        .{ .id = "b", .label = "b", .action = "b", .priority = 1 },
        .{ .id = "c", .label = "c", .action = "c", .priority = 1 },
        .{ .id = "d", .label = "d", .action = "d", .priority = 1000 },
    };
    const widths = [_]f32{ 10, 10, 10, 10 };
    var shown: [4]bool = undefined;
    fit(&items, &widths, 40, 5, &shown);
    try testing.expectEqualSlices(bool, &.{ true, true, true, true }, &shown);
    fit(&items, &widths, 39, 5, &shown);
    try testing.expectEqualSlices(bool, &.{ true, true, false, true }, &shown);
    fit(&items, &widths, 0, 5, &shown);
    try testing.expectEqualSlices(bool, &.{ false, false, false, true }, &shown);
}
