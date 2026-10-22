//! Reconciliation tests (E04.F01.S01.T01).

const std = @import("std");
const ids = @import("ids.zig");
const ui_mod = @import("ui.zig");
const view_mod = @import("view.zig");
const controls = @import("../widgets/controls.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const NodeId = ids.NodeId;
const Ui = ui_mod.Ui;

/// A leaf whose state remembers the item it was created for.
const Tag = struct {
    pub const name = "tag";
    pub const Props = struct { item: u32 };
    pub const State = struct { item: u32 = 0, set: bool = false };
};

var deinit_count: u32 = 0;

const Counted = struct {
    pub const name = "counted";
    pub const Props = struct { n: u32 = 0 };
    pub const State = struct { alive: bool = true };
    pub fn deinitState(s: *State) void {
        std.debug.assert(s.alive);
        s.alive = false;
        deinit_count += 1;
    }
};

const ListView = struct {
    items: std.ArrayList(u32) = .empty,
    builds: u32 = 0,
    counted: bool = false,

    pub fn build(self: *ListView, ui: *Ui) void {
        self.builds += 1;
        ui.open(.{ .test_id = "list", .style = .{ .dir = .column } });
        defer ui.close();
        for (self.items.items) |it| {
            ui.id(it);
            if (self.counted) {
                _ = ui.leaf(Counted, .{ .n = it });
            } else {
                _ = ui.leaf(Tag, .{ .item = it });
                const st = ui.lastState(Tag).?;
                if (!st.set) {
                    st.item = it;
                    st.set = true;
                }
            }
        }
    }
};

fn children(t: *TestApp, parent: NodeId, out: *std.ArrayList(NodeId)) !void {
    out.clearRetainingCapacity();
    var it = t.win.store.children(parent);
    while (it.next()) |c| try out.append(std.testing.allocator, c);
}

fn rebuild(t: *TestApp) void {
    t.win.markAllDirty();
    _ = t.frame();
}

test "stable ids on identical rebuild" {
    const gpa = std.testing.allocator;
    var v: ListView = .{};
    defer v.items.deinit(gpa);
    for (0..100) |i| try v.items.append(gpa, @intCast(i));
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.frame();
    const list = t.find(.{ .test_id = "list" }).?;
    var before: std.ArrayList(NodeId) = .empty;
    defer before.deinit(gpa);
    var after: std.ArrayList(NodeId) = .empty;
    defer after.deinit(gpa);
    try children(t, list, &before);
    const live = t.win.store.live;
    rebuild(t);
    try children(t, list, &after);
    try std.testing.expectEqualSlices(NodeId, before.items, after.items);
    try std.testing.expectEqual(live, t.win.store.live);
    try std.testing.expectEqual(@as(u32, 2), v.builds);
}

test "keyed permutation preserves state" {
    const gpa = std.testing.allocator;
    var v: ListView = .{};
    defer v.items.deinit(gpa);
    const n = 10_000;
    for (0..n) |i| try v.items.append(gpa, @intCast(i + 1));
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.frame();
    const list = t.find(.{ .test_id = "list" }).?;
    var prng = std.Random.DefaultPrng.init(0x4704);
    var kids: std.ArrayList(NodeId) = .empty;
    defer kids.deinit(gpa);
    const by_item = try gpa.alloc(NodeId, n + 1);
    defer gpa.free(by_item);
    try children(t, list, &kids);
    for (kids.items, v.items.items) |k, item| by_item[item] = k;
    const live = t.win.store.live;
    for (0..5) |_| {
        prng.random().shuffle(u32, v.items.items);
        rebuild(t);
        try children(t, list, &kids);
        try std.testing.expectEqual(@as(usize, n), kids.items.len);
        for (kids.items, v.items.items) |k, item| {
            try std.testing.expect(k.eql(by_item[item]));
            const st: *Tag.State = @ptrCast(@alignCast(t.win.store.hot.items(.state)[k.index].?));
            try std.testing.expectEqual(item, st.item);
        }
        try std.testing.expectEqual(live, t.win.store.live);
    }
}

test "insert/remove middle" {
    const gpa = std.testing.allocator;
    var v: ListView = .{};
    defer v.items.deinit(gpa);
    try v.items.appendSlice(gpa, &.{ 1, 2, 3, 4 });
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.frame();
    const list = t.find(.{ .test_id = "list" }).?;
    var kids: std.ArrayList(NodeId) = .empty;
    defer kids.deinit(gpa);
    try children(t, list, &kids);
    const n1 = kids.items[0];
    const n4 = kids.items[3];
    try v.items.insert(gpa, 2, 99);
    _ = v.items.orderedRemove(1); // remove 2
    rebuild(t);
    try children(t, list, &kids);
    try std.testing.expectEqual(@as(usize, 4), kids.items.len);
    try std.testing.expect(kids.items[0].eql(n1));
    try std.testing.expect(kids.items[3].eql(n4));
}

const CondView = struct {
    show: bool = true,
    pub fn build(self: *CondView, ui: *Ui) void {
        if (self.show) _ = controls.button(ui, .{ .label = "a" });
        ui.text("b", .{});
    }
};

test "conditional sibling different kinds" {
    const gpa = std.testing.allocator;
    var v: CondView = .{};
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.frame();
    const b = t.find(.{ .kind = "text" }).?;
    v.show = false;
    rebuild(t);
    try std.testing.expect(t.find(.{ .kind = "button" }) == null);
    try std.testing.expect(t.find(.{ .kind = "text" }).?.eql(b));
    v.show = true;
    rebuild(t);
    try std.testing.expect(t.find(.{ .kind = "text" }).?.eql(b));
}

const DupView = struct {
    pub fn build(_: *DupView, ui: *Ui) void {
        ui.id(@as(u32, 7));
        ui.text("x", .{});
        ui.id(@as(u32, 7));
        ui.text("y", .{});
    }
};

var duplicates: u32 = 0;
fn recordDuplicate(_: ?*anyopaque, _: ids.Key) void {
    duplicates += 1;
}

test "duplicate key reported" {
    const gpa = std.testing.allocator;
    var v: DupView = .{};
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    t.win.ui.on_duplicate_key = recordDuplicate;
    duplicates = 0;
    _ = t.frame();
    rebuild(t);
    try std.testing.expect(duplicates >= 1);
}

test "unmount runs deinitState exactly once" {
    const gpa = std.testing.allocator;
    var v: ListView = .{ .counted = true };
    defer v.items.deinit(gpa);
    try v.items.appendSlice(gpa, &.{ 1, 2, 3, 4, 5 });
    deinit_count = 0;
    {
        const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&v) });
        defer t.deinit();
        _ = t.frame();
        v.items.shrinkRetainingCapacity(2);
        rebuild(t);
        try std.testing.expectEqual(@as(u32, 3), deinit_count);
        rebuild(t);
        try std.testing.expectEqual(@as(u32, 3), deinit_count);
    }
    // Window teardown frees the remaining two.
    try std.testing.expectEqual(@as(u32, 5), deinit_count);
}

