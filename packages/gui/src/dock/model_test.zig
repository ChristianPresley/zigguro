//! `DockModel` (E04.F07.S01.T01): splits and flattening, collapsing,
//! preview and pinned tabs, maximize, geometry and neighbors, undo and
//! reopen, and invariants under random operations.

const std = @import("std");
const model = @import("model.zig");
const geometry = @import("geometry.zig");

const DockModel = model.DockModel;
const GroupId = model.GroupId;
const PanelRef = model.PanelRef;
const testing = std.testing;
const gpa = testing.allocator;

const editor: model.PanelKindId = 1;

fn center(m: *const DockModel) GroupId {
    return m.firstGroup(m.areas[@intFromEnum(model.Area.center)].root).?;
}

fn tabs(m: *const DockModel, g: GroupId) []const PanelRef {
    return m.group(g).?.tabs.items;
}

fn open(m: *DockModel, g: GroupId) !PanelRef {
    const p = try m.addPanel(editor, null);
    try m.openIn(p, g, null, .{});
    return p;
}

test "split creates and flattens same-axis" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    const a = try open(&m, g);
    const b = try m.addPanel(editor, null);
    const g2 = (try m.split(g, .right, b)).?;
    try m.validate();
    const root = m.areas[@intFromEnum(model.Area.center)].root.?;
    try testing.expect(root == .split);
    const sp = m.splitOf(root.split).?;
    try testing.expectEqual(model.Axis.row, sp.axis);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, sp.ratios.items);
    // Splitting g2 right again stays in the same split, halving g2.
    const c = try m.addPanel(editor, null);
    const g3 = (try m.split(g2, .right, c)).?;
    try m.validate();
    try testing.expectEqual(@as(usize, 1), m.splits.count());
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25, 0.25 }, m.splitOf(root.split).?.ratios.items);
    // A column split wraps g3; moving its other tab out flattens back.
    const d = try m.addPanel(editor, null);
    const g4 = (try m.split(g3, .bottom, d)).?;
    try m.validate();
    try testing.expectEqual(@as(usize, 2), m.splits.count());
    try m.move(d, .{ .group = .{ .g = g } });
    try m.validate();
    try testing.expect(m.group(g4) == null);
    try testing.expectEqual(@as(usize, 1), m.splits.count());
    try testing.expectEqualSlices(PanelRef, &.{ a, d }, tabs(&m, g));
}

test "same-axis nested splits flatten with merged ratios" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    _ = try open(&m, g);
    const g2 = (try m.split(g, .right, try m.addPanel(editor, null))).?;
    const g3 = (try m.split(g2, .bottom, try m.addPanel(editor, null))).?;
    const g4 = (try m.split(g3, .right, try m.addPanel(editor, null))).?;
    try m.validate();
    // Closing g2's only tab leaves [g, column[g3 row[...]]] → the column
    // collapses and its row child merges into the top row.
    try m.close(tabs(&m, g2)[0]);
    try m.validate();
    const root = m.areas[@intFromEnum(model.Area.center)].root.?;
    const sp = m.splitOf(root.split).?;
    try testing.expectEqual(@as(usize, 3), sp.children.items.len);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25, 0.25 }, sp.ratios.items);
    try testing.expect(sp.children.items[2].eql(.{ .group = g4 }));
}

test "move last tab collapses group and split" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    _ = try open(&m, g);
    const b = try m.addPanel(editor, null);
    const g2 = (try m.split(g, .left, b)).?;
    try testing.expectEqual(@as(usize, 1), m.splits.count());
    try m.move(b, .{ .group = .{ .g = g, .index = 0 } });
    try m.validate();
    try testing.expect(m.group(g2) == null);
    try testing.expectEqual(@as(usize, 0), m.splits.count());
    try testing.expectEqual(b, tabs(&m, g)[0]);
    // Into a side area, then into a floating window.
    try m.move(b, .{ .area = .bottom });
    try m.validate();
    try testing.expect(m.areas[@intFromEnum(model.Area.bottom)].root != null);
    try m.move(b, .{ .float = .{ .w = 300, .h = 200 } });
    try m.validate();
    try testing.expect(m.areas[@intFromEnum(model.Area.bottom)].root == null);
    try testing.expectEqual(@as(usize, 1), m.floating.items.len);
    // Closing it removes the floating window.
    try m.close(b);
    try m.validate();
    try testing.expectEqual(@as(usize, 0), m.floating.items.len);
}

