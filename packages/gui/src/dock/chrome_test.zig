//! Window chrome tests (E04.F07.S02.T03): the hit map, its lock-free
//! publication, and the title bar drawn for client-side decorations.

const std = @import("std");
const zg_platform = @import("zg_platform");
const chrome = @import("chrome.zig");
const hit_map = @import("hit_map.zig");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const testing = std.testing;
const gpa = testing.allocator;
const HitMap = hit_map.HitMap;
const HitRegion = zg_platform.types.HitRegion;

test "hit map lookup: edges, corners, caption, client widgets, buttons" {
    const rects = [_]HitMap.Entry{
        .{ .rect = .{ 8, 8, 784, 34 }, .region = .caption },
        .{ .rect = .{ 20, 12, 100, 26 }, .region = .client },
        .{ .rect = .{ 760, 13, 24, 24 }, .region = .button_close },
    };
    const m: HitMap = .{ .size_px = .{ 800, 600 }, .resize_border_px = 8, .rects = &rects };
    const cases = [_]struct { x: i32, y: i32, want: HitRegion }{
        .{ .x = 400, .y = 2, .want = .resize_top },
        .{ .x = 400, .y = 597, .want = .resize_bottom },
        .{ .x = 1, .y = 300, .want = .resize_left },
        .{ .x = 799, .y = 300, .want = .resize_right },
        .{ .x = 2, .y = 2, .want = .resize_top_left },
        .{ .x = 10, .y = 3, .want = .resize_top_left },
        .{ .x = 797, .y = 12, .want = .resize_top_right },
        .{ .x = 3, .y = 590, .want = .resize_bottom_left },
        .{ .x = 795, .y = 595, .want = .resize_bottom_right },
        .{ .x = 400, .y = 20, .want = .caption },
        .{ .x = 50, .y = 20, .want = .client },
        .{ .x = 770, .y = 20, .want = .button_close },
        .{ .x = 400, .y = 300, .want = .client },
    };
    for (cases) |c| {
        testing.expectEqual(c.want, m.lookup(.{ .x = c.x, .y = c.y })) catch |e| {
            std.debug.print("at {d},{d}\n", .{ c.x, c.y });
            return e;
        };
    }
    // No border: edges are whatever is there.
    const flat: HitMap = .{ .size_px = .{ 800, 600 }, .rects = &rects };
    try testing.expectEqual(HitRegion.client, flat.lookup(.{ .x = 1, .y = 300 }));
}

