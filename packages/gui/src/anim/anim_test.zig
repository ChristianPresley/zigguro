//! The animator in a window (E04.F08.S03.T01): visuals in the paint pass,
//! hit testing, FLIP, idle-zero, reduced motion and unmount.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const ids = @import("../core/ids.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;
const presets = @import("presets.zig");

const Ui = ui_mod.Ui;
const AnyView = view_mod.AnyView;
const NodeId = ids.NodeId;

/// Two keyed 50×40 hit-testable boxes in a column ("a" then "b", or
/// swapped), "b" optional.
const Boxes = struct {
    swap: bool = false,
    show_b: bool = true,

    pub fn build(self: *Boxes, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column } });
        defer ui.close();
        const order: [2]u8 = if (self.swap) .{ 1, 0 } else .{ 0, 1 };
        for (order) |k| {
            if (k == 1 and !self.show_b) continue;
            ui.id(k);
            ui.open(.{ .test_id = if (k == 0) "a" else "b", .hit = true, .style = .{ .w = .{ .px = 50 }, .h = .{ .px = 40 }, .bg = .{ .token = .accent } } });
            ui.close();
        }
    }
};

const frame_ns = 8_333_333;

/// Runs one frame `frame_ns` later.
fn step(t: *TestApp) @import("../core/window.zig").FrameStats {
    t.win.frame_target_ns += frame_ns;
    t.app.now_ms = t.win.frame_target_ns / std.time.ns_per_ms;
    return t.frame();
}

fn setup(gpa: std.mem.Allocator, v: *Boxes) !*TestApp {
    const t = try TestApp.init(gpa, .{ .root = AnyView.of(v) });
    t.app.now_ms = 1000;
    t.win.frame_target_ns = 1000 * std.time.ns_per_ms;
    _ = t.settle();
    return t;
}

test "hit test uses visual rect" {
    const gpa = std.testing.allocator;
    var v: Boxes = .{};
    const t = try setup(gpa, &v);
    defer t.deinit();
    const a = t.find(.{ .test_id = "a" }).?;
    t.win.setVisual(a, .{ .translate = .{ .x = 300, .y = 0 } });
    const st = t.frame();
    try std.testing.expect(st.presented);
    try std.testing.expect(t.win.hits.hit(.{ .x = 320, .y = 10 }).eql(a));
    try std.testing.expect(!t.win.hits.hit(.{ .x = 10, .y = 10 }).eql(a));
    // The stored rect is the visual one; the layout one did not move.
    try std.testing.expectEqual(@as(f32, 300), t.win.store.absRect(a).x);
    try std.testing.expectEqual(@as(f32, 0), t.win.layoutRect(a).x);
    // Scale about the centre: the box shrinks around (25, 20).
    t.win.setVisual(a, .{ .scale = 0.5 });
    _ = t.frame();
    const r = t.win.store.absRect(a);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), r.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 25), r.w, 1e-4);
    try std.testing.expect(!t.win.hits.hit(.{ .x = 5, .y = 5 }).eql(a));
    try std.testing.expect(t.win.hits.hit(.{ .x = 25, .y = 20 }).eql(a));
}

test "faded and scaled ops replay transformed" {
    const gpa = std.testing.allocator;
    var v: Boxes = .{ .show_b = false };
    const t = try setup(gpa, &v);
    defer t.deinit();
    const a = t.find(.{ .test_id = "a" }).?;
    t.win.setVisual(a, .{ .opacity = 0.5, .scale = 2 });
    _ = t.frame();
    const snap = t.paintSnapshot();
    // 50×40 doubled about the centre (25, 20): x −25, y −20, 100×80.
    try std.testing.expect(std.mem.indexOf(u8, snap, "-25,-20 100x80") != null);
}

test "animator idle when settled" {
    const gpa = std.testing.allocator;
    var v: Boxes = .{};
    const t = try setup(gpa, &v);
    defer t.deinit();
    const a = t.find(.{ .test_id = "a" }).?;
    try std.testing.expect(!t.win.wantsFrame());
    _ = t.win.animate(.{ .node_opacity = a }, 0.2, .{ .spring = .{} });
    try std.testing.expect(t.win.wantsFrame());
    var frames: u32 = 0;
    while (t.win.wantsFrame()) : (frames += 1) {
        try std.testing.expect(frames < 200);
        _ = step(t);
    }
    try std.testing.expectEqual(@as(f32, 0.2), t.win.visualOf(a).opacity);
    // Settled: frames do nothing.
    try std.testing.expect(step(t).idle);
}

