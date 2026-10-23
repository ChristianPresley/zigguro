const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const ai_dep = b.dependency("zg_ai", f.args());
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_agents",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_ai", .module = ai_dep.module("zg_ai") },
            .{ .name = "zg_ai_proto", .module = ai_dep.module("zg_ai_proto") },
        },
        .bench = "bench/main.zig",
    });
}
