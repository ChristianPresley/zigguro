//! A dock group's tab strip (E04.F07.S01.T02): its tabs in a 35 px row
//! that scrolls sideways when they overflow (the wheel scrolls it, the
//! active tab is kept in view) with a "⌄" menu listing every tab.
//!
//! Tabs size to their title (80..240 px). Pinned tabs come first, preview
//! tabs have an italic title, and a dirty tab shows a dot in place of its
//! close button until hovered. Keyboard and close gestures are those of
//! `widgets/tabs.zig`. The strip reports what happened; the caller
//! applies it to the model.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const ids = @import("../core/ids.zig");
const roving = @import("../widgets/roving.zig");
const tabs_w = @import("../widgets/tabs.zig");
const menu = @import("../widgets/menu.zig");
const scroll = @import("../widgets/scroll.zig");

const Ui = ui_mod.Ui;
const NodeId = ids.NodeId;

/// One tab of a strip.
pub const TabSpec = struct {
    id: u64,
    title: []const u8,
    dirty: bool = false,
    preview: bool = false,
    pinned: bool = false,
    tooltip: ?[]const u8 = null,
    closable: bool = true,
    /// Agent status and the like.
    badge: []const u8 = "",
};

/// Strip options.
pub const TabStripProps = struct {
    label: []const u8 = "Tabs",
    /// The group has focus: draw the accent on the active tab.
    focused: bool = false,
    /// Receives the overflow menu's `activate_action` (arg: the tab id).
    on_action: ?menu.ActionCb = null,
    test_id: []const u8 = "tab_strip",
};

/// The overflow menu's action; its argument is the tab's `id`.
pub const activate_action = "dock.activateTab";
/// The strip's height.
pub const height: f32 = 35;

/// What happened on a strip this build.
pub const TabStripResponse = struct {
    /// A tab became active (click or keyboard).
    activated: ?u32 = null,
    /// A tab asked to close.
    closed: ?u32 = null,
    /// A tab asked for its context menu, at `context_node`.
    context: ?u32 = null,
    context_node: NodeId = .none,
    /// Each tab's node, for drag-to-dock (valid until the next build).
    nodes: []const NodeId = &.{},
};

/// Adds a strip for `specs` with tab `active` selected.
pub fn tabStrip(ui: *Ui, specs: []const TabSpec, active: u32, p: TabStripProps) TabStripResponse {
    const w = ui.window();
    var out: TabStripResponse = .{};
    const nodes: []NodeId = ui.arena().alloc(NodeId, specs.len) catch &[_]NodeId{};
    ui.open(.{ .style = .{ .dir = .row, .h = .{ .px = height }, .shrink = 0, .bg = .{ .token = .bg_elevated }, .align_items = .stretch }, .test_id = p.test_id });
    defer ui.close();
    const sc = scroll.scrollArea(ui, .{ .x = true, .y = false, .style = .{ .grow = 1, .basis = .{ .px = 0 }, .dir = .row } });
    {
        defer ui.close();
        const group = ui.begin(roving.Group, .{ .role = .tablist, .label = p.label });
        defer ui.end(roving.Group);
        group.reset(w);
        for (specs, 0..) |t, i| {
            ui.id(t.id);
            const is_active = i == active;
            const r = ui.leaf(tabs_w.Tab, .{
                .group = group,
                .title = t.title,
                .active = is_active,
                .accent = p.focused,
                .dirty = t.dirty,
                .preview = t.preview,
                .pinned = t.pinned,
                .closable = t.closable,
                .badge = t.badge,
                .min_w = 80,
                .max_w = 240,
                .height = height,
            });
            const n = ui.lastNode();
            group.add(n);
            if (i < nodes.len) nodes[i] = n;
            if (t.tooltip) |tt| @import("../widgets/tooltip.zig").tooltipLast(ui, tt, .{ .side = .below });
            if (r.cancelled) {
                out.closed = @intCast(i);
            } else if (r.context_menu or r.right_clicked) {
                out.context = @intCast(i);
                out.context_node = n;
            } else if ((r.clicked or r.focus_gained) and !is_active) out.activated = @intCast(i);
            if (is_active) reveal(w, sc, n);
        }
    }
    out.nodes = nodes;
    // Every tab, for when they overflow.
    if (specs.len > 1) {
        ui.id("\u{2304}");
        const r = @import("../widgets/controls.zig").button(ui, .{ .label = "\u{2304}", .variant = .ghost });
        if (r.clicked) {
            const items = ui.arena().alloc(menu.MenuItem, specs.len) catch return out;
            for (specs, items, 0..) |t, *it, i| it.* = .{ .action = .{
                .label = t.title,
                .action = activate_action,
                .arg = std.fmt.allocPrint(ui.arena(), "{d}", .{t.id}) catch "0",
                .checked = i == active,
            } };
            _ = menu.openMenu(w, items, .{ .node = ui.lastNode() }, .{ .on_action = p.on_action, .keyboard = w.focus_visible, .test_id = "tab_list_menu" }) catch {};
        }
    }
    return out;
}

/// Scrolls `sc` so that tab `n` (laid out last frame) is in view.
fn reveal(w: anytype, sc: NodeId, n: NodeId) void {
    if (sc.isNone() or n.isNone() or !w.store.valid(sc) or !w.store.valid(n)) return;
    const r = w.store.relRect(n);
    const vw = w.store.relRect(sc).w;
    if (r.w == 0 or vw == 0) return;
    const off = w.scrollOffset(sc).x;
    if (r.x < off) {
        _ = w.scrollTo(sc, .{ .x = r.x, .y = 0 });
    } else if (r.right() > off + vw) {
        _ = w.scrollTo(sc, .{ .x = r.right() - vw, .y = 0 });
    }
}
