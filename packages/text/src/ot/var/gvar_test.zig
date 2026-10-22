//! gvar tests: the spec's packed-number examples, crafted tables for
//! shared/embedded/intermediate tuples, point subsets with IUP and
//! composites, and fontTools outline goldens at several instances.

const std = @import("std");
const testing = std.testing;
const reader = @import("../reader.zig");
const Face = @import("../face.zig").Face;
const gvar = @import("gvar.zig");
const Gvar = gvar.Gvar;
const instance = @import("instance.zig");
const FaceInstance = instance.FaceInstance;
const Path = @import("../../outline/path.zig").Path;
const fonts = @import("../../testing/fonts.zig");
const glyf_test = @import("../glyf_test.zig");

test "packed point count and deltas: spec examples" {
    // 0x81 0x22: a two-byte count of 0x0122 = 290.
    {
        const bytes = [_]u8{ 0x81, 0x22 };
        var r = try reader.Reader.at(&bytes, 0);
        var out: std.ArrayList(u16) = .empty;
        defer out.deinit(testing.allocator);
        // Only the count is present, so decoding the runs fails cleanly.
        try testing.expectError(error.Malformed, gvar.decodePoints(testing.allocator, &r, &out));
        r = try reader.Reader.at(&bytes, 0);
        try testing.expectEqual(@as(usize, 290), (try gvar.PointStream.init(&r)).count);
    }
    {
        const bytes = [_]u8{ 0x03, 0x0A, 0x97, 0x00, 0xC6, 0x87, 0x41, 0x10, 0x22, 0xFB, 0x34 };
        var r = try reader.Reader.at(&bytes, 0);
        var out: [14]f32 = undefined;
        try gvar.decodeDeltas(&r, &out);
        try testing.expectEqualSlices(f32, &.{ 10, -105, 0, -58, 0, 0, 0, 0, 0, 0, 0, 0, 4130, -1228 }, &out);
        try testing.expectEqual(@as(usize, 0), r.remaining());
        // A run that overflows the count is malformed.
        var short: [13]f32 = undefined;
        r = try reader.Reader.at(&bytes, 0);
        try testing.expectError(error.Malformed, gvar.decodeDeltas(&r, &short));
    }
    {
        // Point numbers: 3 points in one byte run (cumulative): 1, 3, 7.
        const bytes = [_]u8{ 0x03, 0x02, 0x01, 0x02, 0x04 };
        var r = try reader.Reader.at(&bytes, 0);
        var out: std.ArrayList(u16) = .empty;
        defer out.deinit(testing.allocator);
        const p = try gvar.decodePoints(testing.allocator, &r, &out);
        try testing.expectEqualSlices(u16, &.{ 1, 3, 7 }, p.nums);
    }
}

test "iup interpolation and edge cases" {
    // Square: (0,0) (0,100) (100,100) (100,0).
    const orig = [_][2]f32{ .{ 0, 0 }, .{ 0, 100 }, .{ 100, 100 }, .{ 100, 0 } };
    {
        var d = [_][2]f32{ .{ 10, 4 }, .{ 0, 0 }, .{ 30, 8 }, .{ 0, 0 } };
        var t = [_]bool{ true, false, true, false };
        gvar.iupContour(&orig, &d, &t, 0, 3);
        // p1.x = 0 is at the lower touched x (p0): its delta; p1.y = 100 is
        // at the upper touched y (p2): its delta. p3 mirrors.
        try testing.expectEqual([2]f32{ 10, 8 }, d[1]);
        try testing.expectEqual([2]f32{ 30, 4 }, d[3]);
    }
    {
        // A point between its neighbours interpolates.
        const o = [_][2]f32{ .{ 0, 0 }, .{ 25, 0 }, .{ 100, 0 } };
        var d = [_][2]f32{ .{ 10, 0 }, .{ 0, 0 }, .{ 50, 0 } };
        var t = [_]bool{ true, false, true };
        gvar.iupContour(&o, &d, &t, 0, 2);
        try testing.expectEqual(@as(f32, 20), d[1][0]);
    }
    {
        // Equal neighbour coordinates: shared delta when equal, else 0.
        const o = [_][2]f32{ .{ 50, 0 }, .{ 70, 0 }, .{ 50, 0 } };
        var d = [_][2]f32{ .{ 5, 1 }, .{ 0, 0 }, .{ 5, 2 } };
        var t = [_]bool{ true, false, true };
        gvar.iupContour(&o, &d, &t, 0, 2);
        try testing.expectEqual([2]f32{ 5, 0 }, d[1]);
    }
    {
        // One touched point moves the whole contour; untouched contours
        // stay put.
        var d = [_][2]f32{ .{ 0, 0 }, .{ 0, 0 }, .{ 7, -3 }, .{ 0, 0 } };
        var t = [_]bool{ false, false, true, false };
        gvar.iupContour(&orig, &d, &t, 0, 3);
        for (d) |x| try testing.expectEqual([2]f32{ 7, -3 }, x);
        var z = [_][2]f32{.{ 0, 0 }} ** 4;
        var none = [_]bool{false} ** 4;
        gvar.iupContour(&orig, &z, &none, 0, 3);
        for (z) |x| try testing.expectEqual([2]f32{ 0, 0 }, x);
    }
}

