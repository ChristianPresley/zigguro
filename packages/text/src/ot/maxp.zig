//! `maxp`: maximum profile (glyph count).

const reader = @import("reader.zig");

/// The fields of `maxp` that zg_text uses.
pub const Maxp = struct {
    num_glyphs: u16,
    /// Version 1.0 limits (TrueType only); 0 for version 0.5.
    max_component_depth: u16 = 0,

    /// Parses `maxp` version 0.5 (CFF) or 1.0 (TrueType).
    pub fn parse(data: []const u8) reader.Error!Maxp {
        const version = try reader.readAt(u32, data, 0);
        const n = try reader.readAt(u16, data, 4);
        return switch (version) {
            0x00005000 => .{ .num_glyphs = n },
            0x00010000 => .{ .num_glyphs = n, .max_component_depth = reader.readAt(u16, data, 30) catch 0 },
            else => error.Malformed,
        };
    }
};
