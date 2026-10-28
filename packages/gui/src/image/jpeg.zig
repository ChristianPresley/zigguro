//! JPEG (ITU-T T.81; E04.F06.S02.T01): baseline and extended sequential
//! (SOF0/SOF1) and progressive (SOF2) Huffman JPEGs with 8-bit samples,
//! sampling factors 1 or 2, restart intervals, EXIF orientation (applied
//! by the façade) and Adobe colour transforms. Arithmetic coding and
//! lossless or hierarchical modes are `Unsupported`.
//!
//! A sequential file whose one scan holds every component (the usual
//! camera JPEG) streams: MCU rows decode in chunks into a two-slot
//! coefficient ring, and helper threads run each chunk's IDCT and colour
//! conversion while the next chunk decodes. Other files decode every
//! scan into whole-image coefficients, then run the IDCT and colour
//! conversion in bands on several threads. Small images use no threads.
//!
//! The inverse DCT is libjpeg's accurate integer transform on
//! `@Vector(8, i32)` lanes, and colour conversion is fixed point, so the
//! output is the same on every target. `scale` 2, 4 or 8 decodes at 1/2,
//! 1/4 or 1/8 size with a reduced IDCT (strict float mode, also the same
//! everywhere) over the top-left coefficients.
//! Chroma is upsampled with the triangle ("fancy") filter.

const std = @import("std");
const builtin = @import("builtin");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;
const Image = image.Image;
const Limits = image.Limits;
const DecodeError = image.DecodeError;

/// Natural index of the k-th coefficient in zigzag order.
const dezigzag = [64 + 16]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    // Past the end (corrupt runs) land on 63 instead of out of bounds.
    63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
};

const fast_bits = 10;

const Huffman = struct {
    /// Fast lookup by the next `fast_bits` bits: symbol index + 1 (0: slow).
    fast: [1 << fast_bits]u16 = @splat(0),
    /// For AC tables: a whole run/size code and its magnitude bits within
    /// the next `fast_bits` bits, as `value << 8 | run << 4 | bits used`
    /// (0: decode the slow way). Values outside -128..127 are left out.
    fast_ac: [1 << fast_bits]i16 = @splat(0),
    /// Code length of each symbol index.
    size: [256]u8 = @splat(0),
    values: [256]u8 = @splat(0),
    /// Per length: largest code + 1 (left-aligned to 16 bits), and the
    /// delta from code to symbol index.
    maxcode: [18]u32 = @splat(0),
    delta: [17]i32 = @splat(0),
    defined: bool = false,

    fn build(h: *Huffman, counts: [16]u8, vals: []const u8) DecodeError!void {
        h.* = .{};
        var k: usize = 0;
        for (counts, 0..) |c, i| {
            for (0..c) |_| {
                if (k >= 256) return error.Malformed;
                h.size[k] = @intCast(i + 1);
                k += 1;
            }
        }
        if (k != vals.len) return error.Malformed;
        @memcpy(h.values[0..k], vals);
        var code: u32 = 0;
        var j: usize = 0;
        for (1..17) |len| {
            h.delta[len] = @as(i32, @intCast(j)) - @as(i32, @intCast(code));
            while (j < k and h.size[j] == len) : (j += 1) code += 1;
            if (code > (@as(u32, 1) << @intCast(len))) return error.Malformed;
            h.maxcode[len] = code << @intCast(16 - len);
            code <<= 1;
        }
        h.maxcode[17] = 0xffffffff;
        // Fast table.
        code = 0;
        j = 0;
        for (1..17) |len| {
            while (j < k and h.size[j] == len) : (j += 1) {
                if (len <= fast_bits) {
                    const shift: u4 = @intCast(fast_bits - len);
                    const first = code << shift;
                    const n = @as(u32, 1) << shift;
                    for (0..n) |m| h.fast[first + m] = @intCast(j + 1);
                }
                code += 1;
            }
            code <<= 1;
        }
        for (0..1 << fast_bits) |i| {
            const f = h.fast[i];
            if (f == 0) continue;
            const rs = h.values[f - 1];
            const run: u16 = rs >> 4;
            const mag: u5 = @intCast(rs & 15);
            const len: u5 = @intCast(h.size[f - 1]);
            if (mag == 0 or @as(u32, len) + mag > fast_bits) continue;
            // The magnitude bits follow the code within the lookahead.
            const raw: i32 = @intCast((i << len) & ((1 << fast_bits) - 1));
            var v: i32 = raw >> @intCast(fast_bits - @as(u32, mag));
            if (v < (@as(i32, 1) << @intCast(mag - 1))) v += 1 - (@as(i32, 1) << mag);
            if (v < -128 or v > 127) continue;
            h.fast_ac[i] = @intCast(v * 256 + @as(i32, run) * 16 + len + mag);
        }
        h.defined = true;
    }
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    /// Blocks per line and column, padded to whole MCUs.
    bw: u32 = 0,
    bh: u32 = 0,
    /// Blocks covering the component's own size (non-interleaved scans).
    bw_own: u32 = 0,
    bh_own: u32 = 0,
    coefs: []i16 = &.{},
    dc_pred: i32 = 0,
    td: u8 = 0,
    ta: u8 = 0,
    /// The decoded plane (after IDCT), `pw` × `ph` samples.
    plane: []u8 = &.{},
    pw: u32 = 0,
    ph: u32 = 0,
};

