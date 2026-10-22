//! An 8-bit, four-channel image in CPU memory: render targets of the
//! software renderer, readback results, decoded PNGs and goldens.

const std = @import("std");

const CpuImage = @This();

/// Channel order of each pixel in memory.
pub const Order = enum {
    /// r, g, b, a.
    rgba,
    /// b, g, r, a (DRM ARGB8888 / Win32 DIB order).
    bgra,
};

/// Width in pixels.
width: u32,
/// Height in pixels.
height: u32,
/// Bytes per row (at least `width * 4`).
stride: u32,
/// `stride * height` bytes.
pixels: []u8,
/// Channel order.
order: Order = .rgba,

/// A zeroed (transparent) RGBA image.
pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !CpuImage {
    return initOrder(gpa, w, h, .rgba);
}

/// A zeroed image with the given channel order.
pub fn initOrder(gpa: std.mem.Allocator, w: u32, h: u32, order: Order) !CpuImage {
    const n = @as(usize, w) * h * 4;
    const px = try gpa.alloc(u8, n);
    @memset(px, 0);
    return .{ .width = w, .height = h, .stride = w * 4, .pixels = px, .order = order };
}

/// Frees the pixels.
pub fn deinit(self: *CpuImage, gpa: std.mem.Allocator) void {
    gpa.free(self.pixels);
    self.* = undefined;
}

/// The pixel at `(x, y)` as r, g, b, a.
pub fn get(self: *const CpuImage, x: u32, y: u32) [4]u8 {
    const i = @as(usize, y) * self.stride + @as(usize, x) * 4;
    const p = self.pixels[i..][0..4];
    return switch (self.order) {
        .rgba => p.*,
        .bgra => .{ p[2], p[1], p[0], p[3] },
    };
}

/// Sets the pixel at `(x, y)` from r, g, b, a.
pub fn set(self: *CpuImage, x: u32, y: u32, rgba: [4]u8) void {
    const i = @as(usize, y) * self.stride + @as(usize, x) * 4;
    const p = self.pixels[i..][0..4];
    p.* = switch (self.order) {
        .rgba => rgba,
        .bgra => .{ rgba[2], rgba[1], rgba[0], rgba[3] },
    };
}

/// Fills every pixel with `rgba`.
pub fn fill(self: *CpuImage, rgba: [4]u8) void {
    var y: u32 = 0;
    while (y < self.height) : (y += 1) {
        var x: u32 = 0;
        while (x < self.width) : (x += 1) self.set(x, y, rgba);
    }
}

test "cpu image: get/set honour channel order" {
    const gpa = std.testing.allocator;
    var a = try CpuImage.initOrder(gpa, 2, 2, .bgra);
    defer a.deinit(gpa);
    a.set(1, 1, .{ 1, 2, 3, 4 });
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, a.get(1, 1));
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4 }, a.pixels[12..16]);
}
