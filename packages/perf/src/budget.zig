//! The budget registry and its checks (E14.F01.S01).

/// The `budgets.zon` schema.
pub const schema = @import("budget/schema.zig");
/// The embedded, comptime-validated registry.
pub const registry = @import("budget/registry.zig");
/// Evaluation of observations against budgets.
pub const check = @import("budget/check.zig");
/// Binding of E00 bench JSON results to budgets.
pub const bench_bind = @import("budget/bench_bind.zig");
/// The `docs/perf/budgets.md` renderer.
pub const docgen = @import("budget/docgen.zig");

/// One budget row.
pub const Budget = schema.Budget;
/// Comptime budget lookup (a compile error for an unknown id).
pub const get = registry.get;
/// Runtime budget lookup.
pub const byId = registry.byId;
/// Every budget.
pub const all = registry.all;
/// Evaluation verdict.
pub const Verdict = check.Verdict;
/// Evaluates an observation against a budget.
pub const evaluate = check.evaluate;
/// Test helper asserting an observation stays within a budget.
pub const expectWithin = check.expectWithin;
