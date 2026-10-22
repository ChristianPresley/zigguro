//! `Host` against the headless platform: a window opens, renders through
//! the software renderer, reacts to input and closes.

const std = @import("std");
const zg_platform = @import("zg_platform");
const app_mod = @import("core/app.zig");
const ui_mod = @import("core/ui.zig");
const view_mod = @import("core/view.zig");
const text = @import("paint/text.zig");
const controls = @import("widgets/controls.zig");
const Host = @import("host.zig").Host;

const Headless = zg_platform.headless.Headless;

const Counter = struct {
    clicks: u32 = 0,
    pub fn build(self: *Counter, ui: *ui_mod.Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .bg = .{ .token = .bg_base }, .padding = .all(10) } });
        defer ui.close();
        if (controls.button(ui, .{ .label = "Click" }).clicked) self.clicks += 1;
    }
};

fn pixel(f: anytype, x: u32, y: u32) [4]u8 {
    const o = y * f.stride + x * 4;
    return f.pixels[o..][0..4].*;
}

test "host opens, renders, clicks and closes a window" {
    const gpa = std.testing.allocator;
    const hl = try Headless.init(gpa, std.testing.io, .{});
    defer hl.deinit();
    var app = app_mod.App.init(gpa);
    defer app.deinit();
    var mono: text.MonoText = .{};
    var host = Host.init(gpa, std.testing.io, &app, hl.platform(), mono.system(), .{});
    defer host.deinit();
    var v: Counter = .{};
    const hw = try host.open(.{ .title = "test", .size = .{ .w = 200, .h = 100 }, .root = view_mod.AnyView.of(&v) });

    // Configure, then the first frame on the next vsync.
    _ = try host.pump();
    try std.testing.expect(hw.frame_requested);
    try hl.tick(hl.opts.refresh_ns);
    _ = try host.pump();
    try std.testing.expectEqual(@as(u64, 1), hw.frames);
    const f = hl.lastFrame(hw.id).?;
    try std.testing.expectEqual(@as(u32, 200), f.width);
    const bg = app.theme.color(.bg_base);
    try std.testing.expectEqualSlices(u8, &.{ bg.r, bg.g, bg.b }, pixel(f, 190, 90)[0..3]);

    // Idle: no frame is requested.
    _ = try host.pump();
    try std.testing.expect(!hw.frame_requested);

    // Click the button through platform events.
    const at: [2]f32 = .{ 15, 15 };
    try hl.inject(.{ .pointer_move = .{ .win = hw.id, .pos_px = at, .mods = .{}, .time_ns = 0 } });
    try hl.inject(.{ .pointer_button = .{ .win = hw.id, .button = .left, .pressed = true, .pos_px = at, .mods = .{}, .clicks = 1, .time_ns = 0 } });
    try hl.inject(.{ .pointer_button = .{ .win = hw.id, .button = .left, .pressed = false, .pos_px = at, .mods = .{}, .clicks = 1, .time_ns = 0 } });
    _ = try host.pump();
    try hl.tick(hl.opts.refresh_ns);
    _ = try host.pump();
    try std.testing.expectEqual(@as(u32, 1), v.clicks);

    // Close request.
    try hl.inject(.{ .window_close_requested = hw.id });
    _ = try host.pump();
    try std.testing.expectEqual(@as(usize, 0), host.windows.items.len);
}
