//! Buffer-age damage tracking (E02.F04.S03.T02): the repaint region for an
//! image of a given age, simplified to at most 16 rects, and the present
//! hints (`VkPresentRegionsKHR`, E01 damage, readback copy rects).
//!
//! Age N means the image shows the content of N frames ago, so the repaint
//! is the current damage plus the damage of the previous N - 1 frames.
//! Age 0 (new or unknown) and ages beyond the history repaint everything.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const rect = @import("../r2d/rect.zig");

pub const PxRect = rect.PxRect;
pub const Size = rect.Size;

/// Rects cheaper to overdraw than to scissor separately (`64 × 64`).
pub const merge_slack: u64 = 64 * 64;
/// Above this share of the extent (60%) a full redraw is cheaper.
pub const full_ratio_num: u64 = 3;
pub const full_ratio_den: u64 = 5;

/// Up to 16 rects.
pub const RectList = struct {
    pub const capacity = 16;
    items: [capacity]PxRect = undefined,
    len: u8 = 0,

    /// Appends `r`; when full, `r` is merged into the last rect.
    pub fn add(self: *RectList, r: PxRect) void {
        if (rect.isEmpty(r)) return;
        if (self.len == capacity) {
            self.items[capacity - 1] = rect.unionBox(self.items[capacity - 1], r);
            return;
        }
        self.items[self.len] = r;
        self.len += 1;
    }

    pub fn slice(self: *const RectList) []const PxRect {
        return self.items[0..self.len];
    }

    /// Sum of the rect areas (overlaps counted twice).
    pub fn area(self: RectList) u64 {
        var a: u64 = 0;
        for (self.items[0..self.len]) |r| a += rect.area(r);
        return a;
    }

    /// True when the list is exactly the full `extent`.
    pub fn isFull(self: *const RectList, extent: Size) bool {
        return self.len == 1 and std.meta.eql(self.items[0], rect.full(extent));
    }
};

fn lessYX(_: void, a: PxRect, b: PxRect) bool {
    return if (a.y != b.y) a.y < b.y else a.x < b.x;
}

fn growth(a: PxRect, b: PxRect) u64 {
    const u = rect.area(rect.unionBox(a, b));
    const sum = rect.area(a) + rect.area(b);
    return u -| sum;
}

/// Clamps, merges and bounds `rects` to at most 16 rects covering every
/// input pixel inside `extent`. Deterministic.
pub fn simplify(rects: []const PxRect, extent: Size, out: *RectList) void {
    out.len = 0;
    if (extent.w == 0 or extent.h == 0) return;
    // Work list: clamped, non-empty, sorted. Inputs beyond the work list's
    // capacity are folded into their nearest neighbour first.
    var work: [64]PxRect = undefined;
    var n: usize = 0;
    for (rects) |r| {
        const c = rect.clamp(r, extent);
        if (rect.isEmpty(c)) continue;
        if (n < work.len) {
            work[n] = c;
            n += 1;
        } else {
            var best: usize = 0;
            var best_g: u64 = std.math.maxInt(u64);
            for (work[0..n], 0..) |w, i| {
                const g = growth(w, c);
                if (g < best_g) {
                    best_g = g;
                    best = i;
                }
            }
            work[best] = rect.unionBox(work[best], c);
        }
    }
    std.mem.sort(PxRect, work[0..n], {}, lessYX);

    // Greedy cheap merges until nothing changes.
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        outer: while (i < n) : (i += 1) {
            var j = i + 1;
            while (j < n) : (j += 1) {
                if (growth(work[i], work[j]) <= merge_slack) {
                    work[i] = rect.unionBox(work[i], work[j]);
                    std.mem.copyForwards(PxRect, work[j .. n - 1], work[j + 1 .. n]);
                    n -= 1;
                    changed = true;
                    continue :outer;
                }
            }
        }
    }
    // Then the cheapest merges until at most 16 remain.
    while (n > RectList.capacity) {
        var bi: usize = 0;
        var bj: usize = 1;
        var best_g: u64 = std.math.maxInt(u64);
        for (0..n) |i| for (i + 1..n) |j| {
            const g = growth(work[i], work[j]);
            if (g < best_g) {
                best_g = g;
                bi = i;
                bj = j;
            }
        };
        work[bi] = rect.unionBox(work[bi], work[bj]);
        std.mem.copyForwards(PxRect, work[bj .. n - 1], work[bj + 1 .. n]);
        n -= 1;
    }
    var total: u64 = 0;
    for (work[0..n]) |r| total += rect.area(r);
    const ext_area = @as(u64, extent.w) * extent.h;
    if (total * full_ratio_den > ext_area * full_ratio_num) {
        out.add(rect.full(extent));
        return;
    }
    for (work[0..n]) |r| out.add(r);
}