const ColorView = struct {
    hot: bool = false,
    pub fn build(self: *ColorView, ui: *Ui) void {
        ui.text("hello", .{ .color = if (self.hot) .accent else .fg });
    }
};

test "props paint-only change sets paint_dirty only" {
    const gpa = std.testing.allocator;
    var v: ColorView = .{};
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.frame();
    v.hot = true;
    t.win.markAllDirty();
    const st = t.frame();
    try std.testing.expectEqual(@as(u32, 0), st.layout.visited);
    try std.testing.expectEqual(@as(u32, 1), st.nodes_painted);
    try std.testing.expect(st.presented);
}

test "idle frame does nothing" {
    const gpa = std.testing.allocator;
    var v: ColorView = .{};
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    const frames = t.rec.frames;
    const st = t.frame();
    try std.testing.expect(st.idle);
    try std.testing.expectEqual(frames, t.rec.frames);
}

test "steady-state rebuild does not allocate" {
    const gpa = std.testing.allocator;
    var v: ListView = .{};
    defer v.items.deinit(gpa);
    for (0..1000) |i| try v.items.append(gpa, @intCast(i));
    var counting = @import("zg_core").alloc.CountingAllocator.init(gpa);
    const t = try TestApp.init(counting.allocator(), .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    rebuild(t);
    rebuild(t);
    counting.resetCounters();
    rebuild(t);
    try std.testing.expectEqual(@as(u64, 0), counting.allocs.load(.monotonic));
}
