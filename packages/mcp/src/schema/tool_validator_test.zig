//! `toolValidator` over a copy of zg_ai's facade types (zg_mcp cannot
//! import zg_ai): a corpus of tool schemas and model-shaped inputs, each
//! with the pointer and keyword the model is told about.

const std = @import("std");
const tool_validator = @import("tool_validator.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// The shape of `zg_ai.schema.validate`.
const Facade = struct {
    pub const CompileError = error{ OutOfMemory, InvalidSchema, SchemaTooLarge };
    pub const ValidationError = struct { pointer: []const u8, keyword: []const u8, message: []const u8 };
    pub const ErrorList = struct {
        items: [8]ValidationError = undefined,
        len: u8 = 0,
        overflow: u32 = 0,

        pub fn add(l: *ErrorList, e: ValidationError) void {
            if (l.len < l.items.len) {
                l.items[l.len] = e;
                l.len += 1;
            } else l.overflow += 1;
        }
    };
    pub const Validator = struct {
        ctx: *anyopaque,
        compile: *const fn (ctx: *anyopaque, arena: Allocator, schema_json: []const u8) CompileError!*const anyopaque,
        validate: *const fn (ctx: *anyopaque, compiled: *const anyopaque, arena: Allocator, value: std.json.Value, errs: *ErrorList) bool,
    };
};

const read_file =
    \\{"type":"object","properties":{"path":{"type":"string","minLength":1},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1,"maximum":2000}},"required":["path"],"additionalProperties":false}
;
const edit_file =
    \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","minItems":1,"items":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["old_string","new_string"],"additionalProperties":false}}},"required":["path","edits"]}
;
const run_command =
    \\{"type":"object","properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer","exclusiveMinimum":0},"mode":{"enum":["foreground","background"]},"env":{"type":"object","additionalProperties":{"type":"string"}}},"required":["command"]}
;
const search =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"glob":{"type":"string","pattern":"^[^\\s]+$"},"case":{"oneOf":[{"const":"smart"},{"type":"boolean"}]},"paths":{"type":"array","items":{"type":"string"},"uniqueItems":true,"maxItems":3}},"required":["pattern"],"dependentRequired":{"glob":["pattern"]}}
;
const refs =
    \\{"$defs":{"pos":{"type":"object","properties":{"line":{"type":"integer","minimum":0},"character":{"type":"integer","minimum":0}},"required":["line","character"]}},"type":"object","properties":{"start":{"$ref":"#/$defs/pos"},"end":{"$ref":"#/$defs/pos"},"name":false},"required":["start"]}
;

const Case = struct {
    schema: []const u8,
    input: []const u8,
    /// Null when the input is valid.
    want: ?struct { pointer: []const u8, keyword: []const u8 } = null,
};

