const std = @import("std");
const zg_core = @import("zg_core");
const query = @import("query.zig");

const testing = std.testing;

/// `want` is the tree in a bracketed debug form, or `!msg@start-end`.
const Case = struct { q: []const u8, want: []const u8 };

fn dump(a: std.mem.Allocator, q: query.QueryAst) error{OutOfMemory}![]const u8 {
    return switch (q) {
        .term => |t| std.fmt.allocPrint(a, "t:{s}", .{t.text}),
        .phrase => |w| std.fmt.allocPrint(a, "p:{s}", .{try std.mem.join(a, "_", w)}),
        .regex => |r| std.fmt.allocPrint(a, "re:{s}", .{r}),
        .and_ => |items| list(a, "and", items),
        .or_ => |items| list(a, "or", items),
        .not => |inner| std.fmt.allocPrint(a, "not({s})", .{try dump(a, inner.*)}),
        .op => |o| std.fmt.allocPrint(a, "{s}({s})", .{ o.kind.text(), try dump(a, o.arg.*) }),
        .prop => |p| std.fmt.allocPrint(a, "[{s} {s} {s}]", .{ p.name, @tagName(p.cmp), p.value orelse "-" }),
    };
}

fn list(a: std.mem.Allocator, name: []const u8, items: []const query.QueryAst) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, name);
    try out.append(a, '(');
    for (items, 0..) |it, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, try dump(a, it));
    }
    try out.append(a, ')');
    return out.items;
}

