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
/// Indentation units, guessing and auto-indent rules.
pub const indent = @import("edit/indent.zig");
/// Auto-closing pairs and token context.
pub const pairs = @import("edit/pairs.zig");
/// Line and block comment toggles.
pub const comment = @import("edit/comment.zig");
/// Smart typing: typeChar, newline, deleteLeft.
pub const smart_edit = @import("edit/smart_edit.zig");
/// Line operations: move, duplicate, sort, join, case, indent.
pub const line_ops = @import("edit/line_ops.zig");
/// Multi-cursor copy, cut and paste.
pub const clipboard = @import("edit/clipboard.zig");
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
    _ = @import("edit/smart_edit_test.zig");
    _ = @import("edit/line_ops_test.zig");
}
