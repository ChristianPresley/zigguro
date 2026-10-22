//! Overlays, popovers and dialogs (E04.F05.S03.T01): placement, light
//! dismiss, Escape, modality, focus, and `confirm`.

const std = @import("std");
const geom = @import("../core/geom.zig");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const controls = @import("controls.zig");
const overlay = @import("overlay.zig");
const dialog = @import("dialog.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const Rect = geom.Rect;
const AnyView = view_mod.AnyView;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn expectRect(want: Rect, got: Rect) !void {
    try std.testing.expectApproxEqAbs(want.x, got.x, 0.01);
    try std.testing.expectApproxEqAbs(want.y, got.y, 0.01);
    try std.testing.expectApproxEqAbs(want.w, got.w, 0.01);
    try std.testing.expectApproxEqAbs(want.h, got.h, 0.01);
}

test "place: preferred side, flip, shift" {
    const vp: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const size: geom.Size = .{ .w = 100, .h = 80 };
    // Fits below.
    try expectRect(.{ .x = 20, .y = 54, .w = 100, .h = 80 }, overlay.place(.{ .x = 20, .y = 20, .w = 60, .h = 30 }, size, vp, .{}));
    // No room below: flips above.
    try expectRect(.{ .x = 20, .y = 166, .w = 100, .h = 80 }, overlay.place(.{ .x = 20, .y = 250, .w = 60, .h = 30 }, size, vp, .{}));
    // Wants above but no room: flips below.
    try expectRect(.{ .x = 20, .y = 34, .w = 100, .h = 80 }, overlay.place(.{ .x = 20, .y = 10, .w = 60, .h = 20 }, size, vp, .{ .side = .above }));
    // Near the right edge: shifted to stay 8 px inside.
    try expectRect(.{ .x = 292, .y = 54, .w = 100, .h = 80 }, overlay.place(.{ .x = 350, .y = 20, .w = 40, .h = 30 }, size, vp, .{}));
    // End alignment.
    try expectRect(.{ .x = 100, .y = 54, .w = 100, .h = 80 }, overlay.place(.{ .x = 140, .y = 20, .w = 60, .h = 30 }, size, vp, .{ .alignment = .end }));
    // Right side flips left.
    try expectRect(.{ .x = 246, .y = 100, .w = 100, .h = 80 }, overlay.place(.{ .x = 350, .y = 100, .w = 40, .h = 20 }, size, vp, .{ .side = .right }));
    // Neither side fits: stays on the roomier side, clamped.
    const tall: geom.Size = .{ .w = 100, .h = 280 };
    try expectRect(.{ .x = 20, .y = 12, .w = 100, .h = 280 }, overlay.place(.{ .x = 20, .y = 100, .w = 60, .h = 30 }, tall, vp, .{}));
    // Centred.
    try expectRect(.{ .x = 150, .y = 89.6, .w = 100, .h = 80 }, overlay.center(size, vp));
}

const Menu = struct {
    picks: u32 = 0,
    pub fn build(self: *Menu, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 4 } });
        defer ui.close();
        if (controls.button(ui, .{ .label = "Cut" }).clicked) self.picks += 1;
        if (controls.button(ui, .{ .label = "Copy" }).clicked) self.picks += 1;
    }
};

const Page = struct {
    open: bool = false,
    clicks: u32 = 0,
    anchor_x: f32 = 20,
    show_anchor: bool = true,
    menu: Menu = .{},

    pub fn build(self: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .padding = .{ .l = self.anchor_x, .t = 20 }, .gap = 8, .align_items = .start } });
        defer ui.close();
        if (self.show_anchor) {
            ui.open(.{ .style = .{} });
            const anchor = ui.current();
            if (controls.button(ui, .{ .label = "Edit" }).clicked) self.open = !self.open;
            ui.close();
            overlay.popover(ui, &self.open, anchor, .of(&self.menu), .{ .test_id = "menu", .label = "Edit menu" });
        }
        if (controls.button(ui, .{ .label = "Other" }).clicked) self.clicks += 1;
    }
};

