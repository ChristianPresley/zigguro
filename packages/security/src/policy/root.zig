//! zg_security.policy: the permission engine and its parts (E16.F02).

const std = @import("std");

pub const glob = @import("glob.zig");
pub const domain = @import("domain.zig");
pub const rules = @import("rules.zig");
pub const shell = @import("shell.zig");
pub const readonly_cmds = @import("readonly_cmds.zig");
pub const taint = @import("taint.zig");
pub const managed = @import("managed.zig");
pub const token = @import("token.zig");
pub const mcp_pins = @import("mcp_pins.zig");
pub const protected = @import("protected.zig");
pub const engine = @import("engine.zig");
pub const adapters = @import("adapters.zig");

/// The permission engine.
pub const Engine = engine.Engine;

test {
    std.testing.refAllDecls(@This());
}
