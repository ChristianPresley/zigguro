//! Ticks, label formats, transforms and decimation.

const std = @import("std");
const ticks = @import("ticks.zig");
const transform = @import("transform.zig");
const decimate = @import("decimate.zig");
const spec = @import("spec.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn tickLabels(a: std.mem.Allocator, lo: f64, hi: f64, max: u8) ![]const u8 {
    const t = ticks.niceTicks(lo, hi, max);
    var w: std.Io.Writer.Allocating = .init(a);
    for (0..t.count) |i| {
        if (i > 0) try w.writer.writeByte(' ');
        try ticks.formatNumber(&w.writer, t.value(i), t.decimals, ticks.autoFormat(t));
    }
    return w.written();
}

test "nice_ticks_table" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { lo: f64, hi: f64, max: u8, want: []const u8 }{
        .{ .lo = 0, .hi = 100, .max = 5, .want = "0 20 40 60 80 100" },
        .{ .lo = 0, .hi = 100, .max = 10, .want = "0 10 20 30 40 50 60 70 80 90 100" },
        .{ .lo = 0, .hi = 1, .max = 4, .want = "0.00 0.25 0.50 0.75 1.00" },
        .{ .lo = -37, .hi = 42, .max = 5, .want = "-20 0 20 40" },
        .{ .lo = -1, .hi = -0.2, .max = 4, .want = "-1.0 -0.8 -0.6 -0.4 -0.2" },
        .{ .lo = 0.000012, .hi = 0.000019, .max = 4, .want = "0.000012 0.000014 0.000016 0.000018" },
        .{ .lo = 0, .hi = 3.2e9, .max = 4, .want = "0 1G 2G 3G" },
        .{ .lo = 1.5e6, .hi = 2.6e6, .max = 5, .want = "1.5M 1.75M 2M 2.25M 2.5M" },
        .{ .lo = 7, .hi = 7, .max = 5, .want = "6.5 7.0 7.5" },
        .{ .lo = 0, .hi = 0, .max = 4, .want = "-1.0 -0.5 0.0 0.5 1.0" },
        .{ .lo = 10, .hi = 0, .max = 5, .want = "0 2 4 6 8 10" },
        .{ .lo = 0.1, .hi = 0.3, .max = 2, .want = "0.1 0.2 0.3" },
        .{ .lo = 1e15, .hi = 1.0000000000001e15, .max = 3, .want = "1000T 1000T 1000T" },
    };
    for (cases) |cs| {
        const got = try tickLabels(a, cs.lo, cs.hi, cs.max);
        testing.expectEqualStrings(cs.want, got) catch |e| {
            std.debug.print("niceTicks({d}, {d}, {d})\n", .{ cs.lo, cs.hi, cs.max });
            return e;
        };
    }
    // Steps are 1, 2, 2.5 or 5 × 10^k, ticks stay inside the range and
    // never exceed max_ticks intervals.
    var prng: std.Random.DefaultPrng = .init(11);
    const r = prng.random();
    for (0..2000) |_| {
        // Ranges down to a millionth of the values' magnitude.
        const e = r.intRangeAtMost(i32, -8, 12);
        const lo = (r.float(f64) - 0.5) * std.math.pow(f64, 10, @floatFromInt(e));
        const hi = lo + (0.1 + r.float(f64)) * std.math.pow(f64, 10, @floatFromInt(e - r.intRangeAtMost(i32, 0, 6)));
        const max = r.intRangeAtMost(u8, 1, 12);
        const t = ticks.niceTicks(lo, hi, max);
        if (lo == hi) continue;
        // Three or more intervals always leave a tick inside.
        if (max >= 3) try testing.expect(t.count >= 1);
        if (t.count == 0) continue;
        try testing.expect(t.count <= @as(u32, max) + 1);
        const ex = @floor(std.math.log10(t.step));
        const m = t.step / std.math.pow(f64, 10, ex);
        try testing.expect(for ([_]f64{ 1, 2, 2.5, 5, 10 }) |n| {
            if (@abs(m - n) < 1e-6) break true;
        } else false);
        try testing.expect(t.value(0) >= lo - t.step * 1e-6 and t.value(t.count - 1) <= hi + t.step * 1e-6);
    }
}

test "log ticks" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqualSlices(f64, &.{ 1, 2, 5, 10, 20, 50, 100 }, try ticks.logTicks(arena.allocator(), 1, 100, 8));
    try testing.expectEqualSlices(f64, &.{ 1, 100, 1e4, 1e6 }, try ticks.logTicks(arena.allocator(), 1, 1e6, 3));
    try testing.expectEqual(0, (try ticks.logTicks(arena.allocator(), -1, 10, 5)).len);
}