test "the center keeps one empty group" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    const a = try open(&m, g);
    try m.close(a);
    try m.validate();
    try testing.expectEqual(g, center(&m));
    try testing.expectEqual(@as(usize, 0), tabs(&m, g).len);
}

test "preview replaced" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    const a = try open(&m, g);
    const p1 = try m.addPanel(editor, "one");
    try m.openIn(p1, g, null, .{ .preview = true });
    const p2 = try m.addPanel(editor, "two");
    try m.openIn(p2, g, null, .{ .preview = true });
    try m.validate();
    try testing.expectEqualSlices(PanelRef, &.{ a, p2 }, tabs(&m, g));
    try testing.expectEqual(p2, m.group(g).?.preview.?);
    // p1 closed: it can come back.
    try testing.expect(!m.panels.contains(p1));
    // Editing pins it as a normal tab; the next preview adds a tab.
    m.pinPreview(p2);
    const p3 = try m.addPanel(editor, null);
    try m.openIn(p3, g, null, .{ .preview = true });
    try testing.expectEqualSlices(PanelRef, &.{ a, p2, p3 }, tabs(&m, g));
}

test "pinned order" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    const a = try open(&m, g);
    const b = try open(&m, g);
    const c = try open(&m, g);
    try m.setPinned(c, true);
    try m.setPinned(b, true);
    try m.validate();
    try testing.expectEqualSlices(PanelRef, &.{ c, b, a }, tabs(&m, g));
    try testing.expectEqual(@as(u32, 2), m.group(g).?.pinned);
    // The active tab follows its panel; new tabs never go before pins.
    try testing.expectEqual(c, tabs(&m, g)[m.group(g).?.active]);
    const d = try m.addPanel(editor, null);
    try m.openIn(d, g, 0, .{});
    try testing.expectEqualSlices(PanelRef, &.{ c, b, d, a }, tabs(&m, g));
    try m.setPinned(c, false);
    try testing.expectEqualSlices(PanelRef, &.{ b, c, d, a }, tabs(&m, g));
    try m.validate();
}

test "maximize restore exact" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    _ = try open(&m, g);
    const g2 = (try m.split(g, .right, try m.addPanel(editor, null))).?;
    try m.setRatios(m.areas[@intFromEnum(model.Area.center)].root.?.split, &.{ 0.7, 0.3 });
    var before = try m.snapshot(gpa);
    defer before.deinit();
    m.toggleMaximize(g2);
    var rects: std.ArrayList(model.GroupRect) = .empty;
    defer rects.deinit(gpa);
    const area: model.Rect = .{ .w = 1000, .h = 600 };
    try geometry.layout(&m, m.areas[@intFromEnum(model.Area.center)].root, area, .{}, gpa, &rects, null);
    try testing.expectEqual(@as(usize, 1), rects.items.len);
    try testing.expectEqual(g2, rects.items[0].g);
    try testing.expectEqual(@as(f32, 1000), rects.items[0].rect.w);
    m.toggleMaximize(g2);
    var after = try m.snapshot(gpa);
    defer after.deinit();
    try testing.expectEqual(@as(usize, before.splits.len), after.splits.len);
    try testing.expectEqualSlices(f32, before.splits[0].ratios, after.splits[0].ratios);
    rects.clearRetainingCapacity();
    try geometry.layout(&m, m.areas[@intFromEnum(model.Area.center)].root, area, .{}, gpa, &rects, null);
    try testing.expectEqual(@as(usize, 2), rects.items.len);
    try testing.expectApproxEqAbs(@as(f32, 697.2), rects.items[0].rect.w, 0.01);
}

test "geometry: minimum sizes and splitters" {
    var out: [3]f32 = undefined;
    geometry.share(&.{ 0.9, 0.05, 0.05 }, 1000, 80, &out);
    try testing.expectApproxEqAbs(@as(f32, 840), out[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), out[1], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1000), out[0] + out[1] + out[2], 0.01);
    // Not enough room for the minimum: ratios as given.
    geometry.share(&.{ 0.5, 0.5 }, 100, 80, out[0..2]);
    try testing.expectApproxEqAbs(@as(f32, 50), out[0], 0.01);
}

