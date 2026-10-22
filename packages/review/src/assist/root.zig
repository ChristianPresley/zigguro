//! AI assist inside the editor: inline edit by instruction, streamed
//! into a pending change (E12.F06), and ghost-text completion (E12.F07).

pub const inline_edit = @import("inline_edit/root.zig");
pub const complete = @import("complete/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
