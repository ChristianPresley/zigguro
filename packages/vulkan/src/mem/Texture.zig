//! Sampled textures and render targets (E02.F03.S02.T01).

const Texture = @This();

const std = @import("std");
const vk = @import("../vk/vk.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const types = @import("types.zig");
const barriers = @import("barriers.zig");

/// Texture formats zigguro uses.
pub const Format = enum(u8) {
    /// Grayscale glyph coverage.
    r8_unorm,
    /// Subpixel coverage (RGB in .rgb), linear images.
    rgba8_unorm,
    /// Colour emoji and images (premultiplied, sRGB-encoded).
    rgba8_srgb,
    /// Swapchain and layer targets.
    bgra8_unorm,

    pub fn vkFormat(f: Format) vk.Format {
        return switch (f) {
            .r8_unorm => .r8_unorm,
            .rgba8_unorm => .r8g8b8a8_unorm,
            .rgba8_srgb => .r8g8b8a8_srgb,
            .bgra8_unorm => .b8g8r8a8_unorm,
        };
    }

    /// The view format. Shaders blend in sRGB-encoded space (as the
    /// software renderer does), so sRGB images are viewed as UNORM and
    /// sampling never linearises.
    pub fn viewFormat(f: Format) vk.Format {
        return switch (f) {
            .rgba8_srgb => .r8g8b8a8_unorm,
            else => f.vkFormat(),
        };
    }

    /// The view swizzle: r8 replicates coverage into every channel, as
    /// the software renderer's `texel` does.
    pub fn swizzle(f: Format) vk.ComponentMapping {
        return switch (f) {
            .r8_unorm => .{ .r = .r, .g = .r, .b = .r, .a = .r },
            else => .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        };
    }

    pub fn bytesPerTexel(f: Format) u32 {
        return switch (f) {
            .r8_unorm => 1,
            .rgba8_unorm, .rgba8_srgb, .bgra8_unorm => 4,
        };
    }
};

pub const Use = enum { sampled, render_target };

image: types.Image,
view: vk.ImageView,
format: Format,
width: u32,
height: u32,
/// Bindless index (assigned by E02.F06).
slot: u32 = std.math.maxInt(u32),
/// Where the last recorded use left the image.
access: barriers.Access = .undefined,

/// Largest supported side (`Rect16` coordinates).
pub const max_side = 16384;

/// Creates a `w`×`h` texture with a view. Sampled textures can be
/// uploaded to (TRANSFER_DST) and read back (TRANSFER_SRC); render
/// targets are color attachments that can also be sampled.
pub fn create(mem: *DeviceMemory, w: u32, h: u32, fmt: Format, use: Use, name: [:0]const u8) !Texture {
    if (w == 0 or h == 0 or w > max_side or h > max_side) return error.InvalidSize;
    const usage: vk.ImageUsageFlags = switch (use) {
        .sampled => .{ .sampled = true, .transfer_dst = true, .transfer_src = true },
        .render_target => .{ .color_attachment = true, .sampled = true, .transfer_src = true, .transfer_dst = true },
    };
    const img = try mem.createImage(.{
        .flags = .{ .mutable_format = fmt.viewFormat() != fmt.vkFormat() },
        .image_type = .@"2d",
        .format = fmt.vkFormat(),
        .extent = .{ .width = w, .height = h, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, .gpu_only, name, false);
    errdefer mem.destroyImage(img);
    const gpu = mem.gpu;
    var view: vk.ImageView = .null_handle;
    _ = try vk.check(gpu.ddisp.create_image_view(gpu.dev, &.{
        .image = img.handle,
        .view_type = .@"2d",
        .format = fmt.viewFormat(),
        .components = fmt.swizzle(),
        .subresource_range = barriers.color_range,
    }, null, &view));
    gpu.name(view, name);
    return .{ .image = img, .view = view, .format = fmt, .width = w, .height = h };
}

pub fn destroy(self: *Texture, mem: *DeviceMemory) void {
    mem.gpu.ddisp.destroy_image_view(mem.gpu.dev, self.view, null);
    mem.destroyImage(self.image);
    self.* = undefined;
}
