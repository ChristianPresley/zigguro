//! Dock UI (E04.F07.S01.T02): splits render with splitters that resize
//! (pointer, keyboard, double-click), tab strips follow APG tabs and keep
//! the active tab in view, close gestures and the tab context menu act
//! on the model, focus inside a group focuses it, and dragging a tab
//! reorders, splits, docks into side areas or floats.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const model = @import("model.zig");
const view = @import("view.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const DockModel = model.DockModel;
const PanelRef = model.PanelRef;
const GroupId = model.GroupId;
const testing = std.testing;
const gpa = testing.allocator;

const Page = struct {
    dock: DockModel,
    dv: view.DockView = undefined,
    titles: [64][]const u8 = undefined,
    /// Panels that refuse to close.
    keep: ?PanelRef = null,

    pub fn build(p: *Page, ui: *Ui) void {
        p.dv.beginFrame(ui);
        ui.open(.{ .style = .{ .dir = .row, .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .align_items = .stretch } });
        defer ui.close();
        p.dv.dockArea(ui, .left);
        p.dv.dockArea(ui, .center);
        p.dv.dropOverlay(ui);
    }

    fn tab(ctx: *anyopaque, r: PanelRef) view.TabInfo {
        const p: *Page = @ptrCast(@alignCast(ctx));
        return .{ .title = p.titles[@intFromEnum(r)], .dirty = p.keep == r };
    }

    fn content(ctx: *anyopaque, ui: *Ui, r: PanelRef) void {
        const p: *Page = @ptrCast(@alignCast(ctx));
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "content {s}", .{p.titles[@intFromEnum(r)]}) catch "content";
        ui.text(ui.arena().dupe(u8, s) catch "content", .{});
    }

    fn canClose(ctx: *anyopaque, r: PanelRef) bool {
        const p: *Page = @ptrCast(@alignCast(ctx));
        return p.keep != r;
    }
};

const names = [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.zig", "e.zig", "f.zig", "g.zig", "h.zig", "i.zig", "j.zig", "k.zig", "l.zig" };

const Fx = struct {
    page: Page,
    t: *TestApp,

    fn init(f: *Fx, w: f32) !void {
        f.page = .{ .dock = try DockModel.init(gpa) };
        f.page.dv = .init(gpa, &f.page.dock, .{ .ctx = &f.page, .tab = Page.tab, .build = Page.content, .can_close = Page.canClose });
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.page), .size = .{ .w = w, .h = 400 } });
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.page.dv.deinit();
        f.page.dock.deinit();
    }

    fn center(f: *Fx) GroupId {
        return f.page.dock.firstGroup(f.page.dock.areas[@intFromEnum(model.Area.center)].root).?;
    }

    /// Opens `names[0..n]` in `g`.
    fn open(f: *Fx, g: GroupId, n: usize) ![]PanelRef {
        var out: std.ArrayList(PanelRef) = .empty;
        defer out.deinit(gpa);
        for (names[0..n]) |name| {
            const p = try f.page.dock.addPanel(1, null);
            f.page.titles[@intFromEnum(p)] = name;
            try f.page.dock.openIn(p, g, null, .{});
            try out.append(gpa, p);
        }
        return gpa.dupe(PanelRef, out.items);
    }

    fn rebuild(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn active(f: *Fx, g: GroupId) PanelRef {
        const gr = f.page.dock.group(g).?;
        return gr.tabs.items[gr.active];
    }
};

test "dock view: tabs activate by click and APG keys, content follows" {
    var f: Fx = undefined;
    try f.init(800);
    defer f.deinit();
    const g = f.center();
    const ps = try f.open(g, 3);
    defer gpa.free(ps);
    f.rebuild();
    try testing.expectEqual(ps[2], f.active(g));
    try testing.expect(f.t.find(.{ .name = "content c.zig" }) != null);
    try f.t.click(.{ .role = .tab, .name = "a.zig" });
    try testing.expectEqual(ps[0], f.active(g));
    try testing.expect(f.t.find(.{ .name = "content a.zig" }) != null);
    try testing.expect(f.t.find(.{ .name = "content c.zig" }) == null);
    // Focus is in the group: it is the focused group.
    try testing.expectEqual(g, f.page.dock.focused.?);
    // Right / End move along the list and activate.
    f.t.press(.arrow_right, .{});
    _ = f.t.settle();
    try testing.expectEqual(ps[1], f.active(g));
    f.t.press(.end, .{});
    _ = f.t.settle();
    try testing.expectEqual(ps[2], f.active(g));
    f.t.press(.home, .{});
    _ = f.t.settle();
    try testing.expectEqual(ps[0], f.active(g));
}

