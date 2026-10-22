//! Retention, compaction and blob GC of the review store
//! (E12.F01.S02.T01).
//!
//! `collect` runs with the store's lock held (`withExclusive`), after this
//! process's records are written and the other processes' are read, so it
//! sees the whole journal:
//! 1. Retention picks what stays:
//!    - changesets still open, decided within `decided_days`, or among the
//!      newest `keep_last_n`;
//!    - checkpoints that are pinned, taken within `decided_days`, or among
//!      the newest `keep_last_n`;
//!    - the `History` records after the oldest kept checkpoint and from
//!      the first apply of a kept changeset on.
//! 2. The journal is replaced by one snapshot segment: the id watermarks
//!    (so dropped ids are not handed out again), then a record per kept
//!    checkpoint, history record and changeset, and a `snapshot` record
//!    per comment thread of a kept changeset.
//! 3. The dropped changesets leave the queue with a journaled `remove`,
//!    after the snapshot, so other processes drop them too.
//! 4. Blobs that no record of the journal names are deleted, unless they
//!    were written within `blob_grace_ms`: another process may have
//!    written a blob whose record it has not appended yet.
//!
//! Other processes keep their in-memory checkpoints and history until
//! they reload; restoring a dropped checkpoint there fails on a missing
//! blob. Scheduling (daily, when idle) is the caller's: `journalSize`
//! tells when the journal is worth compacting.

