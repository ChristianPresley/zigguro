//! The types every image decoder shares (E04.F06.S02): a decoded image is
//! premultiplied sRGB RGBA8, rows top to bottom with no padding, the same
//! layout as E03's PNG decoder; animated formats add composed frames.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Format = enum { png, jpeg, gif, bmp, unknown };

/// Checked before anything big is allocated.
pub const Limits = struct {
    max_pixels: u64 = 100_000_000,
    max_frames: u32 = 2000,
    /// Input bytes, and for animations the decoded frames' bytes in all.
    max_bytes: u64 = 512 << 20,
};

pub const DecodeError = error{ Malformed, Unsupported, TooLarge, OutOfMemory };

/// One composed animation frame: the whole canvas (`w * h * 4` bytes)
/// and how long it shows. `x, y, w, h` name the rect the source frame
/// drew and `disposal` what it asked for after it (informational: the
/// pixels are already composed).
pub const Frame = struct {
    rgba: []u8,
    delay_ms: u32,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    disposal: Disposal = .none,

    pub const Disposal = enum { none, keep, background, previous };
};

pub const Image = struct {
    w: u32,
    h: u32,
    /// The image, or an animation's first frame (it aliases
    /// `frames[0].rgba` then).
    rgba: []u8,
    format: Format = .unknown,
    /// Composed frames when the image is animated (more than one frame).
    frames: []Frame = &.{},
    /// 0 loops forever.
    loop_count: u16 = 0,
    /// The input ended before the last frame; `frames` holds the ones
    /// decoded.
    truncated: bool = false,

    pub fn deinit(img: *Image, gpa: Allocator) void {
        if (img.frames.len > 0) {
            for (img.frames) |f| gpa.free(f.rgba);
            gpa.free(img.frames);
        } else gpa.free(img.rgba);
        img.* = undefined;
    }

    pub fn animated(img: *const Image) bool {
        return img.frames.len > 1;
    }
};

/// `w * h * 4`, or `TooLarge` past `limits` (checked for overflow).
pub fn pixelBytes(w: u32, h: u32, limits: Limits) DecodeError!usize {
    const px = std.math.mul(u64, w, h) catch return error.TooLarge;
    if (px > limits.max_pixels) return error.TooLarge;
    const bytes = std.math.mul(u64, px, 4) catch return error.TooLarge;
    return std.math.cast(usize, bytes) orelse error.TooLarge;
}

/// Premultiplies one straight-alpha channel value.
pub inline fn premul(c: u8, a: u8) u8 {
    return @intCast((@as(u32, c) * a + 127) / 255);
}

test "pixelBytes checks limits and overflow" {
    try std.testing.expectEqual(@as(usize, 16), try pixelBytes(2, 2, .{}));
    try std.testing.expectError(error.TooLarge, pixelBytes(20_000, 20_000, .{}));
    try std.testing.expectError(error.TooLarge, pixelBytes(std.math.maxInt(u32), std.math.maxInt(u32), .{ .max_pixels = std.math.maxInt(u64) }));
    try std.testing.expectEqual(@as(u8, 128), premul(255, 128));
}
