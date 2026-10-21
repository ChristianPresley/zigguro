//! zg_net benchmarks (`zig build bench`).

const std = @import("std");
const zg_core = @import("zg_core");
const bench = zg_core.bench;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    _ = b;
}
