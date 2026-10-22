//! Cell colour resolution (E06.F05.S01.T02): the style's colours through
//! the terminal palette, bold-is-bright, inverse, invisible, faint and
//! reverse video, as sRGB `zg_gui` colours.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_terminal = @import("zg_terminal");

const Color = zg_gui.core.Color;
const Palette = zg_terminal.term.Palette;
const Rgb = zg_terminal.term.color.Rgb;
const Style = zg_terminal.screen.Style;
const TColor = zg_terminal.screen.Color;
const Cell = zg_terminal.screen.Cell;

/// The default foreground and background (theme or OSC 10/11).
pub const Defaults = struct {
    fg: Color,
    bg: Color,
};

/// A cell's resolved colours.
pub const Resolved = struct {
    fg: Color,
    bg: Color,
    /// The background is the default one (the view's clear colour covers it).
    bg_default: bool,
};

/// Resolution options.
pub const Options = struct {
    /// Bold text in palette colours 0-7 uses 8-15.
    bold_is_bright: bool = true,
    /// DECSCNM (mode 5): the default colours swap.
    reverse_video: bool = false,
};

/// `rgb` as an opaque colour.
pub fn fromRgb(rgb: Rgb) Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn styleColor(p: *const Palette, c: TColor, bold_bright: bool) ?Color {
    return switch (c.tag) {
        .default => null,
        .palette => fromRgb(p.ansi[if (bold_bright and c.r < 8) c.r + 8 else c.r]),
        .rgb => .{ .r = c.r, .g = c.g, .b = c.b },
    };
}

/// The colours of `cell` drawn with style `st`.
pub fn resolve(p: *const Palette, d: Defaults, st: *const Style, cell: Cell, o: Options) Resolved {
    const def_fg = if (o.reverse_video) d.bg else d.fg;
    const def_bg = if (o.reverse_video) d.fg else d.bg;
    var fg = styleColor(p, st.fg, o.bold_is_bright and st.flags.bold) orelse def_fg;
    // Erased cells (BCE) carry their background in the cell itself.
    const cell_bg: ?Color = switch (cell.tag) {
        .bg_palette => fromRgb(p.ansi[@as(u8, @truncate(cell.content))]),
        .bg_rgb => Color.hex(cell.content),
        else => null,
    };
    var bg_opt = cell_bg orelse styleColor(p, st.bg, false);
    var bg = bg_opt orelse def_bg;
    if (st.flags.inverse) {
        const t = fg;
        fg = bg;
        bg = t;
        bg_opt = bg;
    }
    if (st.flags.invisible) fg = bg;
    if (st.flags.faint) fg = fg.lerp(bg, 0.5);
    return .{ .fg = fg, .bg = bg, .bg_default = bg_opt == null };
}

/// The underline colour: `ul_color` when set, else the foreground.
pub fn underlineColor(p: *const Palette, st: *const Style, fg: Color) Color {
    return styleColor(p, st.ul_color, false) orelse fg;
}

const testing = std.testing;

test "palette: defaults, palette, bold-is-bright, rgb" {
    const p: Palette = .{};
    const d: Defaults = .{ .fg = .hex(0xdddddd), .bg = .hex(0x101010) };
    var st: Style = .{};
    var r = resolve(&p, d, &st, .{}, .{});
    try testing.expectEqual(d.fg, r.fg);
    try testing.expect(r.bg_default);
    st.fg = .palette(1);
    st.flags.bold = true;
    r = resolve(&p, d, &st, .{}, .{});
    try testing.expectEqual(fromRgb(p.ansi[9]), r.fg);
    r = resolve(&p, d, &st, .{}, .{ .bold_is_bright = false });
    try testing.expectEqual(fromRgb(p.ansi[1]), r.fg);
    st = .{ .bg = .rgb(1, 2, 3) };
    r = resolve(&p, d, &st, .{}, .{});
    try testing.expectEqual(Color{ .r = 1, .g = 2, .b = 3 }, r.bg);
    try testing.expect(!r.bg_default);
}

test "palette: inverse, invisible, faint, reverse video and BCE cells" {
    const p: Palette = .{};
    const d: Defaults = .{ .fg = .hex(0xffffff), .bg = .hex(0x000000) };
    var st: Style = .{};
    st.flags.inverse = true;
    var r = resolve(&p, d, &st, .{}, .{});
    try testing.expectEqual(d.bg, r.fg);
    try testing.expectEqual(d.fg, r.bg);
    try testing.expect(!r.bg_default);
    st = .{};
    st.flags.invisible = true;
    r = resolve(&p, d, &st, .{}, .{});
    try testing.expectEqual(r.bg, r.fg);
    st = .{};
    st.flags.faint = true;
    r = resolve(&p, d, &st, .{}, .{});
    try testing.expectEqual(@as(u8, 128), r.fg.r);
    st = .{};
    r = resolve(&p, d, &st, .{}, .{ .reverse_video = true });
    try testing.expectEqual(d.bg, r.fg);
    r = resolve(&p, d, &st, .{ .tag = .bg_palette, .content = 4 }, .{});
    try testing.expectEqual(fromRgb(p.ansi[4]), r.bg);
    try testing.expect(!r.bg_default);
    r = resolve(&p, d, &st, .{ .tag = .bg_rgb, .content = 0x102030 }, .{});
    try testing.expectEqual(Color.hex(0x102030), r.bg);
}
