//! A deterministic, photo-like test JPEG for `gui.jpeg_decode_12mp`, made
//! at bench start so no binary fixture is committed: a baseline 4:2:0
//! encoder with the ITU-T T.81 Annex K Huffman tables and libjpeg's
//! quality-90 quantization tables. The picture is smooth gradients, a
//! mid-frequency texture and per-pixel noise, which lands near the bytes
//! per pixel of a camera photo (about 2 bits per pixel at 4000 × 3000).

const std = @import("std");

/// Quality-90 tables in zigzag order (libjpeg scaling of Annex K).
const q_luma = [64]u8{ 3, 2, 2, 3, 2, 2, 3, 3, 3, 3, 4, 3, 3, 4, 5, 8, 5, 5, 4, 4, 5, 10, 7, 7, 6, 8, 12, 10, 12, 12, 11, 10, 11, 11, 13, 14, 18, 16, 13, 14, 17, 14, 11, 11, 16, 22, 16, 17, 19, 20, 21, 21, 21, 12, 15, 23, 24, 22, 20, 24, 18, 20, 21, 20 };
const q_chroma: [64]u8 = [_]u8{ 3, 4, 4, 5, 4, 5, 9, 5, 5, 9, 20, 13, 11, 13, 20 } ++ [_]u8{20} ** 49;

/// Natural index of the k-th coefficient in zigzag order.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

const dc_bits_luma = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const dc_bits_chroma = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const dc_vals = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const ac_bits_luma = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125 };
const ac_bits_chroma = [16]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119 };
/// The Annex K AC symbol orders: these leading symbols, then every other
/// run/size symbol in ascending order.
const ac_head_luma = [_]u8{ 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35 };
const ac_head_chroma = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1 };

fn acVals(comptime head: []const u8) [162]u8 {
    @setEvalBranchQuota(100000);
    var out: [162]u8 = undefined;
    @memcpy(out[0..head.len], head);
    var n = head.len;
    for (0..256) |sym| {
        const s = sym & 15;
        const valid = (s >= 1 and s <= 10) or sym == 0x00 or sym == 0xf0;
        if (!valid or std.mem.indexOfScalar(u8, head, sym) != null) continue;
        out[n] = sym;
        n += 1;
    }
    std.debug.assert(n == 162);
    return out;
}

const ac_vals_luma = acVals(&ac_head_luma);
const ac_vals_chroma = acVals(&ac_head_chroma);