test "dock view: close gestures and can_close" {
    var f: Fx = undefined;
    try f.init(800);
    defer f.deinit();
    const g = f.center();
    const ps = try f.open(g, 3);
    defer gpa.free(ps);
    f.page.keep = ps[1];
    f.rebuild();
    // Delete on the focused tab closes it.
    try f.t.click(.{ .role = .tab, .name = "a.zig" });
    f.t.press(.delete, .{});
    _ = f.t.settle();
    try testing.expect(f.page.dock.groupOf(ps[0]) == null);
    try testing.expect(f.t.find(.{ .role = .tab, .name = "a.zig" }) == null);
    // A panel the host keeps stays open.
    try f.t.click(.{ .role = .tab, .name = "b.zig" });
    f.t.press(.delete, .{});
    _ = f.t.settle();
    try testing.expect(f.page.dock.groupOf(ps[1]) != null);
    // The close button, at the right end of the tab.
    const r = try f.t.rectOf(.{ .role = .tab, .name = "c.zig" });
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = r.x + r.w - 15, .y = r.y + r.h / 2 }, .clicks = 1 } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = r.x + r.w - 15, .y = r.y + r.h / 2 } } });
    _ = f.t.settle();
    try testing.expect(f.page.dock.groupOf(ps[2]) == null);
}

test "dock view: context menu splits, pins and closes others" {
    var f: Fx = undefined;
    try f.init(1000);
    defer f.deinit();
    const g = f.center();
    const ps = try f.open(g, 4);
    defer gpa.free(ps);
    f.rebuild();
    try f.t.click(.{ .role = .tab, .name = "b.zig" });
    f.t.press(.f10, .{ .shift = true });
    _ = f.t.settle();
    try testing.expect(f.t.find(.{ .test_id = "tab_menu" }) != null);
    try f.t.click(.{ .role = .menuitem, .name = "Pin" });
    try testing.expectEqual(@as(u32, 1), f.page.dock.group(g).?.pinned);
    try testing.expectEqual(ps[1], f.page.dock.group(g).?.tabs.items[0]);
    // Close Others keeps b.
    try f.t.rightClick(.{ .role = .tab, .name = "d.zig" });
    try f.t.click(.{ .role = .menuitem, .name = "Close Others" });
    try testing.expectEqualSlices(PanelRef, &.{ps[3]}, f.page.dock.group(g).?.tabs.items);
    // Split Right moves x into a new group beside d's.
    const extra = try f.page.dock.addPanel(1, null);
    f.page.titles[@intFromEnum(extra)] = "x.zig";
    try f.page.dock.openIn(extra, g, null, .{});
    f.rebuild();
    try f.t.rightClick(.{ .role = .tab, .name = "x.zig" });
    try f.t.click(.{ .role = .menuitem, .name = "Split Right" });
    try testing.expect(f.page.dock.groupOf(extra).? != g);
    try testing.expectEqual(@as(usize, 2), f.t.count(.{ .test_id = "dock_group" }));
    try testing.expectEqual(@as(usize, 1), f.t.count(.{ .kind = "splitter" }));
    // The group rectangles sit side by side.
    var rects: std.ArrayList(model.GroupRect) = .empty;
    defer rects.deinit(gpa);
    try f.page.dv.groupRects(gpa, &rects);
    try testing.expectEqual(@as(usize, 2), rects.items.len);
    try testing.expect(@abs(rects.items[0].rect.w - rects.items[1].rect.w) < 2);
    // Move to Agent Area leaves the center.
    try f.t.rightClick(.{ .role = .tab, .name = "x.zig" });
    try f.t.click(.{ .role = .menuitem, .name = "Move to Agent Area" });
    try testing.expectEqual(model.Owner{ .area = .agent }, f.page.dock.ownerOf(.{ .group = f.page.dock.groupOf(extra).? }).?);
    try f.page.dock.validate();
}

