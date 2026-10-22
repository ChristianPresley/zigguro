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
    /// Hunks and files decided by one apply, before its `applied` and
    /// `state`. The slices live only during the callback.
    decided: Decided,
    /// Decisions landed on disk (the `History` record `apply`).
    applied: struct { cs: ChangesetId, apply: u64 },
    /// Dropped from the queue (garbage collected).
    removed: ChangesetId,
};

pub const Decided = struct {
    cs: ChangesetId,
    /// The `History` record; null when nothing was written (only
    /// rejections).
    apply: ?u64,
    files: []const FileDecisions,
};

/// The decisions on one file. A file without hunks (delete, rename,
/// mode change, binary) is decided as one hunk, 0.
pub const FileDecisions = struct {
    path: []const u8,
    hunks: []const HunkDecision,
    /// The reviewer's rewrites of the `edited` hunks.
    edits: []const HunkEdit = &.{},

    pub fn count(f: FileDecisions, d: changeset.Decision) u32 {
        var n: u32 = 0;
        for (f.hunks) |h| n += @intFromBool(h.decision == d);
        return n;
    }
};

pub const HunkDecision = struct { hunk: u32, decision: changeset.Decision };

/// An edited hunk: the lines the agent proposed and what landed instead.
pub const HunkEdit = struct { hunk: u32, proposed: []const u8, user: []const u8 };

pub const Listener = struct {
    ctx: *anyopaque,
    on: *const fn (ctx: *anyopaque, ev: *const Event) void,
};

pub const ListenerId = enum(u32) { _ };
