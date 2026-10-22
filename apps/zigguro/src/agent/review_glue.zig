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
//! Proposals are still applied as soon as the tool's approval passed;
//! holding them in the review queue (`Outcome.pending`) waits for E12.F03's
//! review UI. Contents live in memory for the app's run, like the agent
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
    mutex: Io.Mutex = .init,

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
        };
        errdefer g.dir.close(io);
        g.workspace = .{ .dir = g.dir, .io = io };
        g.q = try model.Queue.init(gpa, io, .{ .root = root, .blobs = g.blobs.blobs() });
        g.cps = .init(gpa, io, g.q, &g.history, g.workspace.files(), null);
        return g;
    }

    /// No agent may still be running.
    pub fn destroy(g: *ReviewGlue) void {
        const gpa = g.gpa;
        g.cps.deinit();
        g.q.deinit();
        g.history.deinit();
        g.blobs.deinit();
        g.dir.close(g.io);
        gpa.destroy(g);
    }

    /// The `Files` for paths not open in the editor (`EditorFiles.outside`).
    pub fn files(g: *ReviewGlue) zfiles.Files {
        return .{ .ctx = g, .vtable = &.{ .resolve = resolve, .kind = kind, .read = read, .propose = propose } };
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
        g.record(arena, rel, before, origin.agent) catch |e| log.warn("{s}: agent write not recorded for restore: {t}", .{ rel, e });
        return out;
    }

    /// Records the write of `rel` (whose content was `before`). Locked.
    fn record(g: *ReviewGlue, arena: Allocator, rel: []const u8, before: ?zg_review.apply.files.Entry, agent: zg_ai_proto.AgentRef) !void {
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
        if (std.meta.eql(f.pre, f.post) and f.pre_exec == f.post_exec) return;
        const now = Io.Clock.real.now(g.io);
        _ = try g.history.record(.{
            .cs = null,
            .session = agent.session,
            .created_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)),
            .files = &.{f},
        });
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