const Bits = struct {
    data: []const u8,
    pos: usize,
    /// Unread bits, left-aligned; `n` of them are valid.
    acc: u64 = 0,
    n: u7 = 0,
    /// A marker was reached; zeros are fed from here on.
    marker: ?u8 = null,
    /// Zero bytes fed because the data ended (no marker).
    padded: u32 = 0,

    /// Tops the accumulator up to at least 57 bits. Eight bytes without
    /// an 0xFF (no stuffing, no marker) load in one step.
    fn fill(b: *Bits) void {
        if (b.marker == null and b.pos + 8 <= b.data.len) {
            const w = std.mem.readInt(u64, b.data[b.pos..][0..8], .big);
            const inv = ~w;
            const ones: u64 = 0x0101010101010101;
            if ((inv -% ones) & ~inv & (ones << 7) == 0) {
                const take: u7 = (64 - b.n) >> 3;
                b.acc |= (w >> @intCast(64 - @as(u7, take) * 8)) << @intCast(64 - b.n - take * 8);
                b.n += take * 8;
                b.pos += take;
                return;
            }
        }
        while (b.n <= 56) {
            var byte: u64 = 0;
            if (b.marker == null and b.pos >= b.data.len) b.padded += 1;
            if (b.marker == null and b.pos < b.data.len) {
                const c = b.data[b.pos];
                if (c == 0xFF) {
                    const nx: u8 = if (b.pos + 1 < b.data.len) b.data[b.pos + 1] else 0;
                    if (nx == 0) {
                        byte = 0xFF;
                        b.pos += 2;
                    } else {
                        b.marker = nx;
                    }
                } else {
                    byte = c;
                    b.pos += 1;
                }
            }
            b.acc |= byte << @intCast(56 - b.n);
            b.n += 8;
        }
    }

    fn bits(b: *Bits, n: u5) u32 {
        if (n == 0) return 0;
        if (b.n < n) b.fill();
        const v: u32 = @intCast(b.acc >> @intCast(64 - @as(u7, n)));
        b.acc <<= n;
        b.n -= n;
        return v;
    }

    fn bit(b: *Bits) u32 {
        return b.bits(1);
    }

    /// `n` bits as a signed coefficient (T.81 EXTEND).
    fn receiveExtend(b: *Bits, n: u5) i32 {
        if (n == 0) return 0;
        const v: i32 = @intCast(b.bits(n));
        const half = @as(i32, 1) << @intCast(n - 1);
        return if (v < half) v - (@as(i32, 1) << @intCast(n)) + 1 else v;
    }

    fn decode(b: *Bits, h: *const Huffman) DecodeError!u8 {
        if (b.n < 16) b.fill();
        const look: usize = @intCast(b.acc >> (64 - fast_bits));
        const f = h.fast[look];
        if (f != 0) {
            const sz: u6 = @intCast(h.size[f - 1]);
            b.acc <<= sz;
            b.n -= sz;
            return h.values[f - 1];
        }
        const top: u32 = @intCast(b.acc >> 48);
        var len: usize = fast_bits + 1;
        while (len <= 16) : (len += 1) {
            if (top < h.maxcode[len]) break;
        }
        if (len > 16) return error.Malformed;
        const code: i32 = @intCast(top >> @intCast(16 - len));
        const idx = code + h.delta[len];
        if (idx < 0 or idx >= 256 or h.size[@intCast(idx)] != len) return error.Malformed;
        b.acc <<= @intCast(len);
        b.n -= @intCast(len);
        return h.values[@intCast(idx)];
    }

    /// Restarts after an RSTn marker (or tolerates its absence).
    fn restart(b: *Bits) void {
        b.acc = 0;
        b.n = 0;
        if (b.marker) |m| {
            if (m >= 0xD0 and m <= 0xD7) {
                b.pos += 2;
                b.marker = null;
            }
        } else {
            // Skip to the marker.
            while (b.pos + 1 < b.data.len and !(b.data[b.pos] == 0xFF and b.data[b.pos + 1] >= 0xD0 and b.data[b.pos + 1] <= 0xD7)) b.pos += 1;
            if (b.pos + 1 < b.data.len) b.pos += 2;
        }
    }
};

/// A parsed header and the decoder's state.
const Decoder = struct {
    gpa: Allocator,
    data: []const u8,
    limits: Limits,
    qt: [4][64]u16 = @splat(@splat(1)),
    dc: [4]Huffman = @splat(.{}),
    ac: [4]Huffman = @splat(.{}),
    comps: [4]Component = @splat(.{ .id = 0, .h = 1, .v = 1, .tq = 0 }),
    ncomp: u8 = 0,
    w: u32 = 0,
    h: u32 = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcux: u32 = 0,
    mcuy: u32 = 0,
    progressive: bool = false,
    restart_interval: u32 = 0,
    eobrun: u32 = 0,
    adobe: ?u8 = null,
    jfif: bool = false,
    orientation: u8 = 1,
    frame_seen: bool = false,
    /// Output block size: 8 / scale.
    n: u32 = 8,
    /// Whole-image coefficients are allocated (progressive or multi-scan).
    coefs_full: bool = false,
    /// The only scan was decoded and converted as it streamed in.
    streamed: bool = false,
    /// The RGBA output, once allocated.
    out: []u8 = &.{},
    /// Chunks of a streamed scan converted so far (helper threads).
    chunks_done: std.atomic.Value(u32) = .init(0),
    /// Bytes of `out` already touched by the prefault thread; colour
    /// conversion waits for its rows to be covered.
    out_ready: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),

    fn deinit(d: *Decoder) void {
        for (d.comps[0..d.ncomp]) |*c| {
            d.gpa.free(c.coefs);
            d.gpa.free(c.plane);
        }
        d.gpa.free(d.out);
    }

    fn outW(d: *const Decoder) u32 {
        const scale = 8 / d.n;
        return (d.w + scale - 1) / scale;
    }

    fn outH(d: *const Decoder) u32 {
        const scale = 8 / d.n;
        return (d.h + scale - 1) / scale;
    }

    fn transform(d: *const Decoder) Transform {
        return switch (d.ncomp) {
            1 => .gray,
            3 => if (d.adobe) |t| (if (t == 0) .rgb else .ycbcr) else if (d.comps[0].id == 'R' and d.comps[1].id == 'G' and d.comps[2].id == 'B') .rgb else .ycbcr,
            4 => if (d.adobe) |t| (if (t == 2) .ycck else .cmyk) else .cmyk,
            else => unreachable,
        };
    }
};

fn be16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .big);
}

/// What `decodeJpeg` gives besides the pixels.
pub const Info = struct { w: u32, h: u32, components: u8, progressive: bool, orientation: u8 };

/// Reads the frame header and EXIF orientation without decoding.
pub fn info(bytes: []const u8) DecodeError!Info {
    var d: Decoder = .{ .gpa = undefined, .data = bytes, .limits = .{} };
    var pos: usize = 2;
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return error.Malformed;
    while (pos + 4 <= bytes.len) {
        if (bytes[pos] != 0xFF) return error.Malformed;
        const m = bytes[pos + 1];
        if (m == 0xFF) {
            pos += 1;
            continue;
        }
        const len = be16(bytes, pos + 2);
        if (len < 2 or pos + 2 + len > bytes.len) return error.Malformed;
        const seg = bytes[pos + 4 .. pos + 2 + len];
        switch (m) {
            0xE1 => d.orientation = exifOrientation(seg),
            0xC0, 0xC1, 0xC2 => {
                if (seg.len < 6) return error.Malformed;
                return .{ .w = be16(seg, 3), .h = be16(seg, 1), .components = seg[5], .progressive = m == 0xC2, .orientation = d.orientation };
            },
            else => {},
        }
        pos += 2 + len;
    }
    return error.Malformed;
}

