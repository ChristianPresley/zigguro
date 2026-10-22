//! The dock view (E04.F07.S01.T02): renders a `DockModel` area as nested
//! splits (with splitters) and tab groups (a tab strip over the active
//! panel's content).
//!
//! The app supplies panels through `PanelHost`: each panel's tab (title,
//! dirty, badge) and its content. Tab gestures act on the model: clicking
//! or keyboard focus activates, close gestures close, and the context menu
//! offers Close, Close Others, Close to the Right, Pin/Unpin, Split Right,
//! Split Down and Move to Agent Area. Focus inside a group makes it the
//! model's focused group, which draws the accent on its active tab.
//!
//! The last laid-out group rectangles are kept (`groupRects`) for
//! `DockModel.neighbor` and for the drop zones.
//!
//! Drag-to-dock: dragging a tab 8 px starts a drag. Over a tab strip it
//! reorders (or moves into that group at that place); elsewhere the drop
//! zones decide: a group's edge splits it, its center moves into it, a
//! window edge docks into that side area, outside the window floats (when
//! the app shows floating windows: `floating`). The
//! zone's preview is drawn by `dropOverlay`; Escape cancels. The drop is
//! one `DockModel.move`, so one undo step.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const ids = @import("../core/ids.zig");
const window_mod = @import("../core/window.zig");
const menu = @import("../widgets/menu.zig");
const model = @import("model.zig");
const splitter = @import("splitter.zig");
const tab_strip = @import("tab_strip.zig");
const drop_zones = @import("drop_zones.zig");
const tabs_w = @import("../widgets/tabs.zig");
const geom = @import("../core/geom.zig");

const Ui = ui_mod.Ui;
const NodeId = ids.NodeId;
const Window = window_mod.Window;
const DockModel = model.DockModel;
const PanelRef = model.PanelRef;
const GroupId = model.GroupId;

/// What the app shows for its panels.
pub const PanelHost = struct {
    ctx: *anyopaque,
    /// The tab for `p` (strings valid during the build).
    tab: *const fn (ctx: *anyopaque, p: PanelRef) TabInfo,
    /// Adds `p`'s content (it fills the group below the strip).
    build: *const fn (ctx: *anyopaque, ui: *Ui, p: PanelRef) void,
    /// Adds the content of an empty group (the center's welcome page).
    empty: ?*const fn (ctx: *anyopaque, ui: *Ui) void = null,
    /// Asks before `p` closes; false keeps it (unsaved changes).
    can_close: ?*const fn (ctx: *anyopaque, p: PanelRef) bool = null,
};

/// A panel's tab.
pub const TabInfo = struct {
    title: []const u8,
    dirty: bool = false,
    tooltip: ?[]const u8 = null,
    badge: []const u8 = "",
    closable: bool = true,
};

/// The context menu's actions (arg: the panel id).
pub const actions = struct {
    pub const close = "dock.close";
    pub const close_others = "dock.closeOthers";
    pub const close_right = "dock.closeToRight";
    pub const pin = "dock.pin";
    pub const unpin = "dock.unpin";
    pub const split_right = "dock.splitRight";
    pub const split_down = "dock.splitDown";
    pub const to_agent = "dock.moveToAgentArea";
};

