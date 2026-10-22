//! Tool-input validation facade (E10.F01.S01.T02).
//!
//! zigguro has exactly one JSON Schema 2020-12 validator, owned by E11
//! (`packages/mcp/src/schema/`). zg_ai depends only on the small `Validator`
//! surface here; the E11 adapter is injected at `AgentManager` init once
//! zg_mcp is on main (E11.F01.S02.T01, PR #1202). Until then `permissive()`
//! lets every other E10 component run. No keyword logic lives in zg_ai.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;

/// Schema compilation failures.
pub const CompileError = error{ OutOfMemory, InvalidSchema, SchemaTooLarge };

/// One validation failure.
pub const ValidationError = struct {
    /// RFC 6901 pointer into the instance, e.g. `/edits/0/old_string`.
    pointer: []const u8,
    keyword: []const u8,
    message: []const u8,
};

/// Bounded error list (the first 8 errors; the rest are counted).
pub const ErrorList = struct {
    items: [8]ValidationError = undefined,
    len: u8 = 0,
    overflow: u32 = 0,

    /// Records one error.
    pub fn add(l: *ErrorList, e: ValidationError) void {
        if (l.len < l.items.len) {
            l.items[l.len] = e;
            l.len += 1;
        } else l.overflow += 1;
    }

    /// Recorded errors.
    pub fn slice(l: *const ErrorList) []const ValidationError {
        return l.items[0..l.len];
    }
};

/// A pluggable JSON Schema validator.
pub const Validator = struct {
    ctx: *anyopaque,
    compile: *const fn (ctx: *anyopaque, arena: Allocator, schema_json: []const u8) CompileError!*const anyopaque,
    validate: *const fn (ctx: *anyopaque, compiled: *const anyopaque, value: std.json.Value, errs: *ErrorList) bool,
};

var permissive_ctx: u8 = 0;

/// Bootstrap stub: compiles any JSON text and accepts any JSON object.
pub fn permissive() Validator {
    return .{ .ctx = &permissive_ctx, .compile = permissiveCompile, .validate = permissiveValidate };
}

fn permissiveCompile(_: *anyopaque, arena: Allocator, schema_json: []const u8) CompileError!*const anyopaque {
    _ = proto.json.parseValue(arena, schema_json) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSchema,
    };
    return &permissive_ctx;
}

fn permissiveValidate(_: *anyopaque, _: *const anyopaque, value: std.json.Value, errs: *ErrorList) bool {
    if (value == .object) return true;
    errs.add(.{ .pointer = "", .keyword = "type", .message = "expected an object" });
    return false;
}

/// A non-fatal adjustment made before validation (shown on the tool card).
pub const Coercion = struct { pointer: []const u8, from: []const u8 };

/// Coerces top-level string values holding numbers where the schema's
/// property is a plain `integer`/`number` (a common model mistake, e.g.
/// `"limit":"20"`). Returns the coerced pointers. Only plain numeric nodes
/// qualify: no unions, no other keywords that would need the validator.
pub fn coerceNumericStrings(arena: Allocator, schema: std.json.Value, value: *std.json.Value) Allocator.Error![]const Coercion {
    var out: std.ArrayList(Coercion) = .empty;
    if (schema != .object or value.* != .object) return out.items;
    const props_v = schema.object.get("properties") orelse return out.items;
    if (props_v != .object) return out.items;
    var it = value.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        const ps = props_v.object.get(e.key_ptr.*) orelse continue;
        if (ps != .object) continue;
        const ty = ps.object.get("type") orelse continue;
        if (ty != .string) continue;
        const is_int = std.mem.eql(u8, ty.string, "integer");
        if (!is_int and !std.mem.eql(u8, ty.string, "number")) continue;
        const s = std.mem.trim(u8, e.value_ptr.string, " ");
        const ok = if (is_int) (std.fmt.parseInt(i64, s, 10) catch null) != null else (std.fmt.parseFloat(f64, s) catch null) != null;
        if (!ok or s.len == 0) continue;
        var ptr: std.ArrayList(u8) = .empty;
        try appendPointerToken(arena, &ptr, e.key_ptr.*);
        try out.append(arena, .{ .pointer = ptr.items, .from = e.value_ptr.string });
        e.value_ptr.* = .{ .number_string = try arena.dupe(u8, s) };
    }
    return out.items;
}

