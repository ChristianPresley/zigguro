//! Floating windows (E04.F07.S02.T02) through a `Host` on the headless
//! platform: tear-off opens a window showing the panel, a tab dragged to
//! another window moves there, a drag nothing takes tears off, closing a
//! floating window docks back to the last group, and saved rects are put
//! back on screen.

const std = @import("std");
const zg_platform = @import("zg_platform");
const app_mod = @import("../core/app.zig");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const text = @import("../paint/text.zig");
const Host = @import("../host.zig").Host;
const model = @import("model.zig");
const view = @import("view.zig");
const floating = @import("floating.zig");

const Headless = zg_platform.headless.Headless;
const Ui = ui_mod.Ui;
const DockModel = model.DockModel;
const PanelRef = model.PanelRef;
const testing = std.testing;
const gpa = testing.allocator;

const Page = struct {
    dock: DockModel,
    dv: view.DockView = undefined,
    titles: [8][]const u8 = .{ "a", "b", "c", "d", "e", "f", "g", "h" },
    /// Each panel's own state (kept by the app, not the window).
    counts: [8]u32 = @splat(0),
    /// The window each panel was last built in.
    built_in: [8]?*@import("../core/window.zig").Window = @splat(null),
    keep: ?PanelRef = null,

    pub fn build(p: *Page, ui: *Ui) void {
        p.dv.beginFrame(ui);
        ui.open(.{ .style = .{ .dir = .row, .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .align_items = .stretch } });
        defer ui.close();
        p.dv.dockArea(ui, .center);
        p.dv.dropOverlay(ui);
    }

    fn tab(ctx: *anyopaque, r: PanelRef) view.TabInfo {
        const p: *Page = @ptrCast(@alignCast(ctx));
        return .{ .title = p.titles[@intFromEnum(r) % 8] };
    }

    fn content(ctx: *anyopaque, ui: *Ui, r: PanelRef) void {
        const p: *Page = @ptrCast(@alignCast(ctx));
        p.counts[@intFromEnum(r) % 8] += 1;
        p.built_in[@intFromEnum(r) % 8] = ui.window();
        ui.text(p.titles[@intFromEnum(r) % 8], .{});
    }

    fn canClose(ctx: *anyopaque, r: PanelRef) bool {
        const p: *Page = @ptrCast(@alignCast(ctx));
        return p.keep != r;
    }
};

