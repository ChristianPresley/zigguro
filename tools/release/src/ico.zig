//! A Windows `.ico` writer: ICONDIR, one ICONDIRENTRY per image, then the
//! images, each embedded as PNG (accepted by Windows Vista and later, and
//! by Zig's resource compiler).

const std = @import("std");

pub const Image = struct { size: u16, png: []const u8 };

pub fn write(w: *std.Io.Writer, images: []const Image) !void {
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 1, .little); // type: icon
    try w.writeInt(u16, @intCast(images.len), .little);
    var offset: u32 = @intCast(6 + 16 * images.len);
    for (images) |img| {
        std.debug.assert(img.size >= 1 and img.size <= 256);
        const dim: u8 = if (img.size == 256) 0 else @intCast(img.size);
        try w.writeAll(&.{ dim, dim, 0, 0 }); // width, height, colours, reserved
        try w.writeInt(u16, 1, .little); // planes
        try w.writeInt(u16, 32, .little); // bits per pixel
        try w.writeInt(u32, @intCast(img.png.len), .little);
        try w.writeInt(u32, offset, .little);
        offset += @intCast(img.png.len);
    }
    for (images) |img| try w.writeAll(img.png);
}

test "ico: header layout" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, &.{ .{ .size = 16, .png = "AB" }, .{ .size = 256, .png = "CDE" } });
    const dir = [_]u8{ 0, 0, 1, 0, 2, 0 };
    const e16 = [_]u8{ 16, 16, 0, 0, 1, 0, 32, 0, 2, 0, 0, 0, 38, 0, 0, 0 }; // at 38
    const e256 = [_]u8{ 0, 0, 0, 0, 1, 0, 32, 0, 3, 0, 0, 0, 40, 0, 0, 0 }; // at 40
    const want = dir ++ e16 ++ e256 ++ "ABCDE".*;
    try std.testing.expectEqualSlices(u8, &want, w.buffered());
}
