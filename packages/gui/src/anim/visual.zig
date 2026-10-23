//! A node's visual properties (opacity, translation, scale, clip) and the
//! transform they compose to down the tree. The paint pass applies them to
//! cached prims without relayout or repaint; hits and damage use the
//! transformed ("visual") rects.

const std = @import("std");
const geom = @import("../core/geom.zig");

const Rect = geom.Rect;
const Vec2 = geom.Vec2;

/// What an `Animator` moves on a node; the defaults draw the node as laid
/// out. Scale is uniform, about the centre of the node's box.
pub const Visual = struct {
    opacity: f32 = 1,
    translate: Vec2 = .{},
    scale: f32 = 1,
    /// The fraction of the node's height hidden, from the bottom
    /// (0: all of it shows; 1: none).
    clip: f32 = 0,

    pub fn isDefault(v: Visual) bool {
        return v.opacity == 1 and v.translate.x == 0 and v.translate.y == 0 and v.scale == 1 and v.clip == 0;
    }
};

/// Layout space to window space: p' = p × s + b; colours × alpha.
pub const Xform = struct {
    s: f32 = 1,
    b: Vec2 = .{},
    alpha: f32 = 1,

    pub const identity: Xform = .{};

    /// No scale and no fade: a plain translation by `b`.
    pub fn isTranslate(x: Xform) bool {
        return x.s == 1 and x.alpha == 1;
    }

    pub fn isIdentity(x: Xform) bool {
        return x.isTranslate() and x.b.x == 0 and x.b.y == 0;
    }

    pub fn point(x: Xform, p: Vec2) Vec2 {
        return .{ .x = p.x * x.s + x.b.x, .y = p.y * x.s + x.b.y };
    }

    pub fn rect(x: Xform, r: Rect) Rect {
        return .{ .x = r.x * x.s + x.b.x, .y = r.y * x.s + x.b.y, .w = r.w * x.s, .h = r.h * x.s };
    }

    /// This transform with a node's `v` applied about the centre of its
    /// layout rect `box` (layout space) first.
    pub fn then(x: Xform, v: Visual, box: Rect) Xform {
        const sv = v.scale;
        const c: Vec2 = .{ .x = box.x + box.w / 2, .y = box.y + box.h / 2 };
        // q = c + (p − c) × sv + t, then x.
        const lb: Vec2 = .{ .x = c.x * (1 - sv) + v.translate.x, .y = c.y * (1 - sv) + v.translate.y };
        return .{
            .s = x.s * sv,
            .b = .{ .x = lb.x * x.s + x.b.x, .y = lb.y * x.s + x.b.y },
            .alpha = x.alpha * std.math.clamp(v.opacity, 0, 1),
        };
    }
};

test "xform composes translate and scale about the centre" {
    const box: Rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    const x = Xform.identity.then(.{ .scale = 0.5, .translate = .{ .x = 5 } }, box);
    const r = x.rect(box);
    try std.testing.expectApproxEqAbs(@as(f32, 20), r.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 15), r.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), r.w, 1e-5);
    // A child's transform includes the parent's.
    const child: Rect = .{ .x = 10, .y = 10, .w = 4, .h = 4 };
    const cx = x.then(.{ .opacity = 0.5 }, child);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cx.alpha, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 15), cx.rect(child).y, 1e-5);
    try std.testing.expect(Xform.identity.then(.{}, box).isIdentity());
}
