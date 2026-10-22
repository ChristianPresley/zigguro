//! `A11yTree` (E04.F09.S01.T01): a window's semantic tree for assistive
//! technology, derived from the `NodeStore` after each frame, published as
//! an immutable `Snapshot` for bridges on other threads (UIA, AT-SPI) and
//! diffed into an `Update` (added, changed and removed nodes plus events).
//!
//! - Inclusion: the window and every node whose widget gives a role other
//!   than `.none`. Layout boxes are pruned and their children hoisted to
//!   the nearest included ancestor. Hidden nodes and their subtrees are
//!   left out.
//! - Names: the widget's (its label, or `a11y_label`), else its tooltip,
//!   so icon-only buttons are named.
//! - Ids: `(window << 32) | (gen << 24 | index)`, stable while a node
//!   lives and different after its index is reused.
//! - Modal: while a modal overlay is open only it (and the window) is in
//!   the tree; the background is inert.
//! - Virtual collections give their full row count (`row_count`) and each
//!   row its position (`row_index`); `scroll_into_view` with an index on
//!   the collection scrolls a row that isn't built yet into view.
//! - Cost: nothing while inactive (bridges `activate` it when a client
//!   appears); `query` builds on demand for tests either way.
//!
//! Actions (`performAction`) are queued from any thread and run on the UI
//! thread: the widget's `a11yAction` first, else the default (a click at
//! the node's centre, or focus and Enter when something covers it; focus;
//! scrolling ancestors; a right click for `show_menu`).

const std = @import("std");
const zg_platform = @import("zg_platform");
const widget = @import("../core/widget.zig");
const ids = @import("../core/ids.zig");
const geom = @import("../core/geom.zig");
const window_mod = @import("../core/window.zig");
const app_mod = @import("../core/app.zig");
const tooltip = @import("../widgets/tooltip.zig");
const event_mod = @import("../input/event.zig");
const snap = @import("snapshot.zig");

const Allocator = std.mem.Allocator;
const NodeId = ids.NodeId;
const Window = window_mod.Window;
const Wyhash = std.hash.Wyhash;

pub const Snapshot = snap.Snapshot;
pub const Node = snap.Node;
pub const State = snap.State;
pub const Publisher = snap.Publisher;
pub const Action = widget.A11yAction;
pub const Arg = widget.A11yArg;

/// What changed, for bridges to raise as platform events.
pub const A11yEvent = union(enum) {
    focus_changed: u64,
    value_changed: u64,
    /// `mask`: the state bits that flipped.
    state_changed: struct { id: u64, mask: State },
    children_changed: u64,
    name_changed: u64,
    /// An editable node's text: `removed` bytes at `start` were replaced
    /// by `inserted` bytes.
    text_changed: struct { id: u64, start: u32, removed: u32, inserted: u32 },
    announcement: struct { text: []const u8, assertive: bool },
    menu_opened: u64,
    menu_closed: u64,
};

/// One frame's changes; valid until the next `update`.
pub const Update = struct {
    snapshot: *const Snapshot,
    added: []const u64,
    changed: []const u64,
    removed: []const u64,
    events: []const A11yEvent,
};

/// Called with each update (UI thread).
pub const Listener = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, u: *const Update) void,
};

/// Work counters (tests check that an inactive tree costs nothing).
pub const Stats = struct {
    builds: u64 = 0,
    updates: u64 = 0,
    actions: u64 = 0,
};

const Queued = struct { id: u64, action: Action, arg: ?Arg };

const Announcement = struct { text: []u8, assertive: bool };

