//! The lane landing queue (E09.F06.S03.T01): approved lanes go through
//! rebase, checks and landing, one ticket at a time.
//!
//! 1. `submit` builds a land proposal (a detached preview operation that
//!    rebases the lane's stack onto the target bookmark and moves it),
//!    sends it to the `ReviewPort`, and marks the lane `awaiting_review`.
//!    A lane whose policy holds `may_land_without_review` (set by a
//!    human) skips review.
//! 2. On approval the ticket is queued. Processing rebuilds the landing
//!    against the repo as it is then (trunk may have moved): the stack is
//!    rebased with path-level three-way tree merges, commits left empty
//!    are dropped (`abandon_empty`), and with `squash` the whole stack
//!    becomes one change. The result is a detached operation that also
//!    moves the bookmark and marks the lane `landed`.
//! 3. Each check runs through the `CheckPort` in a workspace the
//!    `CheckoutPort` materializes for the landed commit; logs stream as
//!    events.
//! 4. When all pass the preview is adopted, so the bookmark, the rebased
//!    commits and the lane status change in one operation (and one undo).
//!
//! A conflict, a failed check or a rejection discards the preview and
//! returns the lane to `active` with the reason; bookmarks never move. The
//! ticket lives in the lane record (`status` and a `landing` extra holding
//! JSON), so it survives restarts (`resumeAll`) and undo. Landing never
//! pushes.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const op_mod = @import("../oplog/operation.zig");
const view_mod = @import("../oplog/view.zig");
const repo_mod = @import("../oplog/repo.zig");
const preview = @import("../oplog/preview.zig");
const adopt_mod = @import("../oplog/adopt.zig");
const rebase_mod = @import("../oplog/rebase.zig");
const mutable_mod = @import("../oplog/mutable_repo.zig");
const tree_merge = @import("../merge/tree_merge.zig");
const ports = @import("ports.zig");
const ObjectId = id_mod.ObjectId;
const Change = object.Change;
const Repo = repo_mod.Repo;
const LaneRecord = view_mod.LaneRecord;
const Allocator = std.mem.Allocator;

pub const CheckSpec = ports.CheckSpec;
pub const ReviewId = ports.ReviewId;

pub const Strategy = enum { rebase, squash };

pub const LandOptions = struct {
    target_bookmark: []const u8 = "main",
    strategy: Strategy = .rebase,
    checks: []const CheckSpec = &.{},
    abandon_empty: bool = true,
};

pub const LandingState = enum {
    submitted,
    in_review,
    approved,
    rebasing,
    checking,
    landed,
    returned_conflict,
    returned_checks_failed,
    rejected,
    cancelled,

    pub fn finished(s: LandingState) bool {
        return switch (s) {
            .landed, .returned_conflict, .returned_checks_failed, .rejected, .cancelled => true,
            else => false,
        };
    }

    /// The lane `status` that goes with the state.
    pub fn laneStatus(s: LandingState) []const u8 {
        return switch (s) {
            .submitted, .in_review => "awaiting_review",
            .approved, .rebasing, .checking => "landing",
            .landed => "landed",
            else => "active",
        };
    }
};

pub const LandingTicket = struct { id: u64, lane: []const u8, review: ReviewId, state: LandingState };

/// Lane policy word that lets a lane land without review.
pub const no_review_policy = "may_land_without_review";
/// The lane extra holding the ticket.
pub const landing_key = "landing";

/// Materializes a commit into a workspace for checks (E09.F03.S03.T01).
pub const CheckoutPort = struct {
    ctx: *anyopaque,
    /// Returns the workspace root, valid until `release`.
    materialize: *const fn (ctx: *anyopaque, commit: ObjectId) anyerror![]const u8,
    release: *const fn (ctx: *anyopaque, root: []const u8) void,
};

