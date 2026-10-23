const std = @import("std");
const kinds = @import("kinds.zig");

const testing = std.testing;

const png_1x2 = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x02\x08\x02\x00\x00\x00";
const gif_3x4 = "GIF89a\x03\x00\x04\x00\x00\x00\x00";
// SOI, APP0 (length 4), SOF0 with height 5 and width 6.
const jpeg_6x5 = "\xFF\xD8\xFF\xE0\x00\x04\x00\x00\xFF\xC0\x00\x0B\x08\x00\x05\x00\x06\x01\x01\x11\x00";

test "probe images" {
    try testing.expectEqual(kinds.ImageInfo{ .format = .png, .w = 1, .h = 2 }, kinds.probeImage(png_1x2).?);
    try testing.expectEqual(kinds.ImageInfo{ .format = .gif, .w = 3, .h = 4 }, kinds.probeImage(gif_3x4).?);
    try testing.expectEqual(kinds.ImageInfo{ .format = .jpeg, .w = 6, .h = 5 }, kinds.probeImage(jpeg_6x5).?);
    try testing.expectEqual(kinds.ImageInfo{ .format = .svg, .w = 120, .h = 40 }, kinds.probeImage("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120px\" height='40'></svg>").?);
    try testing.expectEqual(kinds.ImageInfo{ .format = .svg, .w = 300, .h = 150 }, kinds.probeImage("\xEF\xBB\xBF<?xml version=\"1.0\"?>\n<!-- made by hand -->\n<!DOCTYPE svg>\n<svg viewBox=\"0 0 300 150\"/>").?);
    try testing.expectEqual(kinds.ImageInfo{ .format = .svg }, kinds.probeImage("<svg><rect/></svg>").?);
    try testing.expect(kinds.probeImage("<svgx/>") == null);
    try testing.expect(kinds.probeImage("<html><svg/></html>") == null);
    try testing.expect(kinds.probeImage("GIF8") == null);
    try testing.expect(kinds.probeImage("") == null);
}

const Rejecter = struct {
    fn check(_: *anyopaque, a: std.mem.Allocator, content: []const u8) anyerror!?[]const u8 {
        if (std.mem.indexOf(u8, content, "\"mark\"") == null) return try std.fmt.allocPrint(a, "chart spec: missing `mark` at 0..{d}", .{content.len});
        return null;
    }
};

test "validation_errors_per_kind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dummy: u8 = 0;
    const with: kinds.Validators = .{ .chart = .{ .ctx = &dummy, .check = Rejecter.check } };
    const Case = struct { kinds.ArtifactKind, []const u8, kinds.Validators, []const u8 };
    const cases = [_]Case{
        .{ .markdown, "# Title\n", .{}, "ok md" },
        .{ .markdown, "bad \xff byte", .{}, "markdown artifacts must be UTF-8 text" },
        .{ .text, "plain", .{}, "ok txt" },
        .{ .html_source, "<p>hi</p>", .{}, "ok html" },
        .{ .table, "a,b\n1,2\n", .{}, "ok csv" },
        .{ .table, "a\tb\n1\t2\n", .{}, "ok tsv" },
        .{ .table, "[{\"a\":1}]", .{}, "ok json" },
        .{ .table, "{\"a\":1}\n{\"a\":2}\n", .{}, "ok ndjson" },
        .{ .table, "[{\"a\":1}", .{}, "the table is not valid JSON" },
        .{ .table, "{\"a\":1}\n{\"a\":\n", .{}, "line 2 of the table is not valid JSON" },
        .{ .table, "  \n", .{}, "the table is empty" },
        .{ .table, "caf\xe9,b\n1,2\n", .{}, "ok csv" },
        .{ .chart, "{\"mark\":\"bar\"}", .{}, "ok json" },
        .{ .chart, "{mark: bar}", .{}, "the chart spec is not valid JSON" },
        .{ .chart, "{\"type\":\"bar\"}", with, "chart spec: missing `mark` at 0..14" },
        .{ .chart, "{\"mark\":\"bar\"}", with, "ok json" },
        .{ .diagram, "graph TD; A-->B", .{}, "ok mmd" },
        .{ .diagram, " \n", .{}, "the diagram source is empty" },
        .{ .image, png_1x2, .{}, "ok png" },
        .{ .image, jpeg_6x5, .{}, "ok jpg" },
        .{ .image, "<svg/>", .{}, "ok svg" },
        .{ .image, "not an image", .{}, "image artifacts must be PNG, JPEG, GIF or SVG" },
        .{ .code, "const x = 1;", .{}, "ok txt" },
    };
    for (cases) |c| {
        const r = try kinds.validate(a, c[0], c[1], null, c[2]);
        const got = switch (r) {
            .ok => |o| try std.fmt.allocPrint(a, "ok {s}", .{o.ext}),
            .invalid => |i| i.message,
        };
        testing.expectEqualStrings(c[3], got) catch |e| {
            std.debug.print("kind {t}: {s}\n", .{ c[0], c[1] });
            return e;
        };
    }
    // Size caps.
    const big = try a.alloc(u8, kinds.max_text + 1);
    @memset(big, 'x');
    const r = try kinds.validate(a, .markdown, big, null, .{});
    try testing.expectEqualStrings("markdown artifacts are limited to 5 MB, got 5242881 bytes", r.invalid.message);
    const code = try kinds.validate(a, .code, "x", "Python", .{});
    try testing.expectEqualStrings("py", code.ok.ext);
}

test "kind from path" {
    try testing.expectEqual(kinds.ArtifactKind.table, kinds.kindForPath("out/result.CSV"));
    try testing.expectEqual(kinds.ArtifactKind.image, kinds.kindForPath("plot.png"));
    try testing.expectEqual(kinds.ArtifactKind.markdown, kinds.kindForPath("report.md"));
    try testing.expectEqual(kinds.ArtifactKind.code, kinds.kindForPath("fit.py"));
    try testing.expectEqual(kinds.ArtifactKind.text, kinds.kindForPath("run.log"));
    try testing.expectEqual(kinds.ArtifactKind.text, kinds.kindForPath("data.bin"));
}