/// Decodes at 1/`scale` size (1, 2, 4 or 8), not yet oriented: the
/// façade applies `orientation` (returned through `orient_out`).
pub fn decodeJpeg(gpa: Allocator, bytes: []const u8, limits: Limits, scale: u4, orient_out: ?*u8) DecodeError!Image {
    if (bytes.len > limits.max_bytes) return error.TooLarge;
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return error.Malformed;
    var d: Decoder = .{ .gpa = gpa, .data = bytes, .limits = limits, .n = switch (scale) {
        1 => 8,
        2 => 4,
        4 => 2,
        8 => 1,
        else => return error.Unsupported,
    } };
    defer d.deinit();
    var pos: usize = 2;
    var scans: u32 = 0;
    outer: while (true) {
        // Find the next marker (tolerating fill bytes).
        while (pos < bytes.len and bytes[pos] != 0xFF) pos += 1;
        while (pos < bytes.len and bytes[pos] == 0xFF) pos += 1;
        if (pos >= bytes.len) break;
        const m = bytes[pos];
        pos += 1;
        switch (m) {
            0xD9 => break :outer,
            0xD0...0xD7, 0x01 => continue,
            else => {},
        }
        if (pos + 2 > bytes.len) break;
        const len = be16(bytes, pos);
        if (len < 2 or pos + len > bytes.len) {
            if (scans > 0) break;
            return error.Malformed;
        }
        const seg = bytes[pos + 2 .. pos + len];
        pos += len;
        switch (m) {
            0xC0, 0xC1, 0xC2 => try readFrame(&d, seg, m == 0xC2),
            0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported,
            0xC4 => try readHuffman(&d, seg),
            0xDB => try readQuant(&d, seg),
            0xDD => {
                if (seg.len < 2) return error.Malformed;
                d.restart_interval = be16(seg, 0);
            },
            0xDA => {
                if (!d.frame_seen) return error.Malformed;
                pos = try readScan(&d, seg, pos);
                scans += 1;
            },
            0xE0 => {
                if (seg.len >= 5 and std.mem.eql(u8, seg[0..5], "JFIF\x00")) d.jfif = true;
            },
            0xE1 => {
                const o = exifOrientation(seg);
                if (o != 1) d.orientation = o;
            },
            0xEE => {
                if (seg.len >= 12 and std.mem.eql(u8, seg[0..5], "Adobe")) d.adobe = seg[11];
            },
            else => {},
        }
    }
    if (!d.frame_seen or scans == 0) return error.Malformed;
    if (orient_out) |o| o.* = d.orientation;
    return finish(&d);
}

fn readQuant(d: *Decoder, seg: []const u8) DecodeError!void {
    var i: usize = 0;
    while (i < seg.len) {
        const pq = seg[i] >> 4;
        const tq = seg[i] & 15;
        if (tq > 3) return error.Malformed;
        i += 1;
        const n: usize = if (pq == 0) 64 else 128;
        if (i + n > seg.len) return error.Malformed;
        for (0..64) |k| d.qt[tq][dezigzag[k]] = if (pq == 0) seg[i + k] else be16(seg, i + k * 2);
        i += n;
    }
}

fn readHuffman(d: *Decoder, seg: []const u8) DecodeError!void {
    var i: usize = 0;
    while (i < seg.len) {
        if (i + 17 > seg.len) return error.Malformed;
        const tc = seg[i] >> 4;
        const th = seg[i] & 15;
        if (tc > 1 or th > 3) return error.Malformed;
        var counts: [16]u8 = undefined;
        @memcpy(&counts, seg[i + 1 .. i + 17]);
        var total: usize = 0;
        for (counts) |c| total += c;
        i += 17;
        if (i + total > seg.len or total > 256) return error.Malformed;
        const t = if (tc == 0) &d.dc[th] else &d.ac[th];
        try t.build(counts, seg[i .. i + total]);
        i += total;
    }
}

fn readFrame(d: *Decoder, seg: []const u8, progressive: bool) DecodeError!void {
    if (d.frame_seen) return error.Malformed;
    if (seg.len < 6) return error.Malformed;
    if (seg[0] != 8) return error.Unsupported;
    d.h = be16(seg, 1);
    d.w = be16(seg, 3);
    d.ncomp = seg[5];
    if (d.w == 0 or d.h == 0) return error.Unsupported; // DNL heights
    if (d.ncomp != 1 and d.ncomp != 3 and d.ncomp != 4) return error.Unsupported;
    if (seg.len < 6 + @as(usize, d.ncomp) * 3) return error.Malformed;
    _ = try image.pixelBytes(d.w, d.h, d.limits);
    d.progressive = progressive;
    for (0..d.ncomp) |i| {
        const c = seg[6 + i * 3 ..];
        const hs = c[1] >> 4;
        const vs = c[1] & 15;
        if (hs < 1 or hs > 2 or vs < 1 or vs > 2) return error.Unsupported;
        if (c[2] > 3) return error.Malformed;
        d.comps[i] = .{ .id = c[0], .h = hs, .v = vs, .tq = c[2] };
        d.hmax = @max(d.hmax, hs);
        d.vmax = @max(d.vmax, vs);
    }
    if (d.ncomp == 1) {
        // A single component is never interleaved: its MCU is one block.
        d.comps[0].h = 1;
        d.comps[0].v = 1;
        d.hmax = 1;
        d.vmax = 1;
    }
    d.mcux = (d.w + 8 * @as(u32, d.hmax) - 1) / (8 * @as(u32, d.hmax));
    d.mcuy = (d.h + 8 * @as(u32, d.vmax) - 1) / (8 * @as(u32, d.vmax));
    // Comps' own sizes; the padding of all components' coefficients stays
    // under the image's limit times a small factor.
    for (d.comps[0..d.ncomp]) |*c| {
        c.bw = d.mcux * c.h;
        c.bh = d.mcuy * c.v;
        const cw = (d.w * c.h + d.hmax - 1) / d.hmax;
        const ch = (d.h * c.v + d.vmax - 1) / d.vmax;
        c.bw_own = (cw + 7) / 8;
        c.bh_own = (ch + 7) / 8;
        _ = std.math.mul(usize, @as(usize, c.bw) * c.bh, 64) catch return error.TooLarge;
    }
    d.frame_seen = true;
}

/// Coefficients for the whole image, for scans that refine or add to
/// earlier ones.
fn allocCoefs(d: *Decoder) DecodeError!void {
    if (d.coefs_full) return;
    for (d.comps[0..d.ncomp]) |*c| {
        d.gpa.free(c.coefs);
        c.coefs = &.{};
        c.coefs = try d.gpa.alloc(i16, @as(usize, c.bw) * c.bh * 64);
        @memset(c.coefs, 0);
    }
    d.coefs_full = true;
}

/// Planes at the output block size.
fn allocPlanes(d: *Decoder) DecodeError!void {
    for (d.comps[0..d.ncomp]) |*c| {
        c.pw = c.bw * d.n;
        c.ph = c.bh * d.n;
        c.plane = try d.gpa.alloc(u8, @as(usize, c.pw) * c.ph);
    }
}

/// True when the output is large enough to decode on several threads.
fn threaded(d: *const Decoder) bool {
    if (builtin.single_threaded) return false;
    if (builtin.is_test and test_knobs.threads) return true;
    return @as(u64, d.w) * d.h * d.n * d.n / 64 >= parallel_min_px;
}

/// MCU rows per chunk of a streamed scan.
const default_chunk_mcu_rows = 8;
fn chunkRows() u32 {
    return if (builtin.is_test) test_knobs.chunk_mcu_rows else default_chunk_mcu_rows;
}

