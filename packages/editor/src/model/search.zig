//! Find and replace in a document (E05.F06).

/// Find sessions, the match index and literal search.
pub const find = @import("search/find.zig");
/// Replacement templates.
pub const replace = @import("search/replace.zig");
/// Preserve-case replacement.
pub const preserve_case = @import("search/preserve_case.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("search/find_test.zig");
    _ = @import("search/replace_test.zig");
}
