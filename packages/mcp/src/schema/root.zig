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
//! `pattern` and `patternProperties` need a regex engine
//! (`CompileOptions.regex`, zg_regex once E05.F03 lands, #61); without one
//! they are annotations and `Schema.warnings` says so.

pub const Schema = @import("Schema.zig");
pub const NodeId = Schema.NodeId;
pub const Node = Schema.Node;
pub const Dialect = Schema.Dialect;
pub const Limits = Schema.Limits;
pub const RegexEngine = Schema.RegexEngine;
pub const RemoteRefFetcher = Schema.RemoteRefFetcher;
pub const Num = @import("number.zig").Num;
pub const formats = @import("formats.zig");
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
    _ = @import("compile.zig");
    _ = @import("schema_test.zig");
    _ = @import("suite_test.zig");
}
