//! Python lexer tests: goldens, the f-string nesting table, tier-2
//! NEWLINE/INDENT/DEDENT tokens and incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const python = @import("python.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Kind = python.Kind;

const goldens = [_][]const u8{
    "keywords", "strings",      "triple_strings", "prefixes",  "fstrings", "fstring_nesting",
    "numbers",  "decorators",   "soft_keywords",  "operators", "comments", "classes",
    "escapes",  "line_joining",
};

test "python: golden highlights" {
    try lt.expectGoldens(&python.python_language, "python", ".py", &goldens);
}

fn lex(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(python.python_language.lexer.lexLineFn, st, line);
}

fn frames(st: *const syntax.LexState) u16 {
    return st.mode & 0xff;
}

test "python: f-string nesting table" {
    // Each case: a line, the open frames at its end, a part that must be
    // code (not string) and a part that must be string text.
    const Case = struct { []const u8, u16, ?[]const u8, ?[]const u8 };
    const cases = [_]Case{
        .{ "f\"{x}\"", 0, "x", null },
        .{ "f\"a {x} b\"", 0, "x", " b" },
        .{ "f\"{{x}}\"", 0, null, null },
        .{ "f\"{{{x}}}\"", 0, "x", null },
        .{ "f\"{x[\"k\"]}\"", 0, "x", null },
        .{ "f\"{x['k']}\"", 0, "x", null },
        .{ "f\"{f\"{y}\"}\"", 0, "y", null },
        .{ "f\"{f\"{f\"{z}\"}\"}\"", 0, "z", null },
        .{ "f'{a!r}'", 0, "a", null },
        .{ "f'{a:>10}'", 0, "a", ">10" },
        .{ "f'{a:{w}.{p}f}'", 0, "w", ".{p}f" },
        .{ "f'{a:{w}}' + b", 0, "b", null },
        .{ "f'{x=}'", 0, "x", null },
        .{ "f'{x:=5}'", 0, "x", null },
        .{ "f'{d[\"a\"]:x}' c", 0, "c", null },
        .{ "f\"\"\"{x}", 1, "x", null },
        .{ "f\"\"\"text", 1, null, "text" },
        .{ "f'{x", 1, "x", null },
        .{ "f'{(x,", 1, "x", null },
        .{ "f'unterminated", 0, null, "unterminated" },
        .{ "rf'{x}\\d'", 0, "x", "\\d" },
        .{ "fr\"{x}\"", 0, "x", null },
        .{ "F'{x}'", 0, "x", null },
        .{ "t'{x}'", 0, "x", null },
        .{ "'{x}' + y", 0, "y", "{x}" },
        .{ "b'{x}'", 0, null, "{x}" },
        .{ "f'{\"}\"}' z", 0, "z", null },
        .{ "f'{lambda: 1}'", 0, "lambda", null },
        .{ "f'a\\N{DASH}b{c}'", 0, "c", null },
        .{ "f'{x:{y:{z}}}' w", 0, "w", null },
    };
    for (cases) |cs| {
        errdefer std.debug.print("case {s}\n", .{cs[0]});
        var l = try lex(.init(.python), cs[0]);
        defer l.deinit();
        try std.testing.expectEqual(cs[1], frames(&l.state));
        if (cs[2]) |code| {
            const at = std.mem.lastIndexOf(u8, cs[0], code).?;
            try std.testing.expect(l.hlAt(at) != .string);
        }
        if (cs[3]) |text| {
            const at = std.mem.lastIndexOf(u8, cs[0], text).?;
            const hl = l.hlAt(at);
            try std.testing.expect(hl == .string or hl == .string_escape);
        }
    }
    // A triple-quoted f-string continues as text, and a field opened on a
    // later line closes properly.
    var a = try lex(.init(.python), "s = f\"\"\"start");
    defer a.deinit();
    var b = try lex(a.state, "  {value!r:>{w}} more");
    defer b.deinit();
    try std.testing.expectEqual(@as(u16, 1), frames(&b.state));
    try std.testing.expectEqual(syntax.HighlightId.variable, b.hlAt(3));
    try std.testing.expectEqual(syntax.HighlightId.string, b.hlAt(18));
    var d = try lex(b.state, "end\"\"\" + x");
    defer d.deinit();
    try std.testing.expectEqual(@as(u16, 0), frames(&d.state));
    try std.testing.expectEqual(syntax.HighlightId.variable, d.hlAt(9));
}

