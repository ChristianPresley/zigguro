//! `git merge` on a git repository (E09.F09.S01.T01): fast-forward,
//! three-way merge commits, stopping on conflicts with git's state
//! files, and `--abort`.

const std = @import("std");
const git = @import("zg_git");
const common = @import("common.zig");
const merge_trees = @import("merge_trees.zig");
const Repository = git.Repository;
const Oid = git.oid.Oid;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    ff: enum { allow, only, never } = .allow,
    /// false: `--no-commit`, stop with the result staged.
    commit: bool = true,
    /// The merge commit message (default: git's "Merge branch 'x'").
    message: ?[]const u8 = null,
    tz_offset_min: i32 = 0,
    /// Receives the paths whose local changes block the merge.
    blocked: common.Blocked = .{},
};

/// Merges `name` (a branch, tag or any revision) into HEAD. Local
/// changes that the merge would touch, or any staged change, stop it
/// with `error.WouldOverwrite`.
pub fn merge(repo: *Repository, name: []const u8, opts: Options) !common.Result {
    var res: common.Result = .init(repo.gpa);
    errdefer res.deinit();
    const a = res.arena.allocator();
    if (common.hasState(repo, "MERGE_HEAD")) return error.MergeInProgress;
    const head = (try repo.head()) orelse return error.UnbornHead;
    const theirs = try git.revparse.resolveCommit(repo, name);
    // git records ORIG_HEAD before it knows what the merge will do.
    try common.writeOrigHead(repo, a, head);

    if (try git.revwalk.isAncestor(repo, theirs, head)) {
        res.kind = .up_to_date;
        res.oid = head;
        return res;
    }
    const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
    if (opts.ff != .never and try git.revwalk.isAncestor(repo, head, theirs)) {
        var blocked: std.ArrayList([]const u8) = .empty;
        git.checkout.moveTree(repo, head, theirs, false, &blocked, a) catch |e| {
            if (e == error.WouldOverwrite) try opts.blocked.report(blocked.items);
            return e;
        };
        try common.moveHead(repo, a, head, theirs, try std.fmt.allocPrint(a, "merge {s}: Fast-forward", .{name}), who);
        res.kind = .fast_forward;
        res.oid = theirs;
        return res;
    }
    if (opts.ff == .only) return error.NotFastForward;

    const bases = try git.revwalk.mergeBases(repo, a, head, theirs);
    if (bases.len == 0) return error.UnrelatedHistories;
    const base_tree = try virtualBase(repo, a, bases);
    const head_tree = try repo.treeOf(head);
    const r = try merge_trees.mergeTrees(repo, a, base_tree, head_tree, try repo.treeOf(theirs), .{ .theirs = name });
    const ours = try git.status.flattenTree(repo, a, head_tree);
    const blocked = try merge_trees.blockers(repo, a, ours, r, true);
    if (blocked.len > 0) {
        try opts.blocked.report(blocked);
        return error.WouldOverwrite;
    }
    var ix = try repo.readIndex();
    defer ix.deinit();
    try merge_trees.apply(repo, a, &ix, ours, r);
    try repo.writeIndex(&ix);

    const msg = if (opts.message) |m| try git.commit_cmd.cleanMessage(a, m, .whitespace, '#') else try defaultMessage(repo, a, name);
    res.conflicts = try r.conflictPaths(a);
    if (r.conflicts.len > 0 or !opts.commit) {
        var hb: [64]u8 = undefined;
        try common.writeState(repo, "MERGE_HEAD", try std.fmt.allocPrint(a, "{s}\n", .{theirs.hex(&hb)}));
        try common.writeState(repo, "MERGE_MODE", if (opts.ff == .never) "no-ff" else "");
        try common.writeState(repo, "MERGE_MSG", try common.mergeMsg(a, msg, res.conflicts));
        res.kind = if (r.conflicts.len > 0) .conflicted else .applied;
        return res;
    }
    const tree_id = try git.write_tree.writeTree(repo, &ix);
    const author = try common.ident(repo, a, .author, opts.tz_offset_min);
    const id = try common.writeCommit(repo, a, tree_id, &.{ head, theirs }, author, who, msg);
    try common.moveHead(repo, a, head, id, try std.fmt.allocPrint(a, "merge {s}: Merge made by the 'ort' strategy.", .{name}), who);
    res.kind = .committed;
    res.oid = id;
    return res;
}

/// The base tree for several merge bases: merged pairwise, as git's
/// recursive virtual ancestor (conflicted paths keep their marker text).
fn virtualBase(repo: *Repository, a: Allocator, bases: []const Oid) !Oid {
    var cur = try repo.treeOf(bases[0]);
    var cur_commit = bases[0];
    for (bases[1..]) |next| {
        const inner = try git.revwalk.mergeBases(repo, a, cur_commit, next);
        const ib: ?Oid = if (inner.len > 0) try repo.treeOf(inner[0]) else null;
        const r = try merge_trees.mergeTrees(repo, a, ib, cur, try repo.treeOf(next), .{ .ours = "Temporary merge branch 1", .theirs = "Temporary merge branch 2" });
        var ix: git.index.Index = .init(a, repo.format);
        for (r.files) |f| try ix.add(.{ .mode = f.mode, .oid = f.oid, .path = f.path });
        for (r.conflicts) |c| {
            const side = c.ours orelse c.theirs orelse continue;
            const id = if (c.text) |t| try repo.odb.writeLoose(.blob, t) else side.oid;
            try ix.add(.{ .mode = side.mode, .oid = id, .path = c.path });
        }
        cur = try git.write_tree.writeTree(repo, &ix);
        cur_commit = next;
    }
    return cur;
}

/// git's default merge message (fmt-merge-msg): what was merged, and
/// " into <branch>" unless that is main or master.
pub fn defaultMessage(repo: *Repository, a: Allocator, name: []const u8) ![]const u8 {
    var buf: [512]u8 = undefined;
    const what: []const u8 = blk: {
        if (try repo.refs.resolve(std.fmt.bufPrint(&buf, "refs/heads/{s}", .{name}) catch name)) |_| break :blk "branch";
        if (try repo.refs.resolve(std.fmt.bufPrint(&buf, "refs/tags/{s}", .{name}) catch name)) |_| break :blk "tag";
        if (try repo.refs.resolve(std.fmt.bufPrint(&buf, "refs/remotes/{s}", .{name}) catch name)) |_| break :blk "remote-tracking branch";
        break :blk "commit";
    };
    const into = try common.branchName(repo, a);
    if (into) |b| if (!std.mem.eql(u8, b, "main") and !std.mem.eql(u8, b, "master")) {
        return std.fmt.allocPrint(a, "Merge {s} '{s}' into {s}\n", .{ what, name, b });
    };
    return std.fmt.allocPrint(a, "Merge {s} '{s}'\n", .{ what, name });
}

/// `git merge --abort`.
pub fn abort(repo: *Repository) !void {
    if (!common.hasState(repo, "MERGE_HEAD")) return error.NoMergeInProgress;
    try common.abort(repo);
    // `--abort` is `git reset --merge`, which logs a reset to HEAD.
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const head = (try repo.head()).?;
    try common.moveHead(repo, a, head, head, "reset: moving to HEAD", try common.ident(repo, a, .committer, 0));
}
