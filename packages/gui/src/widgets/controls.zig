//! Basic controls (E04.F05.S01.T01, first part): button, checkbox, toggle
//! switch, separator, progress bar, badge and spacer. Every control paints
//! with theme tokens only and is keyboard-operable (Tab to focus,
//! Enter/Space to activate) with a visible focus ring.

const std = @import("std");
const geom = @import("../core/geom.zig");
const widget = @import("../core/widget.zig");
const response_mod = @import("../core/response.zig");
const ui_mod = @import("../core/ui.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const measure_mod = @import("../layout/measure.zig");
const style_mod = @import("../layout/style.zig");
const theme_mod = @import("../theme/theme.zig");
const tokens = @import("../theme/tokens.zig");

const Size = geom.Size;
const Rect = geom.Rect;
const Response = response_mod.Response;
const Ui = ui_mod.Ui;
const Token = tokens.Token;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;

fn bodyStyle(th: *const theme_mod.Theme) text_mod.TextStyle {
    return .{ .size = th.dim(.font_size) };
}

/// Button variants.
pub const Variant = enum(u8) { secondary, primary, danger, ghost };

/// A push button with a text label.
pub const Button = struct {
    /// Shown in snapshots.
    pub const name = "button";
    /// Buttons take keyboard focus.
    pub const focusable = true;

    /// Button props.
    pub const Props = struct {
        label: []const u8,
        variant: Variant = .secondary,
        disabled: bool = false,
    };

    /// Padding and control height from the theme.
    pub fn style(_: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .padding = .xy(th.dim(.space_md) + 4, 0), .min_h = th.dim(.control_h), .shrink = 0 };
    }

    /// The label's size plus padding.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = bodyStyle(mc.theme);
        const m = mc.text.metrics(st);
        return .{ .w = mc.text.width(st, props.label), .h = m.line_h };
    }

    /// Background by variant and state, label, focus ring.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const rad = pc.dim(.radius_md);
        const s = pc.state;
        const bg: Token, const fg: Token = switch (props.variant) {
            .primary => .{ if (s.pressed) .accent_pressed else if (s.hovered) .accent_hover else .accent, .fg_on_accent },
            .danger => .{ if (s.hovered) .danger else .button_bg, if (s.hovered) .fg_on_accent else .danger },
            .ghost => .{ if (s.pressed) .button_bg_pressed else if (s.hovered) .hover_bg else .bg_base, .fg },
            .secondary => .{ if (s.pressed) .button_bg_pressed else if (s.hovered) .button_bg_hover else .button_bg, .button_fg },
        };
        if (props.variant != .ghost or s.hovered or s.pressed) pc.fill(r, bg, rad);
        if (props.variant == .secondary or pc.theme.isHighContrast()) pc.border(r, pc.dim(.border_w), pc.color(.button_border), rad);
        const color = if (props.disabled) pc.color(.fg_disabled) else pc.color(fg);
        pc.textBox(props.label, bodyStyle(pc.theme), color, r.inset(.xy(pc.dim(.space_md) + 4, (r.h - pc.text_sys.metrics(bodyStyle(pc.theme)).line_h) / 2)), false, .center);
        pc.focusRing(r, rad);
    }

    /// A button named by its label.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .button, .name = props.label, .disabled = props.disabled };
    }
};

/// A push button; returns `.clicked` after a click or Enter/Space.
pub fn button(ui: *Ui, props: Button.Props) Response {
    var r = ui.leaf(Button, props);
    if (props.disabled) r.clicked = false;
    return r;
}

