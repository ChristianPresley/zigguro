const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_perf_ui",
        .imports = &.{
            .{ .name = "zg_core", .module = b.dependency("zg_core", f.args()).module("zg_core") },
            .{ .name = "zg_perf", .module = b.dependency("zg_perf", f.args()).module("zg_perf") },
            .{ .name = "zg_gui", .module = b.dependency("zg_gui", f.args()).module("zg_gui") },
        },
        .bench = "bench/main.zig",
    });
}
