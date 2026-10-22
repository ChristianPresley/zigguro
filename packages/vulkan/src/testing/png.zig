//! A small PNG codec: 8-bit gray, RGB and RGBA, non-interlaced. Enough for
//! golden images and simple assets. Encoding is deterministic (no time or
//! text chunks). Decoding treats input as untrusted: CRCs are checked,
//! sizes are bounded and every malformed file is an error, never a panic.

const std = @import("std");
const CpuImage = @import("CpuImage.zig");

const flate = std.compress.flate;
const Crc32 = std.hash.Crc32;
const Adler32 = std.hash.Adler32;

/// The 8-byte PNG signature.
pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
/// Largest accepted width or height.
pub const max_dimension = 16384;
/// Largest accepted pixel count.
pub const max_pixels = 64 * 1024 * 1024;

/// Encoder options.
pub const Options = struct {
    /// Write stored (uncompressed) deflate blocks: fast, large, still valid.
    store_only: bool = false,
    /// Deflate effort when compressing.
    level: flate.Compress.Options = .level_4,
};

/// Errors from `decodePng`.
pub const DecodeError = error{
    /// Missing signature or chunk structure.
    NotPng,
    /// A chunk's CRC does not match.
    BadCrc,
    /// IHDR is missing, repeated or invalid.
    BadHeader,
    /// A feature this decoder does not handle (interlace, 16-bit, palette).
    Unsupported,
    /// Larger than `max_dimension` or `max_pixels`.
    TooLarge,
    /// The compressed stream or a filter byte is invalid.
    BadData,
    /// Allocation failed.
    OutOfMemory,
};

/// Encodes `img` as an RGBA PNG to `w`.
pub fn encodePng(gpa: std.mem.Allocator, img: *const CpuImage, w: *std.Io.Writer) !void {
    return encodePngOpts(gpa, img, w, .{});
}

/// `encodePng` with options.
pub fn encodePngOpts(gpa: std.mem.Allocator, img: *const CpuImage, w: *std.Io.Writer, opts: Options) !void {
    const row_len = @as(usize, img.width) * 4;
    const raw = try gpa.alloc(u8, (row_len + 1) * img.height);
    defer gpa.free(raw);
    try filterRows(gpa, img, raw);

    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, raw.len / 2 + 64);
    defer z.deinit();
    if (opts.store_only) {
        try storeZlib(raw, &z.writer);
    } else {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        const c = try gpa.create(flate.Compress);
        defer gpa.destroy(c);
        c.* = try flate.Compress.init(&z.writer, window, .zlib, opts.level);
        try c.writer.writeAll(raw);
        try c.finish();
    }

    try w.writeAll(&signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", z.written());
    try writeChunk(w, "IEND", "");
}

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// zlib stream of stored blocks (no compression).
fn storeZlib(raw: []const u8, w: *std.Io.Writer) !void {
    try w.writeAll(&.{ 0x78, 0x01 });
    var rest = raw;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 65535));
        const final = n == rest.len;
        try w.writeByte(@intFromBool(final));
        try w.writeInt(u16, n, .little);
        try w.writeInt(u16, ~n, .little);
        try w.writeAll(rest[0..n]);
        rest = rest[n..];
        if (final) break;
    }
    try w.writeInt(u32, Adler32.hash(raw), .big);
}

