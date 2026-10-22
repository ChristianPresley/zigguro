//! Client-side decorations on Wayland (E01.F04.S01.T02): the invisible
//! resize and shadow margins around a client-decorated window, its window
//! geometry and input region, which edge a point in the margins resizes,
//! and what a press on a title bar or border does. Pure functions; the
//! backend sends the requests.
//!
//! A client-decorated surface is the visible window plus `default_margin`
//! logical pixels on every edge, except edges that are tiled and every
//! edge while maximized or fullscreen. `xdg_surface.set_window_geometry`
//! names the visible part, so compositors snap and tile it; the input
//! region adds a `resize_band` around it.

const std = @import("std");
const wl = @import("wl_gen");
const types = @import("../api/types.zig");
const WindowState = @import("../api/window.zig").WindowState;
const CursorShape = @import("../api/cursor.zig").CursorShape;
const HitRegion = types.HitRegion;
const ResizeEdge = types.ResizeEdge;
const scale = @import("scale.zig");

/// Margin on each free edge, in logical pixels.
pub const default_margin: u32 = 12;
/// Width of the input band outside the visible window, in logical pixels.
pub const resize_band: u32 = 8;
/// Length of a corner's resize zone along each edge, in logical pixels.
pub const corner_len: u32 = 16;

/// Margins in pixels (logical or physical, by context).
pub const Margins = struct {
    left: u32 = 0,
    top: u32 = 0,
    right: u32 = 0,
    bottom: u32 = 0,

    /// The margins at `scale120`.
    pub fn scaled(m: Margins, scale120: u32) Margins {
        return .{ .left = scale.scaleDim(m.left, scale120), .top = scale.scaleDim(m.top, scale120), .right = scale.scaleDim(m.right, scale120), .bottom = scale.scaleDim(m.bottom, scale120) };
    }

    /// Left, top, right, bottom.
    pub fn array(m: Margins) [4]u32 {
        return .{ m.left, m.top, m.right, m.bottom };
    }
};

/// The margins for a client-decorated window in `state`.
pub fn margins(state: WindowState, base: u32) Margins {
    if (state.maximized or state.fullscreen) return .{};
    return .{
        .left = if (state.tiled_left) 0 else base,
        .top = if (state.tiled_top) 0 else base,
        .right = if (state.tiled_right) 0 else base,
        .bottom = if (state.tiled_bottom) 0 else base,
    };
}

/// `set_window_geometry` arguments: the visible window inside the margins.
pub fn geometry(m: Margins, visible: types.PxSize) [4]i32 {
    return .{ @intCast(m.left), @intCast(m.top), @intCast(visible.w), @intCast(visible.h) };
}

/// The input rectangle: the visible window plus up to `resize_band` of
/// each margin.
pub fn inputRect(m: Margins, visible: types.PxSize) [4]i32 {
    const l = @min(m.left, resize_band);
    const t = @min(m.top, resize_band);
    const r = @min(m.right, resize_band);
    const b = @min(m.bottom, resize_band);
    return .{ @intCast(m.left - l), @intCast(m.top - t), @intCast(visible.w + l + r), @intCast(visible.h + t + b) };
}

/// The edge a point in the margins resizes, or null inside the visible
/// window. `pos`, `surface` and `m` are physical; `corner` is the corner
/// zone's length.
pub fn edgeAt(pos: [2]f32, surface: types.PxSize, m: Margins, corner: u32) ?ResizeEdge {
    const x = pos[0];
    const y = pos[1];
    const w: f32 = @floatFromInt(surface.w);
    const h: f32 = @floatFromInt(surface.h);
    const ml: f32 = @floatFromInt(m.left);
    const mt: f32 = @floatFromInt(m.top);
    const mr: f32 = @floatFromInt(m.right);
    const mb: f32 = @floatFromInt(m.bottom);
    const c: f32 = @floatFromInt(corner);
    const left = x < ml;
    const right = x >= w - mr;
    const top = y < mt;
    const bottom = y >= h - mb;
    const near_top = y < mt + c;
    const near_bottom = y >= h - mb - c;
    const near_left = x < ml + c;
    const near_right = x >= w - mr - c;
    if (left) return if (near_top) .top_left else if (near_bottom) .bottom_left else .left;
    if (right) return if (near_top) .top_right else if (near_bottom) .bottom_right else .right;
    if (top) return if (near_left) .top_left else if (near_right) .top_right else .top;
    if (bottom) return if (near_left) .bottom_left else if (near_right) .bottom_right else .bottom;
    return null;
}

