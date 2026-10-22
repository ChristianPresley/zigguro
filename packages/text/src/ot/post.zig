//! `post`: PostScript information (underline metrics, fixed pitch flag).

const reader = @import("reader.zig");

/// The fields of `post` that zg_text uses.
pub const Post = struct {
    /// Italic angle in degrees (16.16 fixed), counter-clockwise from vertical.
    italic_angle: i32 = 0,
    underline_position: i16 = 0,
    underline_thickness: i16 = 0,
    is_fixed_pitch: bool = false,

    /// Parses the 32-byte `post` header (any version).
    pub fn parse(data: []const u8) reader.Error!Post {
        if (data.len < 16) return error.Malformed;
        return .{
            .italic_angle = try reader.readAt(i32, data, 4),
            .underline_position = try reader.readAt(i16, data, 8),
            .underline_thickness = try reader.readAt(i16, data, 10),
            .is_fixed_pitch = try reader.readAt(u32, data, 12) != 0,
        };
    }
};
