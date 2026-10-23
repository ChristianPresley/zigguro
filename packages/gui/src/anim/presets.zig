//! Motion tokens and the common transitions built from them.
//!
//! - `fade_scale`: popovers, dialogs, toasts (opacity plus a slight zoom);
//! - `slide_up`: toasts and sheets entering from below;
//! - `expand_height`: tree and section disclosure (a clip from the bottom;
//!   the chevron's rotation is an icon swap).
//!
//! Each `show` call first puts the node in its hidden pose, so call it on
//! the build or event that mounts the node, before its first paint.

const std = @import("std");
const ids = @import("../core/ids.zig");
const spring = @import("spring.zig");
const tween = @import("tween.zig");
const bezier = @import("bezier.zig");
const window_mod = @import("../core/window.zig");

const NodeId = ids.NodeId;
const Motion = tween.Motion;
const Window = window_mod.Window;

/// Motion design tokens.
pub const tokens = struct {
    pub const fast_ms: f32 = 80;
    pub const normal_ms: f32 = 120;
    pub const slow_ms: f32 = 200;
    pub const spring_default: spring.SpringParams = .{ .omega = 30, .zeta = 1 };
    pub const spring_bouncy: spring.SpringParams = .{ .omega = 25, .zeta = 0.8 };
};

pub const fast: Motion = .{ .tween = .{ .ms = tokens.fast_ms, .curve = bezier.CubicBezier.standard } };
pub const normal: Motion = .{ .tween = .{ .ms = tokens.normal_ms, .curve = bezier.CubicBezier.standard } };
pub const slow: Motion = .{ .tween = .{ .ms = tokens.slow_ms, .curve = bezier.CubicBezier.standard } };
pub const spring_default: Motion = .{ .spring = tokens.spring_default };
pub const spring_bouncy: Motion = .{ .spring = tokens.spring_bouncy };

/// The scale a `fade_scale` node starts from.
pub const fade_scale_from: f32 = 0.96;

/// Fades and zooms `n` in (`show`) or out.
pub fn fadeScale(w: *Window, n: NodeId, show: bool) void {
    if (show) {
        var v = w.visualOf(n);
        if (w.anim.idOf(.{ .node_opacity = n }) == .none) v.opacity = 0;
        if (w.anim.idOf(.{ .node_scale = n }) == .none) v.scale = fade_scale_from;
        w.setVisual(n, v);
    }
    _ = w.animate(.{ .node_opacity = n }, if (show) 1 else 0, fast);
    _ = w.animate(.{ .node_scale = n }, if (show) 1 else fade_scale_from, spring_default);
}

/// Slides `n` up into place from `distance` below (`show`), or back down,
/// fading with it.
pub fn slideUp(w: *Window, n: NodeId, distance: f32, show: bool) void {
    if (show) {
        var v = w.visualOf(n);
        if (w.anim.idOf(.{ .node_translate_y = n }) == .none) v.translate.y = distance;
        if (w.anim.idOf(.{ .node_opacity = n }) == .none) v.opacity = 0;
        w.setVisual(n, v);
    }
    _ = w.animate(.{ .node_translate_y = n }, if (show) 0 else distance, spring_default);
    _ = w.animate(.{ .node_opacity = n }, if (show) 1 else 0, fast);
}

/// Reveals `n` top to bottom (`open`), or hides it bottom to top.
pub fn expandHeight(w: *Window, n: NodeId, open: bool) void {
    if (open and w.anim.idOf(.{ .node_clip = n }) == .none) {
        var v = w.visualOf(n);
        v.clip = 1;
        w.setVisual(n, v);
    }
    _ = w.animate(.{ .node_clip = n }, if (open) 0 else 1, normal);
}

test "tokens" {
    try std.testing.expectEqual(@as(f32, 120), tokens.normal_ms);
    try std.testing.expectEqual(@as(f32, 0.8), tokens.spring_bouncy.zeta);
}
