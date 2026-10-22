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
/// `core.excludesFile` lookup.
pub const gitconfig_excludes = @import("ignore/gitconfig_excludes.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("ignore/wildmatch_test.zig");
    _ = @import("ignore/ignore_stack_test.zig");
    _ = @import("ignore/globset_test.zig");
}