/// Builds a one-axis-or-more gvar table (long offsets).
const Builder = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    fn u8_(b: *Builder, v: u8) void {
        b.buf[b.len] = v;
        b.len += 1;
    }
    fn u16_(b: *Builder, v: u16) void {
        std.mem.writeInt(u16, b.buf[b.len..][0..2], v, .big);
        b.len += 2;
    }
    fn i16_(b: *Builder, v: i16) void {
        b.u16_(@bitCast(v));
    }
    fn u32_(b: *Builder, v: u32) void {
        std.mem.writeInt(u32, b.buf[b.len..][0..4], v, .big);
        b.len += 4;
    }
    fn at32(b: *Builder, off: usize, v: u32) void {
        std.mem.writeInt(u32, b.buf[off..][0..4], v, .big);
    }
    fn at16(b: *Builder, off: usize, v: u16) void {
        std.mem.writeInt(u16, b.buf[off..][0..2], v, .big);
    }
    fn bytes(b: *const Builder) []const u8 {
        return b.buf[0..b.len];
    }
};

const TupleSpec = struct {
    /// Embedded peak; null uses shared tuple 0.
    peak: ?[]const i16 = null,
    start: ?[]const i16 = null,
    end: ?[]const i16 = null,
    /// Private points; null uses the glyph's shared points; empty = all.
    points: ?[]const u16 = null,
    dx: []const i16,
    dy: []const i16,
};

fn writePoints(b: *Builder, pts: []const u16) void {
    if (pts.len == 0) return b.u8_(0);
    b.u8_(@intCast(pts.len));
    b.u8_(0x80 | @as(u8, @intCast(pts.len - 1))); // one run of words
    var prev: u16 = 0;
    for (pts) |p| {
        b.u16_(p - prev);
        prev = p;
    }
}

fn writeDeltas(b: *Builder, ds: []const i16) void {
    b.u8_(0x40 | @as(u8, @intCast(ds.len - 1)));
    for (ds) |d| b.i16_(d);
}

/// A gvar for one glyph with `axes` axes and the shared tuple `shared`.
fn build(b: *Builder, axes: u16, shared: []const i16, shared_points: ?[]const u16, tuples: []const TupleSpec) void {
    b.u16_(1);
    b.u16_(0);
    b.u16_(axes);
    b.u16_(if (shared.len > 0) 1 else 0);
    b.u32_(0); // shared tuples offset, patched
    b.u16_(1); // glyph count
    b.u16_(1); // long offsets
    b.u32_(0); // array offset, patched
    b.u32_(0);
    b.u32_(0); // end offset, patched
    b.at32(8, @intCast(b.len));
    for (shared) |v| b.i16_(v);
    const array = b.len;
    b.at32(16, @intCast(array));
    // GlyphVariationData.
    b.u16_(@as(u16, @intCast(tuples.len)) | if (shared_points != null) @as(u16, 0x8000) else 0);
    const data_off_at = b.len;
    b.u16_(0);
    var size_at: [8]usize = undefined;
    for (tuples, 0..) |t, i| {
        size_at[i] = b.len;
        b.u16_(0);
        var index: u16 = 0;
        if (t.peak != null) index |= 0x8000;
        if (t.start != null) index |= 0x4000;
        if (t.points != null) index |= 0x2000;
        b.u16_(index);
        if (t.peak) |p| for (p) |v| b.i16_(v);
        if (t.start) |s| for (s) |v| b.i16_(v);
        if (t.end) |e| for (e) |v| b.i16_(v);
    }
    b.at16(data_off_at, @intCast(b.len - array));
    if (shared_points) |sp| writePoints(b, sp);
    for (tuples, 0..) |t, i| {
        const start = b.len;
        if (t.points) |p| writePoints(b, p);
        writeDeltas(b, t.dx);
        writeDeltas(b, t.dy);
        b.at16(size_at[i], @intCast(b.len - start));
    }
    b.at32(24, @intCast(b.len - array));
}