/// Lets tests run the threaded paths on small fixtures.
pub const test_knobs = struct {
    pub var threads = false;
    pub var chunk_mcu_rows: u32 = default_chunk_mcu_rows;
};

/// Inverse DCT of MCU rows `my0..my1`, held in ring slot `slot`.
fn idctChunk(d: *const Decoder, slot: usize, my0: u32, my1: u32) void {
    const n = d.n;
    for (d.comps[0..d.ncomp]) |*c| {
        const q = &d.qt[c.tq];
        const ring = c.coefs[slot * chunkRows() * c.v * c.bw * 64 ..];
        const by0 = my0 * c.v;
        for (by0..my1 * c.v) |by| for (0..c.bw) |bx| {
            const coef = ring[((by - by0) * c.bw + bx) * 64 ..][0..64];
            const at = by * n * c.pw + bx * n;
            if (n == 8) idct8(coef, q, c.plane[at..], c.pw) else idctReduced(coef, q, n, c.plane[at..], c.pw);
        };
    }
}

/// Output rows of MCU rows below `my` (all rows once `my` is the last):
/// the triangle filter reads one chroma row into the next MCU row.
fn rowsReady(d: *const Decoder, my: u32) u32 {
    if (my >= d.mcuy) return d.outH();
    return @min(d.outH(), (my -| 1) * d.vmax * d.n);
}

/// A streamed chunk's work: the IDCT of chunk `k`, then (after the
/// previous chunk's work, which it joins) the colour conversion of every
/// output row that has become complete. Chunks thus convert in order,
/// one at a time, into the one shared row scratch.
fn chunkWork(d: *Decoder, k: u32, slot: usize, my0: u32, my1: u32, prev: ?std.Thread, rows: []u8) void {
    idctChunk(d, slot, my0, my1);
    if (prev) |t| t.join();
    const hi = rowsReady(d, my1);
    while (d.out_ready.load(.acquire) < @as(usize, hi) * d.outW() * 4) std.Thread.yield() catch {};
    colorRows(d, d.transform(), rows, rowsReady(d, my0), hi);
    d.chunks_done.store(k + 1, .release);
}

/// Writes every page of the output once, ahead of colour conversion, so
/// its page faults (a large share of the conversion's time) are taken on
/// a spare core while the entropy decoder runs.
fn prefault(d: *Decoder) void {
    const step = 64 << 10;
    var at: usize = 0;
    while (at < d.out.len) {
        const end = @min(at + step, d.out.len);
        var p = at;
        while (p < end) : (p += 4096) d.out[p] = 0;
        d.out_ready.store(end, .release);
        at = end;
    }
}

/// A sequential scan holding every component (so the only one): MCU rows
/// are decoded in chunks into a two-slot ring, and each chunk's IDCT and
/// colour conversion run on a helper thread while the next chunk decodes.
fn streamScan(d: *Decoder, b: *Bits, sc: []const *Component, sp: ScanParams) DecodeError!void {
    for (d.comps[0..d.ncomp]) |*c| {
        d.gpa.free(c.coefs);
        c.coefs = &.{};
        c.coefs = try d.gpa.alloc(i16, 2 * @as(usize, chunkRows()) * c.v * c.bw * 64);
    }
    try allocPlanes(d);
    d.out = try d.gpa.alloc(u8, try image.pixelBytes(d.outW(), d.outH(), d.limits));
    const rows = try d.gpa.alloc(u8, @as(usize, d.outW()) * d.ncomp);
    defer d.gpa.free(rows);
    d.streamed = true;
    const use_threads = threaded(d);
    // The newest helper; each one joins the one before it.
    var last: ?std.Thread = null;
    defer if (last) |t| t.join();
    var faulter: ?std.Thread = null;
    defer if (faulter) |t| t.join();
    if (use_threads) {
        d.out_ready.store(0, .release);
        faulter = std.Thread.spawn(.{}, prefault, .{d}) catch null;
        if (faulter == null) d.out_ready.store(std.math.maxInt(usize), .release);
    }
    var todo: u32 = d.restart_interval;
    var my0: u32 = 0;
    var k: u32 = 0;
    while (my0 < d.mcuy) : (k += 1) {
        const my1 = @min(my0 + chunkRows(), d.mcuy);
        const slot = k % 2;
        // The slot is free once chunk k - 2 is done.
        while (k >= 2 and d.chunks_done.load(.acquire) < k - 1) std.Thread.yield() catch {};
        var my = my0;
        while (my < my1) : (my += 1) {
            var mx: u32 = 0;
            while (mx < d.mcux) : (mx += 1) {
                if (d.restart_interval != 0) {
                    if (todo == 0) {
                        b.restart();
                        for (sc) |c| c.dc_pred = 0;
                        todo = d.restart_interval;
                    }
                    todo -= 1;
                }
                for (sc) |c| {
                    const ring = c.coefs[slot * chunkRows() * c.v * c.bw * 64 ..];
                    for (0..c.v) |v| for (0..c.h) |hh| {
                        const bx = mx * c.h + @as(u32, @intCast(hh));
                        const by = (my - my0) * c.v + @as(u32, @intCast(v));
                        try decodeBlock(d, b, c, ring[(@as(usize, by) * c.bw + bx) * 64 ..][0..64], sp);
                    };
                }
            }
        }
        const t: ?std.Thread = if (use_threads) std.Thread.spawn(.{}, chunkWork, .{ d, k, slot, my0, my1, last, rows }) catch null else null;
        if (t == null) chunkWork(d, k, slot, my0, my1, last, rows);
        last = t;
        my0 = my1;
    }
}

