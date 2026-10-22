//! Tests for fallback structure: bracket and indentation folds, comment
//! runs, region markers, declaration scopes and the Markdown outline.

const std = @import("std");
const fallback = @import("fallback.zig");
const structure = @import("structure.zig");
const language = @import("../language.zig");
const bracket_tree = @import("../brackets/bracket_tree.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Language = language.Language;
const BracketTree = bracket_tree.BracketTree;
const FoldRange = structure.FoldRange;

const c_like: Language = .{
    .id = .c,
    .name = "c-like",
    .lexer = language.plain.lexer,
    .edit_rules = .{ .line_comment = "//", .block_comment = .{ .open = "/*", .close = "*/" } },
    .brackets = &.{ .{ .open = "(", .close = ")" }, .{ .open = "[", .close = "]" }, .{ .open = "{", .close = "}" } },
};

const python: Language = .{
    .id = .python,
    .name = "python",
    .lexer = language.plain.lexer,
    .fold_by_indent = true,
    .edit_rules = .{ .line_comment = "#" },
    .brackets = c_like.brackets,
};

const yaml: Language = .{
    .id = .yaml,
    .name = "yaml",
    .lexer = language.plain.lexer,
    .fold_by_indent = true,
    .decl_keywords = &.{},
    .edit_rules = .{ .line_comment = "#" },
};

const markdown: Language = .{ .id = .markdown, .name = "markdown", .lexer = language.plain.lexer };

/// Bracket tokens of `text`: `()[]{}` outside double-quoted strings.
fn scanBrackets(text: []const u8, out: *std.ArrayList(bracket_tree.BracketToken)) !void {
    var in_str = false;
    for (text, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (c == '\n') in_str = false;
        if (in_str) continue;
        const k: ?struct { u6, bool } = switch (c) {
            '(' => .{ 0, true },
            ')' => .{ 0, false },
            '[' => .{ 1, true },
            ']' => .{ 1, false },
            '{' => .{ 2, true },
            '}' => .{ 2, false },
            else => null,
        };
        if (k) |x| try out.append(gpa, .{ .offset = i, .len = 1, .pair = x[0], .open = x[1] });
    }
}

fn parse(text: []const u8, lang: *const Language, with_brackets: bool) !structure.Structure {
    var toks: std.ArrayList(bracket_tree.BracketToken) = .empty;
    defer toks.deinit(gpa);
    try scanBrackets(text, &toks);
    var src: bracket_tree.SliceSource = .{ .tokens = toks.items, .text_len = text.len };
    var bt: BracketTree = try .build(gpa, src.source());
    defer bt.deinit();
    return fallback.fallbackStructure(gpa, text, 1, if (with_brackets) &bt else null, lang, .{});
}

fn expectFolds(s: *const structure.Structure, want: []const struct { u32, u32, structure.FoldKind }) !void {
    errdefer for (s.folds) |f| std.debug.print("fold {d}..{d} {t}\n", .{ f.start_line, f.end_line, f.kind });
    try testing.expectEqual(want.len, s.folds.len);
    for (want, s.folds) |w, f| {
        try testing.expectEqual(w[0], f.start_line);
        try testing.expectEqual(w[1], f.end_line);
        try testing.expectEqual(w[2], f.kind);
    }
}

fn expectSymbols(s: *const structure.Structure, want: []const struct { []const u8, structure.SymbolKind, ?u32 }) !void {
    errdefer for (s.symbols) |x| std.debug.print("symbol {s} {t} {?d}\n", .{ x.name, x.kind, x.parent });
    try testing.expectEqual(want.len, s.symbols.len);
    for (want, s.symbols) |w, x| {
        try testing.expectEqualStrings(w[0], x.name);
        try testing.expectEqual(w[1], x.kind);
        try testing.expectEqual(w[2], x.parent);
    }
}

test "fallback: bracket folds, scopes and outline" {
    const text =
        \\// A file header that
        \\// runs over three
        \\// lines.
        \\struct Point {
        \\    x: i32, y: i32,
        \\};
        \\
        \\pub fn area(
        \\    a: Point,
        \\    b: Point,
        \\) i32 {
        \\    if (a.x > 0) {
        \\        return call("}", [
        \\            1, 2]);
        \\    }
        \\    return 0;
        \\}
        \\/* two
        \\   lines */
        \\
    ;
    var s = try parse(text, &c_like, true);
    defer s.deinit();
    try expectFolds(&s, &.{
        .{ 0, 2, .comment },
        .{ 3, 4, .block },
        .{ 7, 9, .block },
        .{ 10, 15, .block },
        .{ 11, 13, .block },
        .{ 12, 13, .block },
        .{ 17, 18, .comment },
    });
    try expectSymbols(&s, &.{ .{ "Point", .@"struct", null }, .{ "area", .function, null } });
    // The function's scope runs from its header line to the closing brace.
    var scopes: std.ArrayList(structure.Scope) = .empty;
    defer scopes.deinit(gpa);
    const ret = std.mem.indexOf(u8, text, "return 0").?;
    try s.enclosingScopes(gpa, @intCast(ret), &scopes);
    try testing.expectEqual(@as(usize, 1), scopes.items.len);
    try testing.expectEqualStrings("area", scopes.items[0].name);
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "pub fn").?)), scopes.items[0].range.start);
    try testing.expectEqual(structure.SymbolKind.function, s.symbols[1].kind);
    try testing.expectEqual(@as(u8, 12), s.symbols[1].kind.lspKind());
}

