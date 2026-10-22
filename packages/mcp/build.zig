const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const jsonrpc = b.dependency("zg_jsonrpc", f.args()).module("zg_jsonrpc");
    const net = b.dependency("zg_net", f.args()).module("zg_net");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_mcp",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_jsonrpc", .module = jsonrpc },
            .{ .name = "zg_net", .module = net },
        },
        .bench = "bench/main.zig",
    });
}
