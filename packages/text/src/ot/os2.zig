//! `OS/2`: weight/width classes, typographic metrics, x/cap height.
//! Short (Apple 68-byte) and versioned tables are both accepted.

const reader = @import("reader.zig");

/// The fields of `OS/2` that zg_text uses. Fields beyond the table's length
/// keep their defaults.
pub const Os2 = struct {
    version: u16 = 0,
    weight_class: u16 = 400,
    width_class: u16 = 5,
    fs_type: u16 = 0,
    strikeout_size: i16 = 0,
    strikeout_position: i16 = 0,
    panose: [10]u8 = @splat(0),
    unicode_ranges: [4]u32 = @splat(0),
    fs_selection: u16 = 0,
    typo_ascender: i16 = 0,
    typo_descender: i16 = 0,
    typo_line_gap: i16 = 0,
    win_ascent: u16 = 0,
    win_descent: u16 = 0,
    code_page_ranges: [2]u32 = @splat(0),
    x_height: i16 = 0,
    cap_height: i16 = 0,

    /// `fsSelection` bits.
    pub const sel_italic: u16 = 1 << 0;
    pub const sel_bold: u16 = 1 << 5;
    pub const sel_regular: u16 = 1 << 6;
    pub const sel_use_typo_metrics: u16 = 1 << 7;
    pub const sel_oblique: u16 = 1 << 9;

    /// Parses `OS/2`; it must be at least 68 bytes.
    pub fn parse(data: []const u8) reader.Error!Os2 {
        if (data.len < 68) return error.Malformed;
        var o: Os2 = .{
            .version = try reader.readAt(u16, data, 0),
            .weight_class = try reader.readAt(u16, data, 4),
            .width_class = try reader.readAt(u16, data, 6),
            .fs_type = try reader.readAt(u16, data, 8),
            .strikeout_size = try reader.readAt(i16, data, 26),
            .strikeout_position = try reader.readAt(i16, data, 28),
            .panose = data[32..42].*,
            .fs_selection = try reader.readAt(u16, data, 62),
        };
        for (&o.unicode_ranges, 0..) |*u, i| u.* = try reader.readAt(u32, data, 42 + i * 4);
        if (data.len >= 78) {
            o.typo_ascender = try reader.readAt(i16, data, 68);
            o.typo_descender = try reader.readAt(i16, data, 70);
            o.typo_line_gap = try reader.readAt(i16, data, 72);
            o.win_ascent = try reader.readAt(u16, data, 74);
            o.win_descent = try reader.readAt(u16, data, 76);
        }
        if (o.version >= 1 and data.len >= 86) {
            o.code_page_ranges[0] = try reader.readAt(u32, data, 78);
            o.code_page_ranges[1] = try reader.readAt(u32, data, 82);
        }
        if (o.version >= 2 and data.len >= 90) {
            o.x_height = try reader.readAt(i16, data, 86);
            o.cap_height = try reader.readAt(i16, data, 88);
        }
        // Weight classes 1..9 come from old tools that meant 100..900.
        if (o.weight_class >= 1 and o.weight_class <= 9) o.weight_class *= 100;
        if (o.weight_class == 0 or o.weight_class > 1000) o.weight_class = 400;
        if (o.width_class == 0 or o.width_class > 9) o.width_class = 5;
        return o;
    }
};
