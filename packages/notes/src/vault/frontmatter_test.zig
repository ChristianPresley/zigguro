//! Frontmatter parser tests (E08.F06.S01.T03).

const std = @import("std");
const zg_core = @import("zg_core");
const fm = @import("zg_frontmatter").frontmatter;

const testing = std.testing;

/// The value of `v: <text>` rendered compactly, for table comparisons.
fn render(w: *std.Io.Writer, v: fm.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.print("bool:{}", .{b}),
        .int => |i| try w.print("int:{d}", .{i}),
        .float => |f| if (std.math.isNan(f)) try w.writeAll("float:nan") else try w.print("float:{d}", .{f}),
        .string => |s| try w.print("str:{s}", .{s}),
        .date => |d| try w.print("date:{d}-{d}-{d}", .{ d.y, d.m, d.d }),
        .datetime => |dt| try w.print("dt:{d}-{d}-{d} {d}:{d}:{d} {?d}", .{ dt.date.y, dt.date.m, dt.date.d, dt.h, dt.min, dt.s, dt.utc_offset_s }),
        .raw => |r| try w.print("raw:{s}", .{r}),
        .list => |items| {
            try w.writeByte('[');
            for (items, 0..) |n, i| {
                if (i > 0) try w.writeByte(',');
                try render(w, n.value);
            }
            try w.writeByte(']');
        },
        .map => |pairs| {
            try w.writeByte('{');
            for (pairs, 0..) |p, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{s}=", .{p.key});
                try render(w, p.node.value);
            }
            try w.writeByte('}');
        },
    }
}

fn expectParse(yaml: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: zg_core.report.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    const root = try fm.parseFrontmatter(arena.allocator(), yaml, &diag);
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try render(&out.writer, root.value);
    testing.expectEqualStrings(want, out.written()) catch |e| {
        std.debug.print("yaml:\n{s}\n", .{yaml});
        return e;
    };
}

fn expectRaw(yaml: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: zg_core.report.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    const root = try fm.parseFrontmatter(arena.allocator(), yaml, &diag);
    try testing.expect(diag.messages.items.len > 0);
    try testing.expect(root.value.map.len >= 1);
    try testing.expect(hasRaw(root.value.map[0].node.value));
}

fn hasRaw(v: fm.Value) bool {
    return switch (v) {
        .raw => true,
        .list => |items| for (items) |n| {
            if (hasRaw(n.value)) break true;
        } else false,
        else => false,
    };
}