fn openPage(p: *Page) !*TestApp {
    const t = try TestApp.init(std.testing.allocator, .{ .root = .of(p), .size = .{ .w = 400, .h = 300 } });
    _ = t.settle();
    try t.click(.{ .name = "Edit" });
    return t;
}

test "popover opens below its anchor and follows it" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    try expect(p.open);
    const anchor = try t.rectOf(.{ .name = "Edit" });
    var panel = try t.rectOf(.{ .test_id = "menu" });
    try std.testing.expectApproxEqAbs(anchor.x, panel.x, 0.01);
    try std.testing.expectApproxEqAbs(anchor.bottom() + 4, panel.y, 0.01);
    // The anchor moves; the panel goes with it.
    p.anchor_x = 60;
    t.win.markAllDirty();
    _ = t.settle();
    panel = try t.rectOf(.{ .test_id = "menu" });
    try std.testing.expectApproxEqAbs(@as(f32, 60), panel.x, 0.01);
    // Focus moved into the popover.
    try expect(t.win.store.isAncestor(t.find(.{ .test_id = "menu" }).?, t.win.focus));
}

test "outside click closes the popover, is consumed, and syncs the flag" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    try t.click(.{ .name = "Other" });
    try expectEqual(@as(u32, 0), p.clicks);
    try expect(!p.open);
    try expect(t.find(.{ .test_id = "menu" }) == null);
    // The next click goes through.
    try t.click(.{ .name = "Other" });
    try expectEqual(@as(u32, 1), p.clicks);
}

test "click inside the popover does not dismiss it" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    try t.click(.{ .name = "Cut" });
    try expectEqual(@as(u32, 1), p.menu.picks);
    try expect(p.open);
}

test "Escape closes the popover and restores focus" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    const edit = t.find(.{ .name = "Edit" }).?;
    t.press(.escape, .{});
    try expect(!p.open);
    try expect(t.find(.{ .test_id = "menu" }) == null);
    try expect(t.win.focus.eql(edit));
}

test "unmounting the anchor closes the popover" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    p.show_anchor = false;
    t.win.markAllDirty();
    _ = t.settle();
    try expect(t.find(.{ .test_id = "menu" }) == null);
    try expectEqual(@as(usize, 0), t.win.overlays.items.items.len);
}

test "window blur closes popovers" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    t.win.dismissPopovers();
    _ = t.settle();
    try expect(!p.open);
}

const Body = struct {
    pub fn build(_: *Body, ui: *Ui) void {
        ui.open(.{ .style = .{ .gap = 8 } });
        defer ui.close();
        _ = controls.button(ui, .{ .label = "One" });
        _ = controls.button(ui, .{ .label = "Two" });
    }
};

const DialogPage = struct {
    open: bool = false,
    behind: u32 = 0,
    body: Body = .{},

    pub fn build(self: *DialogPage, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .padding = .all(20), .gap = 8, .align_items = .start } });
        defer ui.close();
        if (controls.button(ui, .{ .label = "Behind" }).clicked) self.behind += 1;
        dialog.dialog(ui, &self.open, .of(&self.body), .{ .title = "Settings", .size = .sm, .test_id = "dlg" });
    }
};

