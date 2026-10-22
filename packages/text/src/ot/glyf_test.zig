//! `glyf` tests: handcrafted glyphs for each flag and composite form, the
//! whole TrueType test corpus against header bounds, and fontTools path
//! goldens in `testdata/golden/glyf/`. Every glyph of every TTF test font
//! was also diffed once against `gen_outline_golden.py --all` (0 diffs).

const std = @import("std");
const testing = std.testing;
const glyf = @import("glyf.zig");
const Glyf = glyf.Glyf;
const Face = @import("face.zig").Face;
const path_mod = @import("../outline/path.zig");
const Path = path_mod.Path;
const fonts = @import("../testing/fonts.zig");

const Pt = struct { x: i16, y: i16, on: bool = true };

/// Builds a simple glyph with long (int16) coordinates and no repeats.
fn simple(gpa: std.mem.Allocator, contours: []const []const Pt) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var bb: [4]i16 = .{ std.math.maxInt(i16), std.math.maxInt(i16), std.math.minInt(i16), std.math.minInt(i16) };
    for (contours) |c| for (c) |p| {
        bb = .{ @min(bb[0], p.x), @min(bb[1], p.y), @max(bb[2], p.x), @max(bb[3], p.y) };
    };
    try putI16(gpa, &out, @intCast(contours.len));
    for (bb) |v| try putI16(gpa, &out, v);
    var end: i32 = -1;
    for (contours) |c| {
        end += @intCast(c.len);
        try putI16(gpa, &out, @intCast(end));
    }
    try putI16(gpa, &out, 0); // no instructions
    for (contours) |c| for (c) |p| try out.append(gpa, if (p.on) 1 else 0);
    var prev: i16 = 0;
    for (contours) |c| for (c) |p| {
        try putI16(gpa, &out, p.x - prev);
        prev = p.x;
    };
    prev = 0;
    for (contours) |c| for (c) |p| {
        try putI16(gpa, &out, p.y - prev);
        prev = p.y;
    };
    return out.toOwnedSlice(gpa);
}

fn putI16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: i16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(i16, &b, v, .big);
    try out.appendSlice(gpa, &b);
}

const Comp = struct {
    glyph: u16,
    flags: u16 = 0x0002 | 0x0001, // ARGS_ARE_XY_VALUES | ARG_1_AND_2_ARE_WORDS
    arg1: i16 = 0,
    arg2: i16 = 0,
    /// Raw F2Dot14 values following the arguments.
    scale: []const i16 = &.{},
};

fn composite(gpa: std.mem.Allocator, comps: []const Comp) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for ([_]i16{ -1, 0, 0, 0, 0 }) |v| try putI16(gpa, &out, v);
    for (comps, 0..) |c, i| {
        const more: u16 = if (i + 1 < comps.len) 0x0020 else 0;
        try putI16(gpa, &out, @bitCast(c.flags | more));
        try putI16(gpa, &out, @bitCast(c.glyph));
        try putI16(gpa, &out, c.arg1);
        try putI16(gpa, &out, c.arg2);
        for (c.scale) |s| try putI16(gpa, &out, s);
    }
    return out.toOwnedSlice(gpa);
}

/// glyf + long loca for `glyphs` (empty slices are empty glyphs).
const Font = struct {
    glyf: []u8,
    loca: []u8,

    fn init(gpa: std.mem.Allocator, glyphs: []const []const u8) !Font {
        var g: std.ArrayList(u8) = .empty;
        errdefer g.deinit(gpa);
        var l: std.ArrayList(u8) = .empty;
        errdefer l.deinit(gpa);
        for (glyphs) |d| {
            try putU32(gpa, &l, @intCast(g.items.len));
            try g.appendSlice(gpa, d);
            while (g.items.len % 4 != 0) try g.append(gpa, 0);
        }
        try putU32(gpa, &l, @intCast(g.items.len));
        return .{ .glyf = try g.toOwnedSlice(gpa), .loca = try l.toOwnedSlice(gpa) };
    }

    fn deinit(f: Font, gpa: std.mem.Allocator) void {
        gpa.free(f.glyf);
        gpa.free(f.loca);
    }

    fn view(f: Font, n: u16) !Glyf {
        return Glyf.init(f.glyf, f.loca, true, n);
    }
};

