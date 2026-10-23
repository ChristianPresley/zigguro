//! Column statistics and the sketches behind them.

const std = @import("std");
const sketches = @import("sketches.zig");
const stats = @import("stats.zig");
const dataset = @import("dataset.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

test "stats_against_exact" {
    const doc =
        \\id,city,score,day,flag
        \\1,Oslo,3.5,2026-01-01,true
        \\2,Lima,,2026-01-03,false
        \\3,Oslo,7,2026-01-02,true
        \\4,Quito,1.5,\N,true
        \\5,Oslo,10,2026-01-05,false
        \\
    ;
    const ds = try dataset.Dataset.openBytes(gpa, io, doc, .csv);
    defer ds.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cancel: std.atomic.Value(bool) = .init(false);

    const score = try stats.computeStats(io, ds, 2, a, &cancel);
    try testing.expectEqual(.float, score.ty);
    try testing.expectEqual(@as(u64, 5), score.count);
    try testing.expectEqual(@as(u64, 1), score.nulls);
    try testing.expectEqual(@as(u64, 4), score.distinct_est);
    try testing.expectEqual(@as(f64, 1.5), score.min.?.float);
    try testing.expectEqual(@as(f64, 10), score.max.?.float);
    try testing.expectApproxEqAbs(@as(f64, 5.5), score.mean.?, 1e-9);
    try testing.expectEqual(@as(f64, 1.5), score.quantiles[0].?);
    try testing.expectEqual(@as(f64, 10), score.quantiles[4].?);
    var total: u64 = 0;
    for (score.histogram) |h| total += h;
    try testing.expectEqual(@as(u64, 4), total);
    try testing.expectEqual(@as(u64, 1), score.histogram[0]);
    try testing.expectEqual(@as(u64, 1), score.histogram[31]);
    try testing.expect(!score.sampled);

    const city = try stats.computeStats(io, ds, 1, a, &cancel);
    try testing.expectEqual(.string, city.ty);
    try testing.expectEqual(@as(u64, 3), city.distinct_est);
    try testing.expectEqualStrings("Oslo", city.top[0].v);
    try testing.expectEqual(@as(u64, 3), city.top[0].n);
    try testing.expectEqualStrings("Lima", city.top[1].v);
    try testing.expectEqualStrings("Lima", city.min.?.string);
    try testing.expectEqualStrings("Quito", city.max.?.string);
    try testing.expect(city.mean == null);

    const day = try stats.computeStats(io, ds, 3, a, &cancel);
    try testing.expectEqual(.date, day.ty);
    try testing.expectEqual(@as(u64, 1), day.nulls);
    try testing.expectEqual(@as(i32, 20454), day.min.?.date);
    try testing.expectEqual(@as(i32, 20458), day.max.?.date);

    const flag = try stats.computeStats(io, ds, 4, a, &cancel);
    try testing.expectEqual(.bool_, flag.ty);
    try testing.expectApproxEqAbs(@as(f64, 0.6), flag.mean.?, 1e-9);
}

test "hyperloglog error on 1 M distinct values" {
    var h: sketches.HyperLogLog = .{};
    var buf: [32]u8 = undefined;
    for (0..1_000_000) |i| h.addBytes(try std.fmt.bufPrint(&buf, "value-{d}", .{i}));
    const est: f64 = @floatFromInt(h.estimate());
    try testing.expect(@abs(est - 1_000_000) / 1_000_000 < 0.02);
    // Small sets are exact (linear counting).
    var s: sketches.HyperLogLog = .{};
    for (0..100) |i| s.addBytes(try std.fmt.bufPrint(&buf, "{d}", .{i % 37}));
    try testing.expectEqual(@as(u64, 37), s.estimate());
    var other: sketches.HyperLogLog = .{};
    for (0..100) |i| other.addBytes(try std.fmt.bufPrint(&buf, "x{d}", .{i % 20}));
    s.merge(&other);
    try testing.expectEqual(@as(u64, 57), s.estimate());
}

test "quantile_sketch_error_bounds" {
    var prng: std.Random.DefaultPrng = .init(1234);
    const rnd = prng.random();
    for (0..6) |round| {
        const n: usize = 20_000 + round * 31_000;
        const xs = try gpa.alloc(f64, n);
        defer gpa.free(xs);
        var q: sketches.Quantiles = .init(gpa);
        defer q.deinit();
        for (xs) |*x| {
            x.* = switch (round % 3) {
                0 => rnd.float(f64) * 1000,
                1 => rnd.floatNorm(f64) * 50 + 10,
                else => rnd.floatExp(f64) * 3,
            };
            try q.add(x.*);
        }
        try q.flush();
        try testing.expect(q.centroids.items.len <= 200);
        std.mem.sort(f64, xs, {}, std.sort.asc(f64));
        for ([_]f64{ 0.001, 0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99, 0.999 }) |phi| {
            const got = q.quantile(phi).?;
            // Rank error: where the answer falls among the sorted values.
            const rank = std.sort.lowerBound(f64, xs, got, struct {
                fn cmp(ctx: f64, x: f64) std.math.Order {
                    return std.math.order(ctx, x);
                }
            }.cmp);
            const err = @abs(@as(f64, @floatFromInt(rank)) / @as(f64, @floatFromInt(n)) - phi);
            const bound = 0.005 + 4 * phi * (1 - phi) / 100;
            if (err > bound) {
                std.debug.print("round {d} phi {d}: rank error {d}\n", .{ round, phi, err });
                return error.TestUnexpectedResult;
            }
        }
        try testing.expectEqual(xs[0], q.quantile(0).?);
        try testing.expectEqual(xs[n - 1], q.quantile(1).?);
    }
}

test "top-k keeps the heavy hitters" {
    var t: sketches.TopK = try .init(gpa, 5);
    defer t.deinit();
    var buf: [16]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(5);
    const rnd = prng.random();
    for (0..50_000) |_| {
        // Values 0..4 are heavy, the rest a long tail.
        const v = if (rnd.uintLessThan(u8, 2) == 0) rnd.uintLessThan(u32, 5) else 100 + rnd.uintLessThan(u32, 5000);
        try t.add(try std.fmt.bufPrint(&buf, "{d}", .{v}));
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const top = try t.sorted(arena.allocator());
    try testing.expectEqual(@as(usize, 5), top.len);
    for (top) |e| try testing.expect(e.v.len == 1 and e.n > 4000);
}

test "cancel_stops_stats_within_50ms" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "n,v\n");
    for (0..400_000) |i| try text.print(gpa, "{d},{d}\n", .{ i, i % 977 });
    const ds = try dataset.Dataset.openBytes(gpa, io, text.items, .csv);
    defer ds.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    const t0 = std.Io.Timestamp.now(io, .awake);
    try testing.expectError(error.Canceled, stats.computeStats(io, ds, 1, arena.allocator(), &cancel));
    const ms = t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expect(ms < 50);
    // Canceled from another task while running.
    cancel.store(false, .release);
    var fut = try io.concurrent(struct {
        fn run(c: *std.atomic.Value(bool), i: std.Io) void {
            i.sleep(.fromMilliseconds(2), .awake) catch {};
            c.store(true, .release);
        }
    }.run, .{ &cancel, io });
    const r = stats.computeStats(io, ds, 1, arena.allocator(), &cancel);
    fut.await(io);
    if (r) |_| {} else |e| try testing.expectEqual(error.Canceled, e);
}