/// Decodes one scan; returns the position after its entropy-coded data.
fn readScan(d: *Decoder, seg: []const u8, data_at: usize) DecodeError!usize {
    if (seg.len < 1) return error.Malformed;
    const ns = seg[0];
    if (ns < 1 or ns > 4 or seg.len < 1 + @as(usize, ns) * 2 + 3) return error.Malformed;
    var sc: [4]*Component = undefined;
    for (0..ns) |i| {
        const cs = seg[1 + i * 2];
        const t = seg[2 + i * 2];
        var found: ?*Component = null;
        for (d.comps[0..d.ncomp]) |*c| if (c.id == cs) {
            found = c;
        };
        const c = found orelse return error.Malformed;
        c.td = t >> 4;
        c.ta = t & 15;
        if (c.td > 3 or c.ta > 3) return error.Malformed;
        sc[i] = c;
    }
    const p = 1 + @as(usize, ns) * 2;
    const ss = seg[p];
    const se = seg[p + 1];
    const ah: u5 = @intCast(seg[p + 2] >> 4);
    const al: u5 = @intCast(@min(seg[p + 2] & 15, 13));
    if (d.progressive) {
        if (ss > se or se > 63 or (ss == 0 and se != 0) or (ss > 0 and ns != 1)) return error.Malformed;
    } else {
        if (ss != 0 or se != 63) {
            // Sequential scans cover all coefficients.
            return error.Malformed;
        }
    }
    for (sc[0..ns]) |c| {
        c.dc_pred = 0;
        if (!d.progressive or ss == 0) {
            if (ah == 0 and !d.dc[c.td].defined) return error.Malformed;
        }
        if ((!d.progressive or ss > 0) and !d.ac[c.ta].defined) return error.Malformed;
    }
    d.eobrun = 0;
    var b: Bits = .{ .data = d.data, .pos = data_at };
    const kind: ScanKind = if (!d.progressive) .sequential else if (ss == 0) (if (ah == 0) .dc_first else .dc_refine) else (if (ah == 0) .ac_first else .ac_refine);
    const sp: ScanParams = .{ .kind = kind, .ss = ss, .se = se, .al = al };

    var todo: u32 = d.restart_interval;
    if (d.streamed) {
        // Nothing can follow a scan of every component; skip its data.
    } else if (!d.progressive and ns == d.ncomp and !d.coefs_full) {
        try streamScan(d, &b, sc[0..ns], sp);
    } else if (ns == 1) {
        try allocCoefs(d);
        const c = sc[0];
        var by: u32 = 0;
        while (by < c.bh_own) : (by += 1) {
            var bx: u32 = 0;
            while (bx < c.bw_own) : (bx += 1) {
                if (d.restart_interval != 0) {
                    if (todo == 0) {
                        b.restart();
                        c.dc_pred = 0;
                        d.eobrun = 0;
                        todo = d.restart_interval;
                    }
                    todo -= 1;
                }
                try decodeBlock(d, &b, c, c.coefs[(@as(usize, by) * c.bw + bx) * 64 ..][0..64], sp);
            }
        }
    } else {
        try allocCoefs(d);
        var my: u32 = 0;
        while (my < d.mcuy) : (my += 1) {
            var mx: u32 = 0;
            while (mx < d.mcux) : (mx += 1) {
                if (d.restart_interval != 0) {
                    if (todo == 0) {
                        b.restart();
                        for (sc[0..ns]) |c| c.dc_pred = 0;
                        d.eobrun = 0;
                        todo = d.restart_interval;
                    }
                    todo -= 1;
                }
                for (sc[0..ns]) |c| {
                    for (0..c.v) |v| for (0..c.h) |hh| {
                        const bx = mx * c.h + @as(u32, @intCast(hh));
                        const by = my * c.v + @as(u32, @intCast(v));
                        try decodeBlock(d, &b, c, c.coefs[(@as(usize, by) * c.bw + bx) * 64 ..][0..64], sp);
                    };
                }
            }
        }
    }
    // Bits past the end of the file were used: the file is cut short.
    if (@as(u64, b.padded) * 8 > b.n) return error.Malformed;
    // Continue after the scan's data: at the marker that ended it.
    var end = b.pos;
    while (end + 1 < d.data.len and !(d.data[end] == 0xFF and d.data[end + 1] != 0 and !(d.data[end + 1] >= 0xD0 and d.data[end + 1] <= 0xD7))) end += 1;
    return end;
}

const ScanKind = enum { sequential, dc_first, dc_refine, ac_first, ac_refine };
const ScanParams = struct { kind: ScanKind, ss: u8, se: u8, al: u5 };

fn decodeBlock(d: *Decoder, b: *Bits, c: *Component, blk: *[64]i16, sp: ScanParams) DecodeError!void {
    switch (sp.kind) {
        .sequential => {
            blk.* = @splat(0);
            const t = try b.decode(&d.dc[c.td]);
            if (t > 16) return error.Malformed;
            c.dc_pred += b.receiveExtend(@intCast(t));
            blk[0] = @truncate(c.dc_pred);
            var k: usize = 1;
            const ac = &d.ac[c.ta];
            while (k < 64) {
                if (b.n < 16) b.fill();
                const fac = ac.fast_ac[@intCast(b.acc >> (64 - fast_bits))];
                if (fac != 0) {
                    const used: u6 = @intCast(fac & 15);
                    b.acc <<= used;
                    b.n -= used;
                    k += @intCast((fac >> 4) & 15);
                    if (k > 63) return error.Malformed;
                    blk[dezigzag[k]] = fac >> 8;
                    k += 1;
                    continue;
                }
                const rs = try b.decode(ac);
                const r = rs >> 4;
                const s: u5 = @intCast(rs & 15);
                if (s == 0) {
                    if (r != 15) break;
                    k += 16;
                    continue;
                }
                k += r;
                if (k > 63) return error.Malformed;
                blk[dezigzag[k]] = @truncate(b.receiveExtend(s));
                k += 1;
            }
        },
        .dc_first => {
            const t = try b.decode(&d.dc[c.td]);
            if (t > 16) return error.Malformed;
            c.dc_pred += b.receiveExtend(@intCast(t));
            blk[0] = @truncate(c.dc_pred * (@as(i32, 1) << sp.al));
        },
        .dc_refine => {
            if (b.bit() != 0) blk[0] |= @as(i16, 1) << @intCast(sp.al);
        },
        .ac_first => {
            if (d.eobrun > 0) {
                d.eobrun -= 1;
                return;
            }
            var k: usize = sp.ss;
            const ac = &d.ac[c.ta];
            while (k <= sp.se) {
                const rs = try b.decode(ac);
                const r: u5 = @intCast(rs >> 4);
                const s: u5 = @intCast(rs & 15);
                if (s == 0) {
                    if (r < 15) {
                        d.eobrun = (@as(u32, 1) << r) - 1;
                        if (r > 0) d.eobrun += b.bits(r);
                        break;
                    }
                    k += 16;
                    continue;
                }
                k += r;
                if (k > 63) return error.Malformed;
                blk[dezigzag[k]] = @truncate(b.receiveExtend(s) * (@as(i32, 1) << sp.al));
                k += 1;
            }
        },
        .ac_refine => {
            const p1: i16 = @as(i16, 1) << @intCast(sp.al);
            const m1: i16 = -p1;
            if (d.eobrun > 0) {
                d.eobrun -= 1;
                refineNonZero(b, blk, sp.ss, sp.se, p1);
                return;
            }
            var k: usize = sp.ss;
            const ac = &d.ac[c.ta];
            while (k <= sp.se) {
                const rs = try b.decode(ac);
                var r: u32 = rs >> 4;
                const s: u5 = @intCast(rs & 15);
                var val: i16 = 0;
                if (s == 0) {
                    if (r < 15) {
                        d.eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                        if (r > 0) d.eobrun += b.bits(@intCast(r));
                        r = 64;
                    }
                } else {
                    if (s != 1) return error.Malformed;
                    val = if (b.bit() != 0) p1 else m1;
                }
                while (k <= sp.se) {
                    const z = &blk[dezigzag[k]];
                    k += 1;
                    if (z.* != 0) {
                        if (b.bit() != 0 and (z.* & p1) == 0) {
                            z.* = if (z.* >= 0) z.* + p1 else z.* + m1;
                        }
                    } else {
                        if (r == 0) {
                            z.* = val;
                            break;
                        }
                        r -= 1;
                    }
                }
            }
        },
    }
}