test "modal dialog: centred, scrim blocks input, focus trapped, Escape closes" {
    var d: DialogPage = .{ .open = true };
    const t = try TestApp.init(std.testing.allocator, .{ .root = .of(&d), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    _ = t.settle();
    const panel = try t.rectOf(.{ .test_id = "dlg" });
    try std.testing.expectApproxEqAbs(@as(f32, 360), panel.w, 0.01);
    try std.testing.expectApproxEqAbs((800 - 360) / 2, panel.x, 0.01);
    try expect(t.find(.{ .test_id = "overlay.scrim" }) != null);
    try expect(t.find(.{ .name = "Settings" }) != null);
    // Clicks behind the scrim do nothing and do not close the dialog.
    try t.click(.{ .name = "Behind" });
    try expectEqual(@as(u32, 0), d.behind);
    try expect(d.open);
    // Tab cycles inside the dialog.
    const dlg = t.find(.{ .test_id = "dlg" }).?;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        t.press(.tab, .{});
        try expect(t.win.store.isAncestor(dlg, t.win.focus));
    }
    t.press(.tab, .{ .shift = true });
    try expect(t.win.store.isAncestor(dlg, t.win.focus));
    t.press(.escape, .{});
    try expect(!d.open);
    try expect(t.find(.{ .test_id = "overlay.scrim" }) == null);
    try t.click(.{ .name = "Behind" });
    try expectEqual(@as(u32, 1), d.behind);
}

test "dialog above a popover: Escape closes the topmost first" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    var body: Body = .{};
    const id = try t.win.openOverlay(.of(&body), .{ .layer = .dialog, .modal = true, .test_id = "dlg" });
    _ = t.settle();
    try expectEqual(id, t.win.overlays.top().?.id);
    t.press(.escape, .{});
    try expect(!t.win.isOverlayOpen(id));
    try expect(p.open);
    t.press(.escape, .{});
    try expect(!p.open);
}

const Answer = struct {
    got: ?dialog.Result = null,
    calls: u32 = 0,
    fn cb(ctx: ?*anyopaque, r: dialog.Result) void {
        const a: *Answer = @ptrCast(@alignCast(ctx.?));
        a.got = r;
        a.calls += 1;
    }
};

test "confirm reports the button pressed" {
    var d: DialogPage = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = .of(&d) });
    defer t.deinit();
    _ = t.settle();
    var a: Answer = .{};
    _ = try dialog.confirm(t.win, .{ .title = "Delete file?", .message = "This cannot be undone.", .ok_label = "Delete", .alt_label = "Keep", .danger = true }, .{ .ctx = &a, .f = Answer.cb });
    _ = t.settle();
    try expect(t.find(.{ .name = "This cannot be undone." }) != null);
    try t.click(.{ .name = "Delete" });
    try expectEqual(@as(?dialog.Result, .ok), a.got);
    try expectEqual(@as(u32, 1), a.calls);
    try expect(t.find(.{ .test_id = "confirm" }) == null);

    _ = try dialog.confirm(t.win, .{ .title = "Close?", .alt_label = "Don't save" }, .{ .ctx = &a, .f = Answer.cb });
    _ = t.settle();
    try t.click(.{ .name = "Don't save" });
    try expectEqual(@as(?dialog.Result, .alt), a.got);

    _ = try dialog.confirm(t.win, .{ .title = "Quit?" }, .{ .ctx = &a, .f = Answer.cb });
    _ = t.settle();
    t.press(.escape, .{});
    try expectEqual(@as(?dialog.Result, .cancel), a.got);
    try expectEqual(@as(u32, 3), a.calls);
}

test "confirm left open is cancelled when the window closes" {
    var d: DialogPage = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = .of(&d) });
    var a: Answer = .{};
    _ = try dialog.confirm(t.win, .{ .title = "Quit?" }, .{ .ctx = &a, .f = Answer.cb });
    _ = t.settle();
    t.deinit();
    try expectEqual(@as(?dialog.Result, .cancel), a.got);
}

test "stack orders by layer" {
    const gpa = std.testing.allocator;
    var s: overlay.Stack = .{};
    defer s.deinit(gpa);
    var b: Body = .{};
    const v: AnyView = .of(&b);
    const tip = try s.push(gpa, .{ .id = .none, .view = v, .opts = .{ .layer = .tooltip } });
    const dlg = try s.push(gpa, .{ .id = .none, .view = v, .opts = .{ .layer = .dialog, .modal = true } });
    const pop = try s.push(gpa, .{ .id = .none, .view = v, .opts = .{ .layer = .popover } });
    try expectEqual(@as(?usize, 0), s.indexOf(pop));
    try expectEqual(@as(?usize, 1), s.indexOf(dlg));
    try expectEqual(@as(?usize, 2), s.indexOf(tip));
    try expectEqual(dlg, s.topModal().?.id);
    try expect(s.remove(dlg) != null);
    try expect(s.topModal() == null);
}
