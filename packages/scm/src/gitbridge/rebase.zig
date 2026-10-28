//! `git rebase` (merge backend) on a git repository (E09.F09.S01.T01):
//! replays the branch's commits onto another commit, stopping on
//! conflicts with git's `.git/rebase-merge` state so either we or git
//! can `--continue`, `--skip` or `--abort`. Merge commits are dropped
//! and commits that become empty are dropped, as git does by default.

const std = @import("std");
const git = @import("zg_git");
const common = @import("common.zig");
const merge_trees = @import("merge_trees.zig");
const Repository = git.Repository;
const Oid = git.oid.Oid;
const Ident = git.commit.Ident;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// `--onto`: where to replay (default: the upstream).
    onto: ?[]const u8 = null,
    tz_offset_min: i32 = 0,
    blocked: common.Blocked = .{},
    signing: common.Signing = .{},
    /// The reflog prefix: "rebase", or "pull --rebase" for pulls.
    reflog_action: []const u8 = "rebase",
};

const state_dir = "rebase-merge";

pub fn inProgress(repo: *Repository) bool {
    return common.hasState(repo, state_dir) or common.hasState(repo, "rebase-apply");
}

/// A todo line: `pick <id> <subject>`.
const Step = struct { id: Oid, line: []const u8 };

const State = struct {
    head_name: []const u8,
    onto: Oid,
    orig_head: Oid,
    done: std.ArrayList([]const u8) = .empty,
    todo: std.ArrayList(Step) = .empty,
    end: usize,
    reflog_action: []const u8,
};

/// Rebases the current branch onto `upstream` (or `opts.onto`).
pub fn rebase(repo: *Repository, upstream: []const u8, opts: Options) !common.Result {
    var res: common.Result = .init(repo.gpa);
    errdefer res.deinit();
    const a = res.arena.allocator();
    if (inProgress(repo)) return error.RebaseInProgress;
    for ([_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD" }) |f| if (common.hasState(repo, f)) return error.OperationInProgress;
    const head = (try repo.head()) orelse return error.UnbornHead;
    try requireClean(repo);
    const up = try git.revparse.resolveCommit(repo, upstream);
    const onto = if (opts.onto) |o| try git.revparse.resolveCommit(repo, o) else up;

    // Nothing to replay and already on top: up to date.
    const picks = try commitsToReplay(repo, a, head, up);
    if (try git.revwalk.isAncestor(repo, onto, head)) {
        const bases = try git.revwalk.mergeBases(repo, a, onto, head);
        if (bases.len == 1 and bases[0].eql(onto) and try linearAbove(repo, a, head, onto)) {
            res.kind = .up_to_date;
            res.oid = head;
            return res;
        }
    }

    const head_name = (try repo.headRef(a)) orelse "detached HEAD";
    try common.writeOrigHead(repo, a, head);
    const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
    var blocked: std.ArrayList([]const u8) = .empty;
    git.checkout.moveTree(repo, head, onto, false, &blocked, a) catch |e| {
        if (e == error.WouldOverwrite) try opts.blocked.report(blocked.items);
        return e;
    };
    try git.checkout.setHead(repo, .{ .direct = onto }, head, onto, who, try std.fmt.allocPrint(a, "{s} (start): checkout {s}", .{ opts.reflog_action, opts.onto orelse upstream }));

    var st: State = .{ .head_name = head_name, .onto = onto, .orig_head = head, .end = picks.len, .reflog_action = opts.reflog_action };
    var hb: [64]u8 = undefined;
    for (picks) |id| {
        const c = try common.readCommit(repo, a, id);
        try st.todo.append(a, .{ .id = id, .line = try std.fmt.allocPrint(a, "pick {s} {s}", .{ id.hex(&hb), common.subject(c.message) }) });
    }
    return run(repo, &res, &st, opts);
}

/// `git rebase --continue`: commits the resolved stop, then goes on.
pub fn continueRebase(repo: *Repository, opts: Options) !common.Result {
    var res: common.Result = .init(repo.gpa);
    errdefer res.deinit();
    const a = res.arena.allocator();
    var st = try readState(repo, a);
    var ix = try repo.readIndex();
    defer ix.deinit();
    for (ix.entries.items) |e| if (e.flags.stage != 0) return error.UnresolvedConflicts;
    if (try readStateFile(repo, a, "stopped-sha")) |_| {
        // Commit what was resolved with the stopped commit's message and author.
        const head = (try repo.head()).?;
        const tree_id = try git.write_tree.writeTree(repo, &ix);
        if (!tree_id.eql(try repo.treeOf(head))) {
            const raw = (try readStateFile(repo, a, "message")) orelse return error.BadRebaseState;
            const msg = try std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, raw, "\n"), "\n" });
            const author = try readAuthorScript(repo, a);
            const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
            const new = try common.writeCommit(repo, a, tree_id, &.{head}, author, who, msg, opts.signing);
            try common.moveHead(repo, a, head, new, try std.fmt.allocPrint(a, "{s} (continue): {s}", .{ st.reflog_action, common.subject(msg) }), who);
        }
    }
    clearStop(repo);
    return run(repo, &res, &st, opts);
}

