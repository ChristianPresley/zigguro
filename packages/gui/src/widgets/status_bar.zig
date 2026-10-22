//! The status bar (E04.F05.S04.T02): prioritised items on the left and
//! right, overflow into a "…" menu, the pending-chord hint and the
//! notification bell.
//!
//! When the items do not fit, the lowest priority goes first (ties: the
//! leftmost on the left side, the rightmost on the right side) into a "…"
//! menu at the end of its side. Priority ≥ 1000 is pinned. Items with an
//! action are buttons that run it through the window's `ActionHandler`.
//! The bell shows the unread count and opens the notification center.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const geom = @import("../core/geom.zig");
const actions = @import("../input/actions.zig");
const measure_mod = @import("../layout/measure.zig");
const style_mod = @import("../layout/style.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const theme_mod = @import("../theme/theme.zig");
const tokens = @import("../theme/tokens.zig");
const menu = @import("menu.zig");
const toast = @import("toast.zig");
const Response = @import("../core/response.zig").Response;

const Ui = ui_mod.Ui;
const Size = geom.Size;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;
const Theme = theme_mod.Theme;

/// Which end of the bar an item sits at.
pub const Side = enum(u8) { left, right };

/// How an item is drawn.
pub const Tone = enum(u8) { normal, warning, error_, prominent };

/// One status bar entry.
pub const StatusItem = struct {
    id: []const u8,
    side: Side = .left,
    /// Higher stays longer; ≥ `pinned_priority` never overflows.
    priority: i32 = 0,
    text: []const u8,
    tooltip: ?[]const u8 = null,
    action: ?actions.ActionId = null,
    arg: ?[]const u8 = null,
    tone: Tone = .normal,
    /// Null: none; NaN: indeterminate; else 0..1 (agent activity).
    progress: ?f32 = null,
};

/// Items at or above this priority never overflow.
pub const pinned_priority: i32 = 1000;
/// The most items a bar lays out.
pub const max_items = 64;

/// Status bar options.
pub const StatusBarProps = struct {
    /// The pending chord ("(Ctrl+K) was pressed. Waiting for second key…"),
    /// shown as a pinned prominent item.
    chord: ?[]const u8 = null,
    /// Show the notification bell with the unread count.
    bell: bool = true,
    /// `statusBar.height`.
    height: f32 = 22,
    /// The width to fit into; null uses the window's.
    width: ?f32 = null,
};

/// The status-bar item widget.
pub const Item = struct {
    /// Shown in snapshots.
    pub const name = "status_item";
    /// Items take focus.
    pub const focusable = true;

    /// Item props.
    pub const Props = struct {
        text: []const u8,
        tone: Tone = .normal,
        progress: ?f32 = null,
        /// Accessible name; defaults to `text`.
        label: []const u8 = "",
        /// Draws the text as a badge (the unread count).
        badge: bool = false,
    };

    /// The item's text size plus padding.
    pub fn style(_: *const Props, _: *const Theme) style_mod.Style {
        return .{ .padding = .xy(item_pad, 0), .shrink = 0, .align_self = .stretch };
    }

    /// The text size.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = textStyle(mc.theme);
        return .{ .w = mc.text.width(st, props.text), .h = mc.text.metrics(st).line_h };
    }

    /// Tone background, text, progress and focus ring.
    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const s = pc.state;
        const bg: ?tokens.Token = switch (props.tone) {
            .prominent => .accent,
            .error_ => .danger,
            else => if (s.pressed) .button_bg_pressed else if (s.hovered) .hover_bg else null,
        };
        if (bg) |t| pc.fill(r, t, 0);
        const fg: tokens.Token = switch (props.tone) {
            .prominent, .error_ => .fg_on_accent,
            .warning => .warning,
            .normal => .fg_muted,
        };
        const st = textStyle(pc.theme);
        const lh = pc.text_sys.metrics(st).line_h;
        const tr = r.inset(.xy(item_pad, (r.h - lh) / 2));
        if (props.badge) {
            pc.fill(tr.inset(.xy(-4, 0)), .badge_bg, lh / 2);
            pc.textBox(props.text, st, pc.color(.badge_fg), tr, false, .center);
        } else pc.textBox(props.text, st, pc.color(fg), tr, false, .start);
        if (props.progress) |p| {
            const frac = if (std.math.isNan(p)) 0.33 else std.math.clamp(p, 0, 1);
            pc.fill(.{ .x = r.x, .y = r.bottom() - 2, .w = r.w * frac, .h = 2 }, .accent, 0);
        }
        pc.focusRing(r, 0);
    }

    /// A button named by its label or text.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .button, .name = if (props.label.len > 0) props.label else props.text };
    }
};

const item_pad: f32 = 8;

fn textStyle(th: *const Theme) text_mod.TextStyle {
    return .{ .font = .ui, .size = th.dim(.font_size_sm) };
}