fn ms(y: i64, m: u32, d: u32, hh: i64, mm: i64) i64 {
    return @as(i64, @import("../data/infer.zig").daysFromCivil(y, m, d)) * ticks.ms_day + hh * ticks.ms_hour + mm * ticks.ms_minute;
}

fn timeLabels(a: std.mem.Allocator, lo: i64, hi: i64, max: u8) ![]const u8 {
    const t = try ticks.timeTicks(a, lo, hi, max, .utc);
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("{t}:", .{t.step});
    for (t.values) |v| {
        try w.writer.writeByte(' ');
        try ticks.formatTime(&w.writer, v, t.step, .utc);
    }
    return w.written();
}

test "time_ticks_table" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { lo: i64, hi: i64, max: u8, want: []const u8 }{
        .{ .lo = ms(2026, 3, 5, 14, 0), .hi = ms(2026, 3, 5, 14, 0) + 40 * ticks.ms_second, .max = 5, .want = "s15: 14:00:00 14:00:15 14:00:30" },
        .{ .lo = ms(2026, 3, 5, 14, 2), .hi = ms(2026, 3, 5, 14, 58), .max = 5, .want = "m15: 14:15 14:30 14:45" },
        .{ .lo = ms(2026, 3, 5, 20, 0), .hi = ms(2026, 3, 6, 8, 0), .max = 5, .want = "h3: 21:00 Mar 6 03:00 06:00" },
        .{ .lo = ms(2026, 3, 1, 0, 0), .hi = ms(2026, 3, 10, 0, 0), .max = 5, .want = "d2: Mar 2 Mar 4 Mar 6 Mar 8 Mar 10" },
        .{ .lo = ms(2026, 2, 20, 0, 0), .hi = ms(2026, 4, 1, 0, 0), .max = 6, .want = "w1: Feb 23 Mar 2 Mar 9 Mar 16 Mar 23 Mar 30" },
        .{ .lo = ms(2025, 11, 15, 0, 0), .hi = ms(2026, 4, 15, 0, 0), .max = 6, .want = "mo1: Dec 2026 Feb Mar Apr" },
        .{ .lo = ms(2024, 1, 1, 0, 0), .hi = ms(2025, 6, 30, 0, 0), .max = 8, .want = "mo3: 2024 Apr Jul Oct 2025 Apr" },
        .{ .lo = ms(2019, 6, 1, 0, 0), .hi = ms(2026, 1, 1, 0, 0), .max = 8, .want = "y1: 2020 2021 2022 2023 2024 2025 2026" },
        .{ .lo = ms(1900, 1, 1, 0, 0), .hi = ms(2026, 1, 1, 0, 0), .max = 6, .want = "years: 1900 1925 1950 1975 2000 2025" },
        // Before 1970 and across a leap day.
        .{ .lo = ms(1960, 2, 27, 0, 0), .hi = ms(1960, 3, 2, 0, 0), .max = 4, .want = "d1: Feb 27 Feb 28 Feb 29 Mar 1 Mar 2" },
    };
    for (cases) |cs| {
        const got = try timeLabels(a, cs.lo, cs.hi, cs.max);
        testing.expectEqualStrings(cs.want, got) catch |e| {
            std.debug.print("timeTicks case {s}\n", .{cs.want});
            return e;
        };
    }
}

test "time ticks align in a zone" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const tz = @import("../sched/tz.zig");
    var zone = try tz.TimeZone.embedded(gpa, "America/New_York");
    defer zone.deinit(gpa);
    const z: ticks.Zone = .{ .tz = &zone };
    // Local midnights (05:00 UTC in winter, 04:00 after the March change).
    const t = try ticks.timeTicks(arena.allocator(), ms(2026, 3, 7, 0, 0), ms(2026, 3, 10, 12, 0), 5, z);
    try testing.expectEqual(ticks.TimeStep.d1, t.step);
    try testing.expectEqualSlices(i64, &.{ ms(2026, 3, 7, 5, 0), ms(2026, 3, 8, 5, 0), ms(2026, 3, 9, 4, 0), ms(2026, 3, 10, 4, 0) }, t.values);
}

test "number formats" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { v: f64, d: u8, f: ticks.NumFormat, want: []const u8 }{
        .{ .v = 1234.5, .d = 1, .f = .fixed, .want = "1234.5" },
        .{ .v = -0.0000001, .d = 2, .f = .fixed, .want = "0.00" },
        .{ .v = 1250, .d = 0, .f = .si, .want = "1.25k" },
        .{ .v = 12_500_000, .d = 0, .f = .si, .want = "12.5M" },
        .{ .v = 999, .d = 0, .f = .si, .want = "999" },
        .{ .v = 0.256, .d = 3, .f = .percent, .want = "25.6%" },
        .{ .v = std.math.inf(f64), .d = 0, .f = .fixed, .want = "∞" },
    };
    for (cases) |cs| {
        var w: std.Io.Writer = .fixed(&buf);
        try ticks.formatNumber(&w, cs.v, cs.d, cs.f);
        try testing.expectEqualStrings(cs.want, w.buffered());
    }
    var w: std.Io.Writer = .fixed(&buf);
    try ticks.formatValue(&w, 3.14159265);
    try testing.expectEqualStrings("3.142", w.buffered());
}

