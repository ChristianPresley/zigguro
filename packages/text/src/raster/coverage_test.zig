//! Coverage rasterizer tests: exact areas on hand-built shapes, the fill
//! rule, flattening error, a supersampled reference over the golden glyph
//! set, and the cross-platform determinism hashes in
//! `testdata/golden/raster/hashes.zon`.

const std = @import("std");
const testing = std.testing;
const coverage = @import("coverage.zig");
const Accumulator = coverage.Accumulator;
const flatten = @import("flatten.zig");
const rz = @import("rasterizer.zig");
const Rasterizer = rz.Rasterizer;
const Path = @import("../outline/path.zig").Path;
const Affine = @import("../outline/path.zig").Affine;
const Face = @import("../ot/face.zig").Face;
const variation = @import("../ot/var/root.zig");
const fonts = @import("../testing/fonts.zig");

fn polygon(a: *Accumulator, pts: []const [2]f32) void {
    for (pts, 0..) |p, i| a.line(p, pts[(i + 1) % pts.len]);
}

fn coverageF32(gpa: std.mem.Allocator, a: *const Accumulator) ![]f32 {
    const out = try gpa.alloc(f32, a.w * a.h);
    a.integrateF32(out);
    return out;
}

test "unit square exact coverage" {
    const gpa = testing.allocator;
    var a: Accumulator = .{};
    defer a.deinit(gpa);
    try a.reset(gpa, 3, 3);
    polygon(&a, &.{ .{ 0.25, 0.25 }, .{ 0.25, 2.75 }, .{ 2.75, 2.75 }, .{ 2.75, 0.25 } });
    const f = try coverageF32(gpa, &a);
    defer gpa.free(f);
    const want = [9]f32{ 0.5625, 0.75, 0.5625, 0.75, 1, 0.75, 0.5625, 0.75, 0.5625 };
    for (want, f) |w, g| try testing.expectApproxEqAbs(w, g, 1e-6);
    var b: [9]u8 = undefined;
    a.integrate(&b, 3);
    try testing.expectEqualSlices(u8, &.{ 143, 191, 143, 191, 255, 191, 143, 191, 143 }, &b);
}

test "triangle area sums" {
    const gpa = testing.allocator;
    var a: Accumulator = .{};
    defer a.deinit(gpa);
    try a.reset(gpa, 40, 30);
    const tri = [_][2]f32{ .{ 1.3, 0.7 }, .{ 37.9, 12.2 }, .{ 9.1, 29.4 } };
    polygon(&a, &tri);
    const f = try coverageF32(gpa, &a);
    defer gpa.free(f);
    var sum: f64 = 0;
    for (f) |v| sum += v;
    const area = @abs((tri[1][0] - tri[0][0]) * (tri[2][1] - tri[0][1]) - (tri[2][0] - tri[0][0]) * (tri[1][1] - tri[0][1])) / 2;
    try testing.expectApproxEqRel(@as(f64, area), sum, 0.005);
    // The 8-bit output sums to the same area.
    const b = try gpa.alloc(u8, 40 * 30);
    defer gpa.free(b);
    a.integrate(b, 40);
    var bsum: f64 = 0;
    for (b) |v| bsum += @as(f64, @floatFromInt(v)) / 255;
    try testing.expectApproxEqRel(@as(f64, area), bsum, 0.005);
}

test "winding hole" {
    const gpa = testing.allocator;
    var a: Accumulator = .{};
    defer a.deinit(gpa);
    try a.reset(gpa, 10, 10);
    polygon(&a, &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 } });
    polygon(&a, &.{ .{ 3, 3 }, .{ 7, 3 }, .{ 7, 7 }, .{ 3, 7 } }); // reversed
    var b: [100]u8 = undefined;
    a.integrate(&b, 10);
    for (0..10) |y| for (0..10) |x| {
        const inside = x >= 3 and x < 7 and y >= 3 and y < 7;
        try testing.expectEqual(@as(u8, if (inside) 0 else 255), b[y * 10 + x]);
    };
}

test "overlapping contours clamp to 1" {
    const gpa = testing.allocator;
    var a: Accumulator = .{};
    defer a.deinit(gpa);
    try a.reset(gpa, 6, 4);
    polygon(&a, &.{ .{ 0, 0 }, .{ 0, 4 }, .{ 4, 4 }, .{ 4, 0 } });
    polygon(&a, &.{ .{ 2, 0 }, .{ 2, 4 }, .{ 6, 4 }, .{ 6, 0 } }); // same direction
    var b: [24]u8 = undefined;
    a.integrate(&b, 6);
    for (b) |v| try testing.expectEqual(@as(u8, 255), v);
}

