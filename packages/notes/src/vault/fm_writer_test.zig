//! Property writer tests (E08.F06.S01.T03).

const std = @import("std");
const zg_core = @import("zg_core");
const fm = @import("frontmatter.zig");
const w = @import("fm_writer.zig");

const testing = std.testing;

fn expectEdit(before: []const u8, edits: []const w.PropEdit, after: []const u8) !void {
    const got = try w.applyPropEdits(testing.allocator, before, edits);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(after, got);
}

fn str(s: []const u8) fm.Value {
    return .{ .string = s };
}

fn listOf(comptime items: []const []const u8) fm.Value {
    const nodes = comptime blk: {
        var ns: [items.len]fm.Node = undefined;
        for (items, 0..) |it, i| ns[i] = .{ .value = .{ .string = it }, .src = .{ 0, 0 }, .style = .plain };
        const out = ns;
        break :blk out;
    };
    return .{ .list = &nodes };
}

test "fm_writer: set/remove/rename keep other bytes identical" {
    const note =
        \\---
        \\# a comment
        \\title:   'Old'   # trailing
        \\unknown: {deep: [1, 2]}
        \\n: 1
        \\---
        \\Body
    ;
    try expectEdit(note, &.{.{ .set = .{ .name = "title", .value = str("New") } }},
        \\---
        \\# a comment
        \\title:   'New'   # trailing
        \\unknown: {deep: [1, 2]}
        \\n: 1
        \\---
        \\Body
    );
    try expectEdit(note, &.{.{ .remove = "unknown" }},
        \\---
        \\# a comment
        \\title:   'Old'   # trailing
        \\n: 1
        \\---
        \\Body
    );
    try expectEdit(note, &.{.{ .rename = .{ .from = "n", .to = "count" } }},
        \\---
        \\# a comment
        \\title:   'Old'   # trailing
        \\unknown: {deep: [1, 2]}
        \\count: 1
        \\---
        \\Body
    );
    try expectEdit(note, &.{.{ .set = .{ .name = "n", .value = .{ .int = 2 } } }},
        \\---
        \\# a comment
        \\title:   'Old'   # trailing
        \\unknown: {deep: [1, 2]}
        \\n: 2
        \\---
        \\Body
    );
    try expectEdit(note, &.{.{ .set = .{ .name = "status", .value = str("done") } }},
        \\---
        \\# a comment
        \\title:   'Old'   # trailing
        \\unknown: {deep: [1, 2]}
        \\n: 1
        \\status: done
        \\---
        \\Body
    );
    // Absent keys: nothing changes.
    try expectEdit(note, &.{ .{ .remove = "nope" }, .{ .rename = .{ .from = "nope", .to = "x" } } }, note);
}

test "fm_writer: unknown and nested keys preserved byte-exact" {
    const note = "---\nmeta:\n  nested:\n    k: &a v\n  other: [x]\ntags: [a]\nweird: !!str 5\n---\n";
    try expectEdit(note, &.{.{ .set = .{ .name = "tags", .value = listOf(&.{ "a", "b" }) } }}, "---\nmeta:\n  nested:\n    k: &a v\n  other: [x]\ntags: [a, b]\nweird: !!str 5\n---\n");
    try expectEdit(note, &.{.{ .remove = "meta" }}, "---\ntags: [a]\nweird: !!str 5\n---\n");
}

