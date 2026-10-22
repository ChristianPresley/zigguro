//! Per-pixel image comparison with tolerances, plus a diff visualisation.

const std = @import("std");
const CpuImage = @import("CpuImage.zig");

/// How different two images may be and still match.
pub const Tolerance = struct {
    /// Largest per-channel difference that still counts as equal.
    max_channel_diff: u8 = 0,
    /// Pixels allowed to exceed `max_channel_diff`.
    max_bad_pixels: u32 = 0,
    /// Ignore the alpha channel.
    ignore_alpha: bool = false,

    /// The preset used when comparing GPU output with software goldens:
    /// at most 2 per channel on all but 0.1% of the pixels.
    pub fn gpu(width: u32, height: u32) Tolerance {
        const area = @as(u64, width) * height;
        return .{ .max_channel_diff = 2, .max_bad_pixels = @intCast(area / 1000) };
    }
};

/// The outcome of `diff`.
pub const DiffResult = struct {
    /// Largest per-channel difference seen.
    max_diff: u8,
    /// Pixels whose difference exceeds the tolerance.
    bad_pixels: u32,
    /// Visualisation (when requested): `a` in gray at 30% plus red = 8×diff.
    diff_image: ?CpuImage,
    /// Whether the images match under the tolerance.
    pass: bool,

    /// Frees the diff image.
    pub fn deinit(self: *DiffResult, gpa: std.mem.Allocator) void {
        if (self.diff_image) |*d| d.deinit(gpa);
        self.* = undefined;
    }
};

/// Compares `a` and `b`. Images of different sizes never match (every
/// pixel counts as bad).
pub fn diff(gpa: std.mem.Allocator, a: *const CpuImage, b: *const CpuImage, tol: Tolerance, want_image: bool) !DiffResult {
    if (a.width != b.width or a.height != b.height) {
        return .{ .max_diff = 255, .bad_pixels = std.math.maxInt(u32), .diff_image = null, .pass = false };
    }
    var out: ?CpuImage = if (want_image) try CpuImage.init(gpa, a.width, a.height) else null;
    errdefer if (out) |*o| o.deinit(gpa);
    var max_diff: u8 = 0;
    var bad: u32 = 0;
    const channels: usize = if (tol.ignore_alpha) 3 else 4;
    var y: u32 = 0;
    while (y < a.height) : (y += 1) {
        var x: u32 = 0;
        while (x < a.width) : (x += 1) {
            const pa = a.get(x, y);
            const pb = b.get(x, y);
            var d: u8 = 0;
            for (0..channels) |c| d = @max(d, if (pa[c] > pb[c]) pa[c] - pb[c] else pb[c] - pa[c]);
            max_diff = @max(max_diff, d);
            if (d > tol.max_channel_diff) bad += 1;
            if (out) |*o| {
                const lum: u32 = (@as(u32, pa[0]) * 54 + @as(u32, pa[1]) * 183 + @as(u32, pa[2]) * 19) >> 8;
                const base: u8 = @intCast(lum * 3 / 10);
                const red: u8 = @intCast(@min(@as(u32, base) + @as(u32, d) * 8, 255));
                o.set(x, y, .{ red, base, base, 255 });
            }
        }
    }
    return .{ .max_diff = max_diff, .bad_pixels = bad, .diff_image = out, .pass = bad <= tol.max_bad_pixels };
}

test "diff: tolerance boundaries" {
    const gpa = std.testing.allocator;
    var a = try CpuImage.init(gpa, 4, 4);
    defer a.deinit(gpa);
    var b = try CpuImage.init(gpa, 4, 4);
    defer b.deinit(gpa);
    a.fill(.{ 100, 100, 100, 255 });
    b.fill(.{ 100, 100, 100, 255 });
    b.set(1, 1, .{ 102, 100, 100, 255 });
    b.set(2, 2, .{ 100, 103, 100, 255 });
    {
        var r = try diff(gpa, &a, &b, .{}, false);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 2), r.bad_pixels);
        try std.testing.expectEqual(@as(u8, 3), r.max_diff);
        try std.testing.expect(!r.pass);
    }
    {
        var r = try diff(gpa, &a, &b, .{ .max_channel_diff = 2 }, false);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 1), r.bad_pixels);
        try std.testing.expect(!r.pass);
    }
    {
        var r = try diff(gpa, &a, &b, .{ .max_channel_diff = 2, .max_bad_pixels = 1 }, true);
        defer r.deinit(gpa);
        try std.testing.expect(r.pass);
        try std.testing.expectEqual(@as(u8, 30 + 24), r.diff_image.?.get(2, 2)[0]);
    }
    b.set(3, 3, .{ 100, 100, 100, 0 });
    {
        var r = try diff(gpa, &a, &b, .{ .max_channel_diff = 3, .ignore_alpha = true }, false);
        defer r.deinit(gpa);
        try std.testing.expect(r.pass);
    }
    try std.testing.expectEqual(@as(u32, 16), Tolerance.gpu(4000, 4).max_bad_pixels);
}