fn boxPath(gpa: std.mem.Allocator, p: *Path, x0: f32, y0: f32, x1: f32, y1: f32) !void {
    try p.moveTo(gpa, x0, y0);
    try p.lineTo(gpa, x0, y1);
    try p.lineTo(gpa, x1, y1);
    try p.lineTo(gpa, x1, y0);
    try p.close(gpa);
}

test "subpixel offsets shift coverage" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    var p: Path = .{};
    defer p.deinit(gpa);
    // 2×2 px box at 1 px per unit.
    try boxPath(gpa, &p, 0, 0, 2, 2);
    const b0 = try r.rasterizePath(&p, 1, .{ .px_per_em = 1 });
    try testing.expectEqual(@as(u16, 2), b0.width);
    try testing.expectEqual(@as(i16, -2), b0.top); // y up in font units
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, b0.pixels);
    const b1 = try r.rasterizePath(&p, 1, .{ .px_per_em = 1, .subpixel_x = 0.25 });
    try testing.expectEqual(@as(u16, 3), b1.width);
    try testing.expectEqual(@as(i16, 0), b1.left);
    try testing.expectEqualSlices(u8, &.{ 191, 255, 64, 191, 255, 64 }, b1.pixels);
}

test "empty and invalid paths give empty bitmaps" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    var p: Path = .{};
    defer p.deinit(gpa);
    try testing.expect((try r.rasterizePath(&p, 1000, .{ .px_per_em = 14 })).isEmpty());
    try boxPath(gpa, &p, 0, 0, std.math.nan(f32), 5);
    try testing.expect((try r.rasterizePath(&p, 1000, .{ .px_per_em = 14 })).isEmpty());
    p.reset();
    try boxPath(gpa, &p, 0, 0, 5000, 10);
    try testing.expectError(error.TooLarge, r.rasterizePath(&p, 100, .{ .px_per_em = 100 }));
}

const Collect = struct {
    gpa: std.mem.Allocator,
    segs: std.ArrayList([2][2]f32) = .empty,
    pub fn segment(c: *Collect, a: [2]f32, b: [2]f32) void {
        c.segs.append(c.gpa, .{ a, b }) catch @panic("oom");
    }
};

fn distToSegment(p: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const l2 = dx * dx + dy * dy;
    const t = if (l2 == 0) 0 else std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2, 0, 1);
    const ex = a[0] + t * dx - p[0];
    const ey = a[1] + t * dy - p[1];
    return @sqrt(ex * ex + ey * ey);
}

fn polylineDist(segs: []const [2][2]f32, p: [2]f32) f32 {
    var d: f32 = std.math.inf(f32);
    for (segs) |s| d = @min(d, distToSegment(p, s[0], s[1]));
    return d;
}

test "quad/cubic flatten error < tol" {
    const gpa = testing.allocator;
    var rng: std.Random.DefaultPrng = .init(7);
    const rand = rng.random();
    for (0..200) |_| {
        var pts: [4][2]f32 = undefined;
        for (&pts) |*p| p.* = .{ rand.float(f32) * 60, rand.float(f32) * 60 };
        const tol = flatten.tol_gray;
        var c: Collect = .{ .gpa = gpa };
        defer c.segs.deinit(gpa);
        flatten.quadTo(&c, pts[0], pts[1], pts[2], tol);
        try testing.expectEqual(pts[2], c.segs.items[c.segs.items.len - 1][1]);
        for (0..65) |k| {
            const t: f32 = @as(f32, @floatFromInt(k)) / 64;
            const u = 1 - t;
            var q: [2]f32 = undefined;
            for (0..2) |i| q[i] = u * u * pts[0][i] + 2 * u * t * pts[1][i] + t * t * pts[2][i];
            try testing.expect(polylineDist(c.segs.items, q) <= tol * 1.01);
        }
        c.segs.clearRetainingCapacity();
        flatten.cubicTo(&c, pts[0], pts[1], pts[2], pts[3], tol);
        try testing.expectEqual(pts[3], c.segs.items[c.segs.items.len - 1][1]);
        for (0..65) |k| {
            const t: f32 = @as(f32, @floatFromInt(k)) / 64;
            const u = 1 - t;
            var q: [2]f32 = undefined;
            for (0..2) |i| q[i] = u * u * u * pts[0][i] + 3 * u * u * t * pts[1][i] + 3 * u * t * t * pts[2][i] + t * t * t * pts[3][i];
            try testing.expect(polylineDist(c.segs.items, q) <= tol * 1.01);
        }
    }
}

