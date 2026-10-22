//! `CommentStore` (E12.F03.S03.T01): review comment threads on a
//! changeset, anchored to lines of one of its files.
//!
//! - A thread has a label (Conventional Comments), a blocking flag, free
//!   tags, an anchor and its comments. Resolving hides nothing: a resolved
//!   thread collapses to one line in views.
//! - Anchors follow the text (`reanchor`, after a rebase or a revision;
//!   see `anchor.zig`). A thread whose lines are gone is `outdated` and
//!   keeps the text it was last on; it is never dropped.
//! - Every change is journaled (`Recorder`, the review store's `comment`
//!   records) and restored by `restore`, which ignores what it already
//!   has, so a load and the tail of other processes' records use the same
//!   sink. Restored changes are not journaled again.
//! - Thread and comment ids share one counter starting at `id_base` (the
//!   glue uses the store's process tag `<< 32`), so processes that share
//!   a store never collide.
//! - Blocking threads that are unresolved warn on "Accept all"
//!   (`unresolvedBlocking`); they never forbid it.
//!
//! Owner thread (the queue's). Threads live, with their strings, until
//! their changeset leaves the store (`dropTarget`).

const std = @import("std");
const proto = @import("zg_ai_proto");
const model = @import("../model/root.zig");
const anchor_mod = @import("anchor.zig");
const labels = @import("labels.zig");

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const LineRange = model.changeset.LineRange;
const Hunk = model.changeset.Hunk;
const AgentRef = proto.AgentRef;
const Stringify = std.json.Stringify;

pub const Label = labels.Label;
pub const Side = anchor_mod.Side;

const log = std.log.scoped(.zg_review);

pub const ThreadId = enum(u64) {
    _,

    /// Writes `c<n>`.
    pub fn format(id: ThreadId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("c{d}", .{@intFromEnum(id)});
    }
};

pub const Author = union(enum) {
    user: []const u8,
    agent: AgentRef,
    /// An F08 code review run.
    code_review: u64,
};

pub const Comment = struct {
    id: u64,
    author: Author,
    /// Markdown, as written (a label prefix stays in it).
    body: []const u8,
    created_ms: i64,
    edited_ms: ?i64 = null,
};

pub const CommentAnchor = struct {
    path: []const u8,
    side: Side = .new,
    lines: LineRange,
    /// The hunk the thread was started on (its key), when it was.
    hunk_key: ?u64 = null,
    /// See `anchor.zig`; 0 for an empty range.
    content_hash: u64 = 0,
    /// The anchored lines' text when the thread was last placed.
    text: []const u8 = "",

    /// The anchor of lines `r` of `text` (the file's text on `side`).
    /// `text` is borrowed; `create` copies it.
    pub fn at(gpa: Allocator, path: []const u8, side: Side, text: []const u8, r: LineRange) Allocator.Error!CommentAnchor {
        return .{
            .path = path,
            .side = side,
            .lines = r,
            .content_hash = if (r.count == 0) 0 else try anchor_mod.hashRange(gpa, text, r),
            .text = try anchor_mod.rangeText(gpa, text, r),
        };
    }
};

pub const Thread = struct {
    id: ThreadId,
    target: ChangesetId,
    anchor: CommentAnchor,
    label: ?Label = null,
    blocking: bool = false,
    /// Free decorations of the first comment's label prefix.
    tags: []const []const u8 = &.{},
    resolved: bool = false,
    /// The anchored lines are gone; `anchor` keeps where they last were.
    outdated: bool = false,
    /// When it was last sent to the agent in a fix request.
    sent_ms: ?i64 = null,
    /// Its lines changed in the agent's revision after it was sent.
    maybe_addressed: bool = false,
    /// The thread it was copied from (onto a superseding changeset).
    copied_from: ?ThreadId = null,
    created_ms: i64,
    comments: std.ArrayList(Comment) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn first(t: *const Thread) *const Comment {
        return &t.comments.items[0];
    }
};

