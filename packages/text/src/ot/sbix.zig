//! `sbix` bitmap strikes (Apple Color Emoji). Each strike has a ppem and
//! per-glyph records of origin offsets, a graphic type and the data.
//! `'png '` is decoded; `'dupe'` points at another glyph of the same strike
//! (followed up to 4 hops); `'jpg '`, `'tiff'` and others read as "no
//! bitmap" so the caller tries another strike or the outline.

const std = @import("std");
const reader = @import("reader.zig");
const GlyphId = reader.GlyphId;
const Face = @import("face.zig").Face;
const cbdt = @import("cbdt.zig");
const StrikeGlyph = cbdt.StrikeGlyph;

/// Most `dupe` hops followed.
pub const max_dupe_hops = 4;

/// A parsed `sbix` table.
pub const Sbix = struct {
    data: []const u8,
    num_strikes: u32,
    num_glyphs: u16,

    /// Checks the header against `num_glyphs` (from maxp).
    pub fn init(data: []const u8, num_glyphs: u16) error{Malformed}!Sbix {
        const version = reader.readAt(u16, data, 0) catch return error.Malformed;
        if (version != 1) return error.Malformed;
        const n = reader.readAt(u32, data, 4) catch return error.Malformed;
        if (n > (data.len - 8) / 4) return error.Malformed;
        return .{ .data = data, .num_strikes = n, .num_glyphs = num_glyphs };
    }

    /// From a face, if it has the table.
    pub fn fromFace(face: *const Face) ?Sbix {
        const t = face.knownTable(.sbix) orelse return null;
        return init(t, face.num_glyphs) catch null;
    }

    fn strikeOff(s: *const Sbix, i: u32) reader.Error!usize {
        return try reader.readAt(u32, s.data, 8 + @as(usize, i) * 4);
    }

    /// ppem of strike `i` (0 when the strike is out of the table).
    pub fn strikePpem(s: *const Sbix, i: u32) u16 {
        const off = s.strikeOff(i) catch return 0;
        return reader.readAt(u16, s.data, off) catch 0;
    }

    /// The record of `gid` in strike `i`: origin offsets, graphic type and
    /// data, or null for an empty slot.
    fn record(s: *const Sbix, i: u32, gid: GlyphId) reader.Error!?struct { ox: i16, oy: i16, kind: u32, body: []const u8 } {
        if (gid >= s.num_glyphs) return null;
        const so = try s.strikeOff(i);
        const a = try reader.readAt(u32, s.data, so + 4 + @as(usize, gid) * 4);
        const b = try reader.readAt(u32, s.data, so + 4 + @as(usize, gid) * 4 + 4);
        if (b <= a) return null;
        if (b - a < 8) return error.Malformed;
        const rec = try reader.subLen(s.data, so + a, b - a);
        return .{
            .ox = std.mem.readInt(i16, rec[0..2], .big),
            .oy = std.mem.readInt(i16, rec[2..4], .big),
            .kind = std.mem.readInt(u32, rec[4..8], .big),
            .body = rec[8..],
        };
    }

    /// The PNG glyph of `gid` in strike `i`, resolving `dupe` records.
    /// `bottom_left` is the glyph's (xMin, yMin) in font units scaled to
    /// strike pixels, added to the origin offsets (null when the font has no
    /// outlines).
    pub fn glyphInStrike(s: *const Sbix, i: u32, gid: GlyphId, bottom_left: ?[2]f32) reader.Error!?StrikeGlyph {
        var g = gid;
        var hops: u8 = 0;
        while (true) {
            const rec = try s.record(i, g) orelse return null;
            switch (rec.kind) {
                reader.tag("dupe") => {
                    if (hops == max_dupe_hops or rec.body.len < 2) return null;
                    hops += 1;
                    g = std.mem.readInt(u16, rec.body[0..2], .big);
                },
                reader.tag("png ") => {
                    const size = cbdt.pngSize(rec.body) orelse return error.Malformed;
                    const bl = bottom_left orelse .{ 0, 0 };
                    return .{
                        .png = rec.body,
                        .origin_x = @as(f32, @floatFromInt(rec.ox)) + bl[0],
                        .origin_y = @as(f32, @floatFromInt(rec.oy)) + bl[1] + @as(f32, @floatFromInt(size[1])),
                        .ppem = s.strikePpem(i),
                    };
                },
                else => return null,
            }
        }
    }

    /// The best strike's glyph for `ppem`: the smallest strike at least
    /// that large, else the largest, skipping strikes that lack it.
    /// `bottom_left_em` is (xMin, yMin) / unitsPerEm, scaled per strike.
    pub fn glyph(s: *const Sbix, gid: GlyphId, ppem: f32, bottom_left_em: ?[2]f32) ?StrikeGlyph {
        var tried: u64 = 0;
        while (true) {
            var best: ?u32 = null;
            for (0..@min(s.num_strikes, 64)) |k| {
                const i: u32 = @intCast(k);
                if (tried & (@as(u64, 1) << @intCast(i)) != 0) continue;
                const p: f32 = @floatFromInt(s.strikePpem(i));
                if (p == 0) continue;
                if (best) |b| {
                    const bp: f32 = @floatFromInt(s.strikePpem(b));
                    const better = if (p >= ppem) (bp < ppem or p < bp) else (bp < ppem and p > bp);
                    if (better) best = i;
                } else best = i;
            }
            const i = best orelse return null;
            const sp: f32 = @floatFromInt(s.strikePpem(i));
            const bl: ?[2]f32 = if (bottom_left_em) |e| .{ e[0] * sp, e[1] * sp } else null;
            if (s.glyphInStrike(i, gid, bl) catch null) |g| return g;
            tried |= @as(u64, 1) << @intCast(i);
        }
    }
};

/// The sbix glyph of `gid` for `ppem`, if the face has one. With `glyf`
/// outlines, the image is placed relative to the glyph's (xMin, yMin).
pub fn sbixGlyph(face: *const Face, gid: GlyphId, ppem: f32) ?StrikeGlyph {
    const s = Sbix.fromFace(face) orelse return null;
    var bl: ?[2]f32 = null;
    if (face.glyf()) |g| {
        if (g.headerBounds(gid) catch null) |b| {
            const upem: f32 = @floatFromInt(face.units_per_em);
            if (upem > 0) bl = .{ b.x0 / upem, b.y0 / upem };
        }
    }
    return s.glyph(gid, ppem, bl);
}
