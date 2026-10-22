//! The built-in text leaf (`Ui.text`): measured and wrapped through the
//! window's `TextSystem`, painted in a theme token colour.

const std = @import("std");
const widget = @import("../core/widget.zig");
const geom = @import("../core/geom.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const measure_mod = @import("../layout/measure.zig");
const tokens = @import("../theme/tokens.zig");

/// How `Ui.text` draws its string.
pub const TextProps = struct {
    style: text_mod.TextStyle = .{},
    color: tokens.Token = .fg,
    /// Wrap at the available width; otherwise one line per `\n`.
    wrap: bool = true,
    @"align": paint_cx.TextAlign = .start,
    /// Use the theme's body size instead of `style.size`.
    theme_size: bool = true,
};

/// A run of text.
pub const Text = struct {
    /// Shown in snapshots.
    pub const name = "text";

    /// The string plus its `TextProps`.
    pub const Props = struct {
        text: []const u8,
        p: TextProps = .{},
    };

    fn styleOf(props: *const Props, th: anytype) text_mod.TextStyle {
        var st = props.p.style;
        if (props.p.theme_size) st.size = th.dim(.font_size);
        return st;
    }

    /// The wrapped size of the string.
    pub fn measure(mc: *measure_mod.MeasureCx, props: *const Props, _: *widget.NoState, max_w: ?f32) geom.Size {
        const st = styleOf(props, mc.theme);
        return mc.text.measure(st, props.text, if (props.p.wrap) max_w else null);
    }

    /// Draws the string in the node's box.
    pub fn paint(pc: *paint_cx.PaintCx, props: *const Props, _: *widget.NoState) void {
        const st = styleOf(props, pc.theme);
        pc.textBox(props.text, st, pc.color(props.p.color), pc.bounds(), props.p.wrap, props.p.@"align");
    }

    /// Static text named by its content.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .text, .name = props.text };
    }

    /// Colour changes only repaint.
    pub fn layoutHash(props: *const Props) u64 {
        var p = props.*;
        p.p.color = .fg;
        return @import("../core/hash.zig").of(p);
    }
};

test {
    std.testing.refAllDecls(@This());
}