/// The golden glyph set: 30 glyphs across glyf, CFF, CJK and Arabic.
pub const golden_fonts = [_]struct { file: []const u8, text: []const u8 }{
    .{ .file = "JetBrainsMono[wght].ttf", .text = "AaBgQ@&%#W" },
    .{ .file = "SourceSerif4-Regular.otf", .text = "agRSW&f8" },
    .{ .file = "SourceHanSansJP-Subset.otf", .text = "語漢字日本あ" },
    .{ .file = "NotoSansArabic-Subset.ttf", .text = "ابجدهو" },
};
/// Pixel sizes of the golden set.
pub const golden_sizes = [_]f32{ 8, 11, 14, 20, 32, 72 };

/// Reference coverage: the same flattened polygon, with the winding
/// number integrated exactly in x on `sub` sub-scanlines per pixel row,
/// then `min(|area|, 1)` per pixel as the accumulator defines it. It shares
/// only `walk` (the flattening) with the code under test.
fn reference(gpa: std.mem.Allocator, segs: []const [2][2]f32, w: u32, h: u32, sub: u32) ![]f32 {
    const out = try gpa.alloc(f32, w * h);
    @memset(out, 0);
    const row = try gpa.alloc(f64, w);
    defer gpa.free(row);
    const fsub: f64 = @floatFromInt(sub);
    for (0..h) |y| {
        @memset(row, 0);
        for (0..sub) |j| {
            const sy: f64 = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(j)) + 0.5) / fsub;
            for (segs) |s| {
                const ay: f64 = s[0][1];
                const by: f64 = s[1][1];
                if (ay == by) continue;
                const dir: f64 = if (ay < by) 1 else -1;
                if (!(sy >= @min(ay, by) and sy < @max(ay, by))) continue;
                const t = (sy - ay) / (by - ay);
                const xc = @as(f64, s[0][0]) + t * (@as(f64, s[1][0]) - @as(f64, s[0][0]));
                // Winding steps by `dir` to the right of the crossing.
                for (0..w) |i| {
                    const fi: f64 = @floatFromInt(i);
                    row[i] += dir * (fi + 1 - std.math.clamp(xc, fi, fi + 1));
                }
            }
        }
        for (0..w) |i| out[y * w + i] = @floatCast(@min(@abs(row[i] / fsub), 1));
    }
    return out;
}

test "supersample reference" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    var worst: f32 = 0;
    for (golden_fonts) |gf| {
        const data = try fonts.font(gpa, gf.file);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        var inst = try variation.FaceInstance.init(gpa, &face, &.{});
        defer inst.deinit(gpa);
        var it = std.unicode.Utf8View.initUnchecked(gf.text).iterator();
        while (it.nextCodepoint()) |cp| {
            const gid = face.glyphIndex(cp);
            try testing.expect(gid != 0);
            for (golden_sizes) |px| {
                const bm = try r.rasterizeGlyph(&inst, gid, .{ .px_per_em = px });
                try testing.expect(!bm.isEmpty());
                const m = rz.pixelTransform(@floatFromInt(face.units_per_em), .{ .px_per_em = px });
                var c: Collect = .{ .gpa = gpa };
                defer c.segs.deinit(gpa);
                rz.walk(&r.path, m, .{ @floatFromInt(bm.left), @floatFromInt(bm.top) }, flatten.tol_gray, &c);
                const ref = try reference(gpa, c.segs.items, bm.width, bm.height, 128);
                defer gpa.free(ref);
                for (0..bm.height) |y| for (0..bm.width) |x| {
                    const got: f32 = @floatFromInt(bm.pixels[y * bm.stride + x]);
                    const d = @abs(got - ref[y * bm.width + x] * 255);
                    worst = @max(worst, d);
                    if (d > 2) {
                        std.debug.print("{s} U+{X} {d}px ({d},{d}): got {d}, ref {d}\n", .{ gf.file, cp, px, x, y, got, ref[y * bm.width + x] * 255 });
                        return error.TestExpectedEqual;
                    }
                };
            }
        }
    }
    try testing.expect(worst <= 2);
}

/// FNV-1a 64 over each bitmap's size, bearings and pixels, per font and
/// size, in golden-set order.
pub fn goldenHashes(gpa: std.mem.Allocator, r: *Rasterizer) ![golden_fonts.len][golden_sizes.len]u64 {
    var out: [golden_fonts.len][golden_sizes.len]u64 = undefined;
    for (golden_fonts, 0..) |gf, fi| {
        const data = try fonts.font(gpa, gf.file);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        var inst = try variation.FaceInstance.init(gpa, &face, &.{});
        defer inst.deinit(gpa);
        for (golden_sizes, 0..) |px, si| {
            var h: std.hash.Fnv1a_64 = .init();
            var it = std.unicode.Utf8View.initUnchecked(gf.text).iterator();
            while (it.nextCodepoint()) |cp| {
                const bm = try r.rasterizeGlyph(&inst, face.glyphIndex(cp), .{ .px_per_em = px });
                var hdr: [8]u8 = undefined;
                std.mem.writeInt(u16, hdr[0..2], bm.width, .little);
                std.mem.writeInt(u16, hdr[2..4], bm.height, .little);
                std.mem.writeInt(i16, hdr[4..6], bm.left, .little);
                std.mem.writeInt(i16, hdr[6..8], bm.top, .little);
                h.update(&hdr);
                for (0..bm.height) |y| h.update(bm.row(y));
            }
            out[fi][si] = h.final();
        }
    }
    return out;
}

