//! `Feedback` (E12.F03.S03.T02): sends review comments to the agent
//! that made a changeset, and follows its revision.
//!
//! Delivery (`requestFix`) by the session's status (`AgentPort`):
//! - `running` → `steer` (E10 queues it at the next tool boundary);
//! - `idle` → a new turn;
//! - `ended` (or unknown) → the user picks: resume the session and send,
//!   or a new session with the message (`finishEnded`).
//! The threads are marked sent.
//!
//! Revisions. A request waits for the agent's next change:
//! - Edits folded into the changeset itself (it was still undecided)
//!   change its proposed texts: `onUpdated` bumps `revision` and keeps
//!   each changed file's previous proposal in `FileChange.previous`.
//! - A new changeset from the same session touching one of its files
//!   (the old one was partly decided) supersedes it: `onSubmitted` sets
//!   `supersedes` and copies the open threads onto it.
//! Either way the threads are re-anchored to the new text, and those
//! whose lines changed are tagged `maybe_addressed`.
//!
//! `interdiff` gives the texts to diff: the previous proposal against the
//! current one, or the superseded changeset's against its successor's.
//!
//! Owner thread (the queue's). Queue listeners must not change the
//! queue, so `listener()` only notes events; `pump` handles them.
//! Requests waiting for a revision live in memory.

const std = @import("std");
const proto = @import("zg_ai_proto");
const model = @import("../model/root.zig");
const comments = @import("comments.zig");
const anchor_mod = @import("anchor.zig");
const message = @import("message.zig");

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const Changeset = model.Changeset;
const FileChange = model.FileChange;
const BlobHash = model.BlobHash;
const CommentStore = comments.CommentStore;
const ThreadId = comments.ThreadId;
const Thread = comments.Thread;
const SessionId = proto.agent_ref.SessionId;

pub const FeedbackMessage = message.FeedbackMessage;

const log = std.log.scoped(.zg_review);

pub const AgentStatus = enum { running, idle, ended, unknown };
pub const SubmitMode = enum { steer, new_turn };

/// The app's side (over E10's AgentManager); zg_review never imports
/// zg_ai.
pub const AgentPort = struct {
    ctx: *anyopaque,
    status: *const fn (ctx: *anyopaque, s: SessionId) AgentStatus,
    submit: *const fn (ctx: *anyopaque, s: SessionId, msg: *const FeedbackMessage, mode: SubmitMode) anyerror!void,
    resumeSession: *const fn (ctx: *anyopaque, s: SessionId) anyerror!void,
    newSession: *const fn (ctx: *anyopaque, msg: *const FeedbackMessage) anyerror!SessionId,
    /// E10's token estimator; chars / 4 without one.
    estimate: ?message.Estimate = null,
};

pub const Delivery = enum {
    steered,
    new_turn,
    /// The session ended: call `finishEnded` with the user's choice.
    ask_resume,
};

pub const EndedChoice = enum { resume_session, new_session, cancel };

pub const Options = struct {
    /// `review.feedbackMaxTokens`.
    max_tokens: u32 = 4000,
};

pub const Error = error{ UnknownChangeset, NotAnAgentChange, NoThreads, NothingWaiting };

/// The texts an interdiff compares.
pub const InterdiffDocs = struct {
    left: []const u8,
    right: []const u8,
    /// "revision 1", "#12" ...
    left_label: []const u8,
    right_label: []const u8,
};

const FileSnap = struct { path: []const u8, hash: BlobHash };

/// A request waiting for the agent's revision.
const Request = struct {
    cs: ChangesetId,
    session: SessionId,
    /// Each text file's proposed text when the request was sent.
    files: []FileSnap,
    threads: []ThreadId,
    arena: std.heap.ArenaAllocator,
};

