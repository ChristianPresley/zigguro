//! The editing model: ChangeSets, anchors, selections and undo.

/// ChangeSet algebra.
pub const change_set = @import("edit/change_set.zig");
/// Anchors resolved through the change log.
pub const anchor = @import("edit/anchor.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("edit/change_set_test.zig");
}
