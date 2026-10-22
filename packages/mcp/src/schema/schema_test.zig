//! Unit tests for the JSON Schema compiler and validator.

const std = @import("std");
const zg_core = @import("zg_core");
const schema = @import("root.zig");
const testing = std.testing;
const Value = std.json.Value;

fn parse(a: std.mem.Allocator, s: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, s, .{ .allocate = .alloc_always });
}

const Case = struct {
    arena: std.heap.ArenaAllocator,
    s: *schema.Schema,

    fn init(src: []const u8, opts: schema.CompileOptions) !Case {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const s = try schema.compile(testing.allocator, try parse(arena.allocator(), src), opts);
        return .{ .arena = arena, .s = s };
    }

    fn deinit(c: *Case) void {
        c.s.deinit();
        c.arena.deinit();
    }

    fn valid(c: *Case, instance: []const u8) !bool {
        return schema.validate(c.s, testing.allocator, try parse(c.arena.allocator(), instance), null);
    }
};

test "schema: type integer accepts 1.0, rejects 1.5" {
    var c = try Case.init(
        \\{"type":"integer"}
    , .{});
    defer c.deinit();
    try testing.expect(try c.valid("1.0"));
    try testing.expect(try c.valid("1"));
    try testing.expect(!try c.valid("1.5"));
}

test "schema: enum deep equality ignores key order" {
    var c = try Case.init(
        \\{"enum":[{"a":1,"b":[1,2]}]}
    , .{});
    defer c.deinit();
    try testing.expect(try c.valid(
        \\{"b":[1.0,2],"a":1}
    ));
    try testing.expect(!try c.valid(
        \\{"b":[2,1],"a":1}
    ));
}

test "schema: multipleOf 0.01 on 19.99 valid" {
    var c = try Case.init(
        \\{"multipleOf":0.01}
    , .{});
    defer c.deinit();
    try testing.expect(try c.valid("19.99"));
    try testing.expect(!try c.valid("19.995"));
}

test "schema: minLength counts code points" {
    var c = try Case.init(
        \\{"minLength":2,"maxLength":2}
    , .{});
    defer c.deinit();
    try testing.expect(try c.valid("\"\u{e9}\u{e9}\""));
    try testing.expect(!try c.valid("\"\u{e9}\""));
}

test "schema: uniqueItems [1, 1.0] invalid" {
    var c = try Case.init(
        \\{"uniqueItems":true}
    , .{});
    defer c.deinit();
    try testing.expect(!try c.valid("[1, 1.0]"));
    try testing.expect(!try c.valid(
        \\[{"a":1,"b":2},{"b":2,"a":1}]
    ));
    try testing.expect(try c.valid("[1, true, \"1\", [1], {\"1\":1}]"));
}

test "schema: output pointers escape ~ and /" {
    var c = try Case.init(
        \\{"properties":{"a/b":{"properties":{"c~d":{"type":"string"}}}}}
    , .{});
    defer c.deinit();
    var out: schema.Output = .init(testing.allocator);
    defer out.deinit();
    const inst = try parse(c.arena.allocator(),
        \\{"a/b":{"c~d":5}}
    );
    try testing.expect(!try schema.validate(c.s, testing.allocator, inst, &out));
    try testing.expect(!out.valid);
    try testing.expectEqual(@as(usize, 1), out.errors.items.len);
    const e = out.errors.items[0];
    try testing.expectEqualStrings("/a~1b/c~0d", e.instance_location);
    try testing.expectEqualStrings("/properties/a~1b/properties/c~0d/type", e.keyword_location);
}

test "schema: unsupported pattern annotate vs reject" {
    var c = try Case.init(
        \\{"pattern":"^(?=a)"}
    , .{});
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.s.warnings.len);
    try testing.expect(try c.valid("\"b\""));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidSchema, schema.compile(testing.allocator, try parse(arena.allocator(),
        \\{"pattern":"^(?=a)"}
    ), .{ .unsupported_pattern = .reject }));
}

test "refs: recursive tree schema" {
    var c = try Case.init(
        \\{"$defs":{"node":{"type":"object","properties":{"value":{"type":"number"},
        \\ "children":{"type":"array","items":{"$ref":"#/$defs/node"}}},"required":["value"]}},
        \\ "$ref":"#/$defs/node"}
    , .{});
    defer c.deinit();
    try testing.expect(try c.valid(
        \\{"value":1,"children":[{"value":2,"children":[{"value":3}]}]}
    ));
    try testing.expect(!try c.valid(
        \\{"value":1,"children":[{"value":2,"children":[{"value":"x"}]}]}
    ));
}