/// `git rebase --skip`: drops the stopped commit and goes on.
pub fn skip(repo: *Repository, opts: Options) !common.Result {
    var res: common.Result = .init(repo.gpa);
    errdefer res.deinit();
    const a = res.arena.allocator();
    var st = try readState(repo, a);
    const head = (try repo.head()).?;
    const files = try git.status.flattenTree(repo, a, try repo.treeOf(head));
    var ix = try repo.readIndex();
    defer ix.deinit();
    try git.checkout.resetTo(repo, a, &ix, files, .hard);
    try repo.writeIndex(&ix);
    clearStop(repo);
    return run(repo, &res, &st, opts);
}

/// `git rebase --abort`: back to the branch as it was.
pub fn abort(repo: *Repository) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = try readState(repo, a);
    const head = (try repo.head()).?;
    const who = try common.ident(repo, a, .committer, 0);
    try git.checkout.moveTree(repo, head, st.orig_head, true, null, null);
    const msg = try std.fmt.allocPrint(a, "{s} (abort): returning to {s}", .{ st.reflog_action, st.head_name });
    if (std.mem.startsWith(u8, st.head_name, "refs/")) {
        try git.checkout.setHead(repo, .{ .symbolic = st.head_name }, head, st.orig_head, who, msg);
    } else try git.checkout.setHead(repo, .{ .direct = st.orig_head }, head, st.orig_head, who, msg);
    clearAll(repo, a);
}

fn run(repo: *Repository, res: *common.Result, st: *State, opts: Options) !common.Result {
    const a = res.arena.allocator();
    var hb: [64]u8 = undefined;
    while (st.todo.items.len > 0) {
        const step = st.todo.orderedRemove(0);
        try st.done.append(a, step.line);
        const head = (try repo.head()).?;
        const c = try common.readCommit(repo, a, step.id);
        const sub = common.subject(c.message);
        const parent_tree: ?Oid = if (c.parents.len > 0) try repo.treeOf(c.parents[0]) else null;
        const head_tree = try repo.treeOf(head);
        const r = try merge_trees.mergeTrees(repo, a, parent_tree, head_tree, c.tree, .{
            .base = try std.fmt.allocPrint(a, "parent of {s} ({s})", .{ common.short(step.id, &hb), sub }),
            .theirs = try std.fmt.allocPrint(a, "{s} ({s})", .{ common.short(step.id, &hb), sub }),
        });
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
        if (r.conflicts.len > 0) {
            res.conflicts = try r.conflictPaths(a);
            try writeState(repo, a, st, step.id, c);
            try common.writeState(repo, "REBASE_HEAD", try std.fmt.allocPrint(a, "{s}\n", .{step.id.hex(&hb)}));
            try common.writeState(repo, "MERGE_MSG", try common.mergeMsg(a, c.message, res.conflicts));
            res.kind = .conflicted;
            res.oid = head;
            return res.*;
        }
        const tree_id = try git.write_tree.writeTree(repo, &ix);
        // A commit whose changes are already there is dropped.
        if (tree_id.eql(head_tree)) continue;
        const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
        const new = try common.writeCommit(repo, a, tree_id, &.{head}, c.author, who, c.message, opts.signing);
        try common.moveHead(repo, a, head, new, try std.fmt.allocPrint(a, "{s} (pick): {s}", .{ st.reflog_action, sub }), who);
    }
    try finish(repo, a, st, opts);
    res.kind = .committed;
    res.oid = (try repo.head()).?;
    return res.*;
}

