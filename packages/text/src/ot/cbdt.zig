//! `CBLC`/`CBDT` colour bitmap strikes (Noto Color Emoji on Linux). CBLC
//! lists strikes (ppem, glyph range) and per-range index subtables
//! (formats 1–5) locating each glyph's data in CBDT; CBDT holds the
//! metrics and a PNG (image formats 17, 18 and 19). Other image formats
//! are uncompressed monochrome or grey bitmaps, which colour fonts do not
//! use; they read as "no bitmap" so the caller falls back to the outline.

const std = @import("std");
const reader = @import("reader.zig");
const GlyphId = reader.GlyphId;
const Face = @import("face.zig").Face;

/// A glyph image from a bitmap strike, in strike pixels.
pub const StrikeGlyph = struct {
    /// The PNG data (borrowed from the font).
    png: []const u8,
    /// Pen origin to the image's left edge, strike pixels.
    origin_x: f32,
    /// Baseline to the image's top edge, strike pixels, y up.
    origin_y: f32,
    /// The strike's pixels per em.
    ppem: u16,
    /// Advance from the strike's metrics, when it has one (the caller
    /// prefers hmtx).
    advance_px: ?f32 = null,
};

/// Width and height from a PNG's IHDR, or null when the data is not a PNG.
pub fn pngSize(png: []const u8) ?[2]u32 {
    if (png.len < 24 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, png[12..16], "IHDR")) return null;
    return .{ std.mem.readInt(u32, png[16..20], .big), std.mem.readInt(u32, png[20..24], .big) };
}

const BigMetrics = struct { height: u8, width: u8, bx: i8, by: i8, adv: u8 };

fn bigMetrics(b: []const u8, off: usize) reader.Error!BigMetrics {
    const m = try reader.subLen(b, off, 8);
    return .{ .height = m[0], .width = m[1], .bx = @bitCast(m[2]), .by = @bitCast(m[3]), .adv = m[4] };
}

/// Location of a glyph's CBDT record.
const Loc = struct { off: u32, len: u32, image_format: u16, metrics: ?BigMetrics };

