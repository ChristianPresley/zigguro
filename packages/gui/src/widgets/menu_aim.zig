//! Menu-aim (E04.F05.S03.T02): keeps an open submenu while the pointer
//! heads for it across sibling items, after Ben Kamens's breakdown of
//! Amazon's mega dropdown.
//!
//! The pointer is "aiming" when its new position lies inside the triangle
//! formed by its previous position and the two corners of the submenu's
//! near edge, and it moved within the last 100 ms. A pointer that stops
//! keeps the submenu for 300 ms, then lets a sibling take over. Pure logic;
//! the menu feeds it pointer samples and the clock.

const std = @import("std");
const geom = @import("../core/geom.zig");

const Vec2 = geom.Vec2;
const Rect = geom.Rect;

/// Pointer samples older than this do not count as movement.
pub const move_window_ms: u64 = 100;
/// How long a resting pointer keeps the submenu.
pub const rest_ms: u64 = 300;
/// Slack around the triangle, in logical pixels.
pub const tolerance: f32 = 2;

/// What the menu should do with a hover over a sibling item.
pub const Decision = enum { keep, switch_allowed };

const Sample = struct { p: Vec2, t: u64 };

/// The tracker; one per menu.
pub const MenuAim = struct {
    /// The last three pointer samples, newest at `head`.
    ring: [3]Sample = undefined,
    len: u8 = 0,
    head: u8 = 0,
    /// When the pointer last moved.
    moved_at: u64 = 0,
    /// Whether the last move was aimed at the submenu.
    aiming: bool = false,

    /// Forgets the samples (a submenu opened or closed).
    pub fn reset(m: *MenuAim) void {
        m.* = .{};
    }

    /// The newest sample.
    fn last(m: *const MenuAim) ?Sample {
        if (m.len == 0) return null;
        return m.ring[m.head];
    }

    fn push(m: *MenuAim, s: Sample) void {
        m.head = if (m.len == 0) 0 else (m.head + 1) % 3;
        m.ring[m.head] = s;
        if (m.len < 3) m.len += 1;
    }

    /// Records the pointer at `pointer` at `t_ms` and decides whether a
    /// sibling under it may replace the submenu at `submenu_rect`.
    pub fn update(m: *MenuAim, pointer: Vec2, t_ms: u64, submenu_rect: Rect) Decision {
        const prev = m.last() orelse {
            m.push(.{ .p = pointer, .t = t_ms });
            m.moved_at = t_ms;
            m.aiming = false;
            return .switch_allowed;
        };
        if (prev.p.x == pointer.x and prev.p.y == pointer.y) {
            // Resting: keep a while if the pointer was heading there.
            if (!m.aiming or t_ms -| m.moved_at >= rest_ms) return .switch_allowed;
            return .keep;
        }
        m.push(.{ .p = pointer, .t = t_ms });
        const recent = t_ms -| prev.t <= move_window_ms;
        m.moved_at = t_ms;
        m.aiming = recent and inTriangle(pointer, prev.p, submenu_rect);
        return if (m.aiming) .keep else .switch_allowed;
    }
};

/// True when `p` lies in the triangle from `apex` to the edge of `sub`
/// nearest the apex (with `tolerance` of slack).
pub fn inTriangle(p: Vec2, apex: Vec2, sub: Rect) bool {
    // The near edge: the submenu's left edge when it is to the right.
    const ex = if (sub.x >= apex.x) sub.x else sub.right();
    const a: Vec2 = apex;
    const b: Vec2 = .{ .x = ex, .y = sub.y - tolerance };
    const c: Vec2 = .{ .x = ex, .y = sub.bottom() + tolerance };
    const d1 = cross(a, b, p);
    const d2 = cross(b, c, p);
    const d3 = cross(c, a, p);
    const neg = d1 < -tolerance or d2 < -tolerance or d3 < -tolerance;
    const pos = d1 > tolerance or d2 > tolerance or d3 > tolerance;
    return !(neg and pos);
}

fn cross(a: Vec2, b: Vec2, p: Vec2) f32 {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

const sub_rect: Rect = .{ .x = 200, .y = 0, .w = 150, .h = 200 };

test "menu-aim keeps submenu on diagonal" {
    var m: MenuAim = .{};
    // On the parent item, then heading down-right towards the submenu
    // across the siblings below it.
    try std.testing.expectEqual(Decision.switch_allowed, m.update(.{ .x = 150, .y = 20 }, 0, sub_rect));
    var t: u64 = 0;
    var p: Vec2 = .{ .x = 150, .y = 20 };
    while (p.x < 195) {
        t += 16;
        p = .{ .x = p.x + 8, .y = p.y + 6 };
        try std.testing.expectEqual(Decision.keep, m.update(p, t, sub_rect));
    }
}

test "menu-aim switches when moving away or too slowly" {
    var m: MenuAim = .{};
    _ = m.update(.{ .x = 150, .y = 20 }, 0, sub_rect);
    // Straight down, away from the submenu's corner: not aiming.
    try std.testing.expectEqual(Decision.switch_allowed, m.update(.{ .x = 140, .y = 60 }, 16, sub_rect));
    // Towards it, but after a long pause: not "keeps moving".
    m.reset();
    _ = m.update(.{ .x = 150, .y = 20 }, 0, sub_rect);
    try std.testing.expectEqual(Decision.switch_allowed, m.update(.{ .x = 160, .y = 28 }, 500, sub_rect));
}

test "menu-aim switches after rest 300ms" {
    var m: MenuAim = .{};
    _ = m.update(.{ .x = 150, .y = 20 }, 0, sub_rect);
    try std.testing.expectEqual(Decision.keep, m.update(.{ .x = 160, .y = 28 }, 16, sub_rect));
    // The pointer stops on a sibling.
    try std.testing.expectEqual(Decision.keep, m.update(.{ .x = 160, .y = 28 }, 200, sub_rect));
    try std.testing.expectEqual(Decision.keep, m.update(.{ .x = 160, .y = 28 }, 315, sub_rect));
    try std.testing.expectEqual(Decision.switch_allowed, m.update(.{ .x = 160, .y = 28 }, 316, sub_rect));
}

test "submenu on the left" {
    const left: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 };
    try std.testing.expect(inTriangle(.{ .x = 140, .y = 40 }, .{ .x = 150, .y = 40 }, left));
    try std.testing.expect(!inTriangle(.{ .x = 160, .y = 40 }, .{ .x = 150, .y = 40 }, left));
}
