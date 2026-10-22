//! zg_editor: the editor core. The document model (piece-tree buffer,
//! ChangeSets, undo), find, diff and the document registry (E05), and the
//! editor view widget on zg_gui.

const std = @import("std");

/// The document model.
pub const model = @import("model.zig");
/// The editor view and widget.
pub const view = @import("view/root.zig");

test {
    std.testing.refAllDecls(@This());
}
