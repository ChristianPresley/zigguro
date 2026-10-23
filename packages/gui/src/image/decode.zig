//! The decode façade (E04.F06.S02.T01): sniffs the format and hands the
//! bytes to E03's PNG decoder or to the GIF, BMP and JPEG decoders here.
//! Every decoder returns premultiplied sRGB RGBA8 and checks `Limits`
//! before it allocates.

const std = @import("std");
const zg_text = @import("zg_text");
const image = @import("image.zig");
const gif = @import("gif.zig");
const bmp = @import("bmp.zig");

const Allocator = std.mem.Allocator;
const Image = image.Image;
const Format = image.Format;
const Limits = image.Limits;
const DecodeError = image.DecodeError;

/// The format from the first bytes.
pub fn sniff(bytes: []const u8) Format {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return .jpeg;
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .gif;
    if (bytes.len >= 14 and bytes[0] == 'B' and bytes[1] == 'M') return .bmp;
    return .unknown;
}

/// Decodes `bytes` at full size.
pub fn decode(gpa: Allocator, bytes: []const u8, limits: Limits) DecodeError!Image {
    if (bytes.len > limits.max_bytes) return error.TooLarge;
    return switch (sniff(bytes)) {
        .png => {
            const max: u32 = @intCast(@min(limits.max_pixels, std.math.maxInt(u32)));
            const p = try zg_text.raster.png.decode(gpa, bytes, max);
            return .{ .w = p.w, .h = p.h, .rgba = p.rgba, .format = .png };
        },
        .gif => gif.decodeGif(gpa, bytes, limits),
        .bmp => bmp.decodeBmp(gpa, bytes, limits),
        .jpeg, .unknown => error.Unsupported,
    };
}

const testing = std.testing;

test "sniff" {
    try testing.expectEqual(Format.png, sniff("\x89PNG\r\n\x1a\nrest"));
    try testing.expectEqual(Format.jpeg, sniff("\xFF\xD8\xFF\xE0"));
    try testing.expectEqual(Format.gif, sniff("GIF89a......"));
    try testing.expectEqual(Format.bmp, sniff("BM" ++ "\x00" ** 12));
    try testing.expectEqual(Format.unknown, sniff("hello"));
    try testing.expectEqual(Format.unknown, sniff(""));
}

test "unknown and oversized input" {
    try testing.expectError(error.Unsupported, decode(testing.allocator, "not an image", .{}));
    try testing.expectError(error.TooLarge, decode(testing.allocator, "GIF89a" ++ "\x00" ** 20, .{ .max_bytes = 8 }));
}
