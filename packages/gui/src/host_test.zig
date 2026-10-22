//! `Host` against the headless platform: a window opens, renders through
//! the software renderer (on its render thread, or on the UI thread),
//! reacts to input and closes.

const std = @import("std");
const zg_platform = @import("zg_platform");
const app_mod = @import("core/app.zig");
const ui_mod = @import("core/ui.zig");
const view_mod = @import("core/view.zig");
const text = @import("paint/text.zig");
const controls = @import("widgets/controls.zig");
const Host = @import("host.zig").Host;
const FontText = @import("paint/font_text.zig").FontText;

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

const flush_ns = 5 * std.time.ns_per_s;

test "host opens, renders, clicks and closes a window" {
    try openRenderClick(true);
}

test "host renders on the UI thread when asked to" {
    try openRenderClick(false);
}

fn openRenderClick(threaded: bool) !void {
    const gpa = std.testing.allocator;
    const hl = try Headless.init(gpa, std.testing.io, .{});
    defer hl.deinit();
    var app = app_mod.App.init(gpa);
    defer app.deinit();
    var mono: text.MonoText = .{};
    var host = Host.init(gpa, std.testing.io, &app, hl.platform(), mono.system(), .{ .render_thread = threaded });
    defer host.deinit();
    var v: Counter = .{};
    const hw = try host.open(.{ .title = "test", .size = .{ .w = 200, .h = 100 }, .root = view_mod.AnyView.of(&v) });
    if (!threaded) try std.testing.expect(hw.out == .direct);

    // Configure, then the first frame on the next vsync.
    _ = try host.pump();
    try std.testing.expect(hw.frame_requested);
    try hl.tick(hl.opts.refresh_ns);
    _ = try host.pump();
    try std.testing.expectEqual(@as(u64, 1), hw.frames);
    try std.testing.expect(host.flush(flush_ns));
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
    try std.testing.expect(host.flush(flush_ns));

    // Close request.
    try hl.inject(.{ .window_close_requested = hw.id });
    _ = try host.pump();
    try std.testing.expectEqual(@as(usize, 0), host.windows.items.len);
}

/// Paints a block whose colour the test flips between frames.
const Flip = struct {
    on: bool = false,
    pub fn build(self: *Flip, ui: *ui_mod.Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .bg = .{ .token = if (self.on) .accent else .bg_base } } });
        ui.close();
    }
};

test "host: frames reach the screen in order through the render thread" {
    const gpa = std.testing.allocator;
    const hl = try Headless.init(gpa, std.testing.io, .{});
    defer hl.deinit();
    var app = app_mod.App.init(gpa);
    defer app.deinit();
    var mono: text.MonoText = .{};
    var host = Host.init(gpa, std.testing.io, &app, hl.platform(), mono.system(), .{});
    defer host.deinit();
    var v: Flip = .{};
    const hw = try host.open(.{ .title = "flip", .size = .{ .w = 40, .h = 20 }, .root = view_mod.AnyView.of(&v) });
    // std.testing.io can spawn: the window renders on its thread.
    try std.testing.expect(hw.out == .thread);
    const on = app.theme.color(.accent);
    const off = app.theme.color(.bg_base);
    for (0..6) |i| {
        v.on = i % 2 == 1;
        hw.win.markAllDirty();
        _ = try host.pump();
        try hl.tick(hl.opts.refresh_ns);
        _ = try host.pump();
        try std.testing.expect(host.flush(flush_ns));
        const want = if (v.on) on else off;
        try std.testing.expectEqualSlices(u8, &.{ want.r, want.g, want.b }, pixel(hl.lastFrame(hw.id).?, 20, 10)[0..3]);
    }
    try std.testing.expectEqual(@as(u64, 6), hw.frames);
    // Resizes go to the render thread with the next frame.
    // (Headless frames are clipped to the window, so shrink it.)
    try hl.inject(.{ .window_configure = .{ .win = hw.id, .size = .{ .w = 30, .h = 20 }, .scale = .{ .factor = 1 }, .state = .{}, .serial = 1, .screen_origin_px = null } });
    _ = try host.pump();
    try hl.tick(hl.opts.refresh_ns);
    _ = try host.pump();
    try std.testing.expect(host.flush(flush_ns));
    try std.testing.expectEqual(@as(u32, 30), hl.lastFrame(hw.id).?.width);
}

test "host keeps the app clipboard in sync with the platform" {
    const gpa = std.testing.allocator;
    const hl = try Headless.init(gpa, std.testing.io, .{});
    defer hl.deinit();
    var app = app_mod.App.init(gpa);
    defer app.deinit();
    var mono: text.MonoText = .{};
    var host = Host.init(gpa, std.testing.io, &app, hl.platform(), mono.system(), .{});
    defer host.deinit();

    // A widget's Copy goes out on the next pump.
    app.clipboard.set(gpa, "from app");
    _ = try host.pump();
    try std.testing.expect(!app.clipboard.pending_write);
    try std.testing.expectEqualStrings("from app", hl.clip[@intFromEnum(zg_platform.clipboard.Selection.clipboard)][0].data);

    // Another app's copy is read back into the app clipboard.
    try hl.setClipboard(.clipboard, .text_utf8, "from elsewhere");
    _ = try host.pump();
    _ = try host.pump();
    try std.testing.expectEqualStrings("from elsewhere", app.clipboard.get());
    try std.testing.expect(app.now_ms > 0);
}

