const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const wl_gen = zg_build.waylandModule(b, f, &wayland_protocols);
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_platform",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "wl_gen", .module = wl_gen },
        },
        .bench = "bench/main.zig",
    });
}

/// The vendored protocols compiled into `wl_gen` (see protocols/wayland/SOURCES.md).
const wayland_protocols = [_][]const u8{
    "protocols/wayland/wayland.xml",
    "protocols/wayland/xdg-shell.xml",
    "protocols/wayland/xdg-decoration-unstable-v1.xml",
    "protocols/wayland/fractional-scale-v1.xml",
    "protocols/wayland/viewporter.xml",
    "protocols/wayland/text-input-unstable-v3.xml",
    "protocols/wayland/primary-selection-unstable-v1.xml",
    "protocols/wayland/tablet-v2.xml",
    "protocols/wayland/cursor-shape-v1.xml",
    "protocols/wayland/linux-dmabuf-v1.xml",
    "protocols/wayland/linux-drm-syncobj-v1.xml",
    "protocols/wayland/presentation-time.xml",
    "protocols/wayland/xdg-activation-v1.xml",
    "protocols/wayland/xdg-foreign-unstable-v2.xml",
};
