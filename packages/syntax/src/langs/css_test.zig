//! CSS lexer tests: goldens, custom properties and url(), nesting and
//! incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const css = @import("css.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;

const goldens = [_][]const u8{
    "selectors", "declarations", "custom_properties", "urls",    "at_rules",  "media",
    "comments",  "numbers",      "functions",         "nesting", "keyframes", "attributes",
};

test "css: golden highlights" {
    try lt.expectGoldens(&css.css_language, "css", ".css", &goldens);
}

fn lex(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(css.css_language.lexer.lexLineFn, st, line);
}

test "css: custom properties and url()" {
    const line = ":root { --main-color: #06c; --gap: calc(1rem + 2px); }";
    var a = try lex(.init(.css), line);
    defer a.deinit();
    try std.testing.expectEqual(syntax.HighlightId.attribute, a.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.variable, a.hlAt(8));
    try std.testing.expectEqualStrings("--main-color", a.textAt(8));
    try std.testing.expectEqual(syntax.HighlightId.constant, a.hlAt(22));
    try std.testing.expectEqual(syntax.HighlightId.function_builtin, a.hlAt(35));
    try std.testing.expectEqual(syntax.HighlightId.number, a.hlAt(40));
    try std.testing.expectEqualStrings("1rem", a.textAt(40));
    try std.testing.expectEqual(@as(u16, 0), a.state.depth);
    var b = try lex(.init(.css), "a { color: var(--main-color, red) !important; }");
    defer b.deinit();
    try std.testing.expectEqual(syntax.HighlightId.function_builtin, b.hlAt(11));
    try std.testing.expectEqual(syntax.HighlightId.variable, b.hlAt(15));
    try std.testing.expectEqual(syntax.HighlightId.constant, b.hlAt(29));
    try std.testing.expectEqual(syntax.HighlightId.keyword, b.hlAt(34));
    // url() with an unquoted argument is one string, quoted is a string.
    var c = try lex(.init(.css), "b { background: url(data:image/png;base64,iVBOR==) no-repeat; }");
    defer c.deinit();
    try std.testing.expectEqual(syntax.HighlightId.function_builtin, c.hlAt(16));
    try std.testing.expectEqualStrings("data:image/png;base64,iVBOR==", c.textAt(20));
    try std.testing.expectEqual(syntax.HighlightId.string_special, c.hlAt(20));
    try std.testing.expectEqual(syntax.HighlightId.constant, c.hlAt(51));
    var d = try lex(.init(.css), "@import url(\"a.css\") screen;");
    defer d.deinit();
    try std.testing.expectEqual(syntax.HighlightId.keyword, d.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.string, d.hlAt(12));
    try std.testing.expectEqual(syntax.HighlightId.constant, d.hlAt(21));
    try std.testing.expectEqual(@as(u16, 0), d.state.mode);
}

test "css: nesting and multi-line values" {
    var a = try lex(.init(.css), ".card {");
    defer a.deinit();
    try std.testing.expectEqual(@as(u16, 1), a.state.depth);
    var b = try lex(a.state, "  &:hover { color: red; }");
    defer b.deinit();
    try std.testing.expectEqual(syntax.HighlightId.operator, b.hlAt(2));
    try std.testing.expectEqual(syntax.HighlightId.attribute, b.hlAt(3));
    try std.testing.expectEqual(syntax.HighlightId.property, b.hlAt(12));
    var c = try lex(b.state, "  grid-template-areas:");
    defer c.deinit();
    try std.testing.expect(c.state.mode & css.Bits.value != 0);
    var d = try lex(c.state, "    \"a b\" \"c d\";");
    defer d.deinit();
    try std.testing.expectEqual(syntax.HighlightId.string, d.hlAt(4));
    try std.testing.expectEqual(@as(u16, 0), d.state.mode);
    var e = try lex(d.state, "}");
    defer e.deinit();
    try std.testing.expectEqual(@as(u16, 0), e.state.depth);
}

const pieces = [_][]const u8{ "a", ".c", "#i", " { ", " }", "color", ": ", "red", "; ", "--x", "url(", ")", "\"s\"", "/*", "*/", "@media ", "1.5em", "&", "\t", "é" };

test "css: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0xc5);
    for (0..300) |_| try hl_test.checkIncremental(&css.css_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (css)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&css.css_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