const Fx = struct {
    hl: *Headless,
    app: app_mod.App,
    mono: text.MonoText = .{},
    host: Host,
    page: Page,
    fl: floating.Floater,
    main: *@import("../host.zig").HostWindow,
    ps: [3]PanelRef,

    fn init(f: *Fx, policy: floating.FloatingPolicy) !void {
        f.hl = try Headless.init(gpa, testing.io, .{});
        f.app = app_mod.App.init(gpa);
        f.mono = .{};
        f.host = Host.init(gpa, testing.io, &f.app, f.hl.platform(), f.mono.system(), .{ .render_thread = false });
        f.page = .{ .dock = try DockModel.init(gpa) };
        const ph: view.PanelHost = .{ .ctx = &f.page, .tab = Page.tab, .build = Page.content, .can_close = Page.canClose };
        f.page.dv = .init(gpa, &f.page.dock, ph);
        f.fl = .init(gpa, &f.page.dock, ph, f.host.windowOpener(), policy);
        f.main = try f.host.open(.{ .title = "main", .size = .{ .w = 800, .h = 400 }, .root = view_mod.AnyView.of(&f.page) });
        f.fl.attachMain(f.main.win, &f.page.dv);
        const g = f.page.dock.firstGroup(f.page.dock.areas[@intFromEnum(model.Area.center)].root).?;
        for (&f.ps) |*p| {
            p.* = try f.page.dock.addPanel(1, null);
            try f.page.dock.openIn(p.*, g, null, .{});
        }
        try f.frames();
    }

    fn deinit(f: *Fx) void {
        f.fl.closeAll();
        f.host.deinit();
        f.fl.deinit();
        f.page.dv.deinit();
        f.page.dock.deinit();
        f.app.deinit();
        f.hl.deinit();
    }

    /// Pumps events and renders every window that asked for a frame.
    fn frames(f: *Fx) !void {
        for (0..3) |_| {
            _ = try f.host.pump();
            try f.hl.tick(f.hl.opts.refresh_ns);
        }
        _ = try f.host.pump();
    }

    fn floatWin(f: *Fx) *@import("../host.zig").HostWindow {
        for (f.host.windows.items) |hw| if (hw != f.main) return hw;
        unreachable;
    }

    /// Presses tab `i` of the main window and drags it out to the left.
    fn dragOut(f: *Fx, i: usize) !void {
        const w = f.main.win;
        const r = w.layoutRect(f.page.dv.tab_nodes.items[i]);
        const at: [2]f32 = .{ r.x + r.w / 2, r.y + r.h / 2 };
        const id = f.main.id;
        try f.hl.inject(.{ .pointer_move = .{ .win = id, .pos_px = at, .mods = .{}, .time_ns = 0 } });
        try f.hl.inject(.{ .pointer_button = .{ .win = id, .button = .left, .pressed = true, .pos_px = at, .mods = .{}, .clicks = 1, .time_ns = 0 } });
        try f.hl.inject(.{ .pointer_move = .{ .win = id, .pos_px = .{ at[0] + 20, at[1] + 30 }, .mods = .{}, .time_ns = 0 } });
        try f.hl.inject(.{ .pointer_move = .{ .win = id, .pos_px = .{ -40, at[1] + 30 }, .mods = .{}, .time_ns = 0 } });
        _ = try f.host.pump();
    }

    fn drop(f: *Fx, hw: anytype, phase: zg_platform.clipboard.DropPhase, pos: [2]f32, bytes: []const u8, mlen: u32, dlen: u32) !void {
        try f.hl.injectPayload(.{ .drop = .{ .win = hw.id, .phase = phase, .allowed = .{ .move = true }, .pos_px = pos, .mimes = .{ .off = 0, .len = mlen }, .data = .{ .off = 0, .len = dlen } } }, bytes);
        _ = try f.host.pump();
    }

    fn finish(f: *Fx, allowed: zg_platform.clipboard.DragActions) !void {
        try f.hl.inject(.{ .drop = .{ .win = f.main.id, .phase = .source_finished, .allowed = allowed, .pos_px = .{ 0, 0 } } });
        try f.frames();
    }
};

test "tear off creates window with panel" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const b = try f.page.dock.addPanel(1, "cursor=42");
    try f.page.dock.openIn(b, f.page.dock.groupOf(f.ps[0]).?, null, .{});
    try f.frames();
    const before = f.page.counts[@intFromEnum(b) % 8];
    const w = try f.fl.tearOff(b, .{ .x = 100, .y = 80 }, .{ .w = 400, .h = 300 });
    try f.frames();
    try testing.expectEqual(@as(usize, 2), f.host.windows.items.len);
    try testing.expectEqual(@as(f32, 400), w.size.w);
    const fid = f.page.dock.floatOf(b).?;
    try testing.expectEqual(@as(f32, 100), f.page.dock.float(fid).?.rect.x);
    // The headless monitor is recorded.
    try testing.expect(f.page.dock.float(fid).?.monitor.len > 0);
    // The panel builds in the new window; its state came along.
    try testing.expectEqual(w, f.page.built_in[@intFromEnum(b) % 8].?);
    try testing.expect(f.page.counts[@intFromEnum(b) % 8] > before);
    try testing.expectEqualStrings("cursor=42", f.page.dock.panels.get(b).?.state.?);
    try testing.expectEqual(f.fl.windowOf(b).?, w);
    try testing.expectEqual(f.fl.windowOf(f.ps[0]).?, f.main.win);
    // The main window keeps the other three.
    try testing.expectEqual(@as(usize, 3), f.page.dv.tab_nodes.items.len);
}

test "drag between windows moves panel" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    _ = try f.fl.tearOff(f.ps[2], .{ .x = 0, .y = 0 }, .{ .w = 400, .h = 300 });
    try f.frames();
    const fw = f.floatWin();
    // Drag "a" out of the main window: a platform drag starts.
    try f.dragOut(0);
    try testing.expect(f.fl.out != null);
    try testing.expect(f.main.win.drag_out == null);
    // Over the floating window's tab strip: previewed and accepted.
    var mimes: [2]u8 = undefined;
    std.mem.writeInt(u16, &mimes, @intFromEnum(zg_platform.clipboard.MimeId.zigguro_internal), .little);
    try f.drop(fw, .enter, .{ 200, 60 }, &mimes, 2, 0);
    try testing.expectEqual(@as(?bool, true), fw.win.drop.sent);
    try testing.expect(f.fl.winByWindow(fw.win).?.dv.drag != null);
    const payload = floating.encodeTab(f.fl.token, f.ps[0]);
    try f.drop(fw, .drop, .{ 200, 60 }, &payload, 0, payload.len);
    try f.finish(.{ .move = true });
    // "a" now floats with "c"; nothing was torn off.
    try testing.expectEqual(f.page.dock.floatOf(f.ps[2]).?, f.page.dock.floatOf(f.ps[0]).?);
    try testing.expectEqual(@as(usize, 1), f.page.dock.floating.items.len);
    try testing.expectEqual(@as(usize, 2), f.host.windows.items.len);
    try testing.expect(f.fl.out == null);
    try testing.expect(f.page.dv.drag == null);
}

