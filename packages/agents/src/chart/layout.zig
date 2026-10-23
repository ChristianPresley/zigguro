//! Chart layout (E13.F07.S01.T03): text measurement, the chart's
//! style tokens, and how the title, axes, legend and plot area share
//! the chart's size.

const std = @import("std");
const scale = @import("scale.zig");

pub const Box = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn right(b: Box) f32 {
        return b.x + b.w;
    }

    pub fn bottom(b: Box) f32 {
        return b.y + b.h;
    }

    pub fn contains(b: Box, p: [2]f32) bool {
        return p[0] >= b.x and p[0] <= b.right() and p[1] >= b.y and p[1] <= b.bottom();
    }
};

/// Text widths: the app's shaper (E03) through `f`, or an estimate from
/// per-character classes when there is none (headless, SVG export).
pub const Measure = struct {
    ctx: ?*anyopaque = null,
    f: ?*const fn (ctx: ?*anyopaque, text: []const u8, size: f32, bold: bool) f32 = null,

    pub fn width(m: Measure, text: []const u8, size: f32, bold: bool) f32 {
        if (m.f) |f| return f(m.ctx, text, size, bold);
        return estimate(text, size, bold);
    }
};

/// A width estimate for a proportional sans-serif face.
pub fn estimate(text: []const u8, size: f32, bold: bool) f32 {
    var em: f32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        em += switch (cp) {
            'i', 'l', 'j', '.', ',', ':', ';', '\'', '|', '!', ' ' => 0.28,
            'f', 't', 'r', '(', ')', '[', ']', '-', '/' => 0.36,
            'm', 'w', 'M', 'W', '@', '%' => 0.86,
            '0'...'9' => 0.56,
            'A'...'H', 'J'...'L', 'N'...'V', 'X'...'Z', '&', '#' => 0.66,
            'I' => 0.3,
            else => if (cp < 0x80) 0.53 else if (cp >= 0x1100) 1.0 else 0.6,
        };
    }
    return em * size * @as(f32, if (bold) 1.06 else 1);
}

/// Colours and sizes (light theme defaults; the app passes its theme's).
pub const Style = struct {
    font_size: f32 = 11,
    title_size: f32 = 14,
    axis_title_size: f32 = 11,
    text: scale.Rgb = 0x4D4D4D,
    title: scale.Rgb = 0x1A1A1A,
    axis: scale.Rgb = 0x888888,
    grid: scale.Rgb = 0xE6E6E6,
    /// Mark colour without a colour channel.
    mark: scale.Rgb = 0x4C78A8,
    padding: f32 = 8,
    tick_size: f32 = 5,
    label_gap: f32 = 3,
    /// Legend swatch size and row height.
    swatch: f32 = 10,
    legend_row: f32 = 16,
    /// Gridlines one device pixel wide at this scale.
    device_scale: f32 = 1,
};

pub const LegendBox = struct {
    box: Box,
    columns: u32,
    rows_per_column: u32,
    column_w: f32,
};

/// A legend of `n` entries whose widest label is `label_w`, wrapping into
/// columns to fit `max_h` below its title.
pub fn legendBox(st: Style, n: usize, label_w: f32, title_w: f32, max_h: f32) LegendBox {
    const title_h = st.font_size + 6;
    const fit: u32 = @max(1, @as(u32, @intFromFloat(@max(0, (max_h - title_h) / st.legend_row))));
    const rows: u32 = @intCast(@min(n, fit));
    const cols: u32 = if (rows == 0) 1 else @intCast((n + rows - 1) / rows);
    const col_w = st.swatch + 6 + label_w + 10;
    const w = @max(title_w, col_w * @as(f32, @floatFromInt(cols)) - 10);
    return .{
        .box = .{ .w = w, .h = title_h + @as(f32, @floatFromInt(rows)) * st.legend_row },
        .columns = cols,
        .rows_per_column = @max(rows, 1),
        .column_w = col_w,
    };
}

test {
    std.testing.refAllDecls(@This());
}
