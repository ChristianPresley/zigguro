//! Per-Monitor V2 DPI arithmetic for the Win32 backend: scale factors and
//! logical ↔ physical sizes. Pure functions; the OS calls live in
//! `backend.zig`.

const std = @import("std");
const types = @import("../api/types.zig");
const default_dpi = @import("msgs.zig").default_dpi;

/// The scale factor for `dpi` (96 is 1.0).
pub fn scaleOf(dpi: u32) f32 {
    return @as(f32, @floatFromInt(@max(dpi, 1))) / @as(f32, default_dpi);
}

/// `logical` in physical pixels at `dpi`, rounding half away from zero.
pub fn toPhysical(logical: u32, dpi: u32) u32 {
    return @intCast((@as(u64, logical) * dpi + default_dpi / 2) / default_dpi);
}

/// `physical` in logical pixels at `dpi`, rounding half away from zero.
pub fn toLogical(physical: u32, dpi: u32) u32 {
    const d = @max(dpi, 1);
    return @intCast((@as(u64, physical) * default_dpi + d / 2) / d);
}

/// A size in logical pixels converted to physical pixels at `dpi`.
pub fn sizeToPhysical(s: types.PxSize, dpi: u32) types.PxSize {
    return .{ .w = toPhysical(s.w, dpi), .h = toPhysical(s.h, dpi) };
}

test "logical ↔ physical at common DPIs" {
    const dpis = [_]u32{ 96, 120, 144, 168, 192, 288 };
    const want = [_]u32{ 800, 1000, 1200, 1400, 1600, 2400 };
    for (dpis, want) |d, w| {
        try std.testing.expectEqual(w, toPhysical(800, d));
        try std.testing.expectEqual(@as(u32, 800), toLogical(w, d));
    }
    try std.testing.expectEqual(@as(f32, 1.5), scaleOf(144));
    try std.testing.expectEqual(@as(u32, 2), toPhysical(1, 168)); // 1.75 rounds up
    try std.testing.expectEqual(types.PxSize{ .w = 1920, .h = 1200 }, sizeToPhysical(.{ .w = 1280, .h = 800 }, 144));
}
