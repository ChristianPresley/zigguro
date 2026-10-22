//! Docking (E04.F07): the layout model, its geometry and its views.

const std = @import("std");

/// The `model.zig` module.
pub const model = @import("model.zig");
/// The `geometry.zig` module.
pub const geometry = @import("geometry.zig");
/// The `splitter.zig` module.
pub const splitter = @import("splitter.zig");
/// The `area_sash.zig` module.
pub const area_sash = @import("area_sash.zig");
/// The `tab_strip.zig` module.
pub const tab_strip = @import("tab_strip.zig");
/// The `drop_zones.zig` module.
pub const drop_zones = @import("drop_zones.zig");
/// The `view.zig` module.
pub const view = @import("view.zig");
/// The `hit_map.zig` module.
pub const hit_map = @import("hit_map.zig");
/// The `chrome.zig` module.
pub const chrome = @import("chrome.zig");

/// See `model.DockModel`.
pub const DockModel = model.DockModel;
/// See `view.DockView`.
pub const DockView = view.DockView;
/// See `view.PanelHost`.
pub const PanelHost = view.PanelHost;
/// See `tab_strip.tabStrip`.
pub const tabStrip = tab_strip.tabStrip;

test {
    std.testing.refAllDecls(@This());
}
