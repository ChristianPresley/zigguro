//! FLIP layout transitions (First, Last, Invert, Play): keep where nodes
//! were painted, let the next layout move them, then start each at the
//! inverse offset and animate it to none. One layout; every frame after
//! that only changes transforms. Used for mode switches, splitter
//! equalize, tab reorder and toast stacking.
//!
//! The inverse is a translation between the rects' centres (a size change
//! snaps; text would smear under a non-uniform scale).

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const tween = @import("tween.zig");
const window_mod = @import("../core/window.zig");

const NodeId = ids.NodeId;
const Rect = geom.Rect;
const Vec2 = geom.Vec2;
const Motion = tween.Motion;
const Window = window_mod.Window;

/// A node waiting for the layout that moves it.
pub const Pending = struct { node: NodeId, old: Rect, how: Motion };

/// The translation that shows a node laid out at `new` where `old` was.
pub fn inverse(old: Rect, new: Rect) Vec2 {
    return .{
        .x = (old.x + old.w / 2) - (new.x + new.w / 2),
        .y = (old.y + old.h / 2) - (new.y + new.h / 2),
    };
}

/// Records where `nodes` are painted now; after the next layout they
/// animate from there (`afterLayout`). Unpainted nodes just appear.
pub fn flip(w: *Window, nodes: []const NodeId, how: Motion) void {
    for (nodes) |n| {
        if (!w.store.valid(n) or !w.store.hot.items(.flags)[n.index].painted) continue;
        w.flips.append(w.gpa, .{ .node = n, .old = w.store.absRect(n), .how = how }) catch return;
    }
    w.needs_frame = true;
}

/// Runs after the frame's layout: each pending node jumps back to its old
/// place and animates to the new one.
pub fn afterLayout(w: *Window) void {
    defer w.flips.clearRetainingCapacity();
    for (w.flips.items) |f| {
        if (!w.store.valid(f.node)) continue;
        const d = inverse(f.old, w.layoutRect(f.node));
        if (d.x == 0 and d.y == 0) continue;
        // Start from the old place, whatever was moving it.
        w.anim.cancel(w.anim.idOf(.{ .node_translate_x = f.node }));
        w.anim.cancel(w.anim.idOf(.{ .node_translate_y = f.node }));
        var v = w.visualOf(f.node);
        v.translate = d;
        w.setVisual(f.node, v);
        w.animateTranslate(f.node, .{}, f.how);
    }
}

test "inverse maps the new centre onto the old" {
    const d = inverse(.{ .x = 0, .y = 100, .w = 50, .h = 20 }, .{ .x = 10, .y = 0, .w = 30, .h = 20 });
    try std.testing.expectEqual(@as(f32, 0), d.x);
    try std.testing.expectEqual(@as(f32, 100), d.y);
}
