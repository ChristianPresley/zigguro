const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    // Only the std-only zg_ignore leaf (wildmatch and ignore rules).
    const ignore = b.dependency("zg_workspace", f.args()).module("zg_ignore");
    // Smart HTTP(S) remotes.
    const net = b.dependency("zg_net", f.args()).module("zg_net");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_git",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_ignore", .module = ignore },
            .{ .name = "zg_net", .module = net },
        },
        .bench = "bench/main.zig",
    });
}