pub const Feedback = struct {
    gpa: Allocator,
    q: *model.Queue,
    comments: *CommentStore,
    port: AgentPort,
    opts: Options,
    requests: std.ArrayList(Request) = .empty,
    /// The message `requestFix` could not deliver (an ended session).
    waiting: ?struct { session: SessionId, msg: FeedbackMessage, arena: std.heap.ArenaAllocator, cs: ChangesetId, threads: []ThreadId } = null,
    /// Queue events noted by `listener()`, handled by `pump`.
    noted: std.ArrayList(model.Event) = .empty,

    pub fn init(gpa: Allocator, q: *model.Queue, cs: *CommentStore, port: AgentPort, o: Options) Feedback {
        return .{ .gpa = gpa, .q = q, .comments = cs, .port = port, .opts = o };
    }

    pub fn deinit(f: *Feedback) void {
        for (f.requests.items) |*r| r.arena.deinit();
        f.requests.deinit(f.gpa);
        if (f.waiting) |*w| w.arena.deinit();
        f.noted.deinit(f.gpa);
    }

    // ------------------------------------------------------- requests

    /// Sends `threads` of changeset `cs` (and `extra`) to the agent that
    /// made it. `now_ms` stamps the threads.
    pub fn requestFix(f: *Feedback, cs_id: ChangesetId, threads: []const ThreadId, extra: []const u8, now_ms: i64) !Delivery {
        const cs = f.q.get(cs_id) orelse return error.UnknownChangeset;
        const ref = cs.prov.origin.agentRef() orelse return error.NotAnAgentChange;
        if (threads.len == 0 and std.mem.trim(u8, extra, " \t\r\n").len == 0) return error.NoThreads;
        var arena: std.heap.ArenaAllocator = .init(f.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const ts = try a.alloc(*const Thread, threads.len);
        for (threads, ts) |id, *t| t.* = f.comments.get(id) orelse return error.UnknownThread;
        var tx: Texts = .{ .f = f, .cs = cs };
        var mo: message.Options = .{ .max_tokens = f.opts.max_tokens };
        if (f.port.estimate) |e| mo.estimate = e;
        const msg = try message.compose(a, cs_id, cs.prov.label, ts, extra, tx.textOf(), mo);
        const tids = try a.dupe(ThreadId, threads);
        switch (f.port.status(f.port.ctx, ref.session)) {
            .running, .idle => |st| {
                const mode: SubmitMode = if (st == .running) .steer else .new_turn;
                try f.port.submit(f.port.ctx, ref.session, &msg, mode);
                try f.sent(cs_id, ref.session, tids, now_ms);
                arena.deinit();
                return if (mode == .steer) .steered else .new_turn;
            },
            .ended, .unknown => {
                if (f.waiting) |*w| w.arena.deinit();
                f.waiting = .{ .session = ref.session, .msg = msg, .arena = arena, .cs = cs_id, .threads = tids };
                return .ask_resume;
            },
        }
    }

    /// The user's answer for an ended session.
    pub fn finishEnded(f: *Feedback, choice: EndedChoice, now_ms: i64) !void {
        var w = f.waiting orelse return error.NothingWaiting;
        f.waiting = null;
        defer w.arena.deinit();
        switch (choice) {
            .cancel => {},
            .resume_session => {
                try f.port.resumeSession(f.port.ctx, w.session);
                try f.port.submit(f.port.ctx, w.session, &w.msg, .new_turn);
                try f.sent(w.cs, w.session, w.threads, now_ms);
            },
            .new_session => {
                const s = try f.port.newSession(f.port.ctx, &w.msg);
                try f.sent(w.cs, s, w.threads, now_ms);
            },
        }
    }

    /// Marks the threads sent and waits for `session`'s revision of `cs`.
    fn sent(f: *Feedback, cs_id: ChangesetId, session: SessionId, threads: []const ThreadId, now_ms: i64) !void {
        f.comments.markSent(threads, now_ms) catch |e| log.warn("marking threads sent failed: {t}", .{e});
        const cs = f.q.get(cs_id) orelse return;
        // A newer request on the same changeset replaces the older.
        for (f.requests.items, 0..) |*r, i| if (r.cs == cs_id) {
            r.arena.deinit();
            _ = f.requests.swapRemove(i);
            break;
        };
        var arena: std.heap.ArenaAllocator = .init(f.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var snaps: std.ArrayList(FileSnap) = .empty;
        for (cs.files) |*fc| {
            const text = (try f.proposed(a, fc)) orelse continue;
            try snaps.append(a, .{ .path = fc.path, .hash = try f.q.blobs.put(text) });
        }
        try f.requests.append(f.gpa, .{ .cs = cs_id, .session = session, .files = snaps.items, .threads = try a.dupe(ThreadId, threads), .arena = arena });
    }

    /// Requests still waiting for a revision.
    pub fn waitingOn(f: *const Feedback, cs: ChangesetId) bool {
        for (f.requests.items) |r| if (r.cs == cs) return true;
        return false;
    }

    // ------------------------------------------------------ revisions

    /// A queue listener that notes events for `pump`.
    pub fn listener(f: *Feedback) model.Listener {
        return .{ .ctx = f, .on = struct {
            fn on(ctx: *anyopaque, ev: *const model.Event) void {
                const self: *Feedback = @ptrCast(@alignCast(ctx));
                switch (ev.*) {
                    .submitted, .updated => if (self.requests.items.len > 0) self.noted.append(self.gpa, ev.*) catch {},
                    else => {},
                }
            }
        }.on };
    }

    /// Handles the noted events (owner thread, outside the queue's
    /// emit).
    pub fn pump(f: *Feedback) void {
        while (f.noted.items.len > 0) {
            const ev = f.noted.orderedRemove(0);
            switch (ev) {
                .submitted => |id| f.onSubmitted(id) catch |e| log.warn("linking revision {f} failed: {t}", .{ id, e }),
                .updated => |id| f.onUpdated(id) catch |e| log.warn("revision of {f} failed: {t}", .{ id, e }),
                else => {},
            }
        }
    }

    fn requestIndex(f: *const Feedback, cs: ChangesetId) ?usize {
        for (f.requests.items, 0..) |r, i| if (r.cs == cs) return i;
        return null;
    }

    /// The agent's edits folded into a changeset that waits for its
    /// revision: when its proposed texts changed, that is the revision.
    pub fn onUpdated(f: *Feedback, id: ChangesetId) !void {
        const ri = f.requestIndex(id) orelse return;
        const r = &f.requests.items[ri];
        const cs = f.q.getMut(id) orelse return;
        var scratch: std.heap.ArenaAllocator = .init(f.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var changed = false;
        for (cs.files) |*fc| {
            const snap = findSnap(r.files, fc.path) orelse continue;
            const now = (try f.proposed(a, fc)) orelse continue;
            if (std.mem.eql(u8, &model.blobHash(now), &snap.hash)) continue;
            if (!changed) {
                changed = true;
                cs.revision += 1;
            }
            fc.previous = snap.hash;
            const old = (try f.q.blobs.get(a, snap.hash)) orelse continue;
            try f.carry(id, fc.path, old, now);
        }
        if (!changed) return;
        f.q.persist(id);
        r.arena.deinit();
        _ = f.requests.swapRemove(ri);
    }

    /// A new changeset of the session a request waits on, touching one
    /// of its files, supersedes the old one.
    pub fn onSubmitted(f: *Feedback, id: ChangesetId) !void {
        const cs = f.q.getMut(id) orelse return;
        if (cs.state == .superseded) return; // all folded: `onUpdated`
        const ref = cs.prov.origin.agentRef() orelse return;
        var ri: ?usize = null;
        for (f.requests.items, 0..) |r, i| {
            if (r.session != ref.session or r.cs == id) continue;
            for (cs.files) |fc| if (fc.state != .superseded and findSnap(r.files, fc.path) != null) {
                ri = i;
                break;
            };
            if (ri != null) break;
        }
        const i = ri orelse return;
        const r = &f.requests.items[i];
        cs.supersedes = r.cs;
        f.q.persist(id);
        _ = try f.comments.copyOpen(r.cs, id);
        var scratch: std.heap.ArenaAllocator = .init(f.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        for (cs.files) |*fc| {
            const snap = findSnap(r.files, fc.path) orelse continue;
            const now = (try f.proposed(a, fc)) orelse continue;
            const old = (try f.q.blobs.get(a, snap.hash)) orelse continue;
            try f.carry(id, fc.path, old, now);
        }
        r.arena.deinit();
        _ = f.requests.swapRemove(i);
    }

    /// Re-anchors `target`'s threads on `path` from `old` to `now` and
    /// tags the ones whose lines changed.
    fn carry(f: *Feedback, target: ChangesetId, path: []const u8, old: []const u8, now: []const u8) !void {
        var before: anchor_mod.LineHashes = try .init(f.gpa, old);
        defer before.deinit(f.gpa);
        var after: anchor_mod.LineHashes = try .init(f.gpa, now);
        defer after.deinit(f.gpa);
        for (f.comments.threadsOf(target)) |t| {
            if (t.resolved or t.anchor.side != .new or !std.mem.eql(u8, t.anchor.path, path)) continue;
            // Unchanged when its lines, as they were, are still there.
            const was = before.hashOf(t.anchor.lines) orelse t.anchor.content_hash;
            const same = anchor_mod.relocate(&after, t.anchor.lines, was, null) != null;
            if (!same and t.sent_ms != null) try f.comments.setAddressed(t.id, true);
        }
        _ = try f.comments.reanchor(target, path, now, .{});
    }

    /// Interdiff of `path`: `older`'s previous proposal against its
    /// current one (`older == newer`), or `older`'s proposal against
    /// `newer`'s. Null when the file has no such texts.
    pub fn interdiff(f: *Feedback, older: ChangesetId, newer: ChangesetId, path: []const u8, arena: Allocator) !?InterdiffDocs {
        const n = f.q.get(newer) orelse return error.UnknownChangeset;
        const nf = &n.files[n.fileIndex(path) orelse return null];
        const right = (try f.proposed(arena, nf)) orelse return null;
        if (older == newer) {
            const h = nf.previous orelse return null;
            const left = (try f.q.blobs.get(arena, h)) orelse return error.MissingBlob;
            return .{
                .left = left,
                .right = right,
                .left_label = try std.fmt.allocPrint(arena, "revision {d}", .{n.revision - 1}),
                .right_label = try std.fmt.allocPrint(arena, "revision {d}", .{n.revision}),
            };
        }
        const o = f.q.get(older) orelse return error.UnknownChangeset;
        const of = &o.files[o.fileIndex(path) orelse return null];
        return .{
            .left = (try f.proposed(arena, of)) orelse return null,
            .right = right,
            .left_label = try std.fmt.allocPrint(arena, "{f}", .{older}),
            .right_label = try std.fmt.allocPrint(arena, "{f}", .{newer}),
        };
    }

    /// A file's proposed text, in `arena`; null without text.
    fn proposed(f: *Feedback, arena: Allocator, fc: *const FileChange) !?[]const u8 {
        const t = switch (fc.content) {
            .text => |*t| t,
            else => return null,
        };
        const base: []const u8 = if (t.base) |b| (try f.q.blobs.get(arena, b.hash)) orelse return error.MissingBlob else "";
        return try t.edits.applyToSlice(arena, base);
    }
};

fn findSnap(files: []const FileSnap, path: []const u8) ?FileSnap {
    for (files) |s| if (std.mem.eql(u8, s.path, path)) return s;
    return null;
}

/// Quotes come from the changeset's own texts.
const Texts = struct {
    f: *Feedback,
    cs: *const Changeset,

    fn textOf(t: *Texts) message.TextOf {
        return .{ .ctx = t, .text = text };
    }

    fn text(ctx: *anyopaque, arena: Allocator, path: []const u8, side: comments.Side) anyerror!?[]const u8 {
        const t: *Texts = @ptrCast(@alignCast(ctx));
        const fc = &t.cs.files[t.cs.fileIndex(path) orelse return null];
        if (side == .new) return t.f.proposed(arena, fc);
        const tc = switch (fc.content) {
            .text => |*x| x,
            else => return null,
        };
        return if (tc.base) |b| try t.f.q.blobs.get(arena, b.hash) else "";
    }
};