/// Writes each row of `img` as RGBA bytes preceded by the filter type that
/// minimises the sum of absolute (signed) residuals.
fn filterRows(gpa: std.mem.Allocator, img: *const CpuImage, raw: []u8) !void {
    const row_len = @as(usize, img.width) * 4;
    const buf = try gpa.alloc(u8, row_len * 3);
    defer gpa.free(buf);
    var prev = buf[0..row_len];
    var cur = buf[row_len .. 2 * row_len];
    const trial = buf[2 * row_len ..];
    @memset(prev, 0);
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        const src = img.pixels[@as(usize, y) * img.stride ..][0..row_len];
        switch (img.order) {
            .rgba => @memcpy(cur, src),
            .bgra => {
                var i: usize = 0;
                while (i < row_len) : (i += 4) cur[i..][0..4].* = .{ src[i + 2], src[i + 1], src[i], src[i + 3] };
            },
        }
        const out = raw[y * (row_len + 1) ..][0 .. row_len + 1];
        var best: u8 = 0;
        var best_cost: u64 = std.math.maxInt(u64);
        for (0..5) |f| {
            applyFilter(@intCast(f), cur, prev, trial);
            var cost: u64 = 0;
            for (trial) |b| cost += @abs(@as(i8, @bitCast(b)));
            if (cost < best_cost) {
                best_cost = cost;
                best = @intCast(f);
            }
        }
        out[0] = best;
        applyFilter(best, cur, prev, out[1..]);
        std.mem.swap([]u8, &prev, &cur);
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn applyFilter(f: u8, cur: []const u8, prev: []const u8, out: []u8) void {
    for (cur, 0..) |x, i| {
        const a: u8 = if (i >= 4) cur[i - 4] else 0;
        const b = prev[i];
        const c: u8 = if (i >= 4) prev[i - 4] else 0;
        out[i] = switch (f) {
            0 => x,
            1 => x -% a,
            2 => x -% b,
            3 => x -% @as(u8, @intCast((@as(u16, a) + b) / 2)),
            else => x -% paeth(a, b, c),
        };
    }
}

/// Decodes an 8-bit gray, RGB or RGBA PNG into an RGBA `CpuImage`.
pub fn decodePng(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!CpuImage {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.NotPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: u32 = 0;
    var seen_header = false;
    var seen_end = false;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (pos < bytes.len) {
        if (bytes.len - pos < 12) return error.NotPng;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (len > bytes.len - pos - 12) return error.NotPng;
        const kind = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];
        const want = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        var crc = Crc32.init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != want) return error.BadCrc;
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (seen_header or len != 13) return error.BadHeader;
            seen_header = true;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (width == 0 or height == 0) return error.BadHeader;
            if (width > max_dimension or height > max_dimension) return error.TooLarge;
            if (@as(u64, width) * height > max_pixels) return error.TooLarge;
            if (data[8] != 8) return error.Unsupported;
            channels = switch (data[9]) {
                0 => 1,
                2 => 3,
                6 => 4,
                else => return error.Unsupported,
            };
            if (data[10] != 0 or data[11] != 0) return error.BadHeader;
            if (data[12] != 0) return error.Unsupported;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (!seen_header) return error.BadHeader;
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            seen_end = true;
            break;
        } else if (kind[0] & 0x20 == 0) {
            // Unknown critical chunk (e.g. PLTE).
            return error.Unsupported;
        }
    }
    if (!seen_header or !seen_end) return error.NotPng;

    const row_len = @as(usize, width) * channels;
    const raw = try gpa.alloc(u8, (row_len + 1) * height);
    defer gpa.free(raw);
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var in: std.Io.Reader = .fixed(idat.items);
        var d = flate.Decompress.init(&in, .zlib, window);
        d.reader.readSliceAll(raw) catch return error.BadData;
    }

    var img = try CpuImage.init(gpa, width, height);
    errdefer img.deinit(gpa);
    const bpp = channels;
    var prev: []const u8 = &.{};
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const line = raw[y * (row_len + 1) ..][0 .. row_len + 1];
        const f = line[0];
        const cur = line[1..];
        if (f > 4) return error.BadData;
        for (cur, 0..) |*x, i| {
            const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
            const b: u8 = if (prev.len > 0) prev[i] else 0;
            const c: u8 = if (prev.len > 0 and i >= bpp) prev[i - bpp] else 0;
            x.* = switch (f) {
                0 => x.*,
                1 => x.* +% a,
                2 => x.* +% b,
                3 => x.* +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                else => x.* +% paeth(a, b, c),
            };
        }
        prev = cur;
        var xi: u32 = 0;
        while (xi < width) : (xi += 1) {
            const p = cur[xi * channels ..][0..channels];
            img.set(xi, y, switch (channels) {
                1 => .{ p[0], p[0], p[0], 255 },
                3 => .{ p[0], p[1], p[2], 255 },
                else => .{ p[0], p[1], p[2], p[3] },
            });
        }
    }
    return img;
}

const testing = std.testing;

fn randomImage(gpa: std.mem.Allocator, rnd: std.Random, w: u32, h: u32) !CpuImage {
    var img = try CpuImage.init(gpa, w, h);
    // Mix smooth and noisy rows so every filter wins somewhere.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const v: [4]u8 = switch (y % 4) {
                0 => .{ @truncate(x * 3), @truncate(y * 5), @truncate(x + y), 255 },
                1 => .{ rnd.int(u8), rnd.int(u8), rnd.int(u8), rnd.int(u8) },
                2 => .{ @truncate(x), @truncate(x), @truncate(x), @truncate(200 + x) },
                else => .{ 10, 20, 30, 40 },
            };
            img.set(x, y, v);
        }
    }
    return img;
}