const corpus = [_]Case{
    // read_file
    .{ .schema = read_file, .input = "{\"path\":\"src/main.zig\"}" },
    .{ .schema = read_file, .input = "{\"path\":\"a\",\"offset\":10,\"limit\":200}" },
    .{ .schema = read_file, .input = "{}", .want = .{ .pointer = "", .keyword = "required" } },
    .{ .schema = read_file, .input = "{\"path\":\"\"}", .want = .{ .pointer = "/path", .keyword = "minLength" } },
    .{ .schema = read_file, .input = "{\"path\":7}", .want = .{ .pointer = "/path", .keyword = "type" } },
    .{ .schema = read_file, .input = "{\"path\":\"a\",\"offset\":0}", .want = .{ .pointer = "/offset", .keyword = "minimum" } },
    .{ .schema = read_file, .input = "{\"path\":\"a\",\"limit\":5000}", .want = .{ .pointer = "/limit", .keyword = "maximum" } },
    .{ .schema = read_file, .input = "{\"path\":\"a\",\"limit\":2.5}", .want = .{ .pointer = "/limit", .keyword = "type" } },
    .{ .schema = read_file, .input = "{\"path\":\"a\",\"limit\":20.0}" },
    .{ .schema = read_file, .input = "{\"path\":\"a\",\"lines\":3}", .want = .{ .pointer = "/lines", .keyword = "additionalProperties" } },
    .{ .schema = read_file, .input = "[\"a\"]", .want = .{ .pointer = "", .keyword = "type" } },
    .{ .schema = read_file, .input = "null", .want = .{ .pointer = "", .keyword = "type" } },
    // edit_file
    .{ .schema = edit_file, .input = "{\"path\":\"a\",\"edits\":[{\"old_string\":\"x\",\"new_string\":\"y\"}]}" },
    .{ .schema = edit_file, .input = "{\"path\":\"a\",\"edits\":[{\"old_string\":\"x\",\"new_string\":\"y\",\"replace_all\":true},{\"old_string\":\"\",\"new_string\":\"z\"}]}" },
    .{ .schema = edit_file, .input = "{\"path\":\"a\",\"edits\":[]}", .want = .{ .pointer = "/edits", .keyword = "minItems" } },
    .{ .schema = edit_file, .input = "{\"path\":\"a\",\"edits\":[{\"old_string\":\"x\"}]}", .want = .{ .pointer = "/edits/0", .keyword = "required" } },
    .{ .schema = edit_file, .input = "{\"path\":\"a\",\"edits\":[{\"old_string\":\"x\",\"new_string\":\"y\"},{\"old_string\":1,\"new_string\":\"y\"}]}", .want = .{ .pointer = "/edits/1/old_string", .keyword = "type" } },
    .{ .schema = edit_file, .input = "{\"path\":\"a\",\"edits\":[{\"old_string\":\"x\",\"new_string\":\"y\",\"replace_all\":\"yes\"}]}", .want = .{ .pointer = "/edits/0/replace_all", .keyword = "type" } },
    .{ .schema = edit_file, .input = "{\"path\":\"a\",\"edits\":[{\"old_string\":\"x\",\"new_string\":\"y\",\"newString\":\"y\"}]}", .want = .{ .pointer = "/edits/0/newString", .keyword = "additionalProperties" } },
    .{ .schema = edit_file, .input = "{\"path\":\"a\",\"edits\":{\"old_string\":\"x\",\"new_string\":\"y\"}}", .want = .{ .pointer = "/edits", .keyword = "type" } },
    // run_command
    .{ .schema = run_command, .input = "{\"command\":\"zig build\"}" },
    .{ .schema = run_command, .input = "{\"command\":\"ls\",\"mode\":\"background\",\"env\":{\"A\":\"1\"}}" },
    .{ .schema = run_command, .input = "{\"command\":\"ls\",\"mode\":\"bg\"}", .want = .{ .pointer = "/mode", .keyword = "enum" } },
    .{ .schema = run_command, .input = "{\"command\":\"ls\",\"timeout_ms\":0}", .want = .{ .pointer = "/timeout_ms", .keyword = "exclusiveMinimum" } },
    .{ .schema = run_command, .input = "{\"command\":\"ls\",\"env\":{\"A\":1}}", .want = .{ .pointer = "/env/A", .keyword = "type" } },
    .{ .schema = run_command, .input = "{\"command\":[\"ls\",\"-l\"]}", .want = .{ .pointer = "/command", .keyword = "type" } },
    .{ .schema = run_command, .input = "{\"cmd\":\"ls\"}", .want = .{ .pointer = "", .keyword = "required" } },
    // search
    .{ .schema = search, .input = "{\"pattern\":\"fn main\"}" },
    .{ .schema = search, .input = "{\"pattern\":\"x\",\"glob\":\"*.zig\",\"case\":\"smart\",\"paths\":[\"a\",\"b\"]}" },
    .{ .schema = search, .input = "{\"pattern\":\"x\",\"case\":false}" },
    .{ .schema = search, .input = "{\"pattern\":\"x\",\"glob\":\"*.zig src\"}", .want = .{ .pointer = "/glob", .keyword = "pattern" } },
    .{ .schema = search, .input = "{\"pattern\":\"x\",\"case\":\"loud\"}", .want = .{ .pointer = "/case", .keyword = "oneOf" } },
    .{ .schema = search, .input = "{\"pattern\":\"x\",\"paths\":[\"a\",\"a\"]}", .want = .{ .pointer = "/paths", .keyword = "uniqueItems" } },
    .{ .schema = search, .input = "{\"pattern\":\"x\",\"paths\":[\"a\",\"b\",\"c\",\"d\"]}", .want = .{ .pointer = "/paths", .keyword = "maxItems" } },
    .{ .schema = search, .input = "{\"pattern\":\"x\",\"paths\":[\"a\",2]}", .want = .{ .pointer = "/paths/1", .keyword = "type" } },
    // $ref and false subschemas
    .{ .schema = refs, .input = "{\"start\":{\"line\":0,\"character\":4}}" },
    .{ .schema = refs, .input = "{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":2,\"character\":0}}" },
    .{ .schema = refs, .input = "{\"start\":{\"line\":-1,\"character\":4}}", .want = .{ .pointer = "/start/line", .keyword = "minimum" } },
    .{ .schema = refs, .input = "{\"start\":{\"line\":1},\"end\":{\"line\":1,\"character\":1}}", .want = .{ .pointer = "/start", .keyword = "required" } },
    .{ .schema = refs, .input = "{\"start\":{\"line\":1,\"character\":1},\"name\":\"x\"}", .want = .{ .pointer = "/name", .keyword = "false" } },
};