test "neighbor geometric" {
    const g = struct {
        fn id(n: u32) GroupId {
            return @enumFromInt(n);
        }
    }.id;
    // 1 | 2
    // --+---
    // 3 | 4 (4 is wider, starting under 2)
    const rects = [_]model.GroupRect{
        .{ .g = g(1), .rect = .{ .x = 0, .y = 0, .w = 500, .h = 300 } },
        .{ .g = g(2), .rect = .{ .x = 504, .y = 0, .w = 496, .h = 300 } },
        .{ .g = g(3), .rect = .{ .x = 0, .y = 304, .w = 300, .h = 296 } },
        .{ .g = g(4), .rect = .{ .x = 304, .y = 304, .w = 696, .h = 296 } },
    };
    try testing.expectEqual(g(2), geometry.neighbor(g(1), .right, &rects).?);
    try testing.expectEqual(g(3), geometry.neighbor(g(1), .down, &rects).?);
    try testing.expectEqual(g(4), geometry.neighbor(g(2), .down, &rects).?);
    // From 4 up: 1 and 2 are equally near; 2 overlaps 496, 1 only 196.
    try testing.expectEqual(g(2), geometry.neighbor(g(4), .up, &rects).?);
    try testing.expectEqual(g(1), geometry.neighbor(g(3), .up, &rects).?);
    try testing.expectEqual(@as(?GroupId, null), geometry.neighbor(g(2), .right, &rects));
}

test "reopen closed and undo" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    const a = try m.addPanel(editor, "state-a");
    try m.openIn(a, g, null, .{});
    const b = try open(&m, g);
    const g2 = (try m.split(g, .right, b)).?;
    try m.close(b);
    try m.validate();
    try testing.expect(m.group(g2) == null);
    // Its group is gone: it reopens in the center.
    try testing.expectEqual(b, (try m.reopenClosed()).?);
    try m.validate();
    try testing.expectEqual(g, m.groupOf(b).?);
    try m.close(a);
    try testing.expectEqual(a, (try m.reopenClosed()).?);
    try testing.expectEqualStrings("state-a", m.panels.get(a).?.state.?);
    // Undoing the reopen restores the layout but never closes a panel:
    // `a` stays open in the center.
    try testing.expect(try m.undo());
    try m.validate();
    try testing.expectEqual(g, m.groupOf(a).?);
}

test "undo restores the split and keeps panels opened since" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    _ = try open(&m, g);
    const b = try m.addPanel(editor, null);
    _ = (try m.split(g, .right, b)).?;
    try testing.expectEqual(@as(usize, 1), m.splits.count());
    m.history = false;
    const late = try open(&m, g);
    m.history = true;
    try testing.expect(try m.undo());
    try m.validate();
    try testing.expectEqual(@as(usize, 0), m.splits.count());
    // b was opened by the undone split: it goes back to the center, as
    // does the panel opened without history.
    try testing.expect(m.groupOf(b) != null);
    try testing.expect(m.groupOf(late) != null);
}

