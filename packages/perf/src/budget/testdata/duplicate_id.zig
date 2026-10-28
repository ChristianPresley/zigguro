//! Compile-error fixture for `zig build test-perf-compile-errors`: a
//! registry with a duplicate id must fail `validate`.

const zg_perf = @import("zg_perf");
const schema = zg_perf.budget.schema;

const row: schema.Budget = .{ .id = "a.b", .owner = "E14", .spec = "E14", .metric = .count, .stat = .max, .limit = 1, .source = .{ .runtime = "pending" } };

comptime {
    zg_perf.budget.registry.validate(.{ .schema = 1, .machines = &.{}, .budgets = &.{ row, row } });
}

test {}