pub const Event = struct {
    ticket: u64,
    lane: []const u8,
    state: LandingState,
    /// Why the lane came back, or what landed.
    reason: []const u8 = "",
    /// For check output: the check and a chunk of its log (`state` is
    /// `.checking`).
    check: []const u8 = "",
    log: []const u8 = "",
};

/// Every event the queue emitted, plus listeners called as they happen
/// (ScmService forwards them to the UI, E13 and E10).
pub const EventStream = struct {
    arena_state: std.heap.ArenaAllocator,
    items: std.ArrayList(Event) = .empty,
    listeners: std.ArrayList(Listener) = .empty,

    pub const Listener = struct { ctx: *anyopaque, on: *const fn (ctx: *anyopaque, e: *const Event) void };

    pub fn listen(s: *EventStream, l: Listener) !void {
        try s.listeners.append(s.arena_state.allocator(), l);
    }

    fn emit(s: *EventStream, e: Event) !void {
        const a = s.arena_state.allocator();
        var owned = e;
        owned.lane = try a.dupe(u8, e.lane);
        owned.reason = try a.dupe(u8, e.reason);
        owned.check = try a.dupe(u8, e.check);
        owned.log = try a.dupe(u8, e.log);
        try s.items.append(a, owned);
        for (s.listeners.items) |l| l.on(l.ctx, &owned);
    }
};

/// What the `landing` extra records.
const Persisted = struct {
    ticket: u64,
    state: LandingState,
    review: ReviewId = 0,
    target: []const u8,
    strategy: Strategy = .rebase,
    abandon_empty: bool = true,
    checks: []const CheckSpec = &.{},
    reason: []const u8 = "",
};

const Ticket = struct {
    id: u64,
    lane: []const u8,
    review: ReviewId,
    state: LandingState,
    opts: LandOptions,
};

pub const Config = struct {
    review: ports.ReviewPort,
    checks: ?ports.CheckPort = null,
    checkout: ?CheckoutPort = null,
    notify: ?ports.NotificationPort = null,
    /// Recorded on the queue's operations.
    user: []const u8 = "zg",
    host: []const u8 = "",
    workspace: []const u8 = "default",
};

