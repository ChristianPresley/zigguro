//! The task board's model (E13.F03): task files, the store and its
//! views, ids, the query language, dependencies and events.

pub const task = @import("task.zig");
pub const ids = @import("ids.zig");
pub const view = @import("view.zig");
pub const deps = @import("deps.zig");
pub const query = @import("query.zig");
pub const events = @import("events.zig");
pub const rank = @import("rank.zig");
pub const board = @import("board.zig");
pub const lease = @import("lease.zig");
pub const ClaimManager = @import("claim.zig");
pub const tools = @import("tools.zig");
pub const hooks = @import("hooks.zig");
pub const dispatch = @import("dispatch.zig");
pub const TaskStore = @import("store.zig");

pub const Task = task.Task;
pub const TaskId = task.TaskId;
pub const Status = task.Status;
pub const TasksView = view.TasksView;
pub const Query = query.Query;
pub const TaskEvent = events.TaskEvent;
pub const parseQuery = query.parseQuery;
pub const evalQuery = query.evalQuery;
pub const BoardVM = board.BoardVM;
pub const BoardMode = board.BoardMode;

test {
    _ = ids;
    _ = TaskStore;
    _ = @import("store_test.zig");
    _ = @import("query_test.zig");
    _ = @import("deps_test.zig");
    _ = rank;
    _ = @import("board_test.zig");
    _ = lease;
    _ = hooks;
    _ = dispatch;
    _ = @import("claim_test.zig");
}