fn encodeToSlice(gpa: std.mem.Allocator, img: *const CpuImage, opts: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try encodePngOpts(gpa, img, &out.writer, opts);
    return out.toOwnedSlice();
}

test "png: encode→decode roundtrip random images" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    for ([_][2]u32{ .{ 1, 1 }, .{ 3, 7 }, .{ 64, 33 }, .{ 300, 20 } }) |sz| {
        for ([_]bool{ false, true }) |store| {
            var img = try randomImage(gpa, prng.random(), sz[0], sz[1]);
            defer img.deinit(gpa);
            const bytes = try encodeToSlice(gpa, &img, .{ .store_only = store });
            defer gpa.free(bytes);
            var back = try decodePng(gpa, bytes);
            defer back.deinit(gpa);
            try testing.expectEqual(img.width, back.width);
            try testing.expectEqualSlices(u8, img.pixels, back.pixels);
        }
    }
}

test "png: bgra images are written as rgba" {
    const gpa = testing.allocator;
    var img = try CpuImage.initOrder(gpa, 2, 1, .bgra);
    defer img.deinit(gpa);
    img.set(0, 0, .{ 1, 2, 3, 4 });
    const bytes = try encodeToSlice(gpa, &img, .{});
    defer gpa.free(bytes);
    var back = try decodePng(gpa, bytes);
    defer back.deinit(gpa);
    try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, back.get(0, 0));
}

test "png: decode reference files" {
    const gpa = testing.allocator;
    const Ref = struct { name: []const u8, w: u32, h: u32, px00: [4]u8, last: [4]u8 };
    // See testdata/png/README.md for how each file was made.
    const refs = [_]Ref{
        .{ .name = "gray_3x2.png", .w = 3, .h = 2, .px00 = .{ 0, 0, 0, 255 }, .last = .{ 250, 250, 250, 255 } },
        .{ .name = "rgb_4x4_filters.png", .w = 4, .h = 4, .px00 = .{ 10, 20, 30, 255 }, .last = .{ 160, 170, 180, 255 } },
        .{ .name = "rgba_5x3_paeth.png", .w = 5, .h = 3, .px00 = .{ 255, 0, 0, 255 }, .last = .{ 40, 80, 120, 128 } },
        .{ .name = "rgba_stored_2x2.png", .w = 2, .h = 2, .px00 = .{ 1, 2, 3, 4 }, .last = .{ 13, 14, 15, 16 } },
        .{ .name = "rgba_deflate_16x16.png", .w = 16, .h = 16, .px00 = .{ 0, 0, 0, 255 }, .last = .{ 240, 240, 0, 255 } },
    };
    inline for (refs) |r| {
        const bytes = @embedFile("testdata_png/" ++ r.name);
        var img = try decodePng(gpa, bytes);
        defer img.deinit(gpa);
        try testing.expectEqual(r.w, img.width);
        try testing.expectEqual(r.h, img.height);
        try testing.expectEqual(r.px00, img.get(0, 0));
        try testing.expectEqual(r.last, img.get(r.w - 1, r.h - 1));
    }
}

test "png: crc mismatch rejected" {
    const gpa = testing.allocator;
    var img = try CpuImage.init(gpa, 4, 4);
    defer img.deinit(gpa);
    const bytes = try encodeToSlice(gpa, &img, .{});
    defer gpa.free(bytes);
    bytes[20] ^= 1; // inside IHDR data
    try testing.expectError(error.BadCrc, decodePng(gpa, bytes));
    try testing.expectError(error.NotPng, decodePng(gpa, "GIF89a"));
}

test "png: oversize header rejected before allocation" {
    const gpa = testing.allocator;
    var img = try CpuImage.init(gpa, 1, 1);
    defer img.deinit(gpa);
    const bytes = try encodeToSlice(gpa, &img, .{});
    defer gpa.free(bytes);
    std.mem.writeInt(u32, bytes[16..20], 20000, .big);
    var crc = Crc32.init();
    crc.update(bytes[12..29]);
    std.mem.writeInt(u32, bytes[29..33], crc.final(), .big);
    try testing.expectError(error.TooLarge, decodePng(gpa, bytes));
}

test "fuzz: png decoder never panics" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            if (decodePng(testing.allocator, input)) |img| {
                var m = img;
                m.deinit(testing.allocator);
            } else |_| {}
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "png") });
}
