//! `DockModel` (E04.F07.S01.T01): the workbench layout as pure data, with
//! no GUI types beyond ids.
//!
//! Five areas (`left`, `right`, `bottom`, `center`, `agent`) and any
//! number of floating windows each hold a tree of splits and tab groups.
//! Panels are instances (`PanelRef`) of a panel kind with optional state;
//! a panel is open in at most one group.
//!
//! Every operation normalizes the trees: empty groups go (except the
//! center's only group, which may be empty: it shows the empty editor),
//! single-child splits collapse, same-axis splits flatten (ratios merged
//! proportionally) and ratios sum to 1. `validate` checks the invariants.
//!
//! Undo: every operation first records a snapshot in a ring of
//! `undo_depth`; `undo` restores the last one. Closed panels go on a stack
//! that `reopenClosed` pops. Maximize is a view flag: the center tree is
//! kept and only the maximized group is shown, so restoring is exact.
//! Snapshots cover the layout only; panels are shared, so restoring one
//! (undo, modes) never closes a panel: panels opened since go to the
//! center, panels closed since are dropped from it.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A panel instance.
pub const PanelRef = enum(u32) { _ };
/// A tab group.
pub const GroupId = enum(u32) { _ };
/// A split.
pub const SplitId = enum(u32) { _ };
/// A floating window.
pub const FloatId = enum(u32) { _ };
/// A panel kind (editor, terminal, agent, ...), defined by the app.
pub const PanelKindId = u32;

/// The docking areas.
pub const Area = enum(u3) { left, right, bottom, center, agent };
/// Where a split puts the new group.
pub const Side = enum(u2) { left, right, top, bottom };
/// A split's direction: `row` lays children left to right.
pub const Axis = enum(u1) { row, column };
/// A neighbor direction.
pub const Dir = enum(u2) { left, right, up, down };

/// A rectangle (layout units).
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// A tree node.
pub const Node = union(enum) {
    group: GroupId,
    split: SplitId,

    pub fn eql(a: Node, b: Node) bool {
        return switch (a) {
            .group => |g| b == .group and b.group == g,
            .split => |s| b == .split and b.split == s,
        };
    }
};

/// Where a tree is rooted.
pub const Owner = union(enum) {
    area: Area,
    float: FloatId,
};

/// A tab group.
pub const Group = struct {
    tabs: std.ArrayList(PanelRef) = .empty,
    active: u32 = 0,
    /// Tabs `[0, pinned)` are pinned.
    pinned: u32 = 0,
    /// The group's preview tab (replaced by the next preview open).
    preview: ?PanelRef = null,
};

/// A split.
pub const Split = struct {
    axis: Axis,
    children: std.ArrayList(Node) = .empty,
    ratios: std.ArrayList(f32) = .empty,
};

/// A panel.
pub const Panel = struct {
    kind: PanelKindId,
    /// Kind-defined state (owned), restored with the layout.
    state: ?[]u8 = null,
};

/// Each area's size before the user resizes it (pixels along its axis).
pub fn defaultSize(a: Area) f32 {
    return switch (a) {
        .left, .right => 240,
        .bottom => 260,
        .agent => 380,
        .center => 0,
    };
}

/// An area's tree and visibility.
pub const AreaState = struct {
    root: ?Node = null,
    visible: bool = true,
    /// Size along the area's axis (pixels; the center ignores it).
    size: f32 = 240,
};

/// A floating window.
pub const Floating = struct {
    id: FloatId,
    /// Position and size; the position is the monitor's global layout
    /// in logical pixels (unknown on Wayland, where only the size
    /// restores).
    rect: Rect,
    monitor_hint: u32 = 0,
    /// The monitor it was on (`MonitorName.set`), for restoring.
    monitor: MonitorName = .{},
    /// That monitor's scale.
    scale: f32 = 1,
    root: ?Node,
};

/// A monitor's name, stored inline so layouts copy without allocating.
pub const MonitorName = struct {
    buf: [48]u8 = undefined,
    len: u8 = 0,

    /// The name (truncated to 48 bytes).
    pub fn set(n: *MonitorName, s: []const u8) void {
        const k = @min(s.len, n.buf.len);
        @memcpy(n.buf[0..k], s[0..k]);
        n.len = @intCast(k);
    }

    /// The name.
    pub fn get(n: *const MonitorName) []const u8 {
        return n.buf[0..n.len];
    }
};

/// Where `move` takes a panel.
pub const DropTarget = union(enum) {
    /// Into a group, at `index` (null: the end).
    group: struct { g: GroupId, index: ?u32 = null },
    /// Into a new group beside `g`.
    split: struct { g: GroupId, side: Side },
    /// Into an area (its first group, or a new one).
    area: Area,
    /// Into a new floating window.
    float: Rect,
};

