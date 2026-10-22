//! Tests for `glob.zig`.

const std = @import("std");
const testing = std.testing;
const glob = @import("glob.zig");
const Glob = glob.Glob;

fn expectMatch(pattern: []const u8, path: []const u8, want: bool) !void {
    return expectMatchOpts(pattern, path, want, .{ .case_insensitive = false });
}

fn expectMatchOpts(pattern: []const u8, path: []const u8, want: bool, opts: glob.GlobOptions) !void {
    var g = try Glob.compile(testing.allocator, pattern, opts);
    defer g.deinit(testing.allocator);
    if (g.match(path) != want) {
        std.debug.print("pattern {s} path {s}: want {}\n", .{ pattern, path, want });
        return error.TestUnexpectedResult;
    }
}

test "glob: spec examples" {
    try expectMatch("**/*.ts", "a.ts", true);
    try expectMatch("**/*.ts", "src/a/b.ts", true);
    try expectMatch("**/*.ts", "src/a/b.tsx", false);
    try expectMatch("**/*.{ts,js}", "x/y.js", true);
    try expectMatch("**/*.{ts,js}", "x/y.ts", true);
    try expectMatch("**/*.{ts,js}", "x/y.cs", false);
    try expectMatch("src/**/test/*.zig", "src/test/a.zig", true);
    try expectMatch("src/**/test/*.zig", "src/a/b/test/a.zig", true);
    try expectMatch("src/**/test/*.zig", "src/a/b/test/c/a.zig", false);
    try expectMatch("[!a]*.c", "b.c", true);
    try expectMatch("[!a]*.c", "abc.c", false);
    try expectMatch("?.zig", "a.zig", true);
    try expectMatch("?.zig", "ab.zig", false);
    try expectMatch("?.zig", "/.zig", false);
    try expectMatch("*.zig", "a/b.zig", false);
    try expectMatch("[a-c]x", "bx", true);
    try expectMatch("[a-c]x", "dx", false);
    try expectMatch("[^a-c]x", "dx", true);
}

test "glob: nested braces and literal fallbacks" {
    try expectMatch("{a,{b,c}d}.zig", "a.zig", true);
    try expectMatch("{a,{b,c}d}.zig", "cd.zig", true);
    try expectMatch("{a,{b,c}d}.zig", "c.zig", false);
    try expectMatch("{a,b}/{c,d}/{e,f}", "b/c/f", true);
    try expectMatch("{a,b}/{c,d}/{e,f}", "b/c/g", false);
    try expectMatch("{a,b", "{a,b", true);
    try expectMatch("{a,b", "a", false);
    try expectMatch("[ab", "[ab", true);
    try expectMatch("a,b", "a,b", true);
    try expectMatch("{}", "", true);
    try expectMatch("x{,y}", "x", true);
    try expectMatch("x{,y}", "xy", true);
    try expectMatch("{**/*.zig,*.zon}", "a/b.zig", true);
    try expectMatch("{**/*.zig,*.zon}", "b.zon", true);
    try expectMatch("{**/*.zig,*.zon}", "a/b.zon", false);
    try expectMatch("[]]", "]", true);
}

test "glob: case-insensitive on windows option" {
    try expectMatchOpts("**/*.ZIG", "src/Main.zig", true, .{ .case_insensitive = true });
    try expectMatchOpts("[A-C]x", "bX", true, .{ .case_insensitive = true });
    try expectMatchOpts("**/*.ZIG", "src/Main.zig", false, .{ .case_insensitive = false });
    const default: glob.GlobOptions = .{};
    try testing.expectEqual(@import("builtin").os.tag == .windows, default.case_insensitive);
}

test "glob: ** across zero segments" {
    try expectMatch("a/**/b", "a/b", true);
    try expectMatch("a/**/b", "a/x/y/b", true);
    try expectMatch("a/**/b", "ab", false);
    try expectMatch("a/**", "a/x/y", true);
    try expectMatch("a/**", "a", true);
    try expectMatch("a/**", "ab", false);
    try expectMatch("**", "a/b/c", true);
    try expectMatch("a**b", "axxb", true);
    try expectMatch("a**b", "ax/xb", false);
}

test "glob: edge cases" {
    try expectMatch("", "", false);
    try expectMatch("", "a", false);
    try expectMatch("src/", "src", true);
    try expectMatch("src/", "src/", true);
    try expectMatch("src/", "src/a", false);
    var deep: [3 * 40]u8 = undefined;
    for (0..40) |i| deep[i] = '{';
    for (40..80) |i| deep[i] = 'a';
    for (80..120) |i| deep[i] = '}';
    try testing.expectError(error.InvalidGlob, Glob.compile(testing.allocator, &deep, .{}));
    const long = "a" ** (glob.max_states + 1);
    try testing.expectError(error.InvalidGlob, Glob.compile(testing.allocator, long, .{}));
}

test "fuzz: lsp glob" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var pat: [48]u8 = undefined;
            var path: [64]u8 = undefined;
            const np = s.slice(&pat);
            const nq = s.slice(&path);
            var g = Glob.compile(testing.allocator, pat[0..np], .{}) catch |err| switch (err) {
                error.InvalidGlob => return,
                error.OutOfMemory => return err,
            };
            defer g.deinit(testing.allocator);
            // `match` takes no allocator; it must simply not crash.
            _ = g.match(path[0..nq]);
        }
    }.one, .{});
}
