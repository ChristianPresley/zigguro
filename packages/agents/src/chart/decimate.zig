//! Decimation (E13.F07.S01.T03): long lines keep, per pixel column, the
//! first, last, lowest and highest point (M4), which draws the same
//! polyline as the full series; huge scatters keep a deterministic
//! stratified sample.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Lines with more points than this times the plot width are decimated.
pub const line_factor = 4;
/// Scatters with more points than this are sampled.
pub const max_points = 200_000;

/// Indices (ascending) of the points of a series sorted by x that M4
/// keeps over `columns` pixel columns spanning `[x0, x1]`. NaN ys are
/// gaps: the first NaN of each run is kept so the line still breaks.
pub fn m4(a: Allocator, xs: []const f64, ys: []const f64, x0: f64, x1: f64, columns: u32) ![]u32 {
    std.debug.assert(xs.len == ys.len);
    var out: std.ArrayListUnmanaged(u32) = .empty;
    if (xs.len == 0) return out.items;
    try out.ensureTotalCapacity(a, @min(xs.len, @as(usize, columns) * 4 + 8));
    var st: M4(u32) = .init(x0, x1, columns);
    for (xs, ys, 0..) |x, y, i| try st.push(a, &out, @intCast(i), x, y);
    try st.finish(a, &out);
    return out.items;
}

/// M4 over a stream of points sorted by x: `push` each in order and
/// `finish`; kept items are appended to `out` in input order. `T` is
/// what is kept (an index, or the point itself).
pub fn M4(comptime T: type) type {
    return struct {
        const Self = @This();
        const Pick = struct { seq: u64, item: T, y: f64 };

        x0: f64,
        k: f64,
        cols: f64,
        seq: u64 = 0,
        /// The open column's first, lowest, highest and last points.
        col: ?i64 = null,
        first: Pick = undefined,
        lo: Pick = undefined,
        hi: Pick = undefined,
        last: Pick = undefined,
        /// Whether the last item kept was a gap.
        in_gap: bool = false,

        pub fn init(x0: f64, x1: f64, columns: u32) Self {
            const cols: f64 = @floatFromInt(@max(columns, 1));
            return .{ .x0 = x0, .k = if (x1 > x0) cols / (x1 - x0) else 0, .cols = cols };
        }

        pub fn push(st: *Self, a: Allocator, out: *std.ArrayListUnmanaged(T), item: T, x: f64, y: f64) Allocator.Error!void {
            const seq = st.seq;
            st.seq += 1;
            if (std.math.isNan(y)) {
                try st.flush(a, out);
                if (!st.in_gap) try out.append(a, item);
                st.in_gap = true;
                return;
            }
            const c = column(x, st.x0, st.k, st.cols);
            const p: Pick = .{ .seq = seq, .item = item, .y = y };
            if (st.col != c) {
                try st.flush(a, out);
                st.col = c;
                st.first = p;
                st.lo = p;
                st.hi = p;
            } else {
                if (y < st.lo.y) st.lo = p;
                if (y > st.hi.y) st.hi = p;
            }
            st.last = p;
        }

        fn flush(st: *Self, a: Allocator, out: *std.ArrayListUnmanaged(T)) Allocator.Error!void {
            if (st.col == null) return;
            st.col = null;
            st.in_gap = false;
            var picks = [4]Pick{ st.first, st.lo, st.hi, st.last };
            std.mem.sort(Pick, &picks, {}, struct {
                fn lt(_: void, l: Pick, r: Pick) bool {
                    return l.seq < r.seq;
                }
            }.lt);
            var prev: ?u64 = null;
            for (picks) |p| {
                if (prev == p.seq) continue;
                prev = p.seq;
                try out.append(a, p.item);
            }
        }

        pub fn finish(st: *Self, a: Allocator, out: *std.ArrayListUnmanaged(T)) Allocator.Error!void {
            try st.flush(a, out);
        }
    };
}

fn column(x: f64, x0: f64, k: f64, cols: f64) i64 {
    if (!std.math.isFinite(x)) return std.math.minInt(i64);
    return @intFromFloat(std.math.clamp(@floor((x - x0) * k), -1, cols));
}

/// `k` indices (ascending) out of `n`: one from each of `k` equal
/// strata, chosen by a hash of the stratum and `seed`, so the same data
/// samples the same way every time.
pub fn stratified(a: Allocator, n: usize, k: usize, seed: u64) ![]u32 {
    if (n <= k) {
        const all = try a.alloc(u32, n);
        for (all, 0..) |*o, i| o.* = @intCast(i);
        return all;
    }
    const out = try a.alloc(u32, k);
    for (out, 0..) |*o, s| {
        const lo = s * n / k;
        const hi = (s + 1) * n / k;
        const h = std.hash.Wyhash.hash(seed, std.mem.asBytes(&s));
        o.* = @intCast(lo + h % (hi - lo));
    }
    return out;
}

test {
    std.testing.refAllDecls(@This());
}
