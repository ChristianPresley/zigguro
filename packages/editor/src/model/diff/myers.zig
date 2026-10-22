//! Myers' O(ND) diff (Myers 1986) in linear space: the forward and reverse
//! searches run together until they meet (the middle snake, §4b), and the
//! region is split there and both halves recursed. Common prefixes and
//! suffixes are trimmed first, and elements that occur on one side only
//! are discarded before the search (they can never match).
//!
//! Without `minimal`, a cost limit bounds the search as git's xdiff does:
//! once D passes `max(256, sqrt(N + M))`, the region is split at the
//! furthest-reaching forward diagonal instead. A deadline turns the
//! remaining regions into delete plus insert.

const std = @import("std");
const script = @import("script.zig");

const Allocator = std.mem.Allocator;
const Edit = script.Edit;
const Marks = script.Marks;

/// Myers options.
pub const Options = struct {
    /// Disable the cost limit (git `--minimal`): the script is shortest.
    minimal: bool = false,
    deadline: ?script.Deadline = null,
};

/// The edit script turning `a` into `b`.
pub fn myers(gpa: Allocator, a: []const u32, b: []const u32, o: Options) Allocator.Error![]Edit {
    var m = try Marks.init(gpa, a, b, o.deadline);
    defer m.deinit(gpa);
    try markDiscarding(gpa, &m, o.minimal);
    return m.toScript(gpa);
}

/// Marks the whole of `m`, first discarding elements absent from the
/// other side.
pub fn markDiscarding(gpa: Allocator, m: *Marks, minimal: bool) Allocator.Error!void {
    var max_id: u32 = 0;
    for (m.a) |x| max_id = @max(max_id, x);
    for (m.b) |x| max_id = @max(max_id, x);
    const in_a = try std.DynamicBitSetUnmanaged.initEmpty(gpa, @as(usize, max_id) + 1);
    var in_a_m = in_a;
    defer in_a_m.deinit(gpa);
    var in_b = try std.DynamicBitSetUnmanaged.initEmpty(gpa, @as(usize, max_id) + 1);
    defer in_b.deinit(gpa);
    for (m.a) |x| in_a_m.set(x);
    for (m.b) |x| in_b.set(x);
    // Compact the matchable elements, run the core, map the marks back.
    var ia: std.ArrayList(u32) = .empty;
    defer ia.deinit(gpa);
    var ib: std.ArrayList(u32) = .empty;
    defer ib.deinit(gpa);
    for (m.a, 0..) |x, i| if (in_b.isSet(x)) try ia.append(gpa, @intCast(i)) else {
        m.ca[i] = true;
    };
    for (m.b, 0..) |x, j| if (in_a_m.isSet(x)) try ib.append(gpa, @intCast(j)) else {
        m.cb[j] = true;
    };
    if (ia.items.len == m.a.len and ib.items.len == m.b.len) {
        return markRegion(gpa, m, 0, m.a.len, 0, m.b.len, minimal);
    }
    const ca2 = try gpa.alloc(u32, ia.items.len);
    defer gpa.free(ca2);
    const cb2 = try gpa.alloc(u32, ib.items.len);
    defer gpa.free(cb2);
    for (ia.items, ca2) |i, *x| x.* = m.a[i];
    for (ib.items, cb2) |j, *x| x.* = m.b[j];
    var sub = try Marks.init(gpa, ca2, cb2, m.deadline);
    defer sub.deinit(gpa);
    sub.polls = m.polls;
    try markRegion(gpa, &sub, 0, ca2.len, 0, cb2.len, minimal);
    m.timed_out = sub.timed_out;
    for (ia.items, sub.ca) |i, c| m.ca[i] = c;
    for (ib.items, sub.cb) |j, c| m.cb[j] = c;
}

/// Marks the region `a[alo..ahi]` x `b[blo..bhi]`.
pub fn markRegion(gpa: Allocator, m: *Marks, alo: usize, ahi: usize, blo: usize, bhi: usize, minimal: bool) Allocator.Error!void {
    const n = (ahi - alo) + (bhi - blo);
    const v = try gpa.alloc(i64, 2 * (n + 4));
    defer gpa.free(v);
    var ctx: Ctx = .{ .m = m, .v1 = v[0 .. n + 4], .v2 = v[n + 4 ..], .minimal = minimal, .cost_limit = costLimit(n) };
    ctx.compare(alo, ahi, blo, bhi);
}

fn costLimit(n: usize) i64 {
    const r = std.math.sqrt(n);
    return @intCast(@max(256, r));
}

