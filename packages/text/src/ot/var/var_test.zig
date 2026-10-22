//! Variation tests: crafted tables for every branch of normalization,
//! region scalars, ItemVariationStore and DeltaSetIndexMap, and the
//! fontTools references in `testdata/golden/var/reference.zon`.

const std = @import("std");
const testing = std.testing;
const reader = @import("../reader.zig");
const Face = @import("../face.zig").Face;
const ivs = @import("ivs.zig");
const fvar = @import("fvar.zig");
const avar = @import("avar.zig");
const Mvar = @import("mvar.zig").Mvar;
const instance = @import("instance.zig");
const FaceInstance = instance.FaceInstance;
const fonts = @import("../../testing/fonts.zig");

const tag = reader.tag;

fn tagOf(s: []const u8) reader.Tag {
    return std.mem.readInt(u32, s[0..4], .big);
}

/// Big-endian byte builder.
const Bytes = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn u8_(b: *Bytes, v: u8) void {
        b.buf[b.len] = v;
        b.len += 1;
    }
    fn u16_(b: *Bytes, v: u16) void {
        std.mem.writeInt(u16, b.buf[b.len..][0..2], v, .big);
        b.len += 2;
    }
    fn i16_(b: *Bytes, v: i16) void {
        b.u16_(@bitCast(v));
    }
    fn u32_(b: *Bytes, v: u32) void {
        std.mem.writeInt(u32, b.buf[b.len..][0..4], v, .big);
        b.len += 4;
    }
    fn fixed(b: *Bytes, v: f32) void {
        b.u32_(@bitCast(@as(i32, @intFromFloat(v * 65536))));
    }
    fn bytes(b: *const Bytes) []const u8 {
        return b.buf[0..b.len];
    }
};

fn testFvar(b: *Bytes, axes: []const [3]f32) void {
    b.u16_(1);
    b.u16_(0);
    b.u16_(16);
    b.u16_(2);
    b.u16_(@intCast(axes.len));
    b.u16_(20);
    b.u16_(1); // one instance
    b.u16_(@intCast(4 + 4 * axes.len + 2));
    for (axes, 0..) |a, i| {
        b.u32_(tag("wght") + @as(u32, @intCast(i)));
        for (a) |v| b.fixed(v);
        b.u16_(if (i == 1) 1 else 0);
        b.u16_(256 + @as(u16, @intCast(i)));
    }
    b.u16_(300);
    b.u16_(0);
    for (axes) |a| b.fixed(a[2]);
    b.u16_(301);
}

test "normalize without avar" {
    var b: Bytes = .{};
    testFvar(&b, &.{ .{ 100, 400, 900 }, .{ 0, 0, 1 } });
    const f = try fvar.Fvar.init(b.bytes());
    try testing.expectEqual(@as(u16, 2), f.axis_count);
    const a0 = f.axis(0);
    try testing.expectEqual(@as(f32, 100), a0.min);
    try testing.expect(!a0.hidden and f.axis(1).hidden);
    try testing.expectEqual(@as(u16, 256), a0.name_id);
    var out: [2]i16 = undefined;
    const cases = [_]struct { v: f32, want: i16 }{
        .{ .v = 400, .want = 0 },     .{ .v = 100, .want = -16384 },
        .{ .v = 900, .want = 16384 }, .{ .v = 650, .want = 8192 },
        .{ .v = 50, .want = -16384 }, .{ .v = 1200, .want = 16384 },
        // 1/3 of the way down: -5461.33 rounds to -5461.
        .{ .v = 300, .want = -5461 },
    };
    for (cases) |c| {
        fvar.normalize(&f, null, &.{.{ .tag = tag("wght"), .value = c.v }}, &out);
        try testing.expectEqual(c.want, out[0]);
        try testing.expectEqual(@as(i16, 0), out[1]);
    }
    // Unknown tags are ignored; the second axis is addressed by its tag.
    fvar.normalize(&f, null, &.{ .{ .tag = tag("xxxx"), .value = 5 }, .{ .tag = tag("wght") + 1, .value = 0.5 } }, &out);
    try testing.expectEqualSlices(i16, &.{ 0, 8192 }, &out);
    // Named instance.
    var it = f.namedInstances();
    const ni = it.next().?;
    try testing.expectEqual(@as(u16, 300), ni.subfamily_name_id);
    try testing.expectEqual(@as(?u16, 301), ni.postscript_name_id);
    try testing.expectEqual(@as(f32, 900), ni.coord(0));
    try testing.expect(it.next() == null);
    // Truncated.
    try testing.expectError(error.Malformed, fvar.Fvar.init(b.bytes()[0 .. b.len - 1]));
}

