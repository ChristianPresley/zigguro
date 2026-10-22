//! End-to-end shaping tests against the fonts in `testdata/fonts`.

const std = @import("std");
const testing = std.testing;
const ot = @import("../ot/root.zig");
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const fonts = @import("../testing/fonts.zig");
const shaper = @import("shaper.zig");
const Shaper = shaper.Shaper;
const GlyphRun = shaper.GlyphRun;

const Loaded = struct {
    bytes: []u8,
    face: ot.Face,
    inst: FaceInstance,

    fn deinit(l: *Loaded) void {
        l.inst.deinit(testing.allocator);
        testing.allocator.free(l.bytes);
    }
};

fn load(l: *Loaded, name: []const u8) !void {
    l.bytes = try fonts.font(testing.allocator, name);
    errdefer testing.allocator.free(l.bytes);
    l.face = try ot.Face.init(l.bytes, 0);
    l.inst = try FaceInstance.init(testing.allocator, &l.face, &.{});
}

const features_mod = @import("features.zig");
const buffer = @import("buffer.zig");
const fvar = @import("../ot/var/fvar.zig");

const Script = @import("../unicode/root.zig").Script;

const GoldenAxis = struct { tag: []const u8, value: f32 };
const GoldenCase = struct {
    font: []const u8,
    text: []const u8,
    features: []const u8,
    dir: buffer.Direction,
    script: Script = .Latn,
    axes: []const GoldenAxis,
    glyphs: []const [5]i32,
};

/// Shapes every case of `testdata/golden/shape/<set>.zon` and compares
/// with HarfBuzz's output; returns the number of mismatching cases.
fn checkGolden(set: []const u8, verbose: bool) !usize {
    const gpa = testing.allocator;
    var path_buf: [128]u8 = undefined;
    const src = try fonts.readTestdataZ(gpa, try std.fmt.bufPrint(&path_buf, "golden/shape/{s}.zon", .{set}));
    defer gpa.free(src);
    const cases = try std.zon.parse.fromSliceAlloc([]const GoldenCase, gpa, src, null, .{});
    defer std.zon.parse.free(gpa, cases);
    var s = Shaper.init(gpa);
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var failures: usize = 0;
    for (cases) |cs| {
        _ = arena.reset(.retain_capacity);
        var l: Loaded = undefined;
        l.bytes = try fonts.font(gpa, cs.font);
        defer gpa.free(l.bytes);
        l.face = try ot.Face.init(l.bytes, 0);
        var axes: [4]fvar.AxisValue = undefined;
        for (cs.axes, 0..) |a, i| axes[i] = .{ .tag = std.mem.readInt(u32, a.tag[0..4], .big), .value = a.value };
        l.inst = try FaceInstance.init(gpa, &l.face, axes[0..cs.axes.len]);
        defer l.inst.deinit(gpa);
        var feats: std.ArrayList(buffer.Feature) = .empty;
        defer feats.deinit(gpa);
        try features_mod.parseFeatures(cs.features, &feats, gpa);
        var run: GlyphRun = .{};
        try s.shape(&l.inst, cs.text, cs.script, cs.dir, ot.tag("dflt"), feats.items, &run, arena.allocator());
        s.forget(&l.inst);
        var ok = run.len() == cs.glyphs.len;
        if (ok) for (cs.glyphs, 0..) |g, i| {
            const got = [5]i32{ run.gids[i], @intCast(run.clusters[i]), run.x_adv[i], run.x_off[i], run.y_off[i] };
            if (!std.mem.eql(i32, &g, &got)) ok = false;
        };
        if (ok) continue;
        failures += 1;
        if (!verbose) continue;
        std.debug.print("\n{s} {s} \"{f}\" [{s}]\n  want:", .{ set, cs.font, std.zig.fmtString(cs.text), cs.features });
        for (cs.glyphs) |g| std.debug.print(" {d}:{d}:{d}:{d}:{d}", .{ g[0], g[1], g[2], g[3], g[4] });
        std.debug.print("\n  got: ", .{});
        for (0..run.len()) |i| std.debug.print(" {d}:{d}:{d}:{d}:{d}", .{ run.gids[i], run.clusters[i], run.x_adv[i], run.x_off[i], run.y_off[i] });
        std.debug.print("\n", .{});
    }
    return failures;
}