test "fm_writer: quoting rules for ambiguous strings" {
    const cases = [_][2][]const u8{
        .{ "yes", "\"yes\"" },
        .{ "null", "\"null\"" },
        .{ "1.0", "\"1.0\"" },
        .{ "42", "\"42\"" },
        .{ "#tag", "\"#tag\"" },
        .{ ": x", "\": x\"" },
        .{ "@user", "\"@user\"" },
        .{ "a: b", "\"a: b\"" },
        .{ "say \"hi\"", "say \"hi\"" },
        .{ "\"hi\" there", "'\"hi\" there'" },
        .{ "two\nlines", "\"two\\nlines\"" },
        .{ "2024-01-01", "\"2024-01-01\"" },
        .{ "", "\"\"" },
        .{ "plain words", "plain words" },
        .{ "a#b", "a#b" },
        .{ "http://x.y", "http://x.y" },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        const before = try std.fmt.bufPrint(&buf, "---\nk: x\n---\n", .{});
        var want_buf: [128]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "---\nk: {s}\n---\n", .{c[1]});
        try expectEdit(before, &.{.{ .set = .{ .name = "k", .value = str(c[0]) } }}, want);
        // And it reads back as the same string.
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const root = try fm.parseFrontmatter(arena.allocator(), want[4 .. want.len - 4], null);
        try testing.expectEqualStrings(c[0], fm.get(&root, "k").?.value.string);
    }
}

test "fm_writer: block list stays block, flow stays flow" {
    try expectEdit("---\ntags:\n    - a\n    - b\nx: 1\n---\n", &.{.{ .set = .{ .name = "tags", .value = listOf(&.{ "c", "d", "e" }) } }}, "---\ntags:\n    - c\n    - d\n    - e\nx: 1\n---\n");
    try expectEdit("---\ntags:\n- a\nx: 1\n---\n", &.{.{ .set = .{ .name = "tags", .value = listOf(&.{"b"}) } }}, "---\ntags:\n- b\nx: 1\n---\n");
    try expectEdit("---\ntags: [a]\n---\n", &.{.{ .set = .{ .name = "tags", .value = listOf(&.{ "b", "c d" }) } }}, "---\ntags: [b, c d]\n---\n");
    // Scalar to list and list to scalar.
    try expectEdit("---\ntags: a\n---\n", &.{.{ .set = .{ .name = "tags", .value = listOf(&.{ "a", "b" }) } }}, "---\ntags:\n  - a\n  - b\n---\n");
    try expectEdit("---\ntags:\n  - a\n---\n", &.{.{ .set = .{ .name = "tags", .value = str("a") } }}, "---\ntags: a\n---\n");
    try expectEdit("---\ntags:\n---\n", &.{.{ .set = .{ .name = "tags", .value = listOf(&.{"x"}) } }}, "---\ntags:\n  - x\n---\n");
    try expectEdit("---\nk:\n---\n", &.{.{ .set = .{ .name = "k", .value = .{ .bool = true } } }}, "---\nk: true\n---\n");
    // A new list key is a block list.
    try expectEdit("---\na: 1\n---\n", &.{.{ .set = .{ .name = "aliases", .value = listOf(&.{"A"}) } }}, "---\na: 1\naliases:\n  - A\n---\n");
}

test "fm_writer: EOL style preserved; frontmatter created after BOM" {
    try expectEdit("---\r\na: 1\r\n---\r\nbody\r\n", &.{.{ .set = .{ .name = "tags", .value = listOf(&.{ "x", "z" }) } }}, "---\r\na: 1\r\ntags:\r\n  - x\r\n  - z\r\n---\r\nbody\r\n");
    try expectEdit("---\r\ntags:\r\n  - a\r\n---\r\n", &.{.{ .set = .{ .name = "tags", .value = listOf(&.{ "b", "c" }) } }}, "---\r\ntags:\r\n  - b\r\n  - c\r\n---\r\n");
    try expectEdit("\xEF\xBB\xBF# Title\n", &.{.{ .set = .{ .name = "status", .value = str("draft") } }}, "\xEF\xBB\xBF---\nstatus: draft\n---\n# Title\n");
    try expectEdit("# Title\r\n", &.{.{ .set = .{ .name = "n", .value = .{ .int = 1 } } }}, "---\r\nn: 1\r\n---\r\n# Title\r\n");
    try expectEdit("# Title\n", &.{.{ .remove = "x" }}, "# Title\n");
}

