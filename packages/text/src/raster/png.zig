//! A PNG decoder for bitmap-strike glyphs (sbix, CBDT), on std's zlib
//! inflate. It handles every colour type and bit depth, Adam7 interlacing,
//! PLTE and tRNS, checks every chunk CRC, and returns premultiplied sRGB
//! RGBA8. Ancillary chunks other than tRNS are skipped; gamma, colour
//! profiles and text are ignored, as emoji renderers do.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// A decoded image: `w * h * 4` bytes of premultiplied sRGB RGBA8 (straight
/// with `Options.premultiply = false`), rows top to bottom, no padding.
pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8,

    /// Frees the pixels.
    pub fn deinit(img: *Image, gpa: Allocator) void {
        gpa.free(img.rgba);
        img.* = undefined;
    }
};

/// Decode failures.
pub const Error = error{ Malformed, Unsupported, TooLarge, OutOfMemory };

/// The default pixel limit, 4096×4096.
pub const default_max_pixels: u32 = 4096 * 4096;

const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

const Header = struct {
    w: u32,
    h: u32,
    depth: u8,
    color: u8,
    interlace: bool,

    fn channels(h: Header) u8 {
        return switch (h.color) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => unreachable,
        };
    }

    /// Bytes in one filtered row of `pw` pixels (without the filter byte).
    fn rowBytes(h: Header, pw: u32) usize {
        return (@as(usize, pw) * h.channels() * h.depth + 7) / 8;
    }

    /// The filter's "bytes per complete pixel", at least 1.
    fn filterBpp(h: Header) usize {
        return @max(1, @as(usize, h.channels()) * h.depth / 8);
    }
};

const Pass = struct { xs: u32, ys: u32, dx: u32, dy: u32 };
const adam7 = [7]Pass{
    .{ .xs = 0, .ys = 0, .dx = 8, .dy = 8 }, .{ .xs = 4, .ys = 0, .dx = 8, .dy = 8 },
    .{ .xs = 0, .ys = 4, .dx = 4, .dy = 8 }, .{ .xs = 2, .ys = 0, .dx = 4, .dy = 4 },
    .{ .xs = 0, .ys = 2, .dx = 2, .dy = 4 }, .{ .xs = 1, .ys = 0, .dx = 2, .dy = 2 },
    .{ .xs = 0, .ys = 1, .dx = 1, .dy = 2 },
};
const no_interlace = [1]Pass{.{ .xs = 0, .ys = 0, .dx = 1, .dy = 1 }};

fn passSize(p: Pass, w: u32, h: u32) [2]u32 {
    const pw = if (w > p.xs) (w - p.xs + p.dx - 1) / p.dx else 0;
    const ph = if (h > p.ys) (h - p.ys + p.dy - 1) / p.dy else 0;
    return .{ pw, ph };
}

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

/// Decodes `bytes`. Images with more than `max_pixels` pixels return
/// `TooLarge` before anything big is allocated.
pub fn decode(gpa: Allocator, bytes: []const u8, max_pixels: u32) Error!Image {
    return decodeOpts(gpa, bytes, max_pixels, .{});
}

/// Decoding options.
pub const Options = struct {
    /// False keeps straight alpha (for resamplers that linearize first).
    premultiply: bool = true,
};

