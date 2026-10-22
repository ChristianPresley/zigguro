//! Benchmarks for zg_ai; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const bench = zg_core.bench;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("noop", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) bench.doNotOptimizeAway(i);
        }
    }.f);
}