test "FLIP lays out once" {
    const gpa = std.testing.allocator;
    var v: Boxes = .{};
    const t = try setup(gpa, &v);
    defer t.deinit();
    const a = t.find(.{ .test_id = "a" }).?;
    const b = t.find(.{ .test_id = "b" }).?;
    t.win.flip(&.{ a, b }, presets.spring_default);
    v.swap = true;
    t.win.markAllDirty();
    const first = step(t);
    try std.testing.expect(first.layout.visited > 0);
    // Laid out swapped, painted where they were.
    try std.testing.expectEqual(@as(f32, 40), t.win.layoutRect(a).y);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.win.store.absRect(a).y, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 40), t.win.store.absRect(b).y, 1e-3);
    var frames: u32 = 0;
    var moved = false;
    while (t.win.wantsFrame()) : (frames += 1) {
        try std.testing.expect(frames < 200);
        const st = step(t);
        try std.testing.expectEqual(@as(u32, 0), st.layout.visited);
        try std.testing.expectEqual(@as(u32, 0), st.nodes_painted);
        if (st.presented) moved = true;
    }
    try std.testing.expect(moved);
    try std.testing.expectApproxEqAbs(@as(f32, 40), t.win.store.absRect(a).y, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.win.store.absRect(b).y, 1e-3);
}

test "reduced motion instant" {
    const gpa = std.testing.allocator;
    var v: Boxes = .{};
    const t = try setup(gpa, &v);
    defer t.deinit();
    t.app.onAppearance(.{ .reduced_motion = true });
    try std.testing.expect(t.app.reduced_motion);
    const a = t.find(.{ .test_id = "a" }).?;
    presets.slideUp(t.win, a, 30, true);
    // The slide is instant; the 80 ms fade still plays.
    try std.testing.expectEqual(@as(f32, 0), t.win.visualOf(a).translate.y);
    try std.testing.expectEqual(@as(usize, 1), t.win.anim.count());
    presets.expandHeight(t.win, a, false);
    try std.testing.expectEqual(@as(f32, 1), t.win.visualOf(a).clip);
    t.app.reduced_motion = false;
    presets.expandHeight(t.win, a, true);
    try std.testing.expectEqual(@as(usize, 2), t.win.anim.count());
}

test "cancel on unmount" {
    const gpa = std.testing.allocator;
    var v: Boxes = .{};
    const t = try setup(gpa, &v);
    defer t.deinit();
    const b = t.find(.{ .test_id = "b" }).?;
    var x: f32 = 0;
    _ = t.win.animate(.{ .node_scale = b }, 2, .{ .spring = .{} });
    _ = t.win.animate(.{ .value = .{ .ptr = &x, .node = b } }, 1, .{ .tween = .{ .ms = 500 } });
    try std.testing.expectEqual(@as(usize, 2), t.win.anim.count());
    _ = step(t);
    v.show_b = false;
    t.win.markAllDirty();
    _ = step(t);
    try std.testing.expect(!t.win.store.valid(b));
    try std.testing.expectEqual(@as(usize, 0), t.win.anim.count());
    try std.testing.expectEqual(@as(u32, 0), t.win.visuals.count());
    try std.testing.expect(step(t).idle);
}

test "animated clip hides the bottom" {
    const gpa = std.testing.allocator;
    var v: Boxes = .{ .show_b = false };
    const t = try setup(gpa, &v);
    defer t.deinit();
    const a = t.find(.{ .test_id = "a" }).?;
    t.win.setVisual(a, .{ .clip = 0.75 });
    _ = t.frame();
    try std.testing.expect(t.win.hits.hit(.{ .x = 10, .y = 5 }).eql(a));
    try std.testing.expect(!t.win.hits.hit(.{ .x = 10, .y = 20 }).eql(a));
}
