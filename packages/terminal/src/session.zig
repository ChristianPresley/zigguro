//! Terminal sessions (E06.F05): what a terminal showed, kept across
//! restarts (`persist`).

pub const persist = @import("session/persist.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("session/persist_test.zig");
}
