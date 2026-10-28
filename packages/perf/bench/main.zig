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
    try b.run("perf.shadow_push_pop", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var st: zg_perf.runtime.ShadowStack = .{};
            const site = zg_core.trace.siteFor(@src(), "bench");
            for (0..s.iterations()) |_| {
                st.push(site);
                st.pop();
            }
            bench.doNotOptimizeAway(&st);
        }
    }.f);
    // With -Dtracing=zones: a zone with and without the shadow-stack hook
    // (the difference is the hook's cost, budget < 5 ns).
    try b.run("perf.zone_no_hook", {}, struct {
        fn f(_: void, s: *bench.State) void {
            for (0..s.iterations()) |_| zg_core.trace.zone(@src(), "bench").end();
            drainTrace();
        }
    }.f);
    try b.run("perf.zone_hook_overhead", {}, struct {
        fn f(_: void, s: *bench.State) void {
            _ = zg_perf.runtime.shadow_stack.enableForCurrentThread();
            defer zg_core.trace.zone_hook = null;
            for (0..s.iterations()) |_| zg_core.trace.zone(@src(), "bench").end();
            drainTrace();
        }
    }.f);
    try b.run("perf.activity_level", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var sig: zg_perf.ActivitySignal = .{};
            sig.publish(.interactive, 1000);
            var x: usize = 0;
            for (0..s.iterations()) |_| x += @intFromEnum(sig.publishedLevel());
            bench.doNotOptimizeAway(x);
        }
    }.f);
    try b.run("perf.budget_by_id", {}, struct {
        fn f(_: void, s: *bench.State) void {
            for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_perf.budget.byId("agents.notification_route"));
        }
    }.f);
}

/// Keeps the trace rings from filling (dropped events are cheaper and
/// would flatter the zone benches).
fn drainTrace() void {
    if (!zg_core.trace.enabled) return;
    var events: std.ArrayList(zg_core.trace.Event) = .empty;
    defer events.deinit(std.heap.page_allocator);
    zg_core.trace.collect(std.heap.page_allocator, &events) catch {};
}