test "dock view: splitter drag, keyboard, double-click and undo" {
    var f: Fx = undefined;
    try f.init(1004);
    defer f.deinit();
    const g = f.center();
    const ps = try f.open(g, 2);
    defer gpa.free(ps);
    _ = try f.page.dock.split(g, .right, ps[1]);
    f.rebuild();
    f.rebuild();
    const root = f.page.dock.areas[@intFromEnum(model.Area.center)].root.?.split;
    const ratios = f.page.dock.splitOf(root).?.ratios.items;
    try testing.expectApproxEqAbs(@as(f32, 0.5), ratios[0], 1e-4);
    // Drag 100 px right of 1000.
    const r = try f.t.rectOf(.{ .kind = "splitter" });
    const x = r.x + r.w / 2;
    const y = r.y + r.h / 2;
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = x, .y = y }, .clicks = 1 } });
    f.t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = x + 100, .y = y } } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = x + 100, .y = y } } });
    _ = f.t.settle();
    try testing.expectApproxEqAbs(@as(f32, 0.6), f.page.dock.splitOf(root).?.ratios.items[0], 1e-3);
    const g1 = try f.t.rectOf(.{ .test_id = "dock_group" });
    try testing.expectApproxEqAbs(@as(f32, 600), g1.w, 2);
    // The minimum holds.
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = x + 100, .y = y }, .clicks = 1 } });
    f.t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = x + 1000, .y = y } } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = x + 1000, .y = y } } });
    _ = f.t.settle();
    try testing.expectApproxEqAbs(@as(f32, 0.88), f.page.dock.splitOf(root).?.ratios.items[0], 1e-3);
    // Each drag is one undo step.
    try testing.expect(try f.page.dock.undo());
    try testing.expectApproxEqAbs(@as(f32, 0.6), f.page.dock.splitOf(root).?.ratios.items[0], 1e-3);
    // Keyboard: focused splitter, Left moves 10 px, Shift+Left 50.
    f.rebuild();
    f.t.press(.arrow_left, .{});
    _ = f.t.settle();
    try testing.expectApproxEqAbs(@as(f32, 0.59), f.page.dock.splitOf(root).?.ratios.items[0], 1e-3);
    f.t.press(.arrow_left, .{ .shift = true });
    _ = f.t.settle();
    try testing.expectApproxEqAbs(@as(f32, 0.54), f.page.dock.splitOf(root).?.ratios.items[0], 1e-3);
    // Double-click equalizes.
    const r2 = try f.t.rectOf(.{ .kind = "splitter" });
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = r2.x + 1, .y = y }, .clicks = 2 } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = r2.x + 1, .y = y } } });
    _ = f.t.settle();
    try testing.expectApproxEqAbs(@as(f32, 0.5), f.page.dock.splitOf(root).?.ratios.items[0], 1e-3);
}

test "dock view: overflowing strip keeps the active tab in view; the list menu activates" {
    var f: Fx = undefined;
    try f.init(400);
    defer f.deinit();
    const g = f.center();
    const ps = try f.open(g, 12);
    defer gpa.free(ps);
    f.rebuild();
    f.rebuild();
    // l.zig (last) is active and inside the strip.
    const strip = try f.t.rectOf(.{ .test_id = "tab_strip" });
    const l = try f.t.rectOf(.{ .role = .tab, .name = "l.zig" });
    try testing.expect(l.x >= strip.x and l.x + l.w <= strip.x + strip.w + 0.5);
    // The list menu activates a.zig, which scrolls back into view.
    try f.t.click(.{ .name = "\u{2304}" });
    try f.t.click(.{ .role = .menuitem, .name = "a.zig" });
    f.rebuild();
    try testing.expectEqual(ps[0], f.active(g));
    const a = try f.t.rectOf(.{ .role = .tab, .name = "a.zig" });
    try testing.expect(a.x >= strip.x - 0.5);
}

