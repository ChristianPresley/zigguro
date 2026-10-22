//! JavaScript/TypeScript/JSX/TSX lexer tests: goldens, regex versus
//! division, template nesting, JSX versus generics and
//! incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const js = @import("js.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Frame = js.Frame;

const js_goldens = [_][]const u8{
    "keywords", "strings", "templates", "regex",    "numbers", "comments",
    "classes",  "modules", "operators", "hashbang", "async",   "objects",
};
const ts_goldens = [_][]const u8{
    "types",   "interfaces", "generics", "enums",      "decorators", "namespaces",
    "classes", "contextual", "unions",   "assertions", "declare",    "overloads",
};
const jsx_goldens = [_][]const u8{
    "elements",   "attributes",  "expressions", "fragments", "nested",       "entities",
    "components", "conditional", "lists",       "multiline", "self_closing", "text",
};
const tsx_goldens = [_][]const u8{
    "component", "generics", "props",  "hooks",    "arrow_generics", "assertions",
    "fragments", "nested",   "events", "children", "conditional",    "lists",
};

test "js: golden highlights" {
    try lt.expectGoldens(&js.javascript_language, "js", ".js", &js_goldens);
}

test "ts: golden highlights" {
    try lt.expectGoldens(&js.typescript_language, "ts", ".ts", &ts_goldens);
}

test "jsx: golden highlights" {
    try lt.expectGoldens(&js.jsx_language, "jsx", ".jsx", &jsx_goldens);
}

test "tsx: golden highlights" {
    try lt.expectGoldens(&js.tsx_language, "tsx", ".tsx", &tsx_goldens);
}

fn lexJs(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(js.javascript_language.lexer.lexLineFn, st, line);
}

fn lexTs(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(js.typescript_language.lexer.lexLineFn, st, line);
}

fn lexTsx(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(js.tsx_language.lexer.lexLineFn, st, line);
}

test "js: regex vs division table" {
    // Each case: a line and whether its first `/` starts a regex.
    const cases = [_]struct { []const u8, bool }{
        .{ "x = /a/g", true },
        .{ "f(/a/)", true },
        .{ "[/a/, 1]", true },
        .{ "return /a/.test(s)", true },
        .{ "typeof /a/", true },
        .{ "a && /b/.test(c)", true },
        .{ "a || /b/", true },
        .{ "!/a/.test(s)", true },
        .{ "x ? /a/ : 1", true },
        .{ "{ /a/ }", true },
        .{ "} /a/.test(x)", true },
        .{ "; /a/.exec(s)", true },
        .{ "case /a/:", true },
        .{ "do /a/.test(x); while (0)", true },
        .{ "else /a/.test(x)", true },
        .{ "x in /a/", true },
        .{ "for (x of [/a/]) {}", true },
        .{ "new /a/.constructor()", true },
        .{ "delete /a/.x", true },
        .{ "void /a/", true },
        .{ "throw /a/", true },
        .{ "yield /a/", true },
        .{ "await /a/", true },
        .{ "/[/]/.test(s)", true },
        .{ "x = /\\//", true },
        .{ "a = b ? c : /d/", true },
        .{ "x += /a/.source", true },
        .{ "f = () => /a/", true },
        .{ "a, /b/", true },
        .{ "(/a/)", true },
        .{ "a = b === /c/", true },
        .{ "a / b", false },
        .{ "a / 2 / 3", false },
        .{ "f() / 2", false },
        .{ "a[0] / 2", false },
        .{ "1 / x", false },
        .{ "\"s\" / 2", false },
        .{ "this / 2", false },
        .{ "x.y / 2", false },
        .{ "a++ / 2", false },
        .{ "x /= 2", false },
        .{ "0x10 / 2", false },
        .{ "`t` / 2", false },
        .{ "true / 1", false },
        .{ "x.return / 2", false },
        .{ "of / 2", false },
        .{ "1n / 2n", false },
        .{ "#p / 2", false },
        .{ "a?.b / 2", false },
    };
    for (cases) |cs| {
        errdefer std.debug.print("case {s}\n", .{cs[0]});
        var l = try lexJs(.init(.javascript), cs[0]);
        defer l.deinit();
        const at = std.mem.indexOfScalar(u8, cs[0], '/').?;
        try std.testing.expectEqual(cs[1], l.hlAt(at) == .string_special);
    }
    // The previous token carries across lines.
    var a = try lexJs(.init(.javascript), "x = a");
    defer a.deinit();
    var b = try lexJs(a.state, "  / b");
    defer b.deinit();
    try std.testing.expectEqual(syntax.HighlightId.operator, b.hlAt(2));
    var c = try lexJs(.init(.javascript), "return");
    defer c.deinit();
    var d = try lexJs(c.state, "/a/.test(s)");
    defer d.deinit();
    try std.testing.expectEqual(syntax.HighlightId.string_special, d.hlAt(0));
}

