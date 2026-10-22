//! Input routing, hit testing and focus (E04.F03).

const std = @import("std");
const zg_platform = @import("zg_platform");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const geom = @import("../core/geom.zig");
const controls = @import("../widgets/controls.zig");
const keys_mod = @import("keys.zig");
const event = @import("event.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;

const Form = struct {
    clicks: [3]u32 = .{ 0, 0, 0 },
    cancelled: u32 = 0,

    pub fn build(self: *Form, ui: *Ui) void {
        ui.open(.{ .style = .{ .gap = 8, .padding = .all(10), .align_items = .start }, .key_context = "form" });
        defer ui.close();
        for ([_][]const u8{ "One", "Two", "Three" }, 0..) |label, i| {
            const r = controls.button(ui, .{ .label = label });
            if (r.clicked) self.clicks[i] += 1;
            if (r.cancelled) self.cancelled += 1;
        }
    }
};

test "click reports clicked once" {
    var f: Form = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&f) });
    defer t.deinit();
    _ = t.settle();
    try t.click(.{ .name = "Two" });
    try std.testing.expectEqual([3]u32{ 0, 1, 0 }, f.clicks);
    t.win.markAllDirty();
    _ = t.settle();
    try std.testing.expectEqual([3]u32{ 0, 1, 0 }, f.clicks);
}

test "release outside the pressed node does not click" {
    var f: Form = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&f) });
    defer t.deinit();
    _ = t.settle();
    const r = try t.rectOf(.{ .name = "One" });
    const p: geom.Vec2 = .{ .x = r.x + 2, .y = r.y + 2 };
    t.win.dispatch(.{ .pointer_down = .{ .pos = p } });
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = 700, .y = 500 } } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = 700, .y = 500 } } });
    _ = t.settle();
    try std.testing.expectEqual([3]u32{ 0, 0, 0 }, f.clicks);
}

test "hover damage is the node rect plus the focus ring outset" {
    var f: Form = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&f) });
    defer t.deinit();
    _ = t.settle();
    const r = try t.rectOf(.{ .name = "Two" });
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = r.x + 3, .y = r.y + 3 } } });
    const st = t.frame();
    try std.testing.expect(st.presented);
    try std.testing.expectEqual(@as(u32, 0), st.views_built);
    try std.testing.expectEqual(@as(u32, 1), st.nodes_painted);
    try std.testing.expectEqual(@as(usize, 1), t.rec.damage.items.len);
    const ring = t.app.theme.dim(.focus_ring_w) + t.app.theme.dim(.focus_ring_offset);
    try std.testing.expect(t.rec.damage.items[0].eql(r.outset(ring)));
}

test "tab order, wrap and shift-tab" {
    var f: Form = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&f) });
    defer t.deinit();
    _ = t.settle();
    const one = t.find(.{ .name = "One" }).?;
    const two = t.find(.{ .name = "Two" }).?;
    const three = t.find(.{ .name = "Three" }).?;
    t.press(.tab, .{});
    try std.testing.expect(t.win.focus.eql(one));
    try std.testing.expect(t.win.focus_visible);
    t.press(.tab, .{});
    try std.testing.expect(t.win.focus.eql(two));
    t.press(.tab, .{});
    t.press(.tab, .{});
    try std.testing.expect(t.win.focus.eql(one));
    t.press(.tab, .{ .shift = true });
    try std.testing.expect(t.win.focus.eql(three));
    // The focus ring is painted: a border op around the focused button.
    try std.testing.expect(std.mem.indexOf(u8, t.paintSnapshot(), "border") != null);
}

test "enter and space activate the focused button; escape cancels" {
    var f: Form = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&f) });
    defer t.deinit();
    _ = t.settle();
    t.press(.tab, .{});
    t.press(.enter, .{});
    t.press(.space, .{});
    try std.testing.expectEqual([3]u32{ 2, 0, 0 }, f.clicks);
    t.press(.escape, .{});
    try std.testing.expectEqual(@as(u32, 1), f.cancelled);
}

test "clicking focuses without a visible ring" {
    var f: Form = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&f) });
    defer t.deinit();
    _ = t.settle();
    try t.click(.{ .name = "Three" });
    try std.testing.expect(t.win.focus.eql(t.find(.{ .name = "Three" }).?));
    try std.testing.expect(!t.win.focus_visible);
}

const Recorder = struct {
    got: std.ArrayList(u8) = .empty,
    fn handle(p: *anyopaque, k: event.KeyPress, ctxs: []const []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(p));
        if (k.key != .key_p) return false;
        for (ctxs) |c| self.got.appendSlice(std.testing.allocator, c) catch {};
        return true;
    }
};

test "unhandled keys reach the key handler with key contexts" {
    var f: Form = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&f) });
    defer t.deinit();
    var rec: Recorder = .{};
    defer rec.got.deinit(std.testing.allocator);
    t.win.key_handler = .{ .ptr = &rec, .handle = Recorder.handle };
    _ = t.settle();
    t.press(.tab, .{});
    t.press(.key_p, .{ .ctrl = true, .shift = true });
    try std.testing.expectEqualStrings("form", rec.got.items);
}

const Layered = struct {
    hits: u32 = 0,
    pub fn build(self: *Layered, ui: *Ui) void {
        ui.open(.{ .style = .{ .display = .stack, .w = .{ .px = 200 }, .h = .{ .px = 200 } } });
        defer ui.close();
        ui.open(.{ .test_id = "top", .hit = true, .style = .{ .z = 1 } });
        if (ui.response().clicked) self.hits += 1;
        ui.close();
        ui.open(.{ .test_id = "under", .hit = true });
        ui.close();
    }
};

test "z order decides the hit target" {
    var l: Layered = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&l) });
    defer t.deinit();
    _ = t.settle();
    const top = t.find(.{ .test_id = "top" }).?;
    try std.testing.expect(t.win.hitTest(.{ .x = 50, .y = 50 }).eql(top));
    try t.click(.{ .test_id = "under" });
    try std.testing.expectEqual(@as(u32, 1), l.hits);
}

test "platform events are translated with the window scale" {
    var f: Form = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&f), .scale = 2 });
    defer t.deinit();
    _ = t.settle();
    const r = try t.rectOf(.{ .name = "One" });
    const px: [2]f32 = .{ (r.x + 4) * 2, (r.y + 4) * 2 };
    const Payload = struct {
        pub fn payload(_: @This(), _: zg_platform.types.PayloadSlice) []const u8 {
            return "";
        }
    };
    const win: zg_platform.types.WindowId = @enumFromInt(1);
    t.win.handlePlatformEvent(.{ .pointer_button = .{ .win = win, .button = .left, .pressed = true, .pos_px = px, .mods = .{}, .clicks = 1, .time_ns = 0 } }, Payload{});
    t.win.handlePlatformEvent(.{ .pointer_button = .{ .win = win, .button = .left, .pressed = false, .pos_px = px, .mods = .{}, .clicks = 1, .time_ns = 0 } }, Payload{});
    _ = t.settle();
    try std.testing.expectEqual([3]u32{ 1, 0, 0 }, f.clicks);
    _ = keys_mod;
}
