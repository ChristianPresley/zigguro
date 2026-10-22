const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const mod = zg_build.addPackage(b, f, .{
        .name = "zg_terminal",
        .imports = &.{.{ .name = "zg_core", .module = core }},
        .bench = "bench/main.zig",
    });

    // Reference-table generator (the root `docs-terminal-modes` step runs it).
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_docs.zig"),
        .target = f.target,
        .optimize = .Debug,
    });
    docs_mod.addImport("zg_terminal", mod);
    b.installArtifact(b.addExecutable(.{ .name = "zg_terminal-docs", .root_module = docs_mod }));
}
