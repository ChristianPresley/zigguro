//! Parser tests: the valid-pattern golden, the error table, `x` mode, flag
//! scoping, class operator precedence, `escape` and the parse fuzzer.

const std = @import("std");
const zg_core = @import("zg_core");
const ast = @import("ast.zig");
const parse_mod = @import("parse.zig");
const errors = @import("errors.zig");

const testing = std.testing;

fn parseOk(arena: std.mem.Allocator, pattern: []const u8) !*ast.Ast {
    return switch (try parse_mod.parse(arena, pattern, .{})) {
        .ok => |a| a,
        .err => |e| {
            std.debug.print("unexpected error {s} at {d}..{d} for {s}\n", .{ @tagName(e.kind), e.span.start, e.span.end, pattern });
            return error.TestUnexpectedResult;
        },
    };
}

const valid_patterns = [_][]const u8{
    "",                    "a",                "abc",                  "a|b",
    "a|b|c",               "|",                "a|",                   "|a",
    "ab|cd",               "(a)",              "(a)(b)",               "((a))",
    "(?:a)",               "(?:a|b)c",         "(?P<name>a)",          "(?<name>a)",
    "(?P<a1_b.c[0]>x)",    "(?i)a",            "(?i:a)b",              "(?-i:a)",
    "(?im-sx:a)",          "(?ims)",           "(?U)a*",               "(?u)a",
    "(?R)^$",              "(?x) a b # c\n d", "(?x)a\\ b",            "(?x)\\#",
    ".",                   "^",                "$",                    "\\A",
    "\\z",                 "\\b",              "\\B",                  "\\b{start}",
    "\\b{end}",            "\\b{start-half}",  "\\b{end-half}",        "\\<",
    "\\>",                 "\\b{2}",           "a*",                   "a+",
    "a?",                  "a*?",              "a+?",                  "a??",
    "a{2}",                "a{2,}",            "a{2,5}",               "a{,5}",
    "a{2}?",               "a{0}",             "a{1000}",              "a**",
    "(ab)*",               "(?:ab)+",          "^a*$",                 "(?x)a{ 2 , 3 }",
    "\\d",                 "\\D",              "\\s",                  "\\S",
    "\\w",                 "\\W",              "\\pL",                 "\\PL",
    "\\p{L}",              "\\p{Greek}",       "\\p{Script=Greek}",    "\\p{sc=Grek}",
    "\\p{sc:Grek}",        "\\p{gc=Lu}",       "\\p{^Greek}",          "\\P{^Greek}",
    "\\p{sc!=Grek}",       "\\p{Alphabetic}",  "\\p{ Greek }",         "\\pN",
    "\\x7F",               "\\x{10FFFF}",      "\\x{0}",               "\\u0041",
    "\\u{41}",             "\\U00000041",      "\\U{1F600}",           "\\n\\t\\r\\f\\v\\a",
    "\\0",                 "\\.",              "\\*",                  "\\\\",
    "\\-",                 "\\~",              "\\&",                  "\\#",
    "\\ ",                 "\\{",              "\\}",                  "\\[",
    "\\]",                 "\\(",              "\\)",                  "\\|",
    "\\^",                 "\\$",              "\\?",                  "\\+",
    "[a]",                 "[abc]",            "[a-z]",                "[a-zA-Z0-9_]",
    "[^a]",                "[^a-z]",           "[]]",                  "[]a]",
    "[^]]",                "[-a]",             "[a-]",                 "[a\\-z]",
    "[\\d]",               "[\\D\\s]",         "[\\pL]",               "[\\p{Greek}\\d]",
    "[[:alpha:]]",         "[[:^alpha:]]",     "[[:alnum:][:punct:]]", "[x[:digit:]y]",
    "[[a-z]]",             "[a[bc]d]",         "[[^a]]",               "[a&&b]",
    "[a--b]",              "[a~~b]",           "[a-z&&[^aeiou]]",      "[\\w--\\d]",
    "[a&&b--c]",           "[a--b&&c]",        "[a~~b--c&&d]",         "[[a&&b]--c]",
    "[\\x00-\\x{10FFFF}]", "[\\n]",            "[.]",                  "[*+?]",
    "[(]",                 "[|]",              "[{}]",                 "[$^]",
    "[a&b]",               "[a~b]",            "[&]",                  "[~]",
    "[\\[\\]]",            "[\\^a]",           "[[:]]",                "[[:foo:]]",
    "é",
    "日本語",
    "[α-ω]",
    "😀+",
    "(?i)[a-z]",           "a(?i)b|c",         "(?i)(?-i)a",           "(a(b(c)))",
    "(?P<x>a)|(?P<y>b)",   "a|(b|c)|d",        "((a|b)*c)+",           "(?s).",
    "(?m)^a$",             "(?-u)\\xFF",       "\\b\\w+\\b",           "[\\p{L}--\\p{Lu}]",
};

