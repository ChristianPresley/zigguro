//! `ReviewGlue`: E12 review under the workbench agent (E10 ↔ E12).
//!
//! - Agent writes to files that are not open in the editor still go to
//!   disk through zg_ai's `DiskFiles`, but each one is recorded in
//!   zg_review's `History`, with the content before and after, under the
//!   agent's session. Edits to open documents land in the editor's buffer
//!   as one undo step (`EditorFiles`) and are not recorded yet.
//! - `checkpoints` is E10's `deps.Checkpoints`: the agent loop takes one
//!   at the start of every user turn.
//! - `restore` is the `CheckpointRestore` of E10's rewind: the files the
//!   session's agents wrote since the checkpoint go back, keeping the
//!   user's edits on other lines. Files where they overlap are skipped,
//!   with the reason.
//!
//! - Each turn's writes become one changeset in the review queue when the
//!   turn ends (`end_turn`), already applied and marked auto-applied, so
//!   the review panel lists what every turn changed (`model`).
//!
//! Proposals are still applied as soon as the tool's approval passed;
//! holding them in the review queue (`Outcome.pending`) waits for a review
//! mode setting. Contents live in memory for the app's run, like the agent
//! sessions; the durable store comes with saved sessions.
//!
//! Agent tasks and rewind call in from any thread: `mutex` serializes the
//! recording and the restore, and owns the queue and the history.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_ai_proto = zg_ai.proto;
const zg_review = @import("zg_review");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const zfiles = zg_ai.tools.builtin.files;
const DiskFiles = zg_ai.tools.builtin.disk_files.DiskFiles;
const rewind = zg_ai.session.rewind;
const model = zg_review.model;
const Checkpoints = zg_review.checkpoint.Checkpoints;
const log = std.log.scoped(.agent);

