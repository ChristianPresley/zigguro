//! Go lexer tests: goldens, raw strings across lines, the automatic
//! semicolon table and incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const go = @import("go.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Mode = go.Mode;

const goldens = [_][]const u8{
    "keywords",    "builtins", "numbers",   "imaginary", "strings",   "runes",
    "raw_strings", "comments", "operators", "generics",  "functions", "structs",
    "channels",
};

test "go: golden highlights" {
    try lt.expectGoldens(&go.go_language, "go", ".go", &goldens);
}

fn lex(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(go.go_language.lexer.lexLineFn, st, line);
}

fn lexSemi(st: *syntax.LexState, s: *syntax.Scanner, out: *syntax.TokenSink) void {
    go.lexLineWith(.{ .virtual_semicolons = true }, st, s, out);
}

test "go: raw string spans lines" {
    var a = try lex(.init(.go), "q := `SELECT *");
    defer a.deinit();
    try std.testing.expectEqual(Mode.raw_string, a.state.mode);
    var b = try lex(a.state, "  FROM t // not a comment \\n");
    defer b.deinit();
    try std.testing.expectEqual(Mode.raw_string, b.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.string, b.hlAt(10));
    try std.testing.expectEqual(@as(usize, 1), b.sink.tokens().len);
    var d = try lex(b.state, "WHERE x`; n := 1");
    defer d.deinit();
    try std.testing.expectEqual(Mode.code, d.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.number, d.hlAt(15));
    // Interpreted strings do not span lines.
    var e = try lex(.init(.go), "s := \"open");
    defer e.deinit();
    try std.testing.expectEqual(Mode.code, e.state.mode);
}

test "go: virtual semicolon table" {
    const Case = struct { []const u8, bool };
    const cases = [_]Case{
        .{ "x := 1", true },
        .{ "foo()", true },
        .{ "a[i]", true },
        .{ "}", true },
        .{ "return", true },
        .{ "break", true },
        .{ "continue", true },
        .{ "fallthrough", true },
        .{ "i++", true },
        .{ "i--", true },
        .{ "s := \"str\"", true },
        .{ "r := 'x'", true },
        .{ "t := `raw`", true },
        .{ "f := 1.5i", true },
        .{ "x := y // comment", true },
        .{ "x := nil", true },
        .{ "var x int", true },
        .{ "func f() {", false },
        .{ "x := a +", false },
        .{ "if x {", false },
        .{ "foo(a,", false },
        .{ "x = y.", false },
        .{ "", false },
        .{ "// only a comment", false },
        .{ "x := `open raw", false },
        .{ "import (", false },
        .{ "go", false },
        .{ "x := y /* spans", true },
        .{ "x := y /* closed */", true },
        .{ "case 1:", false },
        .{ "ch <-", false },
        .{ "default:", false },
    };
    for (cases) |cs| {
        errdefer std.debug.print("case `{s}`\n", .{cs[0]});
        var l = try lt.lexWith(lexSemi, .init(.go), cs[0]);
        defer l.deinit();
        const toks = l.sink.tokens();
        const has = toks.len > 0 and toks[toks.len - 1].kind == go.Kind.virtual_semicolon;
        try std.testing.expectEqual(cs[1], has);
        if (has) try std.testing.expectEqual(@as(u32, @intCast(cs[0].len)), toks[toks.len - 1].start);
    }
    // After a raw string closes on a continuation line.
    var a = try lt.lexWith(lexSemi, .init(.go), "x := `a");
    defer a.deinit();
    var b = try lt.lexWith(lexSemi, a.state, "b`");
    defer b.deinit();
    try std.testing.expectEqual(go.Kind.virtual_semicolon, b.sink.tokens()[b.sink.tokens().len - 1].kind);
    // Highlighting never sees them.
    var h = try lex(.init(.go), "x := 1");
    defer h.deinit();
    for (h.sink.tokens()) |t| try std.testing.expect(t.kind != go.Kind.virtual_semicolon);
}

test "go: tabs by default" {
    try std.testing.expectEqual(@as(?bool, false), go.go_language.edit_rules.insert_spaces);
}

const pieces = [_][]const u8{ "x", " := ", "\"s\\n", "\"", "`", "raw", "'a'", "/*", "*/", "// c", "func ", "(", ")", "{", "}", "0x1p-2i", "\t", "é", ";", "len(" };

test "go: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x60);
    for (0..200) |_| try hl_test.checkIncremental(&go.go_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (go)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&go.go_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
