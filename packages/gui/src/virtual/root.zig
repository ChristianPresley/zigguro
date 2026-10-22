//! Virtualised collections (E04.F04.S02): trees and, later, tables.

/// The `flat_tree.zig` module.
pub const flat_tree = @import("flat_tree.zig");
/// The `tree_view.zig` module.
pub const tree_view = @import("tree_view.zig");

/// See `tree_view.TreeView`.
pub const TreeView = tree_view.TreeView;
/// See `flat_tree.TreeSource`.
pub const TreeSource = flat_tree.TreeSource;
