//! E09's `ReviewPort` (E12.F05.S03.T01): every AI SCM proposal (a
//! description, a split, a conflict resolution, a lane landing) becomes a
//! review item, a changeset with `origin = .scm_proposal`, whose files
//! show what the preview operation would change. Those files are for
//! reading only: the `Applier` refuses such changesets, and decisions go
//! through `decide`, which hands them to E09 (`ScmActions`): adopt or
//! discard the preview, or forward a landing decision to the
//! `LandingQueue`. Landing states come back through `onLanding` and show
//! on the item; a lane returned for a conflict or failed checks reopens it.
//!
//! Owner thread (the queue's): E09 calls `submit` and `status` on its
//! worker, so whoever binds the port runs them under the queue's owner
//! (the IDE's glue mutex, the CLI's single thread).

const std = @import("std");
const zg_scm = @import("zg_scm");
const model = @import("../model/root.zig");

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const Queue = model.Queue;
const Proposal = zg_scm.Proposal;
const ReviewId = zg_scm.ReviewId;
const ReviewStatus = zg_scm.ReviewStatus;
const LandingState = zg_scm.ai.landing.LandingState;
const LandingQueue = zg_scm.ai.landing.LandingQueue;

/// One path of a proposal: its text before (`base`, null when the
/// proposal creates it) and after (`new`, null when it deletes it). Paths
/// are workspace paths (normalized like any other). A `describe` proposal
/// has one per described commit, `.zigguro/scm/description/<change>`,
/// with the old and new description. E09's `proposal_files.FileChange`.
pub const PreviewFile = zg_scm.ai.proposal_files.FileChange;

/// E09's read model: the per-path difference a proposal makes, in
/// `arena`.
pub const PreviewFiles = struct {
    ctx: *anyopaque,
    files: *const fn (ctx: *anyopaque, arena: Allocator, proposal: *const Proposal) anyerror![]const PreviewFile,

    /// Reads a repository's proposals (`zg_scm.ai.proposal_files`).
    pub fn ofRepo(pf: *zg_scm.ai.proposal_files.ProposalFiles) PreviewFiles {
        return .{ .ctx = pf, .files = zg_scm.ai.proposal_files.ProposalFiles.filesFn };
    }
};

/// A reviewer's decision on a whole proposal, per kind.
pub const ScmDecision = union(enum) {
    /// The text the reviewer edited, if they did.
    describe: union(enum) { approve: ?[]const u8, reject },
    split: Verdict,
    resolve: Verdict,
    land: zg_scm.ReviewDecision,

    pub const Verdict = enum { approve, reject };

    pub fn approves(d: ScmDecision) bool {
        return switch (d) {
            .describe => |x| x == .approve,
            .split, .resolve => |v| v == .approve,
            .land => |r| r.verdict == .approve,
        };
    }
};

/// What a proposal's item remembers for E09.
pub const Item = struct {
    review: ReviewId,
    kind: zg_scm.ai.ports.ProposalKind,
    preview_op: zg_scm.DetachedOp,
    /// The proposal's first commit (in the preview): the one a `describe`
    /// proposal describes. Null when it has none.
    commit: ?zg_scm.ObjectId,
    /// For `land`; owned.
    lane: []const u8,
    /// The lane's landing state once it is approved; `reason` owned.
    landing: ?Landing = null,

    pub const Landing = struct { state: LandingState, reason: []const u8 };
};

pub const Outcome = enum {
    done,
    /// The preview no longer adopts cleanly (the repo moved and the merge
    /// needs a decision): the item stays open; E09 sends a new proposal.
    conflicted,
};

/// Carries out a decision on E09's side.
pub const ScmActions = struct {
    ctx: *anyopaque,
    decide: *const fn (ctx: *anyopaque, item: *const Item, d: ScmDecision) anyerror!Outcome,
};

pub const Options = struct {
    /// The workspace root, for provenance.
    workspace: []const u8,
};

