//! Markdown code-block highlighting through zg_syntax: spans, class
//! mapping, unknown languages and the view seam.

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const zg_gui = @import("zg_gui");
const mh = @import("markdown_highlighter.zig");

const gpa = std.testing.allocator;
const Span = zg_gui.markdown.code_view.Span;
const SyntaxClass = zg_gui.markdown.code_view.SyntaxClass;

fn classAt(spans: []const Span, at: u32) SyntaxClass {
    for (spans) |s| if (s.start <= at and at < s.end) return s.class;
    return .plain;
}

fn run(lang: []const u8, code: []const u8) !std.ArrayList(Span) {
    var m = try mh.MarkdownHighlighter.init(gpa);
    defer m.deinit(gpa);
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);
    const h = m.highlighter();
    try h.highlight(h.ptr, gpa, lang, code, &out);
    return out;
}

test "markdown highlighter: zig code gets keyword, string, number and comment spans" {
    const code = "const s = \"hi\";\nvar n: u32 = 42; // note";
    var out = try run("zig", code);
    defer out.deinit(gpa);
    try std.testing.expectEqual(SyntaxClass.keyword, classAt(out.items, 0));
    try std.testing.expectEqual(SyntaxClass.string, classAt(out.items, 10));
    const nl: u32 = @intCast(std.mem.indexOfScalar(u8, code, '\n').? + 1);
    try std.testing.expectEqual(SyntaxClass.keyword, classAt(out.items, nl));
    try std.testing.expectEqual(SyntaxClass.type, classAt(out.items, nl + 7));
    try std.testing.expectEqual(SyntaxClass.number, classAt(out.items, nl + 13));
    try std.testing.expectEqual(SyntaxClass.comment, classAt(out.items, nl + 17));
    try std.testing.expectEqual(SyntaxClass.plain, classAt(out.items, nl + 4));
}

test "markdown highlighter: spans are sorted, disjoint and within the code" {
    const code = "fn main() {\r\n    println!(\"{}\", 1 + 2);\r\n}\r\n";
    var out = try run("rs", code);
    defer out.deinit(gpa);
    try std.testing.expect(out.items.len > 0);
    var prev: u32 = 0;
    for (out.items) |s| {
        try std.testing.expect(s.start >= prev and s.end > s.start and s.end <= code.len);
        try std.testing.expect(s.class != .plain);
        prev = s.end;
    }
    // CRs are not highlighted as part of tokens.
    for (out.items) |s| try std.testing.expect(std.mem.indexOfScalar(u8, code[s.start..s.end], '\r') == null);
}

test "markdown highlighter: aliases and case resolve, unknown languages give nothing" {
    var a = try run("Py", "def f(): pass");
    defer a.deinit(gpa);
    try std.testing.expectEqual(SyntaxClass.keyword, classAt(a.items, 0));
    var b = try run("no-such-lang", "def f(): pass");
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), b.items.len);
}

test "markdown highlighter: html injects script colours" {
    const code = "<script>let a = 1;</script>";
    var out = try run("html", code);
    defer out.deinit(gpa);
    try std.testing.expectEqual(SyntaxClass.punctuation, classAt(out.items, 0));
    try std.testing.expectEqual(SyntaxClass.keyword, classAt(out.items, 1));
    try std.testing.expectEqual(SyntaxClass.keyword, classAt(out.items, 8));
    try std.testing.expectEqual(SyntaxClass.number, classAt(out.items, 16));
}

test "markdown highlighter: class mapping follows dotted parents" {
    try std.testing.expectEqual(SyntaxClass.keyword, mh.classOf(.keyword_control));
    try std.testing.expectEqual(SyntaxClass.string, mh.classOf(.string_escape));
    try std.testing.expectEqual(SyntaxClass.comment, mh.classOf(.comment_doc));
    try std.testing.expectEqual(SyntaxClass.type, mh.classOf(.type_builtin));
    try std.testing.expectEqual(SyntaxClass.function, mh.classOf(.function_macro));
    try std.testing.expectEqual(SyntaxClass.punctuation, mh.classOf(.punctuation_bracket));
    try std.testing.expectEqual(SyntaxClass.constant, mh.classOf(.constant_builtin));
    try std.testing.expectEqual(SyntaxClass.plain, mh.classOf(.variable_parameter));
    try std.testing.expectEqual(SyntaxClass.plain, mh.classOf(.none));
}

test "markdown highlighter: drives a Markdown view's code blocks" {
    var m = try mh.MarkdownHighlighter.init(gpa);
    defer m.deinit(gpa);
    var cache: zg_gui.markdown.code_view.Cache = .{};
    defer cache.deinit(gpa);
    var stats: zg_gui.markdown.view_mod.Stats = .{};
    const code = "const x = 1;";
    cache.update(gpa, m.highlighter(), &stats, 0, "zig", code, false);
    try std.testing.expectEqual(@as(u32, 1), stats.highlighted);
    try std.testing.expectEqual(SyntaxClass.keyword, classAt(cache.spansOf(0), 0));
}
