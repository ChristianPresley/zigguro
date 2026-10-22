//! zg_vulkan: zigguro's GPU layer and 2D renderer (epic E02, #3).
//! `r2d` is the backend-agnostic contract E04 draws through.

const std = @import("std");

/// The backend-agnostic 2D rendering contract.
pub const r2d = @import("r2d/root.zig");
/// GPU memory management.
pub const mem = @import("mem/root.zig");
/// The software renderer.
pub const sw = @import("sw/root.zig");
/// Images, PNG, image diffs and golden-image tests.
pub const testing = @import("testing/root.zig");
/// Vulkan bindings generated from vk.xml by `tools/vkgen`.
pub const vk = @import("vk/vk.zig");
/// The runtime Vulkan loader and dispatch tables.
pub const loader = @import("loader/root.zig");

/// Creates the renderer for `opts`: Vulkan when chosen (or `auto`) and
/// available, otherwise the software renderer. The Vulkan backend lands
/// with E02.F06.S01.T02; until then `.vulkan` fails with
/// `error.VulkanUnavailable` and `.auto` falls back to software.
pub fn createRenderer(gpa: std.mem.Allocator, io: std.Io, opts: r2d.RendererOptions) !r2d.Renderer {
    switch (opts.backend) {
        .vulkan => return error.VulkanUnavailable,
        .auto, .software => {},
    }
    const s = try sw.SwRenderer.create(gpa, io, opts);
    return s.renderer();
}

test "renderer: auto falls back to software" {
    var sink: @import("zg_platform").surface.HeadlessSink = .{ .ptr = undefined, .write = undefined };
    const r = try createRenderer(std.testing.allocator, std.testing.io, .{ .target = .{ .headless = &sink } });
    defer r.deinit();
    try std.testing.expectEqual(r2d.Backend.software, r.backend());
    try std.testing.expectError(error.VulkanUnavailable, createRenderer(std.testing.allocator, std.testing.io, .{ .target = .{ .headless = &sink }, .backend = .vulkan }));
}

test {
    std.testing.refAllDecls(@This());
    _ = r2d;
    _ = testing;
    _ = sw;
    _ = loader;
    _ = @import("vk/check.zig");
    _ = mem;
}
