//! zg_security: the trust boundary of zigguro (E16). Permission engine,
//! audit log, agent sandboxes, egress control, secrets and redaction.
//!
//! `contracts` imports only `std`; consumers that need nothing else stay
//! cheap to compile (Zig analyses the other namespaces lazily). Namespaces
//! are added here as their E16 features land.

const std = @import("std");

pub const contracts = @import("contracts.zig");
pub const audit = @import("audit/root.zig");
pub const policy = @import("policy/root.zig");
pub const testing = @import("testing/fakes.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(contracts);
    std.testing.refAllDecls(testing);
}
