//! Geometric compaction: keeps the number of segments logarithmic in the
//! store size by merging the small ones, the way `git repack --geometric`
//! does for packs. Sorted by size, the segments that break a factor-of-two
//! progression are merged (along with any larger ones the merged total
//! catches up with) into one new segment, deduplicated and, by default,
//! deflated. The new segment is published before the old ones are retired,
//! so readers may briefly see an object twice, which is harmless.

const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Segment = store_mod.Segment;
const Allocator = std.mem.Allocator;

pub const CompactOptions = struct {
    /// Each kept segment must be at least `factor` times the total of all
    /// smaller ones.
    factor: u32 = 2,
    /// Merge every segment into one.
    all: bool = false,
    /// Deflate compressible records while copying them.
    deflate: bool = true,
};

pub const CompactReport = struct {
    merged: usize = 0,
    objects: usize = 0,
};

fn size(sg: *const Segment) u64 {
    return sg.data.bytes.len;
}

fn smaller(_: void, a: *Segment, b: *Segment) bool {
    return size(a) < size(b);
}

/// How many of `sorted` (ascending by size) to merge, counted from the
/// smallest; 0 or 1 means nothing to do.
pub fn mergeCount(sorted: []const u64, factor: u32) usize {
    const n = sorted.len;
    if (n < 2) return 0;
    // From the top, find the first pair that breaks the progression.
    var split: usize = n - 1;
    while (split > 0) : (split -= 1) {
        if (sorted[split] < @as(u64, factor) * sorted[split - 1]) break;
    }
    if (split == 0) return 0;
    var total: u64 = 0;
    for (sorted[0 .. split + 1]) |x| total += x;
    var count = split + 1;
    while (count < n and sorted[count] < @as(u64, factor) * total) : (count += 1) total += sorted[count];
    return count;
}

/// Merges segments as described in the file comment.
pub fn compact(s: *Store, opts: CompactOptions) !CompactReport {
    const gpa = s.gpa;
    try s.rescan();
    const segs = try s.snapshot(gpa);
    defer Store.releaseSnapshot(gpa, segs);
    std.mem.sort(*Segment, segs, {}, smaller);
    const sizes = try gpa.alloc(u64, segs.len);
    defer gpa.free(sizes);
    for (segs, sizes) |sg, *z| z.* = size(sg);
    const n = if (opts.all) segs.len else mergeCount(sizes, opts.factor);
    if (n < 2) return .{};
    const pick = segs[0..n];

    var b = s.batch();
    defer b.abort();
    for (pick) |sg| {
        for (0..sg.index.count) |k| {
            const i: u32 = @intCast(k);
            try b.copyRecord(sg.index.id(i), try sg.record(i), opts.deflate);
        }
    }
    const objects = b.entries.items.len;
    try b.commit();
    s.retire(pick);
    return .{ .merged = n, .objects = objects };
}

test "compaction: geometric merge count" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), mergeCount(&.{ 1, 2, 4, 8 }, 2));
    try t.expectEqual(@as(usize, 0), mergeCount(&.{100}, 2));
    try t.expectEqual(@as(usize, 3), mergeCount(&.{ 1, 1, 1, 100 }, 2));
    try t.expectEqual(@as(usize, 0), mergeCount(&.{ 1, 2, 4, 10, 100 }, 2));
    // 7 < 2 * 4 breaks the progression; 100 stays.
    try t.expectEqual(@as(usize, 4), mergeCount(&.{ 1, 1, 4, 7, 100 }, 2));
    // The merged total (1 + 1 + 3 = 5) catches up with 9.
    try t.expectEqual(@as(usize, 4), mergeCount(&.{ 1, 1, 3, 9, 100 }, 2));
    try t.expectEqual(@as(usize, 8), mergeCount(&([_]u64{5} ** 8), 2));
}
