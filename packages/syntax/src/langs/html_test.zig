//! HTML lexer tests: goldens, script/style injection, raw text and
//! incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const html = @import("html.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const injected = syntax.Token.injected_bit;

const goldens = [_][]const u8{
    "document", "attributes", "comments", "entities", "script",    "style",
    "raw_text", "doctype",    "void",     "forms",    "multiline", "template",
};

test "html: golden highlights" {
    try lt.expectGoldens(&html.html_language, "html", ".html", &goldens);
}

/// A highlighted document.
pub const Doc = struct {
    r: syntax.Registry,
    h: syntax.Highlighter,
    lines: []const []const u8,

    pub fn init(lang: *const syntax.Language, lines: []const []const u8) !*Doc {
        const d = try gpa.create(Doc);
        errdefer gpa.destroy(d);
        d.lines = lines;
        d.r = try lt.registry();
        errdefer d.r.deinit(gpa);
        d.h = try .init(gpa, lang, &d.r);
        const src = syntax.LineSource.fromSlice(&d.lines);
        try d.h.reset(src);
        _ = try d.h.idle(src, null);
        return d;
    }

    pub fn deinit(d: *Doc) void {
        d.h.deinit();
        d.r.deinit(gpa);
        gpa.destroy(d);
    }

    /// The token covering byte `at` of line `i`.
    pub fn tokenAt(d: *const Doc, i: usize, at: usize) syntax.Token {
        var tok: syntax.Token = .{ .start = 0, .kind = 0, .hl = .none };
        for (d.h.tokens(i)) |t| {
            if (t.start > at) break;
            tok = t;
        }
        return tok;
    }

    pub fn hlAt(d: *const Doc, i: usize, at: usize) syntax.HighlightId {
        return d.tokenAt(i, at).hl;
    }

    pub fn injectedAt(d: *const Doc, i: usize, at: usize) bool {
        return d.tokenAt(i, at).kind & injected != 0;
    }
};

test "html: script/style injection" {
    const lines = [_][]const u8{
        "<script>", //                      0
        "let x = 1; // c", //               1
        "</script>", //                     2
        "<style>", //                       3
        "a { color: red; }", //             4
        "</style>", //                      5
        "<p class=\"t\">x &amp; y</p>", //  6
        "<script type=\"module\">import a from \"a\";</script>", // 7
        "<script type=\"text/template\"><b>{{x}}</b></script>", // 8
        "<STYLE>p{}</Style><b>", //         9
    };
    var d = try Doc.init(&html.html_language, &lines);
    defer d.deinit();
    try std.testing.expect(d.h.endState(0).injected());
    try std.testing.expectEqual(syntax.LanguageId.javascript, d.h.endState(1).top());
    try std.testing.expect(d.injectedAt(1, 0));
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, d.hlAt(1, 0));
    try std.testing.expectEqual(syntax.HighlightId.comment, d.hlAt(1, 12));
    try std.testing.expect(!d.h.endState(2).injected());
    try std.testing.expectEqual(syntax.HighlightId.tag, d.hlAt(2, 2));
    try std.testing.expectEqual(syntax.LanguageId.css, d.h.endState(3).top());
    try std.testing.expectEqual(syntax.HighlightId.tag, d.hlAt(4, 0));
    try std.testing.expect(d.injectedAt(4, 0));
    try std.testing.expect(!d.h.endState(5).injected());
    try std.testing.expectEqual(syntax.HighlightId.attribute, d.hlAt(6, 3));
    try std.testing.expectEqual(syntax.HighlightId.string_escape, d.hlAt(6, 15));
    // A module script is JavaScript; a template script is raw text.
    try std.testing.expect(d.injectedAt(7, 22));
    try std.testing.expectEqual(syntax.HighlightId.keyword, d.hlAt(7, 22));
    try std.testing.expect(!d.h.endState(7).injected());
    try std.testing.expect(!d.injectedAt(8, 30));
    try std.testing.expectEqual(syntax.HighlightId.none, d.hlAt(8, 30));
    try std.testing.expectEqual(syntax.HighlightId.tag, d.hlAt(8, 43));
    // End tags match in any case.
    try std.testing.expect(d.injectedAt(9, 7));
    try std.testing.expectEqual(syntax.HighlightId.tag, d.hlAt(9, 12));
    try std.testing.expectEqual(syntax.HighlightId.tag, d.hlAt(9, 19));
    try std.testing.expectEqual(@as(u16, 0), d.h.endState(9).mode & html.State.mask);
}

test "html: </script inside JS string still ends script" {
    const lines = [_][]const u8{
        "<script>var s = \"</script>\";",
        "<p>after</p>",
    };
    var d = try Doc.init(&html.html_language, &lines);
    defer d.deinit();
    const at = std.mem.indexOf(u8, lines[0], "</script>").?;
    try std.testing.expect(d.injectedAt(0, at - 1));
    try std.testing.expect(!d.injectedAt(0, at));
    try std.testing.expectEqual(syntax.HighlightId.tag, d.hlAt(0, at + 2));
    // What follows the end tag is HTML text again.
    try std.testing.expectEqual(syntax.HighlightId.none, d.hlAt(0, at + 9));
    try std.testing.expect(!d.h.endState(0).injected());
    try std.testing.expectEqual(syntax.HighlightId.tag, d.hlAt(1, 1));
}

test "html: comments, rcdata and attributes across lines" {
    var a = try lt.lexWith(html.html_language.lexer.lexLineFn, .init(.html), "<!-- open <b>");
    defer a.deinit();
    try std.testing.expectEqual(html.State.comment, a.state.mode & html.State.mask);
    var b = try lt.lexWith(html.html_language.lexer.lexLineFn, a.state, "still --> <i>");
    defer b.deinit();
    try std.testing.expectEqual(syntax.HighlightId.comment, b.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.tag, b.hlAt(11));
    var c = try lt.lexWith(html.html_language.lexer.lexLineFn, .init(.html), "<textarea><b>&lt;</textarea>");
    defer c.deinit();
    try std.testing.expectEqual(syntax.HighlightId.none, c.hlAt(10));
    try std.testing.expectEqual(syntax.HighlightId.string_escape, c.hlAt(13));
    try std.testing.expectEqual(syntax.HighlightId.tag, c.hlAt(19));
    var e = try lt.lexWith(html.html_language.lexer.lexLineFn, .init(.html), "<a href=\"long");
    defer e.deinit();
    try std.testing.expectEqual(html.State.attr_dq, e.state.mode & html.State.mask);
    var f = try lt.lexWith(html.html_language.lexer.lexLineFn, e.state, "value\" id=x>text");
    defer f.deinit();
    try std.testing.expectEqual(syntax.HighlightId.string, f.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.attribute, f.hlAt(7));
    try std.testing.expectEqual(html.State.data, f.state.mode & html.State.mask);
}

const pieces = [_][]const u8{ "<p>", "</p>", "<script>", "</script>", "<style>", "</style>", "<!--", "-->", "x", " a=\"", "\"", ">", "&amp;", "{ }", "\"</script>\"", "<textarea>", "\t", "é" };

test "html: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x47);
    for (0..300) |_| try hl_test.checkIncremental(&html.html_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (html)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&html.html_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