fn testAvar(b: *Bytes, maps: []const []const [2]i16) void {
    b.u16_(1);
    b.u16_(0);
    b.u16_(0);
    b.u16_(@intCast(maps.len));
    for (maps) |m| {
        b.u16_(@intCast(m.len));
        for (m) |p| {
            b.i16_(p[0]);
            b.i16_(p[1]);
        }
    }
}

test "normalize with avar segments" {
    var b: Bytes = .{};
    // Axis 0: 0.5 -> 0.25 (so 0.75 -> 0.625). Axis 1: missing the 0 anchor,
    // so ignored.
    testAvar(&b, &.{
        &.{ .{ -16384, -16384 }, .{ 0, 0 }, .{ 8192, 4096 }, .{ 16384, 16384 } },
        &.{ .{ -16384, -16384 }, .{ 16384, 16384 } },
    });
    const a = try avar.Avar.init(b.bytes());
    try testing.expectEqual(@as(i16, 4096), a.map(0, 8192));
    try testing.expectEqual(@as(i16, 10240), a.map(0, 12288));
    try testing.expectEqual(@as(i16, 2048), a.map(0, 4096));
    try testing.expectEqual(@as(i16, -8192), a.map(0, -8192));
    try testing.expectEqual(@as(i16, 16384), a.map(0, 16384));
    try testing.expectEqual(@as(i16, 1234), a.map(1, 1234)); // invalid map: identity
    try testing.expectEqual(@as(i16, 1234), a.map(5, 1234)); // no map
    try testing.expectError(error.Malformed, avar.Avar.init(b.bytes()[0..20]));
}

test "region scalar cases" {
    const s = ivs.axisScalar;
    try testing.expectEqual(@as(f32, 1), s(100, 50, 200, 0)); // start > peak: ignored
    try testing.expectEqual(@as(f32, 1), s(0, 300, 200, 0)); // peak > end: ignored
    try testing.expectEqual(@as(f32, 1), s(-100, 50, 200, 9000)); // crosses zero: ignored
    try testing.expectEqual(@as(f32, 1), s(-100, 0, 200, 9000)); // peak 0
    try testing.expectEqual(@as(f32, 0), s(0, 100, 200, 300)); // out of range
    try testing.expectEqual(@as(f32, 0), s(0, 100, 200, -1));
    try testing.expectEqual(@as(f32, 1), s(0, 100, 200, 100)); // at peak
    try testing.expectEqual(@as(f32, 0.5), s(0, 100, 200, 50));
    try testing.expectEqual(@as(f32, 0.25), s(0, 100, 200, 175));
    try testing.expectEqual(@as(f32, 0.5), s(-16384, -16384, 0, -8192));
}

/// A store with 2 axes, 2 regions and one data subtable of 2 items; the
/// first column uses long words when `long`.
fn testStore(b: *Bytes, long: bool) void {
    b.u16_(1);
    b.u32_(12); // region list
    b.u16_(1);
    b.u32_(12 + 4 + 2 * 2 * 6); // data offset
    // Region list: region 0 peaks on axis 0, region 1 on axis 1.
    b.u16_(2);
    b.u16_(2);
    for ([_][6]i16{ .{ 0, 16384, 16384, 0, 0, 0 }, .{ 0, 0, 0, 0, 16384, 16384 } }) |r| for (r) |v| b.i16_(v);
    b.u16_(2); // items
    b.u16_(if (long) 0x8001 else 1); // one word column
    b.u16_(2);
    b.u16_(1); // column 0 -> region 1
    b.u16_(0); // column 1 -> region 0
    for ([_][2]i32{ .{ 100000, -3 }, .{ -2, 7 } }) |row| {
        if (long) b.u32_(@bitCast(row[0])) else b.i16_(@intCast(std.math.clamp(row[0], -32768, 32767)));
        if (long) b.i16_(@intCast(row[1])) else b.u8_(@bitCast(@as(i8, @intCast(row[1]))));
    }
}

