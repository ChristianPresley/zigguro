//! Swapchain parameter choices (E02.F04.S01.T01): present mode, image
//! count, surface format, composite alpha and extent. Pure functions over
//! the surface's capabilities, so they are tested without a window.

const std = @import("std");
const vk = @import("../vk/vk.zig");

/// What the user and the window ask of presentation.
pub const PresentPrefs = struct {
    pub const Mode = enum { auto, fifo, fifo_latest_ready, mailbox, immediate };
    mode: Mode = .auto,
    /// Prefer the lowest-latency vsynced mode (FIFO_LATEST_READY).
    low_latency: bool = true,
    /// The E01 window is transparent (premultiplied composite alpha).
    transparent: bool = false,
};

fn has(modes: []const vk.PresentModeKHR, m: vk.PresentModeKHR) bool {
    return std.mem.indexOfScalar(vk.PresentModeKHR, modes, m) != null;
}

/// The present mode for `prefs` among `supported` (FIFO is always
/// supported). `auto` never picks MAILBOX or IMMEDIATE.
pub fn presentMode(prefs: PresentPrefs, supported: []const vk.PresentModeKHR) vk.PresentModeKHR {
    const want: vk.PresentModeKHR = switch (prefs.mode) {
        .auto => if (prefs.low_latency and has(supported, .fifo_latest_ready)) .fifo_latest_ready else .fifo,
        .fifo => .fifo,
        .fifo_latest_ready => .fifo_latest_ready,
        .mailbox => .mailbox,
        .immediate => .immediate,
    };
    return if (has(supported, want)) want else .fifo;
}

/// `max(min + 1, 3)` images, clamped to `max` (0 = unbounded).
pub fn imageCount(min: u32, max: u32) u32 {
    const n = @max(min + 1, 3);
    return if (max != 0) @min(n, max) else n;
}

/// B8G8R8A8_UNORM, then R8G8B8A8_UNORM, in the sRGB-nonlinear colour
/// space (we blend in sRGB-encoded space, ADR-E02-007, so `_SRGB` formats
/// are not wanted). Null when neither is offered.
pub fn surfaceFormat(formats: []const vk.SurfaceFormatKHR) ?vk.SurfaceFormatKHR {
    for ([_]vk.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm }) |f| {
        for (formats) |sf| if (sf.format == f and sf.color_space == .srgb_nonlinear) return sf;
    }
    return null;
}

/// OPAQUE, or PRE_MULTIPLIED for a transparent window when supported;
/// else whatever the surface supports.
pub fn compositeAlpha(supported: vk.CompositeAlphaFlagsKHR, transparent: bool) vk.CompositeAlphaFlagBitsKHR {
    if (transparent and supported.pre_multiplied) return .{ .pre_multiplied = true };
    if (supported.@"opaque") return .{ .@"opaque" = true };
    if (supported.pre_multiplied) return .{ .pre_multiplied = true };
    if (supported.inherit) return .{ .inherit = true };
    return .{ .post_multiplied = true };
}