/// Receives each change's JSON record; must not block.
pub const Recorder = struct {
    ctx: *anyopaque,
    record: *const fn (ctx: *anyopaque, json: []const u8) void,
};

/// Takes the comment records of a store load or tail.
pub const RestoreSink = struct {
    ctx: *anyopaque,
    restore: *const fn (ctx: *anyopaque, record: std.json.Value) anyerror!void,
};

/// Hears about every change, journaled or restored.
pub const Listener = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque, target: ChangesetId, t: ThreadId) void,
};

pub const Options = struct {
    id_base: u64 = 0,
    recorder: ?Recorder = null,
    listener: ?Listener = null,
};

pub const Error = error{ UnknownThread, UnknownComment, EmptyBody, OutOfMemory };

pub const ReanchorOptions = struct {
    side: Side = .new,
    /// The hunks of the old-to-new edit, when the caller has them (the
    /// Rebaser's ChangeSet, `deriveHunks`).
    map: ?[]const Hunk = null,
};

pub const ReanchorReport = struct { kept: u32 = 0, moved: u32 = 0, outdated: u32 = 0, recovered: u32 = 0 };

pub const CommentStore = struct {
    gpa: Allocator,
    opts: Options,
    next: u64,
    threads: std.AutoArrayHashMapUnmanaged(ThreadId, *Thread) = .empty,
    by_target: std.AutoHashMapUnmanaged(ChangesetId, std.ArrayList(*const Thread)) = .empty,

    pub fn init(gpa: Allocator, opts: Options) CommentStore {
        return .{ .gpa = gpa, .opts = opts, .next = opts.id_base + 1 };
    }

    pub fn deinit(cs: *CommentStore) void {
        for (cs.threads.values()) |t| freeThread(cs.gpa, t);
        cs.threads.deinit(cs.gpa);
        var it = cs.by_target.valueIterator();
        while (it.next()) |l| l.deinit(cs.gpa);
        cs.by_target.deinit(cs.gpa);
    }

    fn freeThread(gpa: Allocator, t: *Thread) void {
        t.arena.deinit();
        gpa.destroy(t);
    }

    /// Binds the store's recorder and id base once the store is open.
    pub fn bind(cs: *CommentStore, recorder: ?Recorder, id_base: u64) void {
        cs.opts.recorder = recorder;
        cs.opts.id_base = id_base;
        cs.next = @max(cs.next, id_base + 1);
    }

    fn nextId(cs: *CommentStore) u64 {
        defer cs.next += 1;
        return cs.next;
    }

    fn see(cs: *CommentStore, id: u64) void {
        if (id >> 32 == cs.opts.id_base >> 32 and id >= cs.next) cs.next = id + 1;
    }

    // ------------------------------------------------------------ edits

    /// Starts a thread on `anchor` (see `CommentAnchor.at`). The body's
    /// free decorations become tags; `label` and `blocking` are the
    /// caller's (the UI prefills them from `parseLabelPrefix`).
    pub fn create(cs: *CommentStore, target: ChangesetId, anchor: CommentAnchor, label: ?Label, blocking: bool, body: []const u8, author: Author, now_ms: i64) Error!ThreadId {
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) return error.EmptyBody;
        const tid: ThreadId = @enumFromInt(cs.nextId());
        const c: Comment = .{ .id = cs.nextId(), .author = author, .body = body, .created_ms = now_ms };
        const t = try cs.addThread(tid, target, anchor, label, blocking, now_ms, c, null);
        cs.journal(.{ .op = .create, .thread = @intFromEnum(tid) }, t, t.first());
        cs.notify(t);
        return tid;
    }

    fn addThread(cs: *CommentStore, tid: ThreadId, target: ChangesetId, anchor: CommentAnchor, label: ?Label, blocking: bool, now_ms: i64, c: Comment, tags: ?[]const []const u8) Allocator.Error!*Thread {
        const t = try cs.gpa.create(Thread);
        t.* = .{ .id = tid, .target = target, .anchor = undefined, .label = label, .blocking = blocking, .created_ms = now_ms, .arena = .init(cs.gpa) };
        errdefer freeThread(cs.gpa, t);
        const a = t.arena.allocator();
        t.anchor = anchor;
        t.anchor.path = try a.dupe(u8, anchor.path);
        t.anchor.text = try a.dupe(u8, anchor.text);
        if (tags) |ts| {
            const out = try a.alloc([]const u8, ts.len);
            for (ts, out) |s, *o| o.* = try a.dupe(u8, s);
            t.tags = out;
        } else {
            var list: std.ArrayList([]const u8) = .empty;
            var it = labels.parseLabelPrefix(c.body).tags();
            while (it.next()) |tag| try list.append(a, try a.dupe(u8, tag));
            t.tags = list.items;
        }
        try t.comments.append(a, try dupeComment(a, c));
        try cs.threads.ensureUnusedCapacity(cs.gpa, 1);
        const gop = try cs.by_target.getOrPut(cs.gpa, target);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(cs.gpa, t);
        cs.threads.putAssumeCapacity(tid, t);
        return t;
    }

    pub fn reply(cs: *CommentStore, tid: ThreadId, body: []const u8, author: Author, now_ms: i64) Error!u64 {
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) return error.EmptyBody;
        const t = cs.threads.get(tid) orelse return error.UnknownThread;
        const c = try dupeComment(t.arena.allocator(), .{ .id = cs.nextId(), .author = author, .body = body, .created_ms = now_ms });
        try t.comments.append(t.arena.allocator(), c);
        cs.journal(.{ .op = .reply, .thread = @intFromEnum(tid) }, t, &t.comments.items[t.comments.items.len - 1]);
        cs.notify(t);
        return c.id;
    }

    /// Replaces a comment's body.
    pub fn edit(cs: *CommentStore, tid: ThreadId, comment: u64, body: []const u8, now_ms: i64) Error!void {
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) return error.EmptyBody;
        const t = cs.threads.get(tid) orelse return error.UnknownThread;
        const c = findComment(t, comment) orelse return error.UnknownComment;
        c.body = try t.arena.allocator().dupe(u8, body);
        c.edited_ms = now_ms;
        cs.journal(.{ .op = .edit, .thread = @intFromEnum(tid) }, t, c);
        cs.notify(t);
    }

    pub fn resolve(cs: *CommentStore, tid: ThreadId, resolved: bool) Error!void {
        const t = cs.threads.get(tid) orelse return error.UnknownThread;
        if (t.resolved == resolved) return;
        t.resolved = resolved;
        cs.journal(.{ .op = .resolve, .thread = @intFromEnum(tid), .resolved = resolved }, t, null);
        cs.notify(t);
    }

    /// Sets a thread's label and blocking flag (the UI's dropdown).
    pub fn setLabel(cs: *CommentStore, tid: ThreadId, label: ?Label, blocking: bool) Error!void {
        const t = cs.threads.get(tid) orelse return error.UnknownThread;
        if (t.label == label and t.blocking == blocking) return;
        t.label = label;
        t.blocking = blocking;
        cs.journal(.{ .op = .label, .thread = @intFromEnum(tid), .label = label, .blocking = blocking }, t, null);
        cs.notify(t);
    }

    /// Moves the threads of `target` on `path` to their lines in
    /// `new_text` (the file's text on `o.side` after a rebase or a
    /// revision); threads whose lines are gone go outdated, and outdated
    /// ones whose lines are back come back.
    pub fn reanchor(cs: *CommentStore, target: ChangesetId, path: []const u8, new_text: []const u8, o: ReanchorOptions) Allocator.Error!ReanchorReport {
        var rep: ReanchorReport = .{};
        const list = cs.by_target.get(target) orelse return rep;
        var lh: ?anchor_mod.LineHashes = null;
        defer if (lh) |*x| x.deinit(cs.gpa);
        for (list.items) |ct| {
            const t = cs.threads.get(ct.id).?;
            if (t.anchor.side != o.side or !std.mem.eql(u8, t.anchor.path, path)) continue;
            if (lh == null) lh = try .init(cs.gpa, new_text);
            // An outdated thread's old lines mean nothing to the mapping.
            const map = if (t.outdated) null else o.map;
            const found = anchor_mod.relocate(&lh.?, t.anchor.lines, t.anchor.content_hash, map);
            if (found) |r| {
                const moved = r.start != t.anchor.lines.start or r.count != t.anchor.lines.count;
                const was_outdated = t.outdated;
                if (!moved and !was_outdated) {
                    rep.kept += 1;
                    continue;
                }
                t.anchor.lines = r;
                t.outdated = false;
                if (was_outdated) rep.recovered += 1 else rep.moved += 1;
                cs.journal(.{ .op = .reanchor, .thread = @intFromEnum(t.id), .lines = .{ r.start, r.count } }, t, null);
                cs.notify(t);
            } else if (!t.outdated) {
                t.outdated = true;
                rep.outdated += 1;
                cs.journal(.{ .op = .outdated, .thread = @intFromEnum(t.id) }, t, null);
                cs.notify(t);
            }
        }
        return rep;
    }

    /// Marks threads as sent to the agent at `now_ms`.
    pub fn markSent(cs: *CommentStore, tids: []const ThreadId, now_ms: i64) Error!void {
        for (tids) |tid| {
            const t = cs.threads.get(tid) orelse return error.UnknownThread;
            t.sent_ms = now_ms;
            t.maybe_addressed = false;
            cs.journal(.{ .op = .sent, .thread = @intFromEnum(tid), .ms = now_ms }, t, null);
            cs.notify(t);
        }
    }

    /// Tags a thread whose lines the agent's revision changed (or clears
    /// the tag).
    pub fn setAddressed(cs: *CommentStore, tid: ThreadId, on: bool) Error!void {
        const t = cs.threads.get(tid) orelse return error.UnknownThread;
        if (t.maybe_addressed == on) return;
        t.maybe_addressed = on;
        cs.journal(.{ .op = .addressed, .thread = @intFromEnum(tid), .addressed = on }, t, null);
        cs.notify(t);
    }

    /// Copies the unresolved threads of `from` onto `to` (a changeset that
    /// supersedes it), comments and all, with new ids; `copied_from`
    /// names the original. Re-anchor them afterwards. Returns how many.
    pub fn copyOpen(cs: *CommentStore, from: ChangesetId, to: ChangesetId) Allocator.Error!u32 {
        const src = cs.by_target.get(from) orelse return 0;
        // `src.items` may move as `to`'s list grows when from == to.
        std.debug.assert(from != to);
        var n: u32 = 0;
        for (src.items) |o| {
            if (o.resolved) continue;
            const tid: ThreadId = @enumFromInt(cs.nextId());
            var first = o.first().*;
            first.id = cs.nextId();
            const t = try cs.addThread(tid, to, o.anchor, o.label, o.blocking, o.created_ms, first, o.tags);
            t.outdated = o.outdated;
            t.sent_ms = o.sent_ms;
            t.copied_from = o.id;
            for (o.comments.items[1..]) |c| {
                var r = try dupeComment(t.arena.allocator(), c);
                r.id = cs.nextId();
                try t.comments.append(t.arena.allocator(), r);
            }
            if (cs.opts.recorder) |rec| {
                var aw: std.Io.Writer.Allocating = .init(cs.gpa);
                defer aw.deinit();
                if (writeSnapshot(cs.gpa, &aw.writer, t)) |_| rec.record(rec.ctx, aw.written()) else |e| log.err("comment thread {f} not recorded: {t}", .{ t.id, e });
            }
            cs.notify(t);
            n += 1;
        }
        return n;
    }

    /// Forgets the threads of a changeset that left the store (not
    /// journaled: compaction drops their records with the changeset's).
    pub fn dropTarget(cs: *CommentStore, target: ChangesetId) void {
        var kv = cs.by_target.fetchRemove(target) orelse return;
        for (kv.value.items) |t| {
            if (cs.threads.fetchSwapRemove(t.id)) |e| freeThread(cs.gpa, e.value);
        }
        kv.value.deinit(cs.gpa);
    }

    // ------------------------------------------------------------ reads

    /// The threads of `target`, oldest first (outdated and resolved ones
    /// included); valid until the next change.
    pub fn threadsOf(cs: *const CommentStore, target: ChangesetId) []const *const Thread {
        const l = cs.by_target.getPtr(target) orelse return &.{};
        return l.items;
    }

    pub fn get(cs: *const CommentStore, tid: ThreadId) ?*const Thread {
        return cs.threads.get(tid);
    }

    /// Threads of `target` that are blocking and unresolved.
    pub fn unresolvedBlocking(cs: *const CommentStore, target: ChangesetId) u32 {
        var n: u32 = 0;
        for (cs.threadsOf(target)) |t| {
            if (t.blocking and !t.resolved) n += 1;
        }
        return n;
    }

    pub const Counts = struct { open: u32 = 0, resolved: u32 = 0, outdated: u32 = 0, blocking: u32 = 0 };

    pub fn counts(cs: *const CommentStore, target: ChangesetId) Counts {
        var c: Counts = .{};
        for (cs.threadsOf(target)) |t| {
            if (t.resolved) c.resolved += 1 else c.open += 1;
            if (t.outdated) c.outdated += 1;
            if (t.blocking and !t.resolved) c.blocking += 1;
        }
        return c;
    }

    // ------------------------------------------------------ persistence

    fn journal(cs: *CommentStore, rec: Record, t: *const Thread, c: ?*const Comment) void {
        const r = cs.opts.recorder orelse return;
        var aw: std.Io.Writer.Allocating = .init(cs.gpa);
        defer aw.deinit();
        writeRecord(&aw.writer, rec, t, c) catch |e| {
            log.err("comment thread {f} not recorded: {t}", .{ t.id, e });
            return;
        };
        r.record(r.ctx, aw.written());
    }

    fn notify(cs: *CommentStore, t: *const Thread) void {
        if (cs.opts.listener) |l| l.changed(l.ctx, t.target, t.id);
    }

    /// The sink a store load or tail restores comment records into.
    pub fn restoreSink(cs: *CommentStore) RestoreSink {
        return .{ .ctx = cs, .restore = struct {
            fn f(ctx: *anyopaque, v: std.json.Value) anyerror!void {
                const self: *CommentStore = @ptrCast(@alignCast(ctx));
                try self.restore(v);
            }
        }.f };
    }

    /// Applies one record; records this store already has, and records of
    /// threads it does not know, are ignored.
    pub fn restore(cs: *CommentStore, v: std.json.Value) !void {
        var arena_state: std.heap.ArenaAllocator = .init(cs.gpa);
        defer arena_state.deinit();
        const rec = std.json.parseFromValueLeaky(Wire, arena_state.allocator(), v, .{ .ignore_unknown_fields = true }) catch return error.InvalidRecord;
        const tid: ThreadId = @enumFromInt(rec.thread);
        cs.see(rec.thread);
        if (rec.comment) |c| cs.see(c.id);
        const existing = cs.threads.get(tid);
        switch (rec.op) {
            .create, .snapshot => {
                if (existing != null) return;
                const a = rec.anchor orelse return error.InvalidRecord;
                const first = rec.comment orelse return error.InvalidRecord;
                const t = try cs.addThread(tid, @enumFromInt(rec.cs orelse return error.InvalidRecord), .{
                    .path = a.path,
                    .side = a.side,
                    .lines = .{ .start = a.lines[0], .count = a.lines[1] },
                    .hunk_key = a.hunk,
                    .content_hash = a.hash,
                    .text = a.text,
                }, rec.label, rec.blocking orelse false, rec.created_ms orelse first.created_ms, try first.decode(), rec.tags);
                t.resolved = rec.resolved orelse false;
                t.outdated = rec.outdated orelse false;
                t.sent_ms = rec.ms;
                t.maybe_addressed = rec.addressed orelse false;
                if (rec.copied_from) |x| t.copied_from = @enumFromInt(x);
                if (rec.op == .snapshot) for (rec.replies orelse &.{}) |r| {
                    cs.see(r.id);
                    try t.comments.append(t.arena.allocator(), try dupeComment(t.arena.allocator(), try r.decode()));
                };
                cs.notify(t);
            },
            .reply => {
                const t = existing orelse return;
                const c = rec.comment orelse return error.InvalidRecord;
                if (findComment(t, c.id) != null) return;
                try t.comments.append(t.arena.allocator(), try dupeComment(t.arena.allocator(), try c.decode()));
                cs.notify(t);
            },
            .edit => {
                const t = existing orelse return;
                const w = rec.comment orelse return error.InvalidRecord;
                const c = findComment(t, w.id) orelse return;
                if (c.edited_ms != null and w.edited_ms != null and c.edited_ms.? >= w.edited_ms.?) return;
                c.body = try t.arena.allocator().dupe(u8, w.body);
                c.edited_ms = w.edited_ms;
                cs.notify(t);
            },
            .resolve => {
                const t = existing orelse return;
                t.resolved = rec.resolved orelse return error.InvalidRecord;
                cs.notify(t);
            },
            .label => {
                const t = existing orelse return;
                t.label = rec.label;
                t.blocking = rec.blocking orelse false;
                cs.notify(t);
            },
            .reanchor => {
                const t = existing orelse return;
                const l = rec.lines orelse return error.InvalidRecord;
                t.anchor.lines = .{ .start = l[0], .count = l[1] };
                t.outdated = false;
                cs.notify(t);
            },
            .outdated => {
                const t = existing orelse return;
                t.outdated = true;
                cs.notify(t);
            },
            .sent => {
                const t = existing orelse return;
                t.sent_ms = rec.ms;
                t.maybe_addressed = false;
                cs.notify(t);
            },
            .addressed => {
                const t = existing orelse return;
                t.maybe_addressed = rec.addressed orelse false;
                cs.notify(t);
            },
        }
    }
};

