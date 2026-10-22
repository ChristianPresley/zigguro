//! Textures of the software renderer: plain CPU pixel arrays. Atlas pages,
//! images and layers all live here.

const std = @import("std");
const r2d = @import("../r2d/root.zig");

/// A texture in CPU memory. `rgba8` texels are premultiplied.
pub const CpuTexture = struct {
    /// Width in texels.
    width: u32,
    /// Height in texels.
    height: u32,
    /// Bytes per row.
    stride: u32,
    /// Texel format.
    format: r2d.TextureFormat,
    /// `stride * height` bytes.
    pixels: []u8,

    /// A zeroed texture.
    pub fn init(gpa: std.mem.Allocator, desc: r2d.TextureDesc) !CpuTexture {
        const stride = desc.width * desc.format.bytesPerTexel();
        const px = try gpa.alloc(u8, @as(usize, stride) * desc.height);
        @memset(px, 0);
        return .{ .width = desc.width, .height = desc.height, .stride = stride, .format = desc.format, .pixels = px };
    }

    /// Frees the texels.
    pub fn deinit(t: *CpuTexture, gpa: std.mem.Allocator) void {
        gpa.free(t.pixels);
        t.* = undefined;
    }

    /// Copies `rect` from `data` (`row_pitch` bytes per row).
    pub fn update(t: *CpuTexture, rect: r2d.PxRect, data: []const u8, row_pitch: u32) r2d.RenderError!void {
        if (rect.x < 0 or rect.y < 0) return error.InvalidArgument;
        const x: u32 = @intCast(rect.x);
        const y: u32 = @intCast(rect.y);
        if (@as(u64, x) + rect.w > t.width or @as(u64, y) + rect.h > t.height) return error.InvalidArgument;
        const bpt = t.format.bytesPerTexel();
        const row_bytes = rect.w * bpt;
        if (rect.h == 0 or rect.w == 0) return;
        if (row_pitch < row_bytes or data.len < @as(usize, row_pitch) * (rect.h - 1) + row_bytes) return error.InvalidArgument;
        var r: u32 = 0;
        while (r < rect.h) : (r += 1) {
            const dst = t.pixels[@as(usize, y + r) * t.stride + @as(usize, x) * bpt ..][0..row_bytes];
            @memcpy(dst, data[@as(usize, r) * row_pitch ..][0..row_bytes]);
        }
    }

    /// Zeroes `rect` (clipped to the texture).
    pub fn clear(t: *CpuTexture, rect: r2d.PxRect) void {
        const c = r2d.DrawList.clipPx(rect, .{ .w = t.width, .h = t.height }) orelse return;
        const bpt = t.format.bytesPerTexel();
        var r: u32 = 0;
        while (r < c.h) : (r += 1) {
            const off = @as(usize, @as(u32, @intCast(c.y)) + r) * t.stride + @as(usize, @intCast(c.x)) * bpt;
            @memset(t.pixels[off..][0 .. c.w * bpt], 0);
        }
    }
};

test "texture: update bounds checked" {
    const gpa = std.testing.allocator;
    var t = try CpuTexture.init(gpa, .{ .width = 4, .height = 4, .format = .r8 });
    defer t.deinit(gpa);
    try t.update(.{ .x = 1, .y = 1, .w = 2, .h = 2 }, &.{ 1, 2, 9, 3, 4 }, 3);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 4, 0 }, t.pixels[0..12]);
    try std.testing.expectError(error.InvalidArgument, t.update(.{ .x = 3, .y = 0, .w = 2, .h = 1 }, &.{ 1, 2 }, 2));
    try std.testing.expectError(error.InvalidArgument, t.update(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, &.{ 1, 2 }, 2));
    t.clear(.{ .x = 0, .y = 0, .w = 9, .h = 2 });
    try std.testing.expectEqual(@as(u8, 3), t.pixels[9]);
    try std.testing.expectEqual(@as(u8, 0), t.pixels[5]);
}
