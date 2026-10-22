//! Menus (E04.F05.S03.T02): context menus, dropdowns and submenus,
//! following the WAI-ARIA APG Menu pattern.
//!
//! A menu is data (`MenuItem`s), copied when it opens. Each level is an
//! overlay at the popover layer; the levels of one menu share a dismiss
//! group, so a press anywhere outside all of them closes the menu.
//!
//! Keyboard: Up/Down move with wrap, Home/End jump, Enter activates, Space
//! toggles a checkbox item without closing, Right opens a submenu (Left
//! and Right past the edge move along the menubar), Left and Escape close
//! a level, Tab closes everything. Letters jump by type-ahead, or activate
//! an item's mnemonic ("&Open") while mnemonics show.
//!
//! Pointer: hovering an item focuses it and opens its submenu; menu-aim
//! (`menu_aim.zig`) keeps an open submenu while the pointer heads for it.
//!
//! Not yet: icons (no icon set until E04.F08), the 60 ms close fade
//! (E04.F08.S03.T01).

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const window_mod = @import("../core/window.zig");
const style_mod = @import("../layout/style.zig");
const measure_mod = @import("../layout/measure.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const event_mod = @import("../input/event.zig");
const actions = @import("../input/actions.zig");
const theme_mod = @import("../theme/theme.zig");
const controls = @import("controls.zig");
const overlay = @import("overlay.zig");
const menu_aim = @import("menu_aim.zig");

const Vec2 = geom.Vec2;
const Rect = geom.Rect;
const Size = geom.Size;
const NodeId = ids.NodeId;
const Ui = ui_mod.Ui;
const Window = window_mod.Window;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;

/// A command id (see `input/actions.zig`).
pub const ActionId = actions.ActionId;

/// One entry of a menu.
pub const MenuItem = union(enum) {
    action: Action,
    submenu: Submenu,
    separator,
    /// A non-interactive group heading.
    header: []const u8,

    /// A command. `&` in the label marks the mnemonic ("&&" is a literal
    /// ampersand).
    pub const Action = struct {
        label: []const u8,
        action: ActionId,
        arg: ?[]const u8 = null,
        /// Shown right-aligned; null asks the window's `ActionHandler`.
        shortcut: ?[]const u8 = null,
        enabled: bool = true,
        /// Non-null makes a checkbox item (or a radio item with
        /// `radio_group`).
        checked: ?bool = null,
        radio_group: ?u16 = null,
    };

    /// A nested menu.
    pub const Submenu = struct {
        label: []const u8,
        items: []const MenuItem,
        enabled: bool = true,
    };
};

/// Where a menu opens.
pub const MenuAnchor = union(enum) {
    /// At the pointer (context menus): below and to the right, flipping
    /// up and left to stay visible.
    pointer: Vec2,
    /// Below a node (dropdowns, menubar entries).
    node: NodeId,
    /// Below a rectangle in window coordinates.
    rect: Rect,
};

/// Receives the chosen action instead of the window's `ActionHandler`.
pub const ActionCb = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, action: ActionId, arg: ?[]const u8) void,
};

/// Called once when the whole menu closes.
pub const CloseCb = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque) void,
};

/// Lets Left/Right at a menu's edge move along a menubar.
pub const BarLink = struct {
    ctx: *anyopaque,
    move: *const fn (ctx: *anyopaque, dir: i8) void,
};

/// How a menu opens and reports.
pub const MenuOptions = struct {
    on_action: ?ActionCb = null,
    on_close: ?CloseCb = null,
    /// Opened from the keyboard: focus the first item.
    keyboard: bool = false,
    /// Underline mnemonics and let their letters activate items.
    mnemonics: bool = false,
    /// Placement against a node or rect anchor.
    placement: overlay.Placement = .{},
    bar: ?BarLink = null,
    /// Swallow the press that closes the menu.
    consume_outside_click: bool = true,
    test_id: []const u8 = "menu",
};

/// An open menu; stale (and harmless) once it closes.
pub const MenuHandle = struct {
    id: overlay.OverlayId = .none,
    menu: ?*Menu = null,

    /// True while the menu is open.
    pub fn isOpen(h: MenuHandle, win: *const Window) bool {
        return h.id != .none and win.isOverlayOpen(h.id);
    }

    /// Closes the menu and its submenus.
    pub fn close(h: MenuHandle, win: *Window) void {
        if (h.isOpen(win)) win.closeOverlay(h.id);
    }
};

