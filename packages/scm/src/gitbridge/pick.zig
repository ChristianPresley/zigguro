//! `git cherry-pick` and `git revert` of one commit (E09.F09.S01.T01),
//! stopping on conflicts with CHERRY_PICK_HEAD or REVERT_HEAD as git
//! does.

const std = @import("std");
const git = @import("zg_git");
const common = @import("common.zig");
const merge_trees = @import("merge_trees.zig");
const Repository = git.Repository;
const Oid = git.oid.Oid;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// false: `-n`, apply to the index and worktree only.
    commit: bool = true,
    /// `-m`: the parent (from 1) to diff a merge commit against.
    mainline: ?u32 = null,
    tz_offset_min: i32 = 0,
    blocked: common.Blocked = .{},
    /// Passphrase prompt and agent for `commit.gpgSign`.
    signing: common.Signing = .{},
};

const Mode = enum { pick, revert };

pub fn cherryPick(repo: *Repository, rev: []const u8, opts: Options) !common.Result {
    return run(repo, rev, opts, .pick);
}

pub fn revert(repo: *Repository, rev: []const u8, opts: Options) !common.Result {
    return run(repo, rev, opts, .revert);
}

fn run(repo: *Repository, rev: []const u8, opts: Options, mode: Mode) !common.Result {
    var res: common.Result = .init(repo.gpa);
    errdefer res.deinit();
    const a = res.arena.allocator();
    for ([_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD" }) |f| if (common.hasState(repo, f)) return error.OperationInProgress;
    const head = (try repo.head()) orelse return error.UnbornHead;
    const id = try git.revparse.resolveCommit(repo, rev);
    const c = try common.readCommit(repo, a, id);
    const parent: ?Oid = if (c.parents.len > 1) blk: {
        const m = opts.mainline orelse return error.MergeCommitNeedsMainline;
        if (m == 0 or m > c.parents.len) return error.InvalidMainline;
        break :blk c.parents[m - 1];
    } else if (c.parents.len == 1) c.parents[0] else null;
    const parent_tree: ?Oid = if (parent) |p| try repo.treeOf(p) else null;

    var hb: [64]u8 = undefined;
    var fb: [64]u8 = undefined;
    const sub = common.subject(c.message);
    const head_tree = try repo.treeOf(head);
    const r = switch (mode) {
        .pick => try merge_trees.mergeTrees(repo, a, parent_tree, head_tree, c.tree, .{
            .base = try std.fmt.allocPrint(a, "parent of {s} ({s})", .{ common.short(id, &hb), sub }),
            .theirs = try std.fmt.allocPrint(a, "{s} ({s})", .{ common.short(id, &hb), sub }),
        }),
        .revert => try merge_trees.mergeTrees(repo, a, c.tree, head_tree, parent_tree orelse try emptyTree(repo), .{
            .base = try std.fmt.allocPrint(a, "{s} ({s})", .{ common.short(id, &hb), sub }),
            .theirs = try std.fmt.allocPrint(a, "parent of {s} ({s})", .{ common.short(id, &hb), sub }),
        }),
    };
    const ours = try git.status.flattenTree(repo, a, head_tree);
    const blocked = try merge_trees.blockers(repo, a, ours, r, opts.commit);
    if (blocked.len > 0) {
        try opts.blocked.report(blocked);
        return error.WouldOverwrite;
    }
    var ix = try repo.readIndex();
    defer ix.deinit();
    try merge_trees.apply(repo, a, &ix, ours, r);
    try repo.writeIndex(&ix);

    const msg = switch (mode) {
        .pick => c.message,
        .revert => try std.fmt.allocPrint(a, "Revert \"{s}\"\n\nThis reverts commit {s}.\n", .{ sub, id.hex(&fb) }),
    };
    res.conflicts = try r.conflictPaths(a);
    if (!opts.commit and r.conflicts.len == 0) {
        try common.writeState(repo, "MERGE_MSG", msg);
        res.kind = .applied;
        return res;
    }
    if (r.conflicts.len > 0) {
        try common.writeState(repo, if (mode == .pick) "CHERRY_PICK_HEAD" else "REVERT_HEAD", try std.fmt.allocPrint(a, "{s}\n", .{id.hex(&fb)}));
        try common.writeState(repo, "MERGE_MSG", try common.mergeMsg(a, msg, res.conflicts));
        res.kind = .conflicted;
        return res;
    }
    const tree_id = try git.write_tree.writeTree(repo, &ix);
    if (tree_id.eql(head_tree)) return error.EmptyCommit;
    const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
    const author = if (mode == .pick) c.author else try common.ident(repo, a, .author, opts.tz_offset_min);
    const new = try common.writeCommit(repo, a, tree_id, &.{head}, author, who, msg, opts.signing);
    const reflog = switch (mode) {
        .pick => try std.fmt.allocPrint(a, "cherry-pick: {s}", .{sub}),
        .revert => try std.fmt.allocPrint(a, "revert: {s}", .{common.subject(msg)}),
    };
    try common.moveHead(repo, a, head, new, reflog, who);
    res.kind = .committed;
    res.oid = new;
    return res;
}

fn emptyTree(repo: *Repository) !Oid {
    return repo.odb.writeLoose(.tree, "");
}

/// `git cherry-pick --abort` / `git revert --abort`.
pub fn abort(repo: *Repository) !void {
    if (!common.hasState(repo, "CHERRY_PICK_HEAD") and !common.hasState(repo, "REVERT_HEAD")) return error.NoOperationInProgress;
    try common.abort(repo);
}