fn refineNonZero(b: *Bits, blk: *[64]i16, ss: u8, se: u8, p1: i16) void {
    var k: usize = ss;
    while (k <= se) : (k += 1) {
        const z = &blk[dezigzag[k]];
        if (z.* != 0 and b.bit() != 0 and (z.* & p1) == 0) {
            z.* = if (z.* >= 0) z.* + p1 else z.* - p1;
        }
    }
}

// -- IDCT ---------------------------------------------------------------------

const I8 = @Vector(8, i32);

fn splat8(v: i32) I8 {
    return @splat(v);
}

/// One 8-point pass of libjpeg's accurate integer IDCT (jidctint.c,
/// 13-bit constants) over eight lanes at once; outputs are not descaled.
/// Arithmetic wraps so corrupt coefficients cannot trap.
inline fn idct1d(x: [8]I8) [8]I8 {
    var z2 = x[2];
    var z3 = x[6];
    var z1 = (z2 +% z3) *% splat8(4433);
    const t2 = z1 +% z3 *% splat8(-15137);
    const t3 = z1 +% z2 *% splat8(6270);
    const t0 = (x[0] +% x[4]) << @splat(13);
    const t1 = (x[0] -% x[4]) << @splat(13);
    const t10 = t0 +% t3;
    const t13 = t0 -% t3;
    const t11 = t1 +% t2;
    const t12 = t1 -% t2;
    var o0 = x[7];
    var o1 = x[5];
    var o2 = x[3];
    var o3 = x[1];
    z1 = o0 +% o3;
    z2 = o1 +% o2;
    z3 = o0 +% o2;
    var z4 = o1 +% o3;
    const z5 = (z3 +% z4) *% splat8(9633);
    o0 *%= splat8(2446);
    o1 *%= splat8(16819);
    o2 *%= splat8(25172);
    o3 *%= splat8(12299);
    z1 *%= splat8(-7373);
    z2 *%= splat8(-20995);
    z3 = z3 *% splat8(-16069) +% z5;
    z4 = z4 *% splat8(-3196) +% z5;
    o0 +%= z1 +% z3;
    o1 +%= z2 +% z4;
    o2 +%= z2 +% z3;
    o3 +%= z1 +% z4;
    return .{ t10 +% o3, t11 +% o2, t12 +% o1, t13 +% o0, t13 -% o0, t12 -% o1, t11 -% o2, t10 -% o3 };
}

fn transpose8(m: [8]I8) [8]I8 {
    var a: [8][8]i32 = undefined;
    for (0..8) |i| a[i] = m[i];
    var t: [8]I8 = undefined;
    for (0..8) |i| {
        var r: [8]i32 = undefined;
        for (0..8) |j| r[j] = a[j][i];
        t[i] = r;
    }
    return t;
}

/// Inverse DCT of a dequantized block into 8×8 samples at `out` (stride
/// `stride`), level-shifted and clamped. Integer only, so the output is
/// the same on every target.
fn idct8(coef: *const [64]i16, q: *const [64]u16, out: []u8, stride: usize) void {
    // A flat block (only DC) is one value; smooth images have many.
    var ac: @Vector(64, i16) = coef.*;
    ac[0] = 0;
    if (!@reduce(.Or, ac != @as(@Vector(64, i16), @splat(0)))) {
        const dc = @as(i32, coef[0]) *% q[0];
        const v: u8 = @intCast(std.math.clamp((dc +% 4) >> 3, -128, 127) + 128);
        for (0..8) |y| @memset(out[y * stride ..][0..8], v);
        return;
    }
    // Columns (lanes are columns), descaled by CONST_BITS - PASS1_BITS.
    var x: [8]I8 = undefined;
    for (0..8) |r| {
        const cv: @Vector(8, i16) = coef[r * 8 ..][0..8].*;
        const qv: @Vector(8, u16) = q[r * 8 ..][0..8].*;
        x[r] = @as(I8, cv) *% @as(I8, qv);
    }
    var ws = idct1d(x);
    for (&ws) |*w| w.* = (w.* +% splat8(1 << 10)) >> @splat(11);
    // Rows (lanes are rows after the transpose), descaled by
    // CONST_BITS + PASS1_BITS + 3 with the +128 level shift folded in.
    const px = idct1d(transpose8(ws));
    var cols: [8]I8 = undefined;
    for (0..8) |k| {
        const v = (px[k] +% splat8((1 << 17) + (128 << 18))) >> @splat(18);
        cols[k] = @min(@max(v, splat8(0)), splat8(255));
    }
    const rows = transpose8(cols);
    for (0..8) |y| {
        const b: @Vector(8, u8) = @intCast(rows[y]);
        out[y * stride ..][0..8].* = b;
    }
}

/// An `n`-point reduced inverse DCT (n = 1, 2 or 4) from the top-left
/// n×n coefficients: 1/(8/n) scaled output.
fn idctReduced(coef: *const [64]i16, q: *const [64]u16, n: usize, out: []u8, stride: usize) void {
    @setFloatMode(.strict);
    var f: [4][4]f32 = undefined;
    for (0..n) |v| for (0..n) |u| {
        f[v][u] = @floatFromInt(@as(i32, coef[v * 8 + u]) * q[v * 8 + u]);
    };
    var kk: [4][4]f32 = undefined;
    for (0..n) |u| for (0..n) |x| {
        const cu: f32 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
        kk[u][x] = cu / 2.0 * @cos(@as(f32, @floatFromInt((2 * x + 1) * u)) * std.math.pi / @as(f32, @floatFromInt(2 * n)));
    };
    for (0..n) |y| for (0..n) |x| {
        var s: f32 = 128.5;
        for (0..n) |v| for (0..n) |u| {
            s += kk[v][y] * kk[u][x] * f[v][u];
        };
        out[y * stride + x] = @intFromFloat(@floor(std.math.clamp(s, 0, 255)));
    };
}

// -- output -------------------------------------------------------------------

/// Images from this many output pixels up run the IDCT and colour
/// conversion on several threads.
const parallel_min_px = 1 << 20;
const max_threads = 8;

/// Runs `f(ctx, band, lo, hi)` over `0..total` split into `bands` bands,
/// one per thread (the caller's thread takes band 0). A band whose
/// thread fails to start runs on the caller's thread.
fn forBands(total: usize, bands: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize, usize, usize) void) void {
    if (bands <= 1) return f(ctx, 0, 0, total);
    var threads: [max_threads]?std.Thread = @splat(null);
    for (1..bands) |i| threads[i] = std.Thread.spawn(.{}, f, .{ ctx, i, total * i / bands, total * (i + 1) / bands }) catch null;
    f(ctx, 0, 0, total / bands);
    for (1..bands) |i| {
        if (threads[i]) |t| t.join() else f(ctx, i, total * i / bands, total * (i + 1) / bands);
    }
}

