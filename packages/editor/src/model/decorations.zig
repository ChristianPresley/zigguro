//! Decorations: annotations attached to a document's text (E05.F05).

/// The interval tree with lazy deltas.
pub const interval_tree = @import("decorations/interval_tree.zig");
/// The per-document decoration store.
pub const store = @import("decorations/store.zig");

test {
    _ = interval_tree;
    _ = @import("decorations/store_test.zig");
}
