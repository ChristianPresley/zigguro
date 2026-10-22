//! Emacs mode (E05.F09.S02): movement and editing keys, the mark and
//! region, the kill ring, incremental search, query replace and the
//! universal argument.

pub const kill_ring = @import("emacs/kill_ring.zig");
pub const regexp = @import("emacs/regexp.zig");
pub const isearch = @import("emacs/isearch.zig");
pub const state = @import("emacs/emacs.zig");

pub const EmacsState = state.EmacsState;

/// The Emacs keymap layer (E15 format) to load on top of the preset when
/// Emacs keys are on: the `C-x` chords and `M-x` outside the editor, and
/// the preset keys Emacs takes back.
pub const keymap_source: [:0]const u8 = @embedFile("emacs/keymap.zon");
pub const KillRing = kill_ring.KillRing;
pub const ISearch = isearch.ISearch;

test {
    @import("std").testing.refAllDecls(@This());
}
