//! The editing model: ChangeSets, anchors, selections and undo.

/// ChangeSet algebra.
pub const change_set = @import("edit/change_set.zig");
/// Anchors resolved through the change log.
pub const anchor = @import("edit/anchor.zig");
/// Carets and ranges.
pub const selection = @import("edit/selection.zig");
/// Multi-cursor commands and box selection.
pub const multi_cursor = @import("edit/multi_cursor.zig");
/// Cursor movement by unit.
pub const movement = @import("edit/movement.zig");
/// Word classes and subword boundaries for movement.
pub const word = @import("edit/word.zig");
/// The ASCII and script tailoring of word classes.
pub const word_tailoring = @import("edit/word_tailoring.zig");
/// Movement and delete commands with their ids.
pub const commands_move = @import("edit/commands_move.zig");
/// The per-selection command runner.
pub const runner = @import("edit/runner.zig");
/// The undo tree.
pub const undo = @import("edit/undo.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("edit/change_set_test.zig");
    _ = @import("edit/undo_test.zig");
    _ = @import("edit/selection_test.zig");
    _ = @import("edit/movement_test.zig");
}