fn putU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try out.appendSlice(gpa, &b);
}

/// Outlines `gid` and returns its `Path.format` text (caller frees).
fn render(g: *const Glyf, gid: u16) ![]u8 {
    const gpa = testing.allocator;
    var s: glyf.Scratch = .{};
    defer s.deinit(gpa);
    var p: Path = .{};
    defer p.deinit(gpa);
    _ = try g.outline(gpa, gid, &s, null, &p);
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try p.format(&w.writer);
    return w.toOwnedSlice();
}

fn expectRender(g: *const Glyf, gid: u16, want: []const u8) !void {
    const got = try render(g, gid);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const square = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 100 }, .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 0 } };

test "glyf simple square" {
    const gpa = testing.allocator;
    const sq = try simple(gpa, &.{&square});
    defer gpa.free(sq);
    const f = try Font.init(gpa, &.{ &.{}, sq });
    defer f.deinit(gpa);
    const g = try f.view(2);
    try expectRender(&g, 1, "M 0 0 L 0 100 L 100 100 L 100 0 Z");
    try expectRender(&g, 0, "");
    try testing.expectEqual(@as(?path_mod.Rect, null), try g.headerBounds(0));
    try testing.expectEqual(path_mod.Rect{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 }, (try g.headerBounds(1)).?);
    try testing.expectError(error.Malformed, g.glyphData(2));
}

test "glyf implied midpoints" {
    const gpa = testing.allocator;
    // All off-curve: starts at the midpoint of the last and first points.
    const circle = try simple(gpa, &.{&.{
        .{ .x = 0, .y = 100, .on = false }, .{ .x = 100, .y = 100, .on = false },
        .{ .x = 100, .y = 0, .on = false }, .{ .x = 0, .y = 0, .on = false },
    }});
    defer gpa.free(circle);
    // Mixed: two consecutive off-curve points imply an on-curve midpoint,
    // and the contour starts at its first on-curve point.
    const mixed = try simple(gpa, &.{&.{
        .{ .x = 10, .y = 10, .on = false }, .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0, .on = false },  .{ .x = 50, .y = 50, .on = false },
    }});
    defer gpa.free(mixed);
    const f = try Font.init(gpa, &.{ circle, mixed });
    defer f.deinit(gpa);
    const g = try f.view(2);
    try expectRender(&g, 0, "M 0 50 Q 0 100 50 100 Q 100 100 100 50 Q 100 0 50 0 Q 0 0 0 50 Z");
    try expectRender(&g, 1, "M 0 0 Q 50 0 50 25 Q 50 50 30 30 Q 10 10 0 0 Z");
}

test "glyf repeat and short flags" {
    const gpa = testing.allocator;
    // A triangle written with X_SHORT/Y_SHORT, IS_SAME and REPEAT:
    // (0,0) (0,100) (100,100), all on-curve.
    const bytes = [_]u8{
        0, 1, 0, 0, 0, 0, 0, 100, 0, 100, // 1 contour, bbox
        0, 2, // endPts
        0, 0, // no instructions
        0x01 | 0x10 | 0x20, // p0: x same (0), y same (0)
        0x01 | 0x10 | 0x04 | 0x20 | 0x08, 0, // p1 (repeat 0): x same, y short +
        0x01 | 0x02 | 0x10 | 0x20, // p2: x short +, y same
        100, // p2 x
        100, // p1 y
    };
    const f = try Font.init(gpa, &.{&bytes});
    defer f.deinit(gpa);
    const g = try f.view(1);
    try expectRender(&g, 0, "M 0 0 L 0 100 L 100 100 Z");
    // REPEAT running past the point count is malformed.
    var bad = bytes;
    bad[17] = 5;
    const f2 = try Font.init(gpa, &.{&bad});
    defer f2.deinit(gpa);
    try testing.expectError(error.Malformed, render(&try f2.view(1), 0));
}

