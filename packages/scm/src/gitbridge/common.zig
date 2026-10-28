//! Shared pieces of the git bridge operations (E09.F09.S01.T01):
//! results, commits, HEAD moves and the operation-state files git keeps
//! in `$GIT_DIR` (MERGE_HEAD, CHERRY_PICK_HEAD, MERGE_MSG, ...).

const std = @import("std");
const git = @import("zg_git");
const Repository = git.Repository;
const Oid = git.oid.Oid;
const Ident = git.commit.Ident;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Kind = enum {
    /// Nothing to do (the other side is already contained).
    up_to_date,
    /// HEAD moved forward without a merge commit.
    fast_forward,
    /// A new commit was made.
    committed,
    /// The result is in the index and worktree, not committed.
    applied,
    /// Conflicts are left in the index and worktree.
    conflicted,
};

/// What an operation did. Strings live in `arena`.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind = .up_to_date,
    /// The new commit (or HEAD after a fast-forward).
    oid: ?Oid = null,
    /// Conflicted paths, in index order.
    conflicts: []const []const u8 = &.{},

    pub fn init(gpa: Allocator) Result {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }
};

/// Paths that block an operation, copied for the caller when it asked.
pub const Blocked = struct {
    list: ?*std.ArrayList([]const u8) = null,
    gpa: ?Allocator = null,

    pub fn report(b: Blocked, paths: []const []const u8) !void {
        const l = b.list orelse return;
        for (paths) |p| try l.append(b.gpa.?, try b.gpa.?.dupe(u8, p));
    }
};

pub fn nowSecs(repo: *Repository) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s));
}

pub fn ident(repo: *Repository, a: Allocator, role: enum { author, committer }, tz_offset_min: i32) !Ident {
    return switch (role) {
        .author => git.commit_cmd.ident(repo, a, repo.envMap(), .author, nowSecs(repo), tz_offset_min),
        .committer => git.commit_cmd.ident(repo, a, repo.envMap(), .committer, nowSecs(repo), tz_offset_min),
    };
}

/// Writes a commit object. `message` should end with a newline.
pub fn writeCommit(repo: *Repository, a: Allocator, tree: Oid, parents: []const Oid, author: Ident, committer: Ident, message: []const u8) !Oid {
    if (repo.config.getBool("commit.gpgsign") orelse false) return error.SigningUnsupported;
    const c: git.commit.Commit = .{ .tree = tree, .parents = parents, .author = author, .committer = committer, .message = message };
    var aw: std.Io.Writer.Allocating = .init(a);
    try git.commit.serializeCommit(&c, &aw.writer);
    return repo.odb.writeLoose(.commit, aw.written());
}

/// Moves the current branch (or a detached HEAD) from `old` to `new`.
pub fn moveHead(repo: *Repository, a: Allocator, old: Oid, new: Oid, msg: []const u8, who: Ident) !void {
    const ref = (try repo.headRef(a)) orelse "HEAD";
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.update(ref, .{ .direct = new }, .{ .oid = old }, msg, who);
    try tx.commit();
}

/// The parsed commit `id`, in `a`.
pub fn readCommit(repo: *Repository, a: Allocator, id: Oid) !git.commit.Commit {
    const obj = try repo.odb.read(a, id);
    if (obj.type != .commit) return error.NotACommit;
    return git.commit.parseCommit(a, repo.format, obj.data);
}

pub fn subject(message: []const u8) []const u8 {
    return std.mem.sliceTo(message, '\n');
}

/// The 7-digit abbreviation git prints by default.
pub fn short(id: Oid, buf: *[64]u8) []const u8 {
    return id.hex(buf)[0..7];
}

/// The current branch's short name, or null when HEAD is detached.
pub fn branchName(repo: *Repository, a: Allocator) !?[]const u8 {
    const r = (try repo.headRef(a)) orelse return null;
    return if (std.mem.startsWith(u8, r, "refs/heads/")) r["refs/heads/".len..] else r;
}

pub fn writeState(repo: *Repository, name: []const u8, data: []const u8) !void {
    try repo.git_dir.writeFile(repo.io, .{ .sub_path = name, .data = data });
}

pub fn hasState(repo: *Repository, name: []const u8) bool {
    repo.git_dir.access(repo.io, name, .{}) catch return false;
    return true;
}

pub fn writeOrigHead(repo: *Repository, a: Allocator, id: Oid) !void {
    var hb: [64]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ repo.git_dir_path, "ORIG_HEAD" });
    try git.config.writeLocked(repo.io, path, try std.fmt.allocPrint(a, "{s}\n", .{id.hex(&hb)}));
}

/// MERGE_MSG for a stopped operation: the message, then the conflicted
/// paths as comments (git's layout).
pub fn mergeMsg(a: Allocator, message: []const u8, conflicts: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, std.mem.trimEnd(u8, message, "\n"));
    try out.appendSlice(a, "\n");
    if (conflicts.len > 0) {
        try out.appendSlice(a, "\n# Conflicts:\n");
        for (conflicts) |p| try out.print(a, "#\t{s}\n", .{p});
    }
    return out.items;
}

/// `git merge --abort`, `git cherry-pick --abort`, `git revert --abort`:
/// index and worktree back to HEAD, operation state removed.
pub fn abort(repo: *Repository) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasState(repo, "MERGE_HEAD") and !hasState(repo, "CHERRY_PICK_HEAD") and !hasState(repo, "REVERT_HEAD")) return error.NoOperationInProgress;
    const head = (try repo.head()) orelse return error.UnbornHead;
    const files = try git.status.flattenTree(repo, a, try repo.treeOf(head));
    var ix = try repo.readIndex();
    defer ix.deinit();
    try git.checkout.resetTo(repo, a, &ix, files, .hard);
    try repo.writeIndex(&ix);
    clearState(repo);
}

pub fn clearState(repo: *Repository) void {
    for ([_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE", "CHERRY_PICK_HEAD", "REVERT_HEAD" }) |f| {
        repo.git_dir.deleteFile(repo.io, f) catch {};
    }
}
