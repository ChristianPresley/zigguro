//! YAML lexer tests: goldens, block scalar indentation and
//! incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const yaml = @import("yaml.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Mode = yaml.Mode;

const goldens = [_][]const u8{
    "mappings",      "sequences",     "comments",      "anchors",      "tags",      "plain_scalars",
    "double_quoted", "single_quoted", "block_literal", "block_folded", "documents", "flow",
    "workflow",
};

test "yaml: golden highlights" {
    try lt.expectGoldens(&yaml.yaml_language, "yaml", ".yaml", &goldens);
}

fn lex(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(yaml.yaml_language.lexer.lexLineFn, st, line);
}

/// Lexes `lines` in order and returns the highlight of each line's first
/// non-blank byte (`.none` for blank lines).
fn firstHls(lines: []const []const u8, out: []syntax.HighlightId) !void {
    var st = syntax.LexState.init(.yaml);
    for (lines, out) |line, *o| {
        var l = try lex(st, line);
        defer l.deinit();
        const i = std.mem.indexOfNone(u8, line, " ") orelse line.len;
        o.* = if (i < line.len) l.hlAt(i) else .none;
        st = l.state;
    }
}

test "yaml: block scalar indentation" {
    // `|`: content while deeper than the parent key; blank lines included.
    {
        const lines = [_][]const u8{ "key: |", "  line one", "", "    deeper", "  # not a comment", "next: 1" };
        var got: [lines.len]syntax.HighlightId = undefined;
        try firstHls(&lines, &got);
        try std.testing.expectEqualSlices(syntax.HighlightId, &.{ .property, .string, .none, .string, .string, .property }, &got);
    }
    // `>-` under a nested key: the parent indentation is the key's.
    {
        const lines = [_][]const u8{ "outer:", "  inner: >-", "    folded", "    text", "  sibling: x" };
        var got: [lines.len]syntax.HighlightId = undefined;
        try firstHls(&lines, &got);
        try std.testing.expectEqualSlices(syntax.HighlightId, &.{ .property, .property, .string, .string, .property }, &got);
    }
    // `|2+`: explicit content indentation 2 relative to the parent.
    {
        const lines = [_][]const u8{ "a: |2+", "   three spaces kept", "  two", " one: ends" };
        var got: [lines.len]syntax.HighlightId = undefined;
        try firstHls(&lines, &got);
        try std.testing.expectEqualSlices(syntax.HighlightId, &.{ .property, .string, .string, .property }, &got);
    }
    // The state records the parent indentation and the explicit indicator.
    var a = try lex(.init(.yaml), "  k: |+3 # keep");
    defer a.deinit();
    try std.testing.expectEqual(Mode.block_scalar, a.state.mode);
    try std.testing.expectEqual(@as(u16, 3), a.state.depth);
    try std.testing.expectEqualSlices(u8, &.{3}, a.state.auxBytes());
    try std.testing.expectEqual(syntax.HighlightId.comment, a.hlAt(9));
    // `|` followed by text is a plain scalar, not a block scalar.
    var b = try lex(.init(.yaml), "k: |x");
    defer b.deinit();
    try std.testing.expectEqual(Mode.normal, b.state.mode);
    // A sequence entry with a block scalar.
    var c = try lex(.init(.yaml), "- >");
    defer c.deinit();
    try std.testing.expectEqual(Mode.block_scalar, c.state.mode);
}

test "yaml: quoted scalars span lines" {
    var a = try lex(.init(.yaml), "k: \"first");
    defer a.deinit();
    try std.testing.expectEqual(Mode.double_quoted, a.state.mode);
    var b = try lex(a.state, "  second \\\" still\" # c");
    defer b.deinit();
    try std.testing.expectEqual(Mode.normal, b.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.comment, b.hlAt(19));
    var d = try lex(.init(.yaml), "k: 'it''s");
    defer d.deinit();
    try std.testing.expectEqual(Mode.single_quoted, d.state.mode);
}

const pieces = [_][]const u8{ "key", ": ", "- ", "|", ">-", "|2", "  ", "    ", "\"", "'", "#c", "&a", "*a", "!!str", "[", "]", "{", "}", ",", "---", "1.5", "true", "\t" };

test "yaml: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x7a);
    for (0..300) |_| try hl_test.checkIncremental(&yaml.yaml_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (yaml)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&yaml.yaml_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
