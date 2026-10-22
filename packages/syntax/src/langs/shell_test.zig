//! Shell lexer tests: goldens, here-document variants, nested expansion
//! states and incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const shell = @import("shell.zig");
const lt = @import("lang_testing.zig");
const hl_test = @import("../highlight/highlighter_test.zig");

const gpa = std.testing.allocator;
const Ctx = shell.Ctx;
const Bits = shell.Bits;

const goldens = [_][]const u8{
    "commands", "keywords",  "variables", "quotes",   "substitution", "arithmetic",
    "heredocs", "functions", "redirects", "comments", "case",         "pkgbuild",
};

test "shell: golden highlights" {
    try lt.expectGoldens(&shell.shell_language, "shell", ".sh", &goldens);
}

fn lex(st: syntax.LexState, line: []const u8) !lt.Lexed {
    return lt.lexWith(shell.shell_language.lexer.lexLineFn, st, line);
}

/// The highlight of each line's first non-blank byte (`.none` for blank
/// lines) and the final state.
fn firstHls(lines: []const []const u8, out: []syntax.HighlightId) !syntax.LexState {
    var st = syntax.LexState.init(.shell);
    for (lines, out) |line, *o| {
        var l = try lex(st, line);
        defer l.deinit();
        const i = std.mem.indexOfNone(u8, line, " \t") orelse line.len;
        o.* = if (i < line.len) l.hlAt(i) else .none;
        st = l.state;
    }
    return st;
}

test "shell: heredoc variants table" {
    const S = syntax.HighlightId;
    const Case = struct { lines: []const []const u8, want: []const S };
    const cases = [_]Case{
        // Unquoted: expansions in the body.
        .{ .lines = &.{ "cat <<EOF", "$name text", "EOF", "echo" }, .want = &.{ .function, .variable, .label, .function_builtin } },
        // `<<-` strips leading tabs from the end line.
        .{ .lines = &.{ "cat <<-EOF", "\tbody", "\tEOF", "echo" }, .want = &.{ .function, .string, .label, .function_builtin } },
        // `<<-` does not strip spaces.
        .{ .lines = &.{ "cat <<-EOF", "  EOF", "EOF", "echo" }, .want = &.{ .function, .string, .label, .function_builtin } },
        // Quoted delimiters: no expansions.
        .{ .lines = &.{ "cat <<'EOF'", "$name", "EOF" }, .want = &.{ .function, .string, .label } },
        .{ .lines = &.{ "cat <<\"EOF\"", "$name", "EOF" }, .want = &.{ .function, .string, .label } },
        .{ .lines = &.{ "cat <<\\EOF", "$name", "EOF" }, .want = &.{ .function, .string, .label } },
        // A space before the word.
        .{ .lines = &.{ "cat << END", "x", "END" }, .want = &.{ .function, .string, .label } },
        // Two here-documents run one after the other.
        .{ .lines = &.{ "cmd <<A <<'B'", "a", "A", "$b", "B", "fi" }, .want = &.{ .function, .string, .label, .string, .label, .keyword_control } },
        // Without `-`, an indented delimiter is body text.
        .{ .lines = &.{ "cat <<EOF", "  EOF", "EOF" }, .want = &.{ .function, .string, .label } },
        // A here-string queues nothing.
        .{ .lines = &.{ "cat <<< \"x\"", "echo" }, .want = &.{ .function, .function_builtin } },
        // A pipeline after the operator; the body starts on the next line.
        .{ .lines = &.{ "cat <<EOF | grep x", "body", "EOF" }, .want = &.{ .function, .string, .label } },
        // Inside `$( )`: the stack resumes after the body.
        .{ .lines = &.{ "x=$(cat <<EOF", "body", "EOF", ")" }, .want = &.{ .variable, .string, .label, .punctuation_bracket } },
        // A CRLF end line.
        .{ .lines = &.{ "cat <<EOF\r", "body\r", "EOF\r", "echo" }, .want = &.{ .function, .string, .label, .function_builtin } },
    };
    for (cases, 0..) |cs, k| {
        errdefer std.debug.print("case {d}\n", .{k});
        var got: [8]S = undefined;
        const st = try firstHls(cs.lines, got[0..cs.lines.len]);
        try std.testing.expectEqualSlices(S, cs.want, got[0..cs.lines.len]);
        try std.testing.expectEqual(@as(u16, 0), st.mode);
        try std.testing.expectEqual(@as(usize, 0), st.auxBytes().len);
    }
    // The queued state: two here-documents, then the body bit.
    var a = try lex(.init(.shell), "cmd <<-A <<'BB'");
    defer a.deinit();
    try std.testing.expectEqual(@as(u16, 2 << Bits.heredoc_shift) | Bits.in_body, a.state.mode);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 'A', 0x42, 'B', 'B' }, a.state.auxBytes());
}

/// The context stack at the end of `line`.
fn stackAfter(st: syntax.LexState, line: []const u8) !struct { syntax.LexState, [8]u8, usize } {
    var l = try lex(st, line);
    defer l.deinit();
    var out: [8]u8 = @splat(0);
    const n = l.state.mode & Bits.depth_mask;
    @memcpy(out[0..n], l.state.auxBytes()[0..n]);
    return .{ l.state, out, n };
}

