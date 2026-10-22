const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const jsonrpc = b.dependency("zg_jsonrpc", f.args()).module("zg_jsonrpc");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_config",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_jsonrpc", .module = jsonrpc },
        },
        .bench = "bench/main.zig",
    });
    // The extension SDK: the ZEP subset of zg_config as its own module, so
    // extension authors depend on the protocol and client only. Its tests
    // run with zg_config's.
    const sdk = b.addModule("zg_ext_sdk", .{
        .root_source_file = b.path("src/zep/root.zig"),
        .target = f.target,
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_jsonrpc", .module = jsonrpc },
        },
    });

    // ZEP example extension in Zig (`zig build examples`).
    const hello = b.addExecutable(.{ .name = "hello-zig", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/zep/hello_zig/main.zig"),
        .target = f.target,
        .optimize = f.optimize,
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_ext_sdk", .module = sdk },
        },
    }) });
    b.step("examples", "Build the ZEP example extensions").dependOn(&b.addInstallArtifact(hello, .{}).step);
}
