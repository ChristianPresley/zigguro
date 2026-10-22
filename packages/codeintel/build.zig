const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const lsp = b.dependency("zg_lsp", f.args()).module("zg_lsp");
    const editor = b.dependency("zg_editor", f.args()).module("zg_editor");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_codeintel",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_lsp", .module = lsp },
            .{ .name = "zg_editor", .module = editor },
        },
        .bench = "bench/main.zig",
    });
}