test "tool validator corpus" {
    const v = tool_validator.toolValidator(Facade);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (corpus, 0..) |c, i| {
        const s = try v.compile(v.ctx, a, c.schema);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, c.input, .{});
        var errs: Facade.ErrorList = .{};
        const ok = v.validate(v.ctx, s, a, value, &errs);
        errdefer std.debug.print("case {d}: {s}\n", .{ i, c.input });
        errdefer for (errs.items[0..errs.len]) |e| std.debug.print("  {s} {s}: {s}\n", .{ e.pointer, e.keyword, e.message });
        const want = c.want orelse {
            try testing.expect(ok);
            try testing.expectEqual(0, errs.len);
            continue;
        };
        try testing.expect(!ok);
        try testing.expect(errs.len >= 1);
        try testing.expectEqualStrings(want.pointer, errs.items[0].pointer);
        try testing.expectEqualStrings(want.keyword, errs.items[0].keyword);
        try testing.expect(errs.items[0].message.len > 0);
        if (std.mem.eql(u8, want.keyword, "additionalProperties") or std.mem.eql(u8, want.keyword, "false"))
            try testing.expectEqualStrings("this property is not allowed", errs.items[0].message);
    }
}

test "tool validator: every leaf error is reported" {
    const v = tool_validator.toolValidator(Facade);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try v.compile(v.ctx, a, read_file);
    var errs: Facade.ErrorList = .{};
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":1,\"offset\":0,\"limit\":9999}", .{});
    try testing.expect(!v.validate(v.ctx, s, a, value, &errs));
    try testing.expectEqual(3, errs.len);
}

test "tool validator: schema errors" {
    const v = tool_validator.toolValidator(Facade);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidSchema, v.compile(v.ctx, a, "{"));
    try testing.expectError(error.InvalidSchema, v.compile(v.ctx, a, "{\"type\":12}"));
    try testing.expectError(error.InvalidSchema, v.compile(v.ctx, a, "{\"$ref\":\"#/$defs/missing\"}"));
    try testing.expectError(error.InvalidSchema, v.compile(v.ctx, a, "{\"$ref\":\"https://example.com/s.json\"}"));
    _ = try v.compile(v.ctx, a, "true");
}
