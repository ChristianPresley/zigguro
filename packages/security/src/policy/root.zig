//! zg_security.policy: the permission engine and its parts (E16.F02).

const std = @import("std");

pub const glob = @import("glob.zig");
pub const domain = @import("domain.zig");
pub const rules = @import("rules.zig");
pub const shell = @import("shell.zig");
pub const readonly_cmds = @import("readonly_cmds.zig");
pub const taint = @import("taint.zig");

test {
    std.testing.refAllDecls(@This());
}
