//! Markdown lexer tests: goldens, fenced, HTML and front-matter
//! injection, inline spans and incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const markdown = @import("markdown.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");
const Doc = @import("html_test.zig").Doc;

const gpa = std.testing.allocator;

const goldens = [_][]const u8{
    "headings", "emphasis", "code", "fences",       "links",  "lists",
    "quotes",   "tables",   "html", "front_matter", "breaks", "readme",
};

test "markdown: golden highlights" {
    try lt.expectGoldens(&markdown.markdown_language, "markdown", ".md", &goldens);
}

test "markdown: fenced injection switches lexers and returns" {
    const lines = [_][]const u8{
        "# Title", //               0
        "```python", //             1
        "def f(): return 1", //     2
        "```", //                   3
        "after *em*", //            4
        "~~~~ {.js}", //            5
        "let x = 1;", //            6
        "~~~", //                   7 shorter: still inside
        "~~~~~", //                 8 closes
        "- ```zig", //              9 inside a list item
        "  const a = 1;", //        10
        "  ```", //                 11
        "tail", //                  12
    };
    var d = try Doc.init(&markdown.markdown_language, &lines);
    defer d.deinit();
    try std.testing.expectEqual(syntax.HighlightId.markup_heading_1, d.hlAt(0, 0));
    try std.testing.expectEqual(syntax.LanguageId.python, d.h.endState(1).top());
    try std.testing.expect(d.injectedAt(2, 0));
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, d.hlAt(2, 0));
    try std.testing.expect(!d.h.endState(3).injected());
    try std.testing.expectEqual(syntax.HighlightId.punctuation_delimiter, d.hlAt(3, 0));
    try std.testing.expectEqual(syntax.HighlightId.markup_italic, d.hlAt(4, 6));
    try std.testing.expectEqual(syntax.LanguageId.javascript, d.h.endState(5).top());
    try std.testing.expectEqual(syntax.LanguageId.javascript, d.h.endState(7).top());
    try std.testing.expect(d.injectedAt(7, 0));
    try std.testing.expect(!d.h.endState(8).injected());
    try std.testing.expectEqual(syntax.LanguageId.zig, d.h.endState(9).top());
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, d.hlAt(10, 2));
    try std.testing.expect(!d.h.endState(11).injected());
    try std.testing.expectEqual(syntax.HighlightId.none, d.hlAt(12, 0));
    try std.testing.expectEqual(@as(u16, markdown.Bits.paragraph | markdown.Bits.started), d.h.endState(12).mode);
}

test "markdown: unknown info string falls back to raw" {
    const lines = [_][]const u8{ "```nosuchlang extra", "code *not em*", "", "```", "*em*" };
    var d = try Doc.init(&markdown.markdown_language, &lines);
    defer d.deinit();
    try std.testing.expectEqual(syntax.HighlightId.label, d.hlAt(0, 3));
    try std.testing.expect(!d.h.endState(0).injected());
    try std.testing.expectEqual(syntax.HighlightId.markup_code, d.hlAt(1, 5));
    try std.testing.expect(!d.injectedAt(1, 5));
    try std.testing.expectEqual(markdown.Block.fence, d.h.endState(2).mode & markdown.Block.mask);
    try std.testing.expectEqual(markdown.Block.normal, d.h.endState(3).mode & markdown.Block.mask);
    try std.testing.expectEqual(syntax.HighlightId.markup_italic, d.hlAt(4, 0));
}

test "markdown: front matter yaml only at file start" {
    {
        const lines = [_][]const u8{ "---", "title: Notes", "tags: [a, b]", "---", "# Body" };
        var d = try Doc.init(&markdown.markdown_language, &lines);
        defer d.deinit();
        try std.testing.expectEqual(syntax.LanguageId.yaml, d.h.endState(0).top());
        try std.testing.expect(d.injectedAt(1, 0));
        try std.testing.expectEqual(syntax.HighlightId.property, d.hlAt(1, 0));
        try std.testing.expect(!d.h.endState(3).injected());
        try std.testing.expectEqual(syntax.HighlightId.punctuation_delimiter, d.hlAt(3, 0));
        try std.testing.expectEqual(syntax.HighlightId.markup_heading_1, d.hlAt(4, 0));
    }
    {
        // Not on the first line: a setext underline, then a thematic break.
        const lines = [_][]const u8{ "text", "---", "title: x", "", "---" };
        var d = try Doc.init(&markdown.markdown_language, &lines);
        defer d.deinit();
        try std.testing.expectEqual(syntax.HighlightId.markup_heading_2, d.hlAt(1, 0));
        try std.testing.expect(!d.h.endState(1).injected());
        try std.testing.expect(!d.injectedAt(2, 0));
        try std.testing.expectEqual(syntax.HighlightId.punctuation_delimiter, d.hlAt(4, 0));
    }
}

test "markdown: html blocks inject html until a blank line" {
    const lines = [_][]const u8{ "<div class=\"x\">", "<script>let a;</script>", "*not em*", "", "*em*" };
    var d = try Doc.init(&markdown.markdown_language, &lines);
    defer d.deinit();
    try std.testing.expectEqual(syntax.LanguageId.html, d.h.endState(0).top());
    try std.testing.expectEqual(syntax.HighlightId.tag, d.hlAt(0, 1));
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, d.hlAt(1, 8));
    try std.testing.expect(!d.h.endState(3).injected());
    try std.testing.expectEqual(syntax.HighlightId.markup_italic, d.hlAt(4, 0));
}

test "markdown: inline spans" {
    var l = try lt.lexWith(markdown.markdown_language.lexer.lexLineFn, .init(.markdown), "a **b** `c` [d](e) ![f][g] <https://h> https://i.j, \\* &amp; <b>k</b> snake_case_word");
    defer l.deinit();
    const S = syntax.HighlightId;
    const line = l.line;
    const at = struct {
        fn f(x: []const u8, needle: []const u8) usize {
            return std.mem.indexOf(u8, x, needle).?;
        }
    }.f;
    try std.testing.expectEqual(S.markup_bold, l.hlAt(at(line, "**b")));
    try std.testing.expectEqual(S.markup_code, l.hlAt(at(line, "`c")));
    try std.testing.expectEqual(S.markup_link, l.hlAt(at(line, "[d")));
    try std.testing.expectEqual(S.string_special, l.hlAt(at(line, "(e")));
    try std.testing.expectEqual(S.markup_link, l.hlAt(at(line, "![f")));
    try std.testing.expectEqual(S.markup_link, l.hlAt(at(line, "<https")));
    try std.testing.expectEqual(S.markup_link, l.hlAt(at(line, "https://i")));
    try std.testing.expectEqual(S.none, l.hlAt(at(line, ", \\")));
    try std.testing.expectEqual(S.string_escape, l.hlAt(at(line, "\\*")));
    try std.testing.expectEqual(S.string_escape, l.hlAt(at(line, "&amp")));
    try std.testing.expectEqual(S.tag, l.hlAt(at(line, "<b>")));
    try std.testing.expectEqual(S.none, l.hlAt(at(line, "_case")));
}

const pieces = [_][]const u8{ "# ", "```", "```python", "~~~", "x", "*a*", "`", "---", "<div>", "</div>", "", "- ", "> ", "|", "[l](u)", "    ", "\t", "é" };

test "markdown: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x3d);
    for (0..300) |_| try hl_test.checkIncremental(&markdown.markdown_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (markdown)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&markdown.markdown_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