/// Options for `openIn`.
pub const OpenOptions = struct {
    preview: bool = false,
    activate: bool = true,
};

/// A group's last laid-out rectangle (for `neighbor`).
pub const GroupRect = struct { g: GroupId, rect: Rect };

/// A closed panel, for `reopenClosed`.
pub const Closed = struct { p: PanelRef, panel: Panel, group: ?GroupId };

/// A copy of the layout (not the panels).
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    groups: []const GroupSnap,
    splits: []const SplitSnap,
    areas: [area_count]AreaState,
    floating: []const Floating,
    maximized: ?GroupId,

    pub const GroupSnap = struct { id: GroupId, tabs: []const PanelRef, active: u32, pinned: u32, preview: ?PanelRef };
    pub const SplitSnap = struct { id: SplitId, axis: Axis, children: []const Node, ratios: []const f32 };

    pub fn deinit(s: *Snapshot) void {
        s.arena.deinit();
        s.* = undefined;
    }
};

const area_count = @typeInfo(Area).@"enum".fields.len;

/// Undo ring size.
pub const undo_depth = 50;

/// See the module doc.
pub const DockModel = struct {
    gpa: Allocator,
    panels: std.AutoArrayHashMapUnmanaged(PanelRef, Panel) = .empty,
    groups: std.AutoArrayHashMapUnmanaged(GroupId, Group) = .empty,
    splits: std.AutoArrayHashMapUnmanaged(SplitId, Split) = .empty,
    areas: [area_count]AreaState = @splat(.{}),
    floating: std.ArrayList(Floating) = .empty,
    /// The center group shown alone, if any.
    maximized: ?GroupId = null,
    /// The group with focus.
    focused: ?GroupId = null,
    closed: std.ArrayList(Closed) = .empty,
    undo_ring: [undo_depth]?Snapshot = @splat(null),
    undo_head: usize = 0,
    /// Record snapshots for `undo` (off for benchmarks).
    history: bool = true,
    next_id: u32 = 1,
    /// Bumped by every change to the layout (savers compare it).
    revision: u64 = 0,

    /// An empty layout: the center holds one empty group.
    pub fn init(gpa: Allocator) Allocator.Error!DockModel {
        var m: DockModel = .{ .gpa = gpa };
        for (&m.areas, 0..) |*a, i| a.size = defaultSize(@enumFromInt(i));
        const g = try m.newGroup();
        m.areas[@intFromEnum(Area.center)].root = .{ .group = g };
        m.focused = g;
        return m;
    }

    pub fn deinit(m: *DockModel) void {
        const gpa = m.gpa;
        for (m.panels.values()) |p| if (p.state) |s| gpa.free(s);
        m.panels.deinit(gpa);
        for (m.groups.values()) |*g| g.tabs.deinit(gpa);
        m.groups.deinit(gpa);
        for (m.splits.values()) |*s| freeSplit(gpa, s);
        m.splits.deinit(gpa);
        m.floating.deinit(gpa);
        for (m.closed.items) |c| if (c.panel.state) |s| gpa.free(s);
        m.closed.deinit(gpa);
        for (&m.undo_ring) |*u| if (u.*) |*s| s.deinit();
        m.* = undefined;
    }

    fn freeSplit(gpa: Allocator, s: *Split) void {
        s.children.deinit(gpa);
        s.ratios.deinit(gpa);
    }

    fn nextId(m: *DockModel) u32 {
        const id = m.next_id;
        m.next_id += 1;
        return id;
    }

    fn newGroup(m: *DockModel) Allocator.Error!GroupId {
        const id: GroupId = @enumFromInt(m.nextId());
        try m.groups.put(m.gpa, id, .{});
        return id;
    }

    fn newSplit(m: *DockModel, axis: Axis) Allocator.Error!SplitId {
        const id: SplitId = @enumFromInt(m.nextId());
        try m.splits.put(m.gpa, id, .{ .axis = axis });
        return id;
    }

    // -- queries -------------------------------------------------------

    /// The root of `o`'s tree.
    pub fn rootOf(m: *const DockModel, o: Owner) ?Node {
        return switch (o) {
            .area => |a| m.areas[@intFromEnum(a)].root,
            .float => |f| if (m.floatIndex(f)) |i| m.floating.items[i].root else null,
        };
    }

    fn setRoot(m: *DockModel, o: Owner, n: ?Node) void {
        switch (o) {
            .area => |a| m.areas[@intFromEnum(a)].root = n,
            .float => |f| if (m.floatIndex(f)) |i| {
                m.floating.items[i].root = n;
            },
        }
    }

    /// Floating window `f`'s tree, if it still exists.
    pub fn floatRoot(m: *const DockModel, f: FloatId) ?Node {
        const i = m.floatIndex(f) orelse return null;
        return m.floating.items[i].root;
    }

    /// Floating window `f`'s state.
    pub fn float(m: *DockModel, f: FloatId) ?*Floating {
        const i = m.floatIndex(f) orelse return null;
        return &m.floating.items[i];
    }

    /// The floating window showing `p`, if any.
    pub fn floatOf(m: *const DockModel, p: PanelRef) ?FloatId {
        const g = m.groupOf(p) orelse return null;
        const o = m.ownerOf(.{ .group = g }) orelse return null;
        return switch (o) {
            .float => |f| f,
            .area => null,
        };
    }

    /// Appends the panels of the tree at `n` (depth-first, tab order).
    pub fn panelsIn(m: *const DockModel, n: Node, gpa: Allocator, out: *std.ArrayList(PanelRef)) Allocator.Error!void {
        switch (n) {
            .group => |g| if (m.groups.get(g)) |gr| try out.appendSlice(gpa, gr.tabs.items),
            .split => |s| if (m.splits.get(s)) |sp| for (sp.children.items) |c| try m.panelsIn(c, gpa, out),
        }
    }

    fn floatIndex(m: *const DockModel, f: FloatId) ?usize {
        for (m.floating.items, 0..) |w, i| if (w.id == f) return i;
        return null;
    }

    /// The group showing `p`, if open.
    pub fn groupOf(m: *const DockModel, p: PanelRef) ?GroupId {
        var it = m.groups.iterator();
        while (it.next()) |e| {
            if (std.mem.indexOfScalar(PanelRef, e.value_ptr.tabs.items, p) != null) return e.key_ptr.*;
        }
        return null;
    }

    /// A group's state.
    pub fn group(m: *const DockModel, g: GroupId) ?*Group {
        return m.groups.getPtr(g);
    }

    /// A split's state.
    pub fn splitOf(m: *const DockModel, s: SplitId) ?*Split {
        return m.splits.getPtr(s);
    }

    /// The split holding `n` and its index there.
    pub fn parentOf(m: *const DockModel, n: Node) ?struct { s: SplitId, i: usize } {
        var it = m.splits.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.children.items, 0..) |c, i| if (c.eql(n)) return .{ .s = e.key_ptr.*, .i = i };
        }
        return null;
    }

    /// The tree `n` is in.
    pub fn ownerOf(m: *const DockModel, n: Node) ?Owner {
        var top = n;
        while (m.parentOf(top)) |p| top = .{ .split = p.s };
        for (m.areas, 0..) |a, i| if (a.root) |r| if (r.eql(top)) return .{ .area = @enumFromInt(i) };
        for (m.floating.items) |f| if (f.root) |r| if (r.eql(top)) return .{ .float = f.id };
        return null;
    }

    /// The first group of a tree (depth-first), if any.
    pub fn firstGroup(m: *const DockModel, n: ?Node) ?GroupId {
        var cur = n orelse return null;
        while (true) switch (cur) {
            .group => |g| return g,
            .split => |s| {
                const sp = m.splits.getPtr(s) orelse return null;
                if (sp.children.items.len == 0) return null;
                cur = sp.children.items[0];
            },
        };
    }

    // -- operations ----------------------------------------------------

    /// A new panel, not open anywhere yet. `state` is copied.
    pub fn addPanel(m: *DockModel, kind: PanelKindId, state: ?[]const u8) Allocator.Error!PanelRef {
        const id: PanelRef = @enumFromInt(m.nextId());
        const st = if (state) |s| try m.gpa.dupe(u8, s) else null;
        errdefer if (st) |s| m.gpa.free(s);
        try m.panels.put(m.gpa, id, .{ .kind = kind, .state = st });
        return id;
    }

    /// Opens `p` in `g` at `index` (null: after the active tab; never
    /// before the pinned tabs), moving it from where it was. Within its
    /// own group, `index` reorders it (counting it at its old place). A preview
    /// open replaces the group's preview tab, which closes.
    pub fn openIn(m: *DockModel, p: PanelRef, g: GroupId, index: ?u32, opts: OpenOptions) Allocator.Error!void {
        if (!m.panels.contains(p) or !m.groups.contains(g)) return;
        try m.record();
        try m.openInRaw(p, g, index, opts);
        try m.normalize();
    }

    fn openInRaw(m: *DockModel, p: PanelRef, g: GroupId, index: ?u32, opts: OpenOptions) Allocator.Error!void {
        if (m.groupOf(p)) |from| {
            if (from == g) {
                // Already here: move it to `index` within its pinned or
                // unpinned run, and activate it (and pin a preview opened
                // again as a normal tab).
                const gr = m.groups.getPtr(g).?;
                if (!opts.preview and gr.preview == p) gr.preview = null;
                var i: u32 = @intCast(std.mem.indexOfScalar(PanelRef, gr.tabs.items, p).?);
                if (index) |want| {
                    const active = gr.tabs.items[gr.active];
                    const len: u32 = @intCast(gr.tabs.items.len);
                    var to = if (want > i) want - 1 else want;
                    to = if (i < gr.pinned) @min(to, gr.pinned - 1) else std.math.clamp(to, gr.pinned, len - 1);
                    _ = gr.tabs.orderedRemove(i);
                    gr.tabs.insertAssumeCapacity(to, p);
                    gr.active = @intCast(std.mem.indexOfScalar(PanelRef, gr.tabs.items, active).?);
                    i = to;
                }
                if (opts.activate) gr.active = i;
                return;
            }
            m.removeTab(from, p);
        }
        const gr = m.groups.getPtr(g).?;
        if (opts.preview) if (gr.preview) |old| {
            gr.preview = null;
            try m.closeRaw(old);
        };
        const len: u32 = @intCast(gr.tabs.items.len);
        var at = index orelse if (len == 0) 0 else gr.active + 1;
        at = std.math.clamp(at, gr.pinned, len);
        try gr.tabs.insert(m.gpa, at, p);
        if (opts.preview) gr.preview = p;
        if (opts.activate or len == 0) {
            gr.active = at;
            m.focused = g;
        } else if (gr.active >= at) gr.active += 1;
    }

    /// Takes `p` out of `g`'s tabs.
    fn removeTab(m: *DockModel, g: GroupId, p: PanelRef) void {
        const gr = m.groups.getPtr(g) orelse return;
        const i: u32 = @intCast(std.mem.indexOfScalar(PanelRef, gr.tabs.items, p) orelse return);
        _ = gr.tabs.orderedRemove(i);
        if (i < gr.pinned) gr.pinned -= 1;
        if (gr.preview == p) gr.preview = null;
        if (gr.active > i or (gr.active == i and gr.active > 0 and gr.active >= gr.tabs.items.len)) gr.active -= 1;
        if (gr.tabs.items.len == 0) gr.active = 0;
    }

    /// Turns the preview tab `p` into a normal tab (it was edited).
    pub fn pinPreview(m: *DockModel, p: PanelRef) void {
        const g = m.groupOf(p) orelse return;
        const gr = m.groups.getPtr(g).?;
        if (gr.preview == p) gr.preview = null;
    }

    /// Pins `p` (moves it after the other pinned tabs) or unpins it.
    pub fn setPinned(m: *DockModel, p: PanelRef, on: bool) Allocator.Error!void {
        const g = m.groupOf(p) orelse return;
        try m.record();
        const gr = m.groups.getPtr(g).?;
        const i: u32 = @intCast(std.mem.indexOfScalar(PanelRef, gr.tabs.items, p).?);
        const is_pinned = i < gr.pinned;
        if (is_pinned == on) return;
        const active = gr.tabs.items[gr.active];
        _ = gr.tabs.orderedRemove(i);
        if (on) {
            if (gr.preview == p) gr.preview = null;
            gr.tabs.insertAssumeCapacity(gr.pinned, p);
            gr.pinned += 1;
        } else {
            gr.pinned -= 1;
            gr.tabs.insertAssumeCapacity(gr.pinned, p);
        }
        gr.active = @intCast(std.mem.indexOfScalar(PanelRef, gr.tabs.items, active).?);
    }

    /// Opens `p` in a new group on `side` of `g`; returns the new group.
    pub fn split(m: *DockModel, g: GroupId, side: Side, p: PanelRef) Allocator.Error!?GroupId {
        if (!m.panels.contains(p) or !m.groups.contains(g)) return null;
        try m.record();
        const ng = try m.splitRaw(g, side);
        try m.openInRaw(p, ng, null, .{});
        try m.normalize();
        return if (m.groups.contains(ng)) ng else null;
    }

    fn splitRaw(m: *DockModel, g: GroupId, side: Side) Allocator.Error!GroupId {
        const axis: Axis = if (side == .left or side == .right) .row else .column;
        const before = side == .left or side == .top;
        const ng = try m.newGroup();
        const node: Node = .{ .group = g };
        if (m.parentOf(node)) |par| {
            const sp = m.splits.getPtr(par.s).?;
            if (sp.axis == axis) {
                const half = sp.ratios.items[par.i] / 2;
                sp.ratios.items[par.i] = half;
                const at = if (before) par.i else par.i + 1;
                try sp.children.insert(m.gpa, at, .{ .group = ng });
                try sp.ratios.insert(m.gpa, at, half);
                return ng;
            }
        }
        // Wrap `g` in a new split where it was.
        const owner = m.ownerOf(node);
        const parent = m.parentOf(node);
        const s = try m.newSplit(axis);
        const sp = m.splits.getPtr(s).?;
        try sp.children.appendSlice(m.gpa, if (before) &.{ .{ .group = ng }, node } else &.{ node, .{ .group = ng } });
        try sp.ratios.appendSlice(m.gpa, &.{ 0.5, 0.5 });
        if (parent) |par| {
            m.splits.getPtr(par.s).?.children.items[par.i] = .{ .split = s };
        } else if (owner) |o| m.setRoot(o, .{ .split = s });
        return ng;
    }

    /// Moves `p` (see `DropTarget`).
    pub fn move(m: *DockModel, p: PanelRef, to: DropTarget) Allocator.Error!void {
        if (!m.panels.contains(p)) return;
        switch (to) {
            .group => |t| return m.openIn(p, t.g, t.index, .{}),
            .split => |t| {
                _ = try m.split(t.g, t.side, p);
                return;
            },
            .area => |a| {
                try m.record();
                const g = m.firstGroup(m.areas[@intFromEnum(a)].root) orelse blk: {
                    const ng = try m.newGroup();
                    m.areas[@intFromEnum(a)].root = .{ .group = ng };
                    break :blk ng;
                };
                try m.openInRaw(p, g, null, .{});
            },
            .float => |r| {
                try m.record();
                const ng = try m.newGroup();
                try m.floating.append(m.gpa, .{ .id = @enumFromInt(m.nextId()), .rect = r, .root = .{ .group = ng } });
                try m.openInRaw(p, ng, null, .{});
            },
        }
        try m.normalize();
    }

    /// Closes `p` (it can be reopened with `reopenClosed`).
    pub fn close(m: *DockModel, p: PanelRef) Allocator.Error!void {
        if (!m.panels.contains(p)) return;
        try m.record();
        try m.closeRaw(p);
        try m.normalize();
    }

    fn closeRaw(m: *DockModel, p: PanelRef) Allocator.Error!void {
        const g = m.groupOf(p);
        if (g) |gg| m.removeTab(gg, p);
        const kv = m.panels.fetchSwapRemove(p) orelse return;
        m.closed.append(m.gpa, .{ .p = p, .panel = kv.value, .group = g }) catch |e| {
            if (kv.value.state) |s| m.gpa.free(s);
            return e;
        };
        // Keep the stack bounded.
        if (m.closed.items.len > undo_depth) {
            const old = m.closed.orderedRemove(0);
            if (old.panel.state) |s| m.gpa.free(s);
        }
    }

    /// Reopens the last closed panel where it was (or in the center).
    pub fn reopenClosed(m: *DockModel) Allocator.Error!?PanelRef {
        const c = m.closed.pop() orelse return null;
        m.panels.put(m.gpa, c.p, c.panel) catch |e| {
            m.closed.appendAssumeCapacity(c);
            return e;
        };
        try m.record();
        const g = if (c.group) |cg| (if (m.groups.contains(cg)) cg else try m.centerGroup()) else try m.centerGroup();
        try m.openInRaw(c.p, g, null, .{});
        try m.normalize();
        return c.p;
    }

    /// The center's first group, created when the center is empty.
    fn centerGroup(m: *DockModel) Allocator.Error!GroupId {
        const ci = @intFromEnum(Area.center);
        return m.firstGroup(m.areas[ci].root) orelse blk: {
            const ng = try m.newGroup();
            m.areas[ci].root = .{ .group = ng };
            break :blk ng;
        };
    }

    /// Sets a split's ratios (normalized to sum 1; non-positive entries
    /// get a small share). Ignored when the count does not match.
    pub fn setRatios(m: *DockModel, s: SplitId, ratios: []const f32) Allocator.Error!void {
        const sp = m.splits.getPtr(s) orelse return;
        if (ratios.len != sp.ratios.items.len) return;
        try m.record();
        for (sp.ratios.items, ratios) |*d, r| d.* = if (r > min_ratio and std.math.isFinite(r)) r else min_ratio;
        renormalize(sp.ratios.items);
    }

    /// Sets ratios without an undo step (live splitter drags; call
    /// `checkpoint` once when the gesture starts).
    pub fn setRatiosLive(m: *DockModel, s: SplitId, ratios: []const f32) void {
        const sp = m.splits.getPtr(s) orelse return;
        if (ratios.len != sp.ratios.items.len) return;
        @memcpy(sp.ratios.items, ratios);
        renormalize(sp.ratios.items);
        m.revision +%= 1;
    }

    /// Sets an area's size without an undo step (live resize drags; call
    /// `checkpoint` once when the gesture starts).
    pub fn setAreaSizeLive(m: *DockModel, a: Area, px: f32) void {
        if (!std.math.isFinite(px)) return;
        m.areas[@intFromEnum(a)].size = @max(0, px);
        m.revision +%= 1;
    }

    /// Records an undo step for a gesture made of live changes.
    pub fn checkpoint(m: *DockModel) Allocator.Error!void {
        try m.record();
    }

    /// Shows only `g` in the center, or everything again.
    pub fn toggleMaximize(m: *DockModel, g: GroupId) void {
        m.revision +%= 1;
        if (m.maximized) |cur| {
            m.maximized = null;
            if (cur == g) return;
        }
        const o = m.ownerOf(.{ .group = g }) orelse return;
        if (o != .area or o.area != .center) return;
        m.maximized = g;
    }

    /// Shows or hides an area (its panels stay open).
    pub fn areaVisible(m: *DockModel, a: Area, visible: bool) void {
        m.areas[@intFromEnum(a)].visible = visible;
        m.revision +%= 1;
    }

    /// Activates tab `i` of `g` and focuses `g`.
    pub fn activate(m: *DockModel, g: GroupId, i: u32) void {
        const gr = m.groups.getPtr(g) orelse return;
        if (i < gr.tabs.items.len) gr.active = i;
        m.focused = g;
        m.revision +%= 1;
    }

    /// The group next to `g` in `dir`, from the last laid-out rects (see
    /// `geometry.neighbor`).
    pub fn neighbor(_: *const DockModel, g: GroupId, dir: Dir, rects: []const GroupRect) ?GroupId {
        return @import("geometry.zig").neighbor(g, dir, rects);
    }

    /// Moves a floating window.
    pub fn setFloatRect(m: *DockModel, f: FloatId, r: Rect) void {
        const i = m.floatIndex(f) orelse return;
        m.floating.items[i].rect = r;
        m.revision +%= 1;
    }

    // -- normalization -------------------------------------------------

    const min_ratio: f32 = 1e-3;

    /// Scales `r` to sum 1. Only non-positive or non-finite entries are
    /// raised to `min_ratio`, so a normalized split stays as it is (a
    /// share that fell below `min_ratio` by the division survives a
    /// save and reload).
    fn renormalize(r: []f32) void {
        var sum: f32 = 0;
        for (r) |*x| {
            if (!(x.* > 0) or !std.math.isFinite(x.*)) x.* = min_ratio;
            sum += x.*;
        }
        for (r) |*x| x.* /= sum;
    }

    /// Restores the invariants after an operation.
    fn normalize(m: *DockModel) Allocator.Error!void {
        for (0..area_count) |i| {
            const a: Area = @enumFromInt(i);
            const root = m.areas[i].root orelse continue;
            // The center keeps one group, even empty.
            if (a == .center and root == .group) continue;
            m.areas[i].root = try m.normNode(root);
        }
        if (m.areas[@intFromEnum(Area.center)].root == null) _ = try m.centerGroup();
        var fi: usize = 0;
        while (fi < m.floating.items.len) {
            const f = &m.floating.items[fi];
            if (f.root) |r| f.root = try m.normNode(r);
            if (f.root == null) {
                _ = m.floating.orderedRemove(fi);
            } else fi += 1;
        }
        if (m.maximized) |g| if (!m.groups.contains(g)) {
            m.maximized = null;
        };
        if (m.focused) |g| if (!m.groups.contains(g)) {
            m.focused = m.firstGroup(m.areas[@intFromEnum(Area.center)].root);
        };
    }

    /// Normalizes the subtree at `n`; null when nothing is left.
    fn normNode(m: *DockModel, n: Node) Allocator.Error!?Node {
        switch (n) {
            .group => |g| {
                const gr = m.groups.getPtr(g) orelse return null;
                if (gr.tabs.items.len > 0) return n;
                var kv = m.groups.fetchSwapRemove(g).?;
                kv.value.tabs.deinit(m.gpa);
                return null;
            },
            .split => |s| {
                const sp0 = m.splits.getPtr(s) orelse return null;
                const axis = sp0.axis;
                var i: usize = 0;
                while (i < m.splits.getPtr(s).?.children.items.len) {
                    const sp = m.splits.getPtr(s).?;
                    const child = sp.children.items[i];
                    const r = sp.ratios.items[i];
                    const kept = try m.normNode(child);
                    const spn = m.splits.getPtr(s).?;
                    if (kept == null) {
                        _ = spn.children.orderedRemove(i);
                        _ = spn.ratios.orderedRemove(i);
                        continue;
                    }
                    spn.children.items[i] = kept.?;
                    // Flatten a same-axis child split into this one.
                    if (kept.? == .split) {
                        const cs = m.splits.getPtr(kept.?.split).?;
                        if (cs.axis == axis) {
                            var kv = m.splits.fetchSwapRemove(kept.?.split).?;
                            defer freeSplit(m.gpa, &kv.value);
                            const sp2 = m.splits.getPtr(s).?;
                            _ = sp2.children.orderedRemove(i);
                            _ = sp2.ratios.orderedRemove(i);
                            var sum: f32 = 0;
                            for (kv.value.ratios.items) |x| sum += x;
                            for (kv.value.children.items, kv.value.ratios.items, 0..) |c, x, k| {
                                try sp2.children.insert(m.gpa, i + k, c);
                                try sp2.ratios.insert(m.gpa, i + k, r * x / (if (sum > 0) sum else 1));
                            }
                            i += kv.value.children.items.len;
                            continue;
                        }
                    }
                    i += 1;
                }
                const sp = m.splits.getPtr(s).?;
                if (sp.children.items.len >= 2) {
                    renormalize(sp.ratios.items);
                    return n;
                }
                const only: ?Node = if (sp.children.items.len == 1) sp.children.items[0] else null;
                var kv = m.splits.fetchSwapRemove(s).?;
                freeSplit(m.gpa, &kv.value);
                return only;
            },
        }
    }

    // -- invariants ----------------------------------------------------

    pub const Invalid = error{Invalid};

    /// Checks the invariants (see the module doc); `error.Invalid` names
    /// the first failure in debug logs.
    pub fn validate(m: *const DockModel) Invalid!void {
        var seen_groups: usize = 0;
        var seen_splits: usize = 0;
        for (m.areas, 0..) |a, i| if (a.root) |r| try m.validateNode(r, null, @as(Area, @enumFromInt(i)) == .center, &seen_groups, &seen_splits, true);
        for (m.floating.items) |f| {
            const r = f.root orelse return fail("floating window without a tree");
            try m.validateNode(r, null, false, &seen_groups, &seen_splits, true);
        }
        if (m.areas[@intFromEnum(Area.center)].root == null) return fail("center has no tree");
        if (seen_groups != m.groups.count()) return fail("a group is not in any tree");
        if (seen_splits != m.splits.count()) return fail("a split is not in any tree");
        // Each panel in at most one group; every tab is a live panel.
        // (Tabs are counted against the panels' order, without allocating.)
        var total: usize = 0;
        var it = m.groups.iterator();
        while (it.next()) |e| for (e.value_ptr.tabs.items) |p| {
            if (!m.panels.contains(p)) return fail("a tab names a closed panel");
            total += 1;
        };
        var open: usize = 0;
        for (m.panels.keys()) |p| {
            var n: usize = 0;
            var it2 = m.groups.iterator();
            while (it2.next()) |e2| {
                if (std.mem.indexOfScalar(PanelRef, e2.value_ptr.tabs.items, p)) |i| {
                    n += 1;
                    if (std.mem.indexOfScalarPos(PanelRef, e2.value_ptr.tabs.items, i + 1, p) != null) n += 1;
                }
            }
            if (n > 1) return fail("a panel is in two groups");
            open += n;
        }
        if (open != total) return fail("a tab repeats");
        if (m.maximized) |g| if (!m.groups.contains(g)) return fail("maximized group is gone");
    }

    fn validateNode(m: *const DockModel, n: Node, parent_axis: ?Axis, center: bool, ng: *usize, ns: *usize, is_root: bool) Invalid!void {
        switch (n) {
            .group => |g| {
                const gr = m.groups.getPtr(g) orelse return fail("missing group");
                ng.* += 1;
                const len = gr.tabs.items.len;
                if (len == 0 and !(center and is_root)) return fail("empty group");
                if (len > 0 and gr.active >= len) return fail("active out of range");
                if (gr.pinned > len) return fail("pinned out of range");
                if (gr.preview) |p| {
                    const i = std.mem.indexOfScalar(PanelRef, gr.tabs.items, p) orelse return fail("preview not a tab");
                    if (i < gr.pinned) return fail("pinned preview");
                }
            },
            .split => |s| {
                const sp = m.splits.getPtr(s) orelse return fail("missing split");
                ns.* += 1;
                if (sp.children.items.len < 2) return fail("split with fewer than 2 children");
                if (sp.children.items.len != sp.ratios.items.len) return fail("ratio count");
                if (parent_axis) |pa| if (pa == sp.axis) return fail("same-axis nested split");
                var sum: f32 = 0;
                for (sp.ratios.items) |r| {
                    if (!(r > 0)) return fail("non-positive ratio");
                    sum += r;
                }
                if (@abs(sum - 1) > 1e-4) return fail("ratios do not sum to 1");
                for (sp.children.items) |c| try m.validateNode(c, sp.axis, center, ng, ns, false);
            },
        }
    }

    fn fail(comptime why: []const u8) Invalid {
        std.log.scoped(.dock).debug("invalid layout: " ++ why, .{});
        return error.Invalid;
    }

    // -- snapshots and undo --------------------------------------------

    /// A copy of the layout.
    pub fn snapshot(m: *const DockModel, gpa: Allocator) Allocator.Error!Snapshot {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const groups = try a.alloc(Snapshot.GroupSnap, m.groups.count());
        for (m.groups.keys(), m.groups.values(), groups) |id, g, *o| o.* = .{ .id = id, .tabs = try a.dupe(PanelRef, g.tabs.items), .active = g.active, .pinned = g.pinned, .preview = g.preview };
        const splits = try a.alloc(Snapshot.SplitSnap, m.splits.count());
        for (m.splits.keys(), m.splits.values(), splits) |id, s, *o| o.* = .{ .id = id, .axis = s.axis, .children = try a.dupe(Node, s.children.items), .ratios = try a.dupe(f32, s.ratios.items) };
        const floating = try a.dupe(Floating, m.floating.items);
        // The arena is copied last, after its final allocation.
        return .{ .arena = arena, .groups = groups, .splits = splits, .areas = m.areas, .floating = floating, .maximized = m.maximized };
    }

    /// Replaces the layout with `s` (see the module doc for panels).
    pub fn restore(m: *DockModel, s: *const Snapshot) Allocator.Error!void {
        const gpa = m.gpa;
        m.revision +%= 1;
        // Build the new maps first so a failure leaves the model as it was.
        var groups: std.AutoArrayHashMapUnmanaged(GroupId, Group) = .empty;
        errdefer {
            for (groups.values()) |*g| g.tabs.deinit(gpa);
            groups.deinit(gpa);
        }
        for (s.groups) |g| {
            var tabs: std.ArrayList(PanelRef) = .empty;
            errdefer tabs.deinit(gpa);
            var pinned = g.pinned;
            for (g.tabs, 0..) |p, i| {
                if (m.panels.contains(p)) {
                    try tabs.append(gpa, p);
                } else if (i < g.pinned) pinned -= 1;
            }
            const len: u32 = @intCast(tabs.items.len);
            try groups.put(gpa, g.id, .{
                .tabs = tabs,
                .active = if (len == 0) 0 else @min(g.active, len - 1),
                .pinned = @min(pinned, len),
                .preview = if (g.preview) |p| (if (std.mem.indexOfScalar(PanelRef, tabs.items, p) != null) p else null) else null,
            });
        }
        var splits: std.AutoArrayHashMapUnmanaged(SplitId, Split) = .empty;
        errdefer {
            for (splits.values()) |*sp| freeSplit(gpa, sp);
            splits.deinit(gpa);
        }
        for (s.splits) |sp| {
            var v: Split = .{ .axis = sp.axis };
            errdefer freeSplit(gpa, &v);
            try v.children.appendSlice(gpa, sp.children);
            try v.ratios.appendSlice(gpa, sp.ratios);
            try splits.put(gpa, sp.id, v);
        }
        var floating: std.ArrayList(Floating) = .empty;
        errdefer floating.deinit(gpa);
        try floating.appendSlice(gpa, s.floating);
        // Panels open now but not in the snapshot.
        var orphans: std.ArrayList(PanelRef) = .empty;
        defer orphans.deinit(gpa);
        for (m.panels.keys()) |p| {
            if (m.groupOf(p) == null) continue;
            var found = false;
            for (groups.values()) |g| if (std.mem.indexOfScalar(PanelRef, g.tabs.items, p) != null) {
                found = true;
                break;
            };
            if (!found) try orphans.append(gpa, p);
        }

        for (m.groups.values()) |*g| g.tabs.deinit(gpa);
        m.groups.deinit(gpa);
        for (m.splits.values()) |*sp| freeSplit(gpa, sp);
        m.splits.deinit(gpa);
        m.floating.deinit(gpa);
        m.groups = groups;
        m.splits = splits;
        m.floating = floating;
        m.areas = s.areas;
        m.maximized = s.maximized;
        groups = .empty;
        splits = .empty;
        floating = .empty;
        if (orphans.items.len > 0) {
            const g = try m.centerGroup();
            for (orphans.items) |p| try m.openInRaw(p, g, null, .{ .activate = false });
        }
        try m.normalize();
        if (m.focused) |g| if (!m.groups.contains(g)) {
            m.focused = null;
        };
        if (m.focused == null) m.focused = m.firstGroup(m.areas[@intFromEnum(Area.center)].root);
    }

    /// Saves the layout for `undo` (the ring drops the oldest).
    fn record(m: *DockModel) Allocator.Error!void {
        m.revision +%= 1;
        if (!m.history) return;
        const snap = try m.snapshot(m.gpa);
        const slot = &m.undo_ring[m.undo_head];
        if (slot.*) |*old| old.deinit();
        slot.* = snap;
        m.undo_head = (m.undo_head + 1) % undo_depth;
    }

    /// Restores the layout before the last operation; false when there is
    /// nothing to undo.
    pub fn undo(m: *DockModel) Allocator.Error!bool {
        const i = (m.undo_head + undo_depth - 1) % undo_depth;
        var snap = m.undo_ring[i] orelse return false;
        m.undo_ring[i] = null;
        m.undo_head = i;
        defer snap.deinit();
        try m.restore(&snap);
        return true;
    }
};
