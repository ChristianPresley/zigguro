//! GlobSet tests.

const std = @import("std");
const GlobSet = @import("zg_ignore").GlobSet;

test "globset: braces, ./ anchoring, implicit **/, case-insensitive option" {
    const gpa = std.testing.allocator;
    var gs = try GlobSet.compile(gpa, "*.{zig,zon}, ./docs/*.md ,src/**/gen,{a,b{c,d}}.txt", .{});
    defer gs.deinit();
    try std.testing.expect(gs.matches("build.zig"));
    try std.testing.expect(gs.matches("deep/x/build.zon"));
    try std.testing.expect(!gs.matches("build.zigx"));
    try std.testing.expect(gs.matches("docs/a.md"));
    try std.testing.expect(!gs.matches("x/docs/a.md"));
    try std.testing.expect(gs.matches("src/gen"));
    try std.testing.expect(gs.matches("src/a/b/gen/table.c"));
    try std.testing.expect(gs.matches("q/bd.txt"));
    try std.testing.expect(!gs.matches("bx.txt"));
    try std.testing.expect(!gs.matches("README.MD"));
    var ci = try GlobSet.compile(gpa, "*.md", .{ .case_insensitive = true });
    defer ci.deinit();
    try std.testing.expect(ci.matches("docs/README.MD"));
    try std.testing.expectError(error.InvalidPattern, GlobSet.compile(gpa, "{a,b", .{}));
    try std.testing.expectError(error.TooManyExpansions, GlobSet.compile(gpa, "{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}", .{}));
    var empty = try GlobSet.compile(gpa, " , ", .{});
    defer empty.deinit();
    try std.testing.expect(empty.isEmpty());
}

test "globset: matchesDirPrefix pruning table" {
    const gpa = std.testing.allocator;
    var gs = try GlobSet.compile(gpa, "**/node_modules,./target,src/*/gen/**", .{});
    defer gs.deinit();
    const T = struct { []const u8, GlobSet.DirMatch };
    const cases = [_]T{
        .{ "node_modules", .all },
        .{ "a/b/node_modules", .all },
        .{ "a/b/node_modules/x", .all },
        .{ "target", .all },
        .{ "src", .maybe },
        .{ "src/core", .maybe },
        .{ "src/core/gen", .all },
        .{ "a", .maybe }, // **/node_modules may still match below
    };
    for (cases) |c| try std.testing.expectEqual(c[1], gs.matchesDirPrefix(c[0]));
    var anchored = try GlobSet.compile(gpa, "./target,src/*/gen", .{});
    defer anchored.deinit();
    try std.testing.expectEqual(GlobSet.DirMatch.no, anchored.matchesDirPrefix("docs"));
    try std.testing.expectEqual(GlobSet.DirMatch.no, anchored.matchesDirPrefix("src/a/other"));
    try std.testing.expectEqual(GlobSet.DirMatch.maybe, anchored.matchesDirPrefix("src/a"));
}
