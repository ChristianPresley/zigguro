//! Decorations: annotations attached to a document's text (E05.F05).

/// The interval tree with lazy deltas.
pub const interval_tree = @import("decorations/interval_tree.zig");
/// The per-document decoration store.
pub const store = @import("decorations/store.zig");
/// Inline AI suggestions.
pub const ghost = @import("decorations/ghost.zig");
/// Agent edits shown as inline diffs with per-hunk accept/reject.
pub const pending = @import("decorations/pending.zig");

test {
    _ = interval_tree;
    _ = @import("decorations/store_test.zig");
    _ = @import("decorations/ghost_test.zig");
    _ = @import("decorations/pending_test.zig");
}
