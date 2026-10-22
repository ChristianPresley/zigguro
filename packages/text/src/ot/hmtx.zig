//! `hmtx`: horizontal metrics. Glyphs at or past `numberOfHMetrics` reuse the
//! last advance and take their left side bearing from the trailing array.

const reader = @import("reader.zig");
const GlyphId = reader.GlyphId;

/// A view of `hmtx`, bounded by `numberOfHMetrics` and the glyph count.
pub const Hmtx = struct {
    data: []const u8,
    /// Usable long metrics (clamped to what the table holds; at least 1 unless empty).
    num_long: u16,
    num_glyphs: u16,

    /// A view over `data` for `num_hmetrics` long metrics and `num_glyphs` glyphs.
    pub fn init(data: []const u8, num_hmetrics: u16, num_glyphs: u16) Hmtx {
        const fit: u16 = @intCast(@min(data.len / 4, num_hmetrics));
        return .{ .data = data, .num_long = fit, .num_glyphs = num_glyphs };
    }

    /// Advance width of `gid` in design units (0 when the table is empty).
    pub fn advance(h: Hmtx, gid: GlyphId) u16 {
        if (h.num_long == 0) return 0;
        const i: usize = @min(gid, h.num_long - 1);
        return reader.readAt(u16, h.data, i * 4) catch 0;
    }

    /// Left side bearing of `gid` in design units (0 when absent).
    pub fn lsb(h: Hmtx, gid: GlyphId) i16 {
        if (gid < h.num_long) return reader.readAt(i16, h.data, @as(usize, gid) * 4 + 2) catch 0;
        const off = @as(usize, h.num_long) * 4 + (@as(usize, gid) - h.num_long) * 2;
        return reader.readAt(i16, h.data, off) catch 0;
    }
};