test "label stride drops labels until they fit" {
    const centers = [_]f32{ 0, 10, 20, 30, 40, 50, 60, 70 };
    try testing.expectEqual(1, ticks.labelStride(&centers, &(.{8} ** 8), 1));
    try testing.expectEqual(2, ticks.labelStride(&centers, &(.{15} ** 8), 2));
    try testing.expectEqual(4, ticks.labelStride(&centers, &(.{30} ** 8), 2));
}

fn table(a: std.mem.Allocator, json: []const u8) !transform.Table {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    return transform.fromJson(a, v.array.items);
}

fn colText(a: std.mem.Allocator, t: *const transform.Table, name: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    for (t.column(name).?, 0..) |v, i| {
        if (i > 0) try w.writer.writeByte(',');
        try transform.writeLit(&w.writer, v);
    }
    return w.written();
}

test "aggregate_bin_timeunit_transforms" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try table(a,
        \\[{"region":"EU","day":"2026-01-05","price":3,"q1":1,"q2":4},
        \\ {"region":"US","day":"2026-01-20","price":17,"q1":2,"q2":5},
        \\ {"region":"EU","day":"2026-02-02","price":11,"q1":3,"q2":null},
        \\ {"region":"US","day":"2026-04-30T10:00:00Z","price":24.5,"q1":4,"q2":7},
        \\ {"region":"APAC","day":"2026-05-01","price":"n/a","q1":5,"q2":8}]
    );
    try testing.expectEqual(.string, t.types.items[t.find("price").?]); // mixed number and text
    var diag: transform.Diagnostic = .{};
    try transform.apply(a, gpa, &t, &.{
        .{ .filter = "region != 'APAC'" },
        .{ .calculate = .{ .expr = "q1 * 10 + 1", .as = "q1x" } },
        .{ .time_unit = .{ .unit = .month, .field = "day", .as = "month" } },
        .{ .time_unit = .{ .unit = .quarter, .field = "day", .as = "quarter" } },
        .{ .time_unit = .{ .unit = .week, .field = "day", .as = "week" } },
    }, .utc, &diag);
    try testing.expectEqual(4, t.rows);
    try testing.expectEqualStrings("11,21,31,41", try colText(a, &t, "q1x"));
    try testing.expectEqualStrings("2026-01-01,2026-01-01,2026-02-01,2026-04-01", try colText(a, &t, "month"));
    try testing.expectEqualStrings("2026-01-01,2026-01-01,2026-01-01,2026-04-01", try colText(a, &t, "quarter"));
    try testing.expectEqualStrings("2026-01-05,2026-01-19,2026-02-02,2026-04-27", try colText(a, &t, "week"));

    // Bins over q2 (with a null).
    try transform.apply(a, gpa, &t, &.{.{ .bin = .{ .field = "q2", .maxbins = 3, .as = "b" } }}, .utc, &diag);
    try testing.expectEqualStrings("4,4,null,6", try colText(a, &t, "b"));
    try testing.expectEqualStrings("6,6,null,8", try colText(a, &t, "b_end"));

    // Group by region: every operation.
    const g = try transform.aggregate(a, &t, &.{"region"}, &.{
        .{ .op = .count, .as = "n" },
        .{ .op = .sum, .field = "q1", .as = "sum" },
        .{ .op = .mean, .field = "q2", .as = "mean" },
        .{ .op = .median, .field = "q1", .as = "median" },
        .{ .op = .min, .field = "day", .as = "first" },
        .{ .op = .max, .field = "q2", .as = "max" },
        .{ .op = .distinct, .field = "month", .as = "months" },
    }, 0, &diag);
    try testing.expectEqualStrings("EU,US", try colText(a, &g, "region"));
    try testing.expectEqualStrings("2,2", try colText(a, &g, "n"));
    try testing.expectEqualStrings("4,6", try colText(a, &g, "sum"));
    try testing.expectEqualStrings("4,6", try colText(a, &g, "mean"));
    try testing.expectEqualStrings("2,3", try colText(a, &g, "median"));
    try testing.expectEqualStrings("2026-01-05,2026-01-20", try colText(a, &g, "first"));
    try testing.expectEqualStrings("4,7", try colText(a, &g, "max"));
    try testing.expectEqualStrings("2,2", try colText(a, &g, "months"));

    // Fold wide to long.
    var w = try table(a,
        \\[{"k":"a","x":1,"y":2},{"k":"b","x":3,"y":4.5}]
    );
    try transform.apply(a, gpa, &w, &.{.{ .fold = .{ .fields = &.{ "x", "y" }, .as = .{ "key", "value" } } }}, .utc, &diag);
    try testing.expectEqualStrings("a,a,b,b", try colText(a, &w, "k"));
    try testing.expectEqualStrings("x,y,x,y", try colText(a, &w, "key"));
    try testing.expectEqualStrings("1,2,3,4.5", try colText(a, &w, "value"));

    // Errors name the transform.
    try testing.expectError(error.InvalidTransform, transform.apply(a, gpa, &w, &.{ .{ .filter = "k == 'a'" }, .{ .filter = "nope > 1" } }, .utc, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message, "transform[1].filter: "));
    try testing.expectError(error.InvalidTransform, transform.apply(a, gpa, &w, &.{.{ .bin = .{ .field = "zz", .maxbins = 5, .as = "b" } }}, .utc, &diag));
    try testing.expectEqualStrings("transform[0].bin: unknown field `zz`; fields: k, key, value", diag.message);
}