pub const LandingQueue = struct {
    gpa: Allocator,
    /// Owns tickets' strings and options.
    arena_state: std.heap.ArenaAllocator,
    cfg: Config,
    /// The repo at the latest operation the queue saw; replaced as the
    /// queue commits (the caller's handle is not closed).
    repo: *Repo,
    owns_repo: bool = false,
    tickets: std.ArrayList(Ticket) = .empty,
    /// Approved tickets waiting to be processed, oldest first.
    queued: std.ArrayList(u64) = .empty,
    next_id: u64 = 1,
    stream: EventStream,
    busy: bool = false,

    pub fn init(gpa: Allocator, repo: *Repo, cfg: Config) LandingQueue {
        return .{ .gpa = gpa, .arena_state = .init(gpa), .cfg = cfg, .repo = repo, .stream = .{ .arena_state = .init(gpa) } };
    }

    pub fn deinit(q: *LandingQueue) void {
        if (q.owns_repo) q.repo.close();
        q.tickets.deinit(q.gpa);
        q.queued.deinit(q.gpa);
        q.stream.arena_state.deinit();
        q.arena_state.deinit();
    }

    pub fn events(q: *LandingQueue) *EventStream {
        return &q.stream;
    }

    pub fn ticket(q: *const LandingQueue, id: u64) ?LandingTicket {
        for (q.tickets.items) |t| if (t.id == id) return .{ .id = t.id, .lane = t.lane, .review = t.review, .state = t.state };
        return null;
    }

    fn find(q: *LandingQueue, id: u64) ?*Ticket {
        for (q.tickets.items) |*t| if (t.id == id) return t;
        return null;
    }

    /// The repo the queue last saw.
    pub fn current(q: *const LandingQueue) *Repo {
        return q.repo;
    }

    /// Loads the latest operation, in case others committed.
    pub fn refresh(q: *LandingQueue) !void {
        const fresh = try Repo.load(q.gpa, q.repo.io, q.repo.repo_dir, q.repo.store, q.repo.opts, .head);
        q.setRepo(fresh);
    }

    fn setRepo(q: *LandingQueue, r: *Repo) void {
        if (q.owns_repo) q.repo.close();
        q.repo = r;
        q.owns_repo = true;
    }

    fn meta(q: *LandingQueue, description: []const u8) op_mod.OpMeta {
        const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(q.repo.io, .real).nanoseconds, std.time.ns_per_ms));
        return .{
            .start_ms = now,
            .end_ms = now,
            .description = description,
            .user = q.cfg.user,
            .host = q.cfg.host,
            .workspace = q.cfg.workspace,
            .actor = .systemTask("landing"),
            .tags = &.{},
        };
    }

    fn setState(q: *LandingQueue, t: *Ticket, s: LandingState, reason: []const u8) !void {
        t.state = s;
        try q.stream.emit(.{ .ticket = t.id, .lane = t.lane, .state = s, .reason = reason });
    }

    /// Submits lane `lane` for landing.
    pub fn submit(q: *LandingQueue, lane: []const u8, o: LandOptions) !LandingTicket {
        try q.refresh();
        const rec = q.repo.view().lane(lane) orelse return error.UnknownLane;
        for (q.tickets.items) |t| {
            if (std.mem.eql(u8, t.lane, lane) and !t.state.finished()) return error.AlreadySubmitted;
        }
        const a = q.arena_state.allocator();
        try q.tickets.append(q.gpa, .{ .id = q.next_id, .lane = try a.dupe(u8, lane), .review = 0, .state = .submitted, .opts = try ownOptions(a, o) });
        q.next_id += 1;
        const t = &q.tickets.items[q.tickets.items.len - 1];
        try q.stream.emit(.{ .ticket = t.id, .lane = t.lane, .state = .submitted });

        if (hasPolicy(rec.policy, no_review_policy)) {
            try q.persist(t, .approved, "", "land lane (no review required)");
            try q.setState(t, .approved, "lane policy allows landing without review");
            try q.queued.append(q.gpa, t.id);
            try q.pump();
            return q.ticket(t.id).?;
        }

        // The proposal shows the landing as it would happen now.
        var built = try q.build(t, .proposal);
        defer built.deinit();
        switch (built.outcome) {
            .preview => |p| {
                const proposal: ports.Proposal = .{
                    .kind = .land,
                    .preview_op = p.op,
                    .summary = try std.fmt.allocPrint(built.arena(), "Land lane {s} onto {s} ({d} change{s})", .{ lane, t.opts.target_bookmark, p.changes.len, if (p.changes.len == 1) "" else "s" }),
                    .changes = p.changes,
                    .provenance = .{ .actor = .systemTask("landing") },
                    .lane = lane,
                };
                t.review = q.cfg.review.submitProposal(&proposal) catch |e| {
                    preview.discard(q.repo, p.op.op);
                    try q.finish(t, .cancelled, "review submission failed");
                    return e;
                };
            },
            .conflict => |paths| {
                try q.finish(t, .returned_conflict, paths);
                return q.ticket(t.id).?;
            },
            .empty => {
                try q.finish(t, .cancelled, "the lane has no changes to land");
                return q.ticket(t.id).?;
            },
        }
        try q.persist(t, .in_review, "", "submit lane for landing");
        try q.setState(t, .in_review, "");
        return q.ticket(t.id).?;
    }

    /// Applies a reviewer's decision on a land proposal.
    pub fn onReviewDecision(q: *LandingQueue, review: ReviewId, d: ports.ReviewDecision) !void {
        const t = for (q.tickets.items) |*t| {
            if (t.review == review and !t.state.finished()) break t;
        } else return error.UnknownReview;
        if (t.state != .in_review) return;
        switch (d.verdict) {
            .reject => {
                const reason = if (d.note.len > 0) d.note else "rejected in review";
                try q.finish(t, .rejected, reason);
            },
            .approve => {
                try q.refresh();
                try q.persist(t, .approved, "", "approve lane landing");
                try q.setState(t, .approved, d.reviewer);
                try q.queued.append(q.gpa, t.id);
                try q.pump();
            },
        }
    }

    /// Asks the review port about tickets still in review (for ports that
    /// do not call back, and after a restart).
    pub fn poll(q: *LandingQueue) !void {
        var i: usize = 0;
        while (i < q.tickets.items.len) : (i += 1) {
            const t = q.tickets.items[i];
            if (t.state != .in_review) continue;
            switch (q.cfg.review.statusOf(t.review)) {
                .approved => try q.onReviewDecision(t.review, .{ .verdict = .approve, .reviewer = "review" }),
                .rejected => try q.onReviewDecision(t.review, .{ .verdict = .reject, .reviewer = "review" }),
                .cancelled, .unknown => try q.finish(q.find(t.id).?, .cancelled, "the review item is gone"),
                .in_review => {},
            }
        }
    }

    /// Withdraws a ticket that is not being processed.
    pub fn cancel(q: *LandingQueue, id: u64) void {
        const t = q.find(id) orelse return;
        if (t.state.finished() or t.state == .rebasing or t.state == .checking) return;
        for (q.queued.items, 0..) |x, i| if (x == id) {
            _ = q.queued.orderedRemove(i);
            break;
        };
        q.finish(t, .cancelled, "cancelled") catch {
            // The lane record keeps its old status; the ticket is gone
            // from this queue either way.
            t.state = .cancelled;
        };
    }

    /// Rebuilds the queue from the lane records after a restart: tickets
    /// in review are polled, approved ones processed again from scratch.
    pub fn resumeAll(q: *LandingQueue) !void {
        try q.refresh();
        const a = q.arena_state.allocator();
        for (q.repo.view().lanes) |l| {
            const p = readPersisted(a, l) orelse continue;
            if (p.state.finished()) {
                q.next_id = @max(q.next_id, p.ticket + 1);
                continue;
            }
            if (q.find(p.ticket) != null) continue;
            try q.tickets.append(q.gpa, .{
                .id = p.ticket,
                .lane = try a.dupe(u8, l.name),
                .review = p.review,
                .state = if (p.state == .submitted) .in_review else p.state,
                .opts = .{ .target_bookmark = p.target, .strategy = p.strategy, .checks = p.checks, .abandon_empty = p.abandon_empty },
            });
            q.next_id = @max(q.next_id, p.ticket + 1);
            switch (p.state) {
                .approved, .rebasing, .checking => {
                    q.tickets.items[q.tickets.items.len - 1].state = .approved;
                    try q.queued.append(q.gpa, p.ticket);
                },
                else => {},
            }
        }
        try q.poll();
        try q.pump();
    }

    /// Processes queued tickets in order.
    pub fn pump(q: *LandingQueue) !void {
        if (q.busy) return;
        q.busy = true;
        defer q.busy = false;
        while (q.queued.items.len > 0) {
            const id = q.queued.orderedRemove(0);
            const t = q.find(id) orelse continue;
            if (t.state != .approved) continue;
            try q.land(t);
        }
    }

    fn land(q: *LandingQueue, t: *Ticket) !void {
        try q.refresh();
        // Someone may have moved trunk between building and adopting; a
        // fresh build is cheap, so retry a few times.
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            try q.setState(t, .rebasing, "");
            var built = try q.build(t, .landing);
            defer built.deinit();
            const p = switch (built.outcome) {
                .preview => |p| p,
                .conflict => |paths| return q.finish(t, .returned_conflict, paths),
                .empty => return q.finish(t, .cancelled, "the lane has no changes to land"),
            };
            if (try q.runChecks(t, p.top)) |failure| {
                preview.discard(q.repo, p.op.op);
                return q.finish(t, .returned_checks_failed, failure);
            }
            var desc_buf: [256]u8 = undefined;
            const desc = std.fmt.bufPrint(&desc_buf, "land lane {s}", .{t.lane}) catch "land lane";
            var res = try adopt_mod.adopt(q.repo, p.op, q.meta(desc));
            defer res.deinit();
            switch (res) {
                .adopted => |op| {
                    q.setRepo(try q.repo.reopen(op, false));
                    t.state = .landed;
                    var hex: [64]u8 = undefined;
                    const reason = try std.fmt.allocPrint(built.arena(), "{s} is now {s}", .{ t.opts.target_bookmark, p.top.hex(&hex)[0..12] });
                    try q.stream.emit(.{ .ticket = t.id, .lane = t.lane, .state = .landed, .reason = reason });
                    q.notifyOwner(t, .info, "Lane landed", reason);
                    return;
                },
                .conflicted => {
                    preview.discard(q.repo, p.op.op);
                    if (attempt >= 2) return q.finish(t, .returned_conflict, "the repository kept changing while landing");
                    try q.refresh();
                },
            }
        }
    }

    /// Null when every check passed, else what failed (with the log tail).
    fn runChecks(q: *LandingQueue, t: *Ticket, top: ObjectId) !?[]const u8 {
        if (t.opts.checks.len == 0) return null;
        const port = q.cfg.checks orelse return "checks are configured but no check runner is available";
        const co = q.cfg.checkout orelse return "checks are configured but no workspace can be materialized";
        try q.setState(t, .checking, "");
        const root = try co.materialize(co.ctx, top);
        defer co.release(co.ctx, root);
        var fwd: LogForward = .{ .q = q, .t = t };
        var sink: ports.CheckSink = .{ .ctx = &fwd, .onLog = LogForward.onLog };
        for (t.opts.checks) |*spec| {
            const r = port.runCheck(root, spec, &sink) catch |e| {
                return try std.fmt.allocPrint(q.arena_state.allocator(), "check {s} could not run: {t}", .{ spec.name, e });
            };
            if (r.passed) continue;
            const why = if (r.timed_out) "timed out" else "failed";
            return try std.fmt.allocPrint(q.arena_state.allocator(), "check {s} {s}\n{s}", .{ spec.name, why, r.log_tail });
        }
        return null;
    }

    const LogForward = struct {
        q: *LandingQueue,
        t: *Ticket,
        fn onLog(ctx: *anyopaque, check: []const u8, chunk: []const u8) void {
            const f: *LogForward = @ptrCast(@alignCast(ctx));
            f.q.stream.emit(.{ .ticket = f.t.id, .lane = f.t.lane, .state = .checking, .check = check, .log = chunk }) catch {};
        }
    };

    /// Ends a ticket that did not land: records the state and reason on
    /// the lane (back to `active`) and tells the owner.
    fn finish(q: *LandingQueue, t: *Ticket, s: LandingState, reason: []const u8) !void {
        try q.refresh();
        if (q.repo.view().lane(t.lane) != null) try q.persist(t, s, reason, "return lane from landing");
        try q.setState(t, s, reason);
        const title = switch (s) {
            .returned_conflict => "Lane needs a rebase: conflicts with trunk",
            .returned_checks_failed => "Lane checks failed",
            .rejected => "Lane landing rejected",
            else => "Lane landing cancelled",
        };
        q.notifyOwner(t, if (s == .cancelled) .info else .failure, title, reason);
    }

    fn notifyOwner(q: *LandingQueue, t: *Ticket, level: ports.Notification.Level, title: []const u8, body: []const u8) void {
        const port = q.cfg.notify orelse return;
        const owner = if (q.repo.view().lane(t.lane)) |l| l.owner else "";
        const n: ports.Notification = .{ .owner = owner, .level = level, .title = title, .body = body, .lane = t.lane, .review = if (t.review == 0) null else t.review };
        port.send(&n);
    }

    /// Commits an operation setting the lane's status and ticket.
    fn persist(q: *LandingQueue, t: *Ticket, s: LandingState, reason: []const u8, description: []const u8) !void {
        const tx = try q.repo.startTransaction(q.meta(description));
        errdefer tx.discard();
        const rec = q.repo.view().lane(t.lane) orelse return error.UnknownLane;
        try tx.mutRepo().setLane(try withLanding(tx.arena(), rec, t, s, reason, tx.meta.end_ms));
        q.setRepo(try tx.commit());
    }

    const Built = struct {
        arena_state: std.heap.ArenaAllocator,
        outcome: union(enum) {
            preview: struct { op: preview.DetachedOp, top: ObjectId, changes: []const ObjectId },
            /// Conflicting paths, one per line.
            conflict: []const u8,
            empty,
        },

        fn arena(b: *Built) Allocator {
            return b.arena_state.allocator();
        }

        fn deinit(b: *Built) void {
            b.arena_state.deinit();
        }
    };

    /// The landing of `t` against the current repo, as a detached
    /// operation: the stack rebased (or squashed) onto the target, the
    /// target moved, the lane marked landed.
    fn build(q: *LandingQueue, t: *Ticket, purpose: preview.DetachedOp.Purpose) !Built {
        var out: Built = .{ .arena_state = .init(q.gpa), .outcome = .empty };
        errdefer out.deinit();
        const a = out.arena();
        const v = q.repo.view();
        const rec = v.lane(t.lane) orelse return error.UnknownLane;
        const trunk = v.bookmark(t.opts.target_bookmark).asNormal() orelse {
            out.outcome = .{ .conflict = try std.fmt.allocPrint(a, "bookmark {s} is missing or conflicted", .{t.opts.target_bookmark}) };
            return out;
        };
        const wc = v.wcCommit(rec.workspace) orelse return out;

        var desc_buf: [256]u8 = undefined;
        const desc = std.fmt.bufPrint(&desc_buf, "land-rebase lane {s} (pending checks)", .{t.lane}) catch "land-rebase lane";
        const tx = try q.repo.startTransaction(q.meta(desc));
        var tx_live = true;
        defer if (tx_live) tx.discard();
        const m = tx.mutRepo();

        const stack = try laneStack(m, a, wc, rec.base, trunk);
        if (stack.len == 0) return out;

        var tm = tree_merge.TreeMerger.init(q.gpa, q.repo.store, m.batch);
        defer tm.deinit();
        const trunk_change = try m.readChange(a, trunk);
        const trunk_tree = trunk_change.tree() orelse {
            out.outcome = .{ .conflict = "trunk has unresolved conflicts" };
            return out;
        };

        var top: ObjectId = trunk;
        var changes: std.ArrayList(ObjectId) = .empty;
        switch (t.opts.strategy) {
            .rebase => {
                // Old commit → what replaces it (itself when unchanged).
                var mapped: std.AutoHashMapUnmanaged(ObjectId, ObjectId) = .empty;
                var trees: std.AutoHashMapUnmanaged(ObjectId, ObjectId) = .empty;
                try trees.put(a, trunk, trunk_tree);
                for (stack) |old| {
                    const c = try m.readChange(a, old);
                    var parents: std.ArrayList(ObjectId) = .empty;
                    for (c.parents) |p| {
                        const np = mapped.get(p) orelse trunk;
                        for (parents.items) |x| {
                            if (x.eql(np)) break;
                        } else try parents.append(a, np);
                    }
                    const own_tree = c.tree() orelse {
                        try tm.conflicts.append(a, try std.fmt.allocPrint(a, "(change {s} already has conflicts)", .{c.description}));
                        continue;
                    };
                    const old_parent_tree = if (c.parents.len == 0) null else try treeOf(m, a, &trees, c.parents[0]);
                    const new_parent_tree = try treeOf(m, a, &trees, parents.items[0]);
                    const merged = (try tm.merge3(old_parent_tree, new_parent_tree, own_tree)) orelse continue;
                    if (t.opts.abandon_empty and parents.items.len == 1 and merged.eql(new_parent_tree)) {
                        try m.abandon(old, parents.items);
                        try mapped.put(a, old, parents.items[0]);
                        continue;
                    }
                    var n = c;
                    n.parents = parents.items;
                    n.tree_terms = try a.dupe(ObjectId, &.{merged});
                    n.predecessors = &.{};
                    n.sig = null;
                    const id = if (sameIds(c.parents, parents.items) and merged.eql(own_tree)) old else try m.rewriteChange(old, n);
                    try mapped.put(a, old, id);
                    try trees.put(a, id, merged);
                    try changes.append(a, id);
                    top = id;
                }
            },
            .squash => {
                // One change: the whole stack's diff applied to trunk.
                const first = try m.readChange(a, stack[0]);
                const last = try m.readChange(a, stack[stack.len - 1]);
                const base_tree = if (first.parents.len == 0) null else (try m.readChange(a, first.parents[0])).tree();
                const top_tree = last.tree() orelse return error.ConflictedLane;
                if (try tm.merge3(base_tree, trunk_tree, top_tree)) |merged| {
                    var description: std.ArrayList(u8) = .empty;
                    var preds: std.ArrayList(ObjectId) = .empty;
                    for (stack) |old| {
                        const c = try m.readChange(a, old);
                        try preds.append(a, old);
                        const d = std.mem.trim(u8, c.description, " \n");
                        if (d.len == 0) continue;
                        if (description.items.len > 0) try description.appendSlice(a, "\n\n");
                        try description.appendSlice(a, d);
                    }
                    if (!(t.opts.abandon_empty and merged.eql(trunk_tree))) {
                        var n = last;
                        n.parents = try a.dupe(ObjectId, &.{trunk});
                        n.tree_terms = try a.dupe(ObjectId, &.{merged});
                        n.change_id = first.change_id;
                        n.author = first.author;
                        n.description = description.items;
                        n.predecessors = preds.items;
                        n.sig = null;
                        top = try m.writeChange(n);
                        try changes.append(a, top);
                    }
                    for (stack) |old| {
                        _ = m.view.heads.swapRemove(old);
                        if (top.eql(trunk)) try m.abandon(old, &.{trunk}) else try m.rewritten.put(m.gpa, old, top);
                    }
                }
            },
        }
        if (tm.conflicts.items.len > 0) {
            out.outcome = .{ .conflict = try std.mem.join(a, "\n", tm.conflicts.items) };
            return out;
        }
        if (changes.items.len == 0) return out;

        // Bookmarks and working copies on the old stack follow it.
        _ = try m.rebaseDescendants(rebase_mod.reparent, q.repo.opts.index);
        var target: ?ObjectId = top;
        try m.setBookmark(t.opts.target_bookmark, .normal(&target));
        var landed = try withLanding(tx.arena(), rec, t, .landed, "", tx.meta.end_ms);
        landed.base = top;
        try m.setLane(landed);
        tx_live = false;
        const op = try preview.commitDetached(tx, purpose);
        out.outcome = .{ .preview = .{ .op = op, .top = top, .changes = changes.items } };
        return out;
    }
};