/// A checkbox with a label; toggles `value` on click or Space.
pub const Checkbox = struct {
    /// Shown in snapshots.
    pub const name = "checkbox";
    /// Checkboxes take keyboard focus.
    pub const focusable = true;

    /// Checkbox props.
    pub const Props = struct {
        label: []const u8,
        checked: bool,
        disabled: bool = false,
    };

    /// No padding; the box is drawn at the start.
    pub fn style(_: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .min_h = th.dim(.control_h) - 6, .shrink = 0 };
    }

    fn boxSize(th: *const theme_mod.Theme) f32 {
        return th.dim(.font_size) + 3;
    }

    /// Box, gap and label.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = bodyStyle(mc.theme);
        const b = boxSize(mc.theme);
        const lw = mc.text.width(st, props.label);
        return .{ .w = b + (if (lw > 0) mc.theme.dim(.space_md) + lw else 0), .h = @max(b, mc.text.metrics(st).line_h) };
    }

    /// The box (filled with a check mark when checked) and the label.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const b = boxSize(pc.theme);
        const r = pc.bounds();
        const bx: Rect = .{ .x = 0, .y = (r.h - b) / 2, .w = b, .h = b };
        const rad = pc.dim(.radius_sm);
        if (props.checked) {
            pc.fill(bx, .control_checked, rad);
            // The check mark: two strokes drawn as thin rects (no path renderer).
            const t = @max(1.5, b / 8);
            pc.rect(.{ .x = bx.x + b * 0.22, .y = bx.y + b * 0.5, .w = b * 0.25, .h = t }, pc.color(.fg_on_accent), .all(t / 2));
            pc.rect(.{ .x = bx.x + b * 0.4, .y = bx.y + b * 0.3, .w = t, .h = b * 0.42 }, pc.color(.fg_on_accent), .all(t / 2));
        } else {
            pc.fill(bx, .control_bg, rad);
            pc.border(bx, pc.dim(.border_w), pc.color(if (pc.state.hovered) .border_strong else .control_border), rad);
        }
        const st = bodyStyle(pc.theme);
        const color = pc.color(if (props.disabled) .fg_disabled else .fg);
        pc.textBox(props.label, st, color, .{ .x = b + pc.dim(.space_md), .y = (r.h - pc.text_sys.metrics(st).line_h) / 2, .w = r.w, .h = r.h }, false, .start);
        pc.focusRing(bx, rad);
    }

    /// A checkbox with its checked state.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .checkbox, .name = props.label, .checked = props.checked, .disabled = props.disabled };
    }
};

/// A checkbox bound to `value`; returns `.changed` when toggled.
pub fn checkbox(ui: *Ui, label: []const u8, value: *bool) Response {
    var r = ui.leaf(Checkbox, .{ .label = label, .checked = value.* });
    if (r.clicked) {
        value.* = !value.*;
        r.changed = true;
        ui.cx().notify();
    }
    return r;
}

/// An on/off switch with a label.
pub const Toggle = struct {
    /// Shown in snapshots.
    pub const name = "toggle";
    /// Switches take keyboard focus.
    pub const focusable = true;

    /// Toggle props.
    pub const Props = struct {
        label: []const u8,
        on: bool,
        disabled: bool = false,
    };

    /// No padding.
    pub fn style(_: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .min_h = th.dim(.control_h) - 6, .shrink = 0 };
    }

    fn track(th: *const theme_mod.Theme) Size {
        const h = th.dim(.font_size) + 5;
        return .{ .w = h * 1.8, .h = h };
    }

    /// Track, gap and label.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = bodyStyle(mc.theme);
        const t = track(mc.theme);
        const lw = mc.text.width(st, props.label);
        return .{ .w = t.w + (if (lw > 0) mc.theme.dim(.space_md) + lw else 0), .h = @max(t.h, mc.text.metrics(st).line_h) };
    }

    /// Track, thumb and label.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const t = track(pc.theme);
        const r = pc.bounds();
        const tr: Rect = .{ .x = 0, .y = (r.h - t.h) / 2, .w = t.w, .h = t.h };
        pc.fill(tr, if (props.on) .control_checked else .track, t.h / 2);
        if (!props.on) pc.border(tr, pc.dim(.border_w), pc.color(.control_border), t.h / 2);
        const d = t.h - 6;
        const x = if (props.on) tr.x + tr.w - 3 - d else tr.x + 3;
        pc.fill(.{ .x = x, .y = tr.y + 3, .w = d, .h = d }, .control_thumb, d / 2);
        const st = bodyStyle(pc.theme);
        pc.textBox(props.label, st, pc.color(if (props.disabled) .fg_disabled else .fg), .{ .x = t.w + pc.dim(.space_md), .y = (r.h - pc.text_sys.metrics(st).line_h) / 2, .w = r.w, .h = r.h }, false, .start);
        pc.focusRing(tr, t.h / 2);
    }

    /// A switch with its state.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .switch_, .name = props.label, .checked = props.on, .disabled = props.disabled };
    }
};