test "a drag nothing takes tears off where it ended" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.dragOut(1);
    try f.finish(.{});
    try testing.expect(f.page.dock.floatOf(f.ps[1]) != null);
    try testing.expectEqual(@as(usize, 2), f.host.windows.items.len);
    // Another process's tab is refused.
    try testing.expectEqual(@as(?PanelRef, null), floating.decodeTab(f.fl.token +% 1, &floating.encodeTab(f.fl.token, f.ps[1])));
}

test "close docks back to last group" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const home = f.page.dock.groupOf(f.ps[1]).?;
    _ = try f.fl.tearOff(f.ps[1], .{ .x = 10, .y = 10 }, .{ .w = 300, .h = 200 });
    try f.frames();
    const fw = f.floatWin();
    try f.hl.inject(.{ .window_close_requested = fw.id });
    try f.frames();
    try testing.expectEqual(@as(usize, 1), f.host.windows.items.len);
    try testing.expectEqual(home, f.page.dock.groupOf(f.ps[1]).?);
    try testing.expectEqual(@as(usize, 0), f.page.dock.floating.items.len);
    try testing.expectEqual(f.main.win, f.page.built_in[@intFromEnum(f.ps[1]) % 8].?);
    // "Dock back" with a target.
    const w2 = try f.fl.tearOff(f.ps[0], .{ .x = 10, .y = 10 }, .{ .w = 300, .h = 200 });
    try f.frames();
    f.fl.dockBack(w2, .{ .area = .right });
    try f.frames();
    try testing.expectEqual(@as(?model.Owner, .{ .area = .right }), f.page.dock.ownerOf(.{ .group = f.page.dock.groupOf(f.ps[0]).? }));
    try testing.expectEqual(@as(usize, 1), f.host.windows.items.len);
}

test "close without docking back asks each panel" {
    var f: Fx = undefined;
    try f.init(.{ .close_docks_back = false });
    defer f.deinit();
    _ = try f.fl.tearOff(f.ps[1], .{ .x = 10, .y = 10 }, .{ .w = 300, .h = 200 });
    try f.frames();
    f.page.keep = f.ps[1];
    const fw = f.floatWin();
    try f.hl.inject(.{ .window_close_requested = fw.id });
    try f.frames();
    // Vetoed: still open.
    try testing.expectEqual(@as(usize, 2), f.host.windows.items.len);
    f.page.keep = null;
    try f.hl.inject(.{ .window_close_requested = fw.id });
    try f.frames();
    try testing.expectEqual(@as(usize, 1), f.host.windows.items.len);
    try testing.expectEqual(@as(?model.GroupId, null), f.page.dock.groupOf(f.ps[1]));
}

test "closing the main window docks floating panels back" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    _ = try f.fl.tearOff(f.ps[1], .{ .x = 10, .y = 10 }, .{ .w = 300, .h = 200 });
    try f.frames();
    try f.hl.inject(.{ .window_close_requested = f.main.id });
    _ = try f.host.pump();
    try testing.expectEqual(@as(usize, 0), f.host.windows.items.len);
    try testing.expectEqual(@as(usize, 0), f.page.dock.floating.items.len);
    try testing.expect(f.page.dock.groupOf(f.ps[1]) != null);
}

fn monitor(name: []const u8, x: i32, w: u32, primary: bool, scale: f32) zg_platform.types.MonitorInfo {
    var m: zg_platform.types.MonitorInfo = .{
        .id = 1,
        .rect_px = .{ .x = x, .y = 0, .w = w, .h = 1000 },
        .work_px = .{ .x = x, .y = 0, .w = w, .h = 960 },
        .scale = .{ .factor = scale },
        .refresh_mhz = 60000,
        .primary = primary,
    };
    @memcpy(m.name_buf[0..name.len], name);
    m.name_len = @intCast(name.len);
    return m;
}