/// The protocol's value for `e`.
pub fn wlEdge(e: ResizeEdge) wl.xdg_toplevel.ResizeEdge {
    return switch (e) {
        .top => .top,
        .bottom => .bottom,
        .left => .left,
        .right => .right,
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
    };
}

/// The edge a resize region names.
pub fn regionEdge(r: HitRegion) ?ResizeEdge {
    return switch (r) {
        .resize_top => .top,
        .resize_bottom => .bottom,
        .resize_left => .left,
        .resize_right => .right,
        .resize_top_left => .top_left,
        .resize_top_right => .top_right,
        .resize_bottom_left => .bottom_left,
        .resize_bottom_right => .bottom_right,
        else => null,
    };
}

/// The region for an edge.
pub fn edgeRegion(e: ResizeEdge) HitRegion {
    return switch (e) {
        .top => .resize_top,
        .bottom => .resize_bottom,
        .left => .resize_left,
        .right => .resize_right,
        .top_left => .resize_top_left,
        .top_right => .resize_top_right,
        .bottom_left => .resize_bottom_left,
        .bottom_right => .resize_bottom_right,
    };
}

/// The cursor over a resize edge.
pub fn cursorFor(e: ResizeEdge) CursorShape {
    return switch (e) {
        .top, .bottom => .ns_resize,
        .left, .right => .ew_resize,
        .top_left, .bottom_right => .nwse_resize,
        .top_right, .bottom_left => .nesw_resize,
    };
}

/// What a press does on a client-decorated window.
pub const Action = union(enum) {
    /// Give the press to the app.
    deliver,
    /// `xdg_toplevel.move`.
    move,
    /// `xdg_toplevel.resize`.
    resize: ResizeEdge,
    /// `xdg_toplevel.show_window_menu`.
    window_menu,
    /// Maximize or restore.
    toggle_maximize,
};

/// The action for pressing `button` on `region`; `double` is a second
/// left press on the title bar in quick succession.
pub fn pressAction(region: HitRegion, button: types.Button, double: bool) Action {
    if (region == .caption) return switch (button) {
        .left => if (double) .toggle_maximize else .move,
        .right => .window_menu,
        else => .deliver,
    };
    if (regionEdge(region)) |e| if (button == .left) return .{ .resize = e };
    return .deliver;
}

/// Title-bar double-click detection.
pub const Clicks = struct {
    last_ns: u64 = 0,
    last_pos: [2]f32 = .{ -1000, -1000 },

    /// Records a title-bar press; true when it completes a double click
    /// (which then starts over).
    pub fn press(c: *Clicks, now_ns: u64, pos: [2]f32, max_ns: u64, max_px: f32) bool {
        const near = @abs(pos[0] - c.last_pos[0]) <= max_px and @abs(pos[1] - c.last_pos[1]) <= max_px;
        if (near and now_ns -| c.last_ns <= max_ns) {
            c.* = .{};
            return true;
        }
        c.last_ns = now_ns;
        c.last_pos = pos;
        return false;
    }
};

const testing = std.testing;

test "margins: free edges only; none when maximized or fullscreen" {
    try testing.expectEqual(Margins{ .left = 12, .top = 12, .right = 12, .bottom = 12 }, margins(.{}, 12));
    try testing.expectEqual(Margins{}, margins(.{ .maximized = true }, 12));
    try testing.expectEqual(Margins{}, margins(.{ .fullscreen = true }, 12));
    // Tiled to the left half: the left, top and bottom edges touch the screen.
    try testing.expectEqual(Margins{ .right = 12 }, margins(.{ .tiled_left = true, .tiled_top = true, .tiled_bottom = true }, 12));
    try testing.expectEqual(Margins{ .left = 18, .top = 18, .right = 18, .bottom = 18 }, (Margins{ .left = 12, .top = 12, .right = 12, .bottom = 12 }).scaled(180));
}