/// `decode` with options.
pub fn decodeOpts(gpa: Allocator, bytes: []const u8, max_pixels: u32, opts: Options) Error!Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.Malformed;
    var hdr: ?Header = null;
    var palette: [256][4]u8 = undefined;
    var n_palette: usize = 0;
    var trns_key: ?[3]u16 = null; // gray in [0], or RGB
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var pos: usize = 8;
    var seen_idat = false;
    var idat_done = false;
    var ended = false;
    while (!ended) {
        if (bytes.len - pos < 12) return error.Malformed;
        const len = be32(bytes[pos..]);
        if (len > bytes.len - pos - 12) return error.Malformed;
        const ctype = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];
        const crc = be32(bytes[pos + 8 + len ..]);
        if (std.hash.Crc32.hash(bytes[pos + 4 .. pos + 8 + len]) != crc) return error.Malformed;
        pos += 12 + len;
        const is = struct {
            fn f(t: *const [4]u8, comptime name: []const u8) bool {
                return std.mem.eql(u8, t, name);
            }
        }.f;
        if (hdr == null and !is(ctype, "IHDR")) return error.Malformed;
        if (seen_idat and !is(ctype, "IDAT")) idat_done = true;
        if (is(ctype, "IHDR")) {
            if (hdr != null or len != 13) return error.Malformed;
            const h: Header = .{ .w = be32(data[0..]), .h = be32(data[4..]), .depth = data[8], .color = data[9], .interlace = data[12] == 1 };
            if (h.w == 0 or h.h == 0 or h.w > 1 << 31 or h.h > 1 << 31) return error.Malformed;
            if (data[10] != 0 or data[11] != 0 or data[12] > 1) return error.Malformed;
            const ok = switch (h.color) {
                0 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8 or h.depth == 16,
                3 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8,
                2, 4, 6 => h.depth == 8 or h.depth == 16,
                else => false,
            };
            if (!ok) return error.Malformed;
            if (@as(u64, h.w) * h.h > max_pixels) return error.TooLarge;
            hdr = h;
        } else if (is(ctype, "PLTE")) {
            if (len % 3 != 0 or len == 0 or len / 3 > 256 or seen_idat) return error.Malformed;
            n_palette = len / 3;
            for (0..n_palette) |k| palette[k] = .{ data[3 * k], data[3 * k + 1], data[3 * k + 2], 255 };
        } else if (is(ctype, "tRNS")) {
            const h = hdr.?;
            switch (h.color) {
                0 => {
                    if (len < 2) return error.Malformed;
                    trns_key = .{ std.mem.readInt(u16, data[0..2], .big), 0, 0 };
                },
                2 => {
                    if (len < 6) return error.Malformed;
                    trns_key = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
                },
                3 => {
                    if (len > n_palette) return error.Malformed;
                    for (data, 0..) |a, k| palette[k][3] = a;
                },
                else => {}, // not allowed with an alpha channel; ignored
            }
        } else if (is(ctype, "IDAT")) {
            if (idat_done) return error.Malformed; // IDATs must be consecutive
            seen_idat = true;
            try idat.appendSlice(gpa, data);
        } else if (is(ctype, "IEND")) {
            ended = true;
        } else if (ctype[0] & 0x20 == 0) {
            return error.Unsupported; // unknown critical chunk
        }
    }
    const h = hdr orelse return error.Malformed;
    if (!seen_idat) return error.Malformed;
    if (h.color == 3 and n_palette == 0) return error.Malformed;

    const passes: []const Pass = if (h.interlace) &adam7 else &no_interlace;
    var raw_len: usize = 0;
    for (passes) |p| {
        const s = passSize(p, h.w, h.h);
        if (s[0] != 0 and s[1] != 0) raw_len += s[1] * (1 + h.rowBytes(s[0]));
    }
    // Deflate expands at most ~1032:1, so a stream too short for the image
    // fails here instead of after a large allocation.
    if (raw_len / 1032 > idat.items.len + 64) return error.Malformed;
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var in: std.Io.Reader = .fixed(idat.items);
        var dec: flate.Decompress = .init(&in, .zlib, window);
        dec.reader.readSliceAll(raw) catch return error.Malformed;
    }

    const rgba = try gpa.alloc(u8, @as(usize, h.w) * h.h * 4);
    errdefer gpa.free(rgba);
    var off: usize = 0;
    for (passes) |p| {
        const s = passSize(p, h.w, h.h);
        if (s[0] == 0 or s[1] == 0) continue;
        const rb = h.rowBytes(s[0]);
        var prev: ?[]const u8 = null;
        for (0..s[1]) |j| {
            const ft = raw[off];
            const row = raw[off + 1 ..][0..rb];
            off += 1 + rb;
            try unfilter(ft, row, prev, h.filterBpp());
            prev = row;
            const y = p.ys + @as(u32, @intCast(j)) * p.dy;
            for (0..s[0]) |i| {
                const x = p.xs + @as(u32, @intCast(i)) * p.dx;
                const px = try pixel(h, row, i, palette[0..n_palette], trns_key);
                const a: u32 = px[3];
                const dst = rgba[(@as(usize, y) * h.w + x) * 4 ..][0..4];
                if (opts.premultiply) {
                    inline for (0..3) |c| dst[c] = @intCast((@as(u32, px[c]) * a + 127) / 255);
                    dst[3] = px[3];
                } else dst.* = px;
            }
        }
    }
    return .{ .w = h.w, .h = h.h, .rgba = rgba };
}