const Ctx = struct {
    m: *Marks,
    v1: []i64,
    v2: []i64,
    minimal: bool,
    cost_limit: i64,

    fn compare(c: *Ctx, alo_in: usize, ahi_in: usize, blo_in: usize, bhi_in: usize) void {
        var alo = alo_in;
        var ahi = ahi_in;
        var blo = blo_in;
        var bhi = bhi_in;
        c.m.trim(&alo, &ahi, &blo, &bhi);
        if (alo == ahi or blo == bhi or c.m.timed_out) {
            c.m.markAll(alo, ahi, blo, bhi);
            return;
        }
        const s = c.bisect(alo, ahi, blo, bhi) orelse {
            c.m.markAll(alo, ahi, blo, bhi);
            return;
        };
        if ((s.x == alo and s.y == blo) or (s.x == ahi and s.y == bhi)) {
            c.m.markAll(alo, ahi, blo, bhi); // no progress (defensive)
            return;
        }
        c.compare(alo, s.x, blo, s.y);
        c.compare(s.x, ahi, s.y, bhi);
    }

    const Split = struct { x: usize, y: usize };

    /// The middle snake of the region (after trimming, so both sides are
    /// non-empty and differ at both ends). Null when nothing matches or the
    /// deadline passed.
    fn bisect(c: *Ctx, alo: usize, ahi: usize, blo: usize, bhi: usize) ?Split {
        const a = c.m.a[alo..ahi];
        const b = c.m.b[blo..bhi];
        const n: i64 = @intCast(a.len);
        const mm: i64 = @intCast(b.len);
        const max_d: i64 = @divTrunc(n + mm + 1, 2);
        const v_off = max_d;
        const v_len: usize = @intCast(2 * max_d + 2);
        const v1 = c.v1[0..v_len];
        const v2 = c.v2[0..v_len];
        @memset(v1, -1);
        @memset(v2, -1);
        v1[@intCast(v_off + 1)] = 0;
        v2[@intCast(v_off + 1)] = 0;
        const delta = n - mm;
        const front = @mod(delta, 2) != 0;
        var k1start: i64 = 0;
        var k1end: i64 = 0;
        var k2start: i64 = 0;
        var k2end: i64 = 0;
        var d: i64 = 0;
        while (d < max_d) : (d += 1) {
            if (c.m.checkTime()) return null;
            if (!c.minimal and d > c.cost_limit) {
                // Give up on optimality: split at the furthest-reaching
                // forward point (x + y is at least d, so both halves shrink).
                var best: ?Split = null;
                var best_sum: i64 = -1;
                var k = -d + 1 + k1start;
                while (k <= d - 1 - k1end) : (k += 2) {
                    const x = v1[@intCast(v_off + k)];
                    if (x < 0) continue;
                    const y = x - k;
                    if (x > n or y > mm or y < 0) continue;
                    if (x + y > best_sum and x + y < n + mm and x + y > 0) {
                        best_sum = x + y;
                        best = .{ .x = alo + @as(usize, @intCast(x)), .y = blo + @as(usize, @intCast(y)) };
                    }
                }
                if (best) |s| return s;
            }
            var k1 = -d + k1start;
            while (k1 <= d - k1end) : (k1 += 2) {
                const k1o: usize = @intCast(v_off + k1);
                var x1: i64 = if (k1 == -d or (k1 != d and v1[k1o - 1] < v1[k1o + 1])) v1[k1o + 1] else v1[k1o - 1] + 1;
                var y1 = x1 - k1;
                while (x1 < n and y1 < mm and a[@intCast(x1)] == b[@intCast(y1)]) {
                    x1 += 1;
                    y1 += 1;
                }
                v1[k1o] = x1;
                if (x1 > n) {
                    k1end += 2;
                } else if (y1 > mm) {
                    k1start += 2;
                } else if (front) {
                    const k2o = v_off + delta - k1;
                    if (k2o >= 0 and k2o < v_len and v2[@intCast(k2o)] != -1) {
                        const x2 = n - v2[@intCast(k2o)];
                        if (x1 >= x2) return .{ .x = alo + @as(usize, @intCast(x1)), .y = blo + @as(usize, @intCast(y1)) };
                    }
                }
            }
            var k2 = -d + k2start;
            while (k2 <= d - k2end) : (k2 += 2) {
                const k2o: usize = @intCast(v_off + k2);
                var x2: i64 = if (k2 == -d or (k2 != d and v2[k2o - 1] < v2[k2o + 1])) v2[k2o + 1] else v2[k2o - 1] + 1;
                var y2 = x2 - k2;
                while (x2 < n and y2 < mm and a[@intCast(n - x2 - 1)] == b[@intCast(mm - y2 - 1)]) {
                    x2 += 1;
                    y2 += 1;
                }
                v2[k2o] = x2;
                if (x2 > n) {
                    k2end += 2;
                } else if (y2 > mm) {
                    k2start += 2;
                } else if (!front) {
                    const k1o = v_off + delta - k2;
                    if (k1o >= 0 and k1o < v_len and v1[@intCast(k1o)] != -1) {
                        const x1 = v1[@intCast(k1o)];
                        const y1 = v_off + x1 - k1o;
                        if (x1 >= n - x2) return .{ .x = alo + @as(usize, @intCast(x1)), .y = blo + @as(usize, @intCast(y1)) };
                    }
                }
            }
        }
        return null;
    }
};
