//! zg_editor: the editor core. The document model (piece-tree buffer,
//! ChangeSets, undo), find, diff and the document registry (E05).

const std = @import("std");

/// The document model.
pub const model = @import("model.zig");

test {
    std.testing.refAllDecls(@This());
}
