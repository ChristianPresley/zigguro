//! The document model: buffer, edits and documents.

/// The persistent piece-tree text buffer.
pub const buffer = @import("model/buffer.zig");
/// ChangeSets, anchors, selections and undo.
pub const edit = @import("model/edit.zig");
/// Live documents.
pub const document = @import("model/document.zig");
/// Cross-thread snapshots.
pub const snapshot = @import("model/snapshot.zig");
/// The per-document change log.
pub const change_log = @import("model/change_log.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("model/snapshot_test.zig");
}