/// A label with its mnemonic marker removed.
pub const Mnemonic = struct {
    text: []const u8,
    /// Byte offset of the mnemonic character in `text`, or null.
    pos: ?u16 = null,
    /// The mnemonic as a lowercase ASCII letter or digit, or 0.
    key: u8 = 0,
};

/// Strips the `&` markers from `label` into `buf` (at least as long).
pub fn parseMnemonic(buf: []u8, label: []const u8) Mnemonic {
    var out: Mnemonic = .{ .text = undefined };
    var n: usize = 0;
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        const c = label[i];
        if (c == '&' and i + 1 < label.len) {
            i += 1;
            if (label[i] != '&' and out.pos == null) {
                out.pos = @intCast(n);
                out.key = std.ascii.toLower(label[i]);
                if (!std.ascii.isAlphanumeric(out.key)) out.key = 0;
            }
        }
        buf[n] = label[i];
        n += 1;
    }
    out.text = buf[0..n];
    return out;
}

/// Opens `items` at `at`. The items and strings are copied.
pub fn openMenu(win: *Window, items: []const MenuItem, at: MenuAnchor, opts: MenuOptions) !MenuHandle {
    const gpa = win.gpa;
    const m = try gpa.create(Menu);
    m.* = .{ .gpa = gpa, .win = win, .arena = .init(gpa), .rows = &.{}, .opts = opts, .mnemonics = opts.mnemonics };
    m.group = @truncate((@intFromPtr(m) >> 4) | 1);
    errdefer {
        m.arena.deinit();
        gpa.destroy(m);
    }
    m.rows = try copyRows(m.arena.allocator(), items, win.action_handler);
    const anchor: overlay.Anchor, const placement: overlay.Placement = switch (at) {
        .pointer => |p| .{ .{ .rect = .{ .x = p.x, .y = p.y, .w = 0, .h = 0 } }, .{ .gap = 0 } },
        .node => |n| .{ .{ .node = n }, opts.placement },
        .rect => |r| .{ .{ .rect = r }, opts.placement },
    };
    try m.openLevel(0, m.rows, anchor, placement, opts.keyboard, 0);
    return .{ .id = m.levels[0].id, .menu = m };
}

/// Gives the current container a context menu: right-click (on release),
/// Shift+F10 or the Menu key opens `items` at the pointer or below the
/// focused node.
pub fn contextMenu(ui: *Ui, items: []const MenuItem, opts: MenuOptions) void {
    const n = ui.current();
    if (n.isNone()) return;
    const w = ui.window();
    const fl = w.store.flags(n);
    fl.context_menu = true;
    fl.hit_testable = true;
    if (!ui.response().context_menu) return;
    var o = opts;
    o.keyboard = w.context_keyboard;
    _ = openMenu(w, items, .{ .pointer = w.context_at }, o) catch {};
}

/// Remembers the menu a `menuButton` opened.
const MenuSlot = struct {
    pub const name = "menu_slot";
    pub const Props = struct {};
    pub const State = struct { handle: MenuHandle = .{} };

    pub fn style(_: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return .{ .display = .none };
    }
};

/// A button that drops `items` down below itself.
pub fn menuButton(ui: *Ui, label: []const u8, items: []const MenuItem, opts: MenuOptions) void {
    ui.open(.{ .style = .{} });
    const anchor = ui.current();
    const r = controls.button(ui, .{ .label = label });
    _ = ui.leaf(MenuSlot, .{});
    const st = ui.lastState(MenuSlot);
    ui.close();
    const s = st orelse return;
    const w = ui.window();
    if (!r.clicked) return;
    if (s.handle.isOpen(w)) {
        s.handle.close(w);
        return;
    }
    var o = opts;
    o.keyboard = w.focus_visible;
    s.handle = openMenu(w, items, .{ .node = anchor }, o) catch .{};
}

// -- implementation ----------------------------------------------------------

const max_depth = 8;
const no_mnemonic = std.math.maxInt(u16);
/// Type-ahead forgets earlier letters after this long.
const typeahead_ms: u64 = 1000;