test "parse: table of valid patterns -> AST dump golden" {
    try testing.expect(valid_patterns.len >= 150);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (valid_patterns) |p| {
        const a = try parseOk(arena, p);
        try out.writer.print("pattern: {f}\n", .{std.zig.fmtString(p)});
        try ast.dump(a, &out.writer);
        try out.writer.writeByte('\n');
    }
    try zg_core.testkit.golden.expectGoldenOpts(testing.io, @src(), "valid", out.written(), .{ .root = @import("zg_options").package_root });
}

test "parse: printing re-parses to an equivalent AST" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (valid_patterns) |p| {
        const a = try parseOk(arena, p);
        var out: std.Io.Writer.Allocating = .init(arena);
        try ast.print(a, &out.writer);
        // x-mode patterns print without the comments and whitespace, which is
        // still equivalent.
        const b = try parseOk(arena, out.written());
        if (!ast.eql(a, b)) {
            std.debug.print("print mismatch: {s} -> {s}\n", .{ p, out.written() });
            return error.TestUnexpectedResult;
        }
    }
}

const ErrCase = struct { pattern: []const u8, kind: errors.ErrorKind, start: u32, end: u32 };

const error_cases = [_]ErrCase{
    .{ .pattern = "(a)\\1", .kind = .unsupported_backreference, .start = 3, .end = 5 },
    .{ .pattern = "(?P=n)", .kind = .unsupported_backreference, .start = 0, .end = 4 },
    .{ .pattern = "\\k<n>", .kind = .unsupported_backreference, .start = 0, .end = 2 },
    .{ .pattern = "a(?=b)", .kind = .unsupported_lookaround, .start = 1, .end = 4 },
    .{ .pattern = "a(?!b)", .kind = .unsupported_lookaround, .start = 1, .end = 4 },
    .{ .pattern = "(?<=a)b", .kind = .unsupported_lookaround, .start = 0, .end = 4 },
    .{ .pattern = "(?<!a)b", .kind = .unsupported_lookaround, .start = 0, .end = 4 },
    .{ .pattern = "\\G", .kind = .unsupported_backslash_g, .start = 0, .end = 2 },
    .{ .pattern = "a*+", .kind = .unsupported_possessive, .start = 2, .end = 3 },
    .{ .pattern = "a{2}+", .kind = .unsupported_possessive, .start = 4, .end = 5 },
    .{ .pattern = "(?>a)", .kind = .unsupported_atomic, .start = 0, .end = 3 },
    .{ .pattern = "\\07", .kind = .unsupported_octal, .start = 0, .end = 3 },
    .{ .pattern = "a{1001}", .kind = .repetition_count_too_large, .start = 1, .end = 7 },
    .{ .pattern = "a{1,1001}", .kind = .repetition_count_too_large, .start = 1, .end = 9 },
    .{ .pattern = "a{", .kind = .repetition_count_invalid, .start = 1, .end = 2 },
    .{ .pattern = "a{x}", .kind = .repetition_count_invalid, .start = 1, .end = 3 },
    .{ .pattern = "a{3,2}", .kind = .repetition_count_invalid, .start = 1, .end = 6 },
    .{ .pattern = "a{,}", .kind = .repetition_count_invalid, .start = 1, .end = 4 },
    .{ .pattern = "*", .kind = .repetition_missing, .start = 0, .end = 1 },
    .{ .pattern = "a|*", .kind = .repetition_missing, .start = 2, .end = 3 },
    .{ .pattern = "(?i)*", .kind = .repetition_missing, .start = 4, .end = 5 },
    .{ .pattern = "{2}", .kind = .repetition_missing, .start = 0, .end = 1 },
    .{ .pattern = "[a", .kind = .class_unclosed, .start = 0, .end = 1 },
    .{ .pattern = "[]", .kind = .class_unclosed, .start = 0, .end = 1 },
    .{ .pattern = "a[b[c]", .kind = .class_unclosed, .start = 1, .end = 2 },
    .{ .pattern = "[z-a]", .kind = .class_range_invalid, .start = 1, .end = 4 },
    .{ .pattern = "[a-\\d]", .kind = .class_range_invalid, .start = 1, .end = 5 },
    .{ .pattern = "[a&&]", .kind = .class_empty, .start = 4, .end = 4 },
    .{ .pattern = "(a", .kind = .group_unclosed, .start = 0, .end = 1 },
    .{ .pattern = "(?:a", .kind = .group_unclosed, .start = 0, .end = 3 },
    .{ .pattern = "a)", .kind = .group_unopened, .start = 1, .end = 2 },
    .{ .pattern = "(?P<n>a)(?P<n>b)", .kind = .group_name_duplicate, .start = 12, .end = 13 },
    .{ .pattern = "(?P<1a>x)", .kind = .group_name_invalid, .start = 4, .end = 6 },
    .{ .pattern = "(?P<>x)", .kind = .group_name_invalid, .start = 0, .end = 5 },
    .{ .pattern = "\\q", .kind = .escape_invalid, .start = 0, .end = 2 },
    .{ .pattern = "[\\b]", .kind = .escape_invalid, .start = 1, .end = 3 },
    .{ .pattern = "\\", .kind = .escape_unexpected_eof, .start = 0, .end = 1 },
    .{ .pattern = "\\xZZ", .kind = .escape_hex_invalid, .start = 0, .end = 3 },
    .{ .pattern = "\\x{110000}", .kind = .escape_hex_invalid, .start = 0, .end = 10 },
    .{ .pattern = "\\x{D800}", .kind = .escape_hex_invalid, .start = 0, .end = 8 },
    .{ .pattern = "\\p{}", .kind = .unicode_property_unknown, .start = 0, .end = 4 },
    .{ .pattern = "(?q)", .kind = .flag_unknown, .start = 2, .end = 3 },
    .{ .pattern = "(?)", .kind = .flag_unknown, .start = 2, .end = 3 },
    .{ .pattern = "(?ii)", .kind = .flag_duplicate, .start = 3, .end = 4 },
    .{ .pattern = "(?i-)", .kind = .flag_dangling, .start = 3, .end = 4 },
    .{ .pattern = "\xff", .kind = .pattern_invalid_utf8, .start = 0, .end = 1 },
};