/// See the module doc.
pub const ReviewGlue = struct {
    gpa: Allocator,
    io: Io,
    /// Absolute and normalized; borrowed.
    root: []const u8,
    dir: Io.Dir,
    disk: DiskFiles,
    workspace: zg_review.apply.DirFiles,
    blobs: model.MemBlobs,
    history: model.History,
    q: *model.Queue,
    cps: Checkpoints,
    /// Accept, reject and undo from the review panel.
    applier: zg_review.apply.Applier,
    /// The review panel's rows (read under `mutex`).
    model: *zg_review.queue_view.QueueModel,
    /// What each running turn wrote: the content before its first write.
    turns: std.ArrayList(Turn) = .empty,
    /// Called after a turn's changeset is in the queue, on the agent's
    /// task (the panel posts a repaint).
    on_change: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
    mutex: Io.Mutex = .init,

    const Turn = struct {
        agent: zg_ai_proto.AgentRef,
        turn: u32,
        /// Path → content before the turn's first write (null: none).
        before: std.StringArrayHashMapUnmanaged(?zg_review.apply.files.Entry) = .empty,
        /// The history records of its writes, folded into the
        /// changeset's apply at the end.
        writes: std.ArrayList(u64) = .empty,
        arena: std.heap.ArenaAllocator,
    };

    /// Review of the workspace at `root` (absolute, normalized).
    pub fn create(gpa: Allocator, io: Io, root: []const u8) !*ReviewGlue {
        const g = try gpa.create(ReviewGlue);
        errdefer gpa.destroy(g);
        g.* = .{
            .gpa = gpa,
            .io = io,
            .root = root,
            .dir = try Io.Dir.cwd().openDir(io, root, .{}),
            .disk = .{ .root = root },
            .workspace = undefined,
            .blobs = .init(gpa),
            .history = .init(gpa, null),
            .q = undefined,
            .cps = undefined,
            .applier = undefined,
            .model = undefined,
        };
        errdefer g.dir.close(io);
        g.workspace = .{ .dir = g.dir, .io = io };
        g.q = try model.Queue.init(gpa, io, .{ .root = root, .blobs = g.blobs.blobs() });
        g.cps = .init(gpa, io, g.q, &g.history, g.workspace.files(), null);
        g.applier = .init(gpa, io, g.q, g.workspace.files(), &g.history);
        g.model = try zg_review.queue_view.QueueModel.init(gpa, g.q, .{});
        return g;
    }

    /// No agent may still be running.
    pub fn destroy(g: *ReviewGlue) void {
        const gpa = g.gpa;
        for (g.turns.items) |*t| t.arena.deinit();
        g.turns.deinit(gpa);
        g.model.deinit();
        g.cps.deinit();
        g.q.deinit();
        g.history.deinit();
        g.blobs.deinit();
        g.dir.close(g.io);
        gpa.destroy(g);
    }

    /// The `Files` for paths not open in the editor (`EditorFiles.outside`).
    pub fn files(g: *ReviewGlue) zfiles.Files {
        return .{ .ctx = g, .vtable = &.{ .resolve = resolve, .kind = kind, .read = read, .propose = propose, .end_turn = endTurn } };
    }

    /// E10's `deps.Checkpoints`.
    pub fn checkpoints(g: *ReviewGlue) zg_ai.loop.deps.Checkpoints {
        return .{ .ctx = &g.cps, .create = Checkpoints.createErased };
    }

    /// E10 rewind's `CheckpointRestore`.
    pub fn restore(g: *ReviewGlue) rewind.CheckpointRestore {
        return .{ .ctx = g, .restore_to = restoreTo };
    }

    fn cast(ctx: *anyopaque) *ReviewGlue {
        return @ptrCast(@alignCast(ctx));
    }

    fn diskFiles(g: *ReviewGlue) zfiles.Files {
        return g.disk.asFiles();
    }

    fn resolve(ctx: *anyopaque, io: Io, arena: Allocator, path: []const u8) Allocator.Error!zfiles.Resolved {
        const d = cast(ctx).diskFiles();
        return d.vtable.resolve(d.ctx, io, arena, path);
    }

    fn kind(ctx: *anyopaque, io: Io, abs: []const u8) zfiles.Kind {
        const d = cast(ctx).diskFiles();
        return d.vtable.kind(d.ctx, io, abs);
    }

    fn read(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, max_bytes: usize) anyerror!zfiles.Read {
        const d = cast(ctx).diskFiles();
        return d.vtable.read(d.ctx, io, arena, abs, max_bytes);
    }

    /// Writes through `DiskFiles` and records what changed.
    fn propose(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, p: zfiles.Proposal, origin: zfiles.Origin) anyerror!zfiles.Outcome {
        const g = cast(ctx);
        const d = g.diskFiles();
        const rel = g.relative(arena, abs) orelse return d.vtable.propose(d.ctx, io, arena, abs, p, origin);
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        const ws = g.workspace.files();
        const before = try ws.read(arena, rel);
        const out = try d.vtable.propose(d.ctx, io, arena, abs, p, origin);
        if (out != .applied) return out;
        // The write landed: a failure to record it must not fail the tool.
        const rec = g.record(arena, rel, before, origin.agent) catch |e| blk: {
            log.warn("{s}: agent write not recorded for restore: {t}", .{ rel, e });
            break :blk null;
        };
        g.noteTurn(rel, before, origin, rec) catch |e| log.warn("{s}: agent write not recorded for review: {t}", .{ rel, e });
        return out;
    }

    /// Remembers what `rel` held before the turn's first write. Locked.
    fn noteTurn(g: *ReviewGlue, rel: []const u8, before: ?zg_review.apply.files.Entry, origin: zfiles.Origin, rec: ?u64) !void {
        const t = for (g.turns.items) |*t| {
            if (std.meta.eql(t.agent.session, origin.agent.session) and t.agent.agent == origin.agent.agent and t.turn == origin.turn) break t;
        } else blk: {
            try g.turns.append(g.gpa, .{ .agent = .{ .session = origin.agent.session, .agent = origin.agent.agent }, .turn = origin.turn, .arena = .init(g.gpa) });
            break :blk &g.turns.items[g.turns.items.len - 1];
        };
        const a = t.arena.allocator();
        if (rec) |id| try t.writes.append(a, id);
        if (t.before.contains(rel)) return;
        const copy: ?zg_review.apply.files.Entry = if (before) |b| .{ .bytes = try a.dupe(u8, b.bytes), .executable = b.executable } else null;
        try t.before.put(a, try a.dupe(u8, rel), copy);
    }

    /// E10's `Files.end_turn`: the turn's writes become one changeset,
    /// applied and marked auto-applied. Null when the turn wrote nothing.
    fn endTurn(ctx: *anyopaque, io: Io, agent: zg_ai_proto.AgentRef, turn: u32) anyerror!?u64 {
        const g = cast(ctx);
        const id = blk: {
            g.mutex.lockUncancelable(io);
            defer g.mutex.unlock(io);
            const i = for (g.turns.items, 0..) |t, i| {
                if (t.agent.session == agent.session and t.agent.agent == agent.agent and t.turn == turn) break i;
            } else return null;
            var t = g.turns.swapRemove(i);
            defer t.arena.deinit();
            break :blk try g.submitTurn(&t) orelse return null;
        };
        if (g.on_change) |h| h.f(h.ctx);
        return @intFromEnum(id);
    }

    /// Queues `t`'s changes as an applied changeset. Locked.
    fn submitTurn(g: *ReviewGlue, t: *Turn) !?model.ChangesetId {
        var arena_state: std.heap.ArenaAllocator = .init(g.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const label = try std.fmt.allocPrint(arena, "Turn {d}", .{t.turn});
        const b = try g.q.beginBatch(.{
            .origin = .{ .agent = .{ .ref = t.agent, .turn = t.turn, .model = "" } },
            .label = label,
            .workspace = g.root,
            .created_ms = nowMs(g.io),
        });
        var n: usize = 0;
        var landed: std.ArrayList(model.ApplyFile) = .empty;
        for (t.before.keys(), t.before.values()) |path, before| {
            const after = try g.workspace.files().read(arena, path);
            if (before == null and after == null) continue;
            if (before != null and after != null and std.mem.eql(u8, before.?.bytes, after.?.bytes) and before.?.executable == after.?.executable) continue;
            if (after) |x| _ = try g.blobs.blobs().put(x.bytes);
            try landed.append(arena, .{
                .path = path,
                .pre = if (before) |x| model.blobHash(x.bytes) else null,
                .post = if (after) |x| model.blobHash(x.bytes) else null,
                .pre_exec = if (before) |x| x.executable else false,
                .post_exec = if (after) |x| x.executable else false,
            });
            if (before == null) {
                try g.q.addCreate(b, path, after.?.bytes);
            } else if (after == null) {
                try g.q.addDelete(b, path, before.?.bytes);
            } else {
                var e = try model.merge3.lineChangeSet(g.gpa, before.?.bytes, after.?.bytes);
                defer e.deinit();
                try g.q.addEdit(b, path, before.?.bytes, null, &e);
            }
            n += 1;
        }
        if (n == 0) {
            g.q.abortBatch(b);
            return null;
        }
        const id = try g.q.commitBatch(b, .{});
        const cs = g.q.getMut(id) orelse return id;
        for (cs.files) |*f| {
            for (f.hunks) |*h| h.decision = .accepted;
            if (f.state == .pending) try model.fileTransition(f, .applied);
        }
        const from = cs.state;
        if (from == .pending) try model.transition(cs, .applied);
        cs.auto_applied = true;
        cs.decided_ms = nowMs(g.io);
        // The turn's write records become this changeset's apply, so the
        // panel can undo it (and a restore reverts it as one).
        _ = try g.history.fold(t.writes.items, .{ .cs = id, .session = t.agent.session, .created_ms = cs.decided_ms.?, .files = landed.items });
        g.q.persist(id);
        g.q.emit(.{ .state = .{ .cs = id, .from = from, .to = cs.state } });
        return id;
    }

    /// Records the write of `rel` (whose content was `before`); null when
    /// nothing changed. Locked.
    fn record(g: *ReviewGlue, arena: Allocator, rel: []const u8, before: ?zg_review.apply.files.Entry, agent: zg_ai_proto.AgentRef) !?u64 {
        const after = try g.workspace.files().read(arena, rel);
        const b = g.blobs.blobs();
        if (before) |x| _ = try b.put(x.bytes);
        if (after) |x| _ = try b.put(x.bytes);
        const f: model.ApplyFile = .{
            .path = rel,
            .pre = if (before) |x| model.blobHash(x.bytes) else null,
            .post = if (after) |x| model.blobHash(x.bytes) else null,
            .pre_exec = if (before) |x| x.executable else false,
            .post_exec = if (after) |x| x.executable else false,
        };
        if (std.meta.eql(f.pre, f.post) and f.pre_exec == f.post_exec) return null;
        return try g.history.record(.{
            .cs = null,
            .session = agent.session,
            .created_ms = nowMs(g.io),
            .files = &.{f},
        });
    }

    /// What the review panel can do to a changeset.
    pub const Action = enum {
        /// Applies what is still open.
        accept,
        /// Rejects what is still open; nothing is written.
        reject,
        /// Reverts the changeset's last apply and reopens its changes
        /// for review.
        undo,
    };

    pub const ActionResult = union(enum) {
        ok,
        /// Nothing was written. `path` (in the caller's arena) changed
        /// since on the same lines, or the action does not fit the
        /// changeset's state (`path` empty).
        refused: struct { path: []const u8, reason: []const u8 },
        /// A write failed (rolled back when possible).
        failed: struct { path: []const u8, err: anyerror },
    };

    /// Runs `act` on changeset `cs`; the caller holds `mutex` (the panel
    /// builds under it). UI thread.
    pub fn actLocked(g: *ReviewGlue, arena: Allocator, cs: model.ChangesetId, act: Action) anyerror!ActionResult {
        const c = g.q.getMut(cs) orelse return .{ .refused = .{ .path = "", .reason = "it is gone" } };
        switch (act) {
            .accept, .reject => {
                if (c.state != .pending and c.state != .partially_applied) return .{ .refused = .{ .path = "", .reason = "it is not open" } };
                const r = if (act == .accept) try g.applier.acceptAll(cs) else blk: {
                    var items: std.ArrayList(zg_review.apply.ApplyItem) = .empty;
                    for (c.files, 0..) |f, i| if (f.state == .pending or f.state == .partially_applied)
                        try items.append(arena, .{ .file = @intCast(i), .whole_file = .reject });
                    break :blk try g.applier.apply(.{ .cs = cs, .items = items.items });
                };
                return switch (r) {
                    .ok => .ok,
                    .failed => |f| .{ .failed = .{ .path = try arena.dupe(u8, f.path), .err = f.err } },
                };
            },
            .undo => {
                const rec = g.history.lastApplyOf(cs) orelse return .{ .refused = .{ .path = "", .reason = "nothing of it is applied" } };
                switch (try g.applier.undoApply(arena, rec.id)) {
                    .ok => {},
                    .conflicts => |cf| return .{ .refused = .{ .path = cf[0].path, .reason = switch (cf[0].kind) {
                        .user_edit_overlaps => "changed since on the same lines",
                        .file_deleted_by_user => "deleted since",
                        .target_exists => "a file is now where it was deleted",
                    } } },
                    .failed => |f| return .{ .failed = .{ .path = f.path, .err = f.err } },
                }
                // It is back for review.
                const back = g.q.getMut(cs).?;
                back.auto_applied = false;
                g.q.persist(cs);
                g.q.emit(.{ .updated = cs });
                return .ok;
            },
        }
    }

    /// `abs` relative to the root, `/`-separated; null outside it.
    fn relative(g: *const ReviewGlue, arena: Allocator, abs: []const u8) ?[]const u8 {
        if (abs.len <= g.root.len + 1 or !std.mem.startsWith(u8, abs, g.root) or !std.fs.path.isSep(abs[g.root.len])) return null;
        const rel = arena.dupe(u8, abs[g.root.len + 1 ..]) catch return null;
        std.mem.replaceScalar(u8, rel, '\\', '/');
        return rel;
    }

    fn restoreTo(ctx: *anyopaque, io: Io, arena: Allocator, checkpoint: u64) anyerror!rewind.RestoreOutcome {
        const g = cast(ctx);
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        const r = try g.cps.restoreTo(arena, checkpoint, .{});
        if (r.failed) |f| {
            log.warn("restore of checkpoint {d} failed at {s}: {t}{s}", .{ checkpoint, f.path, f.err, if (f.rolled_back) "" else " (not rolled back)" });
            return f.err;
        }
        const skipped = try arena.alloc(rewind.SkipReason, r.conflicts.len);
        for (r.conflicts, skipped) |c, *s| s.* = .{ .path = c.path, .reason = switch (c.kind) {
            .user_edit_overlaps => "changed since on the same lines",
            .file_deleted_by_user => "deleted since",
            .target_exists => "a file was created where the agent had deleted one",
        } };
        return .{ .restored_files = r.restored, .skipped = skipped };
    }
};

fn nowMs(io: Io) i64 {
    const now = Io.Clock.real.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const s1: zg_ai_proto.AgentRef = .{ .session = 0x51 };
const s2: zg_ai_proto.AgentRef = .{ .session = 0x52 };

fn edit(fs: zfiles.Files, arena: Allocator, path: []const u8, agent: zg_ai_proto.AgentRef, p: zfiles.Proposal) !zfiles.Outcome {
    const abs = (try fs.resolve(testing.io, arena, path)).abs;
    return fs.propose(testing.io, arena, abs, p, .{ .agent = agent, .tool = "edit_file", .tool_call_id = "t" });
}

test "review glue: agent writes are recorded and a checkpoint restore keeps the user's edits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\n.\ntwo\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "x\n" });

    const g = try ReviewGlue.create(testing.allocator, testing.io, root);
    defer g.destroy();
    const fs = g.files();
    const cps = g.checkpoints();
    const cp = cps.create(cps.ctx, testing.io, s1, 1, "turn 1");

    // The agent edits a.txt and b.txt and creates c/new.txt.
    try testing.expect(try edit(fs, arena, "a.txt", s1, .{ .str_replace = .{ .old = "two", .new = "TWO" } }) == .applied);
    try testing.expect(try edit(fs, arena, "b.txt", s1, .{ .str_replace = .{ .old = "x", .new = "y" } }) == .applied);
    try testing.expect(try edit(fs, arena, "c/new.txt", s1, .{ .create = .{ .text = "new\n" } }) == .applied);
    // A rejected proposal records nothing.
    try testing.expect(try edit(fs, arena, "a.txt", s1, .{ .str_replace = .{ .old = "nowhere", .new = "x" } }) == .rejected);
    try testing.expectEqual(@as(usize, 3), g.history.items().len);
    try testing.expectEqualStrings("c/new.txt", g.history.items()[2].files[0].path);

    // The user edits other lines of a.txt and the line the agent changed in b.txt.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "ONE\n.\nTWO\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "z\n" });

    const rs = g.restore();
    const out = try rs.restore_to(rs.ctx, testing.io, arena, cp);
    try testing.expectEqual(@as(usize, 2), out.restored_files.len);
    try testing.expectEqual(@as(usize, 1), out.skipped.len);
    try testing.expectEqualStrings("b.txt", out.skipped[0].path);
    const a = try tmp.dir.readFileAlloc(testing.io, "a.txt", arena, .limited(64));
    try testing.expectEqualStrings("ONE\n.\ntwo\n", a);
    const b = try tmp.dir.readFileAlloc(testing.io, "b.txt", arena, .limited(64));
    try testing.expectEqualStrings("z\n", b);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "c/new.txt", .{}));

    // Another session's writes are not this session's to restore.
    const cp2 = cps.create(cps.ctx, testing.io, s1, 2, "turn 2");
    try testing.expect(try edit(fs, arena, "a.txt", s2, .{ .str_replace = .{ .old = "ONE", .new = "1" } }) == .applied);
    const out2 = try rs.restore_to(rs.ctx, testing.io, arena, cp2);
    try testing.expectEqual(@as(usize, 0), out2.restored_files.len);
    try testing.expectError(error.UnknownCheckpoint, rs.restore_to(rs.ctx, testing.io, arena, 99));
}

