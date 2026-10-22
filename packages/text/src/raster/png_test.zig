//! PNG decoder tests. A minimal encoder here (stored deflate blocks, every
//! filter type, Adam7) builds conformance images for each colour type and
//! bit depth from known samples, so the expected pixels never come from the
//! decoder under test.

const std = @import("std");
const testing = std.testing;
const png = @import("png.zig");

const Spec = struct {
    w: u32,
    h: u32,
    depth: u8,
    color: u8,
    interlace: bool = false,
    /// Filter type for row k is filters[k % len].
    filters: []const u8 = &.{ 0, 1, 2, 3, 4 },
    palette: []const [3]u8 = &.{},
    trns: []const u8 = &.{},
    /// Split IDAT into chunks of this many bytes (0 = one chunk).
    idat_split: usize = 0,
};

fn channels(color: u8) usize {
    return switch (color) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => unreachable,
    };
}

fn putChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), t: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    const start = out.items.len;
    try out.appendSlice(gpa, t);
    try out.appendSlice(gpa, data);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(gpa, &crc);
}

/// zlib stream of stored blocks.
fn zlibStored(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x78, 0x01 });
    var i: usize = 0;
    while (true) {
        const n = @min(raw.len - i, 65535);
        const final = i + n == raw.len;
        try out.append(gpa, if (final) 1 else 0);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u16, hdr[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, hdr[2..4], ~@as(u16, @intCast(n)), .little);
        try out.appendSlice(gpa, &hdr);
        try out.appendSlice(gpa, raw[i..][0..n]);
        i += n;
        if (final) break;
    }
    var ad: [4]u8 = undefined;
    std.mem.writeInt(u32, &ad, std.hash.Adler32.hash(raw), .big);
    try out.appendSlice(gpa, &ad);
    return out.toOwnedSlice(gpa);
}

fn paeth(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return @intCast(a);
    if (pb <= pc) return @intCast(b);
    return @intCast(c);
}

/// Packs samples (one u16 per sample, row-major) at `depth` into bytes.
fn packRow(dst: []u8, samples: []const u16, depth: u8) void {
    @memset(dst, 0);
    for (samples, 0..) |v, k| switch (depth) {
        16 => std.mem.writeInt(u16, dst[2 * k ..][0..2], v, .big),
        8 => dst[k] = @intCast(v),
        else => {
            const bit = k * depth;
            const shift: u3 = @intCast(8 - depth - bit % 8);
            dst[bit / 8] |= @as(u8, @intCast(v)) << shift;
        },
    };
}

/// Encodes `samples` (w*h*channels values) as a PNG.
fn encode(gpa: std.mem.Allocator, s: Spec, samples: []const u16) ![]u8 {
    const ch = channels(s.color);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    const Pass = struct { xs: u32, ys: u32, dx: u32, dy: u32 };
    const passes: []const Pass = if (s.interlace) &.{
        .{ .xs = 0, .ys = 0, .dx = 8, .dy = 8 }, .{ .xs = 4, .ys = 0, .dx = 8, .dy = 8 },
        .{ .xs = 0, .ys = 4, .dx = 4, .dy = 8 }, .{ .xs = 2, .ys = 0, .dx = 4, .dy = 4 },
        .{ .xs = 0, .ys = 2, .dx = 2, .dy = 4 }, .{ .xs = 1, .ys = 0, .dx = 2, .dy = 2 },
        .{ .xs = 0, .ys = 1, .dx = 1, .dy = 2 },
    } else &.{.{ .xs = 0, .ys = 0, .dx = 1, .dy = 1 }};
    const bpp = @max(1, ch * s.depth / 8);
    var row_k: usize = 0;
    for (passes) |p| {
        if (s.w <= p.xs or s.h <= p.ys) continue;
        const pw = (s.w - p.xs + p.dx - 1) / p.dx;
        const ph = (s.h - p.ys + p.dy - 1) / p.dy;
        const rb = (pw * ch * s.depth + 7) / 8;
        const prev = try gpa.alloc(u8, rb);
        defer gpa.free(prev);
        @memset(prev, 0);
        const cur = try gpa.alloc(u8, rb);
        defer gpa.free(cur);
        const smp = try gpa.alloc(u16, pw * ch);
        defer gpa.free(smp);
        for (0..ph) |j| {
            const y = p.ys + j * p.dy;
            for (0..pw) |i| {
                const x = p.xs + i * p.dx;
                @memcpy(smp[i * ch ..][0..ch], samples[(y * s.w + x) * ch ..][0..ch]);
            }
            packRow(cur, smp, s.depth);
            const ft = s.filters[row_k % s.filters.len];
            row_k += 1;
            try raw.append(gpa, ft);
            for (0..rb) |i| {
                const a: i16 = if (i >= bpp) cur[i - bpp] else 0;
                const b: i16 = if (j > 0) prev[i] else 0;
                const c: i16 = if (i >= bpp and j > 0) prev[i - bpp] else 0;
                const pred: u8 = switch (ft) {
                    0 => 0,
                    1 => @intCast(a),
                    2 => @intCast(b),
                    3 => @intCast(@divFloor(a + b, 2)),
                    4 => paeth(a, b, c),
                    else => unreachable,
                };
                try raw.append(gpa, cur[i] -% pred);
            }
            @memcpy(prev, cur);
        }
    }
    const z = try zlibStored(gpa, raw.items);
    defer gpa.free(z);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], s.w, .big);
    std.mem.writeInt(u32, ihdr[4..8], s.h, .big);
    ihdr[8] = s.depth;
    ihdr[9] = s.color;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = @intFromBool(s.interlace);
    try putChunk(gpa, &out, "IHDR", &ihdr);
    try putChunk(gpa, &out, "tEXt", "Comment\x00ignored");
    if (s.palette.len > 0) {
        var pl: std.ArrayList(u8) = .empty;
        defer pl.deinit(gpa);
        for (s.palette) |c| try pl.appendSlice(gpa, &c);
        try putChunk(gpa, &out, "PLTE", pl.items);
    }
    if (s.trns.len > 0) try putChunk(gpa, &out, "tRNS", s.trns);
    if (s.idat_split == 0) {
        try putChunk(gpa, &out, "IDAT", z);
    } else {
        var i: usize = 0;
        while (i < z.len) : (i += s.idat_split) try putChunk(gpa, &out, "IDAT", z[i..@min(z.len, i + s.idat_split)]);
    }
    try putChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

