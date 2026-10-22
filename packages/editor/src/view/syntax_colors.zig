//! Token colours for the editor view until E15's theme engine supplies
//! them: one table for dark and one for light themes, indexed by
//! `HighlightId` and resolved by dotted prefix (`keyword.control` falls
//! back to `keyword`).

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const zg_gui = @import("zg_gui");

const HighlightId = zg_syntax.HighlightId;
const Color = zg_gui.core.Color;

/// A colour per highlight; null falls back to the parent, then to the
/// default foreground.
pub const Palette = [HighlightId.count]?u32;

fn build(comptime pairs: []const struct { HighlightId, u32 }) Palette {
    var p: Palette = @splat(null);
    for (pairs) |kv| p[@intFromEnum(kv[0])] = kv[1];
    return p;
}

/// For dark backgrounds.
pub const dark: Palette = build(&.{
    .{ .comment, 0x7f8c98ff },
    .{ .string, 0xa5d6a7ff },
    .{ .string_escape, 0xffcb6bff },
    .{ .character, 0xa5d6a7ff },
    .{ .number, 0xf78c6cff },
    .{ .constant, 0xf78c6cff },
    .{ .keyword, 0xc792eaff },
    .{ .type, 0xffcb6bff },
    .{ .function, 0x82aaffff },
    .{ .variable_builtin, 0xff9cacff },
    .{ .property, 0x89ddffff },
    .{ .label, 0xff9cacff },
    .{ .operator, 0x89ddffff },
    .{ .punctuation, 0xa6accdff },
    .{ .tag, 0xf07178ff },
    .{ .attribute, 0xffcb6bff },
    .{ .markup_heading_1, 0x82aaffff },
    .{ .markup_link, 0x89ddffff },
    .{ .invalid, 0xff5370ff },
});

/// For light backgrounds.
pub const light: Palette = build(&.{
    .{ .comment, 0x6a737dff },
    .{ .string, 0x22863aff },
    .{ .string_escape, 0xb08800ff },
    .{ .character, 0x22863aff },
    .{ .number, 0x005cc5ff },
    .{ .constant, 0x005cc5ff },
    .{ .keyword, 0xd73a49ff },
    .{ .type, 0x6f42c1ff },
    .{ .function, 0x6f42c1ff },
    .{ .variable_builtin, 0xe36209ff },
    .{ .property, 0x005cc5ff },
    .{ .label, 0xe36209ff },
    .{ .operator, 0xd73a49ff },
    .{ .punctuation, 0x24292eff },
    .{ .tag, 0x22863aff },
    .{ .attribute, 0x6f42c1ff },
    .{ .markup_heading_1, 0x005cc5ff },
    .{ .markup_link, 0x032f62ff },
    .{ .invalid, 0xcb2431ff },
});

/// The palette for a theme with background `bg`.
pub fn forBackground(bg: Color) *const Palette {
    const lum = 0.2126 * @as(f32, @floatFromInt(bg.r)) + 0.7152 * @as(f32, @floatFromInt(bg.g)) + 0.0722 * @as(f32, @floatFromInt(bg.b));
    return if (lum < 128) &dark else &light;
}

/// The colour of `id`, or `fallback`.
pub fn colorOf(p: *const Palette, id: HighlightId, fallback: Color) Color {
    const v = zg_syntax.highlight_names.resolve(u32, p, id) orelse return fallback;
    return Color.hexa(v);
}

test "prefix fallback and background choice" {
    const fg: Color = .hex(0xffffff);
    try std.testing.expectEqual(Color.hexa(0xc792eaff), colorOf(&dark, .keyword_control, fg));
    try std.testing.expectEqual(fg, colorOf(&dark, .variable, fg));
    try std.testing.expect(forBackground(.hex(0x1e1e1e)) == &dark);
    try std.testing.expect(forBackground(.hex(0xffffff)) == &light);
}
