//! zg_review: review before apply (E12). Every machine-made change to the
//! workspace becomes a `Changeset` that a human accepts, rejects or edits
//! before it lands. This module is the headless core: no GPU or GUI code.
//! See `docs/model.md` and the E12 epic issue.

/// Changesets, file changes, hunks, provenance and their state machines.
pub const model = @import("model/root.zig");
/// The journal and blob store under `.zigguro/review/`.
pub const store = @import("store/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