pub const ScmReviewPort = struct {
    gpa: Allocator,
    q: *Queue,
    files: PreviewFiles,
    actions: ScmActions,
    opts: Options,
    items: std.AutoArrayHashMapUnmanaged(ChangesetId, Item) = .empty,
    landing: ?*LandingQueue = null,

    pub fn init(gpa: Allocator, q: *Queue, files: PreviewFiles, actions: ScmActions, opts: Options) ScmReviewPort {
        return .{ .gpa = gpa, .q = q, .files = files, .actions = actions, .opts = opts };
    }

    pub fn deinit(p: *ScmReviewPort) void {
        for (p.items.values()) |*it| freeItem(p.gpa, it);
        p.items.deinit(p.gpa);
    }

    pub fn port(p: *ScmReviewPort) zg_scm.ReviewPort {
        return .{ .ctx = p, .submit = submitFn, .status = statusFn };
    }

    pub fn item(p: *const ScmReviewPort, cs: ChangesetId) ?*const Item {
        return p.items.getPtr(cs);
    }

    /// Creates the review item for `proposal`; its id is the changeset's.
    pub fn submit(p: *ScmReviewPort, proposal: *const Proposal) !ReviewId {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const files = try p.files.files(p.files.ctx, arena, proposal);
        const b = try p.q.beginBatch(.{
            .origin = .{ .scm_proposal = .{ .kind = std.meta.stringToEnum(model.provenance.ScmKind, @tagName(proposal.kind)).?, .review = 0 } },
            .label = proposal.summary,
            .rationale = if (proposal.rationale.len > 0) proposal.rationale else null,
            .workspace = p.opts.workspace,
            .lane = if (proposal.lane.len > 0) proposal.lane else null,
            .created_ms = 0,
        });
        errdefer p.q.abortBatch(b);
        for (files) |f| {
            if (f.base) |base| {
                if (f.new) |new| {
                    var e = try model.merge3.lineChangeSet(p.gpa, base, new);
                    defer e.deinit();
                    try p.q.addEdit(b, f.path, base, null, &e);
                } else try p.q.addDelete(b, f.path, base);
            } else if (f.new) |new| try p.q.addCreate(b, f.path, new);
        }
        const lane = try p.gpa.dupe(u8, proposal.lane);
        errdefer p.gpa.free(lane);
        try p.items.ensureUnusedCapacity(p.gpa, 1);
        const id = try p.q.commitBatch(b, .{});
        const review: ReviewId = @intFromEnum(id);
        if (p.q.getMut(id)) |cs| {
            cs.prov.origin.scm_proposal.review = review;
            p.q.persist(id);
        }
        p.items.putAssumeCapacity(id, .{ .review = review, .kind = proposal.kind, .preview_op = proposal.preview_op, .commit = if (proposal.changes.len > 0) proposal.changes[0] else null, .lane = lane });
        return review;
    }

    pub fn status(p: *const ScmReviewPort, review: ReviewId) ReviewStatus {
        const cs = p.q.get(@enumFromInt(review)) orelse return .unknown;
        if (cs.prov.origin != .scm_proposal) return .unknown;
        return switch (cs.state) {
            .open_batch, .pending, .partially_applied => .in_review,
            .applied => .approved,
            .rejected => .rejected,
            .superseded, .discarded => .cancelled,
        };
    }

    /// Applies a reviewer's decision on the whole proposal: E09 acts on
    /// it, then the item closes (approved or rejected). A `land` approval
    /// stays approved while the lane lands; `onLanding` reopens it if the
    /// lane comes back.
    pub fn decide(p: *ScmReviewPort, cs_id: ChangesetId, d: ScmDecision) !Outcome {
        const it = p.items.getPtr(cs_id) orelse return error.NotScmProposal;
        const cs = p.q.getMut(cs_id) orelse return error.UnknownChangeset;
        if (cs.state != .pending) return error.NotOpen;
        if (!kindMatches(it.kind, d)) return error.WrongKind;
        const out = try p.actions.decide(p.actions.ctx, it, d);
        if (out == .conflicted) return out;
        try p.setState(cs, if (d.approves()) .applied else .rejected);
        return out;
    }

    /// Mirrors a lane's landing state onto its item: `returned_conflict`
    /// and `returned_checks_failed` reopen it with the reason, `rejected`
    /// and `cancelled` close it.
    pub fn onLanding(p: *ScmReviewPort, review: ReviewId, state: LandingState, reason: []const u8) !void {
        const id: ChangesetId = @enumFromInt(review);
        const it = p.items.getPtr(id) orelse return;
        const cs = p.q.getMut(id) orelse return;
        const owned = try p.gpa.dupe(u8, reason);
        if (it.landing) |l| p.gpa.free(l.reason);
        it.landing = .{ .state = state, .reason = owned };
        switch (state) {
            .returned_conflict, .returned_checks_failed => if (cs.state == .applied) try p.setState(cs, .pending),
            .rejected, .cancelled => if (cs.state == .pending) try p.setState(cs, if (state == .rejected) .rejected else .discarded),
            else => {},
        }
        p.q.emit(.{ .updated = id });
    }

    /// Follows `lq`'s events (on the thread that runs the landing queue,
    /// which must be the queue's owner).
    pub fn bindLanding(p: *ScmReviewPort, lq: *LandingQueue) !void {
        p.landing = lq;
        try lq.events().listen(.{ .ctx = p, .on = onLandingEvent });
    }

    fn onLandingEvent(ctx: *anyopaque, e: *const zg_scm.ai.landing.Event) void {
        const p: *ScmReviewPort = @ptrCast(@alignCast(ctx));
        const lq = p.landing orelse return;
        const t = lq.ticket(e.ticket) orelse return;
        if (e.check.len > 0) return;
        p.onLanding(t.review, e.state, e.reason) catch |err|
            std.log.scoped(.zg_review).warn("landing state of review {d} not shown: {t}", .{ t.review, err });
    }

    fn setState(p: *ScmReviewPort, cs: *model.Changeset, to: model.State) !void {
        const from = cs.state;
        try model.transition(cs, to);
        p.q.persist(cs.id);
        p.q.emit(.{ .state = .{ .cs = cs.id, .from = from, .to = to } });
    }

    fn submitFn(ctx: *anyopaque, proposal: *const Proposal) anyerror!ReviewId {
        const p: *ScmReviewPort = @ptrCast(@alignCast(ctx));
        return p.submit(proposal);
    }

    fn statusFn(ctx: *anyopaque, review: ReviewId) ReviewStatus {
        const p: *ScmReviewPort = @ptrCast(@alignCast(ctx));
        return p.status(review);
    }
};