test "frontmatter: yaml subset table" {
    const cases = [_][2][]const u8{
        // Plain scalars and core-schema typing.
        .{ "a: hello", "{a=str:hello}" },
        .{ "a: hello world  ", "{a=str:hello world}" },
        .{ "a: hello # comment", "{a=str:hello}" },
        .{ "a: hello#not-comment", "{a=str:hello#not-comment}" },
        .{ "a:", "{a=null}" },
        .{ "a: ~", "{a=null}" },
        .{ "a: null", "{a=null}" },
        .{ "a: Null", "{a=null}" },
        .{ "a: NULL", "{a=null}" },
        .{ "a: nULL", "{a=str:nULL}" },
        .{ "a: true", "{a=bool:true}" },
        .{ "a: True", "{a=bool:true}" },
        .{ "a: TRUE", "{a=bool:true}" },
        .{ "a: false", "{a=bool:false}" },
        .{ "a: False", "{a=bool:false}" },
        .{ "a: yes", "{a=str:yes}" },
        .{ "a: 42", "{a=int:42}" },
        .{ "a: -7", "{a=int:-7}" },
        .{ "a: +7", "{a=int:7}" },
        .{ "a: 0o17", "{a=int:15}" },
        .{ "a: 0x1F", "{a=int:31}" },
        .{ "a: 0x", "{a=str:0x}" },
        .{ "a: 1.5", "{a=float:1.5}" },
        .{ "a: .5", "{a=float:0.5}" },
        .{ "a: 1e3", "{a=float:1000}" },
        .{ "a: 1.", "{a=float:1}" },
        .{ "a: .inf", "{a=float:inf}" },
        .{ "a: -.Inf", "{a=float:-inf}" },
        .{ "a: .nan", "{a=float:nan}" },
        .{ "a: 1.2.3", "{a=str:1.2.3}" },
        .{ "a: 12abc", "{a=str:12abc}" },
        // Dates.
        .{ "a: 2024-02-29", "{a=date:2024-2-29}" },
        .{ "a: 2023-02-29", "{a=str:2023-02-29}" },
        .{ "a: 2024-13-01", "{a=str:2024-13-01}" },
        .{ "a: 2024-01-05T10:30", "{a=dt:2024-1-5 10:30:0 null}" },
        .{ "a: 2024-01-05T10:30:15Z", "{a=dt:2024-1-5 10:30:15 0}" },
        .{ "a: 2024-01-05 10:30:15+02:00", "{a=dt:2024-1-5 10:30:15 7200}" },
        .{ "a: 2024-01-05T10:30:15.250-0130", "{a=dt:2024-1-5 10:30:15 -5400}" },
        .{ "a: 2024-01-05T25:30", "{a=str:2024-01-05T25:30}" },
        // Quoted scalars.
        .{ "a: 'it''s'", "{a=str:it's}" },
        .{ "a: '42'", "{a=str:42}" },
        .{ "a: \"42\"", "{a=str:42}" },
        .{ "a: \"tab\\there\"", "{a=str:tab\there}" },
        .{ "a: \"q\\\"x\\\\y\"", "{a=str:q\"x\\y}" },
        .{ "a: \"\\u00e9\\x41\"", "{a=str:\u{e9}A}" },
        .{ "a: \"\\U0001F600\"", "{a=str:\u{1F600}}" },
        .{ "a: \"# not a comment\" # comment", "{a=str:# not a comment}" },
        .{ "a: \"line\n  two\"", "{a=str:line two}" },
        .{ "a: 'one\n\n  two'", "{a=str:one\ntwo}" },
        .{ "\"quoted key\": 1", "{quoted key=int:1}" },
        .{ "'k''s': 1", "{k's=int:1}" },
        // Multi-line plain.
        .{ "a: one\n  two\n  three\nb: 1", "{a=str:one two three,b=int:1}" },
        // Block scalars.
        .{ "a: |\n  one\n  two\nb: 1", "{a=str:one\ntwo\n,b=int:1}" },
        .{ "a: |-\n  one\n  two\n", "{a=str:one\ntwo}" },
        .{ "a: |+\n  one\n\n\nb: 1", "{a=str:one\n\n\n,b=int:1}" },
        .{ "a: >\n  one\n  two\n\n  three\n", "{a=str:one two\nthree\n}" },
        .{ "a: >-\n  one\n    indented\n  two\n", "{a=str:one\n  indented\ntwo}" },
        .{ "a: |2\n    x\n  y\n", "{a=str:  x\ny\n}" },
        .{ "a: | # keep\n  x\n", "{a=str:x\n}" },
        .{ "a: |\nb: 1", "{a=str:,b=int:1}" },
        // Block sequences.
        .{ "tags:\n  - a\n  - b", "{tags=[str:a,str:b]}" },
        .{ "tags:\n- a\n- b\nx: 1", "{tags=[str:a,str:b],x=int:1}" },
        .{ "tags:\n  - 'a'\n  - 3\n  -\n  - [x, y]", "{tags=[str:a,int:3,null,[str:x,str:y]]}" },
        .{ "tags:\n  - a # c\n\n  - b", "{tags=[str:a,str:b]}" },
        // Flow collections.
        .{ "a: [a, \"b\", 3]", "{a=[str:a,str:b,int:3]}" },
        .{ "a: []", "{a=[]}" },
        .{ "a: [ x ,y,]", "{a=[str:x,str:y]}" },
        .{ "a: [one,\n  two]\nb: 2", "{a=[str:one,str:two],b=int:2}" },
        .{ "a: {x: 1, y: \"s\"}", "{a={x=int:1,y=str:s}}" },
        .{ "a: {}", "{a={}}" },
        .{ "a: [http://x.y/z]", "{a=[str:http://x.y/z]}" },
        // Nested maps.
        .{ "a:\n  b: 1\n  c:\n    d: x\ne: 2", "{a={b=int:1,c={d=str:x}},e=int:2}" },
        // Comments and blank lines.
        .{ "# top\n\na: 1\n  # indented comment\nb: 2\n", "{a=int:1,b=int:2}" },
        .{ "a: 1\r\nb: two\r\n", "{a=int:1,b=str:two}" },
        // Keys with colons in values.
        .{ "url: http://example.com:8080/x", "{url=str:http://example.com:8080/x}" },
        .{ "a: b:c", "{a=str:b:c}" },
        .{ "k-1_x: v", "{k-1_x=str:v}" },
        .{ "-k: v", "{-k=str:v}" },
    };
    for (cases) |c| try expectParse(c[0], c[1]);
}

test "frontmatter: unsupported constructs become raw" {
    try expectRaw("a: &anchor 1");
    try expectRaw("a: *alias");
    try expectRaw("a: !!str 1");
    try expectRaw("a:\n  - x: 1\n    y: 2");
    try expectRaw("a:\n  - - x");
    try expectRaw("a: [unterminated");
    try expectRaw("a: \"unterminated");
    try expectRaw("a: [[nested]]");
}

