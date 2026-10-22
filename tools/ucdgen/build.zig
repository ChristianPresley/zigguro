//! ucdgen: the build-time UCD table generator (E03.F05.S01.T01). Exports
//! the `ucdgen` executable (always built for the host, ReleaseSafe) and the
//! `ucd_enums` module shared with zg_text, plus `ucdgen_ref`, the
//! uncompressed table builder that zg_text's tests compare against.

const std = @import("std");

/// The UCD input files in the order `ucdgen` expects them (for build scripts).
pub const files = @import("src/tables.zig").files;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enums = b.addModule("ucd_enums", .{ .root_source_file = b.path("src/enums.zig") });
    _ = b.addModule("ucdgen_ref", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{.{ .name = "ucd_enums", .module = enums }},
    });

    const exe = b.addExecutable(.{
        .name = "ucdgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "ucd_enums", .module = enums }},
        }),
    });
    b.installArtifact(exe);

    const run_enums = b.addRunArtifact(exe);
    run_enums.addArg("enums");
    if (b.args) |a| run_enums.addArgs(a);
    b.step("enums", "Print the enums.zig enum block (args: PropertyValueAliases.txt)").dependOn(&run_enums.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ucd_enums", .module = enums }},
    }) });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run ucdgen's unit tests").dependOn(&run_tests.step);
}
