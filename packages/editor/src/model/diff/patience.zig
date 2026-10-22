//! Patience diff (Bram Cohen): anchor on elements that occur exactly once
//! in each side, keep the anchors whose order agrees on both sides (the
//! longest increasing subsequence, by patience sorting in O(n log n)), and
//! recurse between them. Regions without unique elements fall back to
//! Myers. Reordered or moved code reads better than with plain Myers.

const std = @import("std");
const script = @import("script.zig");
const myers_mod = @import("myers.zig");

const Allocator = std.mem.Allocator;
const Edit = script.Edit;
const Marks = script.Marks;

/// The patience edit script turning `a` into `b`.
pub fn patience(gpa: Allocator, a: []const u32, b: []const u32, deadline: ?script.Deadline) Allocator.Error![]Edit {
    var m = try Marks.init(gpa, a, b, deadline);
    defer m.deinit(gpa);
    try markRegion(gpa, &m, 0, a.len, 0, b.len);
    return m.toScript(gpa);
}

const Count = struct { a: u32 = 0, b: u32 = 0, a_pos: u32 = 0, b_pos: u32 = 0 };

/// Marks `a[alo..ahi]` x `b[blo..bhi]` with patience.
pub fn markRegion(gpa: Allocator, m: *Marks, alo_in: usize, ahi_in: usize, blo_in: usize, bhi_in: usize) Allocator.Error!void {
    var alo = alo_in;
    var ahi = ahi_in;
    var blo = blo_in;
    var bhi = bhi_in;
    m.trim(&alo, &ahi, &blo, &bhi);
    if (alo == ahi or blo == bhi or m.checkTime()) {
        m.markAll(alo, ahi, blo, bhi);
        return;
    }
    var counts: std.AutoHashMapUnmanaged(u32, Count) = .empty;
    defer counts.deinit(gpa);
    for (alo..ahi) |i| {
        const g = try counts.getOrPut(gpa, m.a[i]);
        if (!g.found_existing) g.value_ptr.* = .{};
        g.value_ptr.a += 1;
        g.value_ptr.a_pos = @intCast(i);
    }
    for (blo..bhi) |j| {
        const g = counts.getPtr(m.b[j]) orelse continue;
        g.b += 1;
        g.b_pos = @intCast(j);
    }
    // Unique pairs in `a` order; their `b` positions feed the LIS.
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    for (alo..ahi) |i| {
        const c = counts.get(m.a[i]).?;
        if (c.a == 1 and c.b == 1) try pairs.append(gpa, .{ @intCast(i), c.b_pos });
    }
    if (pairs.items.len == 0) {
        return myers_mod.markRegion(gpa, m, alo, ahi, blo, bhi, false);
    }
    const anchors = try lis(gpa, pairs.items);
    defer gpa.free(anchors);
    var pa = alo;
    var pb = blo;
    for (anchors) |k| {
        const p = pairs.items[k];
        try markRegion(gpa, m, pa, p[0], pb, p[1]);
        pa = p[0] + 1;
        pb = p[1] + 1;
    }
    try markRegion(gpa, m, pa, ahi, pb, bhi);
}

/// Indices into `pairs` of a longest subsequence increasing in `[1]`
/// (pairs are already increasing in `[0]`).
pub fn lis(gpa: Allocator, pairs: []const [2]u32) Allocator.Error![]usize {
    // tails[k]: index of the smallest tail of an increasing run of length k+1.
    const tails = try gpa.alloc(usize, pairs.len);
    defer gpa.free(tails);
    const prev = try gpa.alloc(usize, pairs.len);
    defer gpa.free(prev);
    var len: usize = 0;
    for (pairs, 0..) |p, i| {
        var lo: usize = 0;
        var hi: usize = len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (pairs[tails[mid]][1] < p[1]) lo = mid + 1 else hi = mid;
        }
        prev[i] = if (lo > 0) tails[lo - 1] else std.math.maxInt(usize);
        tails[lo] = i;
        if (lo == len) len += 1;
    }
    const out = try gpa.alloc(usize, len);
    var k = if (len > 0) tails[len - 1] else 0;
    var w = len;
    while (w > 0) {
        w -= 1;
        out[w] = k;
        k = prev[k];
    }
    return out;
}
