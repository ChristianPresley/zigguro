//! zg_workspace: the workspace model, path store, ignore stack, scanner and
//! background indexer (E08). Headless: usable from apps/zg and agents.

const std = @import("std");
const zg_core = @import("zg_core");

/// git-compatible ignore matching (the std-only `zg_ignore` module).
pub const ignore = @import("zg_ignore");
/// Identifier types.
pub const RootId = @import("ids.zig").RootId;
/// A path-store node id.
pub const FileId = @import("ids.zig").FileId;
/// Every ignore source of a workspace with git's precedence.
pub const IgnoreStack = @import("ignore/ignore_stack.zig").IgnoreStack;
/// The answer to an ignore query.
pub const Verdict = @import("ignore/ignore_stack.zig").Verdict;
/// Watcher filter adapter (the E01 `IgnoreFilter` shape).
pub const WatchFilter = @import("ignore/ignore_stack.zig").WatchFilter;
/// The interned path tree.
pub const paths = @import("paths/path_store.zig");
/// The interned path tree (writer side).
pub const PathStore = paths.PathStore;
/// An immutable view of the path tree.
pub const Snapshot = paths.Snapshot;
/// The workspace model.
pub const model = @import("model/workspace.zig");
/// An open workspace.
pub const Workspace = model.Workspace;
/// Session state capture and restore.
pub const session = @import("model/session.zig");
/// Workspace events and the listener bus.
pub const events = @import("scan/events.zig");
/// An event from the workspace.
pub const WorkspaceEvent = events.WorkspaceEvent;
/// The workspace file (`.zigguro/workspace.zon`).
pub const workspace_file = @import("model/workspace_file.zig");
/// Per-workspace storage and the global state directory.
pub const storage = @import("model/storage.zig");
/// Frecency-ranked recents.
pub const recents = @import("model/recents.zig");
/// `core.excludesFile` lookup.
pub const gitconfig_excludes = @import("ignore/gitconfig_excludes.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("ignore/wildmatch_test.zig");
    _ = @import("ignore/ignore_stack_test.zig");
    _ = @import("ignore/globset_test.zig");
    _ = @import("paths/path_store_test.zig");
}
