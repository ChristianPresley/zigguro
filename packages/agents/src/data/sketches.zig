//! Streaming sketches for column statistics (E13.F06.S01.T03), shared
//! with the F06.S02 aggregates (`count_distinct`, `median`, `p`).
//!
//! * `HyperLogLog`: distinct counts with 2^12 registers (~1.6% error),
//!   linear counting for small sets.
//! * `Quantiles`: a merging t-digest: values buffer up and merge into at
//!   most ~100 centroids (k1 scale), sized so the tails stay precise.
//! * `TopK`: a count-min sketch (4 × 2048) and the K heaviest values seen.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn hash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x9E3779B97F4A7C15, bytes);
}

pub const HyperLogLog = struct {
    pub const p = 12;
    pub const m = 1 << p;
    regs: [m]u8 = @splat(0),

    pub fn add(h: *HyperLogLog, x: u64) void {
        const idx: usize = @intCast(x >> (64 - p));
        const w = (x << p) | (@as(u64, 1) << (p - 1));
        const rho: u8 = @intCast(@clz(w) + 1);
        if (rho > h.regs[idx]) h.regs[idx] = rho;
    }

    pub fn addBytes(h: *HyperLogLog, bytes: []const u8) void {
        h.add(hash(bytes));
    }

    pub fn merge(h: *HyperLogLog, o: *const HyperLogLog) void {
        for (&h.regs, o.regs) |*a, b| a.* = @max(a.*, b);
    }

    pub fn estimate(h: *const HyperLogLog) u64 {
        var sum: f64 = 0;
        var zeros: usize = 0;
        for (h.regs) |r| {
            sum += std.math.pow(f64, 2, -@as(f64, @floatFromInt(r)));
            zeros += @intFromBool(r == 0);
        }
        const mf: f64 = m;
        const alpha = 0.7213 / (1.0 + 1.079 / mf);
        const e = alpha * mf * mf / sum;
        if (e <= 2.5 * mf and zeros > 0) {
            return @intFromFloat(@round(mf * @log(mf / @as(f64, @floatFromInt(zeros)))));
        }
        return @intFromFloat(@round(e));
    }
};

pub const Centroid = struct { mean: f64, weight: f64 };

pub const Quantiles = struct {
    gpa: Allocator,
    compression: f64 = 200,
    centroids: std.ArrayList(Centroid) = .empty,
    buffer: std.ArrayList(f64) = .empty,
    total: f64 = 0,
    min: f64 = std.math.inf(f64),
    max: f64 = -std.math.inf(f64),

    const buffer_cap = 2048;

    pub fn init(gpa: Allocator) Quantiles {
        return .{ .gpa = gpa };
    }

    pub fn deinit(q: *Quantiles) void {
        q.centroids.deinit(q.gpa);
        q.buffer.deinit(q.gpa);
    }

    pub fn add(q: *Quantiles, x: f64) Allocator.Error!void {
        if (std.math.isNan(x)) return;
        try q.buffer.append(q.gpa, x);
        q.min = @min(q.min, x);
        q.max = @max(q.max, x);
        if (q.buffer.items.len >= buffer_cap) try q.flush();
    }

    fn scale(q: *const Quantiles, phi: f64) f64 {
        return q.compression / (2 * std.math.pi) * std.math.asin(std.math.clamp(2 * phi - 1, -1, 1));
    }

    /// Merges the buffer into the centroids.
    pub fn flush(q: *Quantiles) Allocator.Error!void {
        if (q.buffer.items.len == 0) return;
        var all: std.ArrayList(Centroid) = try .initCapacity(q.gpa, q.centroids.items.len + q.buffer.items.len);
        defer all.deinit(q.gpa);
        all.appendSliceAssumeCapacity(q.centroids.items);
        for (q.buffer.items) |x| all.appendAssumeCapacity(.{ .mean = x, .weight = 1 });
        q.total += @floatFromInt(q.buffer.items.len);
        q.buffer.clearRetainingCapacity();
        try q.compress(all.items);
    }

    /// Adds `o`'s values (both are flushed).
    pub fn merge(q: *Quantiles, o: *Quantiles) Allocator.Error!void {
        try q.flush();
        try o.flush();
        if (o.centroids.items.len == 0) return;
        var all: std.ArrayList(Centroid) = try .initCapacity(q.gpa, q.centroids.items.len + o.centroids.items.len);
        defer all.deinit(q.gpa);
        all.appendSliceAssumeCapacity(q.centroids.items);
        all.appendSliceAssumeCapacity(o.centroids.items);
        q.total += o.total;
        q.min = @min(q.min, o.min);
        q.max = @max(q.max, o.max);
        try q.compress(all.items);
    }

    /// Sorts `all` and merges neighbours into `q.centroids`.
    fn compress(q: *Quantiles, all: []Centroid) Allocator.Error!void {
        std.mem.sort(Centroid, all, {}, struct {
            fn lt(_: void, a: Centroid, b: Centroid) bool {
                return a.mean < b.mean;
            }
        }.lt);
        q.centroids.clearRetainingCapacity();
        // The k1 scale: a centroid may span one unit of
        // k(q) = compression / 2π · asin(2q - 1), so there are at most
        // about compression / 2 of them and the tails stay fine-grained.
        var cur = all[0];
        var before: f64 = 0; // weight left of `cur`
        var k_left = q.scale(0);
        for (all[1..]) |c| {
            if (q.scale((before + cur.weight + c.weight) / q.total) - k_left <= 1) {
                const w = cur.weight + c.weight;
                cur.mean += (c.mean - cur.mean) * c.weight / w;
                cur.weight = w;
            } else {
                try q.centroids.append(q.gpa, cur);
                before += cur.weight;
                k_left = q.scale(before / q.total);
                cur = c;
            }
        }
        try q.centroids.append(q.gpa, cur);
    }

    pub fn count(q: *const Quantiles) f64 {
        return q.total + @as(f64, @floatFromInt(q.buffer.items.len));
    }

    /// The `phi` quantile (0..1); null when empty. Call `flush` first.
    pub fn quantile(q: *const Quantiles, phi: f64) ?f64 {
        const cs = q.centroids.items;
        if (cs.len == 0) return null;
        if (cs.len == 1) return cs[0].mean;
        const target = std.math.clamp(phi, 0, 1) * q.total;
        // Interpolate between centroid centres (cumulative weight at the
        // middle of each centroid), clamped to the min and max seen.
        var cum: f64 = 0;
        var prev_mid: f64 = 0;
        var prev_mean = q.min;
        for (cs) |c| {
            const mid = cum + c.weight / 2;
            if (target <= mid) {
                const span = mid - prev_mid;
                const t = if (span > 0) (target - prev_mid) / span else 0;
                return prev_mean + (c.mean - prev_mean) * t;
            }
            prev_mid = mid;
            prev_mean = c.mean;
            cum += c.weight;
        }
        const span = q.total - prev_mid;
        const t = if (span > 0) (target - prev_mid) / span else 1;
        return prev_mean + (q.max - prev_mean) * t;
    }
};

