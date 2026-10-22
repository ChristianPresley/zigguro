//! C and C++ lexer tests: goldens, line splicing, raw string delimiters,
//! tier-2 directive tokens and incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const c = @import("c.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Mode = c.Mode;

const c_goldens = [_][]const u8{
    "keywords",  "types",        "numbers",      "strings",  "chars",       "escapes",
    "comments",  "doc_comments", "preprocessor", "includes", "line_splice", "operators",
    "functions",
};

const cpp_goldens = [_][]const u8{
    "keywords",      "raw_strings", "digit_separators", "prefixes",   "templates", "namespaces",
    "operators",     "classes",     "lambdas",          "attributes", "comments",  "preprocessor",
    "user_literals",
};

test "c: golden highlights" {
    try lt.expectGoldens(&c.c_language, "c", ".c", &c_goldens);
}

test "cpp: golden highlights" {
    try lt.expectGoldens(&c.cpp_language, "cpp", ".cpp", &cpp_goldens);
}

fn lexC(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(c.c_language.lexer.lexLineFn, st, line);
}

fn lexCpp(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(c.cpp_language.lexer.lexLineFn, st, line);
}

test "c: line splice continues string" {
    var a = try lexC(.init(.c), "char *s = \"abc\\");
    defer a.deinit();
    try std.testing.expectEqual(Mode.string, a.state.mode);
    var b = try lexC(a.state, "def\"; int x;");
    defer b.deinit();
    try std.testing.expectEqual(Mode.code, b.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.string, b.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.type_builtin, b.hlAt(7));

    // A string without a splice ends at the line end.
    var d = try lexC(.init(.c), "char *s = \"abc");
    defer d.deinit();
    try std.testing.expectEqual(Mode.code, d.state.mode);

    // A char literal, a line comment and a directive continue the same way.
    var e = try lexC(.init(.c), "x = '\\");
    defer e.deinit();
    try std.testing.expectEqual(Mode.char, e.state.mode);
    var f = try lexC(.init(.c), "// comment \\");
    defer f.deinit();
    try std.testing.expectEqual(Mode.line_comment, f.state.mode);
    var g = try lexC(f.state, "still comment");
    defer g.deinit();
    try std.testing.expectEqual(syntax.HighlightId.comment, g.hlAt(0));
    try std.testing.expectEqual(Mode.code, g.state.mode);

    // A directive continued across lines, through a block comment.
    var h = try lexC(.init(.c), "#define MAX(a, b) \\");
    defer h.deinit();
    try std.testing.expectEqual(Mode.directive, h.state.mode);
    var i = try lexC(h.state, "  ((a) > (b) /* x");
    defer i.deinit();
    try std.testing.expectEqual(Mode.directive | Mode.block_comment, i.state.mode);
    var j = try lexC(i.state, "  */ ? (a) : (b))");
    defer j.deinit();
    try std.testing.expectEqual(Mode.code, j.state.mode);
    // A `#` inside a continued directive is the stringizing operator.
    var k = try lexC(h.state, "#a");
    defer k.deinit();
    try std.testing.expectEqual(syntax.HighlightId.operator, k.hlAt(0));

    // CRLF line endings keep the splice.
    var l = try lexC(.init(.c), "\"x\\\r");
    defer l.deinit();
    try std.testing.expectEqual(Mode.string, l.state.mode);
}

test "cpp: raw string delimiter in aux" {
    var a = try lexCpp(.init(.cpp), "auto s = R\"sql(SELECT )\" not the end");
    defer a.deinit();
    try std.testing.expectEqual(Mode.raw_string, a.state.mode);
    try std.testing.expectEqualStrings("sql", a.state.auxBytes());
    // `)"` without the delimiter does not close it.
    var b = try lexCpp(a.state, "  )\" )sq\" still");
    defer b.deinit();
    try std.testing.expectEqual(Mode.raw_string, b.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.string, b.hlAt(12));
    var d = try lexCpp(b.state, "FROM t)sql\"; int x;");
    defer d.deinit();
    try std.testing.expectEqual(Mode.code, d.state.mode);
    try std.testing.expectEqual(@as(usize, 0), d.state.auxBytes().len);
    try std.testing.expectEqual(syntax.HighlightId.type_builtin, d.hlAt(13));
    // Different delimiters are different states.
    var e = try lexCpp(.init(.cpp), "u8R\"x(");
    defer e.deinit();
    try std.testing.expectEqualStrings("x", e.state.auxBytes());
    try std.testing.expect(!e.state.eql(&a.state));
    // An empty delimiter, closed on the same line; backslashes are literal.
    var f = try lexCpp(.init(.cpp), "R\"(a\\)\" + 1");
    defer f.deinit();
    try std.testing.expectEqual(Mode.code, f.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.number, f.hlAt(10));
    // A delimiter that is too long is not a raw string.
    var g = try lexCpp(.init(.cpp), "R\"12345678901234567(x)12345678901234567\"");
    defer g.deinit();
    try std.testing.expectEqual(Mode.code, g.state.mode);
    // C has no raw strings: `R` is an identifier.
    var h = try lexC(.init(.c), "R\"x(");
    defer h.deinit();
    try std.testing.expectEqual(Mode.code, h.state.mode);
}

test "c: tier-2 directive tokens" {
    const lex = struct {
        fn f(st: *syntax.LexState, s: *syntax.Scanner, out: *syntax.TokenSink) void {
            c.lexLineWith(.{ .dialect = .c, .directive_tokens = true }, st, s, out);
        }
    }.f;
    var a = try lt.lexWith(lex, .init(.c), "  #define X(a) \\");
    defer a.deinit();
    try std.testing.expectEqual(@as(usize, 1), a.sink.tokens().len);
    try std.testing.expectEqual(c.Kind.directive, a.sink.tokens()[0].kind);
    var b = try lt.lexWith(lex, a.state, "    (a + 1)");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 1), b.sink.tokens().len);
    try std.testing.expectEqual(Mode.code, b.state.mode);
    var d = try lt.lexWith(lex, b.state, "int y;");
    defer d.deinit();
    try std.testing.expect(d.sink.tokens().len > 1);
}

test "c: every C keyword and type highlights" {
    var a = try lexC(.init(.c), "static inline unsigned long f(void) { return sizeof(int); }");
    defer a.deinit();
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, a.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.type_builtin, a.hlAt(14));
    try std.testing.expectEqual(syntax.HighlightId.function, a.hlAt(28));
    try std.testing.expectEqual(syntax.HighlightId.keyword_control, a.hlAt(39));
    try std.testing.expectEqual(syntax.HighlightId.keyword_operator, a.hlAt(46));
    // C++ words are identifiers in C.
    var b = try lexC(.init(.c), "class new");
    defer b.deinit();
    try std.testing.expectEqual(syntax.HighlightId.variable, b.hlAt(0));
}

const c_pieces = [_][]const u8{ "int ", "x", " = ", "\"s\\n", "\"", "\\", "'a'", "/*", "*/", "// c", "#define ", "#include <a.h>", "R\"d(", ")d\"", "(", ")", "{", "}", "0x1'0", "u8\"", "\t", "é", ";" };

test "c: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0xc1);
    for (0..200) |_| try hl_test.checkIncremental(&c.c_language, &r, &c_pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "cpp: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0xc2);
    for (0..200) |_| try hl_test.checkIncremental(&c.cpp_language, &r, &c_pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (cpp)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&c.cpp_language, &r, &c_pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