test "ivs long words and scalars" {
    for ([_]bool{ false, true }) |long| {
        var b: Bytes = .{};
        testStore(&b, long);
        const s = try ivs.ItemVariationStore.init(b.bytes());
        const big: f32 = if (long) 100000 else 32767;
        // Axis 1 at 0.5: column 0 (region 1) at half strength.
        try testing.expectEqual(big / 2, s.delta(0, 0, &.{ 0, 8192 }));
        try testing.expectEqual(@as(f32, -3), s.delta(0, 0, &.{ 16384, 0 }));
        try testing.expectEqual(@as(f32, -2 + 7), s.delta(0, 1, &.{ 16384, 16384 }));
        try testing.expectEqual(@as(f32, 0), s.delta(0, 2, &.{ 16384, 16384 })); // no such item
        try testing.expectEqual(@as(f32, 0), s.delta(0xFFFF, 0xFFFF, &.{ 16384, 16384 }));
        var sc: [2]f32 = undefined;
        s.regionScalars(&.{ 16384, 8192 }, &sc);
        try testing.expectEqual([2]f32{ 1, 0.5 }, sc);
        try testing.expectEqual(s.delta(0, 1, &.{ 16384, 8192 }), s.deltaScaled(0, 1, &sc));
        try testing.expectError(error.Malformed, ivs.ItemVariationStore.init(b.bytes()[0..20]));
    }
}

test "delta set index map format 0/1 entry sizes 1-4" {
    for (1..5) |size| for ([_]u8{ 0, 1 }) |format| {
        var b: Bytes = .{};
        const inner_bits: u8 = 4;
        b.u8_(format);
        b.u8_(@intCast(((size - 1) << 4) | (inner_bits - 1)));
        if (format == 0) b.u16_(3) else b.u32_(3);
        for ([_]u32{ 0x12, 0x35, 0x4F }) |v| {
            var k = size;
            while (k > 0) : (k -= 1) b.u8_(@truncate(v >> @intCast((k - 1) * 8)));
        }
        const m = try ivs.DeltaSetIndexMap.init(b.bytes());
        try testing.expectEqual(ivs.VarIdx{ .outer = 1, .inner = 2 }, m.get(0));
        try testing.expectEqual(ivs.VarIdx{ .outer = 3, .inner = 5 }, m.get(1));
        try testing.expectEqual(ivs.VarIdx{ .outer = 4, .inner = 15 }, m.get(2));
        try testing.expectEqual(ivs.VarIdx{ .outer = 4, .inner = 15 }, m.get(1000)); // past the end
        try testing.expectError(error.Malformed, ivs.DeltaSetIndexMap.init(b.bytes()[0 .. b.len - 1]));
    };
}

const Reference = struct {
    normalize: []const struct { font: []const u8, user: []const struct { tag: []const u8, value: f32 }, coords: []const i16 },
    advances: []const struct { font: []const u8, coords: []const i16, adv64: []const i32 },
    mvar: []const struct { font: []const u8, coords: []const i16, x_height: f32, strikeout_pos: f32, underline_pos: f32 },
    named: []const struct { name: []const u8, wght: f32 },
};

fn loadReference() !Reference {
    const src = try fonts.readTestdataZ(testing.allocator, "golden/var/reference.zon");
    defer testing.allocator.free(src);
    return std.zon.parse.fromSliceAlloc(Reference, testing.allocator, src, null, .{});
}

test "normalization matches the reference" {
    const gpa = testing.allocator;
    const ref = try loadReference();
    defer std.zon.parse.free(gpa, ref);
    for (ref.normalize) |c| {
        const data = try fonts.font(gpa, c.font);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        var user: [4]fvar.AxisValue = undefined;
        for (c.user, 0..) |u, i| user[i] = .{ .tag = tagOf(u.tag), .value = u.value };
        var fi = try FaceInstance.init(gpa, &face, user[0..c.user.len]);
        defer fi.deinit(gpa);
        testing.expectEqualSlices(i16, c.coords, fi.coordsSlice()) catch |e| {
            std.debug.print("{s} {any}\n", .{ c.font, c.user });
            return e;
        };
    }
}

