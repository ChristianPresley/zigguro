//! Benchmarks for zg_terminal; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const bench = zg_core.bench;
const throughput = @import("throughput.zig");
const screen_bench = @import("screen.zig");
const cold_bench = @import("cold.zig");

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try throughput.register(b);
    try screen_bench.register(b);
    try cold_bench.register(b);
}

test {
    _ = @import("corpus_gen.zig");
}
