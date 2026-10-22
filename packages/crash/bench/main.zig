//! zg_crash benchmarks (`zig build bench`). Budget: `annotations.set` < 100 ns.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_crash = @import("zg_crash");
const bench = zg_core.bench;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("annotations: set", {}, set);
    try b.run("format: write 20 KiB report", {}, writeReport);
}

fn set(_: void, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) zg_crash.annotations.set("ui.view", "editor:main.zig");
}

var out_buf: [64 * 1024]u8 = undefined;
var w_buf: [32 * 1024]u8 = undefined;

fn writeReport(_: void, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var ms: zg_crash.format.MemorySink = .{ .buf = &out_buf };
        var w: zg_crash.format.Writer = .{ .buf = &w_buf, .sink = ms.sink() };
        w.begin(0);
        var l = w.section(.log);
        for (0..20) |_| l.write(&@as([1024]u8, @splat('x')));
        l.end();
        w.finish();
        bench.doNotOptimizeAway(ms.len);
    }
}
