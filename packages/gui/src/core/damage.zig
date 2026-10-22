//! Damage accumulation: up to 64 rectangles per frame, merged when they
//! overlap; overflow collapses to a full-window repaint (E02 contract).

const std = @import("std");
const geom = @import("geom.zig");

const Rect = geom.Rect;

/// The damaged area of one frame.
pub const Damage = struct {
    rects: [max]Rect = undefined,
    len: u8 = 0,
    full: bool = false,

    /// Rectangles kept before collapsing to `full`.
    pub const max = 64;

    /// Forgets all damage.
    pub fn clear(d: *Damage) void {
        d.len = 0;
        d.full = false;
    }

    /// True when nothing is damaged.
    pub fn isEmpty(d: *const Damage) bool {
        return d.len == 0 and !d.full;
    }

    /// Adds `r` (ignored when empty), merging with an overlapping rect.
    pub fn add(d: *Damage, r: Rect) void {
        if (d.full or r.isEmpty()) return;
        var merged = r;
        // Absorb every existing rect the new one overlaps or touches.
        var i: usize = 0;
        while (i < d.len) {
            const o = d.rects[i];
            if (!o.intersect(merged.outset(0.5)).isEmpty()) {
                merged = merged.unite(o);
                d.len -= 1;
                d.rects[i] = d.rects[d.len];
                i = 0;
                continue;
            }
            i += 1;
        }
        if (d.len == max) {
            d.full = true;
            return;
        }
        d.rects[d.len] = merged;
        d.len += 1;
    }

    /// The damaged rectangles (empty when `full`).
    pub fn slice(d: *const Damage) []const Rect {
        return d.rects[0..d.len];
    }

    /// The union of all damage.
    pub fn bounds(d: *const Damage) Rect {
        var b: Rect = .empty;
        for (d.slice()) |r| b = b.unite(r);
        return b;
    }
};

test "merge overlapping, keep disjoint" {
    var d: Damage = .{};
    d.add(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    d.add(.{ .x = 5, .y = 5, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(u8, 1), d.len);
    try std.testing.expect(d.rects[0].eql(.{ .x = 0, .y = 0, .w = 15, .h = 15 }));
    d.add(.{ .x = 100, .y = 100, .w = 1, .h = 1 });
    try std.testing.expectEqual(@as(u8, 2), d.len);
    d.add(.empty);
    try std.testing.expectEqual(@as(u8, 2), d.len);
}

test "overflow collapses to full" {
    var d: Damage = .{};
    var i: usize = 0;
    while (i < Damage.max + 1) : (i += 1) {
        d.add(.{ .x = @floatFromInt(i * 10), .y = 0, .w = 1, .h = 1 });
    }
    try std.testing.expect(d.full);
    try std.testing.expect(!d.isEmpty());
}