test "shape golden: code ligatures" {
    try testing.expectEqual(@as(usize, 0), try checkGolden("code_ligatures", true));
}

test "shape golden: gpos kerning" {
    try testing.expectEqual(@as(usize, 0), try checkGolden("gpos_kern", true));
}

test "shape golden: gpos marks" {
    try testing.expectEqual(@as(usize, 0), try checkGolden("gpos_marks", true));
}

test "shape golden: driver" {
    try testing.expectEqual(@as(usize, 0), try checkGolden("driver", true));
}

test "shape golden: random" {
    try testing.expectEqual(@as(usize, 0), try checkGolden("random", true));
}

test "shape golden: arabic" {
    try testing.expectEqual(@as(usize, 0), try checkGolden("arabic", true));
}

const shape_cache = @import("shape_cache.zig");

fn expectSameRun(a: GlyphRun, b: GlyphRun) !void {
    try testing.expectEqualSlices(ot.GlyphId, a.gids, b.gids);
    try testing.expectEqualSlices(u32, a.clusters, b.clusters);
    try testing.expectEqualSlices(i32, a.x_adv, b.x_adv);
    try testing.expectEqualSlices(i32, a.x_off, b.x_off);
    try testing.expectEqualSlices(i32, a.y_off, b.y_off);
}

test "shape: word cache hit equals full shaping" {
    const gpa = testing.allocator;
    const names = [_][]const u8{ "Inter[opsz,wght].ttf", "SourceSerif4-Regular.otf", "JetBrainsMono[wght].ttf", "FiraCode-Regular.ttf" };
    const words = [_][]const u8{ "1\u{2044}2", "fn", "main()", "void", "{", "}", "return", "x", "=", "AVATAR", "Wave", "office", "To", "e\u{301}t\u{e9}", "a->b", "!=", "0xFF", "//", "ffi", "", "  " };
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var s = Shaper.init(gpa);
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const no_calt = [_]buffer.Feature{ .{ .tag = ot.tag("calt"), .value = 0 }, .{ .tag = ot.tag("kern"), .value = 0 } };
    const no_kern = [_]buffer.Feature{.{ .tag = ot.tag("kern"), .value = 0 }};
    const feature_sets = [_][]const buffer.Feature{ &no_calt, &no_kern, &.{}, &.{} };
    for (names, feature_sets, 0..) |name, feats, fi| {
        var l: Loaded = undefined;
        try load(&l, name);
        defer l.deinit();
        defer s.forget(&l.inst);
        var cache = try shape_cache.ShapeCache.init(gpa, .{ .max_entries = 64, .budget_bytes = 16 << 10 });
        defer cache.deinit();
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        for (0..250) |_| {
            _ = arena.reset(.retain_capacity);
            line.clearRetainingCapacity();
            for (0..rnd.intRangeAtMost(usize, 1, 12)) |_| {
                try line.appendSlice(gpa, words[rnd.uintLessThan(usize, words.len)]);
                try line.append(gpa, ' ');
            }
            const dir: buffer.Direction = if (rnd.uintLessThan(u8, 8) == 0) .rtl else .ltr;
            var full: GlyphRun = .{};
            var cached: GlyphRun = .{};
            try s.shape(&l.inst, line.items, .Latn, dir, ot.tag("dflt"), feats, &full, arena.allocator());
            try shape_cache.shapeCached(&s, &cache, &l.inst, @intCast(fi), 0, line.items, .Latn, dir, ot.tag("dflt"), feats, &cached, arena.allocator());
            try expectSameRun(full, cached);
        }
        // The first two take the word path: many words repeat.
        if (fi < 2) try testing.expect(cache.hits > cache.misses);
    }
}

