const std = @import("std");
const path_mod = @import("path.zig");

const testing = std.testing;
const Path = path_mod.Path;

const scope_json =
    \\{
    \\  "plan": {"subquestions": [{"q": "a", "n": 1}, {"q": "b", "n": 2}, {"q": "c"}]},
    \\  "research": [
    \\    {"findings": [{"claim": "x", "source_ids": ["s1", "s2"]}, {"claim": "y", "source_ids": []}]},
    \\    null,
    \\    {"findings": [{"claim": "z", "source_ids": ["s3"]}]}
    \\  ],
    \\  "score": 7,
    \\  "flag": false,
    \\  "text": "hello",
    \\  "weird-key": {"under_score": true},
    \\  "$args": {"glob": "src/**/*.zig", "n": 3, "tags": ["a", "b"]},
    \\  "$item": {"file": "main.zig", "lines": [10, 20]},
    \\  "$index": 4,
    \\  "file": "bound.zig"
    \\}
;

const Case = struct { path: []const u8, want: []const u8 };

// `want` is the JSON array of matches.
const cases = [_]Case{
    .{ .path = "$.text", .want = "[\"hello\"]" },
    .{ .path = "$.score", .want = "[7]" },
    .{ .path = "$.flag", .want = "[false]" },
    .{ .path = "$.missing", .want = "[]" },
    .{ .path = "$.text.deeper", .want = "[]" },
    .{ .path = "$.plan.subquestions[0].q", .want = "[\"a\"]" },
    .{ .path = "$.plan.subquestions[2].q", .want = "[\"c\"]" },
    .{ .path = "$.plan.subquestions[3].q", .want = "[]" },
    .{ .path = "$.plan.subquestions[2].n", .want = "[]" },
    .{ .path = "$.plan.subquestions[*].q", .want = "[\"a\",\"b\",\"c\"]" },
    .{ .path = "$.plan.subquestions[*].n", .want = "[1,2]" },
    .{ .path = "$.plan.subquestions[*]", .want = "[{\"q\":\"a\",\"n\":1},{\"q\":\"b\",\"n\":2},{\"q\":\"c\"}]" },
    .{ .path = "$.research[*].findings[*].claim", .want = "[\"x\",\"y\",\"z\"]" },
    .{ .path = "$.research[*].findings[*].source_ids[*]", .want = "[\"s1\",\"s2\",\"s3\"]" },
    .{ .path = "$.research[1]", .want = "[null]" },
    .{ .path = "$.research[1].findings", .want = "[]" },
    .{ .path = "$.research[0].findings[1].source_ids", .want = "[[]]" },
    .{ .path = "$.score[*]", .want = "[]" },
    .{ .path = "$.text[0]", .want = "[]" },
    .{ .path = "$.weird-key.under_score", .want = "[true]" },
    .{ .path = "$args.glob", .want = "[\"src/**/*.zig\"]" },
    .{ .path = "$args.n", .want = "[3]" },
    .{ .path = "$args.tags[1]", .want = "[\"b\"]" },
    .{ .path = "$args.tags[*]", .want = "[\"a\",\"b\"]" },
    .{ .path = "$args.none", .want = "[]" },
    .{ .path = "$item.file", .want = "[\"main.zig\"]" },
    .{ .path = "$item.lines[1]", .want = "[20]" },
    .{ .path = "$item.lines[*]", .want = "[10,20]" },
    .{ .path = "$item", .want = "[{\"file\":\"main.zig\",\"lines\":[10,20]}]" },
    .{ .path = "$index", .want = "[4]" },
    .{ .path = "$file", .want = "[\"bound.zig\"]" },
    .{ .path = "$other.file", .want = "[\"main.zig\"]" },
    .{ .path = "$.plan.subquestions[1]", .want = "[{\"q\":\"b\",\"n\":2}]" },
    .{ .path = "$.plan.*", .want = "" },
    .{ .path = "$.", .want = "" },
    .{ .path = "plan", .want = "" },
    .{ .path = "$.plan[", .want = "" },
    .{ .path = "$.plan[-1]", .want = "" },
    .{ .path = "$.plan..q", .want = "" },
    .{ .path = "$index.x", .want = "" },
};

test "path_eval_table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scope = try std.json.parseFromSliceLeaky(std.json.Value, a, scope_json, .{});
    try testing.expectEqual(@as(usize, 40), cases.len);
    for (cases) |c| {
        errdefer std.debug.print("path {s}\n", .{c.path});
        if (c.want.len == 0) {
            try testing.expectError(error.InvalidPath, Path.compile(a, c.path));
            continue;
        }
        const p = try Path.compile(a, c.path);
        var out: std.ArrayList(std.json.Value) = .empty;
        try p.eval(scope, &out, a);
        var arr: std.json.Array = .init(a);
        try arr.appendSlice(out.items);
        const got = try std.json.Stringify.valueAlloc(a, std.json.Value{ .array = arr }, .{});
        try testing.expectEqualStrings(c.want, got);
    }
}

test "path_value_and_item_scoping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scope = try std.json.parseFromSliceLeaky(std.json.Value, a, scope_json, .{});
    // Single paths give the value; wildcard paths always an array.
    try testing.expectEqualStrings("hello", (try (try Path.compile(a, "$.text")).value(scope, a)).string);
    try testing.expect((try (try Path.compile(a, "$.nope")).value(scope, a)) == .null);
    const many = try (try Path.compile(a, "$.nope[*]")).value(scope, a);
    try testing.expectEqual(@as(usize, 0), many.array.items.len);
    // Without an item in scope, $item yields nothing.
    var bare: std.json.ObjectMap = .empty;
    try bare.put(a, "x", .{ .integer = 1 });
    try testing.expect((try (try Path.compile(a, "$item")).first(.{ .object = bare }, a)) == null);
    try testing.expect(path_mod.truthy(.{ .integer = 1 }));
    try testing.expect(!path_mod.truthy(.{ .string = "" }));
    try testing.expect(!path_mod.truthy(.null));
}