fn findComment(t: *Thread, id: u64) ?*Comment {
    for (t.comments.items) |*c| if (c.id == id) return c;
    return null;
}

fn dupeComment(a: Allocator, c: Comment) Allocator.Error!Comment {
    var out = c;
    out.body = try a.dupe(u8, c.body);
    out.author = switch (c.author) {
        .user => |u| .{ .user = try a.dupe(u8, u) },
        .agent => |g| .{ .agent = .{ .session = g.session, .agent = g.agent, .tool_call = if (g.tool_call) |x| try a.dupe(u8, x) else null } },
        .code_review => c.author,
    };
    return out;
}

// ---------------------------------------------------------------- records

pub const Op = enum { create, reply, edit, resolve, label, reanchor, outdated, snapshot, sent, addressed };

const Record = struct {
    op: Op,
    thread: u64,
    resolved: ?bool = null,
    label: ?Label = null,
    blocking: ?bool = null,
    lines: ?[2]u32 = null,
    ms: ?i64 = null,
    addressed: ?bool = null,
};

const WireAuthor = struct {
    t: std.meta.Tag(Author),
    name: ?[]const u8 = null,
    session: ?[]const u8 = null,
    agent: ?u32 = null,
    tool_call: ?[]const u8 = null,
    run: ?u64 = null,
};

