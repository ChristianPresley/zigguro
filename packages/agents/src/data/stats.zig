//! Column statistics (E13.F06.S01.T03), computed on a worker in one
//! sequential pass over the file.
//!
//! Count, nulls, min/max and the mean (Welford) are exact; the distinct
//! count is a HyperLogLog estimate, quantiles come from the t-digest and
//! the top values from a count-min sketch (sketches.zig). The 32-bin
//! histogram takes a second pass over the parsed numbers kept from the
//! first; past 10 M rows only the first 10 M are kept and the result is
//! marked `sampled`. `cancel` is checked every 1,024 rows.

const std = @import("std");
const infer = @import("infer.zig");
const sketches = @import("sketches.zig");
const dataset = @import("dataset.zig");

const Allocator = std.mem.Allocator;
const Value = infer.Value;

pub const quantile_points = [5]f64{ 0.01, 0.25, 0.5, 0.75, 0.99 };
pub const max_cached = 10_000_000;

pub const ColumnStats = struct {
    ty: infer.ColType,
    count: u64,
    nulls: u64,
    distinct_est: u64,
    min: ?Value,
    max: ?Value,
    mean: ?f64,
    /// p1, p25, p50, p75, p99.
    quantiles: [5]?f64,
    top: []const sketches.TopEntry,
    histogram: [32]u64,
    /// Lower and upper bound of the histogram's range.
    hist_range: ?[2]f64 = null,
    sampled: bool,
};

const Acc = struct {
    gpa: Allocator,
    arena: Allocator,
    ty: infer.ColType,
    ctx: infer.InferCtx,
    count: u64 = 0,
    nulls: u64 = 0,
    numeric: u64 = 0,
    lo: f64 = 0,
    hi: f64 = 0,
    mean: f64 = 0,
    min: ?Value = null,
    max: ?Value = null,
    hll: sketches.HyperLogLog = .{},
    q: sketches.Quantiles,
    top: sketches.TopK,
    values: std.ArrayList(f64) = .empty,
    sampled: bool = false,

    fn add(acc: *Acc, text: []const u8, is_null: bool) anyerror!void {
        acc.count += 1;
        if (is_null or infer.isNullText(text)) {
            acc.nulls += 1;
            return;
        }
        const h = sketches.hash(text);
        acc.hll.add(h);
        try acc.top.addHashed(text, h);
        // A cell that doesn't parse as the column's type only counts
        // toward distinct and top values.
        const t = std.mem.trim(u8, text, " \t");
        const v = infer.parseNonNull(t, acc.ty, acc.ctx) orelse if (acc.ty == .string) Value{ .string = t } else return;
        const x = v.toF64() orelse {
            if (acc.min == null or v.order(acc.min.?) == .lt) acc.min = try own(acc.arena, v);
            if (acc.max == null or v.order(acc.max.?) == .gt) acc.max = try own(acc.arena, v);
            return;
        };
        if (acc.numeric == 0 or x < acc.lo) {
            acc.lo = x;
            acc.min = v;
        }
        if (acc.numeric == 0 or x > acc.hi) {
            acc.hi = x;
            acc.max = v;
        }
        acc.numeric += 1;
        acc.mean += (x - acc.mean) / @as(f64, @floatFromInt(acc.numeric));
        try acc.q.add(x);
        if (acc.values.items.len < max_cached) {
            try acc.values.append(acc.gpa, x);
        } else acc.sampled = true;
    }

    fn own(a: Allocator, v: Value) !Value {
        return if (v == .string) .{ .string = try a.dupe(u8, v.string) } else v;
    }
};

/// Statistics of column `col` of `ds`; strings in the result live in
/// `arena`.
pub fn computeStats(io: std.Io, ds: *const dataset.Dataset, col: u32, arena: Allocator, cancel: *const std.atomic.Value(bool)) !ColumnStats {
    _ = io;
    const gpa = ds.gpa;
    var tmp: std.heap.ArenaAllocator = .init(gpa);
    defer tmp.deinit();
    var ctx = ds.inferCtx();
    const samples = try ds.sampleColumn(col, 10_000, tmp.allocator());
    ctx.date_order = infer.dateOrderOf(samples);
    const ty = infer.inferColumn(samples, ctx);

    var acc: Acc = .{ .gpa = gpa, .arena = arena, .ty = ty, .ctx = ctx, .q = .init(gpa), .top = try .init(gpa, 20) };
    defer {
        acc.q.deinit();
        acc.top.deinit();
        acc.values.deinit(gpa);
    }
    try ds.forEachCell(col, &acc, Acc.add, cancel);
    try acc.q.flush();

    var out: ColumnStats = .{
        .ty = ty,
        .count = acc.count,
        .nulls = acc.nulls,
        .distinct_est = if (acc.count == acc.nulls) 0 else acc.hll.estimate(),
        .min = acc.min,
        .max = acc.max,
        .mean = if (acc.numeric > 0) acc.mean else null,
        .quantiles = @splat(null),
        .top = try acc.top.sorted(arena),
        .histogram = @splat(0),
        .sampled = acc.sampled,
    };
    if (acc.numeric > 0) {
        for (quantile_points, &out.quantiles) |p, *o| o.* = acc.q.quantile(p);
        const lo = acc.q.min;
        const hi = acc.q.max;
        out.hist_range = .{ lo, hi };
        for (acc.values.items, 0..) |x, i| {
            if (i % 65536 == 0 and cancel.load(.acquire)) return error.Canceled;
            out.histogram[bin(x, lo, hi)] += 1;
        }
    }
    return out;
}

pub fn bin(x: f64, lo: f64, hi: f64) usize {
    if (!(hi > lo)) return 0;
    const t = (x - lo) / (hi - lo) * 32;
    return @intFromFloat(std.math.clamp(@floor(t), 0, 31));
}
