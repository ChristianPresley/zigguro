const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    // zg_ignore (E08.F01.S02): std only, no imports at all, so zg-git and
    // zg-scm can depend on it without pulling in the workspace.
    const ignore = b.addModule("zg_ignore", .{
        .root_source_file = b.path("src/ignore/root.zig"),
        .target = f.target,
    });
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_workspace",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_ignore", .module = ignore },
        },
        .bench = "bench/main.zig",
    });
}
