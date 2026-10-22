//! The menubar (E04.F05.S03.T02), after the WAI-ARIA APG Menubar pattern.
//!
//! - Alt+letter opens the entry with that mnemonic, first item focused.
//! - Alt pressed and released alone moves focus to the first entry (and
//!   back); holding Alt underlines the mnemonics.
//! - On a focused entry: Left/Right move, Down/Enter/Space open, Escape
//!   leaves the bar.
//! - In an open menu, Left/Right past its edge open the neighbouring menu.
//! - With a menu open, hovering another entry switches to it.
//!
//! The bar goes in the custom title bar (E04.F07.S02.T01); its entries must
//! be excluded from the title bar's drag region there.

const std = @import("std");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const window_mod = @import("../core/window.zig");
const style_mod = @import("../layout/style.zig");
const measure_mod = @import("../layout/measure.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const event_mod = @import("../input/event.zig");
const keys = @import("zg_platform").keys;
const theme_mod = @import("../theme/theme.zig");
const geom = @import("../core/geom.zig");
const menu = @import("menu.zig");

const NodeId = ids.NodeId;
const Ui = ui_mod.Ui;
const Window = window_mod.Window;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;

/// One top-level menu.
pub const MenuBarEntry = struct {
    /// With an `&` mnemonic ("&File").
    label: []const u8,
    items: []const menu.MenuItem,
};

/// Menubar options.
pub const MenuBarOptions = struct {
    /// Receives actions instead of the window's `ActionHandler`.
    on_action: ?menu.ActionCb = null,
    test_id: []const u8 = "menubar",
};

/// Most entries a bar shows.
pub const max_entries = 16;

/// Shows `entries` as a menubar. The entries must stay valid while the bar
/// is mounted (menus copy their items when they open).
pub fn menubar(ui: *Ui, entries: []const MenuBarEntry, opts: MenuBarOptions) void {
    ui.open(.{ .style = .{ .align_items = .center }, .role = .menubar, .test_id = opts.test_id });
    defer ui.close();
    _ = ui.leaf(BarSlot, .{});
    const slot = ui.lastNode();
    const st = ui.lastState(BarSlot) orelse return;
    const w = ui.window();
    st.win = w;
    st.entries = entries[0..@min(entries.len, max_entries)];
    st.opts = opts;
    st.view = ui.currentView();
    if (st.open_index != null and !st.handle.isOpen(w)) st.open_index = null;
    for (st.entries, 0..) |e, i| {
        ui.id(i);
        const buf = ui.arena().alloc(u8, e.label.len) catch return;
        const mn = menu.parseMnemonic(buf, e.label);
        _ = ui.leaf(BarItem, .{
            .bar = st,
            .index = @intCast(i),
            .label = mn.text,
            .mn_pos = mn.pos orelse std.math.maxInt(u16),
            .open = st.open_index != null and st.open_index.? == i,
            .focused = st.focus_index != null and st.focus_index.? == i,
            .mnemonics = st.mnemonics,
        });
        st.items[i] = ui.lastNode();
        st.keys[i] = mn.key;
    }
    w.key_filter = .{ .node = slot, .f = .{ .ptr = st, .filter = BarState.filter } };
}

const BarState = struct {
    win: ?*Window = null,
    entries: []const MenuBarEntry = &.{},
    opts: MenuBarOptions = .{},
    view: u16 = 0,
    items: [max_entries]NodeId = @splat(.none),
    keys: [max_entries]u8 = @splat(0),
    /// The entry whose menu is open.
    open_index: ?u8 = null,
    handle: menu.MenuHandle = .{},
    /// The entry with keyboard focus (after Alt).
    focus_index: ?u8 = null,
    prev_focus: NodeId = .none,
    /// Alt is down and no other key came since.
    alt_down: bool = false,
    mnemonics: bool = false,
    /// The press that closed the last menu, and its entry: that press must
    /// not reopen it.
    closed_press: u32 = 0,
    just_closed: ?u8 = null,

    fn dirty(st: *BarState) void {
        const w = st.win orelse return;
        if (st.view != 0) w.markViewDirty(st.view);
    }

    fn setMnemonics(st: *BarState, on: bool) void {
        if (st.mnemonics == on) return;
        st.mnemonics = on;
        st.dirty();
    }

    /// Opens entry `i`'s menu (replacing any open one).
    fn openAt(st: *BarState, i: u8, keyboard: bool) void {
        const w = st.win orelse return;
        if (i >= st.entries.len) return;
        st.handle.close(w);
        st.handle = menu.openMenu(w, st.entries[i].items, .{ .node = st.items[i] }, .{
            .on_action = st.opts.on_action,
            .on_close = .{ .ctx = st, .f = onMenuClosed },
            .keyboard = keyboard,
            .mnemonics = keyboard,
            .bar = .{ .ctx = st, .move = barMove },
            .consume_outside_click = false,
            .placement = .{ .gap = 0 },
        }) catch return;
        st.open_index = i;
        st.dirty();
    }

    fn onMenuClosed(ctx: ?*anyopaque) void {
        const st: *BarState = @ptrCast(@alignCast(ctx.?));
        st.just_closed = st.open_index;
        if (st.win) |w| st.closed_press = w.press_serial;
        st.open_index = null;
        if (st.focus_index == null) st.mnemonics = false;
        st.dirty();
    }

    /// Left/Right past the edge of an open menu.
    fn barMove(ctx: *anyopaque, dir: i8) void {
        const st: *BarState = @ptrCast(@alignCast(ctx));
        const cur = st.open_index orelse return;
        const n: i32 = @intCast(st.entries.len);
        const next: u8 = @intCast(@mod(@as(i32, cur) + dir, n));
        if (st.focus_index != null) st.focus_index = next;
        st.openAt(next, true);
    }

    fn toggle(st: *BarState, i: u8) void {
        const w = st.win orelse return;
        if (st.just_closed == i and st.closed_press == w.press_serial) {
            st.just_closed = null;
            return;
        }
        st.just_closed = null;
        if (st.open_index == i) {
            st.handle.close(w);
        } else st.openAt(i, false);
    }

    fn enterBar(st: *BarState, i: u8) void {
        const w = st.win orelse return;
        if (st.entries.len == 0) return;
        if (st.focus_index == null) st.prev_focus = w.focus;
        st.focus_index = i;
        st.mnemonics = true;
        w.setFocus(st.items[i], true);
        st.dirty();
    }

    fn exitBar(st: *BarState) void {
        const w = st.win orelse return;
        st.handle.close(w);
        st.focus_index = null;
        st.mnemonics = false;
        const back = if (!st.prev_focus.isNone() and w.store.valid(st.prev_focus)) st.prev_focus else NodeId.none;
        w.setFocus(back, w.focus_visible);
        st.dirty();
    }

    fn byMnemonic(st: *const BarState, c: u8) ?u8 {
        for (st.keys[0..st.entries.len], 0..) |k, i| if (k != 0 and k == c) return @intCast(i);
        return null;
    }

    /// Sees every key first: Alt alone and Alt+letter.
    fn filter(ptr: *anyopaque, k: event_mod.KeyPress) bool {
        const st: *BarState = @ptrCast(@alignCast(ptr));
        if (k.key == .alt_left or k.key == .alt_right) {
            if (k.action == .press) {
                if (k.mods.ctrl or k.mods.shift or k.mods.super) return false;
                st.alt_down = true;
                st.setMnemonics(true);
                return false;
            }
            if (k.action == .release) {
                const alone = st.alt_down;
                st.alt_down = false;
                if (alone) {
                    if (st.focus_index != null or st.open_index != null) st.exitBar() else st.enterBar(0);
                    return true;
                }
                st.setMnemonics(st.focus_index != null or (st.open_index != null and st.handle.isOpen(st.win.?)));
            }
            return false;
        }
        if (k.action != .press) return false;
        st.alt_down = false;
        if (k.mods.alt and !k.mods.ctrl and !k.mods.super) {
            const c = letterOf(k.key) orelse return false;
            const i = st.byMnemonic(c) orelse return false;
            st.openAt(i, true);
            return true;
        }
        return false;
    }

    /// Keys on a focused entry.
    fn onItemKey(st: *BarState, i: u8, k: event_mod.KeyPress) bool {
        if (k.action == .release or k.mods.ctrl or k.mods.alt) return false;
        const n: i32 = @intCast(st.entries.len);
        switch (k.key) {
            .arrow_right, .arrow_left => {
                const d: i32 = if (k.key == .arrow_right) 1 else -1;
                st.enterBar(@intCast(@mod(@as(i32, i) + d, n)));
            },
            .arrow_down, .enter, .numpad_enter, .space => st.openAt(i, true),
            .escape, .tab => {
                st.exitBar();
                return k.key == .escape;
            },
            else => {
                if (k.codepoint == 0 or k.codepoint > 0x7f) return false;
                const j = st.byMnemonic(std.ascii.toLower(@intCast(k.codepoint))) orelse return false;
                st.openAt(j, true);
            },
        }
        return true;
    }
};

fn letterOf(key: keys.Key) ?u8 {
    const v = @intFromEnum(key);
    if (v >= @intFromEnum(keys.Key.key_a) and v <= @intFromEnum(keys.Key.key_z)) return @intCast('a' + (v - @intFromEnum(keys.Key.key_a)));
    if (v >= @intFromEnum(keys.Key.digit_1) and v <= @intFromEnum(keys.Key.digit_9)) return @intCast('1' + (v - @intFromEnum(keys.Key.digit_1)));
    if (key == .digit_0) return '0';
    return null;
}

/// Holds the bar's state; closes its menu when the bar unmounts.
const BarSlot = struct {
    pub const name = "menubar_state";
    pub const Props = struct {};
    pub const State = BarState;

    pub fn style(_: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return .{ .display = .none };
    }

    pub fn deinitState(st: *BarState) void {
        const w = st.win orelse return;
        if (st.handle.isOpen(w)) {
            if (st.handle.menu) |m| m.opts.on_close = null;
            if (st.handle.menu) |m| m.opts.bar = null;
            w.closeOverlay(st.handle.id);
        }
    }
};

/// One top-level entry.
const BarItem = struct {
    pub const name = "menubar_item";

    pub const Props = struct {
        bar: *BarState,
        index: u8,
        label: []const u8,
        mn_pos: u16 = std.math.maxInt(u16),
        open: bool = false,
        focused: bool = false,
        mnemonics: bool = false,
    };

    fn body(th: *const theme_mod.Theme) text_mod.TextStyle {
        return .{ .size = th.dim(.font_size) };
    }

    pub fn style(_: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .padding = .xy(th.dim(.space_sm) + 2, 0), .min_h = th.dim(.control_h), .shrink = 0 };
    }

    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) geom.Size {
        const st = body(mc.theme);
        return .{ .w = mc.text.width(st, props.label), .h = mc.text.metrics(st).line_h };
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const st = body(pc.theme);
        const m = pc.text_sys.metrics(st);
        if (props.open or props.focused or pc.state.hovered) pc.fill(r, if (props.open) .selection_bg else .hover_bg, pc.dim(.radius_sm));
        const fg = pc.color(.fg);
        const x = r.x + pc.dim(.space_sm) + 2;
        const baseline = r.y + (r.h - (m.ascent + m.descent)) / 2 + m.ascent;
        pc.textLine(props.label, st, fg, .{ .x = x, .y = baseline });
        if (props.mnemonics and props.mn_pos < props.label.len) {
            const p = props.mn_pos;
            const ux = x + pc.text_sys.width(st, props.label[0..p]);
            const uw = pc.text_sys.width(st, props.label[p .. p + 1]);
            pc.rect(.{ .x = ux, .y = baseline + 1, .w = uw, .h = 1 }, fg, .all(0));
        }
        if (props.focused) pc.border(r, pc.dim(.focus_ring_w), pc.color(.focus_ring), pc.dim(.radius_sm));
    }

    pub fn event(_: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        const st = props.bar;
        switch (ev.*) {
            .pointer_down => |p| if (p.button == .left) {
                st.toggle(props.index);
                return true;
            },
            .pointer_move => if (st.open_index) |o| if (o != props.index) st.openAt(props.index, false),
            .key => |k| return st.onItemKey(props.index, k),
            else => {},
        }
        return false;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .menuitem, .name = props.label };
    }
};

test {
    std.testing.refAllDecls(@This());
}
