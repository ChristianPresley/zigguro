//! `project.zon` parsing, validation and the canonical writer.

const std = @import("std");
const project = @import("project.zig");

const testing = std.testing;
const gpa = testing.allocator;

const book = @embedFile("testdata/book.zon");

test "zon_roundtrip_golden: the fixture is canonical" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var pr: project.Problem = .{ .message = "" };
    const p = try project.parse(a, "book", book, &pr);
    try testing.expectEqualStrings("book", p.slug);
    try testing.expectEqualStrings("The \"Zig\" book", p.title);
    try testing.expectEqual(@as(usize, 5), p.knowledge.len);
    try testing.expectEqualStrings("**/*", p.knowledge[0].folder.glob);
    try testing.expectEqualStrings("**/*.md", p.knowledge[1].folder.glob);
    try testing.expectEqualStrings("tag:#book", p.knowledge[2].notes_query);
    try testing.expectEqualStrings("writer", p.defaults.agent_def.?);
    try testing.expect(p.defaults.profile == null);
    try testing.expect(p.pinned);
    try testing.expectEqualStrings(book, try project.writeAlloc(a, p.file()));
}

test "minimal project writes only what is set" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const out = try project.writeAlloc(arena.allocator(), .{ .title = "Q4" });
    try testing.expectEqualStrings(".{\n    .version = 1,\n    .title = \"Q4\",\n}\n", out);
}

test "diagnostics: every invalid fixture is refused with a reason" {
    const cases = [_]struct { name: []const u8, src: [:0]const u8, line: u32, has: []const u8 }{
        .{ .name = "unknown-field", .src = @embedFile("testdata/invalid/unknown-field.zon"), .line = 1, .has = "colour" },
        .{ .name = "missing-title", .src = @embedFile("testdata/invalid/missing-title.zon"), .line = 1, .has = "title" },
        .{ .name = "bad-version", .src = @embedFile("testdata/invalid/bad-version.zon"), .line = 0, .has = "version" },
        .{ .name = "empty-title", .src = @embedFile("testdata/invalid/empty-title.zon"), .line = 0, .has = "title" },
        .{ .name = "parent-path", .src = @embedFile("testdata/invalid/parent-path.zon"), .line = 0, .has = "workspace-relative" },
        .{ .name = "absolute-file", .src = @embedFile("testdata/invalid/absolute-file.zon"), .line = 0, .has = "workspace-relative" },
        .{ .name = "empty-query", .src = @embedFile("testdata/invalid/empty-query.zon"), .line = 0, .has = "query" },
        .{ .name = "wrong-type", .src = @embedFile("testdata/invalid/wrong-type.zon"), .line = 4, .has = "" },
    };
    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var pr: project.Problem = .{ .message = "" };
        _ = project.parse(arena.allocator(), "x", c.src, &pr) catch |e| {
            try testing.expectEqual(error.Invalid, e);
            testing.expectEqual(c.line, pr.line) catch |err| {
                std.debug.print("{s}: {d}:{d} {s}\n", .{ c.name, pr.line, pr.column, pr.message });
                return err;
            };
            try testing.expect(pr.message.len > 0);
            try testing.expect(std.mem.indexOf(u8, pr.message, c.has) != null);
            continue;
        };
        std.debug.print("{s} parsed\n", .{c.name});
        return error.TestUnexpectedResult;
    }
}

test "slugs and relative paths" {
    try testing.expect(project.validSlug("q4-launch"));
    try testing.expect(!project.validSlug("-x"));
    try testing.expect(!project.validSlug("Book"));
    try testing.expect(!project.validSlug(""));
    try testing.expect(project.relPath("docs/a.md"));
    try testing.expect(!project.relPath("docs//a.md"));
    try testing.expect(!project.relPath("C:/x"));
    try testing.expect(!project.relPath("a\\b"));
    try testing.expect(!project.relPath("a/../b"));
}