/// Presses tab `name`, drags it to `to` through `via` and releases.
fn dragTab(f: *Fx, name: []const u8, via: []const @import("../core/geom.zig").Vec2, release: bool) !void {
    const r = try f.t.rectOf(.{ .role = .tab, .name = name });
    const from: @import("../core/geom.zig").Vec2 = .{ .x = r.x + 20, .y = r.y + r.h / 2 };
    f.t.win.dispatch(.{ .pointer_move = .{ .pos = from } });
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = from } });
    for (via) |p| {
        f.t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        _ = f.t.settle();
    }
    if (release) f.t.win.dispatch(.{ .pointer_up = .{ .pos = via[via.len - 1] } });
    _ = f.t.settle();
}

test "drag to dock: reorder in the strip, split on an edge, dock to a side area, cancel" {
    var f: Fx = undefined;
    try f.init(1000);
    defer f.deinit();
    const g = f.center();
    const ps = try f.open(g, 3);
    defer gpa.free(ps);
    f.rebuild();
    // Reorder: a past c.
    const c = try f.t.rectOf(.{ .role = .tab, .name = "c.zig" });
    try dragTab(&f, "a.zig", &.{ .{ .x = c.x + 10, .y = c.y + 10 }, .{ .x = c.right() - 5, .y = c.y + 10 } }, true);
    try testing.expectEqualSlices(PanelRef, &.{ ps[1], ps[2], ps[0] }, f.page.dock.group(g).?.tabs.items);
    // While dragging over the right edge, the preview covers the right half.
    try dragTab(&f, "b.zig", &.{ .{ .x = 600, .y = 200 }, .{ .x = 960, .y = 200 } }, false);
    const pv = try f.t.rectOf(.{ .test_id = "dock_drop_preview" });
    try testing.expectApproxEqAbs(@as(f32, 500), pv.x, 1);
    try testing.expectApproxEqAbs(@as(f32, 500), pv.w, 1);
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = 960, .y = 200 } } });
    _ = f.t.settle();
    try testing.expect(f.t.find(.{ .test_id = "dock_drop_preview" }) == null);
    const g2 = f.page.dock.groupOf(ps[1]).?;
    try testing.expect(g2 != g);
    try testing.expectEqual(@as(usize, 2), f.t.count(.{ .test_id = "dock_group" }));
    // One undo step puts it back.
    try testing.expect(try f.page.dock.undo());
    try testing.expectEqual(g, f.page.dock.groupOf(ps[1]).?);
    f.rebuild();
    // The window's left edge docks into the left area, which then shows.
    try dragTab(&f, "c.zig", &.{ .{ .x = 300, .y = 200 }, .{ .x = 5, .y = 200 } }, true);
    try testing.expectEqual(model.Owner{ .area = .left }, f.page.dock.ownerOf(.{ .group = f.page.dock.groupOf(ps[2]).? }).?);
    try testing.expect(f.t.find(.{ .name = "content c.zig" }) != null);
    // Escape cancels a drag.
    try dragTab(&f, "a.zig", &.{ .{ .x = 600, .y = 200 }, .{ .x = 960, .y = 200 } }, false);
    try testing.expect(f.t.find(.{ .test_id = "dock_drop_preview" }) != null);
    f.t.press(.escape, .{});
    try testing.expect(f.t.find(.{ .test_id = "dock_drop_preview" }) == null);
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = 960, .y = 200 } } });
    _ = f.t.settle();
    try testing.expectEqual(g, f.page.dock.groupOf(ps[0]).?);
    try f.page.dock.validate();
}

test "drag to dock: outside the window floats when enabled" {
    var f: Fx = undefined;
    try f.init(800);
    defer f.deinit();
    const g = f.center();
    const ps = try f.open(g, 2);
    defer gpa.free(ps);
    f.rebuild();
    // Not without floating windows.
    try dragTab(&f, "a.zig", &.{ .{ .x = 300, .y = 200 }, .{ .x = 900, .y = 100 } }, true);
    try testing.expectEqual(@as(usize, 0), f.page.dock.floating.items.len);
    try testing.expectEqual(g, f.page.dock.groupOf(ps[0]).?);
    f.page.dv.floating = true;
    try dragTab(&f, "a.zig", &.{ .{ .x = 300, .y = 200 }, .{ .x = 900, .y = 100 } }, true);
    try testing.expectEqual(@as(usize, 1), f.page.dock.floating.items.len);
    try testing.expectEqual(@as(f32, 900), f.page.dock.floating.items[0].rect.x);
    try f.page.dock.validate();
}
