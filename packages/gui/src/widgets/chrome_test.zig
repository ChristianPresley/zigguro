//! Workbench chrome (E04.F05.S04.T02): the status bar's overflow, chord
//! item and bell, toasts (auto-dismiss on a virtual clock, hover pause,
//! sticky errors, at most three, actions) and the notification center.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const actions = @import("../input/actions.zig");
const status_bar = @import("status_bar.zig");
const toast_mod = @import("toast.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const testing = std.testing;
const gpa = testing.allocator;

const Page = struct {
    items: []const status_bar.StatusItem = &.{},
    chord: ?[]const u8 = null,
    ran: std.ArrayList(u8) = .empty,

    pub fn build(p: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        defer ui.close();
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        status_bar.statusBar(ui, p.items, .{ .chord = p.chord });
    }

    fn run(ptr: *anyopaque, action: actions.ActionId, _: ?[]const u8) bool {
        const p: *Page = @ptrCast(@alignCast(ptr));
        p.ran.appendSlice(gpa, action) catch {};
        p.ran.append(gpa, ';') catch {};
        return true;
    }
};

const Fx = struct {
    page: Page,
    t: *TestApp,

    fn init(f: *Fx, items: []const status_bar.StatusItem, w: f32) !void {
        f.page = .{ .items = items };
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.page), .size = .{ .w = w, .h = 400 } });
        f.t.win.action_handler = .{ .ptr = &f.page, .run = Page.run };
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.page.ran.deinit(gpa);
    }

    fn toastCount(f: *Fx) usize {
        return f.t.count(.{ .test_id = "toast" });
    }
};

const bar_items = [_]status_bar.StatusItem{
    .{ .id = "branch", .text = "main", .priority = 1000, .action = "scm.branch" },
    .{ .id = "problems", .text = "0 problems", .priority = 50 },
    .{ .id = "encoding", .text = "UTF-8", .side = .right, .priority = 10, .action = "file.encoding" },
    .{ .id = "eol", .text = "LF", .side = .right, .priority = 5 },
};

test "status bar: items run actions; narrow bars overflow into a menu" {
    var f: Fx = undefined;
    try f.init(&bar_items, 800);
    defer f.deinit();
    try testing.expect(f.t.find(.{ .name = "UTF-8" }) != null);
    try f.t.click(.{ .name = "UTF-8" });
    try f.t.click(.{ .name = "main" });
    try testing.expectEqualStrings("file.encoding;scm.branch;", f.page.ran.items);
    // The bar measures at build time: a resize rebuilds it.
    f.t.win.resize(.{ .w = 150, .h = 400 }, 1);
    f.t.win.markAllDirty();
    _ = f.t.settle();
    // The pinned branch stays; low priorities moved to "…".
    try testing.expect(f.t.find(.{ .name = "main" }) != null);
    try testing.expect(f.t.find(.{ .name = "LF" }) == null);
    try testing.expect(f.t.find(.{ .name = "More status items" }) != null);
    try f.t.click(.{ .name = "More status items" });
    try testing.expect(f.t.find(.{ .role = .menuitem, .name = "LF" }) != null);
}

test "status bar: the pending chord shows as an item" {
    var f: Fx = undefined;
    try f.init(&bar_items, 800);
    defer f.deinit();
    f.page.chord = "(Ctrl+K) was pressed. Waiting for second key\u{2026}";
    f.t.win.markAllDirty();
    _ = f.t.settle();
    try testing.expect(f.t.find(.{ .name = f.page.chord.? }) != null);
}

test "toasts: auto dismiss, hover pauses, errors stay" {
    var f: Fx = undefined;
    try f.init(&.{}, 800);
    defer f.deinit();
    const app = &f.t.app;
    _ = toast_mod.toast(app, .{ .title = "Saved" });
    _ = toast_mod.toast(app, .{ .severity = .error_, .title = "Build failed" });
    _ = f.t.settle();
    try testing.expectEqual(@as(usize, 2), f.toastCount());
    // Hovering the info toast keeps it past its deadline.
    const r = try f.t.rectOf(.{ .test_id = "toast", .name = "Saved" });
    f.t.moveTo(.{ .x = r.x + 20, .y = r.y + 4 });
    f.t.advance(8000);
    try testing.expect(f.t.find(.{ .name = "Saved" }) != null);
    f.t.moveTo(.{ .x = 1, .y = 1 });
    f.t.advance(2000);
    try testing.expect(f.t.find(.{ .name = "Saved" }) == null);
    f.t.advance(60_000);
    try testing.expect(f.t.find(.{ .name = "Build failed" }) != null);
    // The bell counts both.
    try testing.expect(f.t.find(.{ .name = "Notifications" }) != null);
    try testing.expectEqual(@as(u32, 2), app.notifications.unread());
}

test "toasts: at most three show; actions run and dismiss" {
    var f: Fx = undefined;
    try f.init(&.{}, 800);
    defer f.deinit();
    const app = &f.t.app;
    for (0..4) |i| {
        var buf: [8]u8 = undefined;
        _ = toast_mod.toast(app, .{ .severity = .warning, .title = try std.fmt.bufPrint(&buf, "w{d}", .{i}) });
    }
    _ = toast_mod.toast(app, .{ .severity = .approval, .title = "Allow edit?", .actions = &.{.{ .label = "Review", .action = "agent.review", .primary = true }} });
    _ = f.t.settle();
    try testing.expectEqual(@as(usize, 3), f.toastCount());
    try f.t.click(.{ .role = .button, .name = "Review" });
    try testing.expectEqualStrings("agent.review;", f.page.ran.items);
    try testing.expect(f.t.find(.{ .name = "Allow edit?" }) == null);
    try testing.expectEqual(@as(usize, 3), f.toastCount());
}

test "notification center: lists, marks read, do not disturb" {
    var f: Fx = undefined;
    try f.init(&.{}, 800);
    defer f.deinit();
    const app = &f.t.app;
    _ = toast_mod.toast(app, .{ .title = "Indexed", .source = "Search" });
    _ = toast_mod.toast(app, .{ .title = "Edited 3 files", .source = "Agent: refactor" });
    _ = f.t.settle();
    try f.t.click(.{ .name = "Notifications" });
    try testing.expect(f.t.find(.{ .test_id = "notification_center" }) != null);
    try testing.expect(f.t.find(.{ .role = .listitem, .name = "Indexed" }) != null);
    // Toasts hide while the center is open.
    try testing.expectEqual(@as(usize, 0), f.toastCount());
    try testing.expectEqual(@as(u32, 0), app.notifications.unread());
    try f.t.click(.{ .name = "Do not disturb" });
    try testing.expect(app.notifications.dnd);
    f.t.press(.escape, .{});
    try testing.expect(f.t.find(.{ .test_id = "notification_center" }) == null);
    try testing.expectEqual(@as(usize, 0), f.toastCount());
    _ = toast_mod.toast(app, .{ .title = "quiet" });
    _ = toast_mod.toast(app, .{ .severity = .error_, .title = "loud" });
    _ = f.t.settle();
    try testing.expectEqual(@as(usize, 1), f.toastCount());
}