fn treeOf(m: *mutable_mod.MutableRepo, a: Allocator, cache: *std.AutoHashMapUnmanaged(ObjectId, ObjectId), commit: ObjectId) !ObjectId {
    if (cache.get(commit)) |t| return t;
    const c = try m.readChange(a, commit);
    const t = c.tree() orelse return error.ConflictedParent;
    try cache.put(a, commit, t);
    return t;
}

fn sameIds(x: []const ObjectId, y: []const ObjectId) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, r| if (!p.eql(r)) return false;
    return true;
}

/// The lane's commits, parents first: ancestors of `wc` down to (not
/// including) `base` and `trunk`. A path that reaches a root without
/// meeting either means the lane is not built on its base.
fn laneStack(m: *mutable_mod.MutableRepo, a: Allocator, wc: ObjectId, base: ?ObjectId, trunk: ObjectId) ![]const ObjectId {
    var order: std.ArrayList(ObjectId) = .empty;
    var seen: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
    const Frame = struct { id: ObjectId, expanded: bool };
    var stack: std.ArrayList(Frame) = .empty;
    try stack.append(a, .{ .id = wc, .expanded = false });
    while (stack.pop()) |f| {
        if (f.expanded) {
            try order.append(a, f.id);
            continue;
        }
        if (f.id.eql(trunk) or (base != null and f.id.eql(base.?))) continue;
        if ((try seen.getOrPut(a, f.id)).found_existing) continue;
        const c = try m.readChange(a, f.id);
        if (c.parents.len == 0) return error.LaneNotOnBase;
        try stack.append(a, .{ .id = f.id, .expanded = true });
        for (c.parents) |p| try stack.append(a, .{ .id = p, .expanded = false });
    }
    return order.items;
}

