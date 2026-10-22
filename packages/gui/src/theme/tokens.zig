//! Design tokens: the named colours and dimensions every widget paints
//! with. Widgets reference tokens, never colour literals (`lint-gui`).
//!
//! This is the core token set; the full ~400-token schema generated from
//! `tokens.zon` (E04.F08.S01.T01) extends it without renaming these.

const std = @import("std");

/// A colour token.
pub const Token = enum(u16) {
    // Surfaces.
    bg_base,
    bg_elevated,
    bg_sunken,
    bg_overlay,
    // Text.
    fg,
    fg_muted,
    fg_disabled,
    fg_on_accent,
    fg_link,
    // Lines.
    border,
    border_strong,
    focus_ring,
    // Accent and status.
    accent,
    accent_hover,
    accent_pressed,
    danger,
    warning,
    success,
    info,
    // Controls.
    button_bg,
    button_bg_hover,
    button_bg_pressed,
    button_fg,
    button_border,
    control_bg,
    control_border,
    control_checked,
    control_thumb,
    track,
    selection_bg,
    hover_bg,
    badge_bg,
    badge_fg,
    scrollbar_thumb,
    shadow,

    /// The number of tokens.
    pub const count = @typeInfo(Token).@"enum".fields.len;

    /// The token's dotted name, e.g. `button.bg.hover`.
    pub fn name(t: Token) []const u8 {
        return names[@intFromEnum(t)];
    }

    /// The token named `n` (dotted form).
    pub fn fromName(n: []const u8) ?Token {
        for (names, 0..) |x, i| {
            if (std.mem.eql(u8, x, n)) return @enumFromInt(i);
        }
        return null;
    }

    const names = blk: {
        var out: [count][]const u8 = undefined;
        for (@typeInfo(Token).@"enum".fields, 0..) |f, i| {
            var buf: [f.name.len]u8 = f.name[0..f.name.len].*;
            for (&buf) |*c| {
                if (c.* == '_') c.* = '.';
            }
            const final = buf;
            out[i] = &final;
        }
        break :blk out;
    };
};

/// A dimension token (logical pixels).
pub const Dim = enum(u8) {
    radius_sm,
    radius_md,
    radius_lg,
    space_xs,
    space_sm,
    space_md,
    space_lg,
    control_h,
    focus_ring_w,
    focus_ring_offset,
    border_w,
    font_size,
    font_size_sm,
    font_size_lg,

    /// The number of dimension tokens.
    pub const count = @typeInfo(Dim).@"enum".fields.len;
};

test "token names are dotted and round trip" {
    try std.testing.expectEqualStrings("button.bg.hover", Token.button_bg_hover.name());
    try std.testing.expectEqual(Token.fg_muted, Token.fromName("fg.muted").?);
    try std.testing.expectEqual(@as(?Token, null), Token.fromName("nope"));
}
