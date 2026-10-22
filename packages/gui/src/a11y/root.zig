//! Accessibility (E04.F09): the semantic tree derived from a window's
//! nodes, the snapshots platform bridges read, and action routing.

pub const tree = @import("tree.zig");
pub const snapshot = @import("snapshot.zig");
pub const uia = @import("uia/root.zig");

pub const A11yTree = tree.A11yTree;
pub const Snapshot = snapshot.Snapshot;
pub const Node = snapshot.Node;
pub const State = snapshot.State;
pub const Update = tree.Update;
pub const A11yEvent = tree.A11yEvent;
pub const Action = tree.Action;
pub const Arg = tree.Arg;
pub const dump = tree.dump;