/// See the module doc. Must not move while a window shows it.
pub const DockView = struct {
    gpa: std.mem.Allocator,
    dock: *DockModel,
    host: PanelHost,
    /// The least a split child gets.
    min_px: f32 = 120,
    /// Dropping outside the window floats the panel (the app shows
    /// `DockModel.floating`); otherwise nothing happens there.
    floating: bool = false,
    win: ?*Window = null,
    /// Group boxes from the last build.
    group_nodes: std.ArrayList(struct { g: GroupId, node: NodeId }) = .empty,
    /// Tab strips from the last build: their tabs are
    /// `tab_nodes[start..][0..len]`.
    strips: std.ArrayList(struct { g: GroupId, node: NodeId, start: u32, len: u32 }) = .empty,
    tab_nodes: std.ArrayList(NodeId) = .empty,
    /// Each area's box from the last build (none when not shown).
    area_nodes: [5]NodeId = @splat(.none),
    /// The drag in progress.
    drag: ?Drag = null,

    /// A tab being dragged.
    pub const Drag = struct {
        p: PanelRef,
        pos: geom.Vec2,
        zone: ?drop_zones.DropZone = null,
    };

    pub fn init(gpa: std.mem.Allocator, dock: *DockModel, host: PanelHost) DockView {
        return .{ .gpa = gpa, .dock = dock, .host = host };
    }

    pub fn deinit(dv: *DockView) void {
        dv.group_nodes.deinit(dv.gpa);
        dv.strips.deinit(dv.gpa);
        dv.tab_nodes.deinit(dv.gpa);
    }

    /// Starts a build of every area (forgets the last group boxes).
    pub fn beginFrame(dv: *DockView, ui: *Ui) void {
        dv.win = ui.window();
        dv.group_nodes.clearRetainingCapacity();
        dv.strips.clearRetainingCapacity();
        dv.tab_nodes.clearRetainingCapacity();
        dv.area_nodes = @splat(.none);
    }

    /// Adds `area`'s tree, filling the current container (nothing when
    /// the area is hidden or empty).
    pub fn dockArea(dv: *DockView, ui: *Ui, area: model.Area) void {
        const st = dv.dock.areas[@intFromEnum(area)];
        if (!st.visible) return;
        var root = st.root orelse return;
        if (area == .center) if (dv.dock.maximized) |g| {
            root = .{ .group = g };
        };
        ui.id(@intFromEnum(area));
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .align_items = .stretch } });
        defer ui.close();
        dv.area_nodes[@intFromEnum(area)] = ui.current();
        dv.node(ui, root, true);
    }

    /// Draws the drop preview while a tab is dragged. Call it last in a
    /// container at the window's origin (the preview is absolutely placed
    /// in window coordinates).
    pub fn dropOverlay(dv: *DockView, ui: *Ui) void {
        const d = dv.drag orelse return;
        const z = d.zone orelse return;
        if (z.target == .float) return;
        const r = z.preview;
        ui.open(.{ .style = .{
            .position = .absolute,
            .inset = .{ .l = r.x, .t = r.y },
            .w = .{ .px = r.w },
            .h = .{ .px = r.h },
            .bg = .{ .token = .selection_bg },
        }, .test_id = "dock_drop_preview" });
        ui.close();
    }

    /// The drop under `pos`: a place in a tab strip, else a drop zone.
    pub fn zoneAt(dv: *DockView, pos: geom.Vec2) ?drop_zones.DropZone {
        const w = dv.win orelse return null;
        for (dv.strips.items) |st| {
            if (!w.store.valid(st.node)) continue;
            const sr = w.layoutRect(st.node);
            if (!sr.contains(pos)) continue;
            var index: u32 = 0;
            var x = sr.x;
            for (dv.tab_nodes.items[st.start..][0..st.len]) |n| {
                if (!w.store.valid(n)) continue;
                const r = w.layoutRect(n);
                if (pos.x < r.x + r.w / 2) {
                    x = r.x;
                    break;
                }
                index += 1;
                x = r.right();
            }
            const strip: model.Rect = .{ .x = sr.x, .y = sr.y, .w = sr.w, .h = sr.h };
            return .{ .target = .{ .group = .{ .g = st.g, .index = index } }, .rect = strip, .preview = .{ .x = x - 1, .y = sr.y, .w = 2, .h = sr.h } };
        }
        var groups: std.ArrayList(model.GroupRect) = .empty;
        defer groups.deinit(dv.gpa);
        dv.groupRects(dv.gpa, &groups) catch return null;
        var areas: [4]drop_zones.AreaRect = undefined;
        var na: usize = 0;
        for ([_]model.Area{ .left, .right, .bottom, .agent }) |a| {
            const n = dv.area_nodes[@intFromEnum(a)];
            const shown = !n.isNone() and w.store.valid(n);
            const r = if (shown) w.layoutRect(n) else geom.Rect{};
            areas[na] = .{ .area = a, .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, .visible = shown };
            na += 1;
        }
        var zones: std.ArrayList(drop_zones.DropZone) = .empty;
        defer zones.deinit(dv.gpa);
        const win: model.Rect = .{ .w = w.size.w, .h = w.size.h };
        drop_zones.computeDropZones(win, groups.items, areas[0..na], dv.gpa, &zones) catch return null;
        const z = drop_zones.hit(zones.items, win, .{ pos.x, pos.y }) orelse return null;
        return if (z.target == .float and !dv.floating) null else z;
    }

    fn onDrag(ctx: *anyopaque, id: u64, phase: tabs_w.DragPhase, pos: geom.Vec2) void {
        const dv: *DockView = @ptrCast(@alignCast(ctx));
        switch (phase) {
            .start => dv.drag = .{ .p = @enumFromInt(@as(u32, @intCast(id))), .pos = pos },
            .move => if (dv.drag) |*d| {
                d.pos = pos;
                d.zone = dv.zoneAt(pos);
            },
            .drop => if (dv.drag) |d| {
                dv.drag = null;
                if (dv.zoneAt(pos)) |z| dv.dock.move(d.p, z.target) catch {};
            },
            .cancel => dv.drag = null,
        }
        dv.changed();
    }

    /// Each shown group's rectangle from the last layout.
    pub fn groupRects(dv: *const DockView, gpa: std.mem.Allocator, out: *std.ArrayList(model.GroupRect)) std.mem.Allocator.Error!void {
        const w = dv.win orelse return;
        for (dv.group_nodes.items) |e| {
            if (!w.store.valid(e.node)) continue;
            const r = w.layoutRect(e.node);
            try out.append(gpa, .{ .g = e.g, .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h } });
        }
    }

    fn node(dv: *DockView, ui: *Ui, n: model.Node, fill: bool) void {
        switch (n) {
            .group => |g| dv.group(ui, g, fill),
            .split => |s| dv.split(ui, s, fill),
        }
    }

    fn split(dv: *DockView, ui: *Ui, s: model.SplitId, fill: bool) void {
        const sp = dv.dock.splitOf(s) orelse return;
        const row = sp.axis == .row;
        ui.id(@intFromEnum(s));
        ui.open(.{ .style = .{
            .dir = if (row) .row else .column,
            .grow = if (fill) 1 else 0,
            .w = .{ .pct = 100 },
            .h = .{ .pct = 100 },
            .align_items = .stretch,
        }, .test_id = "dock_split" });
        defer ui.close();
        const w = ui.window();
        const box = ui.current();
        const last = w.store.relRect(box);
        const k: f32 = @floatFromInt(sp.children.items.len);
        const total = @max(0, (if (row) last.w else last.h) - splitter.thickness * (k - 1));
        // The children list may change while building (a tab closed by a
        // gesture): copy it.
        var kids_buf: [64]model.Node = undefined;
        var ratios_buf: [64]f32 = undefined;
        const nk = @min(sp.children.items.len, kids_buf.len);
        @memcpy(kids_buf[0..nk], sp.children.items[0..nk]);
        @memcpy(ratios_buf[0..nk], sp.ratios.items[0..nk]);
        for (kids_buf[0..nk], ratios_buf[0..nk], 0..) |c, r, i| {
            if (i > 0) {
                ui.id([2]u64{ @intFromEnum(s), i });
                _ = ui.leaf(splitter.Splitter, .{ .dock = dv.dock, .split = s, .index = @intCast(i - 1), .axis = sp.axis, .total_px = total, .min_px = dv.min_px });
            }
            ui.id(childKey(c));
            ui.open(.{ .style = .{
                .dir = .column,
                .grow = r,
                .basis = .{ .px = 0 },
                .shrink = 1,
                .min_w = if (row) dv.min_px else 0,
                .min_h = if (row) 0 else dv.min_px,
                .align_items = .stretch,
            } });
            dv.node(ui, c, true);
            ui.close();
        }
    }

    fn childKey(c: model.Node) u64 {
        return switch (c) {
            .group => |g| @intFromEnum(g),
            .split => |s| @as(u64, @intFromEnum(s)) | (1 << 40),
        };
    }

    fn group(dv: *DockView, ui: *Ui, g: GroupId, fill: bool) void {
        const gr = dv.dock.group(g) orelse return;
        const w = ui.window();
        ui.id(@intFromEnum(g));
        ui.open(.{ .style = .{ .dir = .column, .grow = if (fill) 1 else 0, .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .align_items = .stretch }, .role = .group, .test_id = "dock_group" });
        defer ui.close();
        const box = ui.current();
        dv.group_nodes.append(dv.gpa, .{ .g = g, .node = box }) catch {};
        // Focus inside the group focuses it.
        if (!w.focus.isNone() and w.store.valid(box) and w.store.isAncestor(box, w.focus) and dv.dock.focused != g) dv.dock.focused = g;

        const n = gr.tabs.items.len;
        const specs = ui.arena().alloc(tab_strip.TabSpec, n) catch return;
        for (gr.tabs.items, specs, 0..) |p, *s, i| {
            const info = dv.host.tab(dv.host.ctx, p);
            s.* = .{
                .id = @intFromEnum(p),
                .title = info.title,
                .dirty = info.dirty,
                .tooltip = info.tooltip,
                .badge = info.badge,
                .closable = info.closable,
                .preview = gr.preview == p,
                .pinned = i < gr.pinned,
            };
        }
        const active = gr.active;
        const active_p: ?PanelRef = if (active < n) gr.tabs.items[active] else null;
        if (n > 0) {
            const r = tab_strip.tabStrip(ui, specs, active, .{
                .focused = dv.dock.focused == g,
                .on_action = .{ .ctx = dv, .f = onMenuAction },
                .drag = .{ .ctx = dv, .f = onDrag },
            });
            const start: u32 = @intCast(dv.tab_nodes.items.len);
            dv.tab_nodes.appendSlice(dv.gpa, r.nodes) catch {};
            dv.strips.append(dv.gpa, .{ .g = g, .node = r.strip, .start = start, .len = @intCast(dv.tab_nodes.items.len - start) }) catch {};
            if (r.closed) |i| dv.closePanel(gr.tabs.items[i]) else if (r.activated) |i| {
                dv.dock.activate(g, i);
                w.markViewDirty(ui.currentView());
            }
            if (r.context) |i| dv.openContext(w, g, i, r.context_node);
        }
        // The active panel's content.
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .align_items = .stretch }, .test_id = "dock_content" });
        if (active_p) |p| {
            ui.id(@intFromEnum(p));
            dv.host.build(dv.host.ctx, ui, p);
        } else if (dv.host.empty) |f| f(dv.host.ctx, ui);
        ui.close();
    }

    fn closePanel(dv: *DockView, p: PanelRef) void {
        if (dv.host.can_close) |f| if (!f(dv.host.ctx, p)) return;
        dv.dock.close(p) catch {};
        dv.changed();
    }

    fn changed(dv: *DockView) void {
        if (dv.win) |w| w.markAllDirty();
    }

    fn openContext(dv: *DockView, w: *Window, g: GroupId, i: u32, at: NodeId) void {
        const gr = dv.dock.group(g) orelse return;
        if (i >= gr.tabs.items.len) return;
        const p = gr.tabs.items[i];
        var buf: [16]u8 = undefined;
        const arg = std.fmt.bufPrint(&buf, "{d}", .{@intFromEnum(p)}) catch return;
        const pinned = i < gr.pinned;
        const items = [_]menu.MenuItem{
            .{ .action = .{ .label = "Close", .action = actions.close, .arg = arg } },
            .{ .action = .{ .label = "Close Others", .action = actions.close_others, .arg = arg, .enabled = gr.tabs.items.len > 1 } },
            .{ .action = .{ .label = "Close to the Right", .action = actions.close_right, .arg = arg, .enabled = i + 1 < gr.tabs.items.len } },
            .separator,
            .{ .action = .{ .label = if (pinned) "Unpin" else "Pin", .action = if (pinned) actions.unpin else actions.pin, .arg = arg } },
            .separator,
            .{ .action = .{ .label = "Split Right", .action = actions.split_right, .arg = arg } },
            .{ .action = .{ .label = "Split Down", .action = actions.split_down, .arg = arg } },
            .{ .action = .{ .label = "Move to Agent Area", .action = actions.to_agent, .arg = arg } },
        };
        _ = menu.openMenu(w, &items, .{ .node = at }, .{ .on_action = .{ .ctx = dv, .f = onMenuAction }, .keyboard = w.focus_visible, .test_id = "tab_menu" }) catch {};
    }

    /// Runs a tab menu or overflow menu action on the model.
    pub fn runAction(dv: *DockView, action: []const u8, arg: ?[]const u8) void {
        const a = arg orelse return;
        const num = std.fmt.parseInt(u32, a, 10) catch return;
        const eql = std.mem.eql;
        defer dv.changed();
        const p: PanelRef = @enumFromInt(num);
        const g = dv.dock.groupOf(p) orelse return;
        const m = dv.dock;
        if (eql(u8, action, tab_strip.activate_action)) {
            const at = std.mem.indexOfScalar(PanelRef, m.group(g).?.tabs.items, p) orelse return;
            m.activate(g, @intCast(at));
            return;
        }
        if (eql(u8, action, actions.close)) {
            dv.closePanel(p);
        } else if (eql(u8, action, actions.close_others) or eql(u8, action, actions.close_right)) {
            const right_only = eql(u8, action, actions.close_right);
            const tabs = m.group(g).?.tabs.items;
            const at = std.mem.indexOfScalar(PanelRef, tabs, p).?;
            var victims: [256]PanelRef = undefined;
            var nv: usize = 0;
            for (tabs, 0..) |t, i| {
                if (t == p or (right_only and i < at) or nv == victims.len) continue;
                victims[nv] = t;
                nv += 1;
            }
            for (victims[0..nv]) |t| dv.closePanel(t);
        } else if (eql(u8, action, actions.pin) or eql(u8, action, actions.unpin)) {
            m.setPinned(p, eql(u8, action, actions.pin)) catch {};
        } else if (eql(u8, action, actions.split_right) or eql(u8, action, actions.split_down)) {
            // Split a copy of the view: the same panel moves to the new group.
            _ = m.split(g, if (eql(u8, action, actions.split_right)) .right else .bottom, p) catch {};
        } else if (eql(u8, action, actions.to_agent)) {
            m.move(p, .{ .area = .agent }) catch {};
        }
    }

    fn onMenuAction(ctx: ?*anyopaque, action: []const u8, arg: ?[]const u8) void {
        const dv: *DockView = @ptrCast(@alignCast(ctx.?));
        dv.runAction(action, arg);
    }
};
