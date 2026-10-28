//! Benchmarks for zg_perf; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_perf = @import("zg_perf");
const bench = zg_core.bench;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("perf.budget_evaluate", {}, struct {
        fn f(_: void, s: *bench.State) void {
            const budget = zg_perf.budget.get("input.key_to_photon");
            var x: f64 = 0;
            for (0..s.iterations()) |i| {
                x += @floatFromInt(@intFromEnum(zg_perf.budget.evaluate(budget, @floatFromInt(i & 0xffffff), 1.0).verdict));
            }
            bench.doNotOptimizeAway(x);
        }
    }.f);
    try b.run("perf.budget_by_id", {}, struct {
        fn f(_: void, s: *bench.State) void {
            for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_perf.budget.byId("agents.notification_route"));
        }
    }.f);
}