/// Applies op `op` with arguments drawn from `r` to `m`; tracks live panels.
pub fn randomOp(m: *DockModel, live: *std.ArrayList(PanelRef), r: std.Random) !void {
    const groups = m.groups.keys();
    const pick_g = groups[r.uintLessThan(usize, groups.len)];
    const has = live.items.len > 0;
    const pick_p = if (has) live.items[r.uintLessThan(usize, live.items.len)] else undefined;
    // Keep the layout at a realistic size.
    const op = if (live.items.len > 48 and r.boolean()) 4 else r.uintLessThan(u8, 12);
    switch (op) {
        0, 1 => {
            const p = try m.addPanel(editor, null);
            try live.append(gpa, p);
            try m.openIn(p, pick_g, if (r.boolean()) r.uintAtMost(u32, 5) else null, .{ .preview = r.uintLessThan(u8, 4) == 0, .activate = r.boolean() });
        },
        2 => if (has) {
            _ = try m.split(pick_g, r.enumValue(model.Side), pick_p);
        },
        3 => if (has) try m.move(pick_p, switch (r.uintLessThan(u8, 4)) {
            0 => .{ .group = .{ .g = pick_g, .index = r.uintAtMost(u32, 4) } },
            1 => .{ .split = .{ .g = pick_g, .side = r.enumValue(model.Side) } },
            2 => .{ .area = r.enumValue(model.Area) },
            else => .{ .float = .{ .w = 100, .h = 100 } },
        }),
        4 => if (has) try m.close(pick_p),
        5 => _ = try m.reopenClosed(),
        6 => if (m.splits.count() > 0) {
            const s = m.splits.keys()[r.uintLessThan(usize, m.splits.count())];
            var buf: [16]f32 = undefined;
            const n = m.splitOf(s).?.ratios.items.len;
            for (buf[0..n]) |*x| x.* = r.float(f32) * 2 - 0.2;
            try m.setRatios(s, buf[0..n]);
        },
        7 => m.toggleMaximize(pick_g),
        8 => if (has) try m.setPinned(pick_p, r.boolean()),
        9 => if (has) m.pinPreview(pick_p),
        10 => _ = try m.undo(),
        else => m.areaVisible(r.enumValue(model.Area), r.boolean()),
    }
    // Panels closed (directly or by a preview replacing them) leave
    // `live`; reopened ones come back.
    var i: usize = 0;
    while (i < live.items.len) {
        if (!m.panels.contains(live.items[i])) {
            _ = live.swapRemove(i);
        } else i += 1;
    }
    for (m.panels.keys()) |p| if (std.mem.indexOfScalar(PanelRef, live.items, p) == null) try live.append(gpa, p);
}

fn checkNoneLost(m: *const DockModel, live: []const PanelRef) !void {
    // Every live panel is open in exactly one group.
    for (live) |p| if (m.groupOf(p) == null) return error.PanelLost;
}

test "random ops keep the invariants" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    var live: std.ArrayList(PanelRef) = .empty;
    defer live.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x5eed_d0c4);
    const n: usize = if (@import("builtin").mode == .Debug) 20_000 else 100_000;
    for (0..n) |_| {
        try randomOp(&m, &live, prng.random());
        try m.validate();
        try checkNoneLost(&m, live.items);
    }
}

test "fuzz: dock" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var m = try DockModel.init(gpa);
            defer m.deinit();
            var live: std.ArrayList(PanelRef) = .empty;
            defer live.deinit(gpa);
            var steps: usize = 0;
            while (!s.eos() and steps < 500) : (steps += 1) {
                var prng: std.Random.DefaultPrng = .init(s.value(u64));
                try randomOp(&m, &live, prng.random());
                try m.validate();
                try checkNoneLost(&m, live.items);
            }
        }
    }.one, .{});
}

test "openIn within its group reorders inside the pinned or unpinned run" {
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const g = center(&m);
    var ps: [4]PanelRef = undefined;
    for (&ps) |*p| p.* = try open(&m, g);
    try m.setPinned(ps[3], true);
    // d | a b c, active d.
    try testing.expectEqualSlices(PanelRef, &.{ ps[3], ps[0], ps[1], ps[2] }, tabs(&m, g));
    // Drop a after c (index 4 counts a at its old place).
    try m.openIn(ps[0], g, 4, .{});
    try testing.expectEqualSlices(PanelRef, &.{ ps[3], ps[1], ps[2], ps[0] }, tabs(&m, g));
    try testing.expectEqual(@as(u32, 3), m.group(g).?.active);
    // Unpinned tabs stay after the pinned ones.
    try m.openIn(ps[2], g, 0, .{});
    try testing.expectEqualSlices(PanelRef, &.{ ps[3], ps[2], ps[1], ps[0] }, tabs(&m, g));
    // A pinned tab stays among the pinned.
    try m.openIn(ps[3], g, 4, .{ .activate = false });
    try testing.expectEqualSlices(PanelRef, &.{ ps[3], ps[2], ps[1], ps[0] }, tabs(&m, g));
    try testing.expectEqual(ps[2], tabs(&m, g)[m.group(g).?.active]);
    // One undo step per reorder.
    try testing.expect(try m.undo());
    try testing.expect(try m.undo());
    try testing.expectEqualSlices(PanelRef, &.{ ps[3], ps[1], ps[2], ps[0] }, tabs(&m, g));
    try m.validate();
}