test "publish swaps atomically; a concurrent reader never sees a torn map" {
    var s: hit_map.ChromeState = .init(gpa);
    defer s.deinit();
    const a = [_]HitMap.Entry{.{ .rect = .{ 0, 0, 100, 100 }, .region = .caption }};
    const b = [_]HitMap.Entry{
        .{ .rect = .{ 0, 0, 100, 100 }, .region = .button_max },
        .{ .rect = .{ 0, 0, 100, 100 }, .region = .button_max },
    };
    try testing.expect(try s.publish(.{ .size_px = .{ 100, 100 }, .rects = &a }));
    // An equal map is not republished.
    try testing.expect(!try s.publish(.{ .size_px = .{ 100, 100 }, .rects = &a }));

    const Reader = struct {
        fn run(st: *hit_map.ChromeState, stop: *std.atomic.Value(bool), bad: *std.atomic.Value(u32)) void {
            const f = hit_map.ChromeState.hitTestFn();
            while (!stop.load(.acquire)) {
                const r = f(st, .{ .x = 50, .y = 50 });
                if (r != .caption and r != .button_max) _ = bad.fetchAdd(1, .monotonic);
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    var bad: std.atomic.Value(u32) = .init(0);
    const th = try std.Thread.spawn(.{}, Reader.run, .{ &s, &stop, &bad });
    for (0..2000) |i| _ = try s.publish(.{ .size_px = .{ 100, 100 }, .rects = if (i % 2 == 0) &b else &a });
    stop.store(true, .release);
    th.join();
    try testing.expectEqual(@as(u32, 0), bad.load(.acquire));
}

const Page = struct {
    pub fn build(_: *Page, ui: *ui_mod.Ui) void {
        chrome.begin(ui, .{ .title = "zigguro" });
        defer chrome.end(ui);
        ui.text("content", .{});
    }
};

fn openPage(p: *Page) !*TestApp {
    const t = try TestApp.init(gpa, .{ .size = .{ .w = 800, .h = 600 }, .root = view_mod.AnyView.of(p) });
    _ = t.settle();
    return t;
}

fn clientDecorated(t: *TestApp, maximized: bool) void {
    t.win.chrome.client = true;
    t.win.chrome.margins_px = .{ 12, 12, 12, 12 };
    t.win.chrome.maximized = maximized;
    t.win.markAllDirty();
    _ = t.settle();
}

test "server decorations draw and map nothing" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    try testing.expect(t.find(.{ .test_id = "title-bar" }) == null);
    var rects: std.ArrayList(HitMap.Entry) = .empty;
    defer rects.deinit(gpa);
    const m = try chrome.buildHitMap(t.win, gpa, &rects);
    try testing.expectEqual(@as(usize, 0), m.rects.len);
    try testing.expectEqual(@as(u16, 0), m.resize_border_px);
}

test "client decorations: title bar inside the margins, hit regions, caption buttons" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    clientDecorated(t, false);

    const bar = try t.rectOf(.{ .test_id = "title-bar" });
    // Inside the 12 px margin and the 1 px border.
    try testing.expectApproxEqAbs(@as(f32, 13), bar.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 13), bar.y, 0.01);
    try testing.expectApproxEqAbs(chrome.title_h, bar.h, 0.01);
    const content = try t.rectOf(.{ .name = "content" });
    try testing.expect(content.y >= bar.bottom());
    try testing.expect(t.find(.{ .role = .button, .name = "Minimize" }) != null);
    try testing.expect(t.find(.{ .role = .button, .name = "Maximize" }) != null);

    var rects: std.ArrayList(HitMap.Entry) = .empty;
    defer rects.deinit(gpa);
    const m = try chrome.buildHitMap(t.win, gpa, &rects);
    try testing.expectEqual(@as(u16, 12), m.resize_border_px);
    const at = struct {
        fn f(map: HitMap, x: f32, y: f32) HitRegion {
            return map.lookup(.{ .x = @intFromFloat(x), .y = @intFromFloat(y) });
        }
    }.f;
    try testing.expectEqual(HitRegion.caption, at(m, bar.x + 200, bar.y + bar.h / 2));
    const close = try t.rectOf(.{ .role = .button, .name = "Close" });
    try testing.expectEqual(HitRegion.button_close, at(m, close.x + close.w / 2, close.y + close.h / 2));
    const max = try t.rectOf(.{ .role = .button, .name = "Maximize" });
    try testing.expectEqual(HitRegion.button_max, at(m, max.x + max.w / 2, max.y + max.h / 2));
    try testing.expectEqual(HitRegion.resize_top, at(m, 400, 5));
    try testing.expectEqual(HitRegion.client, at(m, 400, 300));

    // Caption buttons ask the platform through the window.
    try t.click(.{ .role = .button, .name = "Maximize" });
    try testing.expectEqualSlices(zg_platform.window.WindowOp, &.{.maximize}, t.win.window_ops.items);
    try t.click(.{ .role = .button, .name = "Close" });
    try testing.expect(t.win.close_requested);
}

test "maximized windows have no margins, border or resize regions" {
    var p: Page = .{};
    const t = try openPage(&p);
    defer t.deinit();
    clientDecorated(t, true);
    const bar = try t.rectOf(.{ .test_id = "title-bar" });
    try testing.expectApproxEqAbs(@as(f32, 0), bar.y, 0.01);
    try testing.expect(t.find(.{ .role = .button, .name = "Restore" }) != null);
    var rects: std.ArrayList(HitMap.Entry) = .empty;
    defer rects.deinit(gpa);
    const m = try chrome.buildHitMap(t.win, gpa, &rects);
    try testing.expectEqual(@as(u16, 0), m.resize_border_px);
    try testing.expectEqual(HitRegion.caption, m.lookup(.{ .x = 400, .y = 5 }));
    try t.click(.{ .role = .button, .name = "Restore" });
    try testing.expectEqualSlices(zg_platform.window.WindowOp, &.{.unmaximize}, t.win.window_ops.items);
}
