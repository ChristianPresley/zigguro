//! Drop zones for drag-to-dock (E04.F07.S01.T02), computed from the last
//! frame's rectangles without any GUI state.
//!
//! Each group has a center zone (move into the group) and four edge zones
//! (split it); an edge is 25 % of the group, at most 200 px. Each docking
//! area has a 24 px strip along its window edge (dock into that area,
//! hidden or not). A point outside the window drops into a new floating
//! window.

const std = @import("std");
const model = @import("model.zig");

const Rect = model.Rect;
const DropTarget = model.DropTarget;
const GroupRect = model.GroupRect;

/// Where a side area docks, and its rectangle (when shown).
pub const AreaRect = struct { area: model.Area, rect: Rect, visible: bool = true };

/// A zone: where it is, what it does, and the preview to draw.
pub const DropZone = struct { target: DropTarget, rect: Rect, preview: Rect };

/// Area edge strips are this thick.
pub const area_strip: f32 = 24;
/// Edge zones take this share of a group, up to `max_edge`.
pub const edge_share: f32 = 0.25;
pub const max_edge: f32 = 200;
/// A hidden area previews at this size.
pub const default_area_size: f32 = 240;

/// Appends the zones for `groups` and `areas` in `window`, in hit order
/// (area strips, then group edges, then group centers).
pub fn computeDropZones(window: Rect, groups: []const GroupRect, areas: []const AreaRect, gpa: std.mem.Allocator, out: *std.ArrayList(DropZone)) std.mem.Allocator.Error!void {
    for (areas) |a| {
        const strip: Rect, const preview: Rect = switch (a.area) {
            .left => .{ .{ .x = window.x, .y = window.y, .w = area_strip, .h = window.h }, sideRect(window, a, .left) },
            .right, .agent => .{ .{ .x = window.x + window.w - area_strip, .y = window.y, .w = area_strip, .h = window.h }, sideRect(window, a, .right) },
            .bottom => .{ .{ .x = window.x, .y = window.y + window.h - area_strip, .w = window.w, .h = area_strip }, sideRect(window, a, .bottom) },
            .center => continue,
        };
        try out.append(gpa, .{ .target = .{ .area = a.area }, .rect = strip, .preview = preview });
    }
    for (groups) |g| {
        const r = g.rect;
        const ew = @min(r.w * edge_share, max_edge);
        const eh = @min(r.h * edge_share, max_edge);
        const half_w = r.w / 2;
        const half_h = r.h / 2;
        try out.appendSlice(gpa, &.{
            .{ .target = .{ .split = .{ .g = g.g, .side = .left } }, .rect = .{ .x = r.x, .y = r.y, .w = ew, .h = r.h }, .preview = .{ .x = r.x, .y = r.y, .w = half_w, .h = r.h } },
            .{ .target = .{ .split = .{ .g = g.g, .side = .right } }, .rect = .{ .x = r.x + r.w - ew, .y = r.y, .w = ew, .h = r.h }, .preview = .{ .x = r.x + half_w, .y = r.y, .w = half_w, .h = r.h } },
            .{ .target = .{ .split = .{ .g = g.g, .side = .top } }, .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = eh }, .preview = .{ .x = r.x, .y = r.y, .w = r.w, .h = half_h } },
            .{ .target = .{ .split = .{ .g = g.g, .side = .bottom } }, .rect = .{ .x = r.x, .y = r.y + r.h - eh, .w = r.w, .h = eh }, .preview = .{ .x = r.x, .y = r.y + half_h, .w = r.w, .h = half_h } },
        });
    }
    for (groups) |g| try out.append(gpa, .{ .target = .{ .group = .{ .g = g.g } }, .rect = g.rect, .preview = g.rect });
}

fn sideRect(window: Rect, a: AreaRect, side: enum { left, right, bottom }) Rect {
    if (a.visible and a.rect.w > 0 and a.rect.h > 0) return a.rect;
    const s = default_area_size;
    return switch (side) {
        .left => .{ .x = window.x, .y = window.y, .w = s, .h = window.h },
        .right => .{ .x = window.x + window.w - s, .y = window.y, .w = s, .h = window.h },
        .bottom => .{ .x = window.x, .y = window.y + window.h - s, .w = window.w, .h = s },
    };
}

/// The zone under `p`: the first containing it, or a floating window
/// when `p` is outside `window`; null over no zone.
pub fn hit(zones: []const DropZone, window: Rect, p: [2]f32) ?DropZone {
    if (!inside(window, p)) {
        const r: Rect = .{ .x = p[0], .y = p[1], .w = 480, .h = 320 };
        return .{ .target = .{ .float = r }, .rect = r, .preview = r };
    }
    for (zones) |z| if (inside(z.rect, p)) return z;
    return null;
}

fn inside(r: Rect, p: [2]f32) bool {
    return p[0] >= r.x and p[1] >= r.y and p[0] < r.x + r.w and p[1] < r.y + r.h;
}

const testing = std.testing;

test "drop zones geometry" {
    const g1: model.GroupId = @enumFromInt(1);
    const win: Rect = .{ .w = 1000, .h = 800 };
    const groups = [_]GroupRect{.{ .g = g1, .rect = .{ .x = 100, .y = 0, .w = 1000 - 100, .h = 800 } }};
    const areas = [_]AreaRect{
        .{ .area = .left, .rect = .{ .w = 100, .h = 800 } },
        .{ .area = .bottom, .rect = .{}, .visible = false },
        .{ .area = .center, .rect = groups[0].rect },
    };
    var zones: std.ArrayList(DropZone) = .empty;
    defer zones.deinit(testing.allocator);
    try computeDropZones(win, &groups, &areas, testing.allocator, &zones);
    // 2 area strips, 4 edges and a center.
    try testing.expectEqual(@as(usize, 7), zones.items.len);
    // Area strips: the left one previews the visible area, the bottom one
    // a default-sized panel.
    try testing.expectEqual(model.Area.left, zones.items[0].target.area);
    try testing.expectEqual(@as(f32, 100), zones.items[0].preview.w);
    try testing.expectEqual(@as(f32, 560), zones.items[1].preview.y);
    // Edges: 25 % capped at 200 px; previews are halves.
    const left = zones.items[2];
    try testing.expectEqual(model.Side.left, left.target.split.side);
    try testing.expectEqual(@as(f32, 200), left.rect.w);
    try testing.expectEqual(@as(f32, 450), left.preview.w);
    const top = zones.items[4];
    try testing.expectEqual(@as(f32, 200), top.rect.h);
    try testing.expectEqual(@as(f32, 400), top.preview.h);

    // Hits: edges win over the center; the window edge over both.
    try testing.expectEqual(model.Side.right, hit(zones.items, win, .{ 950, 400 }).?.target.split.side);
    try testing.expectEqual(g1, hit(zones.items, win, .{ 550, 400 }).?.target.group.g);
    try testing.expectEqual(model.Area.bottom, hit(zones.items, win, .{ 550, 790 }).?.target.area);
    try testing.expect(hit(zones.items, win, .{ 1200, 400 }).?.target == .float);
}