const WireComment = struct {
    id: u64,
    author: WireAuthor,
    body: []const u8,
    created_ms: i64,
    edited_ms: ?i64 = null,

    fn of(c: *const Comment, session_buf: *[26]u8) WireComment {
        return .{
            .id = c.id,
            .author = switch (c.author) {
                .user => |u| .{ .t = .user, .name = u },
                .agent => |g| blk: {
                    session_buf.* = proto.agent_ref.format(g.session);
                    break :blk .{ .t = .agent, .session = session_buf, .agent = g.agent, .tool_call = g.tool_call };
                },
                .code_review => |r| .{ .t = .code_review, .run = r },
            },
            .body = c.body,
            .created_ms = c.created_ms,
            .edited_ms = c.edited_ms,
        };
    }

    fn decode(w: WireComment) error{InvalidRecord}!Comment {
        const a = w.author;
        return .{
            .id = w.id,
            .author = switch (a.t) {
                .user => .{ .user = a.name orelse "" },
                .agent => .{ .agent = .{
                    .session = proto.agent_ref.parse(a.session orelse return error.InvalidRecord) catch return error.InvalidRecord,
                    .agent = a.agent orelse 0,
                    .tool_call = a.tool_call,
                } },
                .code_review => .{ .code_review = a.run orelse 0 },
            },
            .body = w.body,
            .created_ms = w.created_ms,
            .edited_ms = w.edited_ms,
        };
    }
};

