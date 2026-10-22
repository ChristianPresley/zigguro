const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const platform = b.dependency("zg_platform", f.args()).module("zg_platform");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_vulkan",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_platform", .module = platform },
        },
        .bench = "bench/main.zig",
    });
}
