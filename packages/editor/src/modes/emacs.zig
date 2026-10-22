//! Emacs mode (E05.F09.S02): movement and editing keys, the mark and
//! region, the kill ring, incremental search, query replace and the
//! universal argument.

pub const kill_ring = @import("emacs/kill_ring.zig");
pub const regexp = @import("emacs/regexp.zig");
pub const isearch = @import("emacs/isearch.zig");
pub const state = @import("emacs/emacs.zig");

pub const EmacsState = state.EmacsState;
pub const KillRing = kill_ring.KillRing;
pub const ISearch = isearch.ISearch;

test {
    @import("std").testing.refAllDecls(@This());
}