/// A parsed CBLC/CBDT pair.
pub const Cbdt = struct {
    cblc: []const u8,
    cbdt: []const u8,
    num_sizes: u32,

    /// Checks the headers. Versions 2.0 (EBLC-compatible) and 3.0 parse.
    pub fn init(cblc: []const u8, cbdt: []const u8) error{Malformed}!Cbdt {
        const major = reader.readAt(u16, cblc, 0) catch return error.Malformed;
        if (major != 2 and major != 3) return error.Malformed;
        const n = reader.readAt(u32, cblc, 4) catch return error.Malformed;
        if (n > (cblc.len - 8) / 48) return error.Malformed;
        if (cbdt.len < 4) return error.Malformed;
        return .{ .cblc = cblc, .cbdt = cbdt, .num_sizes = n };
    }

    /// From a face, if it has both tables.
    pub fn fromFace(face: *const Face) ?Cbdt {
        const l = face.knownTable(.cblc) orelse return null;
        const d = face.knownTable(.cbdt) orelse return null;
        return init(l, d) catch null;
    }

    fn sizeRec(c: *const Cbdt, i: u32) []const u8 {
        return c.cblc[8 + @as(usize, i) * 48 ..][0..48];
    }

    /// ppemY of strike `i`.
    pub fn strikePpem(c: *const Cbdt, i: u32) u8 {
        return c.sizeRec(i)[45];
    }

    /// Finds `gid` in strike `i`.
    fn locate(c: *const Cbdt, i: u32, gid: GlyphId) reader.Error!?Loc {
        const rec = c.sizeRec(i);
        const start = std.mem.readInt(u16, rec[40..42], .big);
        const end = std.mem.readInt(u16, rec[42..44], .big);
        if (gid < start or gid > end) return null;
        const arr: usize = std.mem.readInt(u32, rec[0..4], .big);
        const n = std.mem.readInt(u32, rec[8..12], .big);
        if (n > c.cblc.len / 8) return error.Malformed;
        for (0..n) |k| {
            const e = try reader.subLen(c.cblc, arr + k * 8, 8);
            const first = std.mem.readInt(u16, e[0..2], .big);
            const last = std.mem.readInt(u16, e[2..4], .big);
            if (gid < first or gid > last) continue;
            const sub = arr + std.mem.readInt(u32, e[4..8], .big);
            const fmt = try reader.readAt(u16, c.cblc, sub);
            const image_format = try reader.readAt(u16, c.cblc, sub + 2);
            const data_off = try reader.readAt(u32, c.cblc, sub + 4);
            const idx: usize = gid - first;
            const body = sub + 8;
            switch (fmt) {
                1 => {
                    const a = try reader.readAt(u32, c.cblc, body + idx * 4);
                    const b = try reader.readAt(u32, c.cblc, body + idx * 4 + 4);
                    if (b <= a) return null;
                    return .{ .off = data_off +| a, .len = b - a, .image_format = image_format, .metrics = null };
                },
                3 => {
                    const a = try reader.readAt(u16, c.cblc, body + idx * 2);
                    const b = try reader.readAt(u16, c.cblc, body + idx * 2 + 2);
                    if (b <= a) return null;
                    return .{ .off = data_off +| a, .len = b - a, .image_format = image_format, .metrics = null };
                },
                2 => {
                    const size = try reader.readAt(u32, c.cblc, body);
                    const m = try bigMetrics(c.cblc, body + 4);
                    return .{ .off = data_off +| @as(u32, @intCast(@min(idx * size, std.math.maxInt(u32)))), .len = size, .image_format = image_format, .metrics = m };
                },
                4 => {
                    const num = try reader.readAt(u32, c.cblc, body);
                    if (num > c.cblc.len / 4) return error.Malformed;
                    // Pairs are sorted by glyph id; the next pair ends the data.
                    var lo: usize = 0;
                    var hi: usize = num;
                    while (lo < hi) {
                        const mid = (lo + hi) / 2;
                        const g = try reader.readAt(u16, c.cblc, body + 4 + mid * 4);
                        if (g < gid) lo = mid + 1 else hi = mid;
                    }
                    if (lo >= num) return null;
                    if (try reader.readAt(u16, c.cblc, body + 4 + lo * 4) != gid) return null;
                    const a = try reader.readAt(u16, c.cblc, body + 4 + lo * 4 + 2);
                    const b = try reader.readAt(u16, c.cblc, body + 4 + (lo + 1) * 4 + 2);
                    if (b <= a) return null;
                    return .{ .off = data_off +| a, .len = b - a, .image_format = image_format, .metrics = null };
                },
                5 => {
                    const size = try reader.readAt(u32, c.cblc, body);
                    const m = try bigMetrics(c.cblc, body + 4);
                    const num = try reader.readAt(u32, c.cblc, body + 12);
                    if (num > c.cblc.len / 2) return error.Malformed;
                    var lo: usize = 0;
                    var hi: usize = num;
                    while (lo < hi) {
                        const mid = (lo + hi) / 2;
                        const g = try reader.readAt(u16, c.cblc, body + 16 + mid * 2);
                        if (g < gid) lo = mid + 1 else hi = mid;
                    }
                    if (lo >= num or try reader.readAt(u16, c.cblc, body + 16 + lo * 2) != gid) return null;
                    return .{ .off = data_off +| @as(u32, @intCast(@min(lo * size, std.math.maxInt(u32)))), .len = size, .image_format = image_format, .metrics = m };
                },
                else => return null,
            }
        }
        return null;
    }

    /// The PNG glyph of `gid` in strike `i`, if it has one.
    pub fn glyphInStrike(c: *const Cbdt, i: u32, gid: GlyphId) reader.Error!?StrikeGlyph {
        const loc = try c.locate(i, gid) orelse return null;
        const rec = try reader.subLen(c.cbdt, loc.off, loc.len);
        const ppem = c.strikePpem(i);
        var m: BigMetrics = undefined;
        var png: []const u8 = undefined;
        switch (loc.image_format) {
            17 => {
                if (rec.len < 9) return error.Malformed;
                m = .{ .height = rec[0], .width = rec[1], .bx = @bitCast(rec[2]), .by = @bitCast(rec[3]), .adv = rec[4] };
                png = try reader.subLen(rec, 9, std.mem.readInt(u32, rec[5..9], .big));
            },
            18 => {
                if (rec.len < 12) return error.Malformed;
                m = try bigMetrics(rec, 0);
                png = try reader.subLen(rec, 12, std.mem.readInt(u32, rec[8..12], .big));
            },
            19 => {
                m = loc.metrics orelse return error.Malformed;
                if (rec.len < 4) return error.Malformed;
                png = try reader.subLen(rec, 4, std.mem.readInt(u32, rec[0..4], .big));
            },
            else => return null,
        }
        return .{
            .png = png,
            .origin_x = @floatFromInt(m.bx),
            .origin_y = @floatFromInt(m.by),
            .ppem = ppem,
            .advance_px = @floatFromInt(m.adv),
        };
    }

    /// The glyph from the best strike for `ppem`: the smallest strike at
    /// least that large, else the largest, skipping strikes without it.
    pub fn glyph(c: *const Cbdt, gid: GlyphId, ppem: f32) ?StrikeGlyph {
        var tried: u64 = 0; // strikes beyond 64 are only tried by the fallback scan
        while (true) {
            var best: ?u32 = null;
            for (0..c.num_sizes) |k| {
                const i: u32 = @intCast(k);
                if (i < 64 and tried & (@as(u64, 1) << @intCast(i)) != 0) continue;
                const p: f32 = @floatFromInt(c.strikePpem(i));
                if (best) |b| {
                    const bp: f32 = @floatFromInt(c.strikePpem(b));
                    const better = if (p >= ppem) (bp < ppem or p < bp) else (bp < ppem and p > bp);
                    if (better) best = i;
                } else best = i;
            }
            const i = best orelse return null;
            if (c.glyphInStrike(i, gid) catch null) |g| return g;
            if (i >= 64) return null;
            tried |= @as(u64, 1) << @intCast(i);
        }
    }
};

/// The CBDT glyph of `gid` for `ppem`, if the face has one.
pub fn cbdtGlyph(face: *const Face, gid: GlyphId, ppem: f32) ?StrikeGlyph {
    const c = Cbdt.fromFace(face) orelse return null;
    return c.glyph(gid, ppem);
}
