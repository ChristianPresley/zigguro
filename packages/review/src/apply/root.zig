//! Landing review decisions (E12.F02.S03): hunk selection, the files
//! port and the applier.

pub const selection = @import("selection.zig");
pub const files = @import("files.zig");
pub const applier = @import("applier.zig");

pub const SelectionInput = selection.SelectionInput;
pub const EditedHunk = selection.EditedHunk;
pub const select = selection.select;
pub const Files = files.Files;
pub const DirFiles = files.DirFiles;
pub const MemFiles = files.MemFiles;
pub const Applier = applier.Applier;
pub const ApplyItem = applier.ApplyItem;
pub const ApplyRequest = applier.ApplyRequest;
pub const ApplyResult = applier.ApplyResult;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("applier_test.zig");
}
