//! Strict-mode schema normalisation, applied when a provider has the
//! `strict_tools` capability. Keys keep their original order (new keys are
//! appended) so the output is byte-stable for prompt caching.
//!
//! - `anthropic`: every object schema gets `"additionalProperties":false`;
//!   `required` is unchanged.
//! - `openai`: the same, plus every property becomes required and formerly
//!   optional properties also accept `null`, because OpenAI strict mode
//!   requires every field in `required`. Example:
//!
//!       before {"type":"object","properties":{"path":{"type":"string"},"limit":{"type":"integer"}},"required":["path"]}
//!       after  {"type":"object","properties":{"path":{"type":"string"},"limit":{"type":["integer","null"]}},"required":["path","limit"],"additionalProperties":false}

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Target strict dialect.
pub const Dialect = enum { anthropic, openai };

/// Returns the strict form of `schema_json`, allocated in `arena`.
pub fn toStrict(arena: Allocator, schema_json: []const u8, dialect: Dialect) ![]const u8 {
    var v = try proto.json.parseValue(arena, schema_json);
    try normalize(arena, &v, dialect, 0);
    return proto.json.stringifyValue(arena, v);
}

fn isObjectSchema(o: std.json.ObjectMap) bool {
    if (o.get("properties") != null) return true;
    const ty = o.get("type") orelse return false;
    return switch (ty) {
        .string => |s| std.mem.eql(u8, s, "object"),
        .array => |a| for (a.items) |t| {
            if (t == .string and std.mem.eql(u8, t.string, "object")) break true;
        } else false,
        else => false,
    };
}

fn normalize(arena: Allocator, v: *Value, dialect: Dialect, depth: u32) !void {
    if (depth > 64) return error.SchemaTooDeep;
    if (v.* != .object) return;
    const o = &v.object;
    // Recurse first into nested schemas.
    inline for (.{ "properties", "$defs", "definitions", "patternProperties" }) |k| {
        if (o.getPtr(k)) |m| if (m.* == .object) {
            for (m.object.values()) |*sub| try normalize(arena, sub, dialect, depth + 1);
        };
    }
    inline for (.{ "items", "additionalItems", "not", "if", "then", "else", "contains" }) |k| {
        if (o.getPtr(k)) |sub| try normalize(arena, sub, dialect, depth + 1);
    }
    inline for (.{ "anyOf", "oneOf", "allOf", "prefixItems" }) |k| {
        if (o.getPtr(k)) |arr| if (arr.* == .array) {
            for (arr.array.items) |*sub| try normalize(arena, sub, dialect, depth + 1);
        };
    }
    if (!isObjectSchema(o.*)) return;
    if (dialect == .openai) {
        if (o.getPtr("properties")) |props| if (props.* == .object) {
            var required: std.json.Array = .init(arena);
            const old_req = o.get("required");
            for (props.object.keys(), props.object.values()) |name, *ps| {
                try required.append(.{ .string = name });
                if (!contains(old_req, name)) try allowNull(arena, ps);
            }
            try o.put(arena, "required", .{ .array = required });
        };
    }
    try o.put(arena, "additionalProperties", .{ .bool = false });
}

fn contains(req: ?Value, name: []const u8) bool {
    const r = req orelse return false;
    if (r != .array) return false;
    for (r.array.items) |x| if (x == .string and std.mem.eql(u8, x.string, name)) return true;
    return false;
}

fn allowNull(arena: Allocator, ps: *Value) !void {
    if (ps.* != .object) return;
    const o = &ps.object;
    if (o.getPtr("enum")) |e| if (e.* == .array) {
        for (e.array.items) |x| {
            if (x == .null) break;
        } else try e.array.append(.null);
    };
    if (o.getPtr("type")) |ty| switch (ty.*) {
        .string => |s| {
            if (std.mem.eql(u8, s, "null")) return;
            var arr: std.json.Array = .init(arena);
            try arr.append(.{ .string = s });
            try arr.append(.{ .string = "null" });
            ty.* = .{ .array = arr };
            return;
        },
        .array => |*a| {
            for (a.items) |t| if (t == .string and std.mem.eql(u8, t.string, "null")) return;
            try a.append(.{ .string = "null" });
            return;
        },
        else => return,
    };
    if (o.getPtr("anyOf")) |any| if (any.* == .array) {
        var nul: std.json.ObjectMap = .empty;
        try nul.put(arena, "type", .{ .string = "null" });
        try any.array.append(.{ .object = nul });
    };
}

const golden = @import("zg_core").testkit.golden;

const samples = [_][]const u8{
    \\{"type":"object","properties":{"path":{"type":"string"},"limit":{"type":"integer"}},"required":["path"]}
    ,
    \\{"type":"object","properties":{"edits":{"type":"array","items":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["old_string","new_string"]}}},"required":["edits"]}
    ,
    \\{"type":"object","properties":{"mode":{"enum":["a","b"],"type":"string"},"opts":{"type":["object","null"],"properties":{"x":{"type":"number"}}}}}
    ,
    \\{"type":"object","properties":{"target":{"anyOf":[{"type":"string"},{"type":"integer"}]}},"required":[]}
    ,
    \\{"$defs":{"pos":{"type":"object","properties":{"line":{"type":"integer"},"col":{"type":"integer"}},"required":["line","col"]}},"type":"object","properties":{"at":{"$ref":"#/$defs/pos"}},"required":["at"]}
    ,
    \\{"type":"object","properties":{},"additionalProperties":true}
    ,
};

fn goldenFor(dialect: Dialect, comptime name: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    for (samples) |s| {
        const first = try toStrict(arena.allocator(), s, dialect);
        // Idempotent and byte-stable.
        try std.testing.expectEqualStrings(first, try toStrict(arena.allocator(), first, dialect));
        try out.appendSlice(arena.allocator(), first);
        try out.append(arena.allocator(), '\n');
    }
    try golden.expectGoldenOpts(std.testing.io, @src(), name, out.items, .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/schema" });
}

test "strict_anthropic_golden" {
    try goldenFor(.anthropic, "strict_anthropic");
}

test "strict_openai_golden" {
    try goldenFor(.openai, "strict_openai");
}

test "strict example from the doc comment" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"path":{"type":"string"},"limit":{"type":["integer","null"]}},"required":["path","limit"],"additionalProperties":false}
    , try toStrict(arena.allocator(), samples[0], .openai));
}
