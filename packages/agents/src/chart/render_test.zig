//! Twelve reference charts rendered to SVG goldens, compile errors, and
//! hover hit testing.

const std = @import("std");
const chart = @import("root.zig");
const vector = @import("../vector/root.zig");
const test_util = @import("../vector/test_util.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

/// Deterministic pseudo-random numbers for chart data.
const Rng = struct {
    s: u64,
    fn next(r: *Rng) f64 {
        r.s = r.s *% 6364136223846793005 +% 1442695040888963407;
        return @as(f64, @floatFromInt(r.s >> 11)) / @as(f64, 1 << 53);
    }
};

fn data(a: Allocator, comptime kind: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    const o = &w.writer;
    var r: Rng = .{ .s = 42 };
    try o.writeAll("[");
    var first = true;
    const sep = struct {
        fn f(out: *std.Io.Writer, fst: *bool) !void {
            if (!fst.*) try out.writeAll(",");
            fst.* = false;
        }
    }.f;
    const regions = [_][]const u8{ "North", "South", "East" };
    const months = [_][]const u8{ "2026-01-01", "2026-02-01", "2026-03-01", "2026-04-01", "2026-05-01", "2026-06-01" };
    if (comptime std.mem.eql(u8, kind, "bar")) {
        for ([_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta" }, [_]f64{ 28, 55, 43, 91, 81, 53, 19 }) |k, v| {
            try sep(o, &first);
            try o.print("{{\"k\":\"{s}\",\"v\":{d}}}", .{ k, v });
        }
    } else if (comptime std.mem.eql(u8, kind, "sales")) {
        for (months) |m| for (regions, 0..) |reg, ri| {
            try sep(o, &first);
            try o.print("{{\"month\":\"{s}\",\"region\":\"{s}\",\"revenue\":{d}}}", .{ m, reg, @round(20 + r.next() * 60 + @as(f64, @floatFromInt(ri)) * 10) });
        };
    } else if (comptime std.mem.eql(u8, kind, "series")) {
        for (regions, 0..) |reg, ri| for (0..20) |i| {
            try sep(o, &first);
            const x: f64 = @floatFromInt(i);
            try o.print("{{\"x\":{d},\"y\":{d:.2},\"s\":\"{s}\"}}", .{ x, 50 + 30 * @sin(x / 3 + @as(f64, @floatFromInt(ri))) + r.next() * 8, reg });
        };
    } else if (comptime std.mem.eql(u8, kind, "scatter")) {
        for (0..60) |i| {
            try sep(o, &first);
            try o.print("{{\"w\":{d:.1},\"h\":{d:.1},\"mass\":{d:.0},\"kind\":\"{s}\"}}", .{ 1 + r.next() * 9, 10 + r.next() * 90, 5 + r.next() * 95, regions[i % 3] });
        }
    } else if (comptime std.mem.eql(u8, kind, "hist")) {
        for (0..400) |_| {
            try sep(o, &first);
            // A rough bell from summed uniforms.
            try o.print("{{\"price\":{d:.2}}}", .{(r.next() + r.next() + r.next() + r.next()) * 25});
        }
    } else if (comptime std.mem.eql(u8, kind, "heat")) {
        for ([_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri" }) |d| for ([_][]const u8{ "08", "10", "12", "14", "16", "18" }) |h| {
            try sep(o, &first);
            try o.print("{{\"day\":\"{s}\",\"hour\":\"{s}\",\"load\":{d:.0}}}", .{ d, h, r.next() * 100 });
        };
    } else if (comptime std.mem.eql(u8, kind, "rules")) {
        for ([_]f64{ 20, 45, 80 }, [_][]const u8{ "low", "target", "high" }) |v, n| {
            try sep(o, &first);
            try o.print("{{\"level\":{d},\"name\":\"{s}\"}}", .{ v, n });
        }
    } else if (comptime std.mem.eql(u8, kind, "ticks")) {
        for (0..45) |i| {
            try sep(o, &first);
            try o.print("{{\"ms\":{d:.1},\"op\":\"{s}\"}}", .{ 5 + r.next() * 120 * @as(f64, @floatFromInt(i % 3 + 1)) / 3, ([_][]const u8{ "read", "write", "sync" })[i % 3] });
        }
    } else if (comptime std.mem.eql(u8, kind, "log")) {
        for (0..12) |i| {
            try sep(o, &first);
            const x: f64 = @floatFromInt(i);
            try o.print("{{\"n\":{d},\"t\":{d:.3}}}", .{ x, 0.5 * std.math.pow(f64, 2.4, x) });
        }
    } else if (comptime std.mem.eql(u8, kind, "time")) {
        for (0..48) |i| {
            try sep(o, &first);
            try o.print("{{\"at\":\"2026-03-05T{d:0>2}:{d:0>2}:00Z\",\"cpu\":{d:.1}}}", .{ 6 + i / 4, (i % 4) * 15, 30 + 25 * @sin(@as(f64, @floatFromInt(i)) / 6) + r.next() * 10 });
        }
    }
    try o.writeAll("]");
    return w.written();
}

const Ref = struct { name: []const u8, data: []const u8, rest: []const u8 };

const refs = [_]Ref{
    .{ .name = "bar", .data = "bar", .rest =
    \\"title":"Bars","mark":"bar","encoding":{"x":{"field":"k","type":"nominal","sort":"none"},"y":{"field":"v","type":"quantitative"}}
    },
    .{ .name = "stacked_bar", .data = "sales", .rest =
    \\"title":"Revenue by month","mark":"bar","encoding":{"x":{"field":"month","type":"temporal","timeUnit":"month"},"y":{"field":"revenue","type":"quantitative","aggregate":"sum"},"color":{"field":"region","type":"nominal"}}
    },
    .{ .name = "grouped_bar", .data = "sales", .rest =
    \\"mark":{"type":"bar","stack":"group"},"encoding":{"x":{"field":"month","type":"temporal","timeUnit":"month"},"y":{"field":"revenue","type":"quantitative"},"color":{"field":"region","type":"nominal"}}
    },
    .{ .name = "line_multi", .data = "series", .rest =
    \\"mark":{"type":"line","point":true},"encoding":{"x":{"field":"x","type":"quantitative"},"y":{"field":"y","type":"quantitative"},"color":{"field":"s","type":"nominal","title":"Series"}}
    },
    .{ .name = "area_stacked", .data = "sales", .rest =
    \\"mark":"area","encoding":{"x":{"field":"month","type":"temporal"},"y":{"field":"revenue","type":"quantitative"},"color":{"field":"region","type":"nominal"}}
    },
    .{ .name = "scatter", .data = "scatter", .rest =
    \\"mark":"point","encoding":{"x":{"field":"w","type":"quantitative"},"y":{"field":"h","type":"quantitative"},"size":{"field":"mass","type":"quantitative"},"color":{"field":"kind","type":"nominal"}}
    },
    .{ .name = "histogram", .data = "hist", .rest =
    \\"mark":"bar","encoding":{"x":{"field":"price","type":"quantitative","bin":{"maxbins":20}},"y":{"aggregate":"count"}}
    },
    .{ .name = "heatmap", .data = "heat", .rest =
    \\"mark":"rect","encoding":{"x":{"field":"hour","type":"ordinal"},"y":{"field":"day","type":"nominal","sort":"none"},"color":{"field":"load","type":"quantitative"}}
    },
    .{ .name = "rules", .data = "rules", .rest =
    \\"width":400,"height":200,"mark":{"type":"rule","strokeWidth":2},"encoding":{"y":{"field":"level","type":"quantitative","scale":{"domain":[0,100]}},"color":{"field":"name","type":"nominal","sort":"none"}}
    },
    .{ .name = "tick_strip", .data = "ticks", .rest =
    \\"height":160,"mark":"tick","encoding":{"x":{"field":"ms","type":"quantitative"},"y":{"field":"op","type":"nominal"}}
    },
    .{ .name = "log_axis", .data = "log", .rest =
    \\"mark":{"type":"line","point":true},"encoding":{"x":{"field":"n","type":"ordinal"},"y":{"field":"t","type":"quantitative","scale":{"type":"log"},"title":"Seconds"}}
    },
    .{ .name = "time_axis", .data = "time", .rest =
    \\"title":"CPU","mark":"line","encoding":{"x":{"field":"at","type":"temporal"},"y":{"field":"cpu","type":"quantitative","scale":{"zero":true},"format":"plain"}}
    },
};

fn build(a: Allocator, ref: Ref, comptime kind: []const u8) !chart.CompiledChart {
    const json = try std.fmt.allocPrint(a, "{{\"data\":{{\"values\":{s}}},{s}}}", .{ try data(a, kind), ref.rest });
    var diag: chart.Diagnostic = .{};
    const s = chart.parseSpec(a, json, &diag) catch |e| {
        std.debug.print("{s}: {s}\n", .{ ref.name, diag.message });
        return e;
    };
    var cd: chart.compile_mod.Diagnostic = .{};
    return chart.compile(a, gpa, &s, .{}, &cd) catch |e| {
        std.debug.print("{s}: {s}\n", .{ ref.name, cd.message });
        return e;
    };
}

fn svgOf(a: Allocator, c: *const chart.CompiledChart) ![]const u8 {
    var cv: vector.VectorCanvas = .init(a);
    try chart.render(c, &cv);
    const dl = try cv.finish();
    var w: std.Io.Writer.Allocating = .init(a);
    try vector.writeSvg(&w.writer, &dl, .{ .view = .xywh(0, 0, c.width, c.height), .background = .rgb(0xFFFFFF) });
    return w.written();
}

test "svg_goldens" {
    inline for (refs) |ref| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const c = try build(a, ref, ref.data);
        const svg = try svgOf(a, &c);
        try @import("zg_core").testkit.golden.expectGoldenOpts(testing.io, @src(), ref.name ++ ".svg", svg, .{ .root = @import("zg_options").package_root, .dir = "testdata/chart", .normalize = .exact });
    }
}

test "compile errors name the encoding" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: chart.Diagnostic = .{};
    const s = try chart.parseSpec(a,
        \\{"data":{"values":[{"a":1}]},"mark":"bar","encoding":{"x":{"field":"b","type":"nominal"}}}
    , &diag);
    var cd: chart.compile_mod.Diagnostic = .{};
    try testing.expectError(error.InvalidChart, chart.compile(a, gpa, &s, .{}, &cd));
    try testing.expectEqualStrings("encoding.x.field: unknown field `b`; fields: a", cd.message);
    const f = try chart.parseSpec(a,
        \\{"data":{"artifact":"A-1"},"mark":"bar","encoding":{"x":{"field":"b","type":"nominal"}}}
    , &diag);
    try testing.expectError(error.InvalidChart, chart.compile(a, gpa, &f, .{}, &cd));
    try testing.expectEqualStrings("data: artifact data needs a data source", cd.message);
}

test "hit_test_nearest" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try build(a, refs[0], "bar");
    // Inside the fourth bar (delta, 91).
    var bar4: ?chart.compile_mod.Item = null;
    var n: usize = 0;
    for (c.items) |it| if (it.geom == .rect) {
        if (n == 3) bar4 = it;
        n += 1;
    };
    const b = bar4.?.geom.rect;
    const tip = (try chart.hitTest(&c, a, .{ b.x + b.w / 2, b.y + 4 })).?;
    try testing.expectEqual(2, tip.lines.len);
    try testing.expectEqualStrings("k", tip.lines[0].label);
    try testing.expectEqualStrings("delta", tip.lines[0].value);
    try testing.expectEqualStrings("91", tip.lines[1].value);
    // Within 8 px beside the bar, nothing beyond it.
    try testing.expect((try chart.hitTest(&c, a, .{ b.x - 6, b.y + 10 })) != null);
    try testing.expect((try chart.hitTest(&c, a, .{ b.x + b.w / 2, b.y - 12 })) == null);

    // Lines: the nearest vertex of the nearest series.
    const l = try build(a, refs[3], "series");
    const first = l.targets[0];
    const tl = (try chart.hitTest(&l, a, .{ first.x0 + 2, first.y0 - 2 })).?;
    try testing.expectEqual(first.row, tl.row);
    try testing.expectEqualStrings("x", tl.lines[0].label);
    try testing.expectEqualStrings("Series", tl.lines[2].label);

    // Temporal fields show timestamps.
    const t = try build(a, refs[11], "time");
    const tt = (try chart.hitTest(&t, a, .{ t.targets[5].x0, t.targets[5].y0 })).?;
    try testing.expectEqualStrings("2026-03-05 07:15", tt.lines[0].value);
}

