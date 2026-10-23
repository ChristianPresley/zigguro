//! Benchmarks for zg_codeintel; run with `zig build bench` at the repo root.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_codeintel = @import("zg_codeintel");
const zg_syntax = @import("zg_syntax");
const bench = zg_core.bench;
const State = bench.State;
const Registry = zg_codeintel.registry.Registry;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("codeintel.registry.discover: 6 builtin servers, 6-entry PATH, cold cache", {}, discover);
    try b.run("codeintel.semtok.decode_200k: full result, 20k lines x 10 tokens", {}, decode200k);
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

const line_text = "word word word word word word word word word word";

fn sameLine(_: *const anyopaque, _: u64, _: *std.ArrayList(u8), _: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    return line_text;
}

/// Decoding a 200k-token full result into the overlay. Budget: < 5 ms.
fn decode200k(_: void, s: *State) void {
    const gpa = s.allocator();
    const lines = 20_000;
    const data = gpa.alloc(u32, lines * 10 * 5) catch unreachable;
    defer gpa.free(data);
    for (0..lines * 10) |i| {
        const first = i % 10 == 0;
        data[i * 5 ..][0..5].* = .{ @intFromBool(first and i > 0), if (first) 0 else 5, 4, @intCast(i % 3), @intCast(i % 2) };
    }
    var names: zg_syntax.HighlightNames = .init(gpa);
    defer names.deinit();
    var legend = (zg_syntax.SemanticLegend{ .types = &.{ "variable", "function", "type" }, .modifiers = &.{"readonly"} }).compile(gpa, &names) catch unreachable;
    defer legend.deinit();
    const src: zg_syntax.LineSource = .{ .ctx = &names, .lines = lines + 1, .getFn = sameLine };
    for (0..s.iterations()) |i| {
        var o = zg_syntax.SemanticOverlay.init(gpa, lines + 1, 1) catch unreachable;
        defer o.deinit();
        o.enc = .utf8;
        const ok = o.applyFull(1, "r", data, &legend, src) catch unreachable;
        bench.doNotOptimizeAway(ok);
        bench.doNotOptimizeAway(i);
    }
}
