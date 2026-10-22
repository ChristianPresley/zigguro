const std = @import("std");
const context = @import("context.zig");
const neighbours = @import("neighbours.zig");
const fim = @import("fim.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// One token per byte, so budgets read as byte counts.
const bytes: context.TokenEstimate = .{ .count = struct {
    fn f(_: ?*anyopaque, t: []const u8) u32 {
        return @intCast(t.len);
    }
}.f };

/// A fixed enclosing scope.
const FixedScope = struct {
    range: [2]usize,

    fn scopes(s: *FixedScope) context.Scopes {
        return .{ .ctx = s, .enclosing = f };
    }

    fn f(ctx: *anyopaque, _: usize) ?[2]usize {
        const s: *FixedScope = @ptrCast(@alignCast(ctx));
        return s.range;
    }
};

fn budget(total: u32) context.ContextBudget {
    return .{ .total_tokens = total, .prefix_share = 0.5, .suffix_share = 0.5, .extra_share = 0.5 };
}

const zig_src =
    \\const std = @import("std");
    \\const mem = std.mem;
    \\
    \\// helpers
    \\fn other() void {}
    \\
    \\fn sum(xs: []const u32) u32 {
    \\    var total: u32 = 0;
    \\    for (xs) |x| total += x;
    \\    return total;
    \\}
    \\
    \\a
    \\b
    \\c
    \\d
    \\e
    \\f
    \\
;

fn at(text: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, text, needle).? + needle.len;
}

test "fim: prefix starts at the enclosing function when within 1.5x the budget" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cursor = at(zig_src, "    return ");
    const fn_start = std.mem.indexOf(u8, zig_src, "fn sum").?;
    var scope: FixedScope = .{ .range = .{ fn_start, at(zig_src, "return total;\n}\n") } };
    // A 65-byte prefix budget reaches two lines back; the function starts
    // 94 bytes back, within 97.5.
    const req = try context.buildRequest(a, zig_src, cursor, .{ .path = "src/m.zig", .language = "zig", .budget = budget(130), .est = bytes, .scopes = scope.scopes() });
    try testing.expect(std.mem.indexOf(u8, req.prefix, "fn sum(xs") != null);
    // The header gave way to the function.
    try testing.expect(std.mem.indexOf(u8, req.prefix, "@import") == null);
    try testing.expect(std.mem.startsWith(u8, req.prefix, "// path: src/m.zig\n"));
    try testing.expect(std.mem.endsWith(u8, req.prefix, "    return "));

    // Too far (75 for a 50-byte budget): whole lines within the budget.
    const tight = try context.buildRequest(a, zig_src, cursor, .{ .path = "src/m.zig", .language = "zig", .budget = budget(100), .est = bytes, .scopes = scope.scopes() });
    try testing.expect(std.mem.indexOf(u8, tight.prefix, "fn sum") == null);
    try testing.expect(std.mem.indexOf(u8, tight.prefix, "for (xs)") != null);
}

test "fim: header and imports block included with a path comment" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cursor = at(zig_src, "\nd");
    // The 28-byte header (the last import line) takes its place first (at
    // most half of 100);
    // the lines above the cursor fill the rest, short of the function.
    const req = try context.buildRequest(a, zig_src, cursor, .{ .path = "src/m.zig", .language = "zig", .budget = budget(200), .est = bytes });
    try testing.expect(std.mem.indexOf(u8, req.prefix, "fn sum") == null);
    try testing.expect(std.mem.startsWith(u8, req.prefix, "// path: src/m.zig\nconst std = @import(\"std\");\n    for (xs) |x| total += x;\n"));
    try testing.expect(std.mem.endsWith(u8, req.prefix, "a\nb\nc\nd"));

    const py = "import os\nfrom x import y\n\n" ++ "z = 1\n" ** 40 ++ "q";
    const preq = try context.buildRequest(a, py, py.len, .{ .path = "m.py", .language = "python", .budget = budget(120), .est = bytes });
    try testing.expect(std.mem.startsWith(u8, preq.prefix, "# path: m.py\nimport os\nfrom x import y\nz = 1\n"));

    // An unknown language has no header, only the path line.
    const other = try context.buildRequest(a, py, py.len, .{ .path = "m.txt", .language = "text", .budget = budget(120), .est = bytes });
    try testing.expect(std.mem.indexOf(u8, other.prefix, "import os") == null);
}

