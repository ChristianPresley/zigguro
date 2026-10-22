//! `HeightIndex`: row heights in a Fenwick tree, so a virtual list maps a
//! scroll offset to a row and a row to its offset in O(log n), and a row
//! that changes height updates in O(log n) (E04.F04.S02.T01).

const std = @import("std");

/// Heights of `len` rows with prefix sums.
pub const HeightIndex = struct {
    gpa: std.mem.Allocator,
    heights: std.ArrayList(f32) = .empty,
    /// 1-based Fenwick tree over `heights`.
    tree: std.ArrayList(f32) = .empty,

    /// An empty index.
    pub fn init(gpa: std.mem.Allocator) HeightIndex {
        return .{ .gpa = gpa };
    }

    /// Frees the index.
    pub fn deinit(h: *HeightIndex) void {
        h.heights.deinit(h.gpa);
        h.tree.deinit(h.gpa);
    }

    /// Number of rows.
    pub fn len(h: *const HeightIndex) usize {
        return h.heights.items.len;
    }

    /// Sets the row count to `n`; new rows get height `default_h`.
    pub fn resize(h: *HeightIndex, n: usize, default_h: f32) !void {
        const old = h.heights.items.len;
        try h.heights.resize(h.gpa, n);
        if (n > old) @memset(h.heights.items[old..], default_h);
        try h.rebuild();
    }

    /// Rebuilds the tree from `heights` in O(n).
    fn rebuild(h: *HeightIndex) !void {
        const n = h.heights.items.len;
        try h.tree.resize(h.gpa, n + 1);
        h.tree.items[0] = 0;
        @memcpy(h.tree.items[1..], h.heights.items);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const j = i + (i & (~i +% 1));
            if (j <= n) h.tree.items[j] += h.tree.items[i];
        }
    }

    /// The height of row `i`.
    pub fn get(h: *const HeightIndex, i: usize) f32 {
        return h.heights.items[i];
    }

    /// Sets the height of row `i`.
    pub fn set(h: *HeightIndex, i: usize, height: f32) void {
        const d = height - h.heights.items[i];
        if (d == 0) return;
        h.heights.items[i] = height;
        var k = i + 1;
        while (k < h.tree.items.len) : (k += k & (~k +% 1)) h.tree.items[k] += d;
    }

    /// The total height of rows `[0, i)`.
    pub fn prefix(h: *const HeightIndex, i: usize) f32 {
        var sum: f32 = 0;
        var k = @min(i, h.heights.items.len);
        while (k > 0) : (k -= k & (~k +% 1)) sum += h.tree.items[k];
        return sum;
    }

    /// The total height of every row.
    pub fn total(h: *const HeightIndex) f32 {
        return h.prefix(h.heights.items.len);
    }

    /// The row containing offset `y` (the last row when `y` is past the
    /// end, 0 when empty).
    pub fn find(h: *const HeightIndex, y: f32) usize {
        const n = h.heights.items.len;
        if (n == 0) return 0;
        var pos: usize = 0;
        var rem = y;
        var step = std.math.floorPowerOfTwo(usize, n);
        while (step > 0) : (step >>= 1) {
            const next = pos + step;
            if (next <= n and h.tree.items[next] <= rem) {
                pos = next;
                rem -= h.tree.items[next];
            }
        }
        return @min(pos, n - 1);
    }
};

test "prefix sums, updates and find" {
    var h: HeightIndex = .init(std.testing.allocator);
    defer h.deinit();
    try h.resize(1000, 20);
    try std.testing.expectEqual(@as(f32, 20_000), h.total());
    try std.testing.expectEqual(@as(f32, 200), h.prefix(10));
    try std.testing.expectEqual(@as(usize, 10), h.find(200));
    try std.testing.expectEqual(@as(usize, 9), h.find(199.5));
    h.set(5, 120);
    try std.testing.expectEqual(@as(f32, 20_100), h.total());
    try std.testing.expectEqual(@as(f32, 100), h.prefix(5));
    try std.testing.expectEqual(@as(f32, 220), h.prefix(6));
    try std.testing.expectEqual(@as(usize, 5), h.find(219));
    try std.testing.expectEqual(@as(usize, 6), h.find(220));
    try std.testing.expectEqual(@as(usize, 999), h.find(1e9));
    try h.resize(3, 20);
    try std.testing.expectEqual(@as(f32, 60), h.total());
}

test "matches a linear scan on random heights" {
    var prng = std.Random.DefaultPrng.init(0x4482);
    const r = prng.random();
    var h: HeightIndex = .init(std.testing.allocator);
    defer h.deinit();
    try h.resize(257, 1);
    var ref: [257]f32 = undefined;
    for (&ref, 0..) |*x, i| {
        x.* = @floatFromInt(1 + r.uintLessThan(u32, 50));
        h.set(i, x.*);
    }
    var acc: f32 = 0;
    for (ref, 0..) |x, i| {
        try std.testing.expectEqual(acc, h.prefix(i));
        try std.testing.expectEqual(i, h.find(acc));
        try std.testing.expectEqual(i, h.find(acc + x - 0.5));
        acc += x;
    }
}