test "composite xy offset, 2x2 transform and scaled offset" {
    const gpa = testing.allocator;
    const sq = try simple(gpa, &.{&square});
    defer gpa.free(sq);
    const shifted = try composite(gpa, &.{ .{ .glyph = 0 }, .{ .glyph = 0, .arg1 = 200, .arg2 = -10 } });
    defer gpa.free(shifted);
    // 90-degree rotation (x' = -y, y' = x) then an unscaled offset.
    const rot = try composite(gpa, &.{.{ .glyph = 0, .flags = 0x0003 | 0x0080, .arg1 = 5, .arg2 = 0, .scale = &.{ 0, 16384, -16384, 0 } }});
    defer gpa.free(rot);
    // Uniform scale 0.5 with SCALED_COMPONENT_OFFSET: the offset is scaled too.
    const scaled = try composite(gpa, &.{.{ .glyph = 0, .flags = 0x0003 | 0x0008 | 0x0800, .arg1 = 100, .arg2 = 0, .scale = &.{8192} }});
    defer gpa.free(scaled);
    const f = try Font.init(gpa, &.{ sq, shifted, rot, scaled });
    defer f.deinit(gpa);
    const g = try f.view(4);
    try expectRender(&g, 1, "M 0 0 L 0 100 L 100 100 L 100 0 Z M 200 -10 L 200 90 L 300 90 L 300 -10 Z");
    try expectRender(&g, 2, "M 5 0 L -95 0 L -95 100 L 5 100 Z");
    try expectRender(&g, 3, "M 50 0 L 50 50 L 100 50 L 100 0 Z");
}

test "composite point matching" {
    const gpa = testing.allocator;
    const sq = try simple(gpa, &.{&square});
    defer gpa.free(sq);
    const dot = try simple(gpa, &.{&.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 5, .y = 10 } }});
    defer gpa.free(dot);
    // Base square, then the dot's point 2 (5,10) placed on the square's
    // point 2 (100,100): words, not XY values.
    const accented = try composite(gpa, &.{ .{ .glyph = 0 }, .{ .glyph = 1, .flags = 0x0001, .arg1 = 2, .arg2 = 2 } });
    defer gpa.free(accented);
    // Byte arguments, anchor out of range.
    const bad = try composite(gpa, &.{ .{ .glyph = 0 }, .{ .glyph = 1, .flags = 0x0001, .arg1 = 9, .arg2 = 0 } });
    defer gpa.free(bad);
    const f = try Font.init(gpa, &.{ sq, dot, accented, bad });
    defer f.deinit(gpa);
    const g = try f.view(4);
    try expectRender(&g, 2, "M 0 0 L 0 100 L 100 100 L 100 0 Z M 95 90 L 105 90 L 100 100 Z");
    try testing.expectError(error.Malformed, render(&g, 3));
}

test "composite self-reference and depth limits" {
    const gpa = testing.allocator;
    const sq = try simple(gpa, &.{&square});
    defer gpa.free(sq);
    const self_ref = try composite(gpa, &.{.{ .glyph = 1 }});
    defer gpa.free(self_ref);
    // 2 -> 3 -> 2
    const a = try composite(gpa, &.{.{ .glyph = 3 }});
    defer gpa.free(a);
    const b = try composite(gpa, &.{.{ .glyph = 2 }});
    defer gpa.free(b);
    // A chain 4 -> 5 -> ... -> 14 -> square, deeper than 8.
    var glyphs: std.ArrayList([]const u8) = .empty;
    defer glyphs.deinit(gpa);
    try glyphs.appendSlice(gpa, &.{ sq, self_ref, a, b });
    var chain: [11][]u8 = undefined;
    for (&chain, 0..) |*c, i| c.* = try composite(gpa, &.{.{ .glyph = if (i == 10) 0 else @intCast(5 + i) }});
    defer for (chain) |c| gpa.free(c);
    for (chain) |c| try glyphs.append(gpa, c);
    const f = try Font.init(gpa, glyphs.items);
    defer f.deinit(gpa);
    const g = try f.view(@intCast(glyphs.items.len));
    try testing.expectError(error.LimitExceeded, render(&g, 1));
    try testing.expectError(error.LimitExceeded, render(&g, 2));
    try testing.expectError(error.LimitExceeded, render(&g, 4));
    // Depth 8 is allowed.
    try expectRender(&g, 7, "M 0 0 L 0 100 L 100 100 L 100 0 Z");
}

