const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const text = zg_build.addPackage(b, f, .{
        .name = "zg_text",
        .imports = &.{.{ .name = "zg_core", .module = core }},
        .bench = "bench/main.zig",
    });

    // `zig build text-dump -- <subcommand> ...` (run from packages/text).
    const dump = b.addExecutable(.{
        .name = "text-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dev/text_dump.zig"),
            .target = f.target,
            .optimize = f.optimize,
            .imports = &.{.{ .name = "zg_text", .module = text }},
        }),
    });
    b.installArtifact(dump);
    const run = b.addRunArtifact(dump);
    run.setCwd(b.path("."));
    if (b.args) |a| run.addArgs(a);
    b.step("text-dump", "Dump metrics/outlines/shaping/raster goldens (args after --)").dependOn(&run.step);
}
