//! The agent's tool-input validator (E10.F01.S01.T02): zg_ai's `Validator`
//! facade over this JSON Schema implementation, so tool inputs are checked
//! by the same code as MCP `tools/call` arguments.
//!
//! zg_mcp and zg_ai sit on the same layer and cannot import each other, so
//! the adapter is generic over the facade: the app passes
//! `zg_ai.schema.validate`, which provides `Validator`, `CompileError`,
//! `ErrorList` and `ValidationError`.
//!
//! ```zig
//! const v = zg_mcp.schema.toolValidator(zg_ai.schema.validate);
//! mgr.deps.validator = v;
//! ```

const std = @import("std");
const compile_mod = @import("compile.zig");
const validate_mod = @import("validate.zig");
const Schema = @import("Schema.zig");

const Allocator = std.mem.Allocator;

/// How many errors are scanned for the leaf ones (the facade keeps 8).
const max_scanned = 64;

var ctx_byte: u8 = 0;

/// The facade validator for `Facade` (a namespace like
/// `zg_ai.schema.validate`). Schemas compile with the default options:
/// 2020-12, ECMA-262 patterns, no remote references, formats as
/// annotations.
pub fn toolValidator(comptime Facade: type) Facade.Validator {
    const Impl = struct {
        fn compile(_: *anyopaque, arena: Allocator, schema_json: []const u8) Facade.CompileError!*const anyopaque {
            const root = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_json, .{}) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidSchema,
            };
            // The schema's own arena hangs off `arena`, which frees it.
            return compile_mod.compile(arena, root, .{}) catch |e| switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.SchemaTooLarge, error.SchemaTooDeep => error.SchemaTooLarge,
                error.InvalidSchema, error.UnsupportedDialect, error.RemoteRefRefused, error.UnresolvedRef => error.InvalidSchema,
            };
        }

        fn validate(_: *anyopaque, compiled: *const anyopaque, arena: Allocator, value: std.json.Value, errs: *Facade.ErrorList) bool {
            const s: *const Schema = @ptrCast(@alignCast(compiled));
            var out: validate_mod.Output = .init(arena);
            const ok = validate_mod.validate(s, arena, value, &out) catch |e| {
                errs.add(.{ .pointer = "", .keyword = "budget", .message = switch (e) {
                    error.ValidationBudgetExceeded => "the input is too complex to validate",
                    error.OutOfMemory => "out of memory while validating",
                } });
                return false;
            };
            if (ok) return true;
            const all = out.errors.items[0..@min(out.errors.items.len, max_scanned)];
            for (all, 0..) |e, i| {
                if (!isLeaf(all, i)) continue;
                const kw = keywordOf(e.keyword_location);
                const unexpected = std.mem.eql(u8, kw, "false") or std.mem.eql(u8, kw, "additionalProperties") or std.mem.eql(u8, kw, "unevaluatedProperties");
                const message = if (unexpected and std.mem.startsWith(u8, e.message, "the false schema")) "this property is not allowed" else e.message;
                errs.add(.{ .pointer = e.instance_location, .keyword = kw, .message = message });
            }
            if (errs.len == 0) errs.add(.{ .pointer = "", .keyword = "schema", .message = "the input does not match the schema" });
            return false;
        }
    };
    return .{ .ctx = &ctx_byte, .compile = Impl.compile, .validate = Impl.validate };
}

/// Whether no other error lies below `errs[i]` in the schema: an
/// applicator that failed because a subschema failed adds nothing the
/// model can act on.
fn isLeaf(errs: []const validate_mod.Output.Error, i: usize) bool {
    const loc = errs[i].keyword_location;
    for (errs, 0..) |o, j| {
        if (j == i or o.keyword_location.len <= loc.len) continue;
        if (std.mem.startsWith(u8, o.keyword_location, loc) and o.keyword_location[loc.len] == '/') return false;
    }
    return true;
}

/// The keyword that failed: the last segment of the keyword location, or
/// `false` for a `false` subschema (whose location ends at a property name
/// or an index).
fn keywordOf(loc: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, loc, '/') orelse return if (loc.len == 0) "false" else loc;
    const last = loc[cut + 1 ..];
    if (last.len == 0 or std.ascii.isDigit(last[0])) return "false";
    const parent_end = cut;
    const parent_start = if (std.mem.lastIndexOfScalar(u8, loc[0..parent_end], '/')) |p| p + 1 else 0;
    const parent = loc[parent_start..parent_end];
    const named = [_][]const u8{ "properties", "patternProperties", "dependentSchemas", "$defs", "definitions" };
    for (named) |n| if (std.mem.eql(u8, parent, n)) return "false";
    return last;
}

test keywordOf {
    const t = std.testing;
    try t.expectEqualStrings("type", keywordOf("/properties/path/type"));
    try t.expectEqualStrings("required", keywordOf("/required"));
    try t.expectEqualStrings("additionalProperties", keywordOf("/additionalProperties"));
    try t.expectEqualStrings("false", keywordOf("/properties/x"));
    try t.expectEqualStrings("false", keywordOf("/prefixItems/0"));
    try t.expectEqualStrings("false", keywordOf(""));
}
