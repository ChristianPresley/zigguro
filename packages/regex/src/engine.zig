//! The search engines and the meta engine that chooses between them.

/// Assertion evaluation.
pub const look = @import("engine/look.zig");
/// The PikeVM (captures, universal fallback).
pub const pikevm = @import("engine/pikevm.zig");
/// The lazy DFA (forward and reverse).
pub const lazy_dfa = @import("engine/lazy_dfa.zig");
/// The meta engine.
pub const meta = @import("engine/meta.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
