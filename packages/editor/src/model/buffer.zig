//! The text buffer: a persistent piece B+tree over immutable buffers.

/// The piece tree's monoid summary.
pub const summary = @import("buffer/summary.zig");
/// The buffer table: original text and add pages.
pub const buffers = @import("buffer/buffers.zig");
/// Tree nodes and their pool.
pub const node_pool = @import("buffer/node_pool.zig");
/// The persistent piece tree.
pub const piece_tree = @import("buffer/piece_tree.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("buffer/piece_tree_test.zig");
}
