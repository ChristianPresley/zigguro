//! JSON and JSONC lexer tests: goldens, comment handling and
//! incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const json = @import("json.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Kind = json.Kind;

const json_goldens = [_][]const u8{
    "objects", "arrays",  "strings",  "escapes", "numbers",  "constants",
    "nested",  "invalid", "comments", "unicode", "minified", "package",
};

const jsonc_goldens = [_][]const u8{
    "comments", "block_comments", "trailing_commas", "settings", "tsconfig", "doc_comments",
    "nested",   "strings",        "multiline_block", "urls",     "launch",   "mixed",
};

test "json: golden highlights" {
    try lt.expectGoldens(&json.json_language, "json", ".json", &json_goldens);
}

test "jsonc: golden highlights" {
    try lt.expectGoldens(&json.jsonc_language, "jsonc", ".jsonc", &jsonc_goldens);
}

fn lexJson(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(json.json_language.lexer.lexLineFn, st, line);
}

fn lexJsonc(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(json.jsonc_language.lexer.lexLineFn, st, line);
}

fn kindAt(l: *const lt.Lexed, at: usize) u16 {
    var k: u16 = 0;
    for (l.sink.tokens()) |t| {
        if (t.start > at) break;
        k = t.kind;
    }
    return k;
}

test "json: comments flagged invalid, jsonc accepts" {
    const line = "{\"a\": 1, // note";
    var a = try lexJson(.init(.json), line);
    defer a.deinit();
    try std.testing.expectEqual(syntax.HighlightId.comment, a.hlAt(9));
    try std.testing.expectEqual(Kind.bad_comment, kindAt(&a, 9));
    try std.testing.expectEqual(syntax.ContextKind.comment, json.json_language.contextOf(Kind.bad_comment, .comment));
    var b = try lexJsonc(.init(.jsonc), line);
    defer b.deinit();
    try std.testing.expectEqual(syntax.HighlightId.comment, b.hlAt(9));
    try std.testing.expectEqual(Kind.comment, kindAt(&b, 9));
    // Block comments span lines in both dialects.
    var c = try lexJson(.init(.json), "[1, /* open");
    defer c.deinit();
    try std.testing.expectEqual(json.Mode.block_comment, c.state.mode);
    try std.testing.expectEqual(Kind.bad_comment, kindAt(&c, 4));
    var d = try lexJson(c.state, "still */ 2]");
    defer d.deinit();
    try std.testing.expectEqual(json.Mode.code, d.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.number, d.hlAt(9));
    var e = try lexJsonc(.init(.jsonc), "/* a */ {\"k\": [1, 2,],}");
    defer e.deinit();
    try std.testing.expectEqual(Kind.comment, kindAt(&e, 0));
    try std.testing.expectEqual(syntax.HighlightId.property, e.hlAt(9));
    try std.testing.expectEqual(syntax.HighlightId.punctuation_delimiter, e.hlAt(19));
}

test "json: keys, escapes and invalid tokens" {
    var a = try lexJson(.init(.json), "{\"k\\\"ey\" : \"v\\u00e9\\n\", \"n\": -1.5e+3, \"t\": tru}");
    defer a.deinit();
    try std.testing.expectEqual(syntax.HighlightId.property, a.hlAt(1));
    try std.testing.expectEqual(syntax.HighlightId.property, a.hlAt(4));
    try std.testing.expectEqual(syntax.HighlightId.string, a.hlAt(11));
    try std.testing.expectEqual(syntax.HighlightId.string_escape, a.hlAt(14));
    try std.testing.expectEqual(syntax.HighlightId.string_escape, a.hlAt(20));
    try std.testing.expectEqual(syntax.HighlightId.number, a.hlAt(31));
    try std.testing.expectEqual(syntax.HighlightId.invalid, a.hlAt(44));
}

const pieces = [_][]const u8{ "{", "}", "[", "]", "\"k\"", ": ", ", ", "1.5", "true", "null", "\"s\\n\"", "//c", "/*", "*/", " ", "\t", "\"", "é" };

test "json: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x15);
    for (0..300) |_| try hl_test.checkIncremental(&json.json_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
    for (0..300) |_| try hl_test.checkIncremental(&json.jsonc_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (json)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&json.jsonc_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