/// Canonical codes per symbol.
const Codes = struct {
    code: [256]u16 = @splat(0),
    size: [256]u8 = @splat(0),

    fn of(bits: [16]u8, vals: []const u8) Codes {
        var c: Codes = .{};
        var code: u16 = 0;
        var k: usize = 0;
        for (bits, 1..) |n, len| {
            for (0..n) |_| {
                c.code[vals[k]] = code;
                c.size[vals[k]] = @intCast(len);
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
        return c;
    }
};

const Writer = struct {
    out: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    acc: u32 = 0,
    n: u5 = 0,

    fn bytes(w: *Writer, b: []const u8) !void {
        try w.out.appendSlice(w.gpa, b);
    }

    fn bits(w: *Writer, v: u32, len: u5) !void {
        var i = len;
        while (i > 0) {
            i -= 1;
            w.acc = (w.acc << 1) | ((v >> i) & 1);
            w.n += 1;
            if (w.n == 8) {
                const byte: u8 = @intCast(w.acc & 0xff);
                try w.out.append(w.gpa, byte);
                if (byte == 0xff) try w.out.append(w.gpa, 0);
                w.acc = 0;
                w.n = 0;
            }
        }
    }

    /// Pads the last byte with ones.
    fn flush(w: *Writer) !void {
        while (w.n != 0) try w.bits(1, 1);
    }

    fn segment(w: *Writer, marker: u8, body: []const u8) !void {
        try w.bytes(&.{ 0xff, marker });
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(body.len + 2), .big);
        try w.bytes(&len);
        try w.bytes(body);
    }
};

/// `cos((2x+1)uπ/16) · C(u) / 2`.
const dct_k: [8][8]f32 = blk: {
    @setEvalBranchQuota(10000);
    var k: [8][8]f32 = undefined;
    for (0..8) |u| for (0..8) |x| {
        const cu: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
        k[u][x] = @floatCast(cu / 2.0 * @cos(@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0));
    };
    break :blk k;
};

/// Forward DCT, quantization and Huffman coding of one 8×8 block of
/// level-shifted samples.
fn block(w: *Writer, px: *const [64]f32, q: *const [64]u8, dc: *const Codes, ac: *const Codes, pred: *i32) !void {
    var tmp: [64]f32 = undefined;
    for (0..8) |y| for (0..8) |u| {
        var s: f32 = 0;
        for (0..8) |x| s += px[y * 8 + x] * dct_k[u][x];
        tmp[y * 8 + u] = s;
    };
    var zz: [64]i32 = undefined;
    for (0..64) |k| {
        const v = zigzag[k] / 8;
        const u = zigzag[k] % 8;
        var s: f32 = 0;
        for (0..8) |y| s += tmp[y * 8 + u] * dct_k[v][y];
        zz[k] = @intFromFloat(@round(s / @as(f32, @floatFromInt(q[k]))));
    }
    const diff = zz[0] - pred.*;
    pred.* = zz[0];
    const dn = magnitude(diff);
    try w.bits(dc.code[dn], @intCast(dc.size[dn]));
    try w.bits(valueBits(diff, dn), dn);
    var run: u32 = 0;
    for (1..64) |k| {
        if (zz[k] == 0) {
            run += 1;
            continue;
        }
        while (run >= 16) : (run -= 16) try w.bits(ac.code[0xf0], @intCast(ac.size[0xf0]));
        const n = magnitude(zz[k]);
        const sym = run << 4 | n;
        try w.bits(ac.code[sym], @intCast(ac.size[sym]));
        try w.bits(valueBits(zz[k], n), n);
        run = 0;
    }
    if (run > 0) try w.bits(ac.code[0], @intCast(ac.size[0]));
}

fn magnitude(v: i32) u5 {
    return @intCast(32 - @clz(@abs(v)));
}

fn valueBits(v: i32, n: u5) u32 {
    if (n == 0) return 0;
    const m = (@as(u32, 1) << n) - 1;
    return if (v < 0) @as(u32, @bitCast(v - 1)) & m else @as(u32, @intCast(v));
}

/// Pixel (x, y) as RGB.
fn sample(x: u32, y: u32, cols: []const [3]f32, rows: []const [3]f32) [3]f32 {
    var h = (@as(u64, x) *% 0x9E3779B97F4A7C15) ^ (@as(u64, y) *% 0xC2B2AE3D27D4EB4F);
    h ^= h >> 29;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= h >> 32;
    const noise: f32 = @as(f32, @floatFromInt(h & 31)) - 15.5;
    const texture = cols[x][2] * rows[y][2];
    var rgb: [3]f32 = undefined;
    for (0..3) |c| {
        const n2: f32 = @as(f32, @floatFromInt((h >> @intCast(8 + c * 5)) & 15)) - 7.5;
        rgb[c] = std.math.clamp(128 + cols[x][c] + rows[y][(c + 1) % 3] + texture + noise + n2, 0, 255);
    }
    return rgb;
}

/// Encodes a `w` × `h` picture; the caller frees the bytes.
pub fn make(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    var wr: Writer = .{ .gpa = gpa };
    errdefer wr.out.deinit(gpa);
    try wr.bytes(&.{ 0xff, 0xd8 });
    try wr.segment(0xe0, "JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00");
    try wr.segment(0xdb, &([_]u8{0} ++ q_luma ++ [_]u8{1} ++ q_chroma));
    var sof: [15]u8 = undefined;
    sof[0] = 8;
    std.mem.writeInt(u16, sof[1..3], @intCast(h), .big);
    std.mem.writeInt(u16, sof[3..5], @intCast(w), .big);
    sof[5..15].* = .{ 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1 };
    try wr.segment(0xc0, &sof);
    try wr.segment(0xc4, &([_]u8{0x00} ++ dc_bits_luma ++ dc_vals ++ [_]u8{0x10} ++ ac_bits_luma ++ ac_vals_luma ++
        [_]u8{0x01} ++ dc_bits_chroma ++ dc_vals ++ [_]u8{0x11} ++ ac_bits_chroma ++ ac_vals_chroma));
    try wr.segment(0xda, &.{ 3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0 });

    const dc_l: Codes = .of(dc_bits_luma, &dc_vals);
    const dc_c: Codes = .of(dc_bits_chroma, &dc_vals);
    const ac_l: Codes = .of(ac_bits_luma, &ac_vals_luma);
    const ac_c: Codes = .of(ac_bits_chroma, &ac_vals_chroma);

    // Separable smooth parts: per column and per row offsets, plus a
    // texture amplitude whose product makes a mid-frequency pattern.
    const cols = try gpa.alloc([3]f32, w);
    defer gpa.free(cols);
    const rows = try gpa.alloc([3]f32, h);
    defer gpa.free(rows);
    for (cols, 0..) |*c, i| {
        const x: f32 = @floatFromInt(i);
        c.* = .{ 60 * @sin(x * 0.0021), 50 * @cos(x * 0.0034), 18 * @sin(x * 0.11) };
    }
    for (rows, 0..) |*r, i| {
        const y: f32 = @floatFromInt(i);
        r.* = .{ 40 * @cos(y * 0.0017), 45 * @sin(y * 0.0029), 1.2 * @cos(y * 0.07) };
    }

    var pred: [3]i32 = .{ 0, 0, 0 };
    var ys: [4][64]f32 = undefined;
    var cb: [64]f32 = undefined;
    var cr: [64]f32 = undefined;
    var my: u32 = 0;
    while (my < (h + 15) / 16) : (my += 1) {
        var mx: u32 = 0;
        while (mx < (w + 15) / 16) : (mx += 1) {
            @memset(&cb, 0);
            @memset(&cr, 0);
            for (0..16) |dy| for (0..16) |dx| {
                const px = @min(mx * 16 + @as(u32, @intCast(dx)), w - 1);
                const py = @min(my * 16 + @as(u32, @intCast(dy)), h - 1);
                const rgb = sample(px, py, cols, rows);
                const yy = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
                ys[(dy / 8) * 2 + dx / 8][(dy % 8) * 8 + dx % 8] = yy - 128;
                const ci = (dy / 2) * 8 + dx / 2;
                cb[ci] += 0.25 * (-0.168736 * rgb[0] - 0.331264 * rgb[1] + 0.5 * rgb[2]);
                cr[ci] += 0.25 * (0.5 * rgb[0] - 0.418688 * rgb[1] - 0.081312 * rgb[2]);
            };
            for (&ys) |*b| try block(&wr, b, &q_luma, &dc_l, &ac_l, &pred[0]);
            try block(&wr, &cb, &q_chroma, &dc_c, &ac_c, &pred[1]);
            try block(&wr, &cr, &q_chroma, &dc_c, &ac_c, &pred[2]);
        }
    }
    try wr.flush();
    try wr.bytes(&.{ 0xff, 0xd9 });
    return wr.out.toOwnedSlice(gpa);
}