test "geometry and input region" {
    const m: Margins = .{ .left = 12, .top = 12, .right = 0, .bottom = 4 };
    try testing.expectEqual([4]i32{ 12, 12, 400, 300 }, geometry(m, .{ .w = 400, .h = 300 }));
    // 8 px of each margin, all of a narrower one.
    try testing.expectEqual([4]i32{ 4, 4, 408, 312 }, inputRect(m, .{ .w = 400, .h = 300 }));
}

test "edges and corners in the margins" {
    const m: Margins = .{ .left = 12, .top = 12, .right = 12, .bottom = 12 };
    const s: types.PxSize = .{ .w = 424, .h = 324 };
    try testing.expectEqual(null, edgeAt(.{ 100, 100 }, s, m, 16));
    try testing.expectEqual(ResizeEdge.left, edgeAt(.{ 5, 150 }, s, m, 16).?);
    try testing.expectEqual(ResizeEdge.right, edgeAt(.{ 415, 150 }, s, m, 16).?);
    try testing.expectEqual(ResizeEdge.top, edgeAt(.{ 200, 3 }, s, m, 16).?);
    try testing.expectEqual(ResizeEdge.bottom, edgeAt(.{ 200, 320 }, s, m, 16).?);
    try testing.expectEqual(ResizeEdge.top_left, edgeAt(.{ 5, 20 }, s, m, 16).?);
    try testing.expectEqual(ResizeEdge.top_left, edgeAt(.{ 20, 5 }, s, m, 16).?);
    try testing.expectEqual(ResizeEdge.top_right, edgeAt(.{ 420, 2 }, s, m, 16).?);
    try testing.expectEqual(ResizeEdge.bottom_left, edgeAt(.{ 2, 320 }, s, m, 16).?);
    try testing.expectEqual(ResizeEdge.bottom_right, edgeAt(.{ 410, 316 }, s, m, 16).?);
}

test "resize edge mapping table" {
    const E = wl.xdg_toplevel.ResizeEdge;
    const want = [_]struct { ResizeEdge, u32, CursorShape }{
        .{ .top, 1, .ns_resize },           .{ .bottom, 2, .ns_resize },
        .{ .left, 4, .ew_resize },          .{ .top_left, 5, .nwse_resize },
        .{ .bottom_left, 6, .nesw_resize }, .{ .right, 8, .ew_resize },
        .{ .top_right, 9, .nesw_resize },   .{ .bottom_right, 10, .nwse_resize },
    };
    for (want) |w| {
        try testing.expectEqual(@as(E, @enumFromInt(w[1])), wlEdge(w[0]));
        try testing.expectEqual(w[2], cursorFor(w[0]));
        try testing.expectEqual(w[0], regionEdge(edgeRegion(w[0])).?);
    }
    try testing.expectEqual(null, regionEdge(.caption));
}

test "press actions and title-bar double click" {
    try testing.expectEqual(Action.move, pressAction(.caption, .left, false));
    try testing.expectEqual(Action.toggle_maximize, pressAction(.caption, .left, true));
    try testing.expectEqual(Action.window_menu, pressAction(.caption, .right, false));
    try testing.expectEqual(Action.deliver, pressAction(.caption, .middle, false));
    try testing.expectEqual(Action{ .resize = .bottom_right }, pressAction(.resize_bottom_right, .left, false));
    try testing.expectEqual(Action.deliver, pressAction(.resize_left, .right, false));
    try testing.expectEqual(Action.deliver, pressAction(.button_close, .left, false));
    try testing.expectEqual(Action.deliver, pressAction(.client, .left, false));

    var c: Clicks = .{};
    try testing.expect(!c.press(1000, .{ 10, 10 }, 500, 4));
    try testing.expect(c.press(1400, .{ 12, 9 }, 500, 4));
    // A third press starts over.
    try testing.expect(!c.press(1500, .{ 12, 9 }, 500, 4));
    // Too far or too late.
    try testing.expect(!c.press(1600, .{ 30, 9 }, 500, 4));
    try testing.expect(!c.press(3000, .{ 30, 9 }, 500, 4));
}
