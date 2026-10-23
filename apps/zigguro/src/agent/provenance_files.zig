//! Provenance for the review glue's writes (E12 → E09.F05). Every file the
//! glue writes, an agent's edit or a changeset applied from review, is
//! reported to zg_scm's provenance recorder as a whole-file write by its
//! actor. At the next snapshot the recorder diffs the file and gives the
//! changed lines to that actor when the content still matches.
//!
//! `RecordingFiles` wraps the workspace `Files` that the applier writes
//! through; the glue sets `actor` around each action (the changeset's
//! agent for an accept, the user for a reject or an undo).

const std = @import("std");
const zg_scm = @import("zg_scm");
const zg_review = @import("zg_review");
const zg_ai_proto = @import("zg_ai").proto;

const Allocator = std.mem.Allocator;
const Files = zg_review.apply.files.Files;
const Entry = zg_review.apply.files.Entry;
const Origin = zg_review.model.provenance.Origin;
pub const Actor = zg_scm.prov.record.Actor;
const Recorder = zg_scm.prov.recorder.Recorder;

/// Where writes are reported.
pub const Provenance = struct {
    ctx: *anyopaque,
    written: *const fn (ctx: *anyopaque, path: []const u8, workspace: []const u8, actor: Actor, hash: [32]u8) void,

    /// Reports to `r` (`Recorder.onFileWritten`).
    pub fn of(r: *Recorder) Provenance {
        return .{ .ctx = r, .written = recorderWritten };
    }

    fn recorderWritten(ctx: *anyopaque, path: []const u8, workspace: []const u8, actor: Actor, hash: [32]u8) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.onFileWritten(path, workspace, actor, hash);
    }

    /// Reports that `actor` wrote `bytes` to `path`.
    pub fn report(p: Provenance, path: []const u8, workspace: []const u8, actor: Actor, bytes: []const u8) void {
        p.written(p.ctx, path, workspace, actor, hashOf(bytes));
    }
};

/// The content hash the recorder compares with the snapshot's blob.
pub fn hashOf(bytes: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &h, .{});
    return h;
}

/// The agent of `ref` (its session as a ULID in `arena`).
pub fn agentActor(arena: Allocator, ref: zg_ai_proto.AgentRef, model_id: []const u8) Allocator.Error!Actor {
    const sid = zg_ai_proto.agent_ref.format(ref.session);
    return .{
        .kind = .agent,
        .name = if (ref.agent == 0) "agent" else "subagent",
        .model_id = model_id,
        .session_id = try arena.dupe(u8, &sid),
        .tool_call_id = ref.tool_call orelse "",
    };
}

/// Who a changeset's lines belong to once it is applied.
pub fn actorOf(arena: Allocator, origin: Origin, user: Actor) Allocator.Error!Actor {
    return switch (origin) {
        .agent => |a| agentActor(arena, a.ref, a.model),
        .inline_edit => |a| agentActor(arena, a.ref, ""),
        .lsp => |l| if (l.agent) |r| agentActor(arena, r, "") else Actor.tool("lsp.edit"),
        .search_replace => |s| if (s.agent) |r| agentActor(arena, r, "") else user,
        .notes => |n| if (n.agent) |r| agentActor(arena, r, "") else Actor.tool("notes"),
        .scm_proposal => |s| Actor.tool(switch (s.kind) {
            .describe => "scm.describe",
            .split => "scm.split",
            .resolve => "scm.resolve",
            .land => "scm.land",
        }),
        .code_review => Actor.tool("review.suggestion"),
        .user_bulk => user,
    };
}

/// `Files` that report each write while `actor` is set.
pub const RecordingFiles = struct {
    inner: Files,
    workspace: []const u8,
    prov: ?Provenance = null,
    /// Who the writes are by now (null: not reported).
    actor: ?Actor = null,

    pub fn files(r: *RecordingFiles) Files {
        return .{ .ctx = r, .vtable = &.{ .read = read, .write = write, .delete = delete } };
    }

    fn read(ctx: *anyopaque, arena: Allocator, path: []const u8) anyerror!?Entry {
        const r: *RecordingFiles = @ptrCast(@alignCast(ctx));
        return r.inner.read(arena, path);
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8, executable: ?bool) anyerror!void {
        const r: *RecordingFiles = @ptrCast(@alignCast(ctx));
        try r.inner.write(path, bytes, executable);
        if (r.prov) |p| if (r.actor) |a| p.report(path, r.workspace, a, bytes);
    }

    fn delete(ctx: *anyopaque, path: []const u8) anyerror!void {
        const r: *RecordingFiles = @ptrCast(@alignCast(ctx));
        return r.inner.delete(path);
    }
};

const testing = std.testing;

/// Reports kept for tests.
pub const Collect = struct {
    arena: std.heap.ArenaAllocator,
    got: std.ArrayList(struct { path: []const u8, actor: Actor, hash: [32]u8 }) = .empty,

    pub fn init(gpa: Allocator) Collect {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(c: *Collect) void {
        c.arena.deinit();
    }

    pub fn provenance(c: *Collect) Provenance {
        return .{ .ctx = c, .written = written };
    }

    fn written(ctx: *anyopaque, path: []const u8, _: []const u8, actor: Actor, hash: [32]u8) void {
        const c: *Collect = @ptrCast(@alignCast(ctx));
        const a = c.arena.allocator();
        const copy = actor.dupe(a) catch return;
        const p = a.dupe(u8, path) catch return;
        c.got.append(a, .{ .path = p, .actor = copy, .hash = hash }) catch return;
    }
};

test "recording files: writes are reported while an actor is set" {
    var mem: zg_review.apply.files.MemFiles = .init(testing.allocator);
    defer mem.deinit();
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var rf: RecordingFiles = .{ .inner = mem.files(), .workspace = "/ws", .prov = c.provenance() };
    const f = rf.files();
    try f.write("a.txt", "one\n", null);
    try testing.expectEqual(@as(usize, 0), c.got.items.len);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const origin: Origin = .{ .agent = .{ .ref = .{ .session = 42, .agent = 1, .tool_call = "toolu_1" }, .turn = 3, .model = "anthropic/claude-haiku" } };
    rf.actor = try actorOf(arena.allocator(), origin, Actor.human("me", ""));
    try f.write("a.txt", "two\n", null);
    try testing.expectEqual(@as(usize, 1), c.got.items.len);
    const got = c.got.items[0];
    try testing.expectEqualStrings("a.txt", got.path);
    try testing.expectEqual(record_kind.agent, got.actor.kind);
    try testing.expectEqualStrings("subagent", got.actor.name);
    try testing.expectEqualStrings("anthropic/claude-haiku", got.actor.model_id);
    try testing.expectEqualStrings("toolu_1", got.actor.tool_call_id);
    try testing.expectEqual(@as(usize, 26), got.actor.session_id.len);
    try testing.expectEqualSlices(u8, &hashOf("two\n"), &got.hash);
    const e = (try f.read(arena.allocator(), "a.txt")).?;
    try testing.expectEqualStrings("two\n", e.bytes);

    try testing.expectEqualStrings("scm.land", (try actorOf(arena.allocator(), .{ .scm_proposal = .{ .kind = .land, .review = 1 } }, .unknown)).name);
    try testing.expectEqual(record_kind.human, (try actorOf(arena.allocator(), .{ .user_bulk = .{ .command = "x" } }, Actor.human("me", ""))).kind);
}

const record_kind = zg_scm.prov.record.ActorKind;
