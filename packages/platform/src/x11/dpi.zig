//! X11 scale discovery: `ZG_SCALE` from the environment, else `Xft.dpi`
//! from the root window's RESOURCE_MANAGER string, else 1.0. EDID-derived
//! DPI is opt-in (E01.F05.S02.T01) and not done here.

const std = @import("std");

/// The DPI value of the `Xft.dpi:` line in an X resource string.
pub fn parseXftDpi(resources: []const u8) ?f32 {
    var lines = std.mem.splitScalar(u8, resources, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Xft.dpi")) continue;
        const rest = std.mem.trimStart(u8, line["Xft.dpi".len..], " \t");
        if (rest.len == 0 or rest[0] != ':') continue;
        const v = std.mem.trim(u8, rest[1..], " \t");
        const dpi = std.fmt.parseFloat(f32, v) catch continue;
        if (dpi > 0 and std.math.isFinite(dpi)) return dpi;
    }
    return null;
}

/// The scale factor for `dpi`, rounded to quarters and clamped to 1..4.
pub fn scaleForDpi(dpi: f32) f32 {
    const s = @round(dpi / 96.0 * 4.0) / 4.0;
    return std.math.clamp(s, 1.0, 4.0);
}

/// The scale from `ZG_SCALE` (any positive number up to 8), if set.
pub fn envScale(env: ?*const std.process.Environ.Map) ?f32 {
    const e = env orelse return null;
    const v = e.get("ZG_SCALE") orelse return null;
    const s = std.fmt.parseFloat(f32, v) catch return null;
    return if (s > 0 and s <= 8) s else null;
}

test "Xft.dpi parse from resource string" {
    try std.testing.expectEqual(@as(?f32, 192), parseXftDpi("Xft.antialias:\t1\nXft.dpi:\t192\nXft.hinting:\t1\n"));
    try std.testing.expectEqual(@as(?f32, 120), parseXftDpi("Xft.dpi : 120"));
    try std.testing.expectEqual(@as(?f32, null), parseXftDpi("Xft.dpix:\t96\n"));
    try std.testing.expectEqual(@as(?f32, null), parseXftDpi("Xft.dpi:\tlots\n"));
    try std.testing.expectEqual(@as(?f32, null), parseXftDpi(""));
}

test "scaleForDpi rounds and clamps" {
    try std.testing.expectEqual(@as(f32, 1.0), scaleForDpi(96));
    try std.testing.expectEqual(@as(f32, 1.25), scaleForDpi(120));
    try std.testing.expectEqual(@as(f32, 2.0), scaleForDpi(192));
    try std.testing.expectEqual(@as(f32, 1.0), scaleForDpi(72));
    try std.testing.expectEqual(@as(f32, 4.0), scaleForDpi(1000));
}

test "envScale" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(@as(?f32, null), envScale(&env));
    try env.put("ZG_SCALE", "1.5");
    try std.testing.expectEqual(@as(?f32, 1.5), envScale(&env));
    try env.put("ZG_SCALE", "-2");
    try std.testing.expectEqual(@as(?f32, null), envScale(&env));
    try std.testing.expectEqual(@as(?f32, null), envScale(null));
}
