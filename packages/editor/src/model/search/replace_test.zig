//! Replacement template and preserve-case tables.

const std = @import("std");
const replace = @import("replace.zig");
const preserve_case = @import("preserve_case.zig");

const gpa = std.testing.allocator;

fn expand(template: []const u8, texts: []const ?[]const u8, names: []const ?[]const u8, preserve: bool) ![]u8 {
    const sg: replace.SliceGroups = .{ .texts = texts, .names = names };
    return replace.expandReplacement(gpa, template, sg.groups(), preserve);
}

test "replace: template table" {
    const texts = [_]?[]const u8{ "foo_bar", "foo", "bar", null, "x", "x", "x", "x", "x", "x", "ten", "eleven" };
    const names = [_]?[]const u8{ null, "first", "second", "gone", null, null, null, null, null, null, null, null };
    const cases = [_][2][]const u8{
        .{ "$0", "foo_bar" },
        .{ "$&!", "foo_bar!" },
        .{ "$2-$1", "bar-foo" },
        .{ "${second}${first}", "barfoo" },
        .{ "${2}", "bar" },
        .{ "[$3]", "[]" },
        .{ "${gone}${missing}", "" },
        .{ "$$1", "$1" },
        .{ "$10/$11", "ten/eleven" },
        .{ "$99", "x9" }, // no group 99: $9 then a literal 9 (JavaScript)
        .{ "a\\nb\\tc\\\\d", "a\nb\tc\\d" },
        .{ "\\u$1", "Foo" },
        .{ "\\U$1\\E-$2", "FOO-bar" },
        .{ "\\L\\uABC", "Abc" },
        .{ "\\l$0", "foo_bar" },
        .{ "\\q", "\\q" },
        .{ "$", "$" },
        .{ "${unclosed", "${unclosed" },
    };
    for (cases) |c| {
        const got = try expand(c[0], &texts, &names, false);
        defer gpa.free(got);
        std.testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("template {s}\n", .{c[0]});
            return e;
        };
    }
}

fn pc(matched: []const u8, repl: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try preserve_case.apply(&out, gpa, matched, repl);
    return out.toOwnedSlice(gpa);
}

test "replace: preserve case table" {
    const cases = [_][3][]const u8{
        .{ "foo", "bar", "bar" },
        .{ "foo", "Bar", "Bar" },
        .{ "FOO", "bar", "BAR" },
        .{ "FOO", "barBaz", "BARBAZ" },
        .{ "Foo", "bar", "Bar" },
        .{ "Foo", "barBaz", "BarBaz" },
        .{ "fooBar", "bazQux", "bazQux" },
        .{ "fooBar", "BazQux", "bazQux" },
        .{ "FooBar", "bazQux", "BazQux" },
        .{ "fooBar", "baz", "baz" },
        .{ "FooBar", "baz", "Baz" },
        .{ "foo_bar", "baz_qux", "baz_qux" },
        .{ "FOO_BAR", "baz_qux", "BAZ_QUX" },
        .{ "Foo_Bar", "baz_qux", "Baz_Qux" },
        .{ "foo-bar", "Baz-Qux", "Baz-Qux" },
        .{ "Foo-bar", "baz-qux", "Baz-qux" },
        .{ "FOO-BAR", "baz-qux", "BAZ-QUX" },
        .{ "123", "abc", "abc" },
        .{ "A", "bc", "Bc" },
        .{ "über", "straße", "straße" },
        .{ "Über", "straße", "Straße" },
        .{ "ÜBER", "straße", "STRASSE" },
        .{ "ΣΟΦΙΑ", "λόγος", "ΛΌΓΟΣ" },
        .{ "foo_bar", "baz", "baz" },
    };
    for (cases) |c| {
        const got = try pc(c[0], c[1]);
        defer gpa.free(got);
        std.testing.expectEqualStrings(c[2], got) catch |e| {
            std.debug.print("matched {s} repl {s}\n", .{ c[0], c[1] });
            return e;
        };
    }
}

test "replace: preserve case through templates" {
    const texts = [_]?[]const u8{"HELLO"};
    const names = [_]?[]const u8{null};
    const got = try expand("goodbye", &texts, &names, true);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("GOODBYE", got);
}