const HashFile = struct { fonts: []const struct { file: []const u8, hashes: []const u64 } };

test "determinism hash" {
    const gpa = testing.allocator;
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    const got = try goldenHashes(gpa, &r);
    const src = try fonts.readTestdataZ(gpa, "golden/raster/hashes.zon");
    defer gpa.free(src);
    const want = try std.zon.parse.fromSliceAlloc(HashFile, gpa, src, null, .{});
    defer std.zon.parse.free(gpa, want);
    var ok = want.fonts.len == golden_fonts.len;
    for (golden_fonts, 0..) |gf, fi| {
        if (fi >= want.fonts.len or !std.mem.eql(u8, want.fonts[fi].file, gf.file) or
            !std.mem.eql(u64, want.fonts[fi].hashes, &got[fi])) ok = false;
    }
    if (!ok) {
        std.debug.print("raster hashes changed; computed:\n", .{});
        for (golden_fonts, 0..) |gf, fi| {
            std.debug.print("        .{{ .file = \"{s}\", .hashes = .{{", .{gf.file});
            for (got[fi], 0..) |v, k| std.debug.print("{s}0x{x:0>16}", .{ if (k == 0) " " else ", ", v });
            std.debug.print(" }} }},\n", .{});
        }
        return error.TestExpectedEqual;
    }
}

test "no allocation after warm-up" {
    const gpa = testing.allocator;
    const data = try fonts.font(gpa, "JetBrainsMono[wght].ttf");
    defer gpa.free(data);
    const face = try Face.init(data, 0);
    var inst = try variation.FaceInstance.init(gpa, &face, &.{});
    defer inst.deinit(gpa);
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    const gid = face.glyphIndex('W');
    _ = try r.rasterizeGlyph(&inst, gid, .{ .px_per_em = 32 });
    r.gpa = testing.failing_allocator;
    defer r.gpa = gpa;
    for ("AaBgQ@&%#W") |ch| _ = try r.rasterizeGlyph(&inst, face.glyphIndex(ch), .{ .px_per_em = 20 });
}

test "fuzz: raster-path" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try fuzzPath(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "raster-path") });
}

/// Input: byte 0 = size (px = 1 + b), byte 1 = subpixel quarter and the
/// oblique flag; then records of 1 verb byte plus its points as raw f32
/// bits (so huge, NaN, infinite and denormal coordinates all occur). Any
/// path must give a bitmap or `TooLarge`, never a crash.
fn fuzzPath(input: []const u8) !void {
    if (input.len < 2) return;
    const gpa = testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    var i: usize = 2;
    while (i < input.len) {
        const v = input[i] % 5;
        i += 1;
        const n: usize = switch (v) {
            0, 1 => 1,
            2 => 2,
            3 => 3,
            else => 0,
        };
        if (i + n * 8 > input.len) break;
        var pts: [3][2]f32 = undefined;
        for (0..n) |k| {
            pts[k] = .{
                @bitCast(std.mem.readInt(u32, input[i..][0..4], .little)),
                @bitCast(std.mem.readInt(u32, input[i + 4 ..][0..4], .little)),
            };
            i += 8;
        }
        if (v != 0 and v != 4 and !p.open) try p.moveTo(gpa, 0, 0);
        switch (v) {
            0 => try p.moveTo(gpa, pts[0][0], pts[0][1]),
            1 => try p.lineTo(gpa, pts[0][0], pts[0][1]),
            2 => try p.quadTo(gpa, pts[0][0], pts[0][1], pts[1][0], pts[1][1]),
            3 => try p.cubicTo(gpa, pts[0][0], pts[0][1], pts[1][0], pts[1][1], pts[2][0], pts[2][1]),
            else => try p.close(gpa),
        }
    }
    var r: Rasterizer = .init(gpa);
    defer r.deinit();
    const params: rz.RasterParams = .{
        .px_per_em = 1 + @as(f32, @floatFromInt(input[0])),
        .subpixel_x = @as(f32, @floatFromInt(input[1] & 3)) * 0.25,
        .synth_oblique = input[1] & 4 != 0,
    };
    const bm = r.rasterizePath(&p, 64, params) catch |e| switch (e) {
        error.TooLarge => return,
        else => return e,
    };
    try testing.expect(bm.pixels.len == @as(usize, bm.width) * bm.height);
}
