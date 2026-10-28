const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const platform = b.dependency("zg_platform", f.args()).module("zg_platform");
    const text = b.dependency("zg_text", f.args()).module("zg_text");
    const vulkan = b.dependency("zg_vulkan", f.args()).module("zg_vulkan");
    const perf = b.dependency("zg_perf", f.args()).module("zg_perf");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_gui",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_platform", .module = platform },
            .{ .name = "zg_text", .module = text },
            .{ .name = "zg_vulkan", .module = vulkan },
            .{ .name = "zg_perf", .module = perf },
        },
        .bench = "bench/main.zig",
    });
}