const Transform = enum { gray, ycbcr, rgb, cmyk, ycck };

const OutCtx = struct {
    d: *const Decoder,
    /// Per band: one upsampled row per component.
    rows: []u8,
};

/// IDCT of block rows `lo..hi`, counted over all components in order.
fn idctBand(cx: *const OutCtx, band: usize, lo: usize, hi: usize) void {
    _ = band;
    const d = cx.d;
    const n = d.n;
    var first: usize = 0;
    for (d.comps[0..d.ncomp]) |*c| {
        const end = first + c.bh;
        const a = @max(lo, first);
        const b = @min(hi, end);
        if (a < b) {
            const q = &d.qt[c.tq];
            for (a - first..b - first) |by| for (0..c.bw) |bx| {
                const coef = c.coefs[(by * c.bw + bx) * 64 ..][0..64];
                const at = by * n * c.pw + bx * n;
                if (n == 8) idct8(coef, q, c.plane[at..], c.pw) else idctReduced(coef, q, n, c.plane[at..], c.pw);
            };
        }
        first = end;
    }
}

fn colorBand(cx: *const OutCtx, band: usize, lo: usize, hi: usize) void {
    const d = cx.d;
    colorRows(d, d.transform(), cx.rows[band * @as(usize, d.outW()) * d.ncomp ..], lo, hi);
}

/// Colour conversion of output rows `lo..hi` into `d.out`; `rows` holds
/// one upsampled row per component.
fn colorRows(d: *const Decoder, transform: Transform, rows: []u8, lo: usize, hi: usize) void {
    const ow = d.outW();
    var src: [4][]const u8 = undefined;
    for (lo..hi) |y| {
        for (d.comps[0..d.ncomp], 0..) |*c, i| src[i] = upsampleRow(d, c, @intCast(y), ow, rows[i * ow ..][0..ow]);
        convertRow(transform, src[0..d.ncomp], d.out[y * ow * 4 ..][0 .. ow * 4]);
    }
}

fn finish(d: *Decoder) DecodeError!Image {
    const ow = d.outW();
    const oh = d.outH();
    if (!d.streamed) {
        const out_len = try image.pixelBytes(ow, oh, d.limits);
        try allocPlanes(d);
        var block_rows: usize = 0;
        for (d.comps[0..d.ncomp]) |*c| block_rows += c.bh;
        d.out = try d.gpa.alloc(u8, out_len);
        // At least 64 rows a band (any number in tests that force threads).
        const band_rows: u32 = if (builtin.is_test and test_knobs.threads) 1 else 64;
        const bands: usize = if (!threaded(d))
            1
        else
            @max(1, @min(max_threads, std.Thread.getCpuCount() catch 1, oh / band_rows));
        const rows = try d.gpa.alloc(u8, bands * @as(usize, ow) * d.ncomp);
        defer d.gpa.free(rows);
        const cx: OutCtx = .{ .d = d, .rows = rows };
        forBands(block_rows, bands, &cx, idctBand);
        forBands(oh, bands, &cx, colorBand);
    }
    const out = d.out;
    d.out = &.{};
    return .{ .w = ow, .h = oh, .rgba = out, .format = .jpeg };
}

/// One output row from per-component rows of `ow` samples.
fn convertRow(transform: Transform, src: []const []const u8, dst: []u8) void {
    const ow = dst.len / 4;
    var x: usize = 0;
    switch (transform) {
        .ycbcr => {
            const L = 16;
            const V = @Vector(L, i32);
            while (x + L <= ow) : (x += L) {
                const yv: V = @as(@Vector(L, u8), src[0][x..][0..L].*);
                const b = @as(V, @as(@Vector(L, u8), src[1][x..][0..L].*)) - @as(V, @splat(128));
                const r = @as(V, @as(@Vector(L, u8), src[2][x..][0..L].*)) - @as(V, @splat(128));
                const Y = (yv << @splat(16)) + @as(V, @splat(1 << 15));
                const lo: V = @splat(0);
                const hi: V = @splat(255);
                const R: @Vector(L, u32) = @intCast(@min(@max((Y + @as(V, @splat(91881)) * r) >> @splat(16), lo), hi));
                const G: @Vector(L, u32) = @intCast(@min(@max((Y - @as(V, @splat(22554)) * b - @as(V, @splat(46802)) * r) >> @splat(16), lo), hi));
                const B: @Vector(L, u32) = @intCast(@min(@max((Y + @as(V, @splat(116130)) * b) >> @splat(16), lo), hi));
                storeRgba(dst[x * 4 ..][0 .. L * 4], R, G, B);
            }
            while (x < ow) : (x += 1) {
                const rgb = ycc(src[0][x], src[1][x], src[2][x]);
                dst[x * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], 255 };
            }
        },
        .gray => {
            const L = 16;
            while (x + L <= ow) : (x += L) {
                const g: @Vector(L, u32) = @as(@Vector(L, u8), src[0][x..][0..L].*);
                storeRgba(dst[x * 4 ..][0 .. L * 4], g, g, g);
            }
            while (x < ow) : (x += 1) dst[x * 4 ..][0..4].* = .{ src[0][x], src[0][x], src[0][x], 255 };
        },
        .rgb => while (x < ow) : (x += 1) {
            dst[x * 4 ..][0..4].* = .{ src[0][x], src[1][x], src[2][x], 255 };
        },
        .cmyk, .ycck => while (x < ow) : (x += 1) {
            var cmy: [3]u8 = .{ src[0][x], src[1][x], src[2][x] };
            if (transform == .ycck) {
                const rgb = ycc(cmy[0], cmy[1], cmy[2]);
                cmy = .{ 255 - rgb[0], 255 - rgb[1], 255 - rgb[2] };
            }
            // Adobe stores CMYK inverted: R = C·K / 255.
            const k: u32 = src[3][x];
            dst[x * 4 ..][0..4].* = .{ @intCast((@as(u32, cmy[0]) * k + 127) / 255), @intCast((@as(u32, cmy[1]) * k + 127) / 255), @intCast((@as(u32, cmy[2]) * k + 127) / 255), 255 };
        },
    }
}

/// Packs channels into RGBA bytes with alpha 255.
fn storeRgba(dst: []u8, r: anytype, g: @TypeOf(r), b: @TypeOf(r)) void {
    const L = @typeInfo(@TypeOf(r)).vector.len;
    var px = r | (g << @splat(8)) | (b << @splat(16)) | @as(@TypeOf(r), @splat(0xFF000000));
    if (builtin.cpu.arch.endian() == .big) px = @byteSwap(px);
    dst[0 .. L * 4].* = @bitCast(px);
}

