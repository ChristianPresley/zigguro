//! `hhea`: horizontal header (ascender, descender, line gap, metric count).

const reader = @import("reader.zig");

/// The fields of `hhea` that zg_text uses.
pub const Hhea = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    advance_width_max: u16,
    caret_slope_rise: i16,
    caret_slope_run: i16,
    number_of_hmetrics: u16,

    /// Parses `hhea`; it must be at least 36 bytes.
    pub fn parse(data: []const u8) reader.Error!Hhea {
        if (data.len < 36) return error.Malformed;
        return .{
            .ascender = try reader.readAt(i16, data, 4),
            .descender = try reader.readAt(i16, data, 6),
            .line_gap = try reader.readAt(i16, data, 8),
            .advance_width_max = try reader.readAt(u16, data, 10),
            .caret_slope_rise = try reader.readAt(i16, data, 18),
            .caret_slope_run = try reader.readAt(i16, data, 20),
            .number_of_hmetrics = try reader.readAt(u16, data, 34),
        };
    }
};
