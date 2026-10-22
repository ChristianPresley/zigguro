//! Checkpoints and restore (E12.F04.S01.T01, E12.F04.S01.T02).
//!
//! `create` runs when an agent turn starts, on any thread, in well under
//! a millisecond: it copies no file, only records how far the apply
//! history and the changeset ids had got. The applier already keeps a
//! preimage of every file it writes.
//!
//! `restoreTo` (agent-only mode) puts the workspace back as it was at a
//! checkpoint, as far as review changed it:
//! 1. The applies after the checkpoint, of the checkpoint's session
//!    (`.session`) or of any agent (`.all_agents`), not undone, are
//!    grouped by path, oldest first.
//! 2. Each file is reverted as in `apply/revert.zig`: the applies are
//!    undone newest first, each with a three-way merge, so the user's
//!    edits on other lines survive, even those made between two agent
//!    turns. Overlaps, edited creates and user deletions are conflicts
//!    and stay as they are.
//! 3. The reverts run as one transaction (rolled back on failure) and
//!    are recorded as a `restore` in `History`.
//! 4. Changesets submitted after the checkpoint in scope that are still
//!    open are closed: pending ones `discarded`, partially applied ones
//!    `rejected`.
//! `dry_run` stops after planning and writes nothing.
//!
//! Not yet: full mode through E09 operations, redo, the untracked-changes
//! report, symlink and hard-link detection, retention and GC.

const std = @import("std");
const zg_ai_proto = @import("zg_ai_proto");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Checkpoint = model.Checkpoint;
const ChangesetId = model.ChangesetId;
const AgentRef = zg_ai_proto.AgentRef;
const log = std.log.scoped(.zg_review);

pub const Scope = enum { session, all_agents };

pub const RestoreOptions = struct {
    dry_run: bool = false,
    scope: Scope = .session,
};

pub const RestoreReport = struct {
    /// Files written or deleted (or that would be, on a dry run).
    restored: []const []const u8 = &.{},
    conflicts: []const apply.revert.Conflict = &.{},
    /// Changesets closed because they came after the checkpoint.
    discarded: []const ChangesetId = &.{},
    /// The `History` restore record, when something was written.
    record: ?u64 = null,
    /// The transaction failed and was rolled back (see `rolled_back`).
    failed: ?apply.txn.Failure = null,
};

