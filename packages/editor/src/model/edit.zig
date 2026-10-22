//! The editing model: ChangeSets, anchors, selections and undo.

/// ChangeSet algebra.
pub const change_set = @import("edit/change_set.zig");
/// Anchors resolved through the change log.
pub const anchor = @import("edit/anchor.zig");
/// Carets and ranges.
pub const selection = @import("edit/selection.zig");
/// Multi-cursor commands and box selection.
pub const multi_cursor = @import("edit/multi_cursor.zig");
/// The per-selection command runner.
pub const runner = @import("edit/runner.zig");
/// The undo tree.
pub const undo = @import("edit/undo.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("edit/change_set_test.zig");
    _ = @import("edit/undo_test.zig");
    _ = @import("edit/selection_test.zig");
}
