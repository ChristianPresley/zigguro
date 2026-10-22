//! Keeping pending changes valid when the files under them move (E12.F02.S02)
//! and when other pending changes land first (E12.F02.S04).

pub const closed_file = @import("closed_file.zig");
pub const conflict_index = @import("conflict_index.zig");

pub const rebaseFile = closed_file.rebaseFile;
pub const RebaseOutcome = closed_file.RebaseOutcome;
pub const ConflictIndex = conflict_index.ConflictIndex;
pub const ConflictPair = conflict_index.ConflictPair;
pub const ConflictKind = conflict_index.ConflictKind;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("conflict_index_test.zig");
}