test "large line charts are decimated and points sampled" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var t: chart.Table = .{ .rows = 100_000 };
    const xs = try a.alloc(chart.transform.Lit, t.rows);
    const ys = try a.alloc(chart.transform.Lit, t.rows);
    for (xs, ys, 0..) |*x, *y, i| {
        x.* = .{ .int = @intCast(i) };
        y.* = .{ .float = @sin(@as(f64, @floatFromInt(i)) / 500) };
    }
    try t.put(a, "x", .int, xs);
    try t.put(a, "y", .float, ys);
    const Src = struct {
        t: chart.Table,
        fn load(ctx: *anyopaque, _: Allocator, _: *const chart.spec.Data) anyerror!chart.Table {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.t;
        }
    };
    var src: Src = .{ .t = t };
    var diag: chart.Diagnostic = .{};
    const s = try chart.parseSpec(a,
        \\{"data":{"artifact":"A-big"},"mark":"line","encoding":{"x":{"field":"x","type":"quantitative"},"y":{"field":"y","type":"quantitative"}}}
    , &diag);
    var cd: chart.compile_mod.Diagnostic = .{};
    const c = try chart.compile(a, gpa, &s, .{ .source = .{ .ctx = &src, .load = Src.load } }, &cd);
    const pts = c.items[0].geom.line.points;
    try testing.expect(pts.len <= 4 * @as(usize, @intFromFloat(c.plot.w)) + 4);
    try testing.expect(pts.len > 100);
}