/// Expected straight RGBA8 for sample set `smp` of one pixel.
fn expectRgba(s: Spec, smp: []const u16) [4]u8 {
    const d = s.depth;
    const to8 = struct {
        fn f(v: u16, depth: u8) u8 {
            return switch (depth) {
                16 => @intCast(v >> 8),
                8 => @intCast(v),
                1 => if (v == 1) 255 else 0,
                2 => @intCast(v * 85),
                4 => @intCast(v * 17),
                else => unreachable,
            };
        }
    }.f;
    const key0: ?u16 = if (s.trns.len >= 2 and s.color != 3) std.mem.readInt(u16, s.trns[0..2], .big) else null;
    return switch (s.color) {
        0 => .{ to8(smp[0], d), to8(smp[0], d), to8(smp[0], d), if (key0 == smp[0]) 0 else 255 },
        2 => blk: {
            const t = s.trns.len == 6 and key0 == smp[0] and std.mem.readInt(u16, s.trns[2..4], .big) == smp[1] and std.mem.readInt(u16, s.trns[4..6], .big) == smp[2];
            break :blk .{ to8(smp[0], d), to8(smp[1], d), to8(smp[2], d), if (t) 0 else 255 };
        },
        3 => blk: {
            const c = s.palette[smp[0]];
            break :blk .{ c[0], c[1], c[2], if (smp[0] < s.trns.len) s.trns[smp[0]] else 255 };
        },
        4 => .{ to8(smp[0], d), to8(smp[0], d), to8(smp[0], d), to8(smp[1], d) },
        6 => .{ to8(smp[0], d), to8(smp[1], d), to8(smp[2], d), to8(smp[3], d) },
        else => unreachable,
    };
}

fn roundTrip(s: Spec, seed: u64) !void {
    const gpa = testing.allocator;
    const ch = channels(s.color);
    const smp = try gpa.alloc(u16, s.w * s.h * ch);
    defer gpa.free(smp);
    var rng: std.Random.DefaultPrng = .init(seed);
    const max: u32 = if (s.color == 3) @intCast(s.palette.len - 1) else (@as(u32, 1) << @intCast(s.depth)) - 1;
    for (smp) |*v| v.* = @intCast(rng.random().uintAtMost(u32, max));
    // Make transparent-key pixels occur.
    if (s.trns.len >= 2 and s.color != 3) {
        const k0 = std.mem.readInt(u16, s.trns[0..2], .big);
        for (0..ch) |c| smp[c] = if (c == 0) k0 else std.mem.readInt(u16, s.trns[2 * c ..][0..2], .big);
    }
    const bytes = try encode(gpa, s, smp);
    defer gpa.free(bytes);
    var img = try png.decode(gpa, bytes, png.default_max_pixels);
    defer img.deinit(gpa);
    try testing.expectEqual(s.w, img.w);
    try testing.expectEqual(s.h, img.h);
    for (0..s.w * s.h) |i| {
        const e = expectRgba(s, smp[i * ch ..][0..ch]);
        const a: u32 = e[3];
        const want = [4]u8{
            @intCast((@as(u32, e[0]) * a + 127) / 255),
            @intCast((@as(u32, e[1]) * a + 127) / 255),
            @intCast((@as(u32, e[2]) * a + 127) / 255),
            e[3],
        };
        try testing.expectEqualSlices(u8, &want, img.rgba[i * 4 ..][0..4]);
    }
}

const pal = blk: {
    var p: [200][3]u8 = undefined;
    for (&p, 0..) |*c, i| c.* = .{ @intCast(i), @intCast(255 - i), @intCast((i * 7) % 256) };
    break :blk p;
};