const cases = [_]Case{
    // Terms and AND.
    .{ .q = "", .want = "and()" },
    .{ .q = "   ", .want = "and()" },
    .{ .q = "zig", .want = "t:zig" },
    .{ .q = "zig lang", .want = "and(t:zig,t:lang)" },
    .{ .q = "  zig\tlang \n", .want = "and(t:zig,t:lang)" },
    .{ .q = "foo-bar", .want = "t:foo-bar" },
    .{ .q = "http://x.y/z", .want = "t:http://x.y/z" },
    .{ .q = "unknown:op", .want = "t:unknown:op" },
    .{ .q = "File:x", .want = "t:File:x" },
    .{ .q = "ORANGE or", .want = "and(t:ORANGE,t:or)" },
    .{ .q = "a(b)", .want = "and(t:a,t:b)" },
    .{ .q = "naïve 東京", .want = "and(t:naïve,t:東京)" },
    // OR and precedence.
    .{ .q = "a OR b", .want = "or(t:a,t:b)" },
    .{ .q = "a b OR c", .want = "or(and(t:a,t:b),t:c)" },
    .{ .q = "a OR b c", .want = "or(t:a,and(t:b,t:c))" },
    .{ .q = "a OR b OR c", .want = "or(t:a,t:b,t:c)" },
    .{ .q = "(a OR b) c", .want = "and(or(t:a,t:b),t:c)" },
    .{ .q = "a OR(b)", .want = "or(t:a,t:b)" },
    .{ .q = "((a))", .want = "t:a" },
    // Negation.
    .{ .q = "-a", .want = "not(t:a)" },
    .{ .q = "a -b", .want = "and(t:a,not(t:b))" },
    .{ .q = "-(a OR b)", .want = "not(or(t:a,t:b))" },
    .{ .q = "--a", .want = "not(not(t:a))" },
    .{ .q = "-\"a b\"", .want = "not(p:a_b)" },
    .{ .q = "-tag:#x", .want = "not(tag(t:#x))" },
    // Phrases.
    .{ .q = "\"hello world\"", .want = "p:hello_world" },
    .{ .q = "\"a  \t b\"", .want = "p:a_b" },
    .{ .q = "\"say \\\"hi\\\"\"", .want = "p:say_\"hi\"" },
    .{ .q = "\"\"", .want = "p:" },
    .{ .q = "\"back\\\\slash\"", .want = "p:back\\slash" },
    // Regex.
    .{ .q = "/ab+c/", .want = "re:ab+c" },
    .{ .q = "/a\\/b/", .want = "re:a/b" },
    .{ .q = "/\\d+/", .want = "re:\\d+" },
    .{ .q = "x /y/ z", .want = "and(t:x,re:y,t:z)" },
    // Operators.
    .{ .q = "file:readme", .want = "file(t:readme)" },
    .{ .q = "path:daily/2024", .want = "path(t:daily/2024)" },
    .{ .q = "content:zig", .want = "content(t:zig)" },
    .{ .q = "tag:#proj/alpha", .want = "tag(t:#proj/alpha)" },
    .{ .q = "line:(mix flour)", .want = "line(and(t:mix,t:flour))" },
    .{ .q = "block:(a OR b)", .want = "block(or(t:a,t:b))" },
    .{ .q = "section:\"two words\"", .want = "section(p:two_words)" },
    .{ .q = "task:call", .want = "task(t:call)" },
    .{ .q = "task-todo:\"\"", .want = "task-todo(p:)" },
    .{ .q = "task-done:(x)", .want = "task-done(t:x)" },
    .{ .q = "match-case:Zig", .want = "match-case(t:Zig)" },
    .{ .q = "ignore-case:/ZIG/", .want = "ignore-case(re:ZIG)" },
    .{ .q = "path:file:x", .want = "path(t:file:x)" },
    .{ .q = "file:-x", .want = "file(t:-x)" },
    .{ .q = "path:[x", .want = "path(t:[x)" },
    .{ .q = "line:(tag:#a -b)", .want = "line(and(tag(t:#a),not(t:b)))" },
    .{ .q = "file:a)", .want = "!unmatched )@6-7" },
    // Properties.
    .{ .q = "[status]", .want = "[status exists -]" },
    .{ .q = "[status:done]", .want = "[status eq done]" },
    .{ .q = "[ status : done ]", .want = "[status eq done]" },
    .{ .q = "[status:null]", .want = "[status is_null -]" },
    .{ .q = "[status:\"null\"]", .want = "[status eq null]" },
    .{ .q = "[rating:<5]", .want = "[rating lt 5]" },
    .{ .q = "[due:>2024-01-01]", .want = "[due gt 2024-01-01]" },
    .{ .q = "[title:\"a ] b\"]", .want = "[title eq a ] b]" },
    .{ .q = "[k:]", .want = "[k exists -]" },
    .{ .q = "[k:\"say \\\"x\\\"\"]", .want = "[k eq say \"x\"]" },
    .{ .q = "[a] [b:1] OR c", .want = "or(and([a exists -],[b eq 1]),t:c)" },
    // Errors with spans.
    .{ .q = "\"open", .want = "!unterminated quote@0-5" },
    .{ .q = "a \"open", .want = "!unterminated quote@2-7" },
    .{ .q = "/open", .want = "!unterminated regex@0-5" },
    .{ .q = "//", .want = "!empty regex@0-2" },
    .{ .q = "(a", .want = "!unclosed (@0-1" },
    .{ .q = "x (a OR b", .want = "!unclosed (@2-3" },
    .{ .q = "()", .want = "!empty group@0-2" },
    .{ .q = "a)", .want = "!unmatched )@1-2" },
    .{ .q = ")", .want = "!unmatched )@0-1" },
    .{ .q = "OR a", .want = "!OR needs a term on both sides@0-2" },
    .{ .q = "a OR", .want = "!OR needs a term on both sides@2-4" },
    .{ .q = "a OR OR b", .want = "!OR needs a term on both sides@2-4" },
    .{ .q = "-", .want = "!nothing to negate@0-1" },
    .{ .q = "a - b", .want = "!nothing to negate@2-3" },
    .{ .q = "tag:", .want = "!operator needs an argument@0-4" },
    .{ .q = "x line: y", .want = "!operator needs an argument@2-7" },
    .{ .q = "[open", .want = "!unterminated [property]@0-5" },
    .{ .q = "[]", .want = "!property name missing@0-2" },
    .{ .q = "[:x]", .want = "!property name missing@0-4" },
    .{ .q = "[a:<]", .want = "!comparison needs a value@0-5" },
    .{ .q = "[a:\"x]", .want = "!unterminated [property]@0-6" },
    .{ .q = "[a:x\"y]", .want = "!unterminated [property]@0-7" },
    .{ .q = "[a:x\"y\"]", .want = "!unexpected quote@0-8" },
    .{ .q = "(" ** 70 ++ "a" ++ ")" ** 70, .want = "!query nests too deeply@64-65" },
};

test "query: parser table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(cases.len >= 60);
    for (cases) |c| {
        const got: []const u8 = switch (query.parseQuery(a, c.q)) {
            .ok => |ast| try dump(a, ast),
            .err => |e| try std.fmt.allocPrint(a, "!{s}@{d}-{d}", .{ e.msg, e.span[0], e.span[1] }),
        };
        testing.expectEqualStrings(c.want, got) catch |err| {
            std.debug.print("query: {s}\n", .{c.q});
            return err;
        };
        if (got[0] != '!') try expectStable(a, c.q);
    }
}

/// parse → print → parse gives the same tree, and printing is a fixpoint.
fn expectStable(a: std.mem.Allocator, q: []const u8) !void {
    const first = switch (query.parseQuery(a, q)) {
        .ok => |ast| ast,
        .err => return,
    };
    const printed = try query.toString(a, first);
    const second = switch (query.parseQuery(a, printed)) {
        .ok => |ast| ast,
        .err => |e| {
            std.debug.print("reparse of '{s}' (from '{s}') failed: {s}\n", .{ printed, q, e.msg });
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings(try dump(a, first), try dump(a, second));
    try testing.expectEqualStrings(printed, try query.toString(a, second));
}

test "fuzz: note_query" {
    try testing.fuzz({}, struct {
        fn f(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const n = smith.slice(&buf);
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            try expectStable(arena.allocator(), buf[0..n]);
        }
    }.f, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "note_query") });
}