fn kindMatches(k: zg_scm.ai.ports.ProposalKind, d: ScmDecision) bool {
    return switch (d) {
        .describe => k == .describe,
        .split => k == .split,
        .resolve => k == .resolve,
        .land => k == .land,
    };
}

fn freeItem(gpa: Allocator, it: *Item) void {
    gpa.free(it.lane);
    if (it.landing) |l| gpa.free(l.reason);
}

/// `ScmActions` on a zg_scm repository: an approval adopts the preview
/// operation, a rejection discards it, and a landing decision goes to the
/// landing queue (which adopts its own landing operation). An approved
/// description the reviewer edited is adopted with the edited text
/// (`zg_scm.ai.describe.redescribe`).
pub const RepoActions = struct {
    repo: *zg_scm.Repo,
    landing: ?*LandingQueue = null,
    /// The adopt operation's metadata (times, user, actor).
    meta: zg_scm.OpMeta,

    pub fn actions(r: *RepoActions) ScmActions {
        return .{ .ctx = r, .decide = decideFn };
    }

    fn decideFn(ctx: *anyopaque, it: *const Item, d: ScmDecision) anyerror!Outcome {
        const r: *RepoActions = @ptrCast(@alignCast(ctx));
        switch (d) {
            .land => |rd| {
                const lq = r.landing orelse return error.NoLandingQueue;
                try lq.onReviewDecision(it.review, rd);
                return .done;
            },
            .describe => |x| if (x == .approve) if (x.approve) |text| {
                const target = it.commit orelse return error.NoDescribedCommit;
                var res = try zg_scm.ai.describe.redescribe(r.repo, it.preview_op, target, text, r.meta);
                defer res.deinit();
                return switch (res) {
                    .adopted => .done,
                    .conflicted => .conflicted,
                };
            },
            else => {},
        }
        if (!d.approves()) {
            zg_scm.preview.discard(r.repo, it.preview_op.op);
            return .done;
        }
        var res = try zg_scm.adopt.adopt(r.repo, it.preview_op, r.meta);
        defer res.deinit();
        return switch (res) {
            .adopted => .done,
            .conflicted => .conflicted,
        };
    }
};