/// See the module doc. Must not move after `attach`.
pub const A11yTree = struct {
    gpa: Allocator,
    window_id: u32,
    publisher: Publisher,
    active: std.atomic.Value(bool) = .init(false),
    win: ?*Window = null,
    listener: ?Listener = null,
    stats: Stats = .{},
    /// The last update's lists.
    upd: std.heap.ArenaAllocator,
    last: ?Update = null,
    announcements: std.ArrayList(Announcement) = .empty,
    /// Actions from any thread, guarded by `queue_lock`.
    queue: std.ArrayList(Queued) = .empty,
    queue_lock: std.atomic.Value(bool) = .init(false),
    posted: std.atomic.Value(bool) = .init(false),
    /// The snapshot being built, in its arena (UI thread).
    nodes: std.ArrayList(Node) = .empty,
    /// The last snapshot's size, to reserve for the next.
    last_len: usize = 0,

    pub fn init(gpa: Allocator, window_id: u32) A11yTree {
        return .{ .gpa = gpa, .window_id = window_id, .publisher = .init(gpa), .upd = .init(gpa) };
    }

    /// Detaches and frees everything. No reader may hold a snapshot.
    pub fn deinit(t: *A11yTree) void {
        t.detach();
        t.publisher.deinit();
        t.upd.deinit();
        for (t.announcements.items) |a| t.gpa.free(a.text);
        t.announcements.deinit(t.gpa);
        for (t.queue.items) |q| freeArg(t.gpa, q.arg);
        t.queue.deinit(t.gpa);
    }

    /// Follows `win`: it calls `update` after each frame it paints.
    pub fn attach(t: *A11yTree, win: *Window) void {
        t.win = win;
        win.a11y = t;
        if (t.active.load(.acquire)) win.needs_frame = true;
    }

    pub fn detach(t: *A11yTree) void {
        if (t.win) |w| if (w.a11y == t) {
            w.a11y = null;
        };
        t.win = null;
    }

    /// Bridges turn the tree on when a client appears and off when it
    /// leaves (any thread). Turning on schedules a frame so the first
    /// update comes at once.
    pub fn activate(t: *A11yTree, on: bool) void {
        if (t.active.swap(on, .acq_rel) == on or !on) return;
        const w = t.win orelse return;
        t.postUi(w, wakeOnUi);
    }

    fn wakeOnUi(ctx: *anyopaque, _: *app_mod.App) void {
        const t: *A11yTree = @ptrCast(@alignCast(ctx));
        t.posted.store(false, .release);
        if (t.win) |w| {
            w.needs_frame = true;
            t.runActions(w);
        }
    }

    /// Posts `f` to the UI thread once until it runs. Without a runtime
    /// (tests) the caller must be on the UI thread.
    fn postUi(t: *A11yTree, w: *Window, f: *const fn (*anyopaque, *app_mod.App) void) void {
        if (t.posted.swap(true, .acq_rel)) return;
        w.app.post(.{ .ctx = t, .f = f }) catch t.posted.store(false, .release);
    }

    /// The current snapshot with a reference held (any thread); release
    /// it with `Snapshot.release`.
    pub fn snapshot(t: *A11yTree) ?*Snapshot {
        return t.publisher.acquire();
    }

    /// Builds and publishes a snapshot of `win` now, active or not (UI
    /// thread; for tests and on-demand queries). Valid until the next
    /// `update` or `query`.
    pub fn query(t: *A11yTree, win: *Window) Allocator.Error!*const Snapshot {
        const s = try t.build(win);
        t.publisher.publish(s);
        return s;
    }

    /// Queues a message for screen readers (toasts, notifications); it goes
    /// out with the next update (UI thread).
    pub fn announce(t: *A11yTree, text: []const u8, assertive: bool) void {
        if (!t.active.load(.acquire)) return;
        const copy = t.gpa.dupe(u8, text) catch return;
        t.announcements.append(t.gpa, .{ .text = copy, .assertive = assertive }) catch {
            t.gpa.free(copy);
            return;
        };
        if (t.win) |w| w.needs_frame = true;
    }

    /// Diffs `win` against the last snapshot and publishes the new one
    /// (UI thread, after paint). Null when inactive or nothing changed.
    pub fn update(t: *A11yTree, win: *Window) ?*const Update {
        if (!t.active.load(.acquire)) return null;
        t.runActions(win);
        const old = t.publisher.peek();
        const s = t.build(win) catch return null;
        _ = t.upd.reset(.retain_capacity);
        const u = t.diff(old, s) catch return null;
        for (t.announcements.items) |a| t.gpa.free(a.text);
        t.announcements.clearRetainingCapacity();
        if (old != null and old.?.active == s.active and u.added.len == 0 and u.changed.len == 0 and u.removed.len == 0 and u.events.len == 0) return null;
        t.publisher.publish(s);
        t.stats.updates += 1;
        t.last = u;
        if (t.listener) |l| l.f(l.ctx, &t.last.?);
        return &t.last.?;
    }

    // -- building -----------------------------------------------------------------

    var dummy_state: u8 = 0;

    fn build(t: *A11yTree, win: *Window) Allocator.Error!*Snapshot {
        t.stats.builds += 1;
        const s = try t.publisher.fresh();
        const a = s.arena.allocator();
        t.nodes = .empty;
        try t.nodes.ensureTotalCapacity(a, t.last_len + 16);
        const modal: NodeId = if (win.overlays.topModal()) |e| e.panel else .none;
        t.nodes.appendAssumeCapacity(.{
            .id = snap.idOf(t.window_id, win.root),
            .parent = Node.no_parent,
            .role = .window,
            .bounds = .{ 0, 0, win.size.w, win.size.h },
            .node = win.root,
        });
        var it = win.store.children(win.root);
        while (it.next()) |c| try t.walk(win, a, c, 0, modal);

        const nodes = t.nodes.items;
        t.last_len = nodes.len;
        t.nodes = .empty;
        // Children, in order: count per parent, then fill.
        for (nodes[1..]) |n| nodes[n.parent].kids_len += 1;
        var at: u32 = 0;
        for (nodes) |*n| {
            n.kids_start = at;
            at += n.kids_len;
            n.kids_len = 0;
        }
        const kids = try a.alloc(u32, nodes.len -| 1);
        for (nodes[1..], 1..) |n, i| {
            const p = &nodes[n.parent];
            kids[p.kids_start + p.kids_len] = @intCast(i);
            p.kids_len += 1;
        }
        try s.index.ensureTotalCapacity(a, @intCast(nodes.len));
        for (nodes, 0..) |n, i| s.index.putAssumeCapacity(n.id, @intCast(i));
        s.nodes = nodes;
        s.kids = kids;
        s.window = t.window_id;
        s.scale = win.scale;
        s.screen_origin = if (win.screen_origin_px) |o| .{ o.x, o.y } else null;
        s.active = win.chrome.focused;
        const fid = snap.idOf(t.window_id, win.focus);
        s.focus = if (!win.focus.isNone() and s.index.contains(fid)) fid else 0;
        return s;
    }

    fn walk(t: *A11yTree, win: *Window, a: Allocator, n: NodeId, parent: u32, modal: NodeId) Allocator.Error!void {
        const store = &win.store;
        const fl = store.flags(n).*;
        if (fl.hidden) return;
        // Behind a modal overlay: only the path to it and its inside count.
        if (!modal.isNone() and !n.eql(modal) and !store.isAncestor(n, modal) and !store.isAncestor(modal, n)) return;
        var me = parent;
        const kind = store.hot.items(.kind)[n.index];
        const vt = widget.vtable(kind);
        if (vt.a11y) |f| if (store.props(n)) |props| {
            const st: *anyopaque = store.hot.items(.state)[n.index] orelse @ptrCast(&dummy_state);
            const info = f(props, st);
            if (info.role != .none) {
                var name = info.name;
                if (name.len == 0) name = tooltipOf(win, n);
                const r = store.absRect(n);
                const offscreen = !fl.painted or r.w <= 0 or r.h <= 0 or
                    r.x >= win.size.w or r.y >= win.size.h or r.x + r.w <= 0 or r.y + r.h <= 0;
                var node: Node = .{
                    .id = snap.idOf(t.window_id, n),
                    .parent = parent,
                    .role = info.role,
                    .name = if (name.len > 0) try a.dupe(u8, name) else "",
                    .text = if (info.text.len > 0) try a.dupe(u8, info.text) else "",
                    .state = .{
                        .focusable = vt.focusable or fl.focusable,
                        .focused = win.focus.eql(n),
                        .checkable = info.checked != null,
                        .checked = info.checked orelse false,
                        .expandable = info.expanded != null,
                        .expanded = info.expanded orelse false,
                        .selectable = info.selected != null,
                        .selected = info.selected orelse false,
                        .disabled = info.disabled or fl.disabled,
                        .offscreen = offscreen,
                        .modal = n.eql(modal),
                        .editable = info.role == .textbox,
                    },
                    .value = info.value,
                    .level = info.level,
                    .row_count = info.row_count,
                    .col_count = info.col_count,
                    .row_index = info.row_index,
                    .col_index = info.col_index,
                    .sort = info.sort,
                    .bounds = .{ r.x, r.y, r.w, r.h },
                    .test_id = store.coldOf(n).test_id,
                    .node = n,
                };
                node.hash = hashNode(&node);
                me = @intCast(t.nodes.items.len);
                try t.nodes.append(a, node);
            }
        };
        var it = store.children(n);
        while (it.next()) |c| try t.walk(win, a, c, me, modal);
    }

    // -- diffing ------------------------------------------------------------------

    fn diff(t: *A11yTree, old: ?*const Snapshot, s: *const Snapshot) Allocator.Error!Update {
        const a = t.upd.allocator();
        var added: std.ArrayList(u64) = .empty;
        var changed: std.ArrayList(u64) = .empty;
        var removed: std.ArrayList(u64) = .empty;
        var events: std.ArrayList(A11yEvent) = .empty;
        for (s.nodes, 0..) |*n, i| {
            // Mostly the tree keeps its shape: try the same position first.
            const o = if (old) |os| (if (i < os.nodes.len and os.nodes[i].id == n.id) &os.nodes[i] else os.find(n.id)) else null;
            const p = o orelse {
                try added.append(a, n.id);
                if (n.role == .menu) try events.append(a, .{ .menu_opened = n.id });
                continue;
            };
            const kids_differ = !sameKids(old.?, p, s, n);
            if (p.hash != n.hash or kids_differ) try changed.append(a, n.id);
            if (kids_differ) try events.append(a, .{ .children_changed = n.id });
            if (!std.mem.eql(u8, p.name, n.name)) try events.append(a, .{ .name_changed = n.id });
            const watched: u16 = (State{ .checked = true, .expanded = true, .selected = true, .disabled = true, .offscreen = true }).bits();
            const flipped = (p.state.bits() ^ n.state.bits()) & watched;
            if (flipped != 0) try events.append(a, .{ .state_changed = .{ .id = n.id, .mask = @bitCast(flipped) } });
            if (p.value != n.value) try events.append(a, .{ .value_changed = n.id });
            if (!std.mem.eql(u8, p.text, n.text)) {
                const e = textEdit(p.text, n.text);
                try events.append(a, .{ .text_changed = .{ .id = n.id, .start = e[0], .removed = e[1], .inserted = e[2] } });
                try events.append(a, .{ .value_changed = n.id });
            }
        }
        if (old) |os| for (os.nodes, 0..) |*o, i| if (!(i < s.nodes.len and s.nodes[i].id == o.id) and !s.index.contains(o.id)) {
            try removed.append(a, o.id);
            if (o.role == .menu) try events.append(a, .{ .menu_closed = o.id });
        };
        const old_focus = if (old) |os| os.focus else 0;
        if (s.focus != old_focus and s.focus != 0) try events.append(a, .{ .focus_changed = s.focus });
        for (t.announcements.items) |an| try events.append(a, .{ .announcement = .{ .text = try a.dupe(u8, an.text), .assertive = an.assertive } });
        return .{ .snapshot = s, .added = added.items, .changed = changed.items, .removed = removed.items, .events = events.items };
    }

    // -- actions ------------------------------------------------------------------

    /// Asks node `id` to do `action` (any thread). It runs on the UI thread
    /// against the current snapshot; a stale id is ignored.
    pub fn performAction(t: *A11yTree, id: u64, action: Action, arg: ?Arg) void {
        const owned: ?Arg = if (arg) |x| switch (x) {
            .text => |s| .{ .text = t.gpa.dupe(u8, s) catch return },
            else => x,
        } else null;
        t.lock();
        t.queue.append(t.gpa, .{ .id = id, .action = action, .arg = owned }) catch {
            t.unlock();
            freeArg(t.gpa, owned);
            return;
        };
        t.unlock();
        const w = t.win orelse return;
        t.postUi(w, wakeOnUi);
    }

    fn lock(t: *A11yTree) void {
        while (t.queue_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(t: *A11yTree) void {
        t.queue_lock.store(false, .release);
    }

    /// Runs the queued actions (UI thread).
    pub fn runActions(t: *A11yTree, w: *Window) void {
        while (true) {
            t.lock();
            if (t.queue.items.len == 0) {
                t.unlock();
                return;
            }
            const q = t.queue.orderedRemove(0);
            t.unlock();
            t.perform(w, q);
            freeArg(t.gpa, q.arg);
        }
    }

    fn perform(t: *A11yTree, w: *Window, q: Queued) void {
        const s = t.publisher.peek() orelse return;
        const sn = s.find(q.id) orelse return;
        const n = sn.node;
        if (!w.store.valid(n)) return;
        t.stats.actions += 1;
        w.needs_frame = true;
        const store = &w.store;
        const vt = widget.vtable(store.hot.items(.kind)[n.index]);
        if (vt.a11yAction) |f| if (store.props(n)) |props| {
            const st: *anyopaque = store.hot.items(.state)[n.index] orelse @ptrCast(&dummy_state);
            if (f(props, st, q.action, q.arg)) return;
        };
        switch (q.action) {
            .focus => focusNode(w, n),
            .scroll_into_view => scrollIntoView(w, n),
            .set_value => {},
            .show_menu => {
                scrollIntoView(w, n);
                click(w, n, .right);
            },
            .invoke, .toggle, .expand, .collapse, .select, .add_to_selection, .remove_from_selection => {
                scrollIntoView(w, n);
                const r = store.absRect(n);
                const h = w.hitTest(center(r));
                if (!h.isNone() and (h.eql(n) or store.isAncestor(n, h) or store.isAncestor(h, n))) {
                    click(w, n, .left);
                } else if (store.flags(n).focusable or vt.focusable) {
                    w.setFocus(n, true);
                    const key: zg_platform.keys.Key = if (q.action == .toggle) .space else .enter;
                    w.dispatch(.{ .key = .{ .key = key, .mods = .{} } });
                    w.dispatch(.{ .key = .{ .key = key, .mods = .{}, .action = .release } });
                }
            },
        }
    }
};

fn freeArg(gpa: Allocator, arg: ?Arg) void {
    if (arg) |x| switch (x) {
        .text => |s| gpa.free(s),
        else => {},
    };
}

fn center(r: geom.Rect) geom.Vec2 {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

/// A press and release at the centre of `n`; the pointer goes back.
fn click(w: *Window, n: NodeId, button: event_mod.Button) void {
    const p = center(w.store.absRect(n));
    const back = w.pointer;
    w.dispatch(.{ .pointer_move = .{ .pos = p } });
    w.dispatch(.{ .pointer_down = .{ .pos = p, .button = button } });
    w.dispatch(.{ .pointer_up = .{ .pos = p, .button = button } });
    if (back.x >= 0 and back.y >= 0) w.dispatch(.{ .pointer_move = .{ .pos = back } });
}

/// Focuses `n` or its nearest focusable ancestor.
fn focusNode(w: *Window, n: NodeId) void {
    var p = n;
    while (!p.isNone()) : (p = w.store.parent(p)) {
        const vt = widget.vtable(w.store.hot.items(.kind)[p.index]);
        if (w.store.flags(p).focusable or vt.focusable) {
            w.setFocus(p, true);
            return;
        }
    }
}

/// Scrolls every scrolling ancestor of `n` so it shows.
fn scrollIntoView(w: *Window, n: NodeId) void {
    var r = w.store.absRect(n);
    var a = w.store.parent(n);
    while (!a.isNone()) : (a = w.store.parent(a)) {
        if (!w.store.coldOf(a).style.scrolls()) continue;
        const v = w.store.absRect(a);
        const d: geom.Vec2 = .{ .x = overflow(r.x, r.w, v.x, v.w), .y = overflow(r.y, r.h, v.y, v.h) };
        if (d.x == 0 and d.y == 0) continue;
        const before = w.scrollOffset(a);
        if (w.scrollBy(a, d)) {
            const after = w.scrollOffset(a);
            r.x -= after.x - before.x;
            r.y -= after.y - before.y;
        }
    }
}

/// How far a span `[x, x + len)` must move to fit in `[vx, vx + vlen)`:
/// its start shows first when it is longer.
fn overflow(x: f32, len: f32, vx: f32, vlen: f32) f32 {
    if (x < vx) return x - vx;
    if (x + len > vx + vlen) return @min(x - vx, x + len - (vx + vlen));
    return 0;
}

/// The tooltip text of `n` (empty when it has none).
fn tooltipOf(w: *Window, n: NodeId) []const u8 {
    const kinds = w.store.hot.items(.kind);
    const slot = widget.kindOf(tooltip.Slot);
    var it = w.store.children(n);
    while (it.next()) |c| if (kinds[c.index] == slot) {
        const sp: *const tooltip.Slot.Props = @ptrCast(@alignCast(w.store.props(c) orelse continue));
        if (!sp.prev) return sp.text;
    };
    const next = w.store.hot.items(.next_sibling)[n.index];
    if (!next.isNone() and kinds[next.index] == slot) {
        if (w.store.props(next)) |pp| {
            const sp: *const tooltip.Slot.Props = @ptrCast(@alignCast(pp));
            if (sp.prev) return sp.text;
        }
    }
    return "";
}

fn hashNode(n: *const Node) u64 {
    // The scalars in one block, then the strings.
    const Pod = extern struct {
        bounds: [4]f32,
        row_count: u64,
        row_index: u64,
        value: f32,
        col_count: u32,
        col_index: u32,
        state: u16,
        level: u16,
        role: u8,
        sort: u8,
        has_value: u8,
        _pad: [5]u8 = .{0} ** 5,
    };
    const pod: Pod = .{
        .bounds = n.bounds,
        .row_count = n.row_count,
        .row_index = n.row_index,
        .value = n.value orelse 0,
        .col_count = n.col_count,
        .col_index = n.col_index,
        .state = n.state.bits(),
        .level = n.level,
        .role = @intFromEnum(n.role),
        .sort = @intFromEnum(n.sort),
        .has_value = @intFromBool(n.value != null),
    };
    var h = Wyhash.hash(0xa11, std.mem.asBytes(&pod));
    if (n.name.len > 0) h = Wyhash.hash(h, n.name);
    if (n.text.len > 0) h = Wyhash.hash(h ^ 0x7e, n.text);
    return h;
}

fn sameKids(os: *const Snapshot, o: *const Node, s: *const Snapshot, n: *const Node) bool {
    const ok = os.children(o);
    const nk = s.children(n);
    if (ok.len != nk.len) return false;
    for (ok, nk) |x, y| if (os.nodes[x].id != s.nodes[y].id) return false;
    return true;
}

/// The edit turning `a` into `b`: start, bytes removed, bytes inserted
/// (common prefix and suffix trimmed).
fn textEdit(a: []const u8, b: []const u8) [3]u32 {
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and a[pre] == b[pre]) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and a[a.len - 1 - suf] == b[b.len - 1 - suf]) suf += 1;
    return .{ @intCast(pre), @intCast(a.len - pre - suf), @intCast(b.len - pre - suf) };
}

/// The tree as indented lines `role "name" states` (for goldens).
pub fn dump(s: *const Snapshot, gpa: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (s.root()) |r| try dumpNode(s, gpa, &out, r, 0);
    return out.toOwnedSlice(gpa);
}

fn dumpNode(s: *const Snapshot, gpa: Allocator, out: *std.ArrayList(u8), n: *const Node, depth: usize) Allocator.Error!void {
    try out.appendNTimes(gpa, ' ', depth * 2);
    try out.print(gpa, "{t}", .{n.role});
    if (n.name.len > 0) try out.print(gpa, " \"{s}\"", .{n.name});
    if (n.text.len > 0) try out.print(gpa, " text=\"{s}\"", .{n.text});
    const st = n.state;
    if (st.checkable) try out.print(gpa, " checked={}", .{st.checked});
    if (n.value) |v| try out.print(gpa, " value={d:.2}", .{v});
    if (st.expandable) try out.print(gpa, " expanded={}", .{st.expanded});
    if (st.selected) try out.appendSlice(gpa, " selected");
    if (n.level > 0) try out.print(gpa, " level={d}", .{n.level});
    if (n.row_count > 0) try out.print(gpa, " rows={d}", .{n.row_count});
    if (n.col_count > 0) try out.print(gpa, " cols={d}", .{n.col_count});
    if (n.row_index > 0) try out.print(gpa, " row={d}", .{n.row_index});
    if (n.col_index > 0) try out.print(gpa, " col={d}", .{n.col_index});
    if (st.disabled) try out.appendSlice(gpa, " disabled");
    if (st.focused) try out.appendSlice(gpa, " focused");
    if (st.modal) try out.appendSlice(gpa, " modal");
    if (st.offscreen) try out.appendSlice(gpa, " offscreen");
    try out.append(gpa, '\n');
    for (s.children(n)) |k| try dumpNode(s, gpa, out, &s.nodes[k], depth + 1);
}