const WireAnchor = struct {
    path: []const u8,
    side: Side,
    lines: [2]u32,
    hunk: ?u64 = null,
    hash: u64,
    text: []const u8,
};

/// One journal record; which fields are set depends on `op`.
const Wire = struct {
    op: Op,
    thread: u64,
    cs: ?u64 = null,
    anchor: ?WireAnchor = null,
    label: ?Label = null,
    blocking: ?bool = null,
    tags: ?[]const []const u8 = null,
    resolved: ?bool = null,
    outdated: ?bool = null,
    created_ms: ?i64 = null,
    lines: ?[2]u32 = null,
    /// `sent`, `snapshot`: when it was sent.
    ms: ?i64 = null,
    addressed: ?bool = null,
    copied_from: ?u64 = null,
    comment: ?WireComment = null,
    /// `snapshot`: the comments after the first.
    replies: ?[]const WireComment = null,
};

fn writeRecord(w: *std.Io.Writer, rec: Record, t: *const Thread, c: ?*const Comment) !void {
    var sb: [26]u8 = undefined;
    var wire: Wire = .{
        .op = rec.op,
        .thread = rec.thread,
        .resolved = rec.resolved,
        .label = rec.label,
        .blocking = rec.blocking,
        .lines = rec.lines,
        .ms = rec.ms,
        .addressed = rec.addressed,
        .comment = if (c) |x| WireComment.of(x, &sb) else null,
    };
    if (rec.op == .create) {
        wire.cs = @intFromEnum(t.target);
        wire.anchor = anchorWire(t);
        wire.label = t.label;
        wire.blocking = t.blocking;
        wire.tags = if (t.tags.len > 0) t.tags else null;
        wire.created_ms = t.created_ms;
    }
    try Stringify.value(wire, .{ .emit_null_optional_fields = false }, w);
}