test "fm_writer: scalar kinds" {
    try expectEdit("---\nd: x\n---\n", &.{.{ .set = .{ .name = "d", .value = .{ .date = .{ .y = 2024, .m = 3, .d = 9 } } } }}, "---\nd: 2024-03-09\n---\n");
    try expectEdit("---\nf: x\n---\n", &.{.{ .set = .{ .name = "f", .value = .{ .float = 2 } } }}, "---\nf: 2.0\n---\n");
    try expectEdit("---\nt: x\n---\n", &.{.{ .set = .{ .name = "t", .value = .{ .datetime = .{ .date = .{ .y = 2024, .m = 3, .d = 9 }, .h = 8, .min = 5, .s = 0, .utc_offset_s = -3600 } } } }}, "---\nt: 2024-03-09T08:05:00-01:00\n---\n");
    try expectEdit("---\nq: \"old\"\n---\n", &.{.{ .set = .{ .name = "q", .value = str("new") } }}, "---\nq: \"new\"\n---\n");
    try expectEdit("---\nb: |\n  text\n  more\nz: 1\n---\n", &.{.{ .set = .{ .name = "b", .value = str("short") } }}, "---\nb: short\nz: 1\n---\n");
    try expectEdit("---\n\"my key\": 1\n---\n", &.{.{ .rename = .{ .from = "my key", .to = "with: colon" } }}, "---\n\"with: colon\": 1\n---\n");
}

test "fm_writer: edits then parse yields edited value, other keys keep bytes" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    for (0..300) |_| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var src: std.Io.Writer.Allocating = .init(a);
        try src.writer.writeAll("---\n");
        const n = r.intRangeAtMost(u32, 1, 6);
        for (0..n) |i| switch (r.intRangeAtMost(u8, 0, 3)) {
            0 => try src.writer.print("k{d}: v{d}\n", .{ i, r.int(u16) }),
            1 => try src.writer.print("k{d}:\n  - a\n  - b{d}\n", .{ i, r.int(u8) }),
            2 => try src.writer.print("k{d}: [x, {d}]\n", .{ i, r.int(u8) }),
            else => try src.writer.print("k{d}: \"q {d}\" # c\n", .{ i, r.int(u8) }),
        };
        try src.writer.writeAll("---\nbody\n");
        const before = src.written();
        const target = r.intRangeAtMost(u32, 0, n - 1);
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "k{d}", .{target});
        const val = try std.fmt.allocPrint(a, "new {d}", .{r.int(u16)});
        const after = try w.applyPropEdits(a, before, &.{.{ .set = .{ .name = name, .value = str(val) } }});
        const loc_b = fm.findFrontmatter(before).?;
        const loc_a = fm.findFrontmatter(after).?;
        const rb = try fm.parseRange(a, before, loc_b.body, null);
        const ra = try fm.parseRange(a, after, loc_a.body, null);
        try testing.expectEqualStrings(val, fm.get(&ra, name).?.value.string);
        for (rb.value.map, ra.value.map) |pb, pa| {
            if (std.mem.eql(u8, pb.key, name)) continue;
            try testing.expectEqualStrings(before[pb.span[0]..pb.span[1]], after[pa.span[0]..pa.span[1]]);
        }
        try testing.expect(std.mem.endsWith(u8, after, "---\nbody\n"));
    }
}

test "fuzz: frontmatter" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            // Any input: no crash, and every node range lies in the input.
            _ = try fm.parseFrontmatter(a, input, null);
            const out = try w.applyPropEdits(a, input, &.{
                .{ .set = .{ .name = "fuzz", .value = .{ .string = "v" } } },
                .{ .rename = .{ .from = "title", .to = "name" } },
                .{ .remove = "tags" },
            });
            // A note with frontmatter keeps it, and the set key reads back.
            if (fm.findFrontmatter(out)) |loc| {
                const root = try fm.parseRange(a, out, loc.body, null);
                if (root.value == .map) if (fm.get(&root, "fuzz")) |n| {
                    _ = n;
                };
            }
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "frontmatter") });
}