test "hvar advances match the reference" {
    const gpa = testing.allocator;
    const ref = try loadReference();
    defer std.zon.parse.free(gpa, ref);
    for (ref.advances) |c| {
        const data = try fonts.font(gpa, c.font);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        var fi = try FaceInstance.initNormalized(gpa, &face, c.coords);
        defer fi.deinit(gpa);
        try testing.expect(fi.hvar != null);
        try testing.expectEqual(@as(usize, face.num_glyphs), c.adv64.len);
        for (c.adv64, 0..) |want, gid| {
            const got = fi.advance(@intCast(gid)) * 64;
            if (@abs(got - @as(f32, @floatFromInt(want))) > 1) {
                std.debug.print("{s} gid {d}: {d} vs {d}\n", .{ c.font, gid, got / 64, @as(f32, @floatFromInt(want)) / 64 });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "mvar deltas match the reference" {
    const gpa = testing.allocator;
    const ref = try loadReference();
    defer std.zon.parse.free(gpa, ref);
    for (ref.mvar) |c| {
        const data = try fonts.font(gpa, c.font);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        var fi = try FaceInstance.initNormalized(gpa, &face, c.coords);
        defer fi.deinit(gpa);
        const m = fi.metrics();
        try testing.expectApproxEqAbs(c.x_height, m.x_height, 1.0 / 64.0);
        try testing.expectApproxEqAbs(c.strikeout_pos, m.strikeout_pos, 1.0 / 64.0);
        try testing.expectApproxEqAbs(c.underline_pos, m.underline_pos, 1.0 / 64.0);
        // The default instance has no deltas and allocates nothing.
        var def = try FaceInstance.initNormalized(testing.failing_allocator, &face, &.{});
        defer def.deinit(testing.failing_allocator);
        try testing.expectEqual(@as(f32, @floatFromInt(face.metrics().x_height)), def.metrics().x_height);
    }
}

test "named instances enumeration" {
    const gpa = testing.allocator;
    const ref = try loadReference();
    defer std.zon.parse.free(gpa, ref);
    const data = try fonts.font(gpa, "JetBrainsMono[wght].ttf");
    defer gpa.free(data);
    const face = try Face.init(data, 0);
    var it = instance.namedInstances(&face);
    var i: usize = 0;
    var nb: [128]u8 = undefined;
    while (it.next()) |ni| : (i += 1) {
        const want = ref.named[i];
        try testing.expectEqual(want.wght, ni.coord(0));
        const name = face.names().get(@enumFromInt(ni.subfamily_name_id), &nb) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(want.name, name);
    }
    try testing.expectEqual(ref.named.len, i);
    // A static font has none.
    const fira = try fonts.font(gpa, "FiraCode-Regular.ttf");
    defer gpa.free(fira);
    const ff = try Face.init(fira, 0);
    var none = instance.namedInstances(&ff);
    try testing.expect(none.next() == null);
}

test "fuzz: ot-var" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            fuzzOne(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "ot-var") });
}

/// Feeds the input to every variation parser as each table kind and
/// queries it; nothing may panic.
fn fuzzOne(input: []const u8) void {
    const coords = [_]i16{ 8192, -16384, 16384, 0 };
    var sc: [64]f32 = undefined;
    if (ivs.ItemVariationStore.init(input)) |s| {
        if (s.region_count <= sc.len) s.regionScalars(&coords, &sc);
        for (0..4) |o| for (0..4) |i| {
            _ = s.delta(@intCast(o), @intCast(i), &coords);
            if (s.region_count <= sc.len) _ = s.deltaScaled(@intCast(o), @intCast(i), sc[0..s.region_count]);
        };
    } else |_| {}
    if (ivs.DeltaSetIndexMap.init(input)) |m| {
        for (0..4) |i| _ = m.get(@intCast(i));
    } else |_| {}
    if (fvar.Fvar.init(input)) |f| {
        var out: [fvar.max_axes]i16 = undefined;
        fvar.normalize(&f, null, &.{.{ .tag = tag("wght"), .value = 700 }}, &out);
        var it = f.namedInstances();
        while (it.next()) |ni| for (0..f.axis_count) |i| {
            _ = ni.coord(i);
        };
    } else |_| {}
    if (avar.Avar.init(input)) |a| {
        for (0..4) |ax| for (coords) |c| {
            _ = a.map(ax, c);
        };
    } else |_| {}
    if (Mvar.init(input)) |m| {
        if (m.store) |s| if (s.region_count <= sc.len) {
            s.regionScalars(&coords, &sc);
            _ = m.delta(tag("xhgt"), sc[0..s.region_count]);
        };
    } else |_| {}
    if (@import("hvar.zig").Hvar.init(input)) |h| {
        if (h.store.region_count <= sc.len) {
            h.store.regionScalars(&coords, &sc);
            for (0..4) |g| {
                _ = h.advanceDelta(@intCast(g), sc[0..h.store.region_count]);
                _ = h.lsbDelta(@intCast(g), sc[0..h.store.region_count]);
            }
        }
    } else |_| {}
}
