const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const release = b.dependency("zg_release", f.args()).module("zg_release");
    // Crash helpers are built like release binaries: optimized, LLVM (the
    // self-hosted aarch64 backend traps before the segfault hook), frame
    // pointers kept and a GNU build id.
    const crasher_imports: []const std.Build.Module.Import = &.{.{ .name = "zg_core", .module = core }};
    const build_id: ?std.zig.BuildId = if (f.target.result.ofmt == .elf) .sha1 else null;
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_crash",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_release", .module = release },
        },
        .bench = "bench/main.zig",
        .test_exes = &.{
            .{ .name = "crasher_fast", .root = "test/crasher.zig", .imports = crasher_imports, .optimize = .ReleaseFast, .build_id = build_id, .use_llvm = true, .omit_frame_pointer = false },
            .{ .name = "crasher_safe", .root = "test/crasher.zig", .imports = crasher_imports, .optimize = .ReleaseSafe, .build_id = build_id, .use_llvm = true, .omit_frame_pointer = false },
        },
    });
}
