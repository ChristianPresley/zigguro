//! Basic controls: behaviour, snapshots and theming (E04.F05.S01.T01,
//! E04.F08.S01.T01).

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const controls = @import("controls.zig");
const theme_mod = @import("../theme/theme.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;

const Settings = struct {
    wrap: bool = false,
    sync: bool = true,
    saved: u32 = 0,

    pub fn build(self: *Settings, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .padding = .all(12), .align_items = .start } });
        defer ui.close();
        ui.text("Editor", .{});
        _ = controls.checkbox(ui, "Word wrap", &self.wrap);
        _ = controls.toggle(ui, "Settings sync", &self.sync);
        controls.separator(ui, false);
        ui.open(.{ .style = .{ .gap = 8 } });
        controls.badge(ui, "3");
        if (controls.button(ui, .{ .label = "Save", .variant = .primary }).clicked) self.saved += 1;
        controls.spacer(ui);
        ui.close();
        controls.progress(ui, 0.5);
    }
};

test "checkbox and toggle flip on click and space" {
    var s: Settings = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&s) });
    defer t.deinit();
    _ = t.settle();
    try t.click(.{ .name = "Word wrap" });
    try std.testing.expect(s.wrap);
    try std.testing.expect(t.find(.{ .name = "Word wrap", .role = .checkbox }) != null);
    t.press(.space, .{});
    try std.testing.expect(!s.wrap);
    try t.click(.{ .role = .switch_ });
    try std.testing.expect(!s.sync);
    try t.click(.{ .name = "Save" });
    try std.testing.expectEqual(@as(u32, 1), s.saved);
}

test "layout snapshot" {
    var s: Settings = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&s), .size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = t.settle();
    const snap = try t.layoutSnapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings(
        \\root 0,0 400x300
        \\  view 0,0 400x300
        \\    box 0,0 400x152
        \\      text "Editor" 12,12 46.8x17
        \\      checkbox "Word wrap" checked=false 12,37 94.2x20
        \\      toggle "Settings sync" checked=true 12,65 141.8x20
        \\      separator 12,93 376x1
        \\      box 12,102 89.8x26
        \\        badge "3" 12,107 18.6x16
        \\        button "Save" 38.6,102 55.2x26
        \\        box 101.8,102 0x26
        \\      progress 12,136 376x4
        \\
    , snap);
}

test "theme switch repaints without relayout" {
    var s: Settings = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&s) });
    defer t.deinit();
    _ = t.settle();
    t.app.setTheme(&theme_mod.zigguro_light);
    const st = t.frame();
    try std.testing.expectEqual(@as(u32, 0), st.layout.visited);
    try std.testing.expectEqual(@as(u32, 0), st.views_built);
    try std.testing.expect(st.full_damage or st.damage_rects > 0);
    try std.testing.expect(std.mem.indexOf(u8, t.paintSnapshot(), "#ffffffff") != null);
}

test "system appearance selects high contrast" {
    var s: Settings = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&s) });
    defer t.deinit();
    t.app.onAppearance(.{ .scheme = .dark, .contrast = .high });
    try std.testing.expectEqual(theme_mod.Theme.Kind.hc_dark, t.app.theme.kind);
    t.app.onAppearance(.{ .scheme = .light });
    try std.testing.expectEqual(theme_mod.Theme.Kind.light, t.app.theme.kind);
}

test "paint snapshot of a primary button" {
    const V = struct {
        pub fn build(_: *@This(), ui: *Ui) void {
            ui.open(.{ .style = .{ .padding = .all(10), .align_items = .start } });
            _ = controls.button(ui, .{ .label = "Go", .variant = .primary });
            ui.close();
        }
    };
    var v: V = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&v), .size = .{ .w = 100, .h = 50 } });
    defer t.deinit();
    _ = t.settle();
    try std.testing.expectEqualStrings(
        \\begin 100x50 @1
        \\rect 0,0 100x50 #1e1f22ff r0
        \\rect 10,10 39.6x26 #2f6ad9ff r5
        \\glyphs 2 22.65,17.8 14.3x9.1 #ffffffff
        \\damage 0,0 100x50
        \\end
        \\
    , t.paintSnapshot());
}
