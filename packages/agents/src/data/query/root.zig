//! The data query language (E13.F06.S02.T01): a pipe-separated query
//! (`from x | where … | group … | sort … | limit n`) parsed, type checked
//! and planned against dataset schemas. See docs/formats/data-query.md.

pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const types = @import("types.zig");
pub const plan = @import("plan.zig");

pub const Ast = ast.Ast;
pub const Diagnostic = ast.Diagnostic;
pub const parse = parser.parse;
pub const formatQuery = parser.formatQuery;
pub const Plan = plan.Plan;
pub const Catalog = plan.Catalog;

/// The language in brief, for tool descriptions (the full reference is
/// docs/formats/data-query.md; a test keeps the names here in sync with
/// `types.Func` and `types.Agg`).
pub const tool_summary =
    \\Query language: stages joined by `|`:
    \\  from NAME | where EXPR | derive c = EXPR, ... | select EXPR or c = EXPR, ...
    \\  | group k1, k2 { c = AGG, ... } | sort -c, c2 | limit N | sample N
    \\  | join NAME on col == other_col [left]
    \\Expressions: + - * / %, == != < <= > >=, and or not, x in [..],
    \\x between a and b, x is [not] null, case when .. then .. else .. end.
    \\Literals: 42, 1.5, "text", true, null, 2025-01-31, 2025-01-31T10:00:00Z.
    \\Names with spaces or keywords go in `backticks`.
    \\Functions: lower upper contains starts_with ends_with length substr
    \\regex_match year month day trunc(d, "month") date_diff abs round floor
    \\ceil log sqrt coalesce.
    \\Aggregates (group only): count() count(x) count_distinct sum avg min max
    \\median p(x, 0.95) stddev.
    \\Errors read "message at start..end" (byte offsets in the query).
;

test "tool_summary names every function and aggregate" {
    const std = @import("std");
    inline for (@typeInfo(types.Func).@"enum".fields) |f|
        try std.testing.expect(std.mem.indexOf(u8, tool_summary, f.name) != null);
    inline for (@typeInfo(types.Agg).@"enum".fields) |f|
        try std.testing.expect(std.mem.indexOf(u8, tool_summary, f.name) != null);
}
