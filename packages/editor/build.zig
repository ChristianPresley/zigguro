const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const text = b.dependency("zg_text", f.args()).module("zg_text");
    const regex = b.dependency("zg_regex", f.args()).module("zg_regex");
    const syntax = b.dependency("zg_syntax", f.args()).module("zg_syntax");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_editor",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_text", .module = text },
            .{ .name = "zg_regex", .module = regex },
            .{ .name = "zg_syntax", .module = syntax },
        },
        .bench = "bench/main.zig",
    });
}