test "every colour type and bit depth, plain and Adam7" {
    const cases = [_]struct { color: u8, depths: []const u8 }{
        .{ .color = 0, .depths = &.{ 1, 2, 4, 8, 16 } },
        .{ .color = 2, .depths = &.{ 8, 16 } },
        .{ .color = 3, .depths = &.{ 1, 2, 4, 8 } },
        .{ .color = 4, .depths = &.{ 8, 16 } },
        .{ .color = 6, .depths = &.{ 8, 16 } },
    };
    var seed: u64 = 1;
    for (cases) |c| for (c.depths) |d| for ([_]bool{ false, true }) |il| for ([_][2]u32{ .{ 1, 1 }, .{ 13, 7 }, .{ 33, 17 } }) |wh| {
        const npal: usize = if (c.color == 3) @min(pal.len, @as(usize, 1) << @intCast(d)) else 0;
        try roundTrip(.{ .w = wh[0], .h = wh[1], .depth = d, .color = c.color, .interlace = il, .palette = pal[0..npal] }, seed);
        seed += 1;
    };
}

test "each filter type alone" {
    for (0..5) |f| {
        const ft = [1]u8{@intCast(f)};
        try roundTrip(.{ .w = 21, .h = 9, .depth = 8, .color = 6, .filters = &ft }, f);
        try roundTrip(.{ .w = 21, .h = 9, .depth = 16, .color = 2, .filters = &ft }, f + 10);
        try roundTrip(.{ .w = 21, .h = 9, .depth = 2, .color = 0, .filters = &ft, .interlace = true }, f + 20);
    }
}

test "tRNS for gray, rgb and palette" {
    try roundTrip(.{ .w = 9, .h = 5, .depth = 4, .color = 0, .trns = &.{ 0, 7 } }, 1);
    try roundTrip(.{ .w = 9, .h = 5, .depth = 16, .color = 0, .trns = &.{ 0x12, 0x34 } }, 2);
    try roundTrip(.{ .w = 9, .h = 5, .depth = 8, .color = 2, .trns = &.{ 0, 10, 0, 20, 0, 30 } }, 3);
    try roundTrip(.{ .w = 9, .h = 5, .depth = 8, .color = 3, .palette = pal[0..16], .trns = &.{ 0, 128, 255, 7 } }, 4);
}

test "split IDAT chunks" {
    try roundTrip(.{ .w = 40, .h = 30, .depth = 8, .color = 6, .idat_split = 37 }, 9);
}

test "crc mismatch -> Malformed" {
    const gpa = testing.allocator;
    const smp = [_]u16{ 1, 2, 3, 4 };
    const bytes = try encode(gpa, .{ .w = 1, .h = 1, .depth = 8, .color = 6 }, &smp);
    defer gpa.free(bytes);
    bytes[8 + 4 + 4 + 1] ^= 1; // a byte of the IHDR width
    try testing.expectError(error.Malformed, png.decode(gpa, bytes, png.default_max_pixels));
}

test "truncated idat -> Malformed" {
    const gpa = testing.allocator;
    var smp: [64 * 64 * 4]u16 = undefined;
    for (&smp, 0..) |*v, i| v.* = @intCast(i % 251);
    const s: Spec = .{ .w = 64, .h = 64, .depth = 8, .color = 6 };
    const bytes = try encode(gpa, s, &smp);
    defer gpa.free(bytes);
    // Rebuild with the IDAT payload cut short (valid CRC, short stream).
    const idat_at = std.mem.indexOf(u8, bytes, "IDAT").? - 4;
    const len = std.mem.readInt(u32, bytes[idat_at..][0..4], .big);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, bytes[0..idat_at]);
    try putChunk(gpa, &out, "IDAT", bytes[idat_at + 8 ..][0 .. len / 2]);
    try putChunk(gpa, &out, "IEND", "");
    try testing.expectError(error.Malformed, png.decode(gpa, out.items, png.default_max_pixels));
    // And every prefix of the file fails cleanly.
    for (0..bytes.len) |n| {
        if (png.decode(gpa, bytes[0..n], png.default_max_pixels)) |img| {
            var m = img;
            m.deinit(gpa);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "limits and invalid headers" {
    const gpa = testing.allocator;
    const smp = [_]u16{0} ** (8 * 8);
    const bytes = try encode(gpa, .{ .w = 8, .h = 8, .depth = 8, .color = 0 }, &smp);
    defer gpa.free(bytes);
    try testing.expectError(error.TooLarge, png.decode(gpa, bytes, 63));
    var ok = try png.decode(gpa, bytes, 64);
    ok.deinit(gpa);
    try testing.expectError(error.Malformed, png.decode(gpa, "not a png at all", 64));
}

test "fuzz: png" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            if (png.decode(testing.allocator, input, 1 << 16)) |img| {
                var m = img;
                try testing.expectEqual(@as(usize, m.w) * m.h * 4, m.rgba.len);
                m.deinit(testing.allocator);
            } else |_| {}
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "png") });
}
