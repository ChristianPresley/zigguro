//! The terminal executor (E06.F02.S02): xterm control functions applied to
//! the screen model, the mode table, palette, reports, OSC and DCS handling.

pub const Terminal = @import("term/Terminal.zig");
pub const modes = @import("term/modes.zig");
pub const ModeId = modes.ModeId;
pub const Modes = modes.Modes;
pub const color = @import("term/color.zig");
pub const Palette = color.Palette;
pub const sgr = @import("term/sgr.zig");
pub const effects = @import("term/effects.zig");
pub const Effect = effects.Effect;
pub const EffectQueue = effects.EffectQueue;
pub const Tabstops = @import("term/tabstops.zig");
pub const charset = @import("term/charset.zig");
pub const handlers = @import("term/handlers.zig");
pub const reports = @import("term/reports.zig");
pub const dcs = @import("term/dcs.zig");
pub const osc = @import("term/osc.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