test "fim: suffix stops five lines past the scope end" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cursor = at(zig_src, "    return ");
    const fn_end = at(zig_src, "return total;\n}\n");
    var scope: FixedScope = .{ .range = .{ std.mem.indexOf(u8, zig_src, "fn sum").?, fn_end } };
    const req = try context.buildRequest(a, zig_src, cursor, .{ .path = "m.zig", .language = "zig", .budget = budget(1000), .est = bytes, .scopes = scope.scopes() });
    try testing.expectEqualStrings("total;\n}\n\na\nb\nc\nd\n", req.suffix);
    // Without scopes, the budget alone.
    const free = try context.buildRequest(a, zig_src, cursor, .{ .path = "m.zig", .language = "zig", .budget = budget(1000), .est = bytes });
    try testing.expectEqualStrings(zig_src[cursor..], free.suffix);
    const small = try context.buildRequest(a, zig_src, cursor, .{ .path = "m.zig", .language = "zig", .budget = budget(18), .est = bytes });
    try testing.expectEqualStrings("total;\n}\n", small.suffix);
}

test "fim: multiline decision table" {
    const Case = struct { before: []const u8, after: []const u8, lang: []const u8, multi: bool };
    const cases = [_]Case{
        .{ .before = "", .after = "\n", .lang = "zig", .multi = true },
        .{ .before = "    ", .after = "", .lang = "zig", .multi = true },
        .{ .before = "fn f() void {", .after = "\n", .lang = "zig", .multi = true },
        .{ .before = "    if (x) {", .after = "}", .lang = "zig", .multi = true },
        .{ .before = "    const x = ", .after = "", .lang = "zig", .multi = false },
        .{ .before = "    foo(", .after = ");", .lang = "zig", .multi = true },
        .{ .before = "    return x", .after = "", .lang = "zig", .multi = false },
        .{ .before = "    x.", .after = "y()", .lang = "zig", .multi = false },
        .{ .before = "def f(x):", .after = "", .lang = "python", .multi = true },
        .{ .before = "    for x in xs:", .after = "\n", .lang = "python", .multi = true },
        .{ .before = "    y = x +", .after = "", .lang = "python", .multi = false },
        .{ .before = "    print(", .after = ")", .lang = "python", .multi = true },
        .{ .before = "label:", .after = "", .lang = "c", .multi = false },
        .{ .before = "const f = (x) =>", .after = "", .lang = "typescript", .multi = true },
        .{ .before = "const xs = [", .after = "];", .lang = "typescript", .multi = true },
        .{ .before = "let s = \"abc", .after = "\";", .lang = "typescript", .multi = false },
        .{ .before = "  return a", .after = " + b;", .lang = "typescript", .multi = false },
        .{ .before = "class A {", .after = "", .lang = "typescript", .multi = true },
    };
    for (cases) |c| {
        testing.expectEqual(c.multi, context.isBlockPosition(c.before, c.after, c.lang)) catch |e| {
            std.debug.print("case: {s}|{s} ({s})\n", .{ c.before, c.after, c.lang });
            return e;
        };
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const line = try context.buildRequest(arena.allocator(), "x = foo", 7, .{ .path = "m.py", .language = "python" });
    try testing.expect(!line.multiline);
    try testing.expectEqual(@as(u32, 32), line.max_tokens);
    try testing.expectEqualStrings("\n", line.stop[0]);
    const block = try context.buildRequest(arena.allocator(), "x = foo", 7, .{ .path = "m.py", .language = "python", .explicit = true });
    try testing.expect(block.multiline);
    try testing.expectEqual(@as(u32, 256), block.max_tokens);
    try testing.expectEqual(@as(usize, 0), block.stop.len);
}

test "fim: neighbour ranking prefers shared identifiers; excluded docs never included" {
    var nb: neighbours.NeighbourIndex = .init(gpa);
    defer nb.deinit();
    try nb.note(1, "a.zig", "fn parseHeader(reader: Reader) Header {}\n", false);
    try nb.note(2, "b.zig", "fn drawButton(canvas: Canvas) void {}\n", false);
    try nb.note(3, "secret.zig", "fn parseHeader(reader: Reader) Header { token }\n", true);
    try nb.note(4, "c.zig", "const header = parseHeader(reader);\n", false);

    const q = try neighbours.identifiers(gpa, "const h = parseHeader(reader); h.Header");
    defer gpa.free(q);
    var out: [3]neighbours.Snippet = undefined;
    const n = try nb.top(q, 4, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("a.zig", out[0].path);

    // Many windows: 60 lines overlapping by 30, the best one wins.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    for (0..100) |i| try long.print(gpa, "line{d} filler\n", .{i});
    try long.appendSlice(gpa, "parseHeader reader Header\n");
    try nb.note(5, "long.zig", long.items, false);
    const m = try nb.top(q, 4, &out);
    try testing.expectEqual(@as(usize, 2), m);
    try testing.expect(std.mem.indexOf(u8, out[1].text, "parseHeader") != null or std.mem.indexOf(u8, out[0].text, "parseHeader") != null);

    // A document's own best window outside the prompt's range.
    const own = (try nb.bestIn(5, q, .{ 0, 10 })).?;
    try testing.expect(std.mem.indexOf(u8, own.text, "parseHeader") != null);
    try testing.expect((try nb.bestIn(5, q, .{ 0, long.items.len })) == null);
    try testing.expect((try nb.bestIn(3, q, .{ 0, 0 })) == null);

    // Only 20 documents are kept.
    for (10..40) |i| try nb.note(i, "x.zig", "x", false);
    try testing.expectEqual(@as(usize, neighbours.max_docs), nb.docs.items.len);
    try testing.expect((try nb.bestIn(1, q, .{ 0, 0 })) == null);
}

test "fim: extras come from neighbours within their budget" {
    var nb: neighbours.NeighbourIndex = .init(gpa);
    defer nb.deinit();
    try nb.note(1, "a.zig", "fn parseHeader(reader: Reader) Header {}\n", false);
    try nb.note(2, "big.zig", "parseHeader reader Header " ++ "x" ** 400 ++ "\n", false);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = "const h = parseHeader(reader);\n";
    const req = try context.buildRequest(arena.allocator(), text, text.len, .{ .path = "m.zig", .language = "zig", .budget = budget(200), .est = bytes, .neighbours = &nb, .doc = 9 });
    try testing.expectEqual(@as(usize, 1), req.extras.len);
    try testing.expectEqualStrings("a.zig", req.extras[0].path);
}

test "fim: budget respected with a byte estimator" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var text: std.ArrayList(u8) = .empty;
    for (0..500) |i| try text.print(arena.allocator(), "line {d}\n", .{i});
    const cursor = text.items.len / 2;
    const b: context.ContextBudget = .{ .total_tokens = 1000 };
    const req = try context.buildRequest(arena.allocator(), text.items, cursor, .{ .path = "m", .budget = b, .est = bytes });
    const path_line = "// path: m\n".len;
    try testing.expect(req.prefix.len - path_line <= 600);
    try testing.expect(req.prefix.len - path_line > 600 - 12);
    try testing.expect(req.suffix.len <= 150);
    try testing.expect(req.suffix.len > 150 - 12);
}

test "fim: catalog, PSM, SPM and repository-level renders" {
    try testing.expect(fim.catalog.len >= 4);
    for (fim.catalog) |t| {
        try testing.expect(t.prefix_tok.len > 0 and t.suffix_tok.len > 0 and t.middle_tok.len > 0 and t.eot.len > 0);
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const req: context.CompletionRequest = .{
        .path = "src/m.py",
        .language = "python",
        .prefix = "def add(a, b):\n    ",
        .suffix = "\n\nprint(add(1, 2))\n",
        .extras = &.{.{ .path = "src/util.py", .text = "def sub(a, b):\n    return a - b" }},
        .multiline = false,
        .max_tokens = 32,
        .stop = &.{"\n"},
    };

    const qwen = fim.find(fim.catalog, "qwen2.5-coder").?;
    try testing.expectEqualStrings(
        "<|repo_name|>demo\n<|file_sep|>src/util.py\ndef sub(a, b):\n    return a - b\n<|file_sep|>src/m.py\n" ++
            "<|fim_prefix|>def add(a, b):\n    <|fim_suffix|>\n\nprint(add(1, 2))\n<|fim_middle|>",
        try fim.render(a, qwen, &req, "demo"),
    );
    // Without a repository name: the triplet alone.
    try testing.expectEqualStrings(
        "<|fim_prefix|>def add(a, b):\n    <|fim_suffix|>\n\nprint(add(1, 2))\n<|fim_middle|>",
        try fim.render(a, qwen, &req, ""),
    );

    const llama = fim.find(fim.catalog, "codellama").?;
    try testing.expectEqualStrings(
        "<PRE> def add(a, b):\n     <SUF>\n\nprint(add(1, 2))\n <MID>",
        try fim.render(a, llama, &req, "demo"),
    );

    var spm = qwen.*;
    spm.order = .spm;
    spm.repo_tok = null;
    try testing.expectEqualStrings(
        "<|fim_suffix|>\n\nprint(add(1, 2))\n<|fim_prefix|>def add(a, b):\n    <|fim_middle|>",
        try fim.render(a, &spm, &req, "demo"),
    );

    const st = try fim.stops(a, llama, &req);
    try testing.expectEqual(@as(usize, 2), st.len);
    try testing.expectEqualStrings(" <EOT>", st[1]);
}