test "restore clamps offscreen rect" {
    const mons = [_]zg_platform.types.MonitorInfo{ monitor("DP-1", 0, 1600, true, 1), monitor("HDMI-1", 1600, 2400, false, 2) };
    // On its monitor (logical 800..2000 for HDMI-1 at scale 2): kept.
    const on = floating.restoreRect(.{ .x = 900, .y = 100, .w = 400, .h = 300 }, "HDMI-1", &mons);
    try testing.expectEqual(@as(f32, 900), on.x);
    // Hanging off the bottom: moved inside its work area.
    const low = floating.restoreRect(.{ .x = 900, .y = 400, .w = 400, .h = 300 }, "HDMI-1", &mons);
    try testing.expectEqual(@as(f32, 180), low.y);
    // Off screen: centered on the primary.
    const off = floating.restoreRect(.{ .x = 5000, .y = 100, .w = 400, .h = 300 }, "HDMI-1", &mons);
    try testing.expectEqual(@as(f32, 600), off.x);
    try testing.expectEqual(@as(f32, 330), off.y);
    // The monitor is gone: the primary, clamped to it.
    const gone = floating.restoreRect(.{ .x = 0, .y = 0, .w = 4000, .h = 300 }, "DP-9", &mons);
    try testing.expectEqual(@as(f32, 0), gone.x);
    try testing.expectEqual(@as(f32, 1600), gone.w);
    // No monitors: unchanged.
    const none = floating.restoreRect(.{ .x = 5000, .y = 1, .w = 2, .h = 3 }, "", &.{});
    try testing.expectEqual(@as(f32, 5000), none.x);
}

test "wayland path uses private mime" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    // The drag offers only the internal type, with this process's token.
    try f.dragOut(0);
    const o = f.fl.out.?;
    try testing.expectEqual(f.ps[0], o.p);
    // A file drag over the same window is not taken as a tab.
    var mimes: [2]u8 = undefined;
    std.mem.writeInt(u16, &mimes, @intFromEnum(zg_platform.clipboard.MimeId.uri_list), .little);
    try f.drop(f.main, .enter, .{ 200, 60 }, &mimes, 2, 0);
    try testing.expect(!f.main.win.drop.internal);
    try f.drop(f.main, .leave, .{ 200, 60 }, "", 0, 0);
    // Our own drag dropped back on the main window's strip reorders.
    std.mem.writeInt(u16, &mimes, @intFromEnum(zg_platform.clipboard.MimeId.zigguro_internal), .little);
    try f.drop(f.main, .enter, .{ 700, 10 }, &mimes, 2, 0);
    try testing.expect(f.main.win.drop.internal);
    try testing.expectEqual(zg_platform.clipboard.MimeId.zigguro_internal, f.main.win.drop.mime);
    const payload = floating.encodeTab(f.fl.token, f.ps[0]);
    try f.drop(f.main, .drop, .{ 700, 10 }, &payload, 0, payload.len);
    try f.finish(.{ .move = true });
    const g = f.page.dock.group(f.page.dock.groupOf(f.ps[0]).?).?;
    try testing.expectEqual(f.ps[0], g.tabs.items[g.tabs.items.len - 1]);
    try testing.expectEqual(@as(usize, 0), f.page.dock.floating.items.len);
}

test "a restored floating window opens at its place, above others" {
    var f: Fx = undefined;
    try f.init(.{ .always_on_top = true });
    defer f.deinit();
    try f.page.dock.move(f.ps[1], .{ .float = .{ .x = 120, .y = 60, .w = 400, .h = 300 } });
    const fm = &f.page.dock.floating.items[0];
    fm.monitor.set("HEADLESS-1");
    try f.fl.sync();
    try f.frames();
    const hw = f.floatWin();
    const scale = f.hl.opts.scale.factor;
    const at = f.hl.placement(hw.id).?;
    try testing.expectEqual(@as(i32, @intFromFloat(@round(120 * scale))), at.position.?.x);
    try testing.expectEqual(@as(i32, @intFromFloat(@round(60 * scale))), at.position.?.y);
    try testing.expect(at.always_on_top);
    f.fl.setAlwaysOnTop(false);
    try f.frames();
    try testing.expect(!f.hl.placement(hw.id).?.always_on_top);
}