test "delta hook moves points and phantoms" {
    const gpa = testing.allocator;
    const sq = try simple(gpa, &.{&square});
    defer gpa.free(sq);
    const comp = try composite(gpa, &.{.{ .glyph = 0, .arg1 = 10 }});
    defer gpa.free(comp);
    const f = try Font.init(gpa, &.{ sq, comp });
    defer f.deinit(gpa);
    const g = try f.view(2);
    const Hook = struct {
        calls: u32 = 0,
        fn apply(ctx: *anyopaque, gid: u16, pts: [][2]f32, ends: []const u16, is_composite: bool) error{ Malformed, OutOfMemory }!void {
            const h: *@This() = @ptrCast(@alignCast(ctx));
            h.calls += 1;
            if (is_composite) {
                std.debug.assert(gid == 1 and pts.len == 1 + 4 and ends.len == 0);
                pts[0][1] += 7; // move the component
                pts[pts.len - 3][0] += 50; // widen the advance
            } else {
                std.debug.assert(pts.len == 4 + 4 and ends.len == 1 and ends[0] == 3);
                for (pts[0..4]) |*p| p[0] += 1;
            }
        }
    };
    var h: Hook = .{};
    var s: glyf.Scratch = .{};
    defer s.deinit(gpa);
    var p: Path = .{};
    defer p.deinit(gpa);
    const info = try g.outline(gpa, 1, &s, .{ .ctx = &h, .apply = Hook.apply }, &p);
    try testing.expectEqual(@as(u32, 2), h.calls);
    try testing.expectEqual(path_mod.Rect{ .x0 = 11, .y0 = 7, .x1 = 111, .y1 = 107 }, p.bounds);
    try testing.expectEqual(@as(f32, 50), info.phantom[1][0] - info.phantom[0][0]);
}

const ttf_fonts = [_][]const u8{
    "FiraCode-Regular.ttf",
    "JetBrainsMono[wght].ttf",
    "Inter[opsz,wght].ttf",
    "NotoSansArabic-Subset.ttf",
    "NotoSansDevanagari-Subset.ttf",
    "NotoColorEmoji-COLRv1-Subset.ttf",
    "test_glyphs-glyf_colr_1.ttf",
    "test_glyphs-glyf_colr_1_variable.ttf",
};

test "all glyphs of all TTF test fonts decode within header bounds" {
    const gpa = testing.allocator;
    var s: glyf.Scratch = .{};
    defer s.deinit(gpa);
    var p: Path = .{};
    defer p.deinit(gpa);
    for (ttf_fonts) |name| {
        const data = try fonts.font(gpa, name);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        const g = face.glyf().?;
        for (0..face.num_glyphs) |i| {
            const gid: u16 = @intCast(i);
            p.reset();
            const info = try g.outline(gpa, gid, &s, null, &p);
            // Without deltas the horizontal phantoms span the hmtx advance.
            try testing.expectEqual(@as(f32, @floatFromInt(face.advance(gid))), info.phantom[1][0] - info.phantom[0][0]);
            const hb = (try g.headerBounds(gid)) orelse {
                try testing.expectEqual(@as(usize, 0), p.points.items.len);
                continue;
            };
            if (p.points.items.len == 0) continue; // components without contours
            // The path is relative to the left phantom point (xMin - lsb).
            const shift = hb.x0 - @as(f32, @floatFromInt(face.lsb(gid)));
            var b = p.bounds;
            b.x0 += shift;
            b.x1 += shift;
            if (@abs(b.x0 - hb.x0) > 1 or @abs(b.y0 - hb.y0) > 1 or @abs(b.x1 - hb.x1) > 1 or @abs(b.y1 - hb.y1) > 1) {
                std.debug.print("{s} gid {d}: bounds {any} header {any}\n", .{ name, gid, b, hb });
                return error.TestUnexpectedResult;
            }
        }
        // Warm buffers: a second pass allocates nothing.
        for (0..face.num_glyphs) |i| {
            p.reset();
            _ = try g.outline(testing.failing_allocator, @intCast(i), &s, null, &p);
        }
    }
}