/// The damage of the last `max_age` presented frames.
pub const DamageHistory = struct {
    pub const max_age = 4;

    frames: [max_age]RectList = @splat(.{}),
    /// Whether each entry was a full-frame repaint.
    full: [max_age]bool = @splat(true),
    /// Frames pushed so far (index of the next entry).
    count: u64 = 0,

    pub fn init() DamageHistory {
        return .{};
    }

    /// Records the damage of the frame just presented (its current damage,
    /// not the age-expanded repaint).
    pub fn push(self: *DamageHistory, frame_damage: []const PxRect) void {
        const e = &self.frames[self.count % max_age];
        e.len = 0;
        for (frame_damage) |r| e.add(r);
        self.full[self.count % max_age] = false;
        self.count += 1;
    }

    /// Records a frame that changed everything.
    pub fn pushFull(self: *DamageHistory) void {
        self.frames[self.count % max_age].len = 0;
        self.full[self.count % max_age] = true;
        self.count += 1;
    }

    /// The region to repaint in an image of `age` for `current` damage.
    pub fn repaintFor(self: *const DamageHistory, age: u32, current: []const PxRect, extent: Size, out: *RectList) void {
        if (age == 0 or age > max_age or age - 1 > self.count) {
            out.len = 0;
            out.add(rect.full(extent));
            return;
        }
        var all: [RectList.capacity * max_age + 64]PxRect = undefined;
        var n: usize = 0;
        for (current) |r| {
            if (n == all.len) break;
            all[n] = r;
            n += 1;
        }
        var k: u32 = 1;
        while (k < age) : (k += 1) {
            const idx = (self.count - k) % max_age;
            if (self.full[idx]) {
                out.len = 0;
                out.add(rect.full(extent));
                return;
            }
            for (self.frames[idx].slice()) |r| {
                if (n == all.len) break;
                all[n] = r;
                n += 1;
            }
        }
        simplify(all[0..n], extent, out);
    }

    /// Forgets everything (resize, expose, device recreation): the next
    /// frames of every age repaint fully.
    pub fn invalidateAll(self: *DamageHistory) void {
        self.* = .{};
    }
};

