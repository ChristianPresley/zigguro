//! `CPAL` colour palettes (versions 0 and 1). Each palette is a run of
//! `numPaletteEntries` colour records in a shared array; records are BGRA,
//! sRGB-encoded and not premultiplied. Version 1 adds palette types, of
//! which only USABLE_WITH_DARK_BACKGROUND matters here.

const std = @import("std");
const reader = @import("reader.zig");

/// Palette index that means "the text colour" in COLR.
pub const foreground_index: u16 = 0xFFFF;

/// paletteTypes bits.
pub const usable_with_light_background: u32 = 1 << 0;
pub const usable_with_dark_background: u32 = 1 << 1;

/// A parsed CPAL table over borrowed bytes.
pub const Cpal = struct {
    data: []const u8,
    num_entries: u16,
    num_palettes: u16,
    /// Offset of the colour record array.
    records_off: u32,
    num_records: u16,
    /// Offset of the paletteTypes array, 0 when absent.
    types_off: u32 = 0,

    /// Checks the header and that every palette's records fit.
    pub fn init(data: []const u8) error{Malformed}!Cpal {
        var r = try reader.Reader.at(data, 0);
        const version = try r.u16_();
        const num_entries = try r.u16_();
        const num_palettes = try r.u16_();
        const num_records = try r.u16_();
        const records_off = try r.u32_();
        _ = try reader.subLen(data, records_off, @as(usize, num_records) * 4);
        var c: Cpal = .{ .data = data, .num_entries = num_entries, .num_palettes = num_palettes, .records_off = records_off, .num_records = num_records };
        for (0..num_palettes) |_| {
            const first = try r.u16_();
            if (@as(u32, first) + num_entries > num_records) return error.Malformed;
        }
        if (version >= 1) {
            const t = try r.u32_();
            if (t != 0 and reader.subLen(data, t, @as(usize, num_palettes) * 4) catch null != null) c.types_off = t;
        }
        return c;
    }

    /// paletteTypes of palette `i` (0 without a types array).
    pub fn paletteType(c: *const Cpal, i: u16) u32 {
        if (c.types_off == 0 or i >= c.num_palettes) return 0;
        return std.mem.readInt(u32, c.data[c.types_off + @as(usize, i) * 4 ..][0..4], .big);
    }

    /// The palette to use for `requested`: it when it exists and suits the
    /// background, else the first palette marked for a dark background
    /// when `dark_bg`, else palette 0.
    pub fn select(c: *const Cpal, requested: u16, dark_bg: bool) u16 {
        const valid = requested < c.num_palettes;
        if (dark_bg) {
            if (valid and c.paletteType(requested) & usable_with_dark_background != 0) return requested;
            for (0..c.num_palettes) |i| {
                if (c.paletteType(@intCast(i)) & usable_with_dark_background != 0) return @intCast(i);
            }
        }
        return if (valid) requested else 0;
    }

    /// Entry `index` of palette `palette` as straight sRGB RGBA bytes, or
    /// null when either is out of range (COLR then uses the text colour).
    pub fn color(c: *const Cpal, palette: u16, index: u16) ?[4]u8 {
        if (palette >= c.num_palettes or index >= c.num_entries) return null;
        const first = std.mem.readInt(u16, c.data[12 + @as(usize, palette) * 2 ..][0..2], .big);
        const rec = c.data[c.records_off + (@as(usize, first) + index) * 4 ..][0..4];
        return .{ rec[2], rec[1], rec[0], rec[3] };
    }
};

test "cpal records and selection" {
    // Two palettes of two entries over three records; v1 types mark
    // palette 1 for dark backgrounds.
    const data = [_]u8{
        0, 1, 0, 2, 0, 2, 0, 3, 0, 0, 0, 28, // header: v1, 2 entries, 2 palettes, 3 records, records at 28
        0, 0, 0, 1, // colorRecordIndices
        0, 0, 0, 40, 0, 0, 0, 0, 0, 0, 0, 0, // types, labels, entry labels
        0x10, 0x20, 0x30, 0xFF, 0x01, 0x02, 0x03, 0x80, 0xAA, 0xBB, 0xCC, 0x40, // BGRA records
        0, 0, 0, 1, 0, 0, 0, 2, // types
    };
    const c = try Cpal.init(&data);
    try std.testing.expectEqual(@as(?[4]u8, .{ 0x30, 0x20, 0x10, 0xFF }), c.color(0, 0));
    try std.testing.expectEqual(@as(?[4]u8, .{ 0x03, 0x02, 0x01, 0x80 }), c.color(1, 0));
    try std.testing.expectEqual(@as(?[4]u8, .{ 0xCC, 0xBB, 0xAA, 0x40 }), c.color(1, 1));
    try std.testing.expectEqual(@as(?[4]u8, null), c.color(0, 2));
    try std.testing.expectEqual(@as(?[4]u8, null), c.color(2, 0));
    try std.testing.expectEqual(@as(u16, 0), c.select(0, false));
    try std.testing.expectEqual(@as(u16, 1), c.select(0, true));
    try std.testing.expectEqual(@as(u16, 0), c.select(7, false));
    var bad = data;
    bad[15] = 2; // palette 1 would run past the records
    try std.testing.expectError(error.Malformed, Cpal.init(&bad));
}