fn applied(table: []const u8, axes: u16, coords: []const i16, pts: [][2]f32, ends: []const u16, composite: bool) !void {
    const g = try Gvar.init(table, axes, 1);
    var s: gvar.GvarScratch = .{};
    defer s.deinit(testing.allocator);
    try g.apply(testing.allocator, 0, coords, pts, ends, composite, &s);
}

const square = [_][2]f32{ .{ 0, 0 }, .{ 0, 100 }, .{ 100, 100 }, .{ 100, 0 }, .{ 0, 0 }, .{ 500, 0 }, .{ 0, 0 }, .{ 0, 0 } };

test "shared tuples and shared all-points" {
    var b: Builder = .{};
    const d8 = [_]i16{10} ** 8;
    build(&b, 1, &.{16384}, &.{}, &.{.{ .dx = &d8, .dy = &(.{0} ** 8) }});
    var pts = square;
    try applied(b.bytes(), 1, &.{8192}, &pts, &.{3}, false);
    for (pts, square) |p, o| try testing.expectEqual([2]f32{ o[0] + 5, o[1] }, p);
    // Default and opposite-side coordinates leave the points alone.
    pts = square;
    try applied(b.bytes(), 1, &.{0}, &pts, &.{3}, false);
    try applied(b.bytes(), 1, &.{-8192}, &pts, &.{3}, false);
    try testing.expectEqual(square, pts);
}

test "intermediate region" {
    var b: Builder = .{};
    const d8 = [_]i16{-20} ** 8;
    build(&b, 1, &.{}, null, &.{.{ .peak = &.{8192}, .start = &.{3277}, .end = &.{16384}, .points = &.{}, .dx = &d8, .dy = &d8 }});
    var pts = square;
    try applied(b.bytes(), 1, &.{12288}, &pts, &.{3}, false); // halfway down from the peak
    try testing.expectEqual([2]f32{ -10, -10 }, pts[0]);
    pts = square;
    try applied(b.bytes(), 1, &.{1000}, &pts, &.{3}, false); // below start
    try testing.expectEqual(square, pts);
}

test "private point subset with IUP; phantoms never inferred" {
    var b: Builder = .{};
    // Touch p0 (+10, +4) and p2 (+30, +8), plus the right phantom (index 5).
    build(&b, 1, &.{}, null, &.{.{ .peak = &.{16384}, .points = &.{ 0, 2, 5 }, .dx = &.{ 10, 30, 40 }, .dy = &.{ 4, 8, 0 } }});
    var pts = square;
    try applied(b.bytes(), 1, &.{16384}, &pts, &.{3}, false);
    try testing.expectEqual([2]f32{ 10, 4 }, pts[0]);
    try testing.expectEqual([2]f32{ 10, 108 }, pts[1]);
    try testing.expectEqual([2]f32{ 130, 108 }, pts[2]);
    try testing.expectEqual([2]f32{ 130, 4 }, pts[3]);
    try testing.expectEqual([2]f32{ 0, 0 }, pts[4]); // left phantom untouched
    try testing.expectEqual([2]f32{ 540, 0 }, pts[5]);
    // The phantom deltas alone, without decoding the outline.
    const g = try Gvar.init(b.bytes(), 1, 1);
    const ph = try g.phantomDeltas(0, &.{16384}, 4);
    try testing.expectEqual([4][2]f32{ .{ 0, 0 }, .{ 40, 0 }, .{ 0, 0 }, .{ 0, 0 } }, ph);
}

