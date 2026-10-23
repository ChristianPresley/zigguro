//! Diagram colours and font (E13.F07.S02.T03): the theme a diagram is
//! drawn with, two built-ins for headless use (SVG export, tests), and
//! the conversion from Mermaid style colours. The UI derives a theme
//! from the app's theme tokens (`zg_agents_ui.diagram_view`).

const std = @import("std");
const vector = @import("../vector/root.zig");

const Color = vector.Color;

pub const DiagramTheme = struct {
    node_fill: Color,
    node_stroke: Color,
    edge: Color,
    text: Color,
    cluster_fill: Color,
    cluster_stroke: Color,
    /// The canvas: behind edge labels, and the SVG background.
    background: Color,
    font: Font = .{},

    pub const Font = struct {
        size: f32 = 14,
        /// A theme font family; null is the UI font.
        family: ?[]const u8 = null,
    };

    pub const light: DiagramTheme = .{
        .node_fill = .rgb(0xECECFF),
        .node_stroke = .rgb(0x9370DB),
        .edge = .rgb(0x333333),
        .text = .rgb(0x1F2328),
        .cluster_fill = Color.rgb(0x9370DB).withAlpha(15),
        .cluster_stroke = .rgb(0xA89BD0),
        .background = .rgb(0xFFFFFF),
    };

    pub const dark: DiagramTheme = .{
        .node_fill = .rgb(0x1F2033),
        .node_stroke = .rgb(0x8B7FD6),
        .edge = .rgb(0xC9CDD4),
        .text = .rgb(0xE6E8EB),
        .cluster_fill = Color.rgb(0x8B7FD6).withAlpha(15),
        .cluster_stroke = .rgb(0x5C5490),
        .background = .rgb(0x16171D),
    };

    /// Identifies the theme (cache keys).
    pub fn hash(t: DiagramTheme) u64 {
        var h: std.hash.Wyhash = .init(0xD1A6_0001);
        inline for (.{ "node_fill", "node_stroke", "edge", "text", "cluster_fill", "cluster_stroke", "background" }) |f| {
            h.update(std.mem.asBytes(&@field(t, f)));
        }
        h.update(std.mem.asBytes(&t.font.size));
        h.update(t.font.family orelse "");
        return h.final();
    }
};

/// A Mermaid style colour (0xAARRGGBB, as the parser stores it).
pub fn fromArgb(argb: u32) Color {
    return Color.rgb(@truncate(argb)).withAlpha(@truncate(argb >> 24));
}

test {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x80 }, fromArgb(0x80123456));
    try std.testing.expect(DiagramTheme.light.hash() != DiagramTheme.dark.hash());
}