fn lexTier2(st: *syntax.LexState, s: *syntax.Scanner, out: *syntax.TokenSink) void {
    python.lexLineWith(.{ .virtual_tokens = true }, st, s, out);
}

/// Tier-2 events of one line: INDENT, the DEDENT count and NEWLINE.
const Events = struct { indent: bool, dedents: u16, newline: bool };

fn events(l: *const lt.Lexed) Events {
    var e: Events = .{ .indent = false, .dedents = 0, .newline = false };
    for (l.sink.tokens()) |t| {
        if (t.kind == Kind.newline) e.newline = true;
        if (t.kind & Kind.indent_flag != 0 and t.kind != Kind.newline) e.indent = true;
        if (t.kind & Kind.dedent_mask != 0 and t.kind & syntax.Token.atomic_bit != 0) e.dedents = (t.kind & Kind.dedent_mask) >> Kind.dedent_shift;
    }
    return e;
}

test "python: indent/dedent virtual tokens table" {
    const lines = [_][]const u8{
        "def f(x):", //          0
        "    if x:", //          1
        "        return (1,", // 2
        "  2)", //               3 inside brackets: no INDENT
        "", //                   4 blank: nothing
        "    # comment", //      5 comment only: nothing
        "    y = \\", //         6 explicit join
        "        3", //          7 joined: no INDENT
        "    s = '''a", //       8 triple string opens
        "b'''", //               9 closes, NEWLINE
        "class C:", //           10 DEDENT x1
        "\tpass", //             11 INDENT (tab = 8)
        "x = 1", //              12 DEDENT x1
    };
    const want = [_]Events{
        .{ .indent = false, .dedents = 0, .newline = true },
        .{ .indent = true, .dedents = 0, .newline = true },
        .{ .indent = true, .dedents = 0, .newline = false },
        .{ .indent = false, .dedents = 0, .newline = true },
        .{ .indent = false, .dedents = 0, .newline = false },
        .{ .indent = false, .dedents = 0, .newline = false },
        .{ .indent = false, .dedents = 1, .newline = false },
        .{ .indent = false, .dedents = 0, .newline = true },
        .{ .indent = false, .dedents = 0, .newline = false },
        .{ .indent = false, .dedents = 0, .newline = true },
        .{ .indent = false, .dedents = 1, .newline = true },
        .{ .indent = true, .dedents = 0, .newline = true },
        .{ .indent = false, .dedents = 1, .newline = true },
    };
    var st = syntax.LexState.init(.python);
    for (lines, want, 0..) |line, w, i| {
        errdefer std.debug.print("line {d}: {s}\n", .{ i, line });
        var l = try lt.lexWith(lexTier2, st, line);
        defer l.deinit();
        const e = events(&l);
        try std.testing.expectEqual(w.indent, e.indent);
        try std.testing.expectEqual(w.dedents, e.dedents);
        try std.testing.expectEqual(w.newline, e.newline);
        st = l.state;
    }
    // Two levels closed at once.
    var a = try lt.lexWith(lexTier2, .init(.python), "if a:");
    defer a.deinit();
    var b = try lt.lexWith(lexTier2, a.state, "  if b:");
    defer b.deinit();
    var c = try lt.lexWith(lexTier2, b.state, "    c");
    defer c.deinit();
    var d = try lt.lexWith(lexTier2, c.state, "d");
    defer d.deinit();
    try std.testing.expectEqual(@as(u16, 2), events(&d).dedents);
    // Highlighting is unaffected.
    var h = try lex(.init(.python), "    x = 1");
    defer h.deinit();
    for (h.sink.tokens()) |t| try std.testing.expect(t.kind & (Kind.indent_flag | Kind.dedent_mask) == 0 or t.kind == Kind.newline);
}

const pieces = [_][]const u8{ "x", " = ", "f\"", "\"", "'''", "\"\"\"", "{", "}", "{{", ":>", "#c", "\\", "def ", "(", ")", "@d", "1.5j", "\t", "é", "rb'", "\\n" };

test "python: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x9e);
    for (0..300) |_| try hl_test.checkIncremental(&python.python_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (python)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&python.python_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
