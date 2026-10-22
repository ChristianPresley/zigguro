//! Queue events (E12.F01.S01.T02), delivered synchronously on the owner
//! thread in registration order. A listener must not call mutating queue
//! functions from the callback; it posts a command instead.

const ids = @import("ids.zig");
const changeset = @import("changeset.zig");

const ChangesetId = ids.ChangesetId;

pub const Event = union(enum) {
    /// A new changeset is in the queue.
    submitted: ChangesetId,
    /// Its files, hunks or provenance changed (folding, derivation).
    updated: ChangesetId,
    state: struct { cs: ChangesetId, from: changeset.State, to: changeset.State },
    /// Decisions landed on disk (the `History` record `apply`).
    applied: struct { cs: ChangesetId, apply: u64 },
    /// Dropped from the queue (garbage collected).
    removed: ChangesetId,
};

pub const Listener = struct {
    ctx: *anyopaque,
    on: *const fn (ctx: *anyopaque, ev: *const Event) void,
};

pub const ListenerId = enum(u32) { _ };
