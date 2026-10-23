const std = @import("std");
const query = @import("query/root.zig");

const testing = std.testing;
const ast = query.ast;

/// A query and either its canonical form or "error: message at s..e".
const Case = struct { []const u8, []const u8 };

const parser_table = [_]Case{
    // Stages.
    .{ "from sales", "from sales" },
    .{ "FROM sales", "from sales" },
    .{ "from `my sales`", "from `my sales`" },
    .{ "from \"2024.csv\"", "from `2024.csv`" },
    .{ "where a > 1", "where a > 1" },
    .{ "from s | where a > 1", "from s | where a > 1" },
    .{ "from s|where a>1|limit 5", "from s | where a > 1 | limit 5" },
    .{ "from s | derive b = a * 2, c = b + 1", "from s | derive b = a * 2, c = b + 1" },
    .{ "from s | select a, b", "from s | select a, b" },
    .{ "from s | select total = a + b, a", "from s | select total = a + b, a" },
    .{ "from s | group region { n = count() }", "from s | group region { n = count() }" },
    .{ "from s | group region, year { n = count(), total = sum(amount), }", "from s | group region, year { n = count(), total = sum(amount) }" },
    .{ "from s | group { n = count() }", "from s | group { n = count() }" },
    .{ "from s | sort a, -b", "from s | sort a, -b" },
    .{ "from s | sort a desc, b asc", "from s | sort -a, b" },
    .{ "from s | sort -a desc", "from s | sort a" },
    .{ "from s | sort +a", "from s | sort a" },
    .{ "from s | limit 10", "from s | limit 10" },
    .{ "from s | sample 1000", "from s | sample 1000" },
    .{ "from s | join r on id == rid", "from s | join r on id == rid" },
    .{ "from s | join r on id == rid left", "from s | join r on id == rid left" },
    .{ "from s # all rows\n| limit 3 # first three", "from s | limit 3" },
    // Literals.
    .{ "where a == 'x'", "where a == \"x\"" },
    .{ "where a == \"say \\\"hi\\\"\\n\"", "where a == \"say \\\"hi\\\"\\n\"" },
    .{ "where a == 'it\\'s'", "where a == \"it's\"" },
    .{ "where a == 1.5", "where a == 1.5" },
    .{ "where a == 2e3", "where a == 2e3" },
    .{ "where a == 2e30", "where a == 2e30" },
    .{ "where a == 2.0", "where a == 2.0" },
    .{ "where a == .5", "where a == 0.5" },
    .{ "where a == true or b == FALSE", "where a == true or b == false" },
    .{ "where a == null", "where a == null" },
    .{ "where d >= 2024-01-31", "where d >= 2024-01-31" },
    .{ "where t < 2024-01-31T10:20:30Z", "where t < 2024-01-31T10:20:30Z" },
    .{ "where t < 2024-01-31T10:20:30.250+02:00", "where t < 2024-01-31T08:20:30.250Z" },
    .{ "where `order id` == 7", "where `order id` == 7" },
    .{ "where `a``b` == 1", "where `a``b` == 1" },
    .{ "where `where` == 1", "where `where` == 1" },
    .{ "where a <> 1", "where a != 1" },
    // Precedence and parentheses.
    .{ "where a + b * c > 1", "where a + b * c > 1" },
    .{ "where (a + b) * c > 1", "where (a + b) * c > 1" },
    .{ "where a - (b - c) == 0", "where a - (b - c) == 0" },
    .{ "where ((a - b) - c) == 0", "where a - b - c == 0" },
    .{ "where a or b and c", "where a or b and c" },
    .{ "where (a or b) and c", "where (a or b) and c" },
    .{ "where not a and b", "where not a and b" },
    .{ "where not (a and b)", "where not (a and b)" },
    .{ "where not not a", "where not not a" },
    .{ "where -a > - -b", "where -a > - -b" },
    .{ "where -(a + b) > 0", "where -(a + b) > 0" },
    .{ "where a % 2 == 0", "where a % 2 == 0" },
    // Predicates.
    .{ "where a in [1, 2, 3]", "where a in [1, 2, 3]" },
    .{ "where a not in ['x']", "where a not in [\"x\"]" },
    .{ "where a in []", "where a in []" },
    .{ "where a between 1 and 10", "where a between 1 and 10" },
    .{ "where a not between 1 and 10 and b", "where a not between 1 and 10 and b" },
    .{ "where a is null", "where a is null" },
    .{ "where a is not null or b IS NULL", "where a is not null or b is null" },
    .{ "where a + 1 in [2]", "where a + 1 in [2]" },
    // Calls and case.
    .{ "where Contains(lower(name), 'x')", "where contains(lower(name), \"x\")" },
    .{ "derive m = trunc(day, 'month')", "derive m = trunc(day, \"month\")" },
    .{ "derive c = case when a > 1 then 'big' when a > 0 then 'small' else 'none' end", "derive c = case when a > 1 then \"big\" when a > 0 then \"small\" else \"none\" end" },
    .{ "derive c = case when a then 1 end", "derive c = case when a then 1 end" },
    .{ "group k { p95 = p(latency, 0.95) }", "group k { p95 = p(latency, 0.95) }" },
    // Errors, with spans.
    .{ "", "error: empty query at 0..0" },
    .{ "  # only a comment", "error: empty query at 18..18" },
    .{ "from", "error: expected a dataset name, found end of query at 4..4" },
    .{ "from where", "error: expected a dataset name, found `where` at 5..10" },
    .{ "from s | from t", "error: `from` must be the first stage at 9..13" },
    .{ "from s | filter a", "error: unknown stage `filter` at 9..15" },
    .{ "from s | 42", "error: expected a stage (from, where, derive, select, group, sort, limit, join, sample), found `42` at 9..11" },
    .{ "from s where a", "error: expected `|` or end of query, found `where` at 7..12" },
    .{ "where a > 1 > 2", "error: comparisons can't be chained; use `and` at 12..13" },
    .{ "where a == 'x", "error: unterminated string at 11..13" },
    .{ "where a ! b", "error: unexpected `!` (use `not` or `!=`) at 8..9" },
    .{ "where a == 12abc", "error: invalid number at 11..16" },
    .{ "where d == 2024-13-01", "error: invalid date at 11..21" },
    .{ "where (a > 1", "error: expected `)`, found end of query at 12..12" },
    .{ "where a in [1, 2", "error: expected `,` or `]`, found end of query at 16..16" },
    .{ "where a between 1 or 2", "error: expected `and` in `between`, found `or` at 18..20" },
    .{ "where a is 3", "error: expected `null` after `is`, found `3` at 11..12" },
    .{ "where and", "error: expected an expression, found keyword `and` at 6..9" },
    .{ "derive x", "error: expected `=` after `x`, found end of query at 8..8" },
    .{ "derive 1", "error: expected `name = expression`, found `1` at 7..8" },
    .{ "group k n = count()", "error: expected `{` and aggregates, found `n` at 8..9" },
    .{ "limit -1", "error: expected a row count, found `-` at 6..7" },
    .{ "limit 99999999999999999999", "error: number too large at 6..26" },
    .{ "where a == 9223372036854775808", "error: number too large at 11..30" },
    .{ "where a == 1e999", "error: number too large at 11..16" },
    .{ "join r id == rid", "error: expected `on`, found `id` at 7..9" },
    .{ "derive c = case a end", "error: expected `when`, found `a` at 16..17" },
    .{ "derive c = case when a then 1", "error: expected `end`, found end of query at 29..29" },
    .{ "from ``", "error: empty `quoted` name at 5..7" },
    .{ "sort \"\"", "error: empty column name at 5..7" },
    .{ "where t == 0000-01-01T00:00:00+01:00", "error: datetime out of range at 11..36" },
    .{ "where a == @", "error: unexpected character at 11..12" },
};