/// JFIF YCbCr to RGB in 16.16 fixed point.
fn ycc(y: u8, cb: u8, cr: u8) [3]u8 {
    const Y: i32 = @as(i32, y) << 16;
    const b: i32 = @as(i32, cb) - 128;
    const r: i32 = @as(i32, cr) - 128;
    const half: i32 = 1 << 15;
    const R = (Y + 91881 * r + half) >> 16;
    const G = (Y - 22554 * b - 46802 * r + half) >> 16;
    const B = (Y + 116130 * b + half) >> 16;
    return .{ clamp8(R), clamp8(G), clamp8(B) };
}

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Row `y` of the output for component `c`, `ow` samples upsampled
/// with the triangle filter when the component is subsampled by 2. The
/// result is `out` or, at full resolution, the plane row itself.
fn upsampleRow(d: *const Decoder, c: *const Component, y: u32, ow: u32, out: []u8) []const u8 {
    const fx: u32 = d.hmax / c.h;
    const fy: u32 = d.vmax / c.v;
    // The rows above and below to blend (the nearer one weighs 3/4).
    const sy = y / fy;
    const sy2: u32 = if (fy == 1) sy else if (y % 2 == 0) (if (sy > 0) sy - 1 else sy) else @min(sy + 1, c.ph - 1);
    const r0 = c.plane[@as(usize, @min(sy, c.ph - 1)) * c.pw ..][0..c.pw];
    if (fx == 1 and fy == 1) return r0[0..ow];
    const r1 = c.plane[@as(usize, @min(sy2, c.ph - 1)) * c.pw ..][0..c.pw];
    if (fx == 1) {
        // Vertical only: (3·near + far + 2) / 4.
        for (out[0..ow], r0[0..ow], r1[0..ow]) |*o, a, b| o.* = @intCast((3 * @as(u16, a) + b + 2) >> 2);
        return out[0..ow];
    }
    // Horizontal (and vertical): per source column s, a = 3·near + far
    // (4·near without vertical subsampling); output 2s blends a with its
    // left neighbour, 2s + 1 with its right one: (3·a + a' + 8) / 16.
    const half = (ow + 1) / 2;
    const col = struct {
        fn at(p: []const u8, q: []const u8, s: usize, vert: bool) u16 {
            return if (vert) 3 * @as(u16, p[s]) + q[s] else 4 * @as(u16, p[s]);
        }
    }.at;
    const vert = fy != 1;
    var s: usize = 0;
    const L = 16;
    const V = @Vector(L, u16);
    while (s < half) {
        if (s > 0 and s + L + 1 <= c.pw and s + L <= half and 2 * (s + L) <= ow) {
            const p0: V = @as(@Vector(L, u8), r0[s - 1 ..][0..L].*);
            const c0: V = @as(@Vector(L, u8), r0[s..][0..L].*);
            const n0: V = @as(@Vector(L, u8), r0[s + 1 ..][0..L].*);
            var pa: V = undefined;
            var ca: V = undefined;
            var na: V = undefined;
            if (vert) {
                const three: V = @splat(3);
                pa = three * p0 + @as(V, @as(@Vector(L, u8), r1[s - 1 ..][0..L].*));
                ca = three * c0 + @as(V, @as(@Vector(L, u8), r1[s..][0..L].*));
                na = three * n0 + @as(V, @as(@Vector(L, u8), r1[s + 1 ..][0..L].*));
            } else {
                const four: V = @splat(4);
                pa = four * p0;
                ca = four * c0;
                na = four * n0;
            }
            const three: V = @splat(3);
            const eight: V = @splat(8);
            const even: @Vector(L, u8) = @intCast((three * ca + pa + eight) >> @splat(4));
            const odd: @Vector(L, u8) = @intCast((three * ca + na + eight) >> @splat(4));
            const mask = comptime blk: {
                var m: [2 * L]i32 = undefined;
                for (0..L) |i| {
                    m[2 * i] = i;
                    m[2 * i + 1] = ~@as(i32, i);
                }
                break :blk m;
            };
            out[2 * s ..][0 .. 2 * L].* = @shuffle(u8, even, odd, mask);
            s += L;
            continue;
        }
        const a = col(r0, r1, s, vert);
        const left = col(r0, r1, if (s > 0) s - 1 else s, vert);
        out[2 * s] = @intCast((3 * a + left + 8) >> 4);
        if (2 * s + 1 < ow) {
            const right = col(r0, r1, @min(s + 1, c.pw - 1), vert);
            out[2 * s + 1] = @intCast((3 * a + right + 8) >> 4);
        }
        s += 1;
    }
    return out[0..ow];
}

// -- EXIF ---------------------------------------------------------------------

/// The orientation tag (1–8) of an APP1 Exif segment, else 1.
pub fn exifOrientation(seg: []const u8) u8 {
    if (seg.len < 14 or !std.mem.eql(u8, seg[0..6], "Exif\x00\x00")) return 1;
    const t = seg[6..];
    const endian: std.builtin.Endian = if (t[0] == 'I' and t[1] == 'I') .little else if (t[0] == 'M' and t[1] == 'M') .big else return 1;
    if (std.mem.readInt(u16, t[2..4], endian) != 42) return 1;
    const ifd = std.mem.readInt(u32, t[4..8], endian);
    if (ifd > t.len or t.len - ifd < 2) return 1;
    const n = std.mem.readInt(u16, t[ifd..][0..2], endian);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = ifd + 2 + i * 12;
        if (e + 12 > t.len) return 1;
        if (std.mem.readInt(u16, t[e..][0..2], endian) == 0x0112) {
            const v = std.mem.readInt(u16, t[e + 8 ..][0..2], endian);
            return if (v >= 1 and v <= 8) @intCast(v) else 1;
        }
    }
    return 1;
}

/// `img` turned upright for EXIF orientation `o` (a new image for 2–8).
pub fn orient(gpa: Allocator, img: Image, o: u8) DecodeError!Image {
    if (o <= 1 or o > 8) return img;
    const swap = o >= 5;
    const w = if (swap) img.h else img.w;
    const h = if (swap) img.w else img.h;
    const out = try gpa.alloc(u8, img.rgba.len);
    const sw = img.w;
    const sh = img.h;
    for (0..h) |y| for (0..w) |x| {
        const s: [2]usize = switch (o) {
            2 => .{ sw - 1 - x, y },
            3 => .{ sw - 1 - x, sh - 1 - y },
            4 => .{ x, sh - 1 - y },
            5 => .{ y, x },
            6 => .{ y, sh - 1 - x },
            7 => .{ sw - 1 - y, sh - 1 - x },
            8 => .{ sw - 1 - y, x },
            else => unreachable,
        };
        out[(y * w + x) * 4 ..][0..4].* = img.rgba[(s[1] * sw + s[0]) * 4 ..][0..4].*;
    };
    var old = img;
    old.deinit(gpa);
    return .{ .w = @intCast(w), .h = @intCast(h), .rgba = out, .format = .jpeg };
}

test "huffman tables reject over-full code lengths" {
    var h: Huffman = .{};
    var counts: [16]u8 = @splat(0);
    counts[0] = 3; // three 1-bit codes
    try std.testing.expectError(error.Malformed, h.build(counts, &.{ 0, 1, 2 }));
}
