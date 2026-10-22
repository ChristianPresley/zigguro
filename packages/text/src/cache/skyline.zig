//! Skyline bottom-left rectangle packing for atlas pages (Jylänki, "A
//! Thousand Ways to Pack the Bin", Skyline-BL with the min-waste tie
//! break).
//!
//! The skyline is the top edge of everything packed so far, as segments
//! sorted by x that tile the page width. A request goes where its bottom
//! edge ends lowest; among equal bottoms, where it leaves the least area
//! wasted under it. Segments never outnumber the page width, so `init`
//! reserves them all and `alloc` never allocates.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One horizontal run of the skyline: [x, x + w) is filled up to y.
const Segment = struct { x: u16, y: u16, w: u16 };

/// The top-left corner of a packed rectangle.
pub const Pos = struct { x: u16, y: u16 };

/// A packer for one `w`×`h` page.
pub const Skyline = struct {
    gpa: Allocator,
    w: u16,
    h: u16,
    segs: std.ArrayList(Segment),
    used: u64 = 0,
    /// A size that did not fit: the skyline only rises, so nothing at
    /// least this wide and tall fits either (saves rescanning full pages).
    fail_w: u16 = std.math.maxInt(u16),
    fail_h: u16 = std.math.maxInt(u16),

    /// An empty page; reserves room for the most segments it can hold.
    pub fn init(gpa: Allocator, w: u16, h: u16) Allocator.Error!Skyline {
        var s: Skyline = .{ .gpa = gpa, .w = w, .h = h, .segs = .empty };
        try s.segs.ensureTotalCapacity(gpa, @as(usize, w) + 1);
        s.reset();
        return s;
    }

    /// Frees the segment list.
    pub fn deinit(s: *Skyline) void {
        s.segs.deinit(s.gpa);
        s.* = undefined;
    }

    /// Empties the page.
    pub fn reset(s: *Skyline) void {
        s.segs.clearRetainingCapacity();
        s.segs.appendAssumeCapacity(.{ .x = 0, .y = 0, .w = s.w });
        s.used = 0;
        s.fail_w = std.math.maxInt(u16);
        s.fail_h = std.math.maxInt(u16);
    }

    /// The top-left corner of a free `w`×`h` rectangle, now taken, or null
    /// when none fits.
    pub fn alloc(s: *Skyline, w: u16, h: u16) ?Pos {
        if (w == 0 or h == 0 or w > s.w or h > s.h) return null;
        if (w >= s.fail_w and h >= s.fail_h) return null;
        const segs = s.segs.items;
        var best: Fit = .{};
        for (segs, 0..) |seg, i| {
            if (@as(u32, seg.x) + w > s.w) break;
            // It rests at least as high as this segment: no better spot.
            if (@as(u32, seg.y) + h > best.bottom) continue;
            s.consider(i, w, h, &best);
        }
        const best_i = best.i;
        const best_y = best.y;
        const best_bottom = best.bottom;
        if (best_bottom == std.math.maxInt(u32)) {
            if (@as(u32, w) * h < @as(u32, s.fail_w) * s.fail_h) {
                s.fail_w = w;
                s.fail_h = h;
            }
            return null;
        }
        const x = segs[best_i].x;
        s.place(best_i, x, w, @intCast(best_bottom));
        s.used += @as(u64, w) * h;
        return .{ .x = x, .y = @intCast(best_y) };
    }

    /// The best spot so far.
    const Fit = struct {
        i: usize = 0,
        y: u32 = 0,
        bottom: u32 = std.math.maxInt(u32),
        waste: u64 = std.math.maxInt(u64),
    };

    /// Takes the spot with its left edge at segment `i` (which leaves
    /// room for `w`) into `best` when it ends lower, or as low with less
    /// waste (candidates come left to right, so ties stay leftmost).
    fn consider(s: *const Skyline, i: usize, w: u16, h: u16, best: *Fit) void {
        const segs = s.segs.items;
        // The rectangle rests on the highest segment it spans; stop as
        // soon as it would end lower than the best so far.
        const limit = @min(best.bottom, s.h);
        var y: u32 = 0;
        var left: u32 = w;
        var j = i;
        while (left > 0 and y + h <= limit) : (j += 1) {
            y = @max(y, segs[j].y);
            left -|= segs[j].w;
        }
        const bottom = y + h;
        if (bottom > limit) return;
        var waste: u64 = 0;
        left = w;
        j = i;
        while (left > 0) : (j += 1) {
            const span = @min(left, segs[j].w);
            waste += @as(u64, y - segs[j].y) * span;
            left -= span;
        }
        if (bottom < best.bottom or waste < best.waste) {
            best.* = .{ .i = i, .y = y, .bottom = bottom, .waste = waste };
        }
    }

    /// Fraction of the page area handed out.
    pub fn occupancy(s: *const Skyline) f32 {
        return @floatCast(@as(f64, @floatFromInt(s.used)) / (@as(f64, @floatFromInt(s.w)) * @as(f64, @floatFromInt(s.h))));
    }

    /// Raises [x, x + w) to `top`, starting at segment `i` (which begins
    /// at x), then merges equal neighbours.
    fn place(s: *Skyline, i: usize, x: u16, w: u16, top: u16) void {
        const end = x + w;
        // Segments wholly under the new one go; one that sticks out past
        // its end is shortened.
        var j = i;
        while (j < s.segs.items.len and s.segs.items[j].x < end) : (j += 1) {
            const seg = &s.segs.items[j];
            const seg_end = seg.x + seg.w;
            if (seg_end > end) {
                seg.w = seg_end - end;
                seg.x = end;
                break;
            }
        }
        // Segments i..j are covered; replace them with the new one.
        const removed = j - i;
        if (removed == 0) {
            s.segs.insertAssumeCapacity(i, .{ .x = x, .y = top, .w = w });
        } else {
            s.segs.items[i] = .{ .x = x, .y = top, .w = w };
            const tail = s.segs.items[j..];
            std.mem.copyForwards(Segment, s.segs.items[i + 1 ..][0..tail.len], tail);
            s.segs.items.len -= removed - 1;
        }
        // Merge with equal-height neighbours.
        if (i + 1 < s.segs.items.len and s.segs.items[i + 1].y == top) {
            s.segs.items[i].w += s.segs.items[i + 1].w;
            _ = s.segs.orderedRemove(i + 1);
        }
        if (i > 0 and s.segs.items[i - 1].y == top) {
            s.segs.items[i - 1].w += s.segs.items[i].w;
            _ = s.segs.orderedRemove(i);
        }
    }
};