/// A copied item.
const Row = struct {
    kind: enum(u8) { action, submenu, separator, header },
    label: []const u8 = "",
    mn_pos: u16 = no_mnemonic,
    mn: u8 = 0,
    shortcut: []const u8 = "",
    action: []const u8 = "",
    arg: ?[]const u8 = null,
    enabled: bool = true,
    checked: ?bool = null,
    radio_group: ?u16 = null,
    sub: []Row = &.{},

    fn selectable(r: *const Row) bool {
        return (r.kind == .action or r.kind == .submenu) and r.enabled;
    }
};

fn copyRows(a: std.mem.Allocator, items: []const MenuItem, handler: ?actions.ActionHandler) ![]Row {
    const rows = try a.alloc(Row, items.len);
    for (items, rows) |it, *r| {
        r.* = switch (it) {
            .separator => .{ .kind = .separator },
            .header => |h| .{ .kind = .header, .label = try a.dupe(u8, h) },
            .action => |ac| blk: {
                const mn = parseMnemonic(try a.alloc(u8, ac.label.len), ac.label);
                const sc = ac.shortcut orelse if (handler) |h| h.labelFor(ac.action) orelse "" else "";
                break :blk .{
                    .kind = .action,
                    .label = mn.text,
                    .mn_pos = mn.pos orelse no_mnemonic,
                    .mn = mn.key,
                    .shortcut = try a.dupe(u8, sc),
                    .action = try a.dupe(u8, ac.action),
                    .arg = if (ac.arg) |x| try a.dupe(u8, x) else null,
                    .enabled = ac.enabled,
                    .checked = ac.checked,
                    .radio_group = ac.radio_group,
                };
            },
            .submenu => |sm| blk: {
                const mn = parseMnemonic(try a.alloc(u8, sm.label.len), sm.label);
                break :blk .{
                    .kind = .submenu,
                    .label = mn.text,
                    .mn_pos = mn.pos orelse no_mnemonic,
                    .mn = mn.key,
                    .enabled = sm.enabled,
                    .sub = try copyRows(a, sm.items, handler),
                };
            },
        };
    }
    return rows;
}

/// One open level of a menu (its overlay's view).
const Level = struct {
    menu: *Menu,
    depth: u8,
    rows: []Row,
    id: overlay.OverlayId = .none,
    active: ?u16 = null,
    /// The item of the level above that opened this one.
    parent: u16 = 0,
    /// Row nodes by item index (`.none` for separators and headers).
    nodes: std.ArrayList(NodeId) = .empty,
    /// The scrolling column.
    scroll: NodeId = .none,

    pub fn build(self: *Level, ui: *Ui) void {
        const m = self.menu;
        const th = ui.theme();
        self.nodes.clearRetainingCapacity();
        ui.open(.{ .style = .{ .dir = .column, .scroll_y = true, .min_w = 180, .min_h = 0, .shrink = 1 } });
        self.scroll = ui.current();
        const expanded: ?u16 = if (m.open_levels > self.depth + 1) m.levels[self.depth + 1].parent else null;
        for (self.rows, 0..) |*r, i| {
            ui.id(i);
            var node: NodeId = .none;
            switch (r.kind) {
                .separator => controls.separator(ui, false),
                .header => ui.text(r.label, .{ .color = .fg_muted, .style = .{ .size = th.dim(.font_size_sm), .weight = 600 }, .theme_size = false, .wrap = false }),
                .action, .submenu => {
                    _ = ui.leaf(MenuRow, .{
                        .menu = m,
                        .depth = self.depth,
                        .index = @intCast(i),
                        .label = r.label,
                        .mn_pos = r.mn_pos,
                        .shortcut = r.shortcut,
                        .check = if (r.checked) |c| (if (r.radio_group != null) (if (c) Check.radio_on else Check.radio_off) else (if (c) Check.on else Check.off)) else .none,
                        .submenu = r.kind == .submenu,
                        .enabled = r.enabled,
                        .active = self.active != null and self.active.? == i,
                        .expanded = expanded != null and expanded.? == i,
                        .mnemonics = m.mnemonics,
                    });
                    node = ui.lastNode();
                },
            }
            self.nodes.append(m.gpa, node) catch {};
        }
        ui.close();
    }

    fn onClose(ctx: *anyopaque, _: overlay.OverlayId) void {
        const lv: *Level = @ptrCast(@alignCast(ctx));
        const m = lv.menu;
        const w = m.win;
        lv.id = .none;
        // Deeper levels go first.
        if (m.open_levels > lv.depth + 1) w.closeOverlay(m.levels[lv.depth + 1].id);
        m.open_levels = lv.depth;
        m.aim.reset();
        m.cancelPending();
        if (lv.depth > 0) {
            const up = &m.levels[lv.depth - 1];
            if (up.id == .none) return;
            // Focus inside the closed level returns to its parent item.
            for (lv.nodes.items) |n| {
                if (!n.isNone() and w.focus.eql(n)) {
                    m.focusRow(up, lv.parent, w.focus_visible);
                    break;
                }
            }
            m.markDirty(up);
            return;
        }
        m.closed = true;
        if (m.opts.on_close) |cb| cb.f(cb.ctx);
        // Rows may still be in the hit index until the next frame.
        w.afterNextFrame(.{ .ctx = m, .f = Menu.free });
    }
};