fn finish(repo: *Repository, a: Allocator, st: *const State, opts: Options) !void {
    const head = (try repo.head()).?;
    const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
    var hb: [64]u8 = undefined;
    if (std.mem.startsWith(u8, st.head_name, "refs/")) {
        var tx = repo.refs.transaction();
        defer tx.deinit();
        try tx.update(st.head_name, .{ .direct = head }, null, try std.fmt.allocPrint(a, "{s} (finish): {s} onto {s}", .{ st.reflog_action, st.head_name, st.onto.hex(&hb) }), who);
        try tx.commit();
        try git.checkout.setHead(repo, .{ .symbolic = st.head_name }, head, head, who, try std.fmt.allocPrint(a, "{s} (finish): returning to {s}", .{ st.reflog_action, st.head_name }));
    }
    clearAll(repo, a);
}

/// The commits of `head` not in `upstream`, oldest first, merges left out.
fn commitsToReplay(repo: *Repository, a: Allocator, head: Oid, upstream: Oid) ![]const Oid {
    const set = try git.revwalk.log(repo, a, &.{head}, &.{upstream}, 0);
    var in_set: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    for (set) |c| try in_set.put(a, c, {});
    // Parents before children: depth-first post-order from head.
    var out: std.ArrayList(Oid) = .empty;
    var visited: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    const Frame = struct { id: Oid, next: usize };
    var stack: std.ArrayList(Frame) = .empty;
    if (in_set.contains(head)) try stack.append(a, .{ .id = head, .next = 0 });
    try visited.put(a, head, {});
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        const c = try common.readCommit(repo, a, top.id);
        if (top.next < c.parents.len) {
            const p = c.parents[top.next];
            top.next += 1;
            if (in_set.contains(p) and !(try visited.getOrPut(a, p)).found_existing) try stack.append(a, .{ .id = p, .next = 0 });
            continue;
        }
        if (c.parents.len <= 1) try out.append(a, top.id);
        _ = stack.pop();
    }
    return out.items;
}

/// Whether every commit between `base` and `head` has one parent.
fn linearAbove(repo: *Repository, a: Allocator, head: Oid, base: Oid) !bool {
    const list = try git.revwalk.log(repo, a, &.{head}, &.{base}, 0);
    for (list) |id| if ((try common.readCommit(repo, a, id)).parents.len > 1) return false;
    return true;
}

fn requireClean(repo: *Repository) !void {
    var st = try git.status.status(repo, .{ .untracked = .no });
    defer st.deinit();
    if (st.entries.len > 0) return error.UncommittedChanges;
}

// ---- state files (git's .git/rebase-merge layout) ----

fn statePath(a: Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ state_dir, name });
}

fn writeStateFile(repo: *Repository, a: Allocator, name: []const u8, data: []const u8) !void {
    try repo.git_dir.writeFile(repo.io, .{ .sub_path = try statePath(a, name), .data = data });
}