fn unfilter(ft: u8, row: []u8, prev: ?[]const u8, bpp: usize) Error!void {
    switch (ft) {
        0 => {},
        1 => for (bpp..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        2 => if (prev) |p| for (row, p) |*c, b| {
            c.* +%= b;
        },
        3 => for (row, 0..) |*c, i| {
            const a: u16 = if (i >= bpp) row[i - bpp] else 0;
            const b: u16 = if (prev) |p| p[i] else 0;
            c.* +%= @intCast((a + b) / 2);
        },
        4 => for (row, 0..) |*c, i| {
            const a: i16 = if (i >= bpp) row[i - bpp] else 0;
            const b: i16 = if (prev) |p| p[i] else 0;
            const cc: i16 = if (i >= bpp) (if (prev) |p| p[i - bpp] else 0) else 0;
            c.* +%= paeth(a, b, cc);
        },
        else => return error.Malformed,
    }
}

/// The Paeth predictor (PNG §9.4).
fn paeth(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return @intCast(a);
    if (pb <= pc) return @intCast(b);
    return @intCast(c);
}

/// Sample `k` of a row at bit depth `d` (1, 2, 4, 8 or 16).
fn sample(row: []const u8, k: usize, d: u8) u16 {
    return switch (d) {
        16 => std.mem.readInt(u16, row[2 * k ..][0..2], .big),
        8 => row[k],
        else => blk: {
            const bit = k * d;
            const shift: u3 = @intCast(8 - d - bit % 8);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(d)) - 1);
            break :blk (row[bit / 8] >> shift) & mask;
        },
    };
}

/// Pixel `i` of an unfiltered row as straight (not premultiplied) RGBA8.
fn pixel(h: Header, row: []const u8, i: usize, palette: []const [4]u8, key: ?[3]u16) Error![4]u8 {
    const d = h.depth;
    const to8 = struct {
        fn f(v: u16, depth: u8) u8 {
            return switch (depth) {
                16 => @intCast(v >> 8),
                8 => @intCast(v),
                else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
            };
        }
    }.f;
    switch (h.color) {
        0 => {
            const g = sample(row, i, d);
            const a: u8 = if (key != null and key.?[0] == g) 0 else 255;
            const v = to8(g, d);
            return .{ v, v, v, a };
        },
        2 => {
            const r = sample(row, 3 * i, d);
            const g = sample(row, 3 * i + 1, d);
            const b = sample(row, 3 * i + 2, d);
            const a: u8 = if (key != null and key.?[0] == r and key.?[1] == g and key.?[2] == b) 0 else 255;
            return .{ to8(r, d), to8(g, d), to8(b, d), a };
        },
        3 => {
            const idx = sample(row, i, d);
            if (idx >= palette.len) return error.Malformed;
            return palette[idx];
        },
        4 => {
            const v = to8(sample(row, 2 * i, d), d);
            return .{ v, v, v, to8(sample(row, 2 * i + 1, d), d) };
        },
        6 => return .{ to8(sample(row, 4 * i, d), d), to8(sample(row, 4 * i + 1, d), d), to8(sample(row, 4 * i + 2, d), d), to8(sample(row, 4 * i + 3, d), d) },
        else => unreachable,
    }
}