test "parse: every parse ErrorKind has a triggering example with expected span" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (error_cases) |c| {
        switch (try parse_mod.parse(arena, c.pattern, .{})) {
            .ok => {
                std.debug.print("expected {s} for {s}\n", .{ @tagName(c.kind), c.pattern });
                return error.TestUnexpectedResult;
            },
            .err => |e| {
                if (e.kind != c.kind or e.span.start != c.start or e.span.end != c.end) {
                    std.debug.print("{s}: want {s} {d}..{d}, got {s} {d}..{d}\n", .{ c.pattern, @tagName(c.kind), c.start, c.end, @tagName(e.kind), e.span.start, e.span.end });
                    return error.TestUnexpectedResult;
                }
            },
        }
    }
    // Kinds only produced at translation or compile time, or by limits.
    const later = [_]errors.ErrorKind{ .unicode_not_allowed, .invalid_utf8, .size_limit_exceeded, .nest_limit_exceeded, .pattern_too_long };
    inline for (std.meta.fields(errors.ErrorKind)) |f| {
        const k: errors.ErrorKind = @enumFromInt(f.value);
        const covered = for (error_cases) |c| {
            if (c.kind == k) break true;
        } else std.mem.indexOfScalar(errors.ErrorKind, &later, k) != null or k == .unicode_property_unknown;
        try testing.expect(covered);
    }
}

test "parse: nest limit and pattern length" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = "(" ** 300 ++ ")" ** 300;
    try testing.expectEqual(errors.ErrorKind.nest_limit_exceeded, (try parse_mod.parse(arena, deep, .{})).err.kind);
    const reps = "a" ++ "*" ** 300;
    try testing.expectEqual(errors.ErrorKind.nest_limit_exceeded, (try parse_mod.parse(arena, reps, .{})).err.kind);
    const classes = "[" ** 300 ++ "a" ++ "]" ** 300;
    try testing.expectEqual(errors.ErrorKind.nest_limit_exceeded, (try parse_mod.parse(arena, classes, .{})).err.kind);
    _ = try parseOk(arena, "(" ** 250 ++ ")" ** 250);
    // Hostile nesting far beyond the limit never touches the thread stack.
    const huge = try arena.alloc(u8, 200_000);
    @memset(huge, '(');
    try testing.expectEqual(errors.ErrorKind.nest_limit_exceeded, (try parse_mod.parse(arena, huge, .{})).err.kind);
    const too_long = try arena.alloc(u8, parse_mod.max_pattern_len + 1);
    @memset(too_long, 'a');
    try testing.expectEqual(errors.ErrorKind.pattern_too_long, (try parse_mod.parse(arena, too_long, .{})).err.kind);
}

