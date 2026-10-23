//! Display lists (E13.F07.S01.T02): what a vector canvas recorded, ready
//! to rasterize in tiles or write as SVG. Strokes keep both their
//! outline (what tiles fill) and the original path and style (what SVG
//! writes as a native stroke).

const std = @import("std");
const path_mod = @import("path.zig");
const stroke_mod = @import("stroke.zig");

const Path = path_mod.Path;
const Rect = path_mod.Rect;

/// sRGB with straight alpha.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(hex: u24) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex) };
    }

    pub fn withAlpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }
};

pub const Anchor = enum { start, middle, end };
pub const Baseline = enum { alphabetic, middle, top, bottom };
/// Text rotation: none, or −90° (reading upwards, for vertical axis
/// titles).
pub const Rotation = enum { none, ccw90 };

pub const Text = struct {
    x: f32,
    y: f32,
    text: []const u8,
    size: f32 = 12,
    color: Color = .{ .r = 0, .g = 0, .b = 0 },
    anchor: Anchor = .start,
    baseline: Baseline = .alphabetic,
    rotate: Rotation = .none,
    bold: bool = false,
    /// A theme font family; null is the UI font.
    family: ?[]const u8 = null,
};

pub const Item = union(enum) {
    fill: struct { path: *const Path, color: Color },
    /// `outline` was flattened within `tol` canvas units.
    stroke: struct { path: *const Path, outline: *const Path, style: stroke_mod.StrokeStyle, color: Color, tol: f32 },
    text: Text,
    clip_push: Rect,
    clip_pop,
};

pub const DisplayList = struct {
    items: []const Item,
    bounds: Rect,
    /// Identifies the content (tile cache keys).
    hash: u64,
};

/// The hash of a list's items.
pub fn hashItems(items: []const Item) u64 {
    var h: std.hash.Wyhash = .init(0x7EC7_0001);
    for (items) |it| {
        h.update(&.{@intFromEnum(std.meta.activeTag(it))});
        switch (it) {
            .fill => |f| {
                f.path.hash(&h);
                h.update(std.mem.asBytes(&f.color));
            },
            .stroke => |s| {
                s.outline.hash(&h);
                h.update(std.mem.asBytes(&s.color));
            },
            .text => |t| {
                h.update(std.mem.asBytes(&[_]f32{ t.x, t.y, t.size }));
                h.update(t.text);
                h.update(std.mem.asBytes(&t.color));
                h.update(&.{ @intFromEnum(t.anchor), @intFromEnum(t.baseline), @intFromEnum(t.rotate), @intFromBool(t.bold) });
                h.update(t.family orelse "");
            },
            .clip_push => |r| h.update(std.mem.asBytes(&r)),
            .clip_pop => {},
        }
    }
    return h.final();
}
