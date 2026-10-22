//! AI assist inside the editor (E12.F06): inline edit by instruction,
//! streamed into a pending change.

pub const inline_edit = @import("inline_edit/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
