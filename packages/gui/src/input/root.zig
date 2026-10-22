//! Input routing (E04.F03): events, hit testing and key routing.

const std = @import("std");

/// The `event.zig` module.
pub const event = @import("event.zig");
/// The `hit_test.zig` module.
pub const hit_test = @import("hit_test.zig");
/// The `keys.zig` module.
pub const keys = @import("keys.zig");

/// See `event.InputEvent`.
pub const InputEvent = event.InputEvent;
/// See `event.EventCx`.
pub const EventCx = event.EventCx;
/// See `keys.KeyHandler`.
pub const KeyHandler = keys.KeyHandler;

test {
    std.testing.refAllDecls(@This());
}
