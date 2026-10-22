//! A checkpoint (E12.F04.S01.T01): a point in the workspace's review
//! history, taken when a user turn starts. Creating one copies nothing:
//! it records how far the apply history and the changeset ids had got,
//! and restoring reverts the applies after it from their preimages.

const std = @import("std");

pub const Checkpoint = struct {
    id: u64,
    /// The agent session (`AgentRef.session`) and agent that took it.
    session: u128,
    agent: u32 = 0,
    turn: u32,
    label: []const u8 = "",
    created_ms: i64,
    /// `History.lastId()` when it was taken: applies with a larger id
    /// came after it.
    after_apply: u64,
    /// Changesets with this id or larger were submitted after it.
    next_changeset: u64,
    /// Kept by retention whatever its age (user action).
    pinned: bool = false,
};

/// Journals new checkpoints.
pub const CheckpointRecorder = struct {
    ctx: *anyopaque,
    checkpoint: *const fn (ctx: *anyopaque, c: *const Checkpoint) void,
};

/// Takes checkpoints from the store (load or another process).
pub const CheckpointSink = struct {
    ctx: *anyopaque,
    restore: *const fn (ctx: *anyopaque, c: *const Checkpoint) anyerror!void,
    /// Ids below `next` are taken (kept by a compaction that dropped old
    /// checkpoints).
    reserve: ?*const fn (ctx: *anyopaque, next: u64) void = null,
};

/// The checkpoints as GC sees them (`checkpoint.Checkpoints.gcList`).
pub const CheckpointList = struct {
    ctx: *anyopaque,
    /// Copies of every checkpoint, oldest first; labels live as long as
    /// the list's owner.
    list: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayList(Checkpoint)) std.mem.Allocator.Error!void,
    /// Drops the checkpoints with these ids.
    forget: *const fn (ctx: *anyopaque, ids: []const u64) void,
    /// The next id it will hand out.
    next_id: *const fn (ctx: *anyopaque) u64,
};

test {
    std.testing.refAllDecls(@This());
}