const Golden = struct {
    font: []const u8,
    glyphs: []const struct { gid: u16, name: []const u8, path: []const u8 },
};

/// Compares two `Path.format` strings: same commands, coordinates within
/// 1/64 unit.
pub fn expectPathsClose(want: []const u8, got: []const u8) !void {
    var a = std.mem.tokenizeScalar(u8, want, ' ');
    var b = std.mem.tokenizeScalar(u8, got, ' ');
    while (true) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return;
        if (x == null or y == null) return error.TestExpectedEqual;
        const xv = std.fmt.parseFloat(f64, x.?) catch {
            if (!std.mem.eql(u8, x.?, y.?)) return error.TestExpectedEqual;
            continue;
        };
        const yv = std.fmt.parseFloat(f64, y.?) catch return error.TestExpectedEqual;
        if (@abs(xv - yv) > 1.0 / 64.0) return error.TestExpectedEqual;
    }
}

test "glyf outlines match fontTools goldens" {
    const gpa = testing.allocator;
    const files = [_][]const u8{ "FiraCode-Regular.zon", "JetBrainsMono.zon", "Inter.zon", "NotoSansArabic-Subset.zon", "NotoSansDevanagari-Subset.zon" };
    var n: usize = 0;
    for (files) |file| {
        var pb: [128]u8 = undefined;
        const src = try fonts.readTestdataZ(gpa, try std.fmt.bufPrint(&pb, "golden/glyf/{s}", .{file}));
        defer gpa.free(src);
        const gold = try std.zon.parse.fromSliceAlloc(Golden, gpa, src, null, .{});
        defer std.zon.parse.free(gpa, gold);
        const data = try fonts.font(gpa, gold.font);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        const g = face.glyf().?;
        for (gold.glyphs) |e| {
            const got = try render(&g, e.gid);
            defer gpa.free(got);
            expectPathsClose(e.path, got) catch |err| {
                std.debug.print("{s} {s}:\n want {s}\n got  {s}\n", .{ gold.font, e.name, e.path, got });
                return err;
            };
            n += 1;
        }
    }
    try testing.expect(n >= 20);
}

test "fuzz: ot-glyf" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try fuzzOne(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "ot-glyf") });
}

/// Input: 1 byte glyph count n (1..8), then 4*(n+1) bytes of long loca
/// (clamped), then glyf bytes. Every glyph is outlined, with and without a
/// delta hook; only `Malformed` and `LimitExceeded` may come back.
fn fuzzOne(input: []const u8) !void {
    if (input.len < 1) return;
    const n: u16 = @as(u16, input[0] % 8) + 1;
    const loca_len = 4 * (@as(usize, n) + 1);
    if (input.len < 1 + loca_len) return;
    const loca = input[1..][0..loca_len];
    const data = input[1 + loca_len ..];
    const g = Glyf.init(data, loca, true, n) catch return;
    const gpa = testing.allocator;
    var s: glyf.Scratch = .{};
    defer s.deinit(gpa);
    var p: Path = .{};
    defer p.deinit(gpa);
    const Hook = struct {
        fn apply(_: *anyopaque, _: u16, pts: [][2]f32, _: []const u16, _: bool) error{ Malformed, OutOfMemory }!void {
            for (pts) |*q| q[0] += 1;
        }
    };
    var dummy: u8 = 0;
    for (0..n) |i| {
        for ([_]?glyf.DeltaHook{ null, .{ .ctx = &dummy, .apply = Hook.apply } }) |hook| {
            p.reset();
            _ = g.outline(gpa, @intCast(i), &s, hook, &p) catch |e| switch (e) {
                error.Malformed, error.LimitExceeded => continue,
                error.OutOfMemory => return e,
            };
            // Every contour is closed and the verbs consume exactly the points.
            var used: usize = 0;
            for (p.verbs.items) |v| used += Path.pointCount(v);
            try testing.expectEqual(p.points.items.len, used);
            try testing.expect(!p.open);
        }
    }
}