const Menu = struct {
    gpa: std.mem.Allocator,
    win: *Window,
    arena: std.heap.ArenaAllocator,
    rows: []Row,
    opts: MenuOptions,
    levels: [max_depth]Level = undefined,
    open_levels: u8 = 0,
    /// Levels whose node lists were allocated.
    used_levels: u8 = 0,
    group: u32 = 1,
    mnemonics: bool = false,
    closed: bool = false,
    aim: menu_aim.MenuAim = .{},
    aim_timer: Window.TimerId = .none,
    pending: ?struct { depth: u8, index: u16 } = null,
    typeahead: [32]u8 = undefined,
    typeahead_len: u8 = 0,
    typeahead_at: u64 = 0,

    fn free(ctx: *anyopaque, _: *Window) void {
        const m: *Menu = @ptrCast(@alignCast(ctx));
        for (m.levels[0..m.used_levels]) |*lv| lv.nodes.deinit(m.gpa);
        m.arena.deinit();
        m.gpa.destroy(m);
    }

    fn openLevel(m: *Menu, depth: u8, rows: []Row, anchor: overlay.Anchor, placement: overlay.Placement, focus_first: bool, parent: u16) !void {
        const lv = &m.levels[depth];
        // A level reopened at this depth keeps its node list allocation.
        const nodes = if (depth < m.used_levels) lv.nodes else std.ArrayList(NodeId).empty;
        lv.* = .{ .menu = m, .depth = depth, .rows = rows, .parent = parent, .nodes = nodes };
        m.used_levels = @max(m.used_levels, depth + 1);
        lv.id = try m.win.openOverlay(.of(lv), .{
            .layer = .popover,
            .anchor = anchor,
            .placement = placement,
            .take_focus = focus_first,
            .restore_focus = depth == 0,
            .role = .menu,
            .test_id = m.opts.test_id,
            .group = m.group,
            .consume_outside_click = m.opts.consume_outside_click,
            .on_close = .{ .ctx = lv, .f = Level.onClose },
        });
        m.open_levels = depth + 1;
    }

    fn markDirty(m: *Menu, lv: *Level) void {
        if (m.win.viewIdOf(.of(lv))) |vid| m.win.markViewDirty(vid);
    }

    fn panelRect(m: *Menu, lv: *const Level) ?Rect {
        const i = m.win.overlays.indexOf(lv.id) orelse return null;
        const p = m.win.overlays.items.items[i].panel;
        if (p.isNone() or !m.win.store.valid(p)) return null;
        return m.win.layoutRect(p);
    }

    fn closeFrom(m: *Menu, depth: u8) void {
        if (m.open_levels > depth) m.win.closeOverlay(m.levels[depth].id);
    }

    fn closeAll(m: *Menu) void {
        if (m.closed or m.open_levels == 0) return;
        // Innermost first, so focus walks back out and level 0 restores it.
        m.closeFrom(1);
        m.win.closeOverlay(m.levels[0].id);
    }

    fn cancelPending(m: *Menu) void {
        m.pending = null;
        if (m.aim_timer != .none) {
            m.win.cancelTimer(m.aim_timer);
            m.aim_timer = .none;
        }
    }

    /// Makes item `i` of `lv` the active one and gives it focus.
    fn focusRow(m: *Menu, lv: *Level, i: u16, visible: bool) void {
        if (lv.active != i) {
            lv.active = i;
            m.markDirty(lv);
        }
        if (i < lv.nodes.items.len) {
            const n = lv.nodes.items[i];
            if (!n.isNone() and m.win.store.valid(n)) {
                m.win.setFocus(n, visible);
                m.scrollIntoView(lv, n);
            }
        }
    }

    fn scrollIntoView(m: *Menu, lv: *Level, n: NodeId) void {
        const w = m.win;
        const sc = lv.scroll;
        if (sc.isNone() or !w.store.valid(sc)) return;
        const r = w.store.relRect(n);
        const vh = w.store.relRect(sc).h;
        const off = w.scrollOffset(sc).y;
        if (r.y < off) {
            _ = w.scrollTo(sc, .{ .x = 0, .y = r.y });
        } else if (r.bottom() > off + vh) {
            _ = w.scrollTo(sc, .{ .x = 0, .y = r.bottom() - vh });
        }
    }

    fn openSub(m: *Menu, lv: *Level, i: u16, focus: bool) void {
        const row = &lv.rows[i];
        if (row.kind != .submenu or !row.enabled) return;
        if (m.open_levels > lv.depth + 1 and m.levels[lv.depth + 1].parent == i) {
            // Already open: just move focus in.
            if (focus) {
                const sub = &m.levels[lv.depth + 1];
                if (firstSelectable(sub.rows)) |f| m.focusRow(sub, f, true);
            }
            return;
        }
        m.closeFrom(lv.depth + 1);
        if (lv.depth + 1 >= max_depth or i >= lv.nodes.items.len) return;
        m.openLevel(lv.depth + 1, row.sub, .{ .node = lv.nodes.items[i] }, .{ .side = .right, .alignment = .start, .gap = 0 }, focus, i) catch return;
        m.aim.reset();
        m.markDirty(lv);
    }

    const How = enum { pointer, enter, space };

    fn activate(m: *Menu, lv: *Level, i: u16, how: How) void {
        const row = &lv.rows[i];
        if (!row.enabled) return;
        switch (row.kind) {
            .submenu => m.openSub(lv, i, how != .pointer),
            .action => {
                if (row.checked) |c| {
                    if (row.radio_group) |g| {
                        for (lv.rows) |*o| {
                            if (o.radio_group == g) o.checked = false;
                        }
                        row.checked = true;
                    } else row.checked = !c;
                    m.markDirty(lv);
                }
                // Space toggles a checkbox in place.
                const keep = how == .space and row.checked != null and row.radio_group == null;
                m.run(row.action, row.arg);
                if (!keep) m.closeAll();
            },
            else => {},
        }
    }

    fn run(m: *Menu, action: []const u8, arg: ?[]const u8) void {
        if (m.opts.on_action) |cb| {
            cb.f(cb.ctx, action, arg);
        } else _ = m.win.dispatchAction(action, arg);
    }

    fn onFocus(m: *Menu, depth: u8, i: u16) void {
        if (m.closed or depth >= m.open_levels) return;
        const lv = &m.levels[depth];
        if (lv.active != i) {
            lv.active = i;
            m.markDirty(lv);
        }
    }

    fn hover(m: *Menu, depth: u8, i: u16, pos: Vec2) void {
        if (m.closed or depth >= m.open_levels) return;
        const w = m.win;
        const lv = &m.levels[depth];
        if (m.pending) |pd| if (pd.depth != depth) m.cancelPending();
        if (m.open_levels > depth + 1) {
            const sub = &m.levels[depth + 1];
            const rect = m.panelRect(sub) orelse Rect{};
            const d = m.aim.update(pos, w.app.now_ms, rect);
            if (sub.parent == i) {
                m.cancelPending();
                if (lv.active != i) m.focusRow(lv, i, false);
                return;
            }
            if (d == .keep) {
                // Heading for the submenu: decide again once the pointer rests.
                m.pending = .{ .depth = depth, .index = i };
                if (m.aim_timer != .none) w.cancelTimer(m.aim_timer);
                m.aim_timer = w.setTimer(w.app.now_ms + menu_aim.rest_ms, .{ .ctx = m, .f = onAimTimer }) catch .none;
                return;
            }
        }
        m.cancelPending();
        if (lv.active == i and w.focus.eql(lv.nodes.items[i])) return;
        m.closeFrom(depth + 1);
        m.focusRow(lv, i, false);
        if (lv.rows[i].kind == .submenu) m.openSub(lv, i, false);
    }

    fn onAimTimer(ctx: *anyopaque, w: *Window) void {
        const m: *Menu = @ptrCast(@alignCast(ctx));
        m.aim_timer = .none;
        const pd = m.pending orelse return;
        if (m.closed) return;
        m.hover(pd.depth, pd.index, w.pointer);
    }

    fn move(m: *Menu, lv: *Level, dir: enum { next, prev, first, last }) void {
        const n = lv.rows.len;
        if (n == 0) return;
        const start: usize = switch (dir) {
            .first => n - 1,
            .last => 0,
            else => lv.active orelse (if (dir == .next) n - 1 else 0),
        };
        const fwd = dir == .next or dir == .first;
        var i = start;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            i = if (fwd) (i + 1) % n else (i + n - 1) % n;
            if (lv.rows[i].selectable()) {
                m.closeFrom(lv.depth + 1);
                m.focusRow(lv, @intCast(i), true);
                return;
            }
        }
    }

    fn onKey(m: *Menu, depth: u8, k: event_mod.KeyPress) bool {
        if (m.closed or depth >= m.open_levels) return false;
        const lv = &m.levels[depth];
        if (k.mods.ctrl or k.mods.super) return false;
        switch (k.key) {
            .arrow_down => m.move(lv, .next),
            .arrow_up => m.move(lv, .prev),
            .home, .page_up => m.move(lv, .first),
            .end, .page_down => m.move(lv, .last),
            .enter, .numpad_enter => if (lv.active) |a| m.activate(lv, a, .enter),
            .space => if (lv.active) |a| m.activate(lv, a, .space),
            .arrow_right => {
                if (lv.active) |a| if (lv.rows[a].kind == .submenu and lv.rows[a].enabled) {
                    m.openSub(lv, a, true);
                    return true;
                };
                if (m.opts.bar) |b| b.move(b.ctx, 1);
            },
            .arrow_left => if (depth > 0) {
                const up = &m.levels[depth - 1];
                const p = lv.parent;
                m.closeFrom(depth);
                m.focusRow(up, p, true);
            } else if (m.opts.bar) |b| b.move(b.ctx, -1),
            .escape => if (depth > 0) {
                const up = &m.levels[depth - 1];
                const p = lv.parent;
                m.closeFrom(depth);
                m.focusRow(up, p, true);
            } else m.closeAll(),
            .tab => {
                m.closeAll();
                return false;
            },
            else => {
                if (k.mods.alt or k.codepoint == 0 or k.codepoint > 0x7f) return false;
                return m.letter(lv, @intCast(k.codepoint));
            },
        }
        return true;
    }

    fn letter(m: *Menu, lv: *Level, cp: u8) bool {
        const c = std.ascii.toLower(cp);
        if (!std.ascii.isPrint(c) or c == ' ') return false;
        if (m.mnemonics) {
            for (lv.rows, 0..) |*r, i| {
                if (r.selectable() and r.mn == c) {
                    m.focusRow(lv, @intCast(i), true);
                    m.activate(lv, @intCast(i), .enter);
                    return true;
                }
            }
        }
        const now = m.win.app.now_ms;
        if (now -| m.typeahead_at > typeahead_ms) m.typeahead_len = 0;
        m.typeahead_at = now;
        if (m.typeahead_len < m.typeahead.len) {
            m.typeahead[m.typeahead_len] = c;
            m.typeahead_len += 1;
        }
        const buf = m.typeahead[0..m.typeahead_len];
        const n = lv.rows.len;
        // A fresh letter searches after the active item; a longer prefix
        // may stay on it.
        const from: usize = if (lv.active) |a| (if (buf.len == 1) a + 1 else a) else 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const i = (from + k) % n;
            const r = &lv.rows[i];
            if (r.selectable() and r.label.len >= buf.len and std.ascii.eqlIgnoreCase(r.label[0..buf.len], buf)) {
                m.closeFrom(lv.depth + 1);
                m.focusRow(lv, @intCast(i), true);
                return true;
            }
        }
        return true;
    }
};

