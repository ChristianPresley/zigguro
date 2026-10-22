//! `head`: font header (units per em, bounds, loca format, mac style).

const reader = @import("reader.zig");

/// The fields of `head` that zg_text uses.
pub const Head = struct {
    units_per_em: u16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    mac_style: u16,
    /// `indexToLocFormat == 1`: `loca` holds Offset32 entries.
    loca_long: bool,

    /// Parses `head`; it must be at least 54 bytes with major version 1.
    pub fn parse(data: []const u8) reader.Error!Head {
        if (data.len < 54) return error.Malformed;
        if (try reader.readAt(u16, data, 0) != 1) return error.Malformed;
        var upem = try reader.readAt(u16, data, 18);
        // Valid range is 16..16384; repair rather than reject.
        if (upem < 16 or upem > 16384) upem = 1000;
        return .{
            .units_per_em = upem,
            .x_min = try reader.readAt(i16, data, 36),
            .y_min = try reader.readAt(i16, data, 38),
            .x_max = try reader.readAt(i16, data, 40),
            .y_max = try reader.readAt(i16, data, 42),
            .mac_style = try reader.readAt(u16, data, 44),
            .loca_long = try reader.readAt(i16, data, 50) == 1,
        };
    }
};