fn hasPolicy(policy: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, policy, " ,;");
    while (it.next()) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn ownOptions(a: Allocator, o: LandOptions) !LandOptions {
    const checks = try a.alloc(CheckSpec, o.checks.len);
    for (o.checks, checks) |c, *d| {
        const argv = try a.alloc([]const u8, c.command.len);
        for (c.command, argv) |x, *y| y.* = try a.dupe(u8, x);
        d.* = .{ .name = try a.dupe(u8, c.name), .command = argv, .timeout_s = c.timeout_s };
    }
    return .{ .target_bookmark = try a.dupe(u8, o.target_bookmark), .strategy = o.strategy, .checks = checks, .abandon_empty = o.abandon_empty };
}

/// `rec` with its status and `landing` extra set for ticket `t` in state
/// `s` (strings in `a`).
fn withLanding(a: Allocator, rec: LaneRecord, t: *const Ticket, s: LandingState, reason: []const u8, now_ms: i64) !LaneRecord {
    const p: Persisted = .{
        .ticket = t.id,
        .state = s,
        .review = t.review,
        .target = t.opts.target_bookmark,
        .strategy = t.opts.strategy,
        .abandon_empty = t.opts.abandon_empty,
        .checks = t.opts.checks,
        .reason = reason,
    };
    const json = try std.json.Stringify.valueAlloc(a, p, .{});
    var extra: std.ArrayList(object.Extra) = .empty;
    var placed = false;
    for (rec.extra) |e| {
        const order = std.mem.order(u8, e.key, landing_key);
        if (order == .eq) continue;
        if (order == .gt and !placed) {
            try extra.append(a, .{ .key = landing_key, .value = json });
            placed = true;
        }
        try extra.append(a, e);
    }
    if (!placed) try extra.append(a, .{ .key = landing_key, .value = json });
    var out = rec;
    out.status = s.laneStatus();
    out.extra = extra.items;
    // The newer lane record wins a concurrent merge.
    out.updated_ms = @max(now_ms, rec.updated_ms + 1);
    return out;
}

/// The ticket recorded on lane `l`, if any.
pub fn readPersisted(a: Allocator, l: LaneRecord) ?Persisted {
    for (l.extra) |e| {
        if (!std.mem.eql(u8, e.key, landing_key)) continue;
        return std.json.parseFromSliceLeaky(Persisted, a, e.value, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null;
    }
    return null;
}

/// The landing state recorded on lane `l` (for `zg scm lane status`).
pub fn laneState(a: Allocator, l: LaneRecord) ?struct { ticket: u64, state: LandingState, reason: []const u8 } {
    const p = readPersisted(a, l) orelse return null;
    return .{ .ticket = p.ticket, .state = p.state, .reason = p.reason };
}
