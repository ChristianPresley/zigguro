//! DRM fourcc codes for our colour formats, and the modifier negotiation
//! between the compositor's list (E01 `Presenter.formats`) and what the
//! device can render to and export (E02.F04.S02.T01). Pure.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const platform = @import("zg_platform");

/// `fourcc_code(a, b, c, d)` from drm_fourcc.h.
pub fn fourcc(code: *const [4]u8) u32 {
    return std.mem.readInt(u32, code, .little);
}

/// [31:0] B:G:R:A little endian (bytes B, G, R, A).
pub const argb8888 = fourcc("AR24");
/// [31:0] B:G:R:x little endian.
pub const xrgb8888 = fourcc("XR24");
/// [31:0] R:G:B:A little endian (bytes R, G, B, A).
pub const abgr8888 = fourcc("AB24");
/// [31:0] R:G:B:x little endian.
pub const xbgr8888 = fourcc("XB24");

pub const mod_linear: u64 = 0;
/// The "implicit modifier" marker; never chosen explicitly.
pub const mod_invalid: u64 = 0x00ff_ffff_ffff_ffff;

/// The fourcc for `f`; `opaque_alpha` picks the X variant.
pub fn vkFormatToFourcc(f: vk.Format, opaque_alpha: bool) ?u32 {
    return switch (f) {
        .b8g8r8a8_unorm, .b8g8r8a8_srgb => if (opaque_alpha) xrgb8888 else argb8888,
        .r8g8b8a8_unorm, .r8g8b8a8_srgb => if (opaque_alpha) xbgr8888 else abgr8888,
        else => null,
    };
}

/// The colour format for `code` (either alpha variant).
pub fn fourccToVkFormat(code: u32) ?vk.Format {
    if (code == argb8888 or code == xrgb8888) return .b8g8r8a8_unorm;
    if (code == abgr8888 or code == xbgr8888) return .r8g8b8a8_unorm;
    return null;
}

/// What the device reports for one modifier of the format.
pub const DeviceModifier = struct {
    modifier: u64,
    planes: u32,
    color_attachment: bool,
    /// Exportable as a dmabuf at the requested size (image format query).
    exportable: bool = true,
};

/// The modifiers to offer `vkCreateImage`, best first: those the
/// compositor lists for `code` (in its order: scanout tranche first),
/// that the device renders to with one plane and can export. Returns the
/// count written to `out`; 0 means the export path is unusable.
pub fn negotiate(code: u32, compositor: []const platform.surface.FormatModifier, device: []const DeviceModifier, out: []u64) usize {
    var n: usize = 0;
    for (compositor) |fm| {
        if (fm.fourcc != code or fm.modifier == mod_invalid) continue;
        const ok = for (device) |d| {
            if (d.modifier == fm.modifier) break d.color_attachment and d.planes == 1 and d.exportable;
        } else false;
        if (!ok) continue;
        if (std.mem.indexOfScalar(u64, out[0..n], fm.modifier) != null) continue;
        if (n == out.len) break;
        out[n] = fm.modifier;
        n += 1;
    }
    return n;
}

test "drm: vkFormat<->fourcc table" {
    try std.testing.expectEqual(@as(u32, 0x34325241), argb8888);
    try std.testing.expectEqual(@as(u32, 0x34325258), xrgb8888);
    try std.testing.expectEqual(@as(u32, 0x34324241), abgr8888);
    try std.testing.expectEqual(@as(?u32, argb8888), vkFormatToFourcc(.b8g8r8a8_unorm, false));
    try std.testing.expectEqual(@as(?u32, xrgb8888), vkFormatToFourcc(.b8g8r8a8_unorm, true));
    try std.testing.expectEqual(@as(?u32, abgr8888), vkFormatToFourcc(.r8g8b8a8_unorm, false));
    try std.testing.expectEqual(@as(?u32, null), vkFormatToFourcc(.r8_unorm, false));
    for ([_]u32{ argb8888, xrgb8888, abgr8888, xbgr8888 }) |c| {
        const f = fourccToVkFormat(c).?;
        const back = vkFormatToFourcc(f, c == xrgb8888 or c == xbgr8888).?;
        try std.testing.expectEqual(c, back);
    }
}

test "drm: modifier intersection ordering" {
    const x_tiled: u64 = 0x0100_0000_0000_0001;
    const y_tiled: u64 = 0x0100_0000_0000_0002;
    const ccs: u64 = 0x0100_0000_0000_0004;
    // Compositor order: scanout tranche (y, ccs) then the rest.
    const comp = [_]platform.surface.FormatModifier{
        .{ .fourcc = argb8888, .modifier = y_tiled },
        .{ .fourcc = argb8888, .modifier = ccs },
        .{ .fourcc = xrgb8888, .modifier = x_tiled },
        .{ .fourcc = argb8888, .modifier = mod_invalid },
        .{ .fourcc = argb8888, .modifier = mod_linear },
        .{ .fourcc = argb8888, .modifier = x_tiled },
        .{ .fourcc = argb8888, .modifier = y_tiled }, // repeated in a later tranche
    };
    const dev = [_]DeviceModifier{
        .{ .modifier = mod_linear, .planes = 1, .color_attachment = true },
        .{ .modifier = x_tiled, .planes = 1, .color_attachment = true },
        .{ .modifier = y_tiled, .planes = 1, .color_attachment = true },
        .{ .modifier = ccs, .planes = 2, .color_attachment = true }, // multi-plane: skipped
    };
    var out: [8]u64 = undefined;
    const n = negotiate(argb8888, &comp, &dev, &out);
    try std.testing.expectEqualSlices(u64, &.{ y_tiled, mod_linear, x_tiled }, out[0..n]);

    // Not exportable or not renderable: dropped.
    const dev2 = [_]DeviceModifier{
        .{ .modifier = mod_linear, .planes = 1, .color_attachment = false },
        .{ .modifier = y_tiled, .planes = 1, .color_attachment = true, .exportable = false },
    };
    try std.testing.expectEqual(@as(usize, 0), negotiate(argb8888, &comp, &dev2, &out));
    // Empty compositor list: nothing.
    try std.testing.expectEqual(@as(usize, 0), negotiate(argb8888, &.{}, &dev, &out));
}
