//! zg_review: review before apply (E12). Every machine-made change to the
//! workspace becomes a `Changeset` that a human accepts, rejects or edits
//! before it lands. This module is the headless core: no GPU or GUI code.
//! See `docs/model.md` and the E12 epic issue.

/// Changesets, file changes, hunks, provenance and their state machines.
pub const model = @import("model/root.zig");
/// The journal and blob store under `.zigguro/review/`.
pub const store = @import("store/root.zig");
/// Hunk selection and the transactional applier.
pub const apply = @import("apply/root.zig");
/// Turn checkpoints and restore.
pub const checkpoint = @import("checkpoint/root.zig");
pub const policy = @import("policy/root.zig");
/// Rebasing pending changes; conflicts between pending changesets.
pub const rebase = @import("rebase/root.zig");
/// Views of the workspace with pending changes taken (read your own).
pub const overlay = @import("overlay/root.zig");
/// The review queue's rows, filters and counts.
pub const queue_view = @import("queue_view/root.zig");
/// The approvals inbox: E16's approval tickets, answered from any view.
pub const approvals = @import("approvals/root.zig");
/// Reviewing hunk by hunk: cursor, decisions and their undo.
pub const session = @import("session/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