test "js: template nesting ${ {a: `${b}`} }" {
    const line = "s = `x${ {a: `${b}`} }c`;";
    var l = try lexJs(.init(.javascript), line);
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 0), l.state.auxBytes().len);
    try std.testing.expectEqual(syntax.HighlightId.variable, l.hlAt(std.mem.indexOf(u8, line, "b}").?));
    try std.testing.expectEqual(syntax.HighlightId.string, l.hlAt(std.mem.indexOf(u8, line, "c`").?));
    try std.testing.expectEqual(syntax.HighlightId.punctuation_delimiter, l.hlAt(line.len - 1));
    // Across lines: the frames and the brace count survive.
    var a = try lexJs(.init(.javascript), "s = `head ${ {");
    defer a.deinit();
    try std.testing.expectEqualSlices(u8, &.{ Frame.template, Frame.template_expr | 1 }, a.state.auxBytes());
    var b = try lexJs(a.state, "  k: `in ${v}`,");
    defer b.deinit();
    try std.testing.expectEqualSlices(u8, &.{ Frame.template, Frame.template_expr | 1 }, b.state.auxBytes());
    var c = try lexJs(b.state, "} } tail`;");
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.state.auxBytes().len);
    try std.testing.expectEqual(syntax.HighlightId.string, c.hlAt(5));
    // A template that spans lines.
    var d = try lexJs(.init(.javascript), "`line one");
    defer d.deinit();
    try std.testing.expectEqualSlices(u8, &.{Frame.template}, d.state.auxBytes());
    var e = try lexJs(d.state, "/not a regex/ ${x}`");
    defer e.deinit();
    try std.testing.expectEqual(syntax.HighlightId.string, e.hlAt(0));
    try std.testing.expectEqual(@as(usize, 0), e.state.auxBytes().len);
    // Overflow degrades instead of failing.
    var deep: [40]u8 = undefined;
    for (0..20) |i| @memcpy(deep[i * 2 ..][0..2], "`$");
    var f = try lexJs(.init(.javascript), &deep);
    defer f.deinit();
    try std.testing.expect(f.state.auxBytes().len <= js.max_frames);
}

test "tsx: generic arrow vs JSX tag table" {
    // Each case: a line, whether its first `<` opens JSX, and whether the
    // line ends with no open frames.
    const cases = [_]struct { []const u8, bool }{
        .{ "const f = <T,>(x: T) => x;", false },
        .{ "const f = <T extends unknown>(x: T) => x;", false },
        .{ "const f = <T, U>(a: T, b: U) => a;", false },
        .{ "const g = <Text>hi</Text>;", true },
        .{ "const e = <T>text</T>;", true },
        .{ "const e = <div className=\"a\">hi</div>;", true },
        .{ "return <Foo.Bar x={1} />;", true },
        .{ "const e = <>frag</>;", true },
        .{ "if (a < b) {}", false },
        .{ "x = a<b>(c);", false },
        .{ "f(<span />)", true },
        .{ "const t = <Item key={i} {...p} />", true },
    };
    for (cases) |cs| {
        errdefer std.debug.print("case {s}\n", .{cs[0]});
        var l = try lexTsx(.init(.tsx), cs[0]);
        defer l.deinit();
        const at = std.mem.indexOfScalar(u8, cs[0], '<').?;
        try std.testing.expectEqual(cs[1], l.hlAt(at) == .punctuation and l.hlAt(at) != .operator);
        try std.testing.expectEqual(@as(usize, 0), l.state.auxBytes().len);
    }
    // Plain TypeScript never starts JSX.
    var a = try lexTs(.init(.typescript), "const e = <T>x;");
    defer a.deinit();
    try std.testing.expectEqual(syntax.HighlightId.operator, a.hlAt(10));
    // Nested elements across lines.
    var b = try lexTsx(.init(.tsx), "return (<ul>");
    defer b.deinit();
    try std.testing.expectEqualSlices(u8, &.{Frame.jsx_children}, b.state.auxBytes());
    var c = try lexTsx(b.state, "  <li onClick={() => go({a: 1})}>a &amp; b</li>");
    defer c.deinit();
    try std.testing.expectEqualSlices(u8, &.{Frame.jsx_children}, c.state.auxBytes());
    try std.testing.expectEqual(syntax.HighlightId.string_escape, c.hlAt(std.mem.indexOf(u8, c.line, "&amp;").?));
    var d = try lexTsx(c.state, "</ul>) / 2;");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.state.auxBytes().len);
    try std.testing.expectEqual(syntax.HighlightId.operator, d.hlAt(7));
}

test "ts: contextual keywords" {
    var a = try lexTs(.init(.typescript), "type T = string; const type = 1; x as number;");
    defer a.deinit();
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, a.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.type_builtin, a.hlAt(9));
    try std.testing.expectEqual(syntax.HighlightId.variable, a.hlAt(23));
    try std.testing.expectEqual(syntax.HighlightId.keyword, a.hlAt(36));
    try std.testing.expectEqual(syntax.HighlightId.type_builtin, a.hlAt(39));
}

const pieces = [_][]const u8{ "x", " = ", "/", "/a/g", "`", "${", "}", "{", "(", ")", "\"s\\", "'", "//c", "/*", "*/", "<div>", "</div>", "<T,>", "/>", ">", "return ", ".", "1", "\t", "é" };

test "js: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x75);
    for ([_]*const syntax.Language{ &js.javascript_language, &js.typescript_language, &js.jsx_language, &js.tsx_language }) |lang| {
        for (0..200) |_| try hl_test.checkIncremental(lang, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
    }
}

test "fuzz: incremental highlight equals full (tsx)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&js.tsx_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}

test "fuzz: incremental highlight equals full (js)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&js.javascript_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