fn firstSelectable(rows: []const Row) ?u16 {
    for (rows, 0..) |*r, i| if (r.selectable()) return @intCast(i);
    return null;
}

/// A row's check mark.
pub const Check = enum(u8) { none, off, on, radio_off, radio_on };

/// One menu item row.
pub const MenuRow = struct {
    pub const name = "menu_item";
    pub const focusable = true;

    pub const Props = struct {
        menu: *Menu,
        depth: u8,
        index: u16,
        label: []const u8,
        mn_pos: u16 = no_mnemonic,
        shortcut: []const u8 = "",
        check: Check = .none,
        submenu: bool = false,
        enabled: bool = true,
        active: bool = false,
        expanded: bool = false,
        mnemonics: bool = false,
    };

    const slot_w: f32 = 22;
    const chevron_w: f32 = 18;
    const shortcut_gap: f32 = 28;

    fn body(th: *const theme_mod.Theme) text_mod.TextStyle {
        return .{ .size = th.dim(.font_size) };
    }

    pub fn style(_: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .min_h = th.dim(.control_h), .padding = .xy(th.dim(.space_sm), 0), .shrink = 0 };
    }

    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = body(mc.theme);
        var w = slot_w + mc.text.width(st, props.label) + chevron_w;
        if (props.shortcut.len > 0) w += shortcut_gap + mc.text.width(st, props.shortcut);
        return .{ .w = w, .h = mc.text.metrics(st).line_h };
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const th = pc.theme;
        const st = body(th);
        const m = pc.text_sys.metrics(st);
        const pad = pc.dim(.space_sm);
        if (props.active or props.expanded) pc.fill(r, .selection_bg, pc.dim(.radius_sm));
        const fg = pc.color(if (props.enabled) .fg else .fg_disabled);
        const baseline = r.y + (r.h - (m.ascent + m.descent)) / 2 + m.ascent;
        const x0 = r.x + pad;
        switch (props.check) {
            .on => pc.textLine("\u{2713}", st, fg, .{ .x = x0 + 2, .y = baseline }),
            .radio_on => pc.textLine("\u{2022}", st, fg, .{ .x = x0 + 4, .y = baseline }),
            else => {},
        }
        const lx = x0 + slot_w;
        pc.textLine(props.label, st, fg, .{ .x = lx, .y = baseline });
        if (props.mnemonics and props.mn_pos < props.label.len) {
            const p = props.mn_pos;
            const cl = std.unicode.utf8ByteSequenceLength(props.label[p]) catch 1;
            const ux = lx + pc.text_sys.width(st, props.label[0..p]);
            const uw = pc.text_sys.width(st, props.label[p..@min(props.label.len, p + cl)]);
            pc.rect(.{ .x = ux, .y = baseline + 1, .w = uw, .h = 1 }, fg, .all(0));
        }
        if (props.shortcut.len > 0) {
            const sw = pc.text_sys.width(st, props.shortcut);
            pc.textLine(props.shortcut, st, pc.color(.fg_muted), .{ .x = r.right() - pad - chevron_w - sw, .y = baseline });
        }
        if (props.submenu) {
            const cw = pc.text_sys.width(st, "\u{203a}");
            pc.textLine("\u{203a}", st, fg, .{ .x = r.right() - pad - cw - 2, .y = baseline });
        }
    }

    pub fn event(_: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        const m = props.menu;
        if (m.closed or props.depth >= m.open_levels) return false;
        const lv = &m.levels[props.depth];
        switch (ev.*) {
            .pointer_move => |p| m.hover(props.depth, props.index, p.pos),
            .pointer_up => |p| if (p.button == .left) {
                m.activate(lv, props.index, .pointer);
                return true;
            },
            .key => |k| if (k.action != .release) return m.onKey(props.depth, k),
            .focus_gained => m.onFocus(props.depth, props.index),
            else => {},
        }
        return false;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{
            .role = .menuitem,
            .name = props.label,
            .checked = switch (props.check) {
                .none => null,
                .on, .radio_on => true,
                .off, .radio_off => false,
            },
            .disabled = !props.enabled,
        };
    }
};

test "parseMnemonic" {
    var buf: [32]u8 = undefined;
    const a = parseMnemonic(&buf, "&Open File");
    try std.testing.expectEqualStrings("Open File", a.text);
    try std.testing.expectEqual(@as(?u16, 0), a.pos);
    try std.testing.expectEqual(@as(u8, 'o'), a.key);
    var buf2: [32]u8 = undefined;
    const b = parseMnemonic(&buf2, "Save && E&xit");
    try std.testing.expectEqualStrings("Save & Exit", b.text);
    try std.testing.expectEqual(@as(?u16, 8), b.pos);
    try std.testing.expectEqual(@as(u8, 'x'), b.key);
    var buf3: [32]u8 = undefined;
    const c = parseMnemonic(&buf3, "Plain");
    try std.testing.expect(c.pos == null);
}

test {
    std.testing.refAllDecls(@This());
}