const Label = struct {
    pub fn build(_: *Label, ui: *ui_mod.Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .bg = .{ .token = .bg_base }, .padding = .all(10) } });
        defer ui.close();
        ui.text("Hello, zigguro", .{});
    }
};

test "host draws real glyphs through FontText" {
    const gpa = std.testing.allocator;
    const fonts = try @import("paint/font_text_test.zig").TestFonts.load(gpa);
    defer fonts.deinit(gpa);
    const ft = try FontText.create(gpa, .{ .ui = fonts.ui, .mono = fonts.mono });
    defer ft.destroy();
    const hl = try Headless.init(gpa, std.testing.io, .{});
    defer hl.deinit();
    var app = app_mod.App.init(gpa);
    defer app.deinit();
    var host = Host.init(gpa, std.testing.io, &app, hl.platform(), ft.system(), .{ .fonts = ft });
    defer host.deinit();
    var v: Label = .{};
    const hw = try host.open(.{ .title = "text", .size = .{ .w = 200, .h = 40 }, .root = view_mod.AnyView.of(&v) });
    _ = try host.pump();
    try hl.tick(hl.opts.refresh_ns);
    _ = try host.pump();
    try std.testing.expectEqual(@as(u64, 1), hw.frames);
    try std.testing.expect(hw.pages.items.len == 1);
    try std.testing.expect(host.flush(flush_ns));

    // The text row has light (foreground) pixels; the area below has none.
    const f = hl.lastFrame(hw.id).?;
    const bg = app.theme.color(.bg_base);
    var lit: u32 = 0;
    for (10..28) |y| for (10..120) |x| {
        const p = pixel(f, @intCast(x), @intCast(y));
        if (@as(u32, p[0]) + p[1] + p[2] > @as(u32, bg.r) + bg.g + bg.b + 120) lit += 1;
    };
    try std.testing.expect(lit > 60);
    for (32..40) |y| for (10..190) |x| {
        try std.testing.expectEqualSlices(u8, &.{ bg.r, bg.g, bg.b }, pixel(f, @intCast(x), @intCast(y))[0..3]);
    };
}

test "host: pacing follows the renderer" {
    const gpa = std.testing.allocator;
    const zg_vulkan = @import("zg_vulkan");
    const pacingFor = @import("host.zig").pacingFor;
    var sink: zg_platform.surface.HeadlessSink = .{ .ptr = undefined, .write = undefined };
    // Software renderers pace on the platform's frame events.
    const sw = try zg_vulkan.createRenderer(gpa, std.testing.io, .{ .target = .{ .headless = &sink }, .backend = .software });
    defer sw.deinit();
    const p = pacingFor(sw);
    try std.testing.expectEqual(zg_vulkan.present.FramePacer.Mode.platform_frame, p.mode);
    try std.testing.expect(p.waiter == null);
    // A headless Vulkan target has no presentation engine: no waits.
    const vk = zg_vulkan.createRenderer(gpa, std.testing.io, .{ .target = .{ .headless = &sink }, .backend = .vulkan }) catch return;
    defer vk.deinit();
    const q = pacingFor(vk);
    try std.testing.expectEqual(zg_vulkan.present.FramePacer.Mode.immediate, q.mode);
    try std.testing.expect(q.waiter == null);
}

test "host sends the window's IME state when it changes" {
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
    _ = try host.pump();
    const pw = hl.windows.getPtr(@intFromEnum(hw.id)).?;
    try std.testing.expect(!pw.ime_enabled);

    // A text input asks for the IME; the next pump tells the platform.
    const node = hw.win.root;
    hw.win.setIme(node, .{ .caret = .{ .x = 10, .y = 20, .w = 2, .h = 16 }, .surrounding = .{ .text = "abc", .cursor_byte = 3, .anchor_byte = 3 } });
    _ = try host.pump();
    try std.testing.expect(pw.ime_enabled);
    try std.testing.expectEqual(hw.win.ime.serial, hw.ime_sent);

    // The same request again changes nothing.
    const sent = hw.ime_sent;
    hw.win.setIme(node, .{ .caret = .{ .x = 10, .y = 20, .w = 2, .h = 16 }, .surrounding = .{ .text = "abc", .cursor_byte = 3, .anchor_byte = 3 } });
    try std.testing.expectEqual(sent, hw.win.ime.serial);

    hw.win.setIme(node, null);
    _ = try host.pump();
    try std.testing.expect(!pw.ime_enabled);
}
