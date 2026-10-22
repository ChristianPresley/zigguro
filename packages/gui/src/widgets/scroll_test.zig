//! Scroll containers and virtual lists (E04.F04.S01.T01, E04.F04.S02.T01).

const std = @import("std");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const scroll = @import("scroll.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const NodeId = ids.NodeId;

const Page = struct {
    rows: u32 = 50,
    area: NodeId = .none,
    pub fn build(self: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = 300 }, .h = .{ .px = 200 }, .dir = .column } });
        defer ui.close();
        self.area = scroll.scrollArea(ui, .{ .test_id = "area" });
        defer ui.close();
        var i: u32 = 0;
        while (i < self.rows) : (i += 1) {
            ui.id(i);
            ui.open(.{ .style = .{ .h = .{ .px = 20 }, .shrink = 0 }, .test_id = if (i == 5) "row5" else "" });
            ui.close();
        }
    }
};

fn wheel(t: *TestApp, x: f32, y: f32, dy: f32) void {
    t.win.dispatch(.{ .scroll = .{ .pos = .{ .x = x, .y = y }, .dx = 0, .dy = dy } });
}

test "wheel scrolls without relayout and clamps at the end" {
    var v: Page = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    const row5 = t.find(.{ .test_id = "row5" }).?;
    try std.testing.expectEqual(@as(f32, 100), t.win.store.absRect(row5).y);
    try std.testing.expectEqual(@as(f32, 800), t.win.maxScroll(v.area).y);

    wheel(t, 100, 100, 1);
    const st = t.frame();
    try std.testing.expectEqual(@as(u32, 0), st.layout.visited);
    try std.testing.expectEqual(@as(f32, 48), t.win.scrollOffset(v.area).y);
    try std.testing.expectEqual(@as(f32, 52), t.win.store.absRect(row5).y);
    // Rows scrolled out of the viewport are not painted.
    try std.testing.expect(st.nodes_painted + st.nodes_replayed < 20);
    // Damage stays inside the scroll area.
    try std.testing.expect(!st.full_damage);
    for (t.rec.damage.items) |r| try std.testing.expect(r.y + r.h <= 200.5 and r.x + r.w <= 300.5);
    // A thumb is drawn.
    try std.testing.expect(std.mem.indexOf(u8, t.rec.text(), "rect") != null);

    wheel(t, 100, 100, 1000);
    _ = t.frame();
    try std.testing.expectEqual(@as(f32, 800), t.win.scrollOffset(v.area).y);
    wheel(t, 100, 100, -1000);
    _ = t.frame();
    try std.testing.expectEqual(@as(f32, 0), t.win.scrollOffset(v.area).y);
}

test "shrinking content clamps the offset" {
    var v: Page = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    _ = t.win.scrollTo(v.area, .{ .y = 700 });
    _ = t.frame();
    v.rows = 15; // 300 px of content in a 200 px viewport
    t.win.markAllDirty();
    _ = t.settle();
    try std.testing.expectEqual(@as(f32, 100), t.win.scrollOffset(v.area).y);
}

const Nested = struct {
    outer: NodeId = .none,
    inner: NodeId = .none,
    pub fn build(self: *Nested, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = 300 }, .h = .{ .px = 200 }, .dir = .column } });
        defer ui.close();
        self.outer = scroll.scrollArea(ui, .{});
        defer ui.close();
        {
            self.inner = scroll.scrollArea(ui, .{ .style = .{ .h = .{ .px = 100 }, .shrink = 0, .dir = .column } });
            defer ui.close();
            ui.open(.{ .style = .{ .h = .{ .px = 150 }, .shrink = 0 } });
            ui.close();
        }
        ui.open(.{ .style = .{ .h = .{ .px = 400 }, .shrink = 0 } });
        ui.close();
    }
};

test "an inner container at its end lets the outer one scroll" {
    var v: Nested = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    t.win.dispatch(.{ .scroll = .{ .pos = .{ .x = 50, .y = 50 }, .dx = 0, .dy = 30, .precise = true } });
    _ = t.frame();
    try std.testing.expectEqual(@as(f32, 30), t.win.scrollOffset(v.inner).y);
    try std.testing.expectEqual(@as(f32, 0), t.win.scrollOffset(v.outer).y);
    t.win.dispatch(.{ .scroll = .{ .pos = .{ .x = 50, .y = 50 }, .dx = 0, .dy = 30, .precise = true } });
    _ = t.frame();
    try std.testing.expectEqual(@as(f32, 50), t.win.scrollOffset(v.inner).y);
    t.win.dispatch(.{ .scroll = .{ .pos = .{ .x = 50, .y = 50 }, .dx = 0, .dy = 30, .precise = true } });
    _ = t.frame();
    try std.testing.expectEqual(@as(f32, 30), t.win.scrollOffset(v.outer).y);
}

const BigList = struct {
    count: usize = 100_000,
    vis: scroll.Visible = .{ .node = .none, .first = 0, .end = 0 },
    builds: u32 = 0,
    pub fn build(self: *BigList, ui: *Ui) void {
        self.builds += 1;
        ui.open(.{ .style = .{ .w = .{ .px = 300 }, .h = .{ .px = 220 }, .dir = .column } });
        defer ui.close();
        self.vis = scroll.virtualList(ui, .{ .count = self.count, .row_h = 22 }, self, row);
    }
    fn row(_: *BigList, ui: *Ui, i: usize) void {
        ui.textf("row {d}", .{i}, .{});
    }
};

test "virtual list builds only the visible rows" {
    var v: BigList = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    // 220 px / 22 px = 10 rows, plus overscan 3 below.
    try std.testing.expectEqual(@as(usize, 0), v.vis.first);
    try std.testing.expectEqual(@as(usize, 14), v.vis.end);
    try std.testing.expect(t.win.store.live < 100);
    try std.testing.expectEqual(@as(f32, 100_000 * 22 - 220), t.win.maxScroll(v.vis.node).y);

    // Row 5 keeps its node while it stays in range.
    const before = t.count(.{ .kind = "text" });
    try std.testing.expectEqual(@as(usize, 14), before);
    var it = t.win.store.children(v.vis.node);
    var row5: NodeId = .none;
    var k: usize = 0;
    while (it.next()) |c| : (k += 1) if (k == 5) {
        row5 = c;
    };
    _ = t.win.scrollTo(v.vis.node, .{ .y = 44 });
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 0), v.vis.first);
    try std.testing.expect(t.win.store.valid(row5));

    // Far down the list.
    _ = t.win.scrollTo(v.vis.node, .{ .y = 22 * 50_000 });
    _ = t.settle();
    try std.testing.expectEqual(@as(usize, 50_000 - 3), v.vis.first);
    try std.testing.expectEqual(@as(usize, 50_000 + 10 + 1 + 3), v.vis.end);
    try std.testing.expect(t.win.store.live < 100);

    scroll.scrollToRow(t.win, v.vis.node, .{ .count = v.count, .row_h = 22 }, 10);
    _ = t.settle();
    try std.testing.expectEqual(@as(f32, 220), t.win.scrollOffset(v.vis.node).y);
}