test "composite offsets vary without IUP" {
    var b: Builder = .{};
    // Two components; only the second's offset moves.
    build(&b, 2, &.{}, null, &.{.{ .peak = &.{ 0, 16384 }, .points = &.{1}, .dx = &.{20}, .dy = &.{-6} }});
    var pts = [_][2]f32{ .{ 0, 0 }, .{ 100, 0 }, .{ 0, 0 }, .{ 600, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    try applied(b.bytes(), 2, &.{ 16384, 16384 }, &pts, &.{}, true);
    try testing.expectEqual([2]f32{ 0, 0 }, pts[0]);
    try testing.expectEqual([2]f32{ 120, -6 }, pts[1]);
    // Axis count must match fvar.
    try testing.expectError(error.Malformed, Gvar.init(b.bytes(), 1, 1));
}

const VarGolden = struct {
    font: []const u8,
    coords: []const i16,
    glyphs: []const struct { gid: u16, name: []const u8, path: []const u8 },
};

test "gvar outlines match fontTools goldens" {
    const gpa = testing.allocator;
    const files = [_][]const u8{ "JetBrainsMono-wght100.zon", "JetBrainsMono-wght700.zon", "Inter-opsz20-wght900.zon" };
    var scratch: instance.OutlineScratch = .{};
    defer scratch.deinit(gpa);
    var p: Path = .{};
    defer p.deinit(gpa);
    for (files) |file| {
        var pb: [128]u8 = undefined;
        const src = try fonts.readTestdataZ(gpa, try std.fmt.bufPrint(&pb, "golden/gvar/{s}", .{file}));
        defer gpa.free(src);
        const gold = try std.zon.parse.fromSliceAlloc(VarGolden, gpa, src, null, .{});
        defer std.zon.parse.free(gpa, gold);
        const data = try fonts.font(gpa, gold.font);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        var fi = try FaceInstance.initNormalized(gpa, &face, gold.coords);
        defer fi.deinit(gpa);
        for (gold.glyphs) |e| {
            p.reset();
            try fi.outline(gpa, e.gid, &scratch, &p);
            var w: std.Io.Writer.Allocating = .init(gpa);
            defer w.deinit();
            try p.format(&w.writer);
            glyf_test.expectPathsClose(e.path, w.written()) catch |err| {
                std.debug.print("{s} {s}:\n want {s}\n got  {s}\n", .{ file, e.name, e.path, w.written() });
                return err;
            };
        }
        // Warm buffers: every glyph again without allocating.
        for (gold.glyphs) |e| {
            p.reset();
            try fi.outline(testing.failing_allocator, e.gid, &scratch, &p);
        }
    }
}

test "phantom advance equals hvar" {
    const gpa = testing.allocator;
    const data = try fonts.font(gpa, "JetBrainsMono[wght].ttf");
    defer gpa.free(data);
    const face = try Face.init(data, 0);
    for ([_]i16{ -16384, 13916, 16384 }) |c| {
        var fi = try FaceInstance.initNormalized(gpa, &face, &.{c});
        defer fi.deinit(gpa);
        try testing.expect(fi.hvar != null and fi.gvar != null);
        var worst: f32 = 0;
        for (0..face.num_glyphs) |gid| {
            const a = fi.advance(@intCast(gid));
            const b = fi.advanceFromPhantoms(@intCast(gid));
            worst = @max(worst, @abs(a - b));
        }
        try testing.expect(worst <= 1.0 / 64.0);
    }
}

test "fuzz: ot-gvar" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [600]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try fuzzOne(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "ot-gvar") });
}

/// Input: axis count (1..4), point count (0..32), contour split, a
/// coordinate per axis, then a gvar table for glyph 0.
fn fuzzOne(input: []const u8) !void {
    if (input.len < 8) return;
    const axes: u16 = @as(u16, input[0] % 4) + 1;
    const n: usize = input[1] % 33;
    const split: u16 = input[2];
    var coords: [4]i16 = undefined;
    for (&coords, 0..) |*c, i| c.* = @as(i16, @intCast(@as(i32, input[3 + i]) * 128 - 16384));
    const table = input[7..];
    const g = Gvar.init(table, axes, 1) catch return;
    var pts: [36][2]f32 = undefined;
    for (pts[0 .. n + 4], 0..) |*p, i| p.* = .{ @floatFromInt(i * 7 % 50), @floatFromInt(i * 13 % 50) };
    var ends_buf: [2]u16 = undefined;
    var ends: []const u16 = &.{};
    if (n > 0) {
        const mid: u16 = @intCast(@min(split, n - 1));
        ends_buf = .{ mid, @intCast(n - 1) };
        ends = if (mid == n - 1) ends_buf[1..] else &ends_buf;
    }
    var s: gvar.GvarScratch = .{};
    defer s.deinit(testing.allocator);
    for ([_]bool{ false, true }) |composite| {
        g.apply(testing.allocator, 0, coords[0..axes], pts[0 .. n + 4], ends, composite, &s) catch |e| switch (e) {
            error.Malformed => {},
            error.OutOfMemory => return e,
        };
    }
    _ = g.phantomDeltas(0, coords[0..axes], n) catch {};
}