fn render(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    var diag: query.Diagnostic = .{};
    const t = query.parse(arena, src, &diag) catch |e| switch (e) {
        error.Syntax => return std.fmt.allocPrint(arena, "error: {f}", .{diag}),
        else => |x| return x,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try query.formatQuery(&t, &out.writer);
    return out.written();
}

test "parser_table" {
    try testing.expect(parser_table.len >= 80);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: usize = 0;
    for (parser_table) |c| {
        const got = try render(arena.allocator(), c[0]);
        if (!std.mem.eql(u8, got, c[1])) {
            std.debug.print("query: {s}\n  want: {s}\n  got:  {s}\n", .{ c[0], c[1], got });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

/// parse(format(ast)) == ast, and formatting is idempotent.
fn checkRoundTrip(arena: std.mem.Allocator, src: []const u8) !void {
    var diag: query.Diagnostic = .{};
    const t = query.parse(arena, src, &diag) catch |e| switch (e) {
        error.Syntax => return,
        else => |x| return x,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try query.formatQuery(&t, &out.writer);
    const text = out.written();
    const again = query.parse(arena, text, &diag) catch |e| {
        std.debug.print("canonical form doesn't parse: {s}\n  from: {s}\n  {f}\n", .{ text, src, diag });
        return e;
    };
    if (!ast.eqlAst(t, again)) {
        std.debug.print("round trip changed the tree: {s}\n  from: {s}\n", .{ text, src });
        return error.TestUnexpectedResult;
    }
    var out2: std.Io.Writer.Allocating = .init(arena);
    try query.formatQuery(&again, &out2.writer);
    try testing.expectEqualStrings(text, out2.written());
}

test "format_roundtrip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (parser_table) |c| try checkRoundTrip(arena.allocator(), c[0]);
    // Mutations of the table's queries: dropped, doubled and swapped bytes.
    var prng: std.Random.DefaultPrng = .init(0x5eed_9e7);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..4000) |_| {
        const src = parser_table[rnd.uintLessThan(usize, parser_table.len)][0];
        if (src.len == 0 or src.len >= buf.len / 2) continue;
        var n = src.len;
        @memcpy(buf[0..n], src);
        for (0..1 + rnd.uintLessThan(usize, 3)) |_| {
            const i = rnd.uintLessThan(usize, n);
            switch (rnd.uintLessThan(u8, 3)) {
                0 => {
                    std.mem.copyForwards(u8, buf[i .. n - 1], buf[i + 1 .. n]);
                    n -= 1;
                },
                1 => {
                    std.mem.copyBackwards(u8, buf[i + 1 .. n + 1], buf[i..n]);
                    n += 1;
                },
                else => std.mem.swap(u8, &buf[i], &buf[rnd.uintLessThan(usize, n)]),
            }
            if (n == 0) break;
        }
        try checkRoundTrip(arena.allocator(), buf[0..n]);
        _ = arena.reset(.retain_capacity);
    }
}

test "depth and length limits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: query.Diagnostic = .{};
    // 200 nested parentheses.
    const deep = try std.mem.concat(a, u8, &.{ "where ", "(" ** 200, "a", ")" ** 200 });
    try testing.expectError(error.Syntax, query.parse(a, deep, &diag));
    try testing.expectEqualStrings("query nested too deeply", diag.message);
    // A long `+` chain is as deep as it is long.
    var chain: std.ArrayList(u8) = .empty;
    try chain.appendSlice(a, "where a");
    for (0..1000) |_| try chain.appendSlice(a, " + a");
    try testing.expectError(error.Syntax, query.parse(a, chain.items, &diag));
    try testing.expectEqualStrings("query nested too deeply", diag.message);
    // 100 levels are fine.
    const ok = try std.mem.concat(a, u8, &.{ "where ", "(" ** 100, "a", ")" ** 100 });
    _ = try query.parse(a, ok, &diag);
    const huge = try a.alloc(u8, (64 << 10) + 1);
    @memset(huge, ' ');
    try testing.expectError(error.Syntax, query.parse(a, huge, &diag));
    try testing.expectEqualStrings("query longer than 64 KiB", diag.message);
}

test "fuzz_query_parse" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            try checkRoundTrip(arena.allocator(), input);
        }
    }.one, .{ .corpus = &.{
        "from s | where a > 1 and b in [1, 2] | group k { n = count() } | sort -n | limit 5",
        "derive c = case when a between 1 and 2 then 'x' else null end",
        "join r on id == rid left | select a, total = sum_x + 1",
        "where t >= 2024-01-01T00:00:00Z and not contains(lower(`a b`), \"q\")",
    } });
}
