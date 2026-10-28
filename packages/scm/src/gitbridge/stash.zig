//! `git stash` (E09.F09.S01.T01): push (with untracked files and
//! keep-index), list, apply, pop, drop and clear, in git's own format: a
//! `refs/stash` commit whose parents are HEAD, the index commit and the
//! untracked-files commit, and the `logs/refs/stash` reflog as the list.

const std = @import("std");
const git = @import("zg_git");
const common = @import("common.zig");
const merge_trees = @import("merge_trees.zig");
const Repository = git.Repository;
const Oid = git.oid.Oid;
const Index = git.index.Index;
const Allocator = std.mem.Allocator;

pub const PushOptions = struct {
    /// `-m`: "On <branch>: <message>" instead of "WIP on <branch>: ...".
    message: ?[]const u8 = null,
    /// `-u`: also stash (and remove) untracked files.
    include_untracked: bool = false,
    /// `--keep-index`: leave staged changes in place.
    keep_index: bool = false,
    tz_offset_min: i32 = 0,
};

/// Saves local changes and resets the index and worktree to HEAD.
/// Returns the stash commit; `error.NoLocalChanges` when there is none.
pub fn push(repo: *Repository, opts: PushOptions) !Oid {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const head = (try repo.head()) orelse return error.UnbornHead;
    var ix = try repo.readIndex();
    defer ix.deinit();
    for (ix.entries.items) |e| if (e.flags.stage != 0) return error.UnmergedEntries;

    var untracked: std.ArrayList([]const u8) = .empty;
    var tracked_changes = false;
    {
        var st = try git.status.status(repo, .{ .untracked = if (opts.include_untracked) .all else .no, .refresh = false });
        defer st.deinit();
        for (st.entries) |e| {
            if (e.x == .untracked) {
                try untracked.append(a, try a.dupe(u8, e.path));
            } else if (e.x != .ignored) tracked_changes = true;
        }
    }
    if (!tracked_changes and untracked.items.len == 0) return error.NoLocalChanges;

    const hc = try common.readCommit(repo, a, head);
    var hb: [64]u8 = undefined;
    const branch = (try common.branchName(repo, a)) orelse "(no branch)";
    const on = try std.fmt.allocPrint(a, "{s}: {s} {s}", .{ branch, common.short(head, &hb), common.subject(hc.message) });
    const author = try common.ident(repo, a, .author, opts.tz_offset_min);
    const who = try common.ident(repo, a, .committer, opts.tz_offset_min);

    const i_tree = try git.write_tree.writeTree(repo, &ix);
    const i_commit = try common.writeCommit(repo, a, i_tree, &.{head}, author, who, try std.fmt.allocPrint(a, "index on {s}\n", .{on}), null);

    var wix = try repo.readIndex();
    defer wix.deinit();
    _ = try git.stage.addInto(repo, &wix, &.{}, .{ .update_only = true });
    const w_tree = try git.write_tree.writeTree(repo, &wix);

    var parents: std.ArrayList(Oid) = .empty;
    try parents.appendSlice(a, &.{ head, i_commit });
    if (untracked.items.len > 0) {
        var uix: Index = .init(repo.gpa, repo.format);
        defer uix.deinit();
        _ = try git.stage.addInto(repo, &uix, untracked.items, .{});
        const u_tree = try git.write_tree.writeTree(repo, &uix);
        try parents.append(a, try common.writeCommit(repo, a, u_tree, &.{}, author, who, try std.fmt.allocPrint(a, "untracked files on {s}\n", .{on}), null));
    }
    const title = if (opts.message) |m|
        try std.fmt.allocPrint(a, "On {s}: {s}", .{ branch, std.mem.trim(u8, m, " \n") })
    else
        try std.fmt.allocPrint(a, "WIP on {s}", .{on});
    // git writes this message without a final newline.
    const w = try common.writeCommit(repo, a, w_tree, parents.items, author, who, title, null);

    // git always keeps a reflog for refs/stash: it is the stash list.
    try repo.git_dir.createDirPath(repo.io, "logs/refs");
    (try repo.git_dir.createFile(repo.io, "logs/refs/stash", .{ .truncate = false })).close(repo.io);
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.update("refs/stash", .{ .direct = w }, null, title, who);
    try tx.commit();

    // Back to HEAD (or to the index with keep_index).
    const files = try git.status.flattenTree(repo, a, if (opts.keep_index) i_tree else try repo.treeOf(head));
    try git.checkout.resetTo(repo, a, &ix, files, .hard);
    try repo.writeIndex(&ix);
    for (untracked.items) |p| git.checkout.removeWorktreeFile(repo, p);
    // As the `git reset --hard` stash runs: ORIG_HEAD and a reflog entry.
    try common.writeOrigHead(repo, a, head);
    try common.logHead(repo, head, head, "reset: moving to HEAD", who);
    return w;
}

pub const Entry = struct {
    /// n in stash@{n}.
    n: usize,
    oid: Oid,
    message: []const u8,
};

pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: []Entry,

    pub fn deinit(l: *List) void {
        l.arena.deinit();
    }
};