fn anchorWire(t: *const Thread) WireAnchor {
    const a = t.anchor;
    return .{ .path = a.path, .side = a.side, .lines = .{ a.lines.start, a.lines.count }, .hunk = a.hunk_key, .hash = a.content_hash, .text = a.text };
}

/// A thread's whole state as one `snapshot` record (compaction).
pub fn writeSnapshot(gpa: Allocator, w: *std.Io.Writer, t: *const Thread) !void {
    const n = t.comments.items.len;
    const bufs = try gpa.alloc([26]u8, n);
    defer gpa.free(bufs);
    const replies = try gpa.alloc(WireComment, n - 1);
    defer gpa.free(replies);
    for (t.comments.items[1..], replies, bufs[1..]) |*c, *r, *b| r.* = WireComment.of(c, b);
    const wire: Wire = .{
        .op = .snapshot,
        .thread = @intFromEnum(t.id),
        .cs = @intFromEnum(t.target),
        .anchor = anchorWire(t),
        .label = t.label,
        .blocking = t.blocking,
        .tags = if (t.tags.len > 0) t.tags else null,
        .resolved = t.resolved,
        .outdated = t.outdated,
        .ms = t.sent_ms,
        .addressed = if (t.maybe_addressed) true else null,
        .copied_from = if (t.copied_from) |x| @intFromEnum(x) else null,
        .created_ms = t.created_ms,
        .comment = WireComment.of(t.first(), &bufs[0]),
        .replies = if (replies.len > 0) replies else null,
    };
    try Stringify.value(wire, .{ .emit_null_optional_fields = false }, w);
}
