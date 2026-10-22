//! Rust lexer tests: goldens, the lifetime-vs-char table, nested comment
//! depth across edits, raw strings and incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const rust = @import("rust.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Mode = rust.Mode;

const goldens = [_][]const u8{
    "keywords",          "raw_strings", "byte_strings", "nested_comments", "doc_comments", "lifetimes",
    "chars",             "numbers",     "macros",       "attributes",      "raw_idents",   "shebang",
    "multiline_strings", "generics",
};

test "rust: golden highlights" {
    try lt.expectGoldens(&rust.rust_language, "rust", ".rs", &goldens);
}

fn lex(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(rust.rust_language.lexer.lexLineFn, st, line);
}

test "rust: lifetime vs char table" {
    const Case = struct { []const u8, rust.Quote, []const u8 };
    const cases = [_]Case{
        .{ "'a'", .char, "'a'" },
        .{ "'a", .lifetime, "'a" },
        .{ "'a,", .lifetime, "'a" },
        .{ "'a>", .lifetime, "'a" },
        .{ "'ab'", .lifetime, "'ab" },
        .{ "'static", .lifetime, "'static" },
        .{ "'static str", .lifetime, "'static" },
        .{ "'_", .lifetime, "'_" },
        .{ "'_'", .char, "'_'" },
        .{ "'\\n'", .char, "'\\n'" },
        .{ "'\\''", .char, "'\\''" },
        .{ "'\\\\'", .char, "'\\\\'" },
        .{ "'\\x7f'", .char, "'\\x7f'" },
        .{ "'\\u{1F600}'", .char, "'\\u{1F600}'" },
        .{ "'\\0'", .char, "'\\0'" },
        .{ "'é'", .char, "'é'" },
        .{ "'日'", .char, "'日'" },
        .{ "'é", .lifetime, "'é" },
        .{ "' '", .char, "' '" },
        .{ "'''", .char, "'''" },
        .{ "'\"'", .char, "'\"'" },
        .{ "'1'", .char, "'1'" },
        .{ "'1", .invalid, "'" },
        .{ "' x", .invalid, "'" },
        .{ "'", .invalid, "'" },
        .{ "'a'b", .char, "'a'" },
        .{ "'outer: loop", .lifetime, "'outer" },
        .{ "'r#fn", .lifetime, "'r#fn" },
        .{ "'r", .lifetime, "'r" },
        .{ "'r'", .char, "'r'" },
        .{ "'{'", .char, "'{'" },
        .{ "'a: {", .lifetime, "'a" },
        .{ "'abc_1 ", .lifetime, "'abc_1" },
        .{ "'\\", .char, "'\\" },
    };
    for (cases) |cs| {
        errdefer std.debug.print("case {s}\n", .{cs[0]});
        const q = rust.classifyQuote(cs[0], 0);
        try std.testing.expectEqual(cs[1], q[0]);
        try std.testing.expectEqualStrings(cs[2], cs[0][0..q[1]]);
        // The lexer agrees.
        var l = try lex(.init(.rust), cs[0]);
        defer l.deinit();
        const want: syntax.HighlightId = switch (cs[1]) {
            .char => .character,
            .lifetime => .label,
            .invalid => .invalid,
        };
        try std.testing.expectEqual(want, l.hlAt(0));
        if (cs[1] != .char) try std.testing.expectEqualStrings(cs[2], l.textAt(0));
    }
    // A byte char is a char.
    var b = try lex(.init(.rust), "b'a' b'\\''");
    defer b.deinit();
    try std.testing.expectEqual(syntax.HighlightId.character, b.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.character, b.hlAt(5));
}

test "rust: nested block comment depth survives edits" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    // Depth after each line of a nested comment.
    var a = try lex(.init(.rust), "x /* a /* b");
    defer a.deinit();
    try std.testing.expectEqual(Mode.block_comment, a.state.mode);
    try std.testing.expectEqual(@as(u16, 2), a.state.depth);
    var b = try lex(a.state, "*/ still");
    defer b.deinit();
    try std.testing.expectEqual(@as(u16, 1), b.state.depth);
    try std.testing.expectEqual(syntax.HighlightId.comment, b.hlAt(5));
    var d = try lex(b.state, "*/ let");
    defer d.deinit();
    try std.testing.expectEqual(Mode.code, d.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, d.hlAt(3));

    // Through the highlighter: opening another level on line 1 keeps the
    // tail commented until a second close; removing it uncomments again.
    var lines = [_][]const u8{ "/* a", "/* b */", "fn f() {}", "*/", "fn g() {}" };
    const view: []const []const u8 = &lines;
    var h: syntax.Highlighter = try .init(gpa, &rust.rust_language, &r);
    defer h.deinit();
    try h.reset(syntax.LineSource.fromSlice(&view));
    _ = try h.idle(syntax.LineSource.fromSlice(&view), null);
    try std.testing.expectEqual(syntax.HighlightId.comment, h.tokens(2)[0].hl);
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, h.tokens(4)[0].hl);
    lines[1] = "/* b /* c */";
    try h.onEdit(.{ .first = 1, .removed = 1, .inserted = 1 }, syntax.LineSource.fromSlice(&view), null);
    _ = try h.idle(syntax.LineSource.fromSlice(&view), null);
    try std.testing.expectEqual(syntax.HighlightId.comment, h.tokens(4)[0].hl);
    lines[1] = "/* b */";
    try h.onEdit(.{ .first = 1, .removed = 1, .inserted = 1 }, syntax.LineSource.fromSlice(&view), null);
    _ = try h.idle(syntax.LineSource.fromSlice(&view), null);
    try std.testing.expectEqual(syntax.HighlightId.keyword_storage, h.tokens(4)[0].hl);
}

test "rust: raw string hash count in aux" {
    var a = try lex(.init(.rust), "let s = r##\"a \"# b");
    defer a.deinit();
    try std.testing.expectEqual(Mode.raw_string, a.state.mode);
    try std.testing.expectEqualSlices(u8, &.{2}, a.state.auxBytes());
    var b = try lex(a.state, "c\"## + 1");
    defer b.deinit();
    try std.testing.expectEqual(Mode.code, b.state.mode);
    try std.testing.expectEqual(syntax.HighlightId.number, b.hlAt(7));
    // Ordinary strings span lines too.
    var d = try lex(.init(.rust), "let s = \"a");
    defer d.deinit();
    try std.testing.expectEqual(Mode.string, d.state.mode);
    // `r#ident` is not a raw string.
    var e = try lex(.init(.rust), "r#match + br\"x\"");
    defer e.deinit();
    try std.testing.expectEqual(Mode.code, e.state.mode);
    try std.testing.expectEqualStrings("r#match", e.textAt(0));
    try std.testing.expectEqual(syntax.HighlightId.string, e.hlAt(10));
}

const pieces = [_][]const u8{ "let ", "x", " = ", "\"s\\n", "\"", "r#\"", "\"#", "'a", "'b'", "/*", "*/", "// c", "/// d", "#[", "]", "m!", "(", ")", "{", "}", "1.0e3f32", "\t", "é", ";" };

test "rust: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x5257);
    for (0..200) |_| try hl_test.checkIncremental(&rust.rust_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (rust)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&rust.rust_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