/// Which items fit in `avail` pixels given each one's width; the rest
/// overflow. `extra` is the width taken by fixed content (bell, chord),
/// `more_w` the width of a "…" button.
pub fn fit(items: []const StatusItem, widths: []const f32, avail: f32, extra: f32, more_w: f32, shown: []bool) void {
    var total = extra;
    for (widths, shown) |w, *s| {
        total += w;
        s.* = true;
    }
    var more = [2]bool{ false, false };
    while (true) {
        const need = total + (if (more[0]) more_w else 0) + (if (more[1]) more_w else 0);
        if (need <= avail) return;
        // The lowest priority shown, not pinned; ties per side.
        var pick: ?usize = null;
        for (items, 0..) |it, i| {
            if (!shown[i] or it.priority >= pinned_priority) continue;
            if (pick) |p| {
                const cur = items[p];
                if (it.priority < cur.priority or (it.priority == cur.priority and it.side == .right and cur.side == .right)) pick = i;
            } else pick = i;
        }
        const i = pick orelse return;
        shown[i] = false;
        total -= widths[i];
        more[@intFromEnum(items[i].side)] = true;
    }
}

/// Adds the status bar (see the module doc).
pub fn statusBar(ui: *Ui, items: []const StatusItem, p: StatusBarProps) void {
    const w = ui.window();
    const th = ui.theme();
    const st = textStyle(th);
    const n = @min(items.len, max_items);
    var widths: [max_items]f32 = undefined;
    for (items[0..n], 0..) |it, i| widths[i] = w.text_sys.width(st, it.text) + 2 * item_pad;
    const more_w = w.text_sys.width(st, "\u{2026}") + 2 * item_pad;
    var extra: f32 = 0;
    var bell_buf: [16]u8 = undefined;
    const unread = w.app.notifications.unread();
    const bell_text = if (unread > 0) std.fmt.bufPrint(&bell_buf, "{d}", .{unread}) catch "!" else "\u{2022}";
    if (p.bell) extra += w.text_sys.width(st, bell_text) + 2 * item_pad + 8;
    if (p.chord) |c| extra += w.text_sys.width(st, c) + 2 * item_pad;
    var shown: [max_items]bool = undefined;
    fit(items[0..n], widths[0..n], p.width orelse w.size.w, extra, more_w, shown[0..n]);

    ui.open(.{ .style = .{ .dir = .row, .h = .{ .px = p.height }, .shrink = 0, .bg = .{ .token = .bg_elevated }, .align_items = .stretch }, .role = .status, .label = "Status bar", .test_id = "status_bar" });
    defer ui.close();
    side(ui, items[0..n], shown[0..n], .left);
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.close();
    if (p.chord) |c| _ = ui.leaf(Item, .{ .text = c, .tone = .prominent });
    side(ui, items[0..n], shown[0..n], .right);
    if (p.bell) {
        const r = ui.leaf(Item, .{ .text = bell_text, .badge = unread > 0, .label = "Notifications" });
        if (r.clicked) _ = toast.openCenter(w, ui.lastNode()) catch {};
    }
}

fn side(ui: *Ui, items: []const StatusItem, shown: []const bool, s: Side) void {
    const w = ui.window();
    var hidden: [max_items]menu.MenuItem = undefined;
    var nh: usize = 0;
    for (items, shown) |it, vis| {
        if (it.side != s) continue;
        if (!vis) {
            hidden[nh] = .{ .action = .{ .label = it.text, .action = it.action orelse "", .arg = it.arg, .enabled = it.action != null } };
            nh += 1;
            continue;
        }
        const r: Response = ui.leaf(Item, .{ .text = it.text, .tone = it.tone, .progress = it.progress });
        if (r.clicked) if (it.action) |a| {
            _ = w.dispatchAction(a, it.arg);
        };
    }
    if (nh == 0) return;
    const r = ui.leaf(Item, .{ .text = "\u{2026}", .label = if (s == .left) "More status items (left)" else "More status items" });
    if (r.clicked) _ = menu.openMenu(w, hidden[0..nh], .{ .node = ui.lastNode() }, .{}) catch {};
}

const testing = std.testing;

test "status: overflow by priority, pinned never dropped" {
    const items = [_]StatusItem{
        .{ .id = "a", .text = "a", .priority = 5 },
        .{ .id = "b", .text = "b", .priority = 1 },
        .{ .id = "c", .text = "c", .priority = 1000 },
        .{ .id = "d", .text = "d", .side = .right, .priority = 1 },
        .{ .id = "e", .text = "e", .side = .right, .priority = 1 },
    };
    const widths = [_]f32{ 10, 10, 10, 10, 10 };
    var shown: [5]bool = undefined;
    fit(&items, &widths, 100, 0, 5, &shown);
    try testing.expectEqualSlices(bool, &.{ true, true, true, true, true }, &shown);
    // 50 + "…" needs dropping: b (leftmost lowest) goes first.
    fit(&items, &widths, 45, 0, 5, &shown);
    try testing.expectEqualSlices(bool, &.{ true, false, true, true, true }, &shown);
    // Then the rightmost of the right-side ties.
    fit(&items, &widths, 40, 0, 5, &shown);
    try testing.expectEqualSlices(bool, &.{ true, false, true, true, false }, &shown);
    // Nothing fits: only the pinned item stays.
    fit(&items, &widths, 0, 0, 5, &shown);
    try testing.expectEqualSlices(bool, &.{ false, false, true, false, false }, &shown);
}