/// Appends `/token` to `ptr` with RFC 6901 escaping (`~` → `~0`, `/` → `~1`).
pub fn appendPointerToken(a: Allocator, ptr: *std.ArrayList(u8), token: []const u8) Allocator.Error!void {
    try ptr.append(a, '/');
    for (token) |c| switch (c) {
        '~' => try ptr.appendSlice(a, "~0"),
        '/' => try ptr.appendSlice(a, "~1"),
        else => try ptr.append(a, c),
    };
}

/// A compiled schema bound to its validator.
pub const Compiled = struct {
    validator: Validator,
    handle: *const anyopaque,
    schema: std.json.Value,

    /// Compiles `schema_json` once (at tool registration).
    pub fn init(v: Validator, arena: Allocator, schema_json: []const u8) CompileError!Compiled {
        const handle = try v.compile(v.ctx, arena, schema_json);
        const schema = proto.json.parseValue(arena, schema_json) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidSchema,
        };
        return .{ .validator = v, .handle = handle, .schema = schema };
    }

    /// Outcome of `check`.
    pub const Result = struct { ok: bool, value: std.json.Value, coercions: []const Coercion, errors: ErrorList };

    /// Parses, coerces and validates a tool input.
    pub fn check(c: Compiled, arena: Allocator, input_json: []const u8) Allocator.Error!Result {
        var r: Result = .{ .ok = false, .value = .null, .coercions = &.{}, .errors = .{} };
        r.value = proto.json.parseValue(arena, input_json) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                r.errors.add(.{ .pointer = "", .keyword = "json", .message = "input is not valid JSON" });
                return r;
            },
        };
        r.coercions = try coerceNumericStrings(arena, c.schema, &r.value);
        r.ok = c.validator.validate(c.validator.ctx, c.handle, r.value, &r.errors);
        return r;
    }
};

const testing = std.testing;

test "permissive_stub_accepts_objects_rejects_scalars" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try Compiled.init(permissive(), arena.allocator(), "{\"type\":\"object\"}");
    try testing.expect((try c.check(arena.allocator(), "{\"a\":1}")).ok);
    const bad = try c.check(arena.allocator(), "42");
    try testing.expect(!bad.ok);
    try testing.expectEqualStrings("type", bad.errors.slice()[0].keyword);
    try testing.expect(!(try c.check(arena.allocator(), "{nope")).ok);
    try testing.expectError(error.InvalidSchema, Compiled.init(permissive(), arena.allocator(), "{"));
}

test "pointer_escaping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: std.ArrayList(u8) = .empty;
    try appendPointerToken(arena.allocator(), &p, "edits");
    try appendPointerToken(arena.allocator(), &p, "a/b~c");
    try testing.expectEqualStrings("/edits/a~1b~0c", p.items);
}

test "numeric_string_coercion_only_for_plain_numeric" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try proto.json.parseValue(a,
        \\{"type":"object","properties":{"limit":{"type":"integer"},"ratio":{"type":"number"},"name":{"type":"string"},"either":{"type":["integer","string"]}}}
    );
    var v = try proto.json.parseValue(a, "{\"limit\":\"20\",\"ratio\":\"0.5\",\"name\":\"7\",\"either\":\"3\",\"bad\":\"x\"}");
    const cs = try coerceNumericStrings(a, schema, &v);
    try testing.expectEqual(@as(usize, 2), cs.len);
    try testing.expectEqualStrings("{\"limit\":20,\"ratio\":0.5,\"name\":\"7\",\"either\":\"3\",\"bad\":\"x\"}", try proto.json.stringifyValue(a, v));
    var v2 = try proto.json.parseValue(a, "{\"limit\":\"twenty\"}");
    try testing.expectEqual(@as(usize, 0), (try coerceNumericStrings(a, schema, &v2)).len);
}
