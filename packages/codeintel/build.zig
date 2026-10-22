const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const lsp_dep = b.dependency("zg_lsp", f.args());
    const lsp = lsp_dep.module("zg_lsp");
    const jsonrpc = b.dependency("zg_jsonrpc", f.args()).module("zg_jsonrpc");
    const editor = b.dependency("zg_editor", f.args()).module("zg_editor");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_codeintel",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_lsp", .module = lsp },
            .{ .name = "zg_editor", .module = editor },
        },
        .bench = "bench/main.zig",
        // zg_lsp's scripted server plays the language servers in tests.
        .test_exes = &.{.{
            .name = "fake_lsp_server",
            .root_file = lsp_dep.path("testdata/fake_server.zig"),
            .imports = &.{
                .{ .name = "zg_lsp", .module = lsp },
                .{ .name = "zg_jsonrpc", .module = jsonrpc },
            },
        }},
    });
}