const testing = std.testing;

/// Packs random rectangles and checks every placement against an
/// occupancy bitmap.
fn packRandom(seed: u64, page: u16, n: usize, min: u16, max: u16) !f32 {
    var s = try Skyline.init(testing.allocator, page, page);
    defer s.deinit();
    const taken = try testing.allocator.alloc(bool, @as(usize, page) * page);
    defer testing.allocator.free(taken);
    @memset(taken, false);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (0..n) |_| {
        const w = r.intRangeAtMost(u16, min, max);
        const h = r.intRangeAtMost(u16, min, max);
        const p = s.alloc(w, h) orelse continue;
        try testing.expect(@as(u32, p.x) + w <= page and @as(u32, p.y) + h <= page);
        for (p.y..p.y + h) |y| for (p.x..p.x + w) |x| {
            try testing.expect(!taken[y * page + x]);
            taken[y * page + x] = true;
        };
    }
    // The skyline tiles the width in order.
    var x: u32 = 0;
    for (s.segs.items) |seg| {
        try testing.expectEqual(x, seg.x);
        x += seg.w;
    }
    try testing.expectEqual(@as(u32, page), x);
    return s.occupancy();
}

test "skyline packs without overlap" {
    for (0..8) |seed| _ = try packRandom(seed, 256, 2000, 1, 40);
    _ = try packRandom(99, 64, 500, 1, 64);
}

test "skyline occupancy >= 0.8 for glyph-like sizes" {
    // Glyph bitmaps at 12–24 px plus padding: 6–22 wide, 8–28 tall.
    var s = try Skyline.init(testing.allocator, 512, 512);
    defer s.deinit();
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var misses: usize = 0;
    while (misses < 50) {
        if (s.alloc(r.intRangeAtMost(u16, 6, 22), r.intRangeAtMost(u16, 8, 28)) == null) misses += 1;
    }
    try testing.expect(s.occupancy() >= 0.8);
}

test "skyline rejects what cannot fit and resets" {
    var s = try Skyline.init(testing.allocator, 16, 16);
    defer s.deinit();
    try testing.expect(s.alloc(17, 1) == null);
    try testing.expect(s.alloc(0, 4) == null);
    const a = s.alloc(16, 10).?;
    try testing.expectEqual(@as(u16, 0), a.y);
    try testing.expect(s.alloc(4, 7) == null);
    const b = s.alloc(4, 6).?;
    try testing.expectEqual(@as(u16, 10), b.y);
    s.reset();
    try testing.expectEqual(@as(f32, 0), s.occupancy());
    try testing.expect(s.alloc(16, 16) != null);
    try testing.expectEqual(@as(f32, 1), s.occupancy());
}

test "skyline bottom-left prefers the lower spot" {
    var s = try Skyline.init(testing.allocator, 30, 30);
    defer s.deinit();
    _ = s.alloc(10, 20).?; // [0,10) up to 20
    _ = s.alloc(10, 5).?; // [10,20) up to 5
    // A 10×5 fits on [20,30) at y 0 (bottom 5), lower than on [10,20).
    const p = s.alloc(10, 5).?;
    try testing.expectEqual(@as(u16, 20), p.x);
    try testing.expectEqual(@as(u16, 0), p.y);
}
