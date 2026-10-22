//! The `fonts` namespace of zg_text: instance ids and per-cluster
//! fallback. E03.F07 adds discovery, the font database and matching.

const std = @import("std");

/// Instance ids for laid-out faces.
pub const registry = @import("registry.zig");
/// Fallback chains and per-cluster resolution.
pub const fallback = @import("fallback.zig");

pub const InstanceId = registry.InstanceId;
pub const FontRegistry = registry.FontRegistry;
pub const Fallback = fallback.Fallback;
pub const ChainId = fallback.ChainId;
pub const Presentation = fallback.Presentation;

test {
    std.testing.refAllDecls(@This());
    _ = @import("fallback_test.zig");
}