fn readStateFile(repo: *Repository, a: Allocator, name: []const u8) !?[]const u8 {
    return repo.git_dir.readFileAlloc(repo.io, try statePath(a, name), a, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn writeState(repo: *Repository, a: Allocator, st: *const State, stopped: Oid, c: git.commit.Commit) !void {
    try repo.git_dir.createDirPath(repo.io, state_dir);
    var hb: [64]u8 = undefined;
    try writeStateFile(repo, a, "head-name", try std.fmt.allocPrint(a, "{s}\n", .{st.head_name}));
    try writeStateFile(repo, a, "onto", try std.fmt.allocPrint(a, "{s}\n", .{st.onto.hex(&hb)}));
    try writeStateFile(repo, a, "orig-head", try std.fmt.allocPrint(a, "{s}\n", .{st.orig_head.hex(&hb)}));
    try writeStateFile(repo, a, "interactive", "");
    try writeStateFile(repo, a, "drop_redundant_commits", "");
    var done: std.ArrayList(u8) = .empty;
    for (st.done.items) |l| try done.print(a, "{s}\n", .{l});
    try writeStateFile(repo, a, "done", done.items);
    var todo: std.ArrayList(u8) = .empty;
    for (st.todo.items) |s| try todo.print(a, "{s}\n", .{s.line});
    try writeStateFile(repo, a, "git-rebase-todo", todo.items);
    try writeStateFile(repo, a, "msgnum", try std.fmt.allocPrint(a, "{d}\n", .{st.done.items.len}));
    try writeStateFile(repo, a, "end", try std.fmt.allocPrint(a, "{d}\n", .{st.end}));
    try writeStateFile(repo, a, "stopped-sha", try std.fmt.allocPrint(a, "{s}\n", .{stopped.hex(&hb)}));
    // git adds a newline after the message; --continue strips it again.
    try writeStateFile(repo, a, "message", try std.mem.concat(a, u8, &.{ c.message, "\n" }));
    try writeStateFile(repo, a, "reflog-action", try std.fmt.allocPrint(a, "{s}\n", .{st.reflog_action}));
    var script: std.ArrayList(u8) = .empty;
    try script.print(a, "GIT_AUTHOR_NAME='{s}'\nGIT_AUTHOR_EMAIL='{s}'\nGIT_AUTHOR_DATE='@{d} {s}'\n", .{ try sq(a, c.author.name), try sq(a, c.author.email), c.author.time, c.author.tz });
    try writeStateFile(repo, a, "author-script", script.items);
}

/// Escapes a value for git's single-quoted author-script.
fn sq(a: Allocator, s: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, s, "'", "'\\''");
}

fn readAuthorScript(repo: *Repository, a: Allocator) !Ident {
    const text = (try readStateFile(repo, a, "author-script")) orelse return error.BadRebaseState;
    var id: Ident = .{ .name = "", .email = "", .time = 0, .tz = "+0000" };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const raw = line[eq + 1 ..];
        const v = try std.mem.replaceOwned(u8, a, std.mem.trim(u8, raw, "'"), "'\\''", "'");
        const k = line[0..eq];
        if (std.mem.eql(u8, k, "GIT_AUTHOR_NAME")) id.name = v else if (std.mem.eql(u8, k, "GIT_AUTHOR_EMAIL")) id.email = v else if (std.mem.eql(u8, k, "GIT_AUTHOR_DATE")) {
            const d = std.mem.trimStart(u8, v, "@");
            const sp = std.mem.indexOfScalar(u8, d, ' ') orelse return error.BadRebaseState;
            id.time = std.fmt.parseInt(i64, d[0..sp], 10) catch return error.BadRebaseState;
            id.tz = d[sp + 1 ..];
        }
    }
    return id;
}

fn readState(repo: *Repository, a: Allocator) !State {
    if (!common.hasState(repo, state_dir)) return error.NoRebaseInProgress;
    const fmt = repo.format;
    const line = struct {
        fn f(s: ?[]const u8) ![]const u8 {
            return std.mem.trimEnd(u8, s orelse return error.BadRebaseState, "\n");
        }
    }.f;
    var st: State = .{
        .head_name = try line(try readStateFile(repo, a, "head-name")),
        .onto = Oid.parseHex(fmt, try line(try readStateFile(repo, a, "onto"))) catch return error.BadRebaseState,
        .orig_head = Oid.parseHex(fmt, try line(try readStateFile(repo, a, "orig-head"))) catch return error.BadRebaseState,
        .end = std.fmt.parseInt(usize, try line(try readStateFile(repo, a, "end")), 10) catch 0,
        .reflog_action = if (try readStateFile(repo, a, "reflog-action")) |r| std.mem.trimEnd(u8, r, "\n") else "rebase",
    };
    if (try readStateFile(repo, a, "done")) |d| {
        var it = std.mem.tokenizeScalar(u8, d, '\n');
        while (it.next()) |l| try st.done.append(a, l);
    }
    if (try readStateFile(repo, a, "git-rebase-todo")) |t| {
        var it = std.mem.tokenizeScalar(u8, t, '\n');
        while (it.next()) |l| {
            if (l.len == 0 or l[0] == '#') continue;
            var words = std.mem.tokenizeScalar(u8, l, ' ');
            const cmd = words.next() orelse continue;
            if (!std.mem.eql(u8, cmd, "pick") and !std.mem.eql(u8, cmd, "p")) return error.UnsupportedRebaseCommand;
            const id = git.revparse.resolveCommit(repo, words.next() orelse return error.BadRebaseState) catch return error.BadRebaseState;
            try st.todo.append(a, .{ .id = id, .line = l });
        }
    }
    return st;
}

fn clearStop(repo: *Repository) void {
    repo.git_dir.deleteFile(repo.io, "REBASE_HEAD") catch {};
    repo.git_dir.deleteFile(repo.io, "MERGE_MSG") catch {};
    repo.git_dir.deleteFile(repo.io, state_dir ++ "/stopped-sha") catch {};
}

fn clearAll(repo: *Repository, a: Allocator) void {
    _ = a;
    clearStop(repo);
    repo.git_dir.deleteTree(repo.io, state_dir) catch {};
}