fn expectStack(st: syntax.LexState, line: []const u8, want: []const u8) !syntax.LexState {
    errdefer std.debug.print("line {s}\n", .{line});
    const r = try stackAfter(st, line);
    try std.testing.expectEqualSlices(u8, want, r[1][0..r[2]]);
    return r[0];
}

test "shell: nested $( \"${x}\" ) states" {
    const init: syntax.LexState = .init(.shell);
    _ = try expectStack(init, "echo $(", &.{Ctx.cmdsubst});
    _ = try expectStack(init, "echo $( \"", &.{ Ctx.cmdsubst, Ctx.dquote });
    _ = try expectStack(init, "echo $( \"${x", &.{ Ctx.cmdsubst, Ctx.dquote, Ctx.param });
    _ = try expectStack(init, "echo $( \"${x}", &.{ Ctx.cmdsubst, Ctx.dquote });
    _ = try expectStack(init, "echo $( \"${x}\"", &.{Ctx.cmdsubst});
    _ = try expectStack(init, "echo $( \"${x}\" )", &.{});
    _ = try expectStack(init, "echo \"$(f '", &.{ Ctx.dquote, Ctx.cmdsubst, Ctx.squote });
    _ = try expectStack(init, "echo ${a:-\"$(b", &.{ Ctx.param, Ctx.dquote, Ctx.cmdsubst });
    _ = try expectStack(init, "echo $(( 1 + $(f", &.{ Ctx.arith, Ctx.cmdsubst });
    _ = try expectStack(init, "echo $(( (1 + 2) * 3 ))", &.{});
    _ = try expectStack(init, "echo `date \"", &.{ Ctx.backtick, Ctx.dquote });
    _ = try expectStack(init, "echo \"`date`\" $'a\\'", &.{Ctx.ansi});
    _ = try expectStack(init, "arr=(a \"b", &.{ Ctx.array, Ctx.dquote });
    _ = try expectStack(init, "diff <(sort a", &.{Ctx.cmdsubst});
    // Across lines.
    var st = try expectStack(init, "x=$(", &.{Ctx.cmdsubst});
    st = try expectStack(st, "  echo \"a", &.{ Ctx.cmdsubst, Ctx.dquote });
    st = try expectStack(st, "b ${c}\" )", &.{});
    // Code inside a substitution starts at command position.
    var l = try lex(.init(.shell), "v=\"$(ls -l)\"");
    defer l.deinit();
    try std.testing.expectEqual(syntax.HighlightId.variable, l.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.function, l.hlAt(5));
    try std.testing.expectEqual(syntax.HighlightId.string, l.hlAt(11));
}

test "shell: command position, comments and continuations" {
    var a = try lex(.init(.shell), "if true; then echo a#b # c; fi");
    defer a.deinit();
    try std.testing.expectEqual(syntax.HighlightId.keyword_control, a.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.function_builtin, a.hlAt(3));
    try std.testing.expectEqual(syntax.HighlightId.keyword_control, a.hlAt(9));
    try std.testing.expectEqual(syntax.HighlightId.function_builtin, a.hlAt(14));
    try std.testing.expectEqual(syntax.HighlightId.none, a.hlAt(20));
    try std.testing.expectEqual(syntax.HighlightId.comment, a.hlAt(23));
    var b = try lex(.init(.shell), "FOO=1 BAR+=x make -j 4 && for i in 1 2; do :; done");
    defer b.deinit();
    try std.testing.expectEqual(syntax.HighlightId.variable, b.hlAt(0));
    try std.testing.expectEqual(syntax.HighlightId.variable, b.hlAt(6));
    try std.testing.expectEqual(syntax.HighlightId.function, b.hlAt(13));
    try std.testing.expectEqual(syntax.HighlightId.number, b.hlAt(21));
    try std.testing.expectEqual(syntax.HighlightId.keyword_control, b.hlAt(26));
    try std.testing.expectEqual(syntax.HighlightId.variable, b.hlAt(30));
    try std.testing.expectEqual(syntax.HighlightId.keyword_control, b.hlAt(32));
    // A trailing backslash: the next line continues the arguments.
    var c = try lex(.init(.shell), "make \\");
    defer c.deinit();
    try std.testing.expect(c.state.mode & Bits.continued != 0);
    var d = try lex(c.state, "  install");
    defer d.deinit();
    try std.testing.expectEqual(syntax.HighlightId.none, d.hlAt(2));
    try std.testing.expectEqual(@as(u16, 0), d.state.mode);
}

const pieces = [_][]const u8{ "echo ", "x", "$y", "${", "}", "$(", "$((", "))", ")", "(", "\"", "'", "`", "\\", "<<EOF", "<<-E", "EOF", "\tE", "E", "#c", "; ", "| ", "if ", "fi", "=", "\t", "é" };

test "shell: incremental equals full" {
    var r = try lt.registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x5e);
    for (0..300) |_| try hl_test.checkIncremental(&shell.shell_language, &r, &pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (shell)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try lt.registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&shell.shell_language, &r, &pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}
