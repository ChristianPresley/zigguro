//! The Linux AT-SPI2 bridge (E04.F09.S01.T03), over zg_platform's D-Bus
//! client.

pub const bridge = @import("bridge.zig");
pub const ifaces = @import("ifaces.zig");
pub const objects = @import("objects.zig");
pub const roles = @import("roles.zig");
pub const states = @import("states.zig");
pub const events = @import("events.zig");
pub const introspect = @import("introspect.zig");

pub const Bridge = bridge.Bridge;
pub const Options = bridge.Options;

test {
    _ = objects;
}