test "decimation_preserves_extrema" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    for (0..50) |_| {
        const n = r.intRangeAtMost(usize, 1, 20_000);
        const cols = r.intRangeAtMost(u32, 1, 800);
        const xs = try a.alloc(f64, n);
        const ys = try a.alloc(f64, n);
        var x: f64 = 0;
        for (xs, ys) |*px, *py| {
            x += r.float(f64) * 3;
            px.* = x;
            py.* = if (r.uintLessThan(u32, 500) == 0) std.math.nan(f64) else r.floatNorm(f64) * 100;
        }
        const keep = try decimate.m4(a, xs, ys, 0, x + 1, cols);
        // Ascending, first and last kept, at most 4 a column (+ gaps).
        for (keep[0..keep.len -| 1], keep[@min(1, keep.len)..]) |p, q| try testing.expect(p < q);
        try testing.expectEqual(0, keep[0]);
        try testing.expectEqual(n - 1, keep[keep.len - 1]);
        // Per column (between gaps), the same min and max as all points.
        const k = @as(f64, @floatFromInt(cols)) / (x + 1);
        var full_min: std.AutoHashMapUnmanaged(i64, f64) = .empty;
        var full_max: std.AutoHashMapUnmanaged(i64, f64) = .empty;
        for (xs, ys) |px, py| if (!std.math.isNan(py)) {
            const c: i64 = @intFromFloat(@floor(px * k));
            const mn = try full_min.getOrPut(a, c);
            if (!mn.found_existing or py < mn.value_ptr.*) mn.value_ptr.* = py;
            const mx = try full_max.getOrPut(a, c);
            if (!mx.found_existing or py > mx.value_ptr.*) mx.value_ptr.* = py;
        };
        var kept_min: std.AutoHashMapUnmanaged(i64, f64) = .empty;
        var kept_max: std.AutoHashMapUnmanaged(i64, f64) = .empty;
        var nan_runs_full: usize = 0;
        var nan_runs_kept: usize = 0;
        for (ys, 0..) |py, i| if (std.math.isNan(py) and (i == 0 or !std.math.isNan(ys[i - 1]))) {
            nan_runs_full += 1;
        };
        for (keep, 0..) |i, j| {
            const py = ys[i];
            if (std.math.isNan(py)) {
                if (j == 0 or !std.math.isNan(ys[keep[j - 1]])) nan_runs_kept += 1;
                continue;
            }
            const c: i64 = @intFromFloat(@floor(xs[i] * k));
            const mn = try kept_min.getOrPut(a, c);
            if (!mn.found_existing or py < mn.value_ptr.*) mn.value_ptr.* = py;
            const mx = try kept_max.getOrPut(a, c);
            if (!mx.found_existing or py > mx.value_ptr.*) mx.value_ptr.* = py;
        }
        try testing.expectEqual(full_min.count(), kept_min.count());
        var it = full_min.iterator();
        while (it.next()) |e| {
            try testing.expectEqual(e.value_ptr.*, kept_min.get(e.key_ptr.*).?);
            try testing.expectEqual(full_max.get(e.key_ptr.*).?, kept_max.get(e.key_ptr.*).?);
        }
        try testing.expectEqual(nan_runs_full, nan_runs_kept);
        try testing.expect(keep.len <= cols * 4 + nan_runs_full * 5 + 4);
    }
    // Stratified samples: deterministic, ascending, one per stratum.
    const s1 = try decimate.stratified(a, 1000, 10, 9);
    const s2 = try decimate.stratified(a, 1000, 10, 9);
    try testing.expectEqualSlices(u32, s1, s2);
    for (s1, 0..) |v, i| try testing.expect(v >= i * 100 and v < (i + 1) * 100);
}
