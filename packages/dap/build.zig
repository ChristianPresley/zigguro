const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const jsonrpc = b.dependency("zg_jsonrpc", f.args()).module("zg_jsonrpc");
    const lsp = b.dependency("zg_lsp", f.args()).module("zg_lsp");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_dap",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_jsonrpc", .module = jsonrpc },
            .{ .name = "zg_lsp", .module = lsp },
        },
        .bench = "bench/main.zig",
        .test_exes = &.{.{
            .name = "fake_dap_adapter",
            .root = "testdata/fake_adapter.zig",
            .imports = &.{.{ .name = "zg_lsp", .module = lsp }},
        }},
    });
}
