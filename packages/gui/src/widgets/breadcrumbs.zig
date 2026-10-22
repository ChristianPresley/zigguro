//! Breadcrumbs (E04.F05.S04.T02): path segments with chevron separators.
//!
//! Clicking a segment (or Enter/Down on it) opens a dropdown of its
//! children, asked for lazily through `Crumb.children`; a segment without
//! children runs its action. When the segments do not fit, the middle ones
//! collapse into a "…" menu, keeping the first and the last two.
//! Left/Right (and Home/End) move between segments.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const geom = @import("../core/geom.zig");
const window_mod = @import("../core/window.zig");
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
const Window = window_mod.Window;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;
const Theme = theme_mod.Theme;
const Roving = roving.Roving;
const Allocator = std.mem.Allocator;

/// Fills `out` with a segment's dropdown. Strings may live in `arena`,
/// which is freed once the menu has copied them.
pub const ChildrenFn = *const fn (ctx: ?*anyopaque, arena: Allocator, out: *std.ArrayList(menu.MenuItem)) void;

/// One segment.
pub const Crumb = struct {
    label: []const u8,
    /// A short glyph before the label.
    icon: []const u8 = "",
    /// The segment's dropdown (siblings, symbols, ...).
    children: ?ChildrenFn = null,
    ctx: ?*anyopaque = null,
    /// Run when the segment has no children, or from the "…" menu.
    action: ?actions.ActionId = null,
    arg: ?[]const u8 = null,
};

/// Breadcrumb options.
pub const BreadcrumbsProps = struct {
    label: []const u8 = "Breadcrumbs",
    /// The width to fit into; null uses the window's.
    width: ?f32 = null,
    /// Receives actions instead of the window's `ActionHandler`.
    on_action: ?menu.ActionCb = null,
    test_id: []const u8 = "breadcrumbs",
};

/// The most segments shown.
pub const max_crumbs = roving.max_items - 1;

/// A segment button.
pub const CrumbButton = struct {
    /// Shown in snapshots.
    pub const name = "crumb";
    /// Segments take focus.
    pub const focusable = true;

    /// Segment props.
    pub const Props = struct {
        group: *Roving,
        text: []const u8,
        /// The last segment draws in the normal text colour.
        current: bool = false,
    };

    /// Tight padding.
    pub fn style(_: *const Props, _: *const Theme) style_mod.Style {
        return .{ .padding = .xy(pad, 0), .shrink = 0, .align_self = .stretch };
    }

    /// The text.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = textStyle(mc.theme);
        return .{ .w = mc.text.width(st, props.text), .h = mc.text.metrics(st).line_h };
    }

    /// Hover background, text and focus ring.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const rad = pc.dim(.radius_sm);
        if (pc.state.pressed) pc.fill(r, .button_bg_pressed, rad) else if (pc.state.hovered) pc.fill(r, .hover_bg, rad);
        const st = textStyle(pc.theme);
        const lh = pc.text_sys.metrics(st).line_h;
        const fg: tokens.Token = if (props.current or pc.state.hovered) .fg else .fg_muted;
        pc.textBox(props.text, st, pc.color(fg), r.inset(.xy(pad, (r.h - lh) / 2)), false, .start);
        pc.focusRing(r, rad);
    }

    /// Left/Right/Home/End move; Down opens like Enter.
    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        switch (ev.*) {
            .key => |k| {
                if (k.key == .arrow_down and k.action != .release and !k.mods.ctrl and !k.mods.alt) {
                    ec.respond(.{ .clicked = true });
                    return true;
                }
                return props.group.onKey(ec.node, k);
            },
            else => return false,
        }
    }

    /// A button named by its text.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .button, .name = props.text };
    }
};

const pad: f32 = 4;
const chevron = "\u{203a}";
const ellipsis = "\u{2026}";

fn textStyle(th: *const Theme) text_mod.TextStyle {
    return .{ .font = .ui, .size = th.dim(.font_size_sm) };
}

/// The segments `[1, end)` to collapse so that the rest fit in `avail`,
/// given each segment's width (separators included) and the "…" width.
/// Keeps the first and last two; `end` 1 collapses none.
pub fn collapse(widths: []const f32, avail: f32, more_w: f32) usize {
    var total: f32 = 0;
    for (widths) |w| total += w;
    if (total <= avail or widths.len <= 3) return 1;
    total += more_w;
    var end: usize = 1;
    while (total > avail and end < widths.len - 2) : (end += 1) total -= widths[end];
    return end;
}

