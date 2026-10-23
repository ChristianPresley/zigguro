//! The chart view in a headless window: the chart draws as tiles plus
//! text, hovering a bar shows its tooltip, leaving hides it, and a bad
//! spec shows its message.

const std = @import("std");
const zg_gui = @import("zg_gui");
const view = @import("chart_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;

const Host = struct {
    v: ?*view.ChartView = null,

    pub fn build(h: *Host, ui: *zg_gui.Ui) void {
        if (h.v) |v| view.chartView(ui, v, .{ .test_id = "chart" });
    }
};

const spec =
    \\{"title":"Bars","width":400,"height":240,"data":{"values":[{"k":"a","v":3},{"k":"b","v":9},{"k":"c","v":5}]},
    \\ "mark":"bar","encoding":{"x":{"field":"k","type":"nominal"},"y":{"field":"v","type":"quantitative"}}}
;

fn has(t: *TestApp, needle: []const u8) bool {
    return std.mem.indexOf(u8, t.paintSnapshot(), needle) != null;
}

test "hover shows the nearest bar's tooltip" {
    var host: Host = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&host), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    const v = try view.ChartView.init(gpa, io, &t.app, .{});
    defer {
        t.app.joinWork();
        _ = t.app.drainMessages();
        host.v = null;
        v.deinit();
    }
    host.v = v;
    try v.setSpec(spec, .{});
    _ = t.settle();
    try testing.expect(t.find(.{ .test_id = "chart", .role = .img, .name = "Bars" }) != null);
    try testing.expect(v.surface.jobs_done >= 1);
    // No tooltip yet: "v" and "9" appear only as axis text.
    const before = std.mem.count(u8, t.paintSnapshot(), "\n");

    // The middle bar (b = 9).
    var bar: ?[2]f32 = null;
    for (v.compiled.?.targets) |tg| if (tg.row == 1) {
        bar = .{ (tg.x0 + tg.x1) / 2, tg.y0 + 4 };
    };
    const r = try t.rectOf(.{ .test_id = "chart", .role = .img });
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = r.x + bar.?[0], .y = r.y + bar.?[1] } } });
    _ = t.settle();
    try testing.expect(v.hover != null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const tip = (try v.tooltip(arena.allocator())).?;
    try testing.expectEqualStrings("b", tip.lines[0].value);
    try testing.expectEqualStrings("9", tip.lines[1].value);
    // The tooltip adds a box, its border and four text runs.
    try testing.expect(std.mem.count(u8, t.paintSnapshot(), "\n") > before);

    t.win.dispatch(.pointer_leave);
    _ = t.settle();
    try testing.expectEqual(null, v.hover);
    try testing.expectEqual(before, std.mem.count(u8, t.paintSnapshot(), "\n"));
}

test "a bad spec shows its message" {
    var host: Host = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&host), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    const v = try view.ChartView.init(gpa, io, &t.app, .{});
    defer {
        t.app.joinWork();
        _ = t.app.drainMessages();
        host.v = null;
        v.deinit();
    }
    host.v = v;
    try testing.expectError(error.InvalidSpec, v.setSpec("{\"data\":{\"values\":[]},\"mark\":\"pie\"}", .{}));
    _ = t.settle();
    try testing.expectEqualStrings("mark: expected one of bar|line|area|point|circle|square|rule|rect|tick|text", v.err.?);
    try testing.expect(t.find(.{ .test_id = "chart", .role = .status }) != null);
    try testing.expect(t.find(.{ .name_contains = "mark: expected one of" }) != null);
}
