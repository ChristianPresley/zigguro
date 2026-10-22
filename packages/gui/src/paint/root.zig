//! Paint: the renderer contract (`Canvas`), retained ops and text.

const std = @import("std");

/// The `canvas.zig` module.
pub const canvas = @import("canvas.zig");
/// The `paint_cx.zig` module.
pub const paint_cx = @import("paint_cx.zig");
/// The `text.zig` module.
pub const text = @import("text.zig");

/// See `canvas.Canvas`.
pub const Canvas = canvas.Canvas;
/// See `paint_cx.PaintCx`.
pub const PaintCx = paint_cx.PaintCx;
/// See `text.TextSystem`.
pub const TextSystem = text.TextSystem;

test {
    std.testing.refAllDecls(@This());
}