test "shape: space participation per font" {
    const gpa = testing.allocator;
    var s = Shaper.init(gpa);
    defer s.deinit();
    const Want = struct { []const u8, []const buffer.Feature, bool };
    // Inter's `calt` and `kern` and Source Serif's `kern` see spaces; without them
    // only `frac` does, which runs where masks are set. The code fonts'
    // `calt` contexts look at spaces too.
    for ([_]Want{
        .{ "Inter[opsz,wght].ttf", &.{}, true },
        .{ "Inter[opsz,wght].ttf", &.{ .{ .tag = ot.tag("calt"), .value = 0 }, .{ .tag = ot.tag("kern"), .value = 0 } }, false },
        .{ "SourceSerif4-Regular.otf", &.{}, true },
        .{ "SourceSerif4-Regular.otf", &.{.{ .tag = ot.tag("kern"), .value = 0 }}, false },
        .{ "JetBrainsMono[wght].ttf", &.{}, true },
        .{ "FiraCode-Regular.ttf", &.{}, true },
    }) |w| {
        var l: Loaded = undefined;
        try load(&l, w[0]);
        defer l.deinit();
        defer s.forget(&l.inst);
        const p = try s.plan(&l.inst, .Latn, ot.tag("dflt"), .ltr, w[1]);
        try testing.expectEqual(w[2], p.space_participates);
    }
}

test "plan: order and masks for latn with liga=0" {
    const gpa = testing.allocator;
    var l: Loaded = undefined;
    try load(&l, "Inter[opsz,wght].ttf");
    defer l.deinit();
    var s = Shaper.init(gpa);
    defer s.deinit();
    const user = [_]buffer.Feature{
        .{ .tag = ot.tag("liga"), .value = 0 },
        .{ .tag = ot.tag("ss01"), .value = 1, .start = 2, .end = 5 },
        .{ .tag = ot.tag("cv05"), .value = 3 },
    };
    const p = try s.plan(&l.inst, .Latn, ot.tag("dflt"), .ltr, &user);
    try testing.expectEqual(ot.tag("latn"), p.chosen_script[0].?);
    // liga=0 removes the feature; calt and kern share the global bit.
    try testing.expectEqual(@as(u32, 0), p.maskOf(ot.tag("liga")).mask);
    try testing.expectEqual(@as(u32, 1), p.maskOf(ot.tag("calt")).mask);
    try testing.expectEqual(@as(u32, 1), p.maskOf(ot.tag("kern")).mask);
    // A ranged feature gets its own bit, off by default; cv05=3 gets two
    // bits holding 3 in the global mask.
    const ss01 = p.maskOf(ot.tag("ss01"));
    try testing.expect(ss01.mask != 0 and ss01.mask & 1 == 0 and p.global_mask & ss01.mask == 0);
    const cv05 = p.maskOf(ot.tag("cv05"));
    try testing.expectEqual(@as(u32, 2), @popCount(cv05.mask));
    try testing.expectEqual(cv05.mask, p.global_mask & cv05.mask);
    try testing.expectEqual(@as(usize, 1), p.ranged.len);
    // rvrn's pause splits GSUB into two stages; each is sorted and unique.
    try testing.expectEqual(@as(usize, 2), p.gsub_stages.len);
    try testing.expectEqual(@as(usize, 1), p.gpos_stages.len);
    for (p.gsub_stages) |st| if (st.lookups.len > 1) for (st.lookups[1..], 1..) |lm, i| try testing.expect(st.lookups[i - 1].index < lm.index);
    // mark and mkmk keep joiners manual.
    try testing.expect(p.apply_gpos and !p.apply_kern);
}
