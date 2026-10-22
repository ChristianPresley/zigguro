//! Session retention (E10.F08.S01.T02): sessions not updated for
//! `retentionDays` are deleted with their blob sidecars, except pinned
//! sessions and the parents of sessions that are kept (a fork reads its
//! prefix from its parent). E12 is told which sessions went so it can
//! garbage-collect their checkpoints.

const std = @import("std");
const proto = @import("zg_ai_proto");
const index = @import("index.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// E12 checkpoint GC notification (stub until E12 lands).
pub const CheckpointGc = struct {
    ctx: ?*anyopaque = null,
    sessions_deleted: ?*const fn (ctx: ?*anyopaque, ids: []const proto.SessionId) void = null,

    fn notify(g: CheckpointGc, ids: []const proto.SessionId) void {
        if (g.sessions_deleted) |f| if (ids.len > 0) f(g.ctx, ids);
    }
};

pub const Options = struct {
    retention_days: u16,
    /// Unix ms; defaults to the real clock.
    now_ms: ?i64 = null,
    gc: CheckpointGc = .{},
};

/// Deletes expired sessions of `ix` and their files; returns how many
/// were deleted. The index is saved when anything changed.
pub fn sweep(ix: *index.SessionIndex, io: Io, o: Options) !u32 {
    const gpa = ix.gpa;
    const now = o.now_ms orelse Io.Timestamp.now(io, .real).toMilliseconds();
    const cutoff = now - @as(i64, o.retention_days) * std.time.ms_per_day;

    var doomed: std.ArrayList(proto.SessionId) = .empty;
    defer doomed.deinit(gpa);
    {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);
        const items = ix.entries.items;
        const del = try gpa.alloc(bool, items.len);
        defer gpa.free(del);
        for (items, del) |m, *d| d.* = m.updated_ms < cutoff and !m.pinned;
        // Keep the parent of every kept session, up the chain.
        var changed = true;
        while (changed) {
            changed = false;
            for (items, del) |m, d| {
                if (d) continue;
                const p = m.parent orelse continue;
                const pi = ix.by_id.get(p) orelse continue;
                if (del[pi]) {
                    del[pi] = false;
                    changed = true;
                }
            }
        }
        for (items, del) |m, d| if (d) try doomed.append(gpa, m.id);
    }

    for (doomed.items) |id| {
        const base = proto.agent_ref.format(id);
        const file = base ++ ".jsonl".*;
        ix.dir.deleteFile(io, &file) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        const blobs = base ++ ".blobs".*;
        ix.dir.deleteTree(io, &blobs) catch {};
        _ = ix.remove(id);
    }
    o.gc.notify(doomed.items);
    if (doomed.items.len > 0) try ix.save();
    return @intCast(doomed.items.len);
}
