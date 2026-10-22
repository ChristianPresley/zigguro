//! zg_gui: zigguro's UI toolkit (E04). A retained node tree built
//! declaratively by views and reconciled by key (docs/adr/0009), a CSS-subset
//! layout engine, input routing and focus, design-token theming, widgets, a
//! platform host and a headless test driver.

const std = @import("std");

/// Core runtime: ids, node store, `Ui` builder, views, `App`, `Window`.
pub const core = @import("core/root.zig");
/// Layout: `Style` and the flex/stack/absolute engine.
pub const layout = @import("layout/root.zig");
/// Input: events, hit testing, key routing.
pub const input = @import("input/root.zig");
/// Paint: the `Canvas` contract, retained ops, text measurement.
pub const paint = @import("paint/root.zig");
/// Widgets.
pub const w = @import("widgets/root.zig");
/// Design tokens and themes.
pub const theme = @import("theme/root.zig");
/// Docking: the workbench layout model.
pub const dock = @import("dock/root.zig");
/// Headless test driver.
pub const testing = @import("testing/root.zig");
/// Runs windows on a platform and renderer.
pub const host = @import("host.zig");

/// The builder view code calls.
pub const Ui = core.Ui;
/// The process-wide UI state.
pub const App = core.App;
/// One window.
pub const Window = core.Window;
/// A type-erased view.
pub const AnyView = core.AnyView;
/// Interaction flags returned by widgets.
pub const Response = core.Response;
/// Effects handle (notify/observe/emit).
pub const Context = core.Context;
/// A layout style.
pub const Style = layout.Style;
/// See `host.Host`.
pub const Host = host.Host;

test {
    std.testing.refAllDecls(@This());
    _ = @import("core/reconcile_test.zig");
    _ = @import("core/view_test.zig");
    _ = @import("layout/flex_test.zig");
    _ = @import("input/input_test.zig");
    _ = @import("widgets/controls_test.zig");
    _ = @import("paint/draw_list_test.zig");
    _ = @import("paint/scroll_layer_test.zig");
    _ = @import("paint/font_text_test.zig");
    _ = @import("host_test.zig");
    _ = @import("widgets/scroll_test.zig");
    _ = @import("widgets/text_field/text_field_test.zig");
    _ = @import("widgets/overlay_test.zig");
    _ = @import("widgets/menu_test.zig");
    _ = @import("widgets/chrome_test.zig");
    _ = @import("dock/model_test.zig");
    _ = @import("widgets/quick_pick_test.zig");
}
