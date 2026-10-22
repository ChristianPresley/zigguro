//! JSON Schema (2020-12 and draft-07) for MCP tool input/output schemas and
//! elicitation forms: compile once, validate many times.
//!
//! ```zig
//! const s = try schema.compile(gpa, schema_json, .{});
//! defer s.deinit();
//! var out: schema.Output = .init(gpa);
//! defer out.deinit();
//! const ok = try schema.validate(s, gpa, args, &out);
//! ```
//!
//! `pattern` and `patternProperties` run on zg_regex with ECMA-262
//! compatibility (`ecma.zig`, the default `CompileOptions.regex`). A
//! pattern zg_regex cannot run (lookaround, backreferences) is kept as an
//! annotation and `Schema.warnings` says so, or rejected by option.

pub const Schema = @import("Schema.zig");
pub const NodeId = Schema.NodeId;
pub const Node = Schema.Node;
pub const Dialect = Schema.Dialect;
pub const Limits = Schema.Limits;
pub const RegexEngine = Schema.RegexEngine;
pub const RemoteRefFetcher = Schema.RemoteRefFetcher;
pub const Num = @import("number.zig").Num;
pub const formats = @import("formats.zig");
pub const ecma = @import("ecma.zig");
pub const FormatAssertion = formats.FormatAssertion;
pub const CompileOptions = @import("compile.zig").CompileOptions;
pub const CompileError = @import("compile.zig").CompileError;
pub const compile = @import("compile.zig").compile;
pub const Output = @import("validate.zig").Output;
pub const ValidateError = @import("validate.zig").ValidateError;
pub const validate = @import("validate.zig").validate;
pub const equal = @import("validate.zig").equal;

test {
    _ = @import("number.zig");
    _ = @import("formats.zig");
    _ = @import("ecma.zig");
    _ = @import("compile.zig");
    _ = @import("schema_test.zig");
    _ = @import("suite_test.zig");
}