test "fallback: indentation folds python/yaml golden" {
    const py =
        \\import os
        \\
        \\class Shape:
        \\    """Doc."""
        \\
        \\    def area(self):
        \\        if self.w:
        \\            return self.w * self.h
        \\
        \\        return 0
        \\
        \\
        \\def main():
        \\    print(Shape().area())
        \\# trailing comment
        \\
    ;
    var s = try parse(py, &python, true);
    defer s.deinit();
    try expectFolds(&s, &.{ .{ 2, 9, .block }, .{ 5, 9, .block }, .{ 6, 7, .block }, .{ 12, 13, .block } });
    try expectSymbols(&s, &.{ .{ "Shape", .class, null }, .{ "area", .function, 0 }, .{ "main", .function, null } });

    const yml =
        \\# config
        \\server:
        \\  host: localhost
        \\  ports:
        \\    - 80
        \\    - 443
        \\
        \\  tls: true
        \\client:
        \\  retries: 3
        \\
    ;
    var y = try parse(yml, &yaml, false);
    defer y.deinit();
    try expectFolds(&y, &.{ .{ 1, 7, .block }, .{ 3, 5, .block }, .{ 8, 9, .block } });
    try testing.expectEqual(@as(usize, 0), y.symbols.len);
}

test "fallback: region markers" {
    const text =
        \\// #region Helpers
        \\fn a() {}
        \\// #region Inner
        \\fn b() {}
        \\// #endregion
        \\// #endregion
        \\# region py
        \\x = 1
        \\# endregion
        \\<!-- #region html -->
        \\<p></p>
        \\<!-- #endregion -->
        \\#pragma region cpp
        \\#pragma endregion
        \\// regional is not a marker
        \\// #endregion with no start
        \\
    ;
    var s = try parse(text, &c_like, true);
    defer s.deinit();
    try expectFolds(&s, &.{ .{ 0, 5, .region }, .{ 2, 4, .region }, .{ 6, 8, .region }, .{ 9, 11, .region }, .{ 12, 13, .region } });
    try testing.expectEqualStrings("region", structure.FoldKind.region.lspKind().?);
}

test "fallback: markdown heading outline golden" {
    const md =
        \\# Title
        \\
        \\Intro.
        \\
        \\## Install ##
        \\
        \\```sh
        \\# not a heading
        \\zig build
        \\```
        \\
        \\### From source
        \\Text.
        \\
        \\Usage
        \\-----
        \\
        \\Run it.
        \\
        \\Other
        \\=====
        \\#hashtag is not a heading
        \\
    ;
    var s = try parse(md, &markdown, false);
    defer s.deinit();
    try expectSymbols(&s, &.{
        .{ "Title", .heading, null },
        .{ "Install", .heading, 0 },
        .{ "From source", .heading, 1 },
        .{ "Usage", .heading, 0 },
        .{ "Other", .heading, null },
    });
    try expectFolds(&s, &.{
        .{ 0, 17, .block },
        .{ 4, 12, .block },
        .{ 6, 9, .block },
        .{ 11, 12, .block },
        .{ 14, 17, .block },
        .{ 19, 21, .block },
    });
    try testing.expectEqual(@as(u8, 15), s.symbols[0].kind.lspKind());
    // A section's range ends at its last non-blank line.
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, md, "Text.").? + 5)), s.symbols[2].range.end);
}