test "refs: $dynamicRef extends" {
    var c = try Case.init(
        \\{"$id":"https://example.test/strict-tree","$dynamicAnchor":"node","$ref":"tree","unevaluatedProperties":false,
        \\ "$defs":{"tree":{"$id":"https://example.test/tree","$dynamicAnchor":"node","type":"object",
        \\   "properties":{"data":true,"children":{"type":"array","items":{"$dynamicRef":"#node"}}}}}}
    , .{});
    defer c.deinit();
    try testing.expect(try c.valid(
        \\{"children":[{"data":1}]}
    ));
    try testing.expect(!try c.valid(
        \\{"children":[{"daat":1}]}
    ));
}

test "unevaluatedProperties with allOf + $ref" {
    var c = try Case.init(
        \\{"$defs":{"base":{"properties":{"a":true}}},"allOf":[{"$ref":"#/$defs/base"},{"properties":{"b":true}}],
        \\ "unevaluatedProperties":false}
    , .{});
    defer c.deinit();
    try testing.expect(try c.valid(
        \\{"a":1,"b":2}
    ));
    try testing.expect(!try c.valid(
        \\{"a":1,"b":2,"c":3}
    ));
}

test "limits: exponential anyOf stops < 10ms" {
    // Each level doubles the work: 2^40 evaluations without a budget.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "{\"$defs\":{\"l0\":{\"type\":\"string\"}");
    for (1..41) |i| try src.print(testing.allocator, ",\"l{d}\":{{\"anyOf\":[{{\"$ref\":\"#/$defs/l{d}\"}},{{\"$ref\":\"#/$defs/l{d}\"}}]}}", .{ i, i - 1, i - 1 });
    try src.appendSlice(testing.allocator, "},\"$ref\":\"#/$defs/l40\"}");
    var c = try Case.init(src.items, .{ .limits = .{ .max_steps_per_validation = 20_000 } });
    defer c.deinit();
    const t0 = std.Io.Timestamp.now(testing.io, .awake);
    try testing.expectError(error.ValidationBudgetExceeded, c.valid("1"));
    const ms = t0.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    try testing.expect(ms < 10);
}

test "remote ref refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.RemoteRefRefused, schema.compile(testing.allocator, try parse(arena.allocator(),
        \\{"$ref":"https://example.test/schema.json"}
    ), .{}));
    try testing.expectError(error.UnresolvedRef, schema.compile(testing.allocator, try parse(arena.allocator(),
        \\{"$ref":"#/$defs/missing"}
    ), .{}));
}

test "draft7 items-array mapping" {
    var c = try Case.init(
        \\{"$schema":"http://json-schema.org/draft-07/schema#","items":[{"type":"integer"},{"type":"string"}],"additionalItems":false}
    , .{});
    defer c.deinit();
    try testing.expectEqual(schema.Dialect.draft7, c.s.dialect);
    try testing.expect(try c.valid("[1,\"a\"]"));
    try testing.expect(!try c.valid("[1,\"a\",3]"));
    try testing.expect(!try c.valid("[\"a\"]"));
}

test "unknown $schema => UnsupportedDialect" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedDialect, schema.compile(testing.allocator, try parse(arena.allocator(),
        \\{"$schema":"https://example.test/my-dialect"}
    ), .{}));
}

test "schema: metaschema reference validates schemas" {
    var c = try Case.init(
        \\{"$ref":"https://json-schema.org/draft/2020-12/schema"}
    , .{});
    defer c.deinit();
    try testing.expect(try c.valid(
        \\{"type":"string","minLength":1}
    ));
    try testing.expect(!try c.valid(
        \\{"type":"strin"}
    ));
}

test "fuzz: mcp schema compile and validate" {
    // Input: schema JSON, a NUL byte, instance JSON. Any outcome but a crash
    // or a hang is fine; the step budget bounds validation.
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const bytes = buf[0..sm.slice(&buf)];
            const cut = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const doc = std.json.parseFromSliceLeaky(Value, a, bytes[0..cut], .{}) catch return;
            const s = schema.compile(testing.allocator, doc, .{
                .limits = .{ .max_steps_per_validation = 50_000, .max_subschemas = 2_000 },
                .format_assertion = .all_supported,
            }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
            defer s.deinit();
            const rest = if (cut < bytes.len) bytes[cut + 1 ..] else "null";
            const inst = std.json.parseFromSliceLeaky(Value, a, rest, .{}) catch return;
            var out: schema.Output = .init(testing.allocator);
            defer out.deinit();
            const ok = schema.validate(s, testing.allocator, inst, &out) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.ValidationBudgetExceeded => return,
            };
            // With and without an Output, the verdict is the same.
            try testing.expectEqual(ok, try schema.validate(s, testing.allocator, inst, null));
            try testing.expectEqual(ok, out.valid);
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "mcp_schema") });
}
