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
};

test {
    std.testing.refAllDecls(@This());
}
