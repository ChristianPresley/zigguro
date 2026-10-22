const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const jsonrpc = b.dependency("zg_jsonrpc", f.args()).module("zg_jsonrpc");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_lsp",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_jsonrpc", .module = jsonrpc },
        },
        .bench = "bench/main.zig",
        .test_exes = &.{.{
            .name = "fake_lsp_server",
            .root = "testdata/fake_server.zig",
            .imports = &.{.{ .name = "zg_jsonrpc", .module = jsonrpc }},
        }},
    });
}
