const std = @import("std");
const zg_build = @import("zg_build");
const ucdgen = @import("ucdgen");

/// Vendored UCD version under ucd/; bumping it is this one-line change.
const ucd_version = "18.0.0";

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");

    // Unicode tables: ucdgen turns ucd/<version>/*.txt into ucd.bin plus
    // ucd_tables.zig. Each input is a file argument so caching is exact.
    const ucd = b.dependency("ucdgen", .{});
    const gen = b.addRunArtifact(ucd.artifact("ucdgen"));
    gen.addArgs(&.{ "--version", ucd_version, "--manifest" });
    gen.addFileArg(b.path("ucd/" ++ ucd_version ++ "/manifest.zon"));
    inline for (ucdgen.files) |rel| gen.addFileArg(b.path("ucd/" ++ ucd_version ++ "/" ++ rel));
    const out = gen.addOutputDirectoryArg("ucd");
    const tables = b.createModule(.{ .root_source_file = out.path(b, "ucd_tables.zig") });

    const text = zg_build.addPackage(b, f, .{
        .name = "zg_text",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "ucd_tables", .module = tables },
            .{ .name = "ucd_enums", .module = ucd.module("ucd_enums") },
            // The uncompressed reference builder; referenced only by tests.
            .{ .name = "ucdgen_ref", .module = ucd.module("ucdgen_ref") },
        },
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
