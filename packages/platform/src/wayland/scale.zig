//! Scale arithmetic for Wayland surfaces. Scales are kept in 1/120 units,
//! as `wp_fractional_scale_v1.preferred_scale` reports them; integer
//! scales (`wl_output.scale`, `wl_surface.preferred_buffer_scale`) are
//! multiplied by 120.

const std = @import("std");
const types = @import("../api/types.zig");
const PxSize = types.PxSize;

/// Scale 1.0 in 1/120 units.
pub const unit: u32 = 120;

/// How a surface's scale reaches the compositor.
pub const Mode = enum {
    /// `wp_viewport.set_destination(logical)` with `set_buffer_scale(1)`.
    viewport,
    /// `wl_surface.set_buffer_scale(n)`; only whole scales.
    buffer_scale,
};

/// `round_half_away_from_zero(v * scale120 / 120)` for one dimension.
pub fn scaleDim(v: u32, scale120: u32) u32 {
    const num = @as(u64, v) * scale120;
    return @intCast((num + unit / 2) / unit);
}

/// The buffer size for a surface of `logical` size at `scale120`.
pub fn bufferSize(logical: PxSize, scale120: u32) PxSize {
    return .{ .w = scaleDim(logical.w, scale120), .h = scaleDim(logical.h, scale120) };
}

/// The logical size that a buffer of `px` covers at `scale120` (rounded
/// to nearest), at least 1x1.
pub fn logicalSize(px: PxSize, scale120: u32) PxSize {
    const s = @max(scale120, 1);
    return .{
        .w = @max(1, @as(u32, @intCast((@as(u64, px.w) * unit + s / 2) / s))),
        .h = @max(1, @as(u32, @intCast((@as(u64, px.h) * unit + s / 2) / s))),
    };
}

/// The factor reported in `Scale`.
pub fn factor(scale120: u32) types.Scale {
    return .{ .factor = @as(f32, @floatFromInt(scale120)) / @as(f32, @floatFromInt(unit)) };
}

/// The integer buffer scale for `scale120` in `buffer_scale` mode (rounded
/// up, so text is never upscaled by the compositor), at least 1.
pub fn integerScale(scale120: u32) i32 {
    return @intCast(@max(1, (scale120 + unit - 1) / unit));
}

/// The scale a surface uses: the fractional preference when the compositor
/// sent one, else `preferred_buffer_scale`, else the largest scale of the
/// outputs the surface is on, else 1.
pub fn choose(fractional: ?u32, preferred_buffer: ?i32, max_output: ?i32) u32 {
    if (fractional) |f| if (f > 0) return f;
    if (preferred_buffer) |p| if (p > 0) return @as(u32, @intCast(p)) * unit;
    if (max_output) |o| if (o > 0) return @as(u32, @intCast(o)) * unit;
    return unit;
}

const testing = std.testing;

test "fractional 180 → buffer 150x75 for 100x50" {
    try testing.expectEqual(PxSize{ .w = 150, .h = 75 }, bufferSize(.{ .w = 100, .h = 50 }, 180));
    try testing.expectEqual(@as(f32, 1.5), factor(180).factor);
}

test "rounding is half away from zero" {
    // 125%: 101 * 1.25 = 126.25 → 126; 102 * 1.25 = 127.5 → 128.
    try testing.expectEqual(@as(u32, 126), scaleDim(101, 150));
    try testing.expectEqual(@as(u32, 128), scaleDim(102, 150));
    // 175%: 3 * 1.75 = 5.25 → 5; 2 * 1.75 = 3.5 → 4.
    try testing.expectEqual(@as(u32, 5), scaleDim(3, 210));
    try testing.expectEqual(@as(u32, 4), scaleDim(2, 210));
    try testing.expectEqual(@as(u32, 0), scaleDim(0, 210));
}

test "logical size inverts buffer size" {
    try testing.expectEqual(PxSize{ .w = 100, .h = 50 }, logicalSize(.{ .w = 150, .h = 75 }, 180));
    try testing.expectEqual(PxSize{ .w = 1, .h = 1 }, logicalSize(.{ .w = 0, .h = 0 }, 240));
}

test "scale preference order" {
    try testing.expectEqual(@as(u32, 150), choose(150, 2, 3));
    try testing.expectEqual(@as(u32, 240), choose(null, 2, 3));
    try testing.expectEqual(@as(u32, 360), choose(null, null, 3));
    try testing.expectEqual(@as(u32, 120), choose(null, null, null));
    try testing.expectEqual(@as(u32, 120), choose(0, 0, 0));
    try testing.expectEqual(@as(i32, 2), integerScale(150));
    try testing.expectEqual(@as(i32, 1), integerScale(120));
}
