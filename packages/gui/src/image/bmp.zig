//! BMP (E04.F06.S02.T03): the core (12-byte), INFO (40), V2/V3 (52/56),
//! V4 (108) and V5 (124) headers; 1/4/8 bpp with a palette, 16 bpp (5-5-5
//! or BI_BITFIELDS), 24 bpp and 32 bpp (BI_RGB or BI_BITFIELDS). Alpha is
//! used only when a V3+ header has a non-zero alpha mask; otherwise the
//! image is opaque. Rows are padded to 4 bytes and stored bottom-up unless
//! the height is negative. RLE and embedded JPEG/PNG are `Unsupported`.

const std = @import("std");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;
const Image = image.Image;
const Limits = image.Limits;
const DecodeError = image.DecodeError;

const bi_rgb = 0;
const bi_bitfields = 3;
const bi_alphabitfields = 6;

/// One channel of a bitfield pixel.
const Field = struct {
    mask: u32,
    shift: u5,
    max: u32,

    fn of(mask: u32) Field {
        if (mask == 0) return .{ .mask = 0, .shift = 0, .max = 0 };
        const shift: u5 = @intCast(@ctz(mask));
        return .{ .mask = mask, .shift = shift, .max = mask >> shift };
    }

    /// The channel scaled to 8 bits.
    fn get(f: Field, px: u32) u8 {
        if (f.max == 0) return 0;
        const v = (px & f.mask) >> f.shift;
        return @intCast((@as(u64, v) * 255 + f.max / 2) / f.max);
    }
};

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

pub fn decodeBmp(gpa: Allocator, bytes: []const u8, limits: Limits) DecodeError!Image {
    if (bytes.len > limits.max_bytes) return error.TooLarge;
    if (bytes.len < 14 + 12 or bytes[0] != 'B' or bytes[1] != 'M') return error.Malformed;
    const data_at = le32(bytes, 10);
    const hsize = le32(bytes, 14);
    const h_end = std.math.add(usize, 14, hsize) catch return error.Malformed;
    if (h_end > bytes.len) return error.Malformed;
    var w: i64 = undefined;
    var h: i64 = undefined;
    var bpp: u16 = undefined;
    var compression: u32 = bi_rgb;
    var colors_used: u32 = 0;
    var pal_entry: usize = 4;
    switch (hsize) {
        12 => {
            w = le16(bytes, 18);
            h = @as(i16, @bitCast(le16(bytes, 20)));
            bpp = le16(bytes, 24);
            pal_entry = 3;
        },
        40, 52, 56, 108, 124 => {
            w = @as(i32, @bitCast(le32(bytes, 18)));
            h = @as(i32, @bitCast(le32(bytes, 22)));
            bpp = le16(bytes, 28);
            compression = le32(bytes, 30);
            colors_used = le32(bytes, 46);
        },
        else => return error.Unsupported,
    }
    switch (compression) {
        bi_rgb, bi_bitfields, bi_alphabitfields => {},
        else => return error.Unsupported,
    }
    if (w <= 0 or h == 0) return error.Malformed;
    const top_down = h < 0;
    const width: u32 = std.math.cast(u32, w) orelse return error.TooLarge;
    const height: u32 = std.math.cast(u32, @abs(h)) orelse return error.TooLarge;
    const out_len = try image.pixelBytes(width, height, limits);

    // Channel masks: defaults per depth, then the header's.
    var masks = [4]u32{ 0, 0, 0, 0 };
    var after_header = h_end;
    switch (bpp) {
        16 => masks = .{ 0x7C00, 0x03E0, 0x001F, 0 },
        24, 32 => masks = .{ 0xFF0000, 0xFF00, 0xFF, 0 },
        1, 4, 8 => {},
        else => return error.Unsupported,
    }
    if (compression != bi_rgb) {
        if (bpp != 16 and bpp != 32) return error.Malformed;
        if (hsize == 40) {
            const n: usize = if (compression == bi_alphabitfields) 16 else 12;
            if (after_header + n > bytes.len) return error.Malformed;
            for (0..n / 4) |i| masks[i] = le32(bytes, after_header + i * 4);
            after_header += n;
        } else {
            for (0..3) |i| masks[i] = le32(bytes, 54 + i * 4);
            if (hsize >= 56) masks[3] = le32(bytes, 66);
        }
    } else if (hsize >= 56 and bpp == 32) {
        // A V3+ BI_RGB 32-bit image with an alpha mask (GIMP writes these).
        masks[3] = le32(bytes, 66);
    }
    if (hsize < 56 and compression != bi_alphabitfields) masks[3] = 0;

    // Palette.
    var palette: [256][3]u8 = undefined;
    var ncolors: usize = 0;
    if (bpp <= 8) {
        const max = @as(usize, 1) << @intCast(bpp);
        ncolors = if (colors_used == 0 or colors_used > max) max else colors_used;
        if (after_header + ncolors * pal_entry > bytes.len) return error.Malformed;
        for (0..ncolors) |i| {
            const e = bytes[after_header + i * pal_entry ..];
            palette[i] = .{ e[2], e[1], e[0] };
        }
    }

    const row_bits = std.math.mul(usize, width, bpp) catch return error.TooLarge;
    const row_bytes = (row_bits + 31) / 32 * 4;
    const need = std.math.mul(usize, row_bytes, height) catch return error.TooLarge;
    if (data_at > bytes.len or bytes.len - data_at < need) return error.Malformed;
    const px = bytes[data_at..];

    const fields = [4]Field{ .of(masks[0]), .of(masks[1]), .of(masks[2]), .of(masks[3]) };
    const out = try gpa.alloc(u8, out_len);
    errdefer gpa.free(out);
    for (0..height) |y| {
        const src_row = if (top_down) y else height - 1 - y;
        const row = px[src_row * row_bytes ..][0..row_bytes];
        const dst = out[y * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            var rgba: [4]u8 = .{ 0, 0, 0, 255 };
            switch (bpp) {
                1, 4, 8 => {
                    const bit = x * bpp;
                    const byte = row[bit / 8];
                    const shift: u3 = @intCast(8 - bpp - (bit % 8));
                    const idx = (byte >> shift) & @as(u8, @intCast((@as(u16, 1) << @intCast(bpp)) - 1));
                    if (idx < ncolors) rgba = .{ palette[idx][0], palette[idx][1], palette[idx][2], 255 } else rgba = .{ 0, 0, 0, 255 };
                },
                16, 32 => {
                    const v: u32 = if (bpp == 16) le16(row, x * 2) else le32(row, x * 4);
                    rgba = .{ fields[0].get(v), fields[1].get(v), fields[2].get(v), if (fields[3].mask != 0) fields[3].get(v) else 255 };
                },
                24 => rgba = .{ row[x * 3 + 2], row[x * 3 + 1], row[x * 3], 255 },
                else => unreachable,
            }
            const a = rgba[3];
            dst[x * 4 ..][0..4].* = .{ image.premul(rgba[0], a), image.premul(rgba[1], a), image.premul(rgba[2], a), a };
        }
    }
    return .{ .w = width, .h = height, .rgba = out, .format = .bmp };
}
