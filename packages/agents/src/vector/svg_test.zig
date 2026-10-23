//! SVG export: a golden chart-like list and well-formedness.

const std = @import("std");
const vector = @import("root.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// Tags balance, attributes are quoted, and `&` only starts the five
/// predefined entities.
fn expectWellFormed(xml: []const u8) !void {
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(gpa);
    var i: usize = 0;
    while (i < xml.len) {
        switch (xml[i]) {
            '&' => {
                const ok = for ([_][]const u8{ "&amp;", "&lt;", "&gt;", "&quot;", "&apos;" }) |e| {
                    if (std.mem.startsWith(u8, xml[i..], e)) break true;
                } else false;
                try testing.expect(ok);
                i += 1;
            },
            '>' => return error.StrayGt,
            '<' => {
                const end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return error.Unclosed;
                const tag = xml[i + 1 .. end];
                try testing.expect(std.mem.indexOfScalar(u8, tag, '<') == null);
                if (tag[0] == '/') {
                    const open = stack.pop() orelse return error.Unbalanced;
                    try testing.expectEqualStrings(open, tag[1..]);
                } else {
                    var quotes: usize = 0;
                    for (tag) |ch| quotes += @intFromBool(ch == '"');
                    try testing.expect(quotes % 2 == 0);
                    const name_end = std.mem.indexOfAny(u8, tag, " /") orelse tag.len;
                    if (tag[tag.len - 1] != '/') try stack.append(gpa, tag[0..name_end]);
                }
                i = end + 1;
            },
            else => i += 1,
        }
    }
    try testing.expectEqual(0, stack.items.len);
}

test "svg_golden_and_wellformed" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: vector.VectorCanvas = .init(arena.allocator());
    // Axes, gridlines, bars, a dashed series line, labels.
    try c.line(40, 10, 40, 170, .{ .width = 1 }, .rgb(0x333333));
    try c.line(40, 170, 300, 170, .{ .width = 1 }, .rgb(0x333333));
    for (0..4) |i| {
        const y: f32 = 50 + @as(f32, @floatFromInt(i)) * 30;
        try c.line(40, y, 300, y, .{ .width = 0.5, .dash = &.{ 2, 2 }, .dash_offset = 1 }, vector.Color.rgb(0x999999).withAlpha(128));
    }
    try c.pushClip(.xywh(40, 10, 260, 160));
    for ([_]f32{ 60, 110, 30, 140 }, 0..) |v, i| {
        const x: f32 = 60 + @as(f32, @floatFromInt(i)) * 60;
        try c.fillRect(.xywh(x, 170 - v, 30, v), .rgb(0x4C78A8));
    }
    const s = try c.path();
    try s.moveTo(c.arena, 75, 100);
    try s.quadTo(c.arena, 105, 40, 135, 130);
    try s.cubicTo(c.arena, 160, 150, 180, 20, 255, 40.125);
    try c.stroke(s, .{ .width = 2.5, .join = .round, .cap = .round, .dash = &.{ 6, 3 } }, .rgb(0xE45756));
    try c.popClip();
    try c.circle(255, 40.125, 3.3333, .rgb(0xE45756));
    try c.text(.{ .x = 170, .y = 190, .text = "Revenue <Q1 & Q2>", .anchor = .middle, .size = 11 });
    try c.text(.{ .x = 14, .y = 90, .text = "\"usd\" 'k'", .rotate = .ccw90, .anchor = .middle, .baseline = .middle, .bold = true, .family = "Mono & Co" });
    try c.text(.{ .x = 36, .y = 50, .text = "tab\there\x01", .anchor = .end, .baseline = .top, .color = .rgb(0x666666) });
    const dl = try c.finish();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try vector.writeSvg(&out.writer, &dl, .{ .view = .xywh(0, 0, 320, 200), .background = .rgb(0xFFFFFF), .font_family = "Inter" });
    const svg = out.written();
    try expectWellFormed(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "Revenue &lt;Q1 &amp; Q2&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray=\"6 3\"") != null);
    try testing.expect(std.mem.indexOfScalar(u8, svg, 1) == null);
    try @import("zg_core").testkit.golden.expectGoldenOpts(testing.io, @src(), "chart.svg", svg, .{ .root = @import("zg_options").package_root, .dir = "testdata/vector", .normalize = .exact });

    // Deterministic.
    var again: std.Io.Writer.Allocating = .init(gpa);
    defer again.deinit();
    try vector.writeSvg(&again.writer, &dl, .{ .view = .xywh(0, 0, 320, 200), .background = .rgb(0xFFFFFF), .font_family = "Inter" });
    try testing.expectEqualStrings(svg, again.written());
}

test "svg numbers" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { x: f32, s: []const u8 }{
        .{ .x = 0, .s = "0" },
        .{ .x = -0.0001, .s = "0" },
        .{ .x = 1.5, .s = "1.5" },
        .{ .x = -2.25, .s = "-2.25" },
        .{ .x = 3.14159, .s = "3.142" },
        .{ .x = 0.05, .s = "0.05" },
        .{ .x = 100, .s = "100" },
        .{ .x = std.math.nan(f32), .s = "0" },
    };
    for (cases) |cs| try testing.expectEqualStrings(cs.s, try std.fmt.bufPrint(&buf, "{f}", .{vector.svg.num(cs.x)}));
}

test "empty list writes a valid document" {
    const dl: vector.DisplayList = .{ .items = &.{}, .bounds = .empty, .hash = 0 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try vector.writeSvg(&out.writer, &dl, .{});
    try expectWellFormed(out.written());
}
