//! The terminal service for agents (E06.F07): commands an agent runs in
//! an interactive shell, bound to the command blocks shell integration
//! reports.

pub const run = @import("agent/run.zig");
pub const Run = run.Run;
pub const Readiness = run.Readiness;
pub const readiness = run.readiness;
pub const commandBytes = run.commandBytes;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("agent/run_test.zig");
}
