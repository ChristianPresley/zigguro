//! Views, entities and effects (E04.F01.S01.T02).

const std = @import("std");
const ui_mod = @import("ui.zig");
const view_mod = @import("view.zig");
const app_mod = @import("app.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const AnyView = view_mod.AnyView;

const Model = struct { n: u32 = 0 };

const Child = struct {
    builds: u32 = 0,
    model: ?view_mod.Entity(Model) = null,
    notify_in_build: bool = false,

    pub fn build(self: *Child, ui: *Ui) void {
        self.builds += 1;
        if (self.model) |m| {
            ui.cx().observe(m.id);
            ui.textf("n={d}", .{m.read(ui.window().app).n}, .{});
        } else ui.text("child", .{});
        if (self.notify_in_build) {
            self.notify_in_build = false;
            ui.cx().notify();
        }
    }
};

const Parent = struct {
    kids: [50]Child = [_]Child{.{}} ** 50,
    builds: u32 = 0,

    pub fn build(self: *Parent, ui: *Ui) void {
        self.builds += 1;
        ui.open(.{ .style = .{ .dir = .column } });
        defer ui.close();
        for (&self.kids, 0..) |*k, i| {
            ui.id(i);
            ui.mount(AnyView.of(k));
        }
    }
};

fn viewId(t: *TestApp, v: anytype) u16 {
    return t.win.viewIdOf(AnyView.of(v)).?;
}

test "only dirty views rebuild" {
    const gpa = std.testing.allocator;
    var p: Parent = .{};
    const t = try TestApp.init(gpa, .{ .root = AnyView.of(&p) });
    defer t.deinit();
    _ = t.settle();
    try std.testing.expectEqual(@as(u32, 1), p.builds);
    for (p.kids) |k| try std.testing.expectEqual(@as(u32, 1), k.builds);
    t.win.markViewDirty(viewId(t, &p.kids[17]));
    const st = t.frame();
    try std.testing.expectEqual(@as(u32, 1), st.views_built);
    try std.testing.expectEqual(@as(u32, 1), p.builds);
    try std.testing.expectEqual(@as(u32, 2), p.kids[17].builds);
    try std.testing.expectEqual(@as(u32, 1), p.kids[16].builds);
    try std.testing.expectEqual(@as(u32, 1), st.nodes_emitted);
}

test "parent rebuild builds a dirty child once and keeps clean children" {
    const gpa = std.testing.allocator;
    var p: Parent = .{};
    const t = try TestApp.init(gpa, .{ .root = AnyView.of(&p) });
    defer t.deinit();
    _ = t.settle();
    t.win.markViewDirty(viewId(t, &p.kids[3]));
    t.win.markViewDirty(viewId(t, &p));
    const st = t.frame();
    try std.testing.expectEqual(@as(u32, 2), st.views_built);
    try std.testing.expectEqual(@as(u32, 2), p.kids[3].builds);
    try std.testing.expectEqual(@as(u32, 1), p.kids[4].builds);
    // Every child text is still there.
    try std.testing.expectEqual(@as(usize, 50), t.count(.{ .kind = "text" }));
}

test "observer rebuild on notifyEntity" {
    const gpa = std.testing.allocator;
    var p: Parent = .{};
    const t = try TestApp.init(gpa, .{ .root = AnyView.of(&p) });
    defer t.deinit();
    const m = try t.app.new(Model, .{});
    p.kids[5].model = m;
    _ = t.settle();
    try std.testing.expect(t.find(.{ .name = "n=0" }) != null);
    t.app.update(Model, m, struct {
        fn f(self: *Model, cx: *app_mod.Context) void {
            self.n = 42;
            cx.notify();
        }
    }.f);
    const st = t.frame();
    try std.testing.expectEqual(@as(u32, 1), st.views_built);
    try std.testing.expect(t.find(.{ .name = "n=42" }) != null);
}

test "stale observation dropped after rebuild without read" {
    const gpa = std.testing.allocator;
    var p: Parent = .{};
    const t = try TestApp.init(gpa, .{ .root = AnyView.of(&p) });
    defer t.deinit();
    const m = try t.app.new(Model, .{});
    p.kids[0].model = m;
    _ = t.settle();
    p.kids[0].model = null;
    t.win.markViewDirty(viewId(t, &p.kids[0]));
    _ = t.settle();
    const before = p.kids[0].builds;
    t.app.notifyEntity(m.id);
    _ = t.settle();
    try std.testing.expectEqual(before, p.kids[0].builds);
}

test "notify during build rebuilds next frame, not re-entrantly" {
    const gpa = std.testing.allocator;
    var p: Parent = .{};
    p.kids[9].notify_in_build = true;
    const t = try TestApp.init(gpa, .{ .root = AnyView.of(&p) });
    defer t.deinit();
    const first = t.frame();
    try std.testing.expect(!first.idle);
    try std.testing.expectEqual(@as(u32, 1), p.kids[9].builds);
    try std.testing.expect(t.win.wantsFrame());
    _ = t.frame();
    try std.testing.expectEqual(@as(u32, 2), p.kids[9].builds);
    try std.testing.expect(t.frame().idle);
}

test "unmounted view is released" {
    const gpa = std.testing.allocator;
    const Toggle = struct {
        show: bool = true,
        child: Child = .{},
        pub fn build(self: *@This(), ui: *Ui) void {
            if (self.show) ui.mount(AnyView.of(&self.child));
        }
    };
    var v: Toggle = .{};
    const t = try TestApp.init(gpa, .{ .root = AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    try std.testing.expect(t.win.viewIdOf(AnyView.of(&v.child)) != null);
    v.show = false;
    t.win.markViewDirty(viewId(t, &v));
    _ = t.settle();
    try std.testing.expect(t.win.viewIdOf(AnyView.of(&v.child)) == null);
    v.show = true;
    t.win.markViewDirty(viewId(t, &v));
    _ = t.settle();
    try std.testing.expectEqual(@as(u32, 2), v.child.builds);
}
