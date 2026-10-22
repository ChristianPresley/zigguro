const std = @import("std");
const zg_build = @import("zg_build");
const ucdgen = @import("ucdgen");

/// UCD version of the vendored files under packages/text/ucd/ (shared with
/// zg_text; bumping Unicode updates both).
const ucd_version = "18.0.0";
const ucd_dir = "../text/ucd/" ++ ucd_version ++ "/";

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");

    // Unicode property, script and case-fold tables: `ucdgen regex` turns
    // the vendored UCD into regex_tables.zig. Each input is a file argument
    // so caching is exact.
    const ucd = b.dependency("ucdgen", .{});
    const gen = b.addRunArtifact(ucd.artifact("ucdgen"));
    gen.addArgs(&.{ "regex", "--version", ucd_version, "--manifest" });
    gen.addFileArg(b.path(ucd_dir ++ "manifest.zon"));
    inline for (ucdgen.regex_files) |rel| gen.addFileArg(b.path(ucd_dir ++ rel));
    const out = gen.addOutputDirectoryArg("regex_ucd");
    const tables = b.createModule(.{ .root_source_file = out.path(b, "regex_tables.zig") });

    _ = zg_build.addPackage(b, f, .{
        .name = "zg_regex",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "regex_tables", .module = tables },
        },
        .bench = "bench/main.zig",
    });
}