test "review glue: a turn's writes become one auto-applied changeset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });

    const g = try ReviewGlue.create(testing.allocator, testing.io, root);
    defer g.destroy();
    const fs = g.files();
    const in_turn = struct {
        fn edit(f: zfiles.Files, ar: Allocator, path: []const u8, turn: u32, p: zfiles.Proposal) !zfiles.Outcome {
            const abs = (try f.resolve(testing.io, ar, path)).abs;
            return f.propose(testing.io, ar, abs, p, .{ .agent = s1, .turn = turn, .tool = "edit_file", .tool_call_id = "t" });
        }
    };
    try testing.expect(try in_turn.edit(fs, arena, "a.txt", 3, .{ .str_replace = .{ .old = "one", .new = "ONE" } }) == .applied);
    try testing.expect(try in_turn.edit(fs, arena, "a.txt", 3, .{ .str_replace = .{ .old = "two", .new = "TWO" } }) == .applied);
    try testing.expect(try in_turn.edit(fs, arena, "new.txt", 3, .{ .create = .{ .text = "hi\n" } }) == .applied);

    const id = (try fs.endTurn(testing.io, s1, 3)).?;
    try testing.expectEqual(@as(?u64, null), try fs.endTurn(testing.io, s1, 3));
    const cs = g.q.get(@enumFromInt(id)).?;
    try testing.expectEqual(model.State.applied, cs.state);
    try testing.expect(cs.auto_applied);
    try testing.expectEqual(@as(usize, 2), cs.files.len);
    try testing.expectEqualStrings("a.txt", cs.files[0].path);
    try testing.expectEqual(@as(u32, 2), cs.files[0].countLines().added);
    try testing.expect(cs.files[1].op == .create);
    const rows = g.model.rows();
    try testing.expectEqualStrings("Recently auto-applied (last 24 h)", rows[0].label);
    try testing.expectEqualStrings("Turn 3", rows[1].label);
    // A turn that wrote nothing has no changeset.
    try testing.expectEqual(@as(?u64, null), try fs.endTurn(testing.io, s1, 4));
}

