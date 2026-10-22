//! The document model: buffer, edits and documents.

/// The persistent piece-tree text buffer.
pub const buffer = @import("model/buffer.zig");
/// ChangeSets, anchors, selections and undo.
pub const edit = @import("model/edit.zig");
/// Line and token diffs.
pub const diff = @import("model/diff.zig");
/// Find and replace.
pub const search = @import("model/search.zig");
/// Live documents.
pub const document = @import("model/document.zig");
/// Cross-thread snapshots.
pub const snapshot = @import("model/snapshot.zig");
/// Highlighting and structure for documents.
pub const syntax = @import("model/syntax.zig");
/// Decorations: diagnostics, find matches, ghost text, pending edits.
pub const decorations = @import("model/decorations.zig");
/// The document registry and LSP sync.
pub const api = @import("model/api.zig");
/// The per-document change log.
pub const change_log = @import("model/change_log.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("model/snapshot_test.zig");
}