pub const Checkpoints = struct {
    gpa: Allocator,
    io: Io,
    q: *model.Queue,
    history: *model.History,
    files: apply.Files,
    recorder: ?model.CheckpointRecorder,
    /// Guards `list`, `arena` and `next_id`: `create` runs on agent threads.
    mutex: Io.Mutex = .init,
    list: std.ArrayList(Checkpoint) = .empty,
    arena: std.heap.ArenaAllocator,
    next_id: u64 = 1,

    pub fn init(gpa: Allocator, io: Io, q: *model.Queue, history: *model.History, files: apply.Files, recorder: ?model.CheckpointRecorder) Checkpoints {
        return .{ .gpa = gpa, .io = io, .q = q, .history = history, .files = files, .recorder = recorder, .arena = .init(gpa) };
    }

    pub fn deinit(c: *Checkpoints) void {
        c.list.deinit(c.gpa);
        c.arena.deinit();
        c.* = undefined;
    }

    /// Takes a checkpoint for `origin`'s turn; any thread, never fails.
    /// Out of memory, the id is still returned but restoring it fails
    /// with `error.UnknownCheckpoint`.
    pub fn create(c: *Checkpoints, origin: AgentRef, turn: u32, label: []const u8) u64 {
        const now = Io.Clock.real.now(c.io);
        var cp: Checkpoint = .{
            .id = 0,
            .session = origin.session,
            .agent = origin.agent,
            .turn = turn,
            .created_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)),
            .after_apply = c.history.lastId(),
            .next_changeset = c.q.next_id.load(.monotonic),
        };
        c.mutex.lockUncancelable(c.io);
        cp.id = c.next_id;
        c.next_id += 1;
        const stored = c.store(cp, label);
        c.mutex.unlock(c.io);
        if (stored) |p| {
            if (c.recorder) |r| r.checkpoint(r.ctx, &p);
        } else |e| log.warn("checkpoint {d} not kept: {t}", .{ cp.id, e });
        return cp.id;
    }

    /// `create` in the shape of E10's `deps.Checkpoints.create`.
    pub fn createErased(ctx: *anyopaque, _: Io, origin: AgentRef, turn: u32, label: []const u8) u64 {
        const c: *Checkpoints = @ptrCast(@alignCast(ctx));
        return c.create(origin, turn, label);
    }

    /// The sink the store restores checkpoints through.
    pub fn sink(c: *Checkpoints) model.CheckpointSink {
        return .{ .ctx = c, .restore = sinkRestore };
    }

    fn sinkRestore(ctx: *anyopaque, cp: *const Checkpoint) anyerror!void {
        const c: *Checkpoints = @ptrCast(@alignCast(ctx));
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.list.items) |x| if (x.id == cp.id) return;
        _ = try c.store(cp.*, cp.label);
        c.next_id = @max(c.next_id, cp.id + 1);
    }

    /// Appends `cp` in id order, its label copied. Locked.
    fn store(c: *Checkpoints, cp: Checkpoint, label: []const u8) Allocator.Error!Checkpoint {
        var x = cp;
        x.label = try c.arena.allocator().dupe(u8, label);
        var i = c.list.items.len;
        while (i > 0 and c.list.items[i - 1].id > x.id) i -= 1;
        try c.list.insert(c.gpa, i, x);
        return x;
    }

    /// A copy of checkpoint `id` (its label lives as long as `c`).
    pub fn get(c: *Checkpoints, id: u64) ?Checkpoint {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.list.items) |x| if (x.id == id) return x;
        return null;
    }

    /// The checkpoints of `session`, oldest first.
    pub fn listSession(c: *Checkpoints, session: u128, out: *std.ArrayList(Checkpoint), gpa: Allocator) Allocator.Error!void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.list.items) |x| if (x.session == session) try out.append(gpa, x);
    }

    /// Changesets submitted after checkpoint `id` in `scope`, in id order.
    /// Owner thread.
    pub fn changesetsSince(c: *Checkpoints, id: u64, scope: Scope, out: *std.ArrayList(ChangesetId), gpa: Allocator) !void {
        const cp = c.get(id) orelse return error.UnknownCheckpoint;
        for (c.q.changesets.values()) |cs| {
            if (@intFromEnum(cs.id) < cp.next_changeset) continue;
            if (!inScope(cp, scope, if (cs.prov.origin.agentRef()) |r| r.session else null)) continue;
            try out.append(gpa, cs.id);
        }
    }

    /// Restores checkpoint `id` (see the file comment); owner thread.
    /// The report is allocated in `arena`.
    pub fn restoreTo(c: *Checkpoints, arena: Allocator, id: u64, o: RestoreOptions) anyerror!RestoreReport {
        const cp = c.get(id) orelse return error.UnknownCheckpoint;

        // 1. What review changed since, per path, oldest first.
        var steps: std.StringArrayHashMapUnmanaged(std.ArrayList(apply.revert.Step)) = .empty;
        for (c.history.items()) |r| {
            if (r.kind != .apply or r.id <= cp.after_apply or c.history.undone(r.id)) continue;
            if (!inScope(cp, o.scope, r.session)) continue;
            for (r.files) |f| {
                const gop = try steps.getOrPut(arena, f.path);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(arena, .{ .pre = f.pre, .pre_exec = f.pre_exec, .post = f.post, .post_exec = f.post_exec });
            }
        }
        const targets = try arena.alloc(apply.revert.Target, steps.count());
        for (steps.keys(), steps.values(), targets) |path, list, *tg| tg.* = .{ .path = path, .steps = list.items };

        // 2. The reverts.
        var t: apply.txn.Txn = .init(arena, c.files);
        const p = try apply.revert.plan(c.gpa, c.q.blobs, &t, targets);
        var report: RestoreReport = .{ .restored = p.reverted, .conflicts = p.conflicts };
        var discard: std.ArrayList(ChangesetId) = .empty;
        try c.changesetsSince(id, o.scope, &discard, arena);
        var closed: std.ArrayList(ChangesetId) = .empty;
        for (discard.items) |cid| {
            const s = c.q.get(cid).?.state;
            if (s == .pending or s == .partially_applied) try closed.append(arena, cid);
        }
        report.discarded = closed.items;
        if (o.dry_run) return report;

        // 3. Write, record.
        if (t.ops.items.len > 0) {
            try t.saveImages(c.q.blobs);
            if (t.run()) |f| {
                report.failed = f;
                report.discarded = &.{};
                return report;
            }
            report.record = try c.history.record(.{
                .kind = .restore,
                .cs = null,
                .session = cp.session,
                .created_ms = nowMs(c.io),
                .files = try t.records(),
            });
        }

        // 4. Close what came after.
        for (closed.items) |cid| {
            const cs = c.q.getMut(cid).?;
            const from = cs.state;
            try model.transition(cs, if (from == .pending) .discarded else .rejected);
            cs.decided_ms = nowMs(c.io);
            c.q.persist(cid);
            c.q.emit(.{ .state = .{ .cs = cid, .from = from, .to = cs.state } });
        }
        return report;
    }
};

fn inScope(cp: Checkpoint, scope: Scope, session: ?u128) bool {
    const s = session orelse return false;
    return scope == .all_agents or s == cp.session;
}

fn nowMs(io: Io) i64 {
    const now = Io.Clock.real.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}