/// A switch bound to `value`; returns `.changed` when flipped.
pub fn toggle(ui: *Ui, label: []const u8, value: *bool) Response {
    var r = ui.leaf(Toggle, .{ .label = label, .on = value.* });
    if (r.clicked) {
        value.* = !value.*;
        r.changed = true;
        ui.cx().notify();
    }
    return r;
}

/// A 1 px line; horizontal in a column, vertical in a row.
pub const Separator = struct {
    /// Shown in snapshots.
    pub const name = "separator";

    /// Separator props.
    pub const Props = struct { vertical: bool = false };

    /// Stretches across the cross axis, 1 px along the main axis.
    pub fn style(props: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        const w = th.dim(.border_w);
        return if (props.vertical) .{ .w = .{ .px = w }, .shrink = 0, .align_self = .stretch } else .{ .h = .{ .px = w }, .shrink = 0, .align_self = .stretch };
    }

    /// A line in the border colour.
    pub fn paint(pc: *PaintCx, _: *const Props, _: *widget.NoState) void {
        pc.fill(pc.bounds(), .border, 0);
    }

    /// A separator.
    pub fn a11y(_: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .separator };
    }
};

/// A separator line.
pub fn separator(ui: *Ui, vertical: bool) void {
    _ = ui.leaf(Separator, .{ .vertical = vertical });
}

/// A determinate progress bar (0..1).
pub const Progress = struct {
    /// Shown in snapshots.
    pub const name = "progress";

    /// Progress props.
    pub const Props = struct { value: f32, label: []const u8 = "" };

    /// A thin full-width bar.
    pub fn style(_: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .h = .{ .px = th.dim(.space_sm) }, .min_w = 40, .align_self = .stretch };
    }

    /// Track and fill.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        pc.fill(r, .track, r.h / 2);
        const v = std.math.clamp(props.value, 0, 1);
        if (v > 0) pc.fill(.{ .w = r.w * v, .h = r.h }, .accent, r.h / 2);
    }

    /// A progress bar with its value.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .progressbar, .name = props.label, .value = props.value };
    }

    /// The value only repaints.
    pub fn layoutHash(_: *const Props) u64 {
        return 0x9e;
    }
};

/// A progress bar.
pub fn progress(ui: *Ui, value: f32) void {
    _ = ui.leaf(Progress, .{ .value = value });
}

/// A small pill with a count or short text.
pub const Badge = struct {
    /// Shown in snapshots.
    pub const name = "badge";

    /// Badge props.
    pub const Props = struct { text: []const u8 };

    /// Compact padding.
    pub fn style(_: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .padding = .xy(th.dim(.space_sm) + 2, 1), .shrink = 0, .align_self = .center };
    }

    /// The text at the small size.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st: text_mod.TextStyle = .{ .size = mc.theme.dim(.font_size_sm) };
        return .{ .w = mc.text.width(st, props.text), .h = mc.text.metrics(st).line_h };
    }

    /// Pill and text.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        pc.fill(r, .badge_bg, r.h / 2);
        pc.textBox(props.text, .{ .size = pc.dim(.font_size_sm) }, pc.color(.badge_fg), r.inset(.xy(pc.dim(.space_sm) + 2, 1)), false, .center);
    }

    /// Status text.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .status, .name = props.text };
    }
};

/// A badge.
pub fn badge(ui: *Ui, s: []const u8) void {
    _ = ui.leaf(Badge, .{ .text = s });
}

/// Flexible empty space.
pub fn spacer(ui: *Ui) void {
    ui.with(.{ .grow = 1 });
    ui.open(.{});
    ui.close();
}

test {
    std.testing.refAllDecls(@This());
}
