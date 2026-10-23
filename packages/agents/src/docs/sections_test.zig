const std = @import("std");
const sections = @import("sections.zig");

const testing = std.testing;

fn render(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try sections.outline(a, text);
    var w: std.Io.Writer.Allocating = .init(a);
    for (out) |s| {
        try w.writer.print("{s} h{d} {s} \"{s}\" [{d},{d}) words={d} parent={s} children={d}\n", .{
            s.id,                                 s.level,        s.slug, s.title, s.range.start, s.range.end, s.words,
            if (s.parent) |p| out[p].id else "-", s.children.len,
        });
    }
    return w.written();
}

test "outline_fixture_goldens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try render(arena.allocator(), @embedFile("testdata/outline.md"));
    try testing.expectEqualStrings(@embedFile("testdata/outline.golden"), got);
}

test "ids, slugs and lookups" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "# A\n## B\n## B\n### C\n# D\n";
    const out = try sections.outline(a, text);
    try testing.expectEqual(5, out.len);
    try testing.expectEqualStrings("1.2.1", out[3].id);
    try testing.expectEqualStrings("b-1", out[2].slug);
    try testing.expectEqual(@as(?u32, 2), sections.find(out, "1.2"));
    try testing.expectEqual(@as(?u32, 2), sections.find(out, "#b-1"));
    try testing.expectEqual(@as(?u32, 4), sections.find(out, "d"));
    try testing.expectEqual(@as(?u32, null), sections.find(out, "9"));
    // B's range ends at the next B; A's covers its children.
    try testing.expectEqual(out[2].range.start, out[1].range.end);
    try testing.expectEqual(out[4].range.start, out[0].range.end);
    try testing.expectEqual(@as(?u32, 3), sections.sectionAt(out, out[3].range.start + 2));
    try testing.expectEqual(out[3].range.start, out[2].ownEnd(out));
    try testing.expectEqual(0, (try sections.outline(a, "no headings\n")).len);
    try testing.expectEqualStrings("hello-wörld_--x", try sections.slugify(a, "Hello, Wörld_ -x!"));
}
