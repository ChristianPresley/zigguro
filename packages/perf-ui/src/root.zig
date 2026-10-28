//! zg_perf_ui: zg_perf's GUI (E14.F03): the performance HUD overlay, its
//! model, the latency probe and their commands. A package of its own
//! because zg_gui imports zg_perf; headless consumers keep importing
//! zg_perf alone.

const std = @import("std");

/// The HUD overlay view (`Hud`, `HudOptions`).
pub const hud = @import("hud.zig");
/// Bars and text rows from a `FrameTimeline` (no GUI types).
pub const hud_model = @import("hud_model.zig");
/// The frame-time graph widget.
pub const hud_graph = @import("hud_graph.zig");
/// The latency probe square (`Probe`, `ProbeOptions`).
pub const probe = @import("probe.zig");
/// `perf.hud.toggle` and `perf.latencyProbe.toggle`.
pub const commands = @import("commands.zig");

/// See `hud.Hud`.
pub const Hud = hud.Hud;
/// See `hud.HudOptions`.
pub const HudOptions = hud.HudOptions;
/// See `probe.Probe`.
pub const Probe = probe.Probe;

test {
    std.testing.refAllDecls(@This());
    _ = @import("hud_test.zig");
}
