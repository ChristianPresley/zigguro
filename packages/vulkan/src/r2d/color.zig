//! Colours: sRGB-encoded RGBA8. `DrawList` takes straight (unpremultiplied)
//! colours and stores them premultiplied; blending happens in sRGB-encoded
//! space (ADR-E02-007), like browsers do.

const std = @import("std");

/// An sRGB-encoded RGBA8 colour, packed little-endian as 0xAABBGGRR so that
/// its bytes in memory are r, g, b, a.
pub const Color = packed struct(u32) {
    /// Red.
    r: u8,
    /// Green.
    g: u8,
    /// Blue.
    b: u8,
    /// Alpha (255 = opaque).
    a: u8 = 255,

    /// Fully transparent.
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    /// Opaque black.
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    /// Opaque white.
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };

    /// The colour with r, g and b multiplied by alpha (rounded to nearest).
    pub fn premul(self: Color) Color {
        if (self.a == 255) return self;
        return .{ .r = mul8(self.r, self.a), .g = mul8(self.g, self.a), .b = mul8(self.b, self.a), .a = self.a };
    }

    /// The colour with its alpha multiplied by `opacity` (0..1).
    pub fn withOpacity(self: Color, opacity: f32) Color {
        const o = std.math.clamp(opacity, 0, 1);
        var c = self;
        c.a = @intFromFloat(@floor(@as(f32, @floatFromInt(self.a)) * o + 0.5));
        return c;
    }

    /// Parses "#rgb", "#rrggbb" or "#rrggbbaa" (the '#' is optional) at
    /// compile time.
    pub fn fromHex(comptime s: []const u8) Color {
        const c = comptime parseHex(s);
        return c;
    }

    /// The colour as a packed u32 (r in the low byte).
    pub fn toU32(self: Color) u32 {
        return @bitCast(self);
    }

    /// The colour unpacked from `toU32`.
    pub fn fromU32(v: u32) Color {
        return @bitCast(v);
    }

    /// Normalised channels r, g, b, a in 0..1.
    pub fn toF32(self: Color) [4]f32 {
        return .{ unorm(self.r), unorm(self.g), unorm(self.b), unorm(self.a) };
    }
};

/// `v / 255` as f32; the exact conversion both backends use.
pub fn unorm(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255.0;
}

/// Converts a normalised channel back to u8: clamp to 0..1, scale by 255
/// and round half up (the software renderer's store; GPUs round to nearest).
pub fn toUnorm8(v: f32) u8 {
    const c = std.math.clamp(v, 0, 1);
    return @intFromFloat(@floor(c * 255.0 + 0.5));
}

fn parseHex(comptime s: []const u8) Color {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
    return switch (h.len) {
        3 => .{ .r = nib(h[0]) * 17, .g = nib(h[1]) * 17, .b = nib(h[2]) * 17 },
        6 => .{ .r = byte(h[0..2]), .g = byte(h[2..4]), .b = byte(h[4..6]) },
        8 => .{ .r = byte(h[0..2]), .g = byte(h[2..4]), .b = byte(h[4..6]), .a = byte(h[6..8]) },
        else => @compileError("Color.fromHex: expected #rgb, #rrggbb or #rrggbbaa, got " ++ s),
    };
}

fn mul8(c: u8, a: u8) u8 {
    const p = @as(u32, c) * a + 127;
    return @intCast(p / 255);
}

fn nib(comptime ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => @compileError("Color.fromHex: bad hex digit"),
    };
}

fn byte(comptime s: *const [2]u8) u8 {
    return nib(s[0]) * 16 + nib(s[1]);
}

test "color: fromHex forms" {
    const c = Color.fromHex("#1e90ff");
    try std.testing.expectEqual(Color{ .r = 0x1e, .g = 0x90, .b = 0xff, .a = 255 }, c);
    try std.testing.expectEqual(Color{ .r = 0xff, .g = 0, .b = 0x11, .a = 255 }, Color.fromHex("f01"));
    try std.testing.expectEqual(@as(u8, 0x80), Color.fromHex("#00000080").a);
    try std.testing.expectEqual(@as(u32, 0xff112233), Color.fromHex("#332211").toU32());
}

test "color: premul rounds and keeps opaque" {
    try std.testing.expectEqual(Color.white, Color.white.premul());
    const half = (Color{ .r = 255, .g = 128, .b = 0, .a = 128 }).premul();
    try std.testing.expectEqual(Color{ .r = 128, .g = 64, .b = 0, .a = 128 }, half);
    try std.testing.expectEqual(Color.transparent, (Color{ .r = 9, .g = 9, .b = 9, .a = 0 }).premul());
}

test "color: unorm roundtrip is exact" {
    var i: u32 = 0;
    while (i < 256) : (i += 1) try std.testing.expectEqual(@as(u8, @intCast(i)), toUnorm8(unorm(@intCast(i))));
}