test "frontmatter: raw values keep their text and the next key still parses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const yaml = "a: &x 1\nb:\n  - k: v\n    j: w\nc: 3";
    const root = try fm.parseFrontmatter(arena.allocator(), yaml, null);
    const m = root.value.map;
    try testing.expectEqual(@as(usize, 3), m.len);
    try testing.expectEqualStrings("&x 1", m[0].node.value.raw);
    try testing.expectEqualStrings("k: v\n    j: w", m[1].node.value.list[0].value.raw);
    try testing.expectEqual(@as(i64, 3), m[2].node.value.int);
}

test "frontmatter: source ranges" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const yaml = "title: \"Hi\" # c\ntags:\n  - a\n  - b\nn: 1\n";
    const root = try fm.parseFrontmatter(arena.allocator(), yaml, null);
    const m = root.value.map;
    try testing.expectEqualStrings("\"Hi\"", yaml[m[0].node.src[0]..m[0].node.src[1]]);
    try testing.expectEqualStrings("title", yaml[m[0].key_src[0]..m[0].key_src[1]]);
    try testing.expectEqualStrings("title: \"Hi\" # c\n", yaml[m[0].span[0]..m[0].span[1]]);
    try testing.expectEqualStrings("  - a\n  - b", yaml[m[1].node.src[0]..m[1].node.src[1]]);
    try testing.expectEqualStrings("tags:\n  - a\n  - b\n", yaml[m[1].span[0]..m[1].span[1]]);
    try testing.expectEqualStrings("n: 1\n", yaml[m[2].span[0]..m[2].span[1]]);
    // Unescaped single-line scalars are slices of the source.
    try testing.expect(m[0].node.value.string.ptr == yaml.ptr + 8);
}

test "frontmatter: detection with BOM, CRLF, '...' terminator, missing terminator" {
    {
        const n = "---\na: 1\n---\nbody";
        const loc = fm.findFrontmatter(n).?;
        try testing.expectEqualStrings("a: 1\n", n[loc.body[0]..loc.body[1]]);
        try testing.expectEqualStrings("---\na: 1\n---\n", n[loc.block[0]..loc.block[1]]);
    }
    {
        const n = "\xEF\xBB\xBF---\r\na: 1\r\n...\r\nbody";
        const loc = fm.findFrontmatter(n).?;
        try testing.expectEqualStrings("a: 1\r\n", n[loc.body[0]..loc.body[1]]);
        try testing.expectEqual(@as(u32, 3), loc.block[0]);
    }
    {
        const n = "---  \n---";
        const loc = fm.findFrontmatter(n).?;
        try testing.expectEqual(loc.body[0], loc.body[1]);
        try testing.expectEqual(@as(u32, 9), loc.block[1]);
    }
    try testing.expect(fm.findFrontmatter("---\na: 1\nno end") == null);
    try testing.expect(fm.findFrontmatter("text\n---\na: 1\n---\n") == null);
    try testing.expect(fm.findFrontmatter("----\na\n---\n") == null);
    try testing.expect(fm.findFrontmatter(" ---\na\n---\n") == null);
    try testing.expect(fm.findFrontmatter("---") == null);
    try testing.expect(fm.findFrontmatter("") == null);
}

test "frontmatter: limits produce diagnostics, not errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: zg_core.report.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    // 64 KB.
    const big = try a.alloc(u8, fm.max_bytes + 1);
    @memset(big, 'x');
    const r1 = try fm.parseFrontmatter(a, big, &diag);
    try testing.expect(r1.value == .raw);
    // 1 000 keys.
    var many: std.Io.Writer.Allocating = .init(a);
    for (0..1005) |i| try many.writer.print("k{d}: {d}\n", .{ i, i });
    const r2 = try fm.parseFrontmatter(a, many.written(), &diag);
    try testing.expectEqual(@as(usize, fm.max_keys), r2.value.map.len);
    // Depth 4.
    const r3 = try fm.parseFrontmatter(a, "a:\n b:\n  c:\n   d:\n    e: 1\nz: 2", &diag);
    const d4 = r3.value.map[0].node.value.map[0].node.value.map[0].node.value.map[0].node;
    try testing.expect(d4.value == .raw);
    try testing.expectEqual(@as(i64, 2), r3.value.map[1].node.value.int);
    try testing.expect(diag.messages.items.len >= 3);
}

test "frontmatter: malformed headers never fail" {
    const broken = [_][]const u8{
        "a",            ": x",              "a: [1, 2", "a: {x: 1",
        "  a: 1\nb: 2", "a: \"x",           "a: 'x",    "- item",
        "a: 1\n  b: 2", "a: |\nb",          "?: x",     "a: !tag",
        "a:\n- - x",    "a: \"\\q\"",       "\t\ta: b", "a: b: c: d",
        "[a]: b",       "a:\n  - b\n c: d", "{ broken", "a: &",
    };
    for (broken) |b| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        _ = try fm.parseFrontmatter(arena.allocator(), b, null);
    }
}