test "dense lines draw the pixels their stroke covers" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // 20,000 noisy points over a 400 px plot, decimated by M4.
    var t: chart.Table = .{ .rows = 20_000 };
    const xs = try a.alloc(chart.transform.Lit, t.rows);
    const ys = try a.alloc(chart.transform.Lit, t.rows);
    var h: u32 = 5;
    for (xs, ys, 0..) |*x, *y, i| {
        h = h *% 1103515245 +% 12345;
        x.* = .{ .int = @intCast(i) };
        y.* = .{ .float = @sin(@as(f64, @floatFromInt(i)) / 900) * 50 + @as(f64, @floatFromInt(h >> 24)) / 16 };
    }
    try t.put(a, "x", .int, xs);
    try t.put(a, "y", .float, ys);
    const Src = struct {
        t: chart.Table,
        fn load(ctx: *anyopaque, _: Allocator, _: *const chart.spec.Data) anyerror!chart.Table {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.t;
        }
    };
    var src: Src = .{ .t = t };
    var diag: chart.Diagnostic = .{};
    const s = try chart.parseSpec(a,
        \\{"width":480,"height":240,"data":{"artifact":"A-big"},"mark":"line","encoding":{"x":{"field":"x","type":"quantitative"},"y":{"field":"y","type":"quantitative"}}}
    , &diag);
    var cd: chart.compile_mod.Diagnostic = .{};
    const c = try chart.compile(a, gpa, &s, .{ .source = .{ .ctx = &src, .load = Src.load } }, &cd);
    const pts = c.items[0].geom.line.points;
    try testing.expect(@as(f32, @floatFromInt(pts.len)) > 2 * c.plot.w);

    const black: vector.Color = .rgb(0);
    var band_cv: vector.VectorCanvas = .init(a);
    try chart.render_mod.denseLine(&band_cv, pts, 2, black);
    const band_dl = try band_cv.finish();
    var stroke_cv: vector.VectorCanvas = .init(a);
    const p = try stroke_cv.path();
    try p.moveTo(a, pts[0][0], pts[0][1]);
    for (pts[1..]) |q| try p.lineTo(a, q[0], q[1]);
    try stroke_cv.stroke(p, .{ .width = 2, .join = .round, .cap = .round }, black);
    const stroke_dl = try stroke_cv.finish();

    const w: u32 = 480;
    const ht: u32 = 240;
    const band_px = try test_util.renderTiled(gpa, &band_dl, 1, w, ht);
    defer gpa.free(band_px);
    const stroke_px = try test_util.renderTiled(gpa, &stroke_dl, 1, w, ht);
    defer gpa.free(stroke_px);
    var covered: usize = 0;
    var off: usize = 0;
    var i: usize = 3;
    while (i < band_px.len) : (i += 4) {
        const sa: i32 = stroke_px[i];
        const ba: i32 = band_px[i];
        covered += @intFromBool(sa > 0 or ba > 0);
        // Solid in one, (nearly) empty in the other.
        off += @intFromBool((sa >= 192 and ba <= 64) or (ba >= 192 and sa <= 64));
    }
    // Edges differ in antialiasing; the shapes agree.
    try testing.expect(covered > 4000);
    try testing.expect(off * 100 < covered * 2);
}