test "parse: x-mode" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try parseOk(arena, "(?x) a b # comment\n c *");
    // flags, a, b, c* => concat of 4
    try testing.expectEqual(@as(usize, 4), a.concat.items.len);
    try testing.expect(a.concat.items[3].* == .repetition);
    // Escaped space and hash are literals.
    const b = try parseOk(arena, "(?x)\\ \\#");
    try testing.expectEqual(@as(u21, ' '), b.concat.items[1].literal.cp);
    try testing.expectEqual(@as(u21, '#'), b.concat.items[2].literal.cp);
    // Whitespace is significant inside classes.
    const c = try parseOk(arena, "(?x)[ a]");
    try testing.expectEqual(@as(usize, 2), c.concat.items[1].class_bracketed.set.item.union_.items.len);
    // Scoped: x ends with its group.
    const d = try parseOk(arena, "(?x: a )b c");
    try testing.expectEqual(@as(usize, 4), d.concat.items.len);
    // Option starts in x mode.
    const e = switch (try parse_mod.parse(arena, " a ", .{ .ignore_whitespace = true })) {
        .ok => |x| x,
        .err => return error.TestUnexpectedResult,
    };
    try testing.expect(e.* == .literal);
}

test "parse: scoped flags restore" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `(?x)` inside a group ends at the group's close.
    const a = try parseOk(arena, "((?x) a ) b");
    try testing.expectEqual(@as(usize, 3), a.concat.items.len); // group, ' ', 'b'
    const g = a.concat.items[0].group;
    try testing.expectEqual(@as(usize, 2), g.sub.concat.items.len); // flags, a
    const b = try parseOk(arena, "(?i:a)b");
    try testing.expect(b.concat.items[0].group.kind.non_capture.set.case_insensitive);
}

test "parse: class set operator precedence" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // a~~b--c&&d == a ~~ (b -- (c && d))
    const a = try parseOk(arena, "[a~~b--c&&d]");
    const top = a.class_bracketed.set.binary;
    try testing.expectEqual(ast.SetOp.symmetric_difference, top.op);
    try testing.expectEqual(ast.SetOp.difference, top.rhs.binary.op);
    try testing.expectEqual(ast.SetOp.intersection, top.rhs.binary.rhs.binary.op);
    // Left-associative: a--b--c == (a--b)--c
    const b = try parseOk(arena, "[a--b--c]");
    try testing.expect(b.class_bracketed.set.binary.lhs.* == .binary);
    // Union binds tighter: ab&&bc == [ab]&&[bc]
    const c = try parseOk(arena, "[ab&&bc]");
    try testing.expect(c.class_bracketed.set.binary.lhs.item == .union_);
}

test "escape: escaped literal re-parses to the same literal" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lits = [_][]const u8{ "a.b*c", "\\(x)|[y]{z}^$", "#-&~ ", "日本+?" };
    for (lits) |lit| {
        var out: std.ArrayList(u8) = .empty;
        try parse_mod.escape(&out, arena, lit);
        const a = try parseOk(arena, out.items);
        var cps: std.ArrayList(u21) = .empty;
        switch (a.*) {
            .literal => |l| try cps.append(arena, l.cp),
            .concat => |c| for (c.items) |it| try cps.append(arena, it.literal.cp),
            else => return error.TestUnexpectedResult,
        }
        var view = (try std.unicode.Utf8View.init(lit)).iterator();
        var i: usize = 0;
        while (view.nextCodepoint()) |cp| : (i += 1) try testing.expectEqual(cp, cps.items[i]);
        try testing.expectEqual(cps.items.len, i);
    }
}

test "fuzz: regex parse" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [96]u8 = undefined;
            const n = s.slice(&buf);
            // Bias towards regex syntax: map bytes onto a meta-heavy alphabet.
            const alphabet = "ab()[]{}|*+?^$.\\-&~:,0129dDwWpPxu<>=!#iImsUxR ";
            for (buf[0..n]) |*c| c.* = if (c.* & 0x80 != 0) c.* & 0x7F else alphabet[c.* % alphabet.len];
            const pattern = buf[0..n];
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            switch (try parse_mod.parse(arena, pattern, .{})) {
                .err => |e| {
                    try testing.expect(e.span.start <= e.span.end and e.span.end <= pattern.len);
                    _ = errors.errorMessage(e);
                },
                .ok => |a| {
                    const sp = a.span();
                    try testing.expect(sp.end <= pattern.len);
                    var out: std.Io.Writer.Allocating = .init(arena);
                    try ast.print(a, &out.writer);
                    switch (try parse_mod.parse(arena, out.written(), .{})) {
                        .ok => |b| try testing.expect(ast.eql(a, b)),
                        .err => |e| {
                            std.debug.print("reprint of {s} = {s} fails: {s}\n", .{ pattern, out.written(), @tagName(e.kind) });
                            return error.TestUnexpectedResult;
                        },
                    }
                },
            }
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "parse") });
}
