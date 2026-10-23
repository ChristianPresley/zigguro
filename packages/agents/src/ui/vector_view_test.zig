//! The vector view in a headless window: tiles become image quads,
//! a zoom change draws the previous tiles stretched in the same frame,
//! and text is drawn as text, not into tiles.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const view = @import("vector_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const vector = zg_agents.vector;

const Host = struct {
    s: ?*view.VectorSurface = null,
    zoom: f32 = 1,

    pub fn build(h: *Host, ui: *zg_gui.Ui) void {
        if (h.s) |s| view.vectorView(ui, s, .{ .zoom = h.zoom, .test_id = "chart", .label = "Chart" });
    }
};

fn images(t: *TestApp) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t.paintSnapshot(), '\n');
    while (it.next()) |line| n += @intFromBool(std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "image "));
    return n;
}

test "tiles drawn after settle, stretched on zoom, text kept as text" {
    var host: Host = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&host), .size = .{ .w = 1200, .h = 800 } });
    defer t.deinit();
    const s = try view.VectorSurface.init(gpa, io, &t.app, .{});
    defer {
        t.app.joinWork();
        _ = t.app.drainMessages();
        host.s = null;
        s.deinit();
    }
    host.s = s;

    const c = try s.begin();
    try c.line(0, 0, 500, 300, .{ .width = 3 }, .rgb(0x204080));
    try c.text(.{ .x = 250, .y = 290, .text = "axis", .anchor = .middle });
    try s.commit();
    _ = t.settle();
    try testing.expect(s.jobs_done >= 1);
    // 500×300 at 1×: 2×2 tiles.
    try testing.expectEqual(4, images(t));
    // "axis" as one glyph run.
    try testing.expect(std.mem.indexOf(u8, t.paintSnapshot(), "glyphs 4 ") != null);
    try testing.expect(t.find(.{ .test_id = "chart", .role = .img }) != null);

    // Zoom: the very next frame still draws the old tiles, stretched.
    host.zoom = 2;
    t.app.notifyEntity(s.entity);
    _ = t.frame();
    try testing.expectEqual(4, images(t));
    // Sharp within two frames.
    try testing.expect(t.settle() <= 2);
    try testing.expectEqual(12, images(t));

    // A new list replaces the tiles.
    const c2 = try s.begin();
    try c2.fillRect(.xywh(0, 0, 100, 100), .rgb(0xFF0000));
    try s.commit();
    _ = t.settle();
    try testing.expectEqual(1, images(t));
}

test "tile cache budget evicts textures" {
    var host: Host = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&host), .size = .{ .w = 1200, .h = 800 } });
    defer t.deinit();
    // Room for six tiles.
    const s = try view.VectorSurface.init(gpa, io, &t.app, .{ .budget = 6 * vector.tiles.tile_bytes });
    defer {
        t.app.joinWork();
        _ = t.app.drainMessages();
        host.s = null;
        s.deinit();
    }
    host.s = s;
    const c = try s.begin();
    try c.fillRect(.xywh(0, 0, 500, 500), .rgb(0x00FF00));
    try s.commit();
    _ = t.settle();
    try testing.expectEqual(4, s.cache.count(io));
    host.zoom = 1.5;
    t.app.notifyEntity(s.entity);
    _ = t.settle();
    // 750×750: 3×3 tiles visible, more than the budget; this frame's
    // tiles are kept, the old scale's are gone.
    try testing.expectEqual(9, s.cache.count(io));
    try testing.expectEqual(9, images(t));
}
