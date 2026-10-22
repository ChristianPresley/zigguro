//! Geometry and colour value types shared by every zg_gui namespace.
//!
//! Coordinates are logical pixels (DIP) unless a name says `px`. `Color`
//! and `Radii` match the layout of E02's `r2d.Color` and `r2d.Radii` so the
//! DrawList adapter converts with a bit cast.

const std = @import("std");

/// A point or offset.
pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    /// Component-wise sum.
    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    /// Component-wise difference.
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
};

/// A width and height.
pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,
};

/// An axis-aligned rectangle: origin plus size.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    /// The empty rectangle at the origin.
    pub const empty: Rect = .{};

    /// A rectangle from its origin and size.
    pub fn fromSize(origin: Vec2, s: Size) Rect {
        return .{ .x = origin.x, .y = origin.y, .w = s.w, .h = s.h };
    }

    /// The right edge.
    pub fn right(r: Rect) f32 {
        return r.x + r.w;
    }

    /// The bottom edge.
    pub fn bottom(r: Rect) f32 {
        return r.y + r.h;
    }

    /// True when the rectangle covers no area.
    pub fn isEmpty(r: Rect) bool {
        return !(r.w > 0 and r.h > 0);
    }

    /// True when `p` is inside (left/top inclusive, right/bottom exclusive).
    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and p.y < r.y + r.h;
    }

    /// The overlap of `a` and `b`; empty when they do not overlap.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return .empty;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// The smallest rectangle covering both; an empty input is ignored.
    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.right(), b.right()) - x0, .h = @max(a.bottom(), b.bottom()) - y0 };
    }

    /// The rectangle moved by `d`.
    pub fn translate(r: Rect, d: Vec2) Rect {
        return .{ .x = r.x + d.x, .y = r.y + d.y, .w = r.w, .h = r.h };
    }

    /// The rectangle grown by `v` on every side (shrunk when negative).
    pub fn outset(r: Rect, v: f32) Rect {
        return .{ .x = r.x - v, .y = r.y - v, .w = @max(0, r.w + 2 * v), .h = @max(0, r.h + 2 * v) };
    }

    /// The rectangle shrunk by `in` (never below zero size).
    pub fn inset(r: Rect, in: Insets) Rect {
        return .{ .x = r.x + in.l, .y = r.y + in.t, .w = @max(0, r.w - in.l - in.r), .h = @max(0, r.h - in.t - in.b) };
    }

    /// Exact equality.
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }

    /// The rectangle as `[x, y, w, h]`.
    pub fn toArray(r: Rect) [4]f32 {
        return .{ r.x, r.y, r.w, r.h };
    }

    /// The rectangle from `[x, y, w, h]`.
    pub fn fromArray(a: [4]f32) Rect {
        return .{ .x = a[0], .y = a[1], .w = a[2], .h = a[3] };
    }
};

/// Per-edge distances: padding, margins, border widths.
pub const Insets = struct {
    l: f32 = 0,
    t: f32 = 0,
    r: f32 = 0,
    b: f32 = 0,

    /// The same value on every edge.
    pub fn all(v: f32) Insets {
        return .{ .l = v, .t = v, .r = v, .b = v };
    }

    /// `x` on the left and right, `y` on the top and bottom.
    pub fn xy(x: f32, y: f32) Insets {
        return .{ .l = x, .t = y, .r = x, .b = y };
    }

    /// Left plus right.
    pub fn horizontal(i: Insets) f32 {
        return i.l + i.r;
    }

    /// Top plus bottom.
    pub fn vertical(i: Insets) f32 {
        return i.t + i.b;
    }
};

/// Corner radii, clockwise from the top left.
pub const Radii = struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,

    /// The same radius on every corner.
    pub fn all(v: f32) Radii {
        return .{ .tl = v, .tr = v, .br = v, .bl = v };
    }
};

/// An sRGB-encoded, straight-alpha RGBA8 colour (E02 premultiplies on append).
pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Fully transparent black.
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// An opaque colour from `0xRRGGBB`.
    pub fn hex(rgb: u24) Color {
        return .{ .r = @truncate(rgb >> 16), .g = @truncate(rgb >> 8), .b = @truncate(rgb), .a = 255 };
    }

    /// A colour from `0xRRGGBBAA`.
    pub fn hexa(rgba: u32) Color {
        return .{ .r = @truncate(rgba >> 24), .g = @truncate(rgba >> 16), .b = @truncate(rgba >> 8), .a = @truncate(rgba) };
    }

    /// The colour with alpha multiplied by `f` (0..1).
    pub fn fade(c: Color, f: f32) Color {
        var out = c;
        out.a = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(c.a)) * f, 0, 255));
        return out;
    }

    /// Linear interpolation in sRGB space: `t = 0` is `a`, `t = 1` is `b`.
    pub fn lerp(a: Color, b: Color, t: f32) Color {
        const tt = std.math.clamp(t, 0, 1);
        return .{
            .r = mix(a.r, b.r, tt),
            .g = mix(a.g, b.g, tt),
            .b = mix(a.b, b.b, tt),
            .a = mix(a.a, b.a, tt),
        };
    }

    fn mix(x: u8, y: u8, t: f32) u8 {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        return @intFromFloat(@round(fx + (fy - fx) * t));
    }

    /// Equality.
    pub fn eql(a: Color, b: Color) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }

    /// Relative luminance per WCAG 2.x (0 = black, 1 = white).
    pub fn luminance(c: Color) f64 {
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }

    fn channel(v: u8) f64 {
        const s = @as(f64, @floatFromInt(v)) / 255.0;
        return if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
    }

    /// The WCAG contrast ratio between two opaque colours (1..21).
    pub fn contrast(a: Color, b: Color) f64 {
        const la = a.luminance();
        const lb = b.luminance();
        return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
    }
};

test "rect intersect and unite" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: Rect = .{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try std.testing.expect(a.intersect(b).eql(.{ .x = 5, .y = 5, .w = 5, .h = 5 }));
    try std.testing.expect(a.unite(b).eql(.{ .x = 0, .y = 0, .w = 15, .h = 15 }));
    try std.testing.expect(a.intersect(.{ .x = 20, .y = 0, .w = 1, .h = 1 }).isEmpty());
    try std.testing.expect(Rect.empty.unite(b).eql(b));
    try std.testing.expect(a.contains(.{ .x = 0, .y = 9.5 }));
    try std.testing.expect(!a.contains(.{ .x = 10, .y = 0 }));
}

test "color hex, lerp and contrast" {
    const c = Color.hex(0x336699);
    try std.testing.expectEqual(@as(u8, 0x33), c.r);
    try std.testing.expectEqual(@as(u8, 0x99), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
    const h = Color.hexa(0x11223344);
    try std.testing.expectEqual(@as(u8, 0x44), h.a);
    try std.testing.expect(Color.lerp(Color.hex(0), Color.hex(0xffffff), 1).eql(Color.hex(0xffffff)));
    const ratio = Color.contrast(Color.hex(0x000000), Color.hex(0xffffff));
    try std.testing.expectApproxEqAbs(@as(f64, 21), ratio, 0.01);
}
