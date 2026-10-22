//! TOML lexer tests: goldens, multi-line strings, table headers inside
//! arrays and incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const toml = @import("toml.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Mode = toml.Mode;

const goldens = [_][]const u8{
    "tables",  "array_tables", "keys",   "strings",       "multiline_basic", "multiline_literal",
    "numbers", "datetimes",    "arrays", "inline_tables", "comments",        "cargo",
};

test "toml: golden highlights" {
    try lt.expectGoldens(&toml.toml_language, "toml", ".toml", &goldens);
}

fn lex(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(toml.toml_language.lexer.lexLineFn, st, line);
}

test "toml: multiline basic string with trailing quotes" {
    // Up to two quotes before the closing `"""` belong to the content.
    const cases = [_]struct { []const u8, usize }{
        .{ "s = \"\"\"ab\"\"\" # c", 13 },
        .{ "s = \"\"\"ab\"\"\"\" # c", 14 },
        .{ "s = \"\"\"ab\"\"\"\"\" # c", 15 },
        .{ "s = '''ab''''' # c", 15 },
    };
    for (cases) |cs| {
        errdefer std.debug.print("case {s}\n", .{cs[0]});
        var l = try lex(.init(.toml), cs[0]);
        defer l.deinit();
        try std.testing.expectEqual(Mode.normal, l.state.mode);
        try std.testing.expectEqual(syntax.HighlightId.string, l.hlAt(cs[1] - 2));
        try std.testing.expectEqual(syntax.HighlightId.comment, l.hlAt(cs[1]));
    }
    // Across lines, with escaped quotes and a line-ending backslash.
    var a = try lex(.init(.toml), "s = \"\"\"");
    defer a.deinit();
    try std.testing.expectEqual(Mode.ml_basic, a.state.mode);
    var b = try lex(a.state, "text \\\"\"\" still \"\" \\");
    defer b.deinit();
    try std.testing.expectEqual(Mode.ml_basic, b.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.string_escape, b.hlAt(5));
    var c = try lex(b.state, "end\"\"\"\"\" # done");
    defer c.deinit();
    try std.testing.expectEqual(Mode.normal, c.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.comment, c.hlAt(9));
    // A literal string has no escapes.
    var d = try lex(.init(.toml), "p = '''C:\\");
    defer d.deinit();
    try std.testing.expectEqual(Mode.ml_literal, d.state.mode);
    var e = try lex(d.state, "dir\\''' = x");
    defer e.deinit();
    try std.testing.expectEqual(Mode.normal, e.state.mode);
}

test "toml: headers, arrays and values" {
    var a = try lex(.init(.toml), "[[bin]] # c");
    defer a.deinit();
    try std.testing.expectEqual(syntax.HighlightId.type, a.hlAt(0));
    try std.testing.expectEqualStrings("[[bin]]", a.textAt(0));
    var b = try lex(.init(.toml), "[ a . \"b.c\" ]");
    defer b.deinit();
    try std.testing.expectEqualStrings("[ a . \"b.c\" ]", b.textAt(0));
    // A `[` at the start of a line inside a multi-line array is an array.
    var c = try lex(.init(.toml), "m = [");
    defer c.deinit();
    try std.testing.expectEqual(@as(u16, 1), c.state.depth);
    var d = try lex(c.state, "[1, 2],");
    defer d.deinit();
    try std.testing.expectEqual(syntax.HighlightId.punctuation_bracket, d.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.number, d.hlAt(1));
    var e = try lex(d.state, "]");
    defer e.deinit();
    try std.testing.expectEqual(@as(u16, 0), e.state.depth);
    // Dotted keys, date-times, booleans and invalid values.
    var f = try lex(.init(.toml), "a.\"b\".c = 1979-05-27 07:32:00Z");
    defer f.deinit();
    try std.testing.expectEqual(syntax.HighlightId.property, f.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.property, f.hlAt(2));
    try std.testing.expectEqual(syntax.HighlightId.constant, f.hlAt(10));
    try std.testing.expectEqualStrings("1979-05-27 07:32:00Z", f.textAt(10));
    var g = try lex(.init(.toml), "t = { x = true, y = nope }");
    defer g.deinit();
    try std.testing.expectEqual(syntax.HighlightId.property, g.hlAt(6));
    try std.testing.expectEqual(syntax.HighlightId.constant_builtin, g.hlAt(10));
    try std.testing.expectEqual(syntax.HighlightId.property, g.hlAt(16));
    try std.testing.expectEqual(syntax.HighlightId.invalid, g.hlAt(20));
}

const pieces = [_][]const u8{ "key", " = ", "[", "]", "[[", "]]", "{", "}", ", ", ".", "\"s\"", "'l'", "\"\"\"", "'''", "\\", "#c", "1.5", "true", "1979-05-27", "\t", "é" };

test "toml: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x70);
    for (0..300) |_| try hl_test.checkIncremental(&toml.toml_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (toml)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&toml.toml_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