/// The swapchain extent: the surface's current extent, or `want` clamped
/// to the limits when the surface leaves it to us (0xFFFFFFFF). 0×0 means
/// minimised.
pub fn extent(caps: vk.SurfaceCapabilitiesKHR, want: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    return .{
        .width = std.math.clamp(want.width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(want.height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

/// Buffer age per swapchain image: frames since its contents were
/// presented (0 = unknown, after creation or recreate).
pub const Ages = struct {
    pub const max_images = 8;
    last: [max_images]u64 = @splat(0),
    frame: u64 = 0,

    pub fn age(self: *const Ages, i: u32) u32 {
        if (i >= max_images or self.last[i] == 0) return 0;
        return @intCast(@min(self.frame + 1 - self.last[i], std.math.maxInt(u32)));
    }

    pub fn presented(self: *Ages, i: u32) void {
        self.frame += 1;
        if (i < max_images) self.last[i] = self.frame;
    }

    pub fn reset(self: *Ages) void {
        self.last = @splat(0);
    }
};

const testing = std.testing;

test "swapchain: present mode choice table" {
    const all = [_]vk.PresentModeKHR{ .immediate, .mailbox, .fifo, .fifo_relaxed, .fifo_latest_ready };
    const basic = [_]vk.PresentModeKHR{ .fifo, .mailbox, .immediate };
    const fifo_only = [_]vk.PresentModeKHR{.fifo};
    try testing.expectEqual(vk.PresentModeKHR.fifo_latest_ready, presentMode(.{}, &all));
    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(.{}, &basic));
    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(.{ .low_latency = false }, &all));
    // auto never picks mailbox or immediate.
    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(.{}, &.{ .mailbox, .immediate, .fifo }));
    try testing.expectEqual(vk.PresentModeKHR.mailbox, presentMode(.{ .mode = .mailbox }, &basic));
    try testing.expectEqual(vk.PresentModeKHR.immediate, presentMode(.{ .mode = .immediate }, &basic));
    // An unsupported choice falls back to FIFO.
    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(.{ .mode = .mailbox }, &fifo_only));
    try testing.expectEqual(vk.PresentModeKHR.fifo, presentMode(.{ .mode = .fifo_latest_ready }, &basic));
}

test "swapchain: image count clamp" {
    try testing.expectEqual(@as(u32, 3), imageCount(1, 0));
    try testing.expectEqual(@as(u32, 3), imageCount(2, 8));
    try testing.expectEqual(@as(u32, 4), imageCount(3, 0));
    try testing.expectEqual(@as(u32, 2), imageCount(2, 2));
    try testing.expectEqual(@as(u32, 3), imageCount(2, 3));
}

test "swapchain: format, alpha and extent" {
    const fmts = [_]vk.SurfaceFormatKHR{
        .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear },
        .{ .format = .r8g8b8a8_unorm, .color_space = .srgb_nonlinear },
        .{ .format = .b8g8r8a8_unorm, .color_space = .srgb_nonlinear },
    };
    try testing.expectEqual(vk.Format.b8g8r8a8_unorm, surfaceFormat(&fmts).?.format);
    try testing.expectEqual(vk.Format.r8g8b8a8_unorm, surfaceFormat(fmts[0..2]).?.format);
    try testing.expectEqual(@as(?vk.SurfaceFormatKHR, null), surfaceFormat(fmts[0..1]));

    try testing.expect(compositeAlpha(.{ .@"opaque" = true, .pre_multiplied = true }, false).@"opaque");
    try testing.expect(compositeAlpha(.{ .@"opaque" = true, .pre_multiplied = true }, true).pre_multiplied);
    try testing.expect(compositeAlpha(.{ .@"opaque" = true }, true).@"opaque");
    try testing.expect(compositeAlpha(.{ .inherit = true }, false).inherit);

    var caps: vk.SurfaceCapabilitiesKHR = .{ .current_extent = .{ .width = 800, .height = 600 }, .min_image_extent = .{ .width = 1, .height = 1 }, .max_image_extent = .{ .width = 4096, .height = 4096 } };
    try testing.expectEqual(vk.Extent2D{ .width = 800, .height = 600 }, extent(caps, .{ .width = 10, .height = 10 }));
    caps.current_extent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) };
    try testing.expectEqual(vk.Extent2D{ .width = 4096, .height = 10 }, extent(caps, .{ .width = 9000, .height = 10 }));
}

test "swapchain: image ages" {
    var a: Ages = .{};
    try testing.expectEqual(@as(u32, 0), a.age(0));
    a.presented(0);
    a.presented(1);
    a.presented(2);
    try testing.expectEqual(@as(u32, 3), a.age(0));
    try testing.expectEqual(@as(u32, 1), a.age(2));
    a.reset();
    try testing.expectEqual(@as(u32, 0), a.age(2));
}