const std = @import("std");
const model = @import("../model/root.zig");
const journal = @import("journal.zig");
const records = @import("records.zig");
const store_mod = @import("store.zig");
const comments = @import("../feedback/comments.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ChangesetStore = store_mod.ChangesetStore;
const BlobHash = model.BlobHash;

pub const Retention = struct {
    decided_days: u32 = 30,
    /// At least 1: the newest changeset and checkpoint always stay.
    keep_last_n: u32 = 500,
    blob_grace_ms: i64 = 10 * std.time.ms_per_min,
};

/// The live state the snapshot is taken from (all on the owner thread).
pub const Live = struct {
    q: *model.Queue,
    history: ?*model.History = null,
    checkpoints: ?model.CheckpointList = null,
    /// Threads of dropped changesets go with them.
    comments: ?*comments.CommentStore = null,
};

pub const Report = struct {
    changesets_removed: u32 = 0,
    checkpoints_removed: u32 = 0,
    applies_removed: u32 = 0,
    segments_removed: u32 = 0,
    blobs_removed: u32 = 0,
    bytes_before: u64 = 0,
    bytes_after: u64 = 0,
};

/// See the file comment. `sink` takes the other processes' records read
/// first (the store's `QueueSink` over the same queue).
pub fn collect(s: *ChangesetStore, sink: store_mod.Sink, live: Live, ret: Retention) !Report {
    var job: Job = .{ .s = s, .live = live, .ret = ret, .now_ms = nowMs(s.io) };
    defer job.dropped.deinit(s.gpa);
    job.report.bytes_before = (try s.journalSize()).bytes;
    try s.withExclusive(sink, &job, Job.run);
    // Removals go after the snapshot (higher sequence numbers), so other
    // processes do not skip them.
    for (job.dropped.items) |id| {
        live.q.remove(id);
        if (live.comments) |c| c.dropTarget(id);
    }
    try s.flush();
    job.report.bytes_after = (try s.journalSize()).bytes;
    return job.report;
}

const Job = struct {
    s: *ChangesetStore,
    live: Live,
    ret: Retention,
    now_ms: i64,
    report: Report = .{},
    dropped: std.ArrayList(model.ChangesetId) = .empty,

    fn run(j: *Job) anyerror!void {
        const gpa = j.s.gpa;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const q = j.live.q;
        const keep_n = @max(1, j.ret.keep_last_n);
        const horizon = j.now_ms - @as(i64, j.ret.decided_days) * std.time.ms_per_day;

        // 1. Retention.
        var kept_cs: std.AutoHashMapUnmanaged(model.ChangesetId, void) = .empty;
        const all = q.changesets.values();
        for (all, 0..) |cs, i| {
            const recent = i + keep_n >= all.len;
            const open = switch (cs.state) {
                .open_batch, .pending, .partially_applied => true,
                .applied, .rejected, .superseded, .discarded => false,
            };
            if (open or recent or (cs.decided_ms orelse cs.created_ms) >= horizon)
                try kept_cs.put(arena, cs.id, {})
            else
                try j.dropped.append(gpa, cs.id);
        }
        var cps: std.ArrayList(model.Checkpoint) = .empty;
        var kept_cps: std.ArrayList(model.Checkpoint) = .empty;
        var forget: std.ArrayList(u64) = .empty;
        var next_cp: u64 = 1;
        if (j.live.checkpoints) |cl| {
            try cl.list(cl.ctx, arena, &cps);
            next_cp = cl.next_id(cl.ctx);
            for (cps.items, 0..) |cp, i| {
                if (cp.pinned or i + keep_n >= cps.items.len or cp.created_ms >= horizon)
                    try kept_cps.append(arena, cp)
                else
                    try forget.append(arena, cp.id);
            }
        }
        var cutoff: u64 = 0;
        if (j.live.history) |h| {
            cutoff = h.lastId();
            for (kept_cps.items) |cp| cutoff = @min(cutoff, cp.after_apply);
            for (h.items()) |r| if (r.cs) |cs| if (kept_cs.contains(cs)) {
                cutoff = @min(cutoff, r.id - 1);
            };
        }

        // 2. The snapshot.
        var frames: std.ArrayList(u8) = .empty;
        defer frames.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const next_apply: u64 = if (j.live.history) |h| h.lastId() + 1 else 1;
        try aw.writer.print("{{\"changeset\":{d},\"apply\":{d},\"checkpoint\":{d}}}", .{ q.next_id.load(.monotonic), next_apply, next_cp });
        try j.s.frameInto(&frames, .ids, aw.written());
        for (kept_cps.items) |*cp| {
            aw.clearRetainingCapacity();
            try records.writeCheckpoint(&aw.writer, cp);
            try j.s.frameInto(&frames, .checkpoint, aw.written());
        }
        if (j.live.history) |h| for (h.items()) |*r| if (r.id > cutoff) {
            aw.clearRetainingCapacity();
            try records.writeApply(&aw.writer, r);
            try j.s.frameInto(&frames, .apply, aw.written());
        };
        for (all) |cs| if (kept_cs.contains(cs.id)) {
            aw.clearRetainingCapacity();
            try records.writeChangeset(&aw.writer, cs, j.s.blobs(), gpa);
            try j.s.frameInto(&frames, .changeset, aw.written());
            if (j.live.comments) |c| for (c.threadsOf(cs.id)) |t| {
                aw.clearRetainingCapacity();
                try comments.writeSnapshot(gpa, &aw.writer, t);
                try j.s.frameInto(&frames, .comment, aw.written());
            };
        };
        j.report.segments_removed = try j.s.replaceJournal(frames.items);

        // Memory follows the journal.
        j.report.changesets_removed = @intCast(j.dropped.items.len);
        if (j.live.checkpoints) |cl| cl.forget(cl.ctx, forget.items);
        j.report.checkpoints_removed = @intCast(forget.items.len);
        if (j.live.history) |h| j.report.applies_removed = h.dropThrough(cutoff);

        // 4. Blobs.
        var hs: Hashes = .{ .gpa = gpa };
        defer hs.keep.deinit(gpa);
        try j.s.eachSegment(&hs, Hashes.collect);
        const before: Io.Timestamp = .{ .nanoseconds = @as(i96, j.now_ms - j.ret.blob_grace_ms) * std.time.ns_per_ms };
        j.report.blobs_removed = try j.s.blobs_.sweep(&hs.keep, before);
    }
};

/// The blob hashes the journal's records name: any string of 64 hex
/// digits (a path or text that looks like one only keeps a blob longer).
const Hashes = struct {
    gpa: Allocator,
    keep: std.AutoHashMapUnmanaged(BlobHash, void) = .empty,

    fn collect(hs: *Hashes, bytes: []const u8) anyerror!void {
        var r: journal.Reader = .{ .bytes = bytes };
        while (true) {
            const fr = switch (r.next()) {
                .frame => |f| f,
                else => return,
            };
            var arena: std.heap.ArenaAllocator = .init(hs.gpa);
            defer arena.deinit();
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), fr.payload, .{}) catch continue;
            try hs.walk(v);
        }
    }

    fn walk(hs: *Hashes, v: std.json.Value) Allocator.Error!void {
        switch (v) {
            .string => |x| if (x.len == 64) {
                var h: BlobHash = undefined;
                _ = std.fmt.hexToBytes(&h, x) catch return;
                try hs.keep.put(hs.gpa, h, {});
            },
            .array => |a| for (a.items) |x| try hs.walk(x),
            .object => |o| for (o.values()) |x| try hs.walk(x),
            else => {},
        }
    }
};

fn nowMs(io: Io) i64 {
    const now = Io.Clock.real.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}
