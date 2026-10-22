//! Reviewing an AI conflict resolution region by region (E12.F05.S03.T01,
//! the `resolve` kind). E09's `Resolver` proposes a text for each conflict
//! region of a change (`zg_scm.ai.resolve.Run`); the reviewer takes each
//! proposal, edits it, picks a side, or keeps the conflict markers. Once
//! every region is decided, `submit` hands the decisions to E09
//! (`applyResolutions`, a detached preview) and puts the resulting
//! `resolve` proposal in the queue through the `ScmReviewPort`, where the
//! whole resolved change is reviewed and approved like any other
//! proposal. Nothing reaches the repository before that approval.
//!
//! Regions the model could not handle (`needs_human`: binary, mode, type
//! or delete conflicts, failed checks) cannot be taken as proposed; the
//! reviewer picks a side or writes the text.
//!
//! Owner thread (the queue's). The run is borrowed and must outlive the
//! review.

const std = @import("std");
const zg_scm = @import("zg_scm");
const port_mod = @import("port.zig");

const Allocator = std.mem.Allocator;
const resolve = zg_scm.ai.resolve;
const Run = resolve.Run;
const Region = resolve.Region;
const RegionProposal = resolve.RegionProposal;
const RegionDecision = resolve.RegionDecision;
const Choice = RegionDecision.Choice;

pub const RegionReview = struct {
    gpa: Allocator,
    run: *Run,
    /// The texts of `edit` choices.
    arena: std.heap.ArenaAllocator,
    choices: []?Choice,

    pub fn init(gpa: Allocator, run: *Run) !RegionReview {
        const choices = try gpa.alloc(?Choice, run.set.regions.len);
        @memset(choices, null);
        return .{ .gpa = gpa, .run = run, .arena = .init(gpa), .choices = choices };
    }

    pub fn deinit(rr: *RegionReview) void {
        rr.gpa.free(rr.choices);
        rr.arena.deinit();
    }

    pub fn count(rr: *const RegionReview) usize {
        return rr.choices.len;
    }

    pub fn region(rr: *const RegionReview, i: usize) *const Region {
        return &rr.run.set.regions[i];
    }

    pub fn proposal(rr: *const RegionReview, i: usize) RegionProposal {
        return rr.run.proposal(i);
    }

    pub fn choice(rr: *const RegionReview, i: usize) ?Choice {
        return rr.choices[i];
    }

    /// Takes region `i`'s proposal as is.
    pub fn accept(rr: *RegionReview, i: usize) !void {
        const p = rr.proposal(i);
        if (p.status != .ok) return error.NeedsHuman;
        rr.choices[i] = .{ .accept = p.text };
    }

    /// Region `i` becomes `text` (an edited proposal or the reviewer's own).
    pub fn edit(rr: *RegionReview, i: usize, text: []const u8) !void {
        if (rr.region(i).kind != .text) return error.NotText;
        rr.choices[i] = .{ .edit = try rr.arena.allocator().dupe(u8, text) };
    }

    /// Region `i` takes side `k` (0 or 1) as it is.
    pub fn side(rr: *RegionReview, i: usize, k: u32) !void {
        if (k > 1) return error.NoSuchSide;
        rr.choices[i] = .{ .side = k };
    }

    /// Region `i` keeps its conflict, written as diff3 markers.
    pub fn keepConflict(rr: *RegionReview, i: usize) !void {
        if (rr.region(i).kind != .text) return error.NotText;
        rr.choices[i] = .keep_conflict;
    }

    pub fn clear(rr: *RegionReview, i: usize) void {
        rr.choices[i] = null;
    }

    /// Takes every undecided region's proposal that is `ok`; returns how
    /// many it took.
    pub fn acceptProposed(rr: *RegionReview) usize {
        var n: usize = 0;
        for (rr.choices, 0..) |c, i| {
            if (c != null) continue;
            rr.accept(i) catch continue;
            n += 1;
        }
        return n;
    }

    /// Regions still undecided.
    pub fn remaining(rr: *const RegionReview) usize {
        var n: usize = 0;
        for (rr.choices) |c| n += @intFromBool(c == null);
        return n;
    }

    /// One decision per region, in `arena`; `error.MissingDecision` while
    /// any region is undecided.
    pub fn decisions(rr: *const RegionReview, arena: Allocator) ![]RegionDecision {
        const out = try arena.alloc(RegionDecision, rr.choices.len);
        for (rr.choices, rr.run.set.regions, out) |c, r, *o| {
            o.* = .{ .path = r.path, .region_idx = r.region_idx, .choice = c orelse return error.MissingDecision };
        }
        return out;
    }

    pub const Submit = struct {
        /// The queue item's label.
        summary: []const u8,
        provenance: zg_scm.ai.ports.ProvenanceRecord,
        meta: zg_scm.OpMeta,
    };

    /// Applies the decisions in a preview and submits the resolved change
    /// for review; returns the review item's id.
    pub fn submit(rr: *const RegionReview, repo: *zg_scm.Repo, port: *port_mod.ScmReviewPort, o: Submit) !zg_scm.ReviewId {
        var arena_state: std.heap.ArenaAllocator = .init(rr.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const ds = try rr.decisions(a);
        const applied = try resolve.applyResolutions(repo, &rr.run.set, ds, o.meta);
        errdefer zg_scm.preview.discard(repo, applied.preview.op);
        const item = applied.proposal(o.summary, o.provenance, try rr.rationale(a));
        return port.submit(&item);
    }

    /// The rationale of every region taken as proposed, one per line.
    fn rationale(rr: *const RegionReview, a: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (rr.choices, 0..) |c, i| {
            if (c == null or c.? != .accept) continue;
            const p = rr.proposal(i);
            if (p.rationale.len == 0) continue;
            try out.print(a, "{s} (region {d}): {s}\n", .{ p.path, p.region_idx + 1, p.rationale });
        }
        return out.items;
    }
};