/// The stashes, newest (stash@{0}) first.
pub fn list(repo: *Repository) !List {
    var out: List = .{ .arena = .init(repo.gpa), .items = &.{} };
    errdefer out.deinit();
    const a = out.arena.allocator();
    const lines = try readLog(repo, a);
    const items = try a.alloc(Entry, lines.len);
    for (items, 0..) |*e, n| {
        const ent = try git.refs.reflog.parseLine(repo.format, lines[lines.len - 1 - n]);
        e.* = .{ .n = n, .oid = ent.new, .message = ent.message };
    }
    out.items = items;
    return out;
}

fn readLog(repo: *Repository, a: Allocator) ![]const []const u8 {
    const text = repo.git_dir.readFileAlloc(repo.io, "logs/refs/stash", a, .limited(64 << 20)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(a, l);
    return lines.items;
}

fn entryOid(repo: *Repository, a: Allocator, n: usize) !Oid {
    const lines = try readLog(repo, a);
    if (n >= lines.len) return error.NoSuchStash;
    return (try git.refs.reflog.parseLine(repo.format, lines[lines.len - 1 - n])).new;
}

pub const ApplyOptions = struct {
    /// n in stash@{n}.
    n: usize = 0,
    tz_offset_min: i32 = 0,
    blocked: common.Blocked = .{},
};

/// `git stash apply`: merges the stash into the current index and
/// worktree. Without conflicts, changes come back unstaged (new files
/// staged), as git leaves them.
pub fn apply(repo: *Repository, opts: ApplyOptions) !common.Result {
    var res: common.Result = .init(repo.gpa);
    errdefer res.deinit();
    const a = res.arena.allocator();
    const w = try entryOid(repo, a, opts.n);
    const wc = try common.readCommit(repo, a, w);
    if (wc.parents.len < 2) return error.NotAStash;

    var ix = try repo.readIndex();
    defer ix.deinit();
    for (ix.entries.items) |e| if (e.flags.stage != 0) return error.UnmergedEntries;
    const c_tree = try git.write_tree.writeTree(repo, &ix);
    const ours = try git.status.flattenTree(repo, a, c_tree);
    const r = try merge_trees.mergeTrees(repo, a, try repo.treeOf(wc.parents[0]), c_tree, wc.tree, .{ .ours = "Updated upstream", .theirs = "Stashed changes" });

    var blocked: std.ArrayList([]const u8) = .empty;
    try blocked.appendSlice(a, try merge_trees.blockers(repo, a, ours, r, false));
    const u_files: []const git.status.TreeFile = if (wc.parents.len > 2) try git.status.flattenTree(repo, a, try repo.treeOf(wc.parents[2])) else &.{};
    for (u_files) |f| {
        if (repo.work.access(repo.io, f.path, .{})) |_| try blocked.append(a, f.path) else |_| {}
    }
    if (blocked.items.len > 0) {
        try opts.blocked.report(blocked.items);
        return error.WouldOverwrite;
    }
    try merge_trees.apply(repo, a, &ix, ours, r);
    if (r.conflicts.len == 0) {
        // Unstage: entries go back to their pre-apply versions, except
        // files the stash adds.
        for (ours) |f| {
            if (ix.find(f.path, 0)) |i| {
                const e = ix.entries.items[i];
                if (e.oid.eql(f.oid) and e.mode == f.mode) continue;
            }
            try ix.add(.{ .mode = f.mode, .oid = f.oid, .path = f.path });
        }
    }
    try repo.writeIndex(&ix);
    for (u_files) |f| try git.checkout.writeFile(repo, f.path, f.mode, f.oid);
    res.conflicts = try r.conflictPaths(a);
    res.kind = if (r.conflicts.len > 0) .conflicted else .applied;
    return res;
}

/// `git stash pop`: apply, then drop unless it conflicted.
pub fn pop(repo: *Repository, opts: ApplyOptions) !common.Result {
    var res = try apply(repo, opts);
    errdefer res.deinit();
    if (res.kind != .conflicted) try drop(repo, opts.n);
    return res;
}

/// `git stash drop stash@{n}`.
pub fn drop(repo: *Repository, n: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try readLog(repo, a);
    if (n >= lines.len) return error.NoSuchStash;
    if (lines.len == 1) return clear(repo);
    const k = lines.len - 1 - n;
    var out: std.ArrayList(u8) = .empty;
    const hl = repo.format.hexLen();
    for (lines, 0..) |l, i| {
        if (i == k) continue;
        if (i == k + 1) {
            // The next entry's old value skips the dropped one.
            try out.appendSlice(a, lines[k][0..hl]);
            try out.appendSlice(a, l[hl..]);
        } else try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    const top = try git.refs.reflog.parseLine(repo.format, if (k == lines.len - 1) lines[k - 1] else lines[lines.len - 1]);
    const log_path = try std.fs.path.join(a, &.{ repo.git_dir_path, "logs", "refs", "stash" });
    try git.config.writeLocked(repo.io, log_path, out.items);
    var hb: [64]u8 = undefined;
    const ref_path = try std.fs.path.join(a, &.{ repo.git_dir_path, "refs", "stash" });
    try git.config.writeLocked(repo.io, ref_path, try std.fmt.allocPrint(a, "{s}\n", .{top.new.hex(&hb)}));
}

/// `git stash clear`.
pub fn clear(repo: *Repository) !void {
    if ((try repo.refs.resolve("refs/stash")) == null) return;
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.delete("refs/stash", null, "");
    try tx.commit();
}
