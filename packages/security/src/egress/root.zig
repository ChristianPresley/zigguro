//! zg_security.egress: network egress control for sandboxed processes and
//! for zigguro's own network calls (E16.F05).

const std = @import("std");

/// IP address classification (RFC 6890) and CIDR opt-ins.
pub const ipclass = @import("ipclass.zig");
pub const IpClass = ipclass.IpClass;
pub const Cidr = ipclass.Cidr;

/// Egress policies compiled from domain rules.
pub const policy = @import("policy.zig");
pub const EgressPolicy = policy.EgressPolicy;
pub const Scope = policy.Scope;
pub const Verdict = policy.Verdict;

/// The proxy request-head parser.
pub const http1 = @import("http1.zig");

test {
    std.testing.refAllDecls(@This());
}
