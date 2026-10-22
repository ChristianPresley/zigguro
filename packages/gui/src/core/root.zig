//! The core UI runtime (E04.F01).

const std = @import("std");

/// The `geom.zig` module.
pub const geom = @import("geom.zig");
/// The `ids.zig` module.
pub const ids = @import("ids.zig");
/// The `hash.zig` module.
pub const hash = @import("hash.zig");
/// The `widget.zig` module.
pub const widget = @import("widget.zig");
/// The `node_store.zig` module.
pub const node_store = @import("node_store.zig");
/// The `response.zig` module.
pub const response = @import("response.zig");
/// The `view.zig` module.
pub const view = @import("view.zig");
/// The `app.zig` module.
pub const app = @import("app.zig");
/// The `ui.zig` module.
pub const ui = @import("ui.zig");
/// The `window.zig` module.
pub const window = @import("window.zig");
/// The `damage.zig` module.
pub const damage = @import("damage.zig");

/// See `geom.Rect`.
pub const Rect = geom.Rect;
/// See `geom.Vec2`.
pub const Vec2 = geom.Vec2;
/// See `geom.Size`.
pub const Size = geom.Size;
/// See `geom.Color`.
pub const Color = geom.Color;
/// See `ids.NodeId`.
pub const NodeId = ids.NodeId;
/// See `ui.Ui`.
pub const Ui = ui.Ui;
/// See `ui.BoxDesc`.
pub const BoxDesc = ui.BoxDesc;
/// See `app.App`.
pub const App = app.App;
/// See `app.Context`.
pub const Context = app.Context;
/// See `window.Window`.
pub const Window = window.Window;
/// See `view.AnyView`.
pub const AnyView = view.AnyView;
/// See `view.Entity`.
pub const Entity = view.Entity;
/// See `view.EntityId`.
pub const EntityId = view.EntityId;
/// See `response.Response`.
pub const Response = response.Response;

test {
    std.testing.refAllDecls(@This());
}