/// `rects` as `VkRectLayerKHR` (layer 0, top-left origin) in `buf`.
pub fn toPresentRegions(rects: []const PxRect, buf: []vk.RectLayerKHR) []vk.RectLayerKHR {
    const n = @min(rects.len, buf.len);
    for (rects[0..n], buf[0..n]) |r, *o| o.* = .{
        .offset = .{ .x = r.x, .y = r.y },
        .extent = .{ .width = r.w, .height = r.h },
        .layer = 0,
    };
    return buf[0..n];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn px(x: i32, y: i32, w: u32, h: u32) PxRect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

test "damage: age 0 → full" {
    var h = DamageHistory.init();
    h.push(&.{px(0, 0, 4, 4)});
    var out: RectList = .{};
    h.repaintFor(0, &.{px(1, 1, 2, 2)}, .{ .w = 100, .h = 50 }, &out);
    try testing.expect(out.isFull(.{ .w = 100, .h = 50 }));
    h.repaintFor(DamageHistory.max_age + 1, &.{px(1, 1, 2, 2)}, .{ .w = 100, .h = 50 }, &out);
    try testing.expect(out.isFull(.{ .w = 100, .h = 50 }));
}

test "damage: age 2 unions previous frame" {
    const ext: Size = .{ .w = 1000, .h = 1000 };
    var h = DamageHistory.init();
    h.push(&.{px(500, 500, 10, 10)});
    var out: RectList = .{};
    // Age 1: current damage only.
    h.repaintFor(1, &.{px(0, 0, 10, 10)}, ext, &out);
    try testing.expectEqualSlices(PxRect, &.{px(0, 0, 10, 10)}, out.slice());
    // Age 2: plus the previous frame's damage.
    h.repaintFor(2, &.{px(0, 0, 10, 10)}, ext, &out);
    try testing.expectEqualSlices(PxRect, &.{ px(0, 0, 10, 10), px(500, 500, 10, 10) }, out.slice());
    // A full frame in the window forces a full repaint.
    h.pushFull();
    h.repaintFor(2, &.{px(0, 0, 10, 10)}, ext, &out);
    try testing.expect(out.isFull(ext));
    h.invalidateAll();
    h.repaintFor(1, &.{px(0, 0, 10, 10)}, ext, &out);
    try testing.expectEqual(@as(u8, 1), out.len);
}

test "damage: > 60% → full" {
    var out: RectList = .{};
    simplify(&.{ px(0, 0, 70, 100), px(-50, -50, 10, 10) }, .{ .w = 100, .h = 100 }, &out);
    try testing.expect(out.isFull(.{ .w = 100, .h = 100 }));
    simplify(&.{px(0, 0, 50, 100)}, .{ .w = 100, .h = 100 }, &out);
    try testing.expectEqualSlices(PxRect, &.{px(0, 0, 50, 100)}, out.slice());
    simplify(&.{px(200, 200, 5, 5)}, .{ .w = 100, .h = 100 }, &out);
    try testing.expectEqual(@as(u8, 0), out.len);
}

test "damage: present regions conversion" {
    var buf: [4]vk.RectLayerKHR = undefined;
    const r = toPresentRegions(&.{ px(1, 2, 3, 4), px(5, 6, 7, 8) }, &buf);
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqual(@as(i32, 5), r[1].offset.x);
    try testing.expectEqual(@as(u32, 8), r[1].extent.height);
    try testing.expectEqual(@as(u32, 0), r[0].layer);
}

/// Checks on a bitmap that `out` covers every pixel of `in` inside the
/// extent and stays within the extent.
fn expectCovers(in: []const PxRect, ext: Size, out: *const RectList) !void {
    try testing.expect(out.len <= RectList.capacity);
    for (out.slice()) |o| try testing.expect(rect.contains(rect.full(ext), o) and !rect.isEmpty(o));
    var y: i32 = 0;
    while (y < ext.h) : (y += 1) {
        var x: i32 = 0;
        while (x < ext.w) : (x += 1) {
            const p = px(x, y, 1, 1);
            const needed = for (in) |r| {
                if (rect.contains(r, p)) break true;
            } else false;
            if (!needed) continue;
            const covered = for (out.slice()) |r| {
                if (rect.contains(r, p)) break true;
            } else false;
            try testing.expect(covered);
        }
    }
}

fn randomRects(rnd: std.Random, buf: []PxRect, ext: Size) []PxRect {
    const n = rnd.uintLessThan(usize, buf.len + 1);
    for (buf[0..n]) |*r| r.* = px(
        rnd.intRangeAtMost(i32, -20, @intCast(ext.w + 10)),
        rnd.intRangeAtMost(i32, -20, @intCast(ext.h + 10)),
        rnd.uintAtMost(u32, 40),
        rnd.uintAtMost(u32, 40),
    );
    return buf[0..n];
}

test "damage: simplify ≤ 16 and covers all input" {
    var prng = std.Random.DefaultPrng.init(0xda3a6e);
    const ext: Size = .{ .w = 200, .h = 120 };
    var buf: [80]PxRect = undefined;
    for (0..300) |_| {
        const in = randomRects(prng.random(), &buf, ext);
        var out: RectList = .{};
        simplify(in, ext, &out);
        try expectCovers(in, ext, &out);
    }
}

test "fuzz: damage simplify covers inputs" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var bytes: [8 * 70]u8 = undefined;
            const input = bytes[0..s.slice(&bytes)];
            var rects: [70]PxRect = undefined;
            const n = input.len / 8;
            for (rects[0..n], 0..) |*r, i| {
                const b = input[i * 8 ..][0..8];
                r.* = px(@as(i32, @as(i8, @bitCast(b[0]))) * 2, @as(i32, @as(i8, @bitCast(b[1]))) * 2, b[2] % 64, b[3] % 64);
            }
            var out: RectList = .{};
            const ext: Size = .{ .w = 128, .h = 96 };
            simplify(rects[0..n], ext, &out);
            try expectCovers(rects[0..n], ext, &out);
        }
    }.one, .{});
}
