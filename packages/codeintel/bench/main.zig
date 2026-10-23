//! Benchmarks for zg_codeintel; run with `zig build bench` at the repo root.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_codeintel = @import("zg_codeintel");
const bench = zg_core.bench;
const State = bench.State;
const Registry = zg_codeintel.registry.Registry;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("codeintel.registry.discover: 6 builtin servers, 6-entry PATH, cold cache", {}, discover);
}

/// A typical PATH; most builtin servers are absent, so every entry is
/// probed for them (the slow case). Budget: < 20 ms per discovery.
const path_var = if (builtin.os.tag == .windows)
    "C:\\Windows\\system32;C:\\Windows;C:\\Windows\\System32\\Wbem;C:\\Program Files\\Git\\cmd;C:\\Users\\Default\\AppData\\Local\\Microsoft\\WindowsApps;C:\\zig"
else
    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

fn discover(_: void, s: *State) void {
    const gpa = s.allocator();
    const io = s.ioHandle();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    env.put("PATH", path_var) catch unreachable;
    var r = Registry.init(gpa, .{}) catch unreachable;
    defer r.deinit();
    var found: usize = 0;
    for (0..s.iterations()) |_| {
        r.rescan();
        for (r.defs) |*d| {
            if (r.resolveExecutable(io, d, &env) catch unreachable) |_| found += 1;
        }
    }
    bench.doNotOptimizeAway(found);
}