pub const CountMin = struct {
    pub const depth = 4;
    pub const width = 2048;
    rows: [depth][width]u32 = @splat(@splat(0)),

    /// Adds one occurrence; returns the new estimate.
    pub fn add(c: *CountMin, h: u64) u32 {
        var est: u32 = std.math.maxInt(u32);
        for (&c.rows, 0..) |*row, i| {
            const slot = slotOf(h, i);
            row[slot] +|= 1;
            est = @min(est, row[slot]);
        }
        return est;
    }

    pub fn estimate(c: *const CountMin, h: u64) u32 {
        var est: u32 = std.math.maxInt(u32);
        for (&c.rows, 0..) |*row, i| est = @min(est, row[slotOf(h, i)]);
        return est;
    }

    fn slotOf(h: u64, i: usize) usize {
        const shift: u6 = @intCast(i * 16);
        const k = (h >> shift) ^ (h *% (0x9E3779B97F4A7C15 +% i));
        return @intCast(k % width);
    }
};

pub const TopEntry = struct { v: []const u8, n: u64 };

/// The `k` most frequent values (estimated counts).
pub const TopK = struct {
    gpa: Allocator,
    k: usize = 20,
    cms: *CountMin,
    /// Value copies live here.
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { v: []const u8, n: u64, h: u64 };

    pub fn init(gpa: Allocator, k: usize) Allocator.Error!TopK {
        const cms = try gpa.create(CountMin);
        cms.* = .{};
        return .{ .gpa = gpa, .k = k, .cms = cms, .arena = .init(gpa) };
    }

    pub fn deinit(t: *TopK) void {
        t.gpa.destroy(t.cms);
        t.entries.deinit(t.gpa);
        t.arena.deinit();
    }

    pub fn add(t: *TopK, v: []const u8) Allocator.Error!void {
        return t.addHashed(v, hash(v));
    }

    /// `add` with `v`'s `hash` already known.
    pub fn addHashed(t: *TopK, v: []const u8, h: u64) Allocator.Error!void {
        const est = t.cms.add(h);
        var min_i: usize = 0;
        for (t.entries.items, 0..) |*e, i| {
            if (e.h == h and std.mem.eql(u8, e.v, v)) {
                e.n = est;
                return;
            }
            if (e.n < t.entries.items[min_i].n) min_i = i;
        }
        if (t.entries.items.len < t.k) {
            try t.entries.append(t.gpa, .{ .v = try t.arena.allocator().dupe(u8, v), .n = est, .h = h });
        } else if (est > t.entries.items[min_i].n) {
            t.entries.items[min_i] = .{ .v = try t.arena.allocator().dupe(u8, v), .n = est, .h = h };
        }
    }

    /// The entries, most frequent first (ties by value), in `a`.
    pub fn sorted(t: *const TopK, a: Allocator) Allocator.Error![]TopEntry {
        const out = try a.alloc(TopEntry, t.entries.items.len);
        for (t.entries.items, out) |e, *o| o.* = .{ .v = try a.dupe(u8, e.v), .n = e.n };
        std.mem.sort(TopEntry, out, {}, struct {
            fn gt(_: void, x: TopEntry, y: TopEntry) bool {
                return if (x.n != y.n) x.n > y.n else std.mem.order(u8, x.v, y.v) == .lt;
            }
        }.gt);
        return out;
    }
};