/// Adds breadcrumbs for `crumbs` (see the module doc). `crumbs` and their
/// contexts are used during the build only.
pub fn breadcrumbs(ui: *Ui, crumbs: []const Crumb, p: BreadcrumbsProps) void {
    const w = ui.window();
    const st = textStyle(ui.theme());
    const n = @min(crumbs.len, max_crumbs);
    const sep_w = w.text_sys.width(st, chevron) + 2 * pad;
    var widths: [max_crumbs]f32 = undefined;
    for (crumbs[0..n], 0..) |c, i| widths[i] = w.text_sys.width(st, c.label) + w.text_sys.width(st, c.icon) + 2 * pad + (if (i > 0) sep_w else 0);
    const more_w = w.text_sys.width(st, ellipsis) + 2 * pad + sep_w;
    const end = collapse(widths[0..n], p.width orelse w.size.w, more_w);

    ui.open(.{ .style = .{ .shrink = 0 }, .test_id = p.test_id });
    defer ui.close();
    const group = ui.begin(roving.Group, .{ .role = .toolbar, .label = p.label });
    defer ui.end(roving.Group);
    group.reset(w);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i == 1 and end > 1) {
            separator(ui);
            ui.id("\u{2026}");
            const r = ui.leaf(CrumbButton, .{ .group = group, .text = ellipsis });
            group.add(ui.lastNode());
            if (r.clicked) openHidden(w, crumbs[1..end], ui.lastNode(), p);
            i = end - 1;
            continue;
        }
        const c = crumbs[i];
        if (i > 0) separator(ui);
        ui.id(i);
        const text = if (c.icon.len > 0) std.fmt.allocPrint(ui.arena(), "{s} {s}", .{ c.icon, c.label }) catch c.label else c.label;
        const r = ui.leaf(CrumbButton, .{ .group = group, .text = text, .current = i + 1 == n });
        group.add(ui.lastNode());
        if (r.clicked) activate(w, c, ui.lastNode(), p);
    }
}

fn separator(ui: *Ui) void {
    ui.text(chevron, .{ .style = .{ .font = .ui }, .color = .fg_muted, .wrap = false });
}

fn activate(w: *Window, c: Crumb, node: @import("../core/ids.zig").NodeId, p: BreadcrumbsProps) void {
    const f = c.children orelse {
        if (c.action) |a| run(w, p, a, c.arg);
        return;
    };
    var arena: std.heap.ArenaAllocator = .init(w.gpa);
    defer arena.deinit();
    var items: std.ArrayList(menu.MenuItem) = .empty;
    f(c.ctx, arena.allocator(), &items);
    if (items.items.len == 0) {
        if (c.action) |a| run(w, p, a, c.arg);
        return;
    }
    _ = menu.openMenu(w, items.items, .{ .node = node }, .{ .on_action = p.on_action, .keyboard = w.focus_visible, .test_id = "crumb_menu" }) catch {};
}

fn openHidden(w: *Window, hidden: []const Crumb, node: @import("../core/ids.zig").NodeId, p: BreadcrumbsProps) void {
    var items: [max_crumbs]menu.MenuItem = undefined;
    for (hidden, 0..) |c, i| items[i] = .{ .action = .{ .label = c.label, .action = c.action orelse "", .arg = c.arg, .enabled = c.action != null } };
    _ = menu.openMenu(w, items[0..hidden.len], .{ .node = node }, .{ .on_action = p.on_action, .keyboard = w.focus_visible, .test_id = "crumb_menu" }) catch {};
}

fn run(w: *Window, p: BreadcrumbsProps, action: actions.ActionId, arg: ?[]const u8) void {
    if (p.on_action) |cb| return cb.f(cb.ctx, action, arg);
    _ = w.dispatchAction(action, arg);
}

const testing = std.testing;

test "breadcrumbs: middle segments collapse, first and last two stay" {
    const widths = [_]f32{ 10, 10, 10, 10, 10 };
    try testing.expectEqual(@as(usize, 1), collapse(&widths, 50, 5));
    // 55 needed with "…": drop segment 1 → 45.
    try testing.expectEqual(@as(usize, 2), collapse(&widths, 45, 5));
    try testing.expectEqual(@as(usize, 3), collapse(&widths, 35, 5));
    // Never more than the middle.
    try testing.expectEqual(@as(usize, 3), collapse(&widths, 0, 5));
    try testing.expectEqual(@as(usize, 1), collapse(widths[0..3], 0, 5));
}