test "review glue: undo, accept and reject a turn from the panel" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });

    const g = try ReviewGlue.create(testing.allocator, testing.io, root);
    defer g.destroy();
    const fs = g.files();
    const cps = g.checkpoints();
    const cp = cps.create(cps.ctx, testing.io, s1, 1, "turn 1");
    const t1: zfiles.Origin = .{ .agent = s1, .turn = 1, .tool = "edit_file", .tool_call_id = "t" };
    const abs = (try fs.resolve(testing.io, arena, "a.txt")).abs;
    _ = try fs.propose(testing.io, arena, abs, .{ .str_replace = .{ .old = "one", .new = "ONE" } }, t1);
    _ = try fs.propose(testing.io, arena, abs, .{ .str_replace = .{ .old = "two", .new = "TWO" } }, t1);
    _ = try fs.propose(testing.io, arena, (try fs.resolve(testing.io, arena, "b.txt")).abs, .{ .create = .{ .text = "b\n" } }, t1);
    const id: model.ChangesetId = @enumFromInt((try fs.endTurn(testing.io, s1, 1)).?);
    const read = struct {
        fn f(d: Io.Dir, ar: Allocator, p: []const u8) ![]u8 {
            return d.readFileAlloc(testing.io, p, ar, .limited(64));
        }
    }.f;

    // Undo: the files go back, the changes wait for review.
    try testing.expect(try g.actLocked(arena, id, .undo) == .ok);
    try testing.expectEqualStrings("one\ntwo\n", try read(tmp.dir, arena, "a.txt"));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "b.txt", .{}));
    try testing.expectEqual(model.State.pending, g.q.get(id).?.state);
    try testing.expect(!g.q.get(id).?.auto_applied);
    try testing.expect(try g.actLocked(arena, id, .undo) == .refused);

    // Accept lands them again; a second undo then works too.
    try testing.expect(try g.actLocked(arena, id, .accept) == .ok);
    try testing.expectEqualStrings("ONE\nTWO\n", try read(tmp.dir, arena, "a.txt"));
    try testing.expectEqual(model.State.applied, g.q.get(id).?.state);
    try testing.expect(try g.actLocked(arena, id, .undo) == .ok);

    // Reject writes nothing and closes it.
    try testing.expect(try g.actLocked(arena, id, .reject) == .ok);
    try testing.expectEqual(model.State.rejected, g.q.get(id).?.state);
    try testing.expectEqualStrings("one\ntwo\n", try read(tmp.dir, arena, "a.txt"));

    // A second turn whose line the user changed since: undo refuses.
    _ = try fs.propose(testing.io, arena, abs, .{ .str_replace = .{ .old = "one", .new = "uno" } }, .{ .agent = s1, .turn = 2, .tool = "edit_file", .tool_call_id = "u" });
    const id2: model.ChangesetId = @enumFromInt((try fs.endTurn(testing.io, s1, 2)).?);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "UNO\ntwo\n" });
    const r = try g.actLocked(arena, id2, .undo);
    try testing.expectEqualStrings("a.txt", r.refused.path);
    try testing.expectEqualStrings("UNO\ntwo\n", try read(tmp.dir, arena, "a.txt"));

    // The checkpoint before turn 1 still restores the folded turn once.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "uno\ntwo\n" });
    const rs = g.restore();
    const out = try rs.restore_to(rs.ctx, testing.io, arena, cp);
    try testing.expectEqual(@as(usize, 0), out.skipped.len);
    try testing.expectEqualStrings("one\ntwo\n", try read(tmp.dir, arena, "a.txt"));
}
