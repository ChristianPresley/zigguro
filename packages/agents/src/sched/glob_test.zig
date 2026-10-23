//! Trigger globs: gitignore-style matching, braces, negation lists.

const std = @import("std");
const glob = @import("glob.zig");

const testing = std.testing;
const gpa = testing.allocator;

const Case = struct { []const u8, []const u8, bool };

const cases = [_]Case{
    // Basenames at any depth.
    .{ "*.md", "README.md", true },
    .{ "*.md", "docs/guide/intro.md", true },
    .{ "*.md", "docs/guide/intro.mdx", false },
    .{ "*.md", "notes.md.bak", false },
    .{ "README", "README", true },
    .{ "README", "docs/README", true },
    .{ "README", "README.md", false },
    // Dotfiles match `*`, as in gitignore.
    .{ "*", ".env", true },
    .{ ".*", ".env", true },
    .{ ".*", "src/.hidden", true },
    .{ "*.env", ".env", true },
    // Anchored patterns.
    .{ "src/*.zig", "src/main.zig", true },
    .{ "src/*.zig", "lib/src/main.zig", false },
    .{ "/build.zig", "build.zig", true },
    .{ "/build.zig", "tools/build.zig", false },
    .{ "src/*", "src/a/b.zig", true }, // matches the directory src/a
    .{ "docs/*.md", "docs/a/b.md", false },
    // `**`.
    .{ "src/**/*.zig", "src/main.zig", true },
    .{ "src/**/*.zig", "src/a/b/c/main.zig", true },
    .{ "src/**/*.zig", "lib/main.zig", false },
    .{ "**/test/*.zig", "test/a.zig", true },
    .{ "**/test/*.zig", "pkg/x/test/a.zig", true },
    .{ "**/test/*.zig", "pkg/test/x/a.zig", false },
    .{ "src/**", "src/a", true },
    .{ "src/**", "src/a/b/c", true },
    .{ "src/**", "srcs/a", false },
    .{ "**", "anything/at/all", true },
    .{ "a/**/b", "a/b", true },
    .{ "a/**/b", "a/x/y/b", true },
    .{ "a/**/**/b", "a/x/b", true },
    // `?` and classes.
    .{ "file?.txt", "file1.txt", true },
    .{ "file?.txt", "file10.txt", false },
    .{ "file?.txt", "file/.txt", false },
    .{ "[abc].zig", "b.zig", true },
    .{ "[abc].zig", "d.zig", false },
    .{ "[a-c]x", "bx", true },
    .{ "[!a-c]x", "bx", false },
    .{ "[^a-c]x", "dx", true },
    .{ "[]]x", "]x", true },
    .{ "v[0-9][0-9]", "v42", true },
    .{ "[unterminated", "[unterminated", true },
    // Escapes.
    .{ "\\*.md", "*.md", true },
    .{ "\\*.md", "a.md", false },
    // Braces.
    .{ "*.{zig,zon}", "build.zig", true },
    .{ "*.{zig,zon}", "build.zig.zon", true },
    .{ "*.{zig,zon}", "build.json", false },
    .{ "{src,lib}/**/*.zig", "lib/x/a.zig", true },
    .{ "{src,lib}/**/*.zig", "tools/a.zig", false },
    .{ "a{b,c{d,e}}f", "acef", true },
    .{ "a{b,c{d,e}}f", "abf", true },
    .{ "a{b,c{d,e}}f", "acf", false },
    .{ "{,x}y.txt", "y.txt", true },
    // Directory-only patterns match their contents, not files.
    .{ "build/", "build/out.o", true },
    .{ "build/", "src/build/out.o", true },
    .{ "build/", "build", false },
    .{ "/out/", "out/a/b", true },
    .{ "/out/", "x/out/a", false },
    // Directories match their contents.
    .{ "node_modules", "web/node_modules/x/index.js", true },
    .{ "docs/api", "docs/api/a.md", true },
    .{ "docs/api", "docs/apis/a.md", false },
};

test "glob_table" {
    try testing.expect(cases.len >= 60);
    for (cases) |c| {
        var g = try glob.Glob.compile(gpa, c[0]);
        defer g.deinit(gpa);
        if (g.match(c[1]) != c[2]) {
            std.debug.print("pattern {s} path {s}: want {}\n", .{ c[0], c[1], c[2] });
            return error.TestUnexpectedResult;
        }
    }
}

test "glob negation lists: last match wins" {
    var l = try glob.GlobList.compile(gpa, &.{ "docs/**/*.md", "!docs/drafts/**", "docs/drafts/keep.md" });
    defer l.deinit(gpa);
    try testing.expect(l.match("docs/a.md"));
    try testing.expect(!l.match("docs/drafts/x.md"));
    try testing.expect(l.match("docs/drafts/keep.md"));
    try testing.expect(!l.match("src/a.md"));
    var only_neg = try glob.GlobList.compile(gpa, &.{"!*.tmp"});
    defer only_neg.deinit(gpa);
    try testing.expect(!only_neg.match("a.tmp"));
    try testing.expect(!only_neg.match("a.md"));
}

test "glob rejects bad patterns" {
    for ([_][]const u8{ "", "!", "/", "a**b", "{a,b", "a}b", "x/***/y" }) |p| {
        if (glob.Glob.compile(gpa, p)) |g| {
            var gg = g;
            gg.deinit(gpa);
            std.debug.print("accepted: {s}\n", .{p});
            return error.TestUnexpectedResult;
        } else |e| try testing.expectEqual(error.InvalidGlob, e);
    }
    // Too many alternatives.
    try testing.expectError(error.InvalidGlob, glob.Glob.compile(gpa, "{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b}"));
}

test "fuzz: glob" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var raw: [64]u8 = undefined;
            const n = s.slice(&raw);
            const split = n / 2;
            var g = glob.Glob.compile(gpa, raw[0..split]) catch return;
            defer g.deinit(gpa);
            _ = g.match(raw[split..n]);
        }
    }.one, .{});
}

test "glob in an arena" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const l = try glob.GlobList.compile(arena.allocator(), &.{ "docs/**/*.md", "**" });
    try testing.expect(l.match("docs/a.md"));
}
