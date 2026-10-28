//! `git rebase` (merge backend) on a git repository (E09.F09.S01.T01):
//! replays the branch's commits onto another commit, stopping on
//! conflicts with git's `.git/rebase-merge` state so either we or git
//! can `--continue`, `--skip` or `--abort`. Merge commits are dropped
//! and commits that become empty are dropped, as git does by default.
//!
//! Interactive rebase takes a todo list instead of the branch's
//! commits: pick, reword, edit, squash, fixup, drop and break, carried
//! out as `git rebase -i` does with an editor that keeps each
//! message (GIT_EDITOR=:), unless a todo item brings its own message.
//! The todo, done list and squash messages live in the same files git
//! keeps, so git can carry on a rebase started here and the other way
//! round.

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
    /// An interactive rebase's todo list, in order (null: pick every
    /// commit of the branch). `plan` gives the default list.
    todo: ?[]const TodoItem = null,
};

/// A todo command.
pub const Command = enum {
    pick,
    reword,
    edit,
    squash,
    fixup,
    drop,
    @"break",

    /// A todo word, abbreviations included (`p`, `r`, `e`, `s`, `f`,
    /// `d`, `b`).
    pub fn parse(word: []const u8) ?Command {
        if (std.meta.stringToEnum(Command, word)) |c| return c;
        if (word.len != 1) return null;
        return switch (word[0]) {
            'p' => .pick,
            'r' => .reword,
            'e' => .edit,
            's' => .squash,
            'f' => .fixup,
            'd' => .drop,
            'b' => .@"break",
            else => null,
        };
    }

    fn isFixup(c: Command) bool {
        return c == .squash or c == .fixup;
    }
};

/// One line of an interactive rebase's todo list.
pub const TodoItem = struct {
    cmd: Command,
    /// The commit (any revision); unused for `break`.
    rev: []const u8 = "",
    /// For `reword`: the new message. For the last `squash` or `fixup`
    /// of a run: the combined commit's message. Null keeps git's.
    message: ?[]const u8 = null,
};

const state_dir = "rebase-merge";

pub fn inProgress(repo: *Repository) bool {
    return common.hasState(repo, state_dir) or common.hasState(repo, "rebase-apply");
}

/// A todo line: `pick <id> <subject>` (no id for `break`).
const Step = struct { cmd: Command = .pick, id: ?Oid, line: []const u8 };

const State = struct {
    head_name: []const u8,
    onto: Oid,
    orig_head: Oid,
    done: std.ArrayList([]const u8) = .empty,
    todo: std.ArrayList(Step) = .empty,
    end: usize,
    reflog_action: []const u8,
    /// Messages todo items brought (`zg-message-<id>` files).
    messages: std.AutoHashMapUnmanaged(Oid, []const u8) = .empty,
    /// The squash/fixup run so far: git's `current-fixups` lines and
    /// `message-squash`.
    fixups: std.ArrayList(u8) = .empty,
    squash_msg: ?[]const u8 = null,
};

/// What a stop leaves for `--continue`.
const Stop = struct {
    id: Oid,
    message: []const u8,
    author: Ident,
    /// The commit `edit` (or a squash) made, which `--continue` amends.
    amend: ?Oid = null,
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
    if (opts.todo == null and try git.revwalk.isAncestor(repo, onto, head)) {
        const bases = try git.revwalk.mergeBases(repo, a, onto, head);
        if (bases.len == 1 and bases[0].eql(onto) and try linearAbove(repo, a, head, onto)) {
            res.kind = .up_to_date;
            res.oid = head;
            return res;
        }
    }

    const head_name = (try repo.headRef(a)) orelse "detached HEAD";
    var st: State = .{ .head_name = head_name, .onto = onto, .orig_head = head, .end = 0, .reflog_action = opts.reflog_action };
    var hb: [64]u8 = undefined;
    if (opts.todo) |items| {
        for (items) |it| {
            if (it.cmd == .@"break") {
                try st.todo.append(a, .{ .cmd = .@"break", .id = null, .line = "break" });
                continue;
            }
            const id = try git.revparse.resolveCommit(repo, it.rev);
            const c = try common.readCommit(repo, a, id);
            try st.todo.append(a, .{ .cmd = it.cmd, .id = id, .line = try std.fmt.allocPrint(a, "{s} {s} {s}", .{ @tagName(it.cmd), id.hex(&hb), common.subject(c.message) }) });
            if (it.message) |m| try st.messages.put(a, id, try ensureNewline(a, m));
        }
        if (st.todo.items.len == 0) return error.NothingToDo;
        for (st.todo.items) |step| {
            if (step.cmd == .@"break" or step.cmd == .drop) continue;
            if (step.cmd.isFixup()) return error.SquashWithoutPrevious;
            break;
        }
    } else for (picks) |id| {
        const c = try common.readCommit(repo, a, id);
        try st.todo.append(a, .{ .id = id, .line = try std.fmt.allocPrint(a, "pick {s} {s}", .{ id.hex(&hb), common.subject(c.message) }) });
    }
    st.end = st.todo.items.len;

    // Leading picks already on top of `onto` are kept as they are.
    var start = onto;
    while (st.todo.items.len > 0 and st.todo.items[0].cmd == .pick) {
        const c = try common.readCommit(repo, a, st.todo.items[0].id.?);
        if (c.parents.len != 1 or !c.parents[0].eql(start)) break;
        start = st.todo.items[0].id.?;
        try st.done.append(a, st.todo.orderedRemove(0).line);
    }

    try common.writeOrigHead(repo, a, head);
    const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
    var blocked: std.ArrayList([]const u8) = .empty;
    git.checkout.moveTree(repo, head, start, false, &blocked, a) catch |e| {
        if (e == error.WouldOverwrite) try opts.blocked.report(blocked.items);
        return e;
    };
    try git.checkout.setHead(repo, .{ .direct = start }, head, start, who, try std.fmt.allocPrint(a, "{s} (start): checkout {s}", .{ opts.reflog_action, opts.onto orelse upstream }));
    return run(repo, &res, &st, opts);
}

/// The default todo list for rebasing the current branch onto
/// `upstream`: a `pick` of each commit, oldest first, in `a`.
pub fn plan(repo: *Repository, a: Allocator, upstream: []const u8) ![]TodoItem {
    const head = (try repo.head()) orelse return error.UnbornHead;
    const up = try git.revparse.resolveCommit(repo, upstream);
    const picks = try commitsToReplay(repo, a, head, up);
    const out = try a.alloc(TodoItem, picks.len);
    for (picks, out) |id, *it| {
        var hb: [64]u8 = undefined;
        it.* = .{ .cmd = .pick, .rev = try a.dupe(u8, id.hex(&hb)) };
    }
    return out;
}

/// A todo list as git shows it in the editor: `pick 1a2b3c4 Subject`.
pub fn formatTodo(repo: *Repository, items: []const TodoItem, w: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    for (items) |it| {
        if (it.cmd == .@"break") {
            try w.writeAll("break\n");
            continue;
        }
        const id = try git.revparse.resolveCommit(repo, it.rev);
        const c = try common.readCommit(repo, arena.allocator(), id);
        var hb: [64]u8 = undefined;
        try w.print("{s} {s} {s}\n", .{ @tagName(it.cmd), common.short(id, &hb), common.subject(c.message) });
    }
}

/// Reads a todo list in git's format: one command per line, `#`
/// comments, abbreviations (`p`, `s`, ...). The text after the commit
/// is git's subject and is not used. Commands git has that are not
/// built in here (`exec`, `label`, `merge`, `fixup -C`, ...) fail with
/// `error.UnsupportedRebaseCommand`.
pub fn parseTodo(a: Allocator, text: []const u8) ![]TodoItem {
    var out: std.ArrayList(TodoItem) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, l, " \t");
        const word = words.next().?;
        if (std.mem.eql(u8, word, "noop")) continue;
        const cmd = Command.parse(word) orelse return error.UnsupportedRebaseCommand;
        if (cmd == .@"break") {
            try out.append(a, .{ .cmd = .@"break" });
            continue;
        }
        const rev = words.next() orelse return error.BadRebaseTodo;
        if (rev[0] == '-') return error.UnsupportedRebaseCommand;
        try out.append(a, .{ .cmd = cmd, .rev = rev });
    }
    return out.items;
}

/// `git rebase --continue`: commits the resolved stop (or amends the
/// commit an `edit` stopped at), then goes on.
pub fn continueRebase(repo: *Repository, opts: Options) !common.Result {
    var res: common.Result = .init(repo.gpa);
    errdefer res.deinit();
    const a = res.arena.allocator();
    var st = try readState(repo, a);
    var ix = try repo.readIndex();
    defer ix.deinit();
    for (ix.entries.items) |e| if (e.flags.stage != 0) return error.UnresolvedConflicts;
    const head = (try repo.head()).?;
    const tree_id = try git.write_tree.writeTree(repo, &ix);
    const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
    const stopped = try readOid(repo, a, "stopped-sha");
    const amend = try readOid(repo, a, "amend");
    if (stopped != null and st.fixups.items.len > 0) {
        // A squash or fixup that conflicted: fold the resolution into HEAD.
        const hc = try common.readCommit(repo, a, head);
        const last = lastOfRun(&st);
        const has_squash = std.mem.indexOf(u8, st.fixups.items, "squash ") != null;
        const msg = if (last and st.messages.get(stopped.?) != null) st.messages.get(stopped.?).? else if (last or has_squash) try cleanup(a, st.squash_msg.?) else st.squash_msg.?;
        const new = try common.writeCommit(repo, a, tree_id, hc.parents, hc.author, who, msg, opts.signing);
        try common.moveHead(repo, a, head, new, try std.fmt.allocPrint(a, "{s} (continue): {s}", .{ st.reflog_action, common.subject(msg) }), who);
        if (last) endRun(repo, &st);
    } else if (amend) |amended| {
        // `edit`: staged changes amend the commit it stopped at.
        if (head.eql(amended) and !tree_id.eql(try repo.treeOf(head))) {
            const hc = try common.readCommit(repo, a, head);
            const new = try common.writeCommit(repo, a, tree_id, hc.parents, hc.author, who, hc.message, opts.signing);
            try common.moveHead(repo, a, head, new, try std.fmt.allocPrint(a, "{s} (continue): {s}", .{ st.reflog_action, common.subject(hc.message) }), who);
        }
    } else if (stopped) |id| {
        // Commit what was resolved with the stopped commit's message and author.
        if (!tree_id.eql(try repo.treeOf(head))) {
            const raw = (try readStateFile(repo, a, "message")) orelse return error.BadRebaseState;
            const msg = try std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, raw, "\n"), "\n" });
            const author = try readAuthorScript(repo, a);
            const new = try common.writeCommit(repo, a, tree_id, &.{head}, author, who, msg, opts.signing);
            try common.moveHead(repo, a, head, new, try std.fmt.allocPrint(a, "{s} (continue): {s}", .{ st.reflog_action, common.subject(msg) }), who);
            // A `reword` that conflicted gets its new message now.
            if (st.messages.get(id)) |m| try reword(repo, a, &st, new, try common.readCommit(repo, a, new), m, who, opts);
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
        const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
        const id = step.id orelse {
            // `break`: stop here; --continue goes on.
            try writeState(repo, a, st, null);
            res.kind = .stopped;
            res.oid = head;
            return res.*;
        };
        if (step.cmd == .drop) continue;
        const c = try common.readCommit(repo, a, id);
        const fixup = step.cmd.isFixup();

        // A commit already on top of HEAD is kept as it is.
        if (!fixup and c.parents.len == 1 and c.parents[0].eql(head)) {
            var blocked: std.ArrayList([]const u8) = .empty;
            git.checkout.moveTree(repo, head, id, false, &blocked, a) catch |e| {
                if (e == error.WouldOverwrite) try opts.blocked.report(blocked.items);
                return e;
            };
            try common.moveHead(repo, a, head, id, "rebase: fast-forward", who);
            if (step.cmd == .reword) {
                const msg = st.messages.get(id) orelse c.message;
                try reword(repo, a, st, id, c, msg, who, opts);
            }
            if (step.cmd == .edit) return stopAt(repo, res, st, .{ .id = id, .message = c.message, .author = c.author, .amend = id });
            continue;
        }

        if (fixup) try addToRun(repo, a, st, step.cmd, id, c.message, head);
        const sub = common.subject(c.message);
        const parent_tree: ?Oid = if (c.parents.len > 0) try repo.treeOf(c.parents[0]) else null;
        const head_tree = try repo.treeOf(head);
        const r = try merge_trees.mergeTrees(repo, a, parent_tree, head_tree, c.tree, .{
            .base = try std.fmt.allocPrint(a, "parent of {s} ({s})", .{ common.short(id, &hb), sub }),
            .theirs = try std.fmt.allocPrint(a, "{s} ({s})", .{ common.short(id, &hb), sub }),
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
            if (fixup) {
                try writeState(repo, a, st, .{ .id = id, .message = st.squash_msg.?, .author = c.author, .amend = head });
                try common.writeState(repo, "MERGE_MSG", st.squash_msg.?);
            } else {
                try writeState(repo, a, st, .{ .id = id, .message = try std.mem.concat(a, u8, &.{ c.message, "\n" }), .author = c.author });
                try common.writeState(repo, "MERGE_MSG", try common.mergeMsg(a, c.message, res.conflicts));
            }
            try common.writeState(repo, "REBASE_HEAD", try std.fmt.allocPrint(a, "{s}\n", .{id.hex(&hb)}));
            res.kind = .conflicted;
            res.oid = head;
            return res.*;
        }
        const tree_id = try git.write_tree.writeTree(repo, &ix);

        if (fixup) {
            // Meld into HEAD: its parents and author, the run's message.
            const hc = try common.readCommit(repo, a, head);
            const last = lastOfRun(st);
            const msg = if (last) st.messages.get(id) orelse try cleanup(a, st.squash_msg.?) else st.squash_msg.?;
            const new = try common.writeCommit(repo, a, tree_id, hc.parents, hc.author, who, msg, opts.signing);
            try common.moveHead(repo, a, head, new, try std.fmt.allocPrint(a, "{s} ({s}): {s}", .{ st.reflog_action, @tagName(step.cmd), common.subject(msg) }), who);
            if (last) endRun(repo, st);
            continue;
        }
        // A commit whose changes are already there is dropped.
        if (tree_id.eql(head_tree)) continue;
        // As git does: pick with the old message, then reword.
        const new = try common.writeCommit(repo, a, tree_id, &.{head}, c.author, who, c.message, opts.signing);
        try common.moveHead(repo, a, head, new, try std.fmt.allocPrint(a, "{s} ({s}): {s}", .{ st.reflog_action, @tagName(step.cmd), common.subject(c.message) }), who);
        if (step.cmd == .reword) if (st.messages.get(id)) |msg| try reword(repo, a, st, new, try common.readCommit(repo, a, new), msg, who, opts);
        if (step.cmd == .edit) return stopAt(repo, res, st, .{ .id = id, .message = c.message, .author = c.author, .amend = new });
    }
    try finish(repo, a, st, opts);
    res.kind = .committed;
    res.oid = (try repo.head()).?;
    return res.*;
}

/// Gives HEAD (`id`) the message `msg` (`commit --amend`), logged only
/// when that makes a new commit.
fn reword(repo: *Repository, a: Allocator, st: *const State, id: Oid, c: git.commit.Commit, msg: []const u8, who: Ident, opts: Options) !void {
    const new = try common.writeCommit(repo, a, c.tree, c.parents, c.author, who, msg, opts.signing);
    if (new.eql(id)) return;
    try common.moveHead(repo, a, id, new, try std.fmt.allocPrint(a, "{s} (reword): {s}", .{ st.reflog_action, common.subject(msg) }), who);
}

/// Stops after an `edit`: `--continue` amends HEAD with what is staged.
fn stopAt(repo: *Repository, res: *common.Result, st: *State, stop: Stop) !common.Result {
    const a = res.arena.allocator();
    var hb: [64]u8 = undefined;
    try writeState(repo, a, st, .{ .id = stop.id, .message = try std.mem.concat(a, u8, &.{ stop.message, "\n" }), .author = stop.author, .amend = stop.amend });
    try common.writeState(repo, "REBASE_HEAD", try std.fmt.allocPrint(a, "{s}\n", .{stop.id.hex(&hb)}));
    res.kind = .stopped;
    res.oid = (try repo.head()).?;
    return res.*;
}

/// Whether the next command ends the squash/fixup run.
fn lastOfRun(st: *const State) bool {
    for (st.todo.items) |s| return !s.cmd.isFixup();
    return true;
}

/// Adds a squash or fixup to the run's message, as git's
/// `message-squash` builds it.
fn addToRun(repo: *Repository, a: Allocator, st: *State, cmd: Command, id: Oid, message: []const u8, head: Oid) !void {
    var msg: std.ArrayList(u8) = .empty;
    var n: usize = 2;
    if (st.squash_msg) |prev| {
        const first = std.mem.sliceTo(prev, '\n');
        const prefix = "# This is a combination of ";
        if (std.mem.startsWith(u8, first, prefix)) {
            const rest = first[prefix.len..];
            n = 1 + (std.fmt.parseInt(usize, rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len], 10) catch 1);
            try msg.print(a, "{s}{d} commits.{s}", .{ prefix, n, prev[first.len..] });
        } else try msg.appendSlice(a, prev);
    } else {
        const hc = try common.readCommit(repo, a, head);
        try msg.print(a, "# This is a combination of 2 commits.\n# This is the 1st commit message:\n\n{s}", .{hc.message});
    }
    var hb: [64]u8 = undefined;
    if (st.fixups.items.len > 0) try st.fixups.append(a, '\n');
    try st.fixups.print(a, "{s} {s}", .{ @tagName(cmd), id.hex(&hb) });
    if (cmd == .squash) {
        try msg.print(a, "\n# This is the commit message #{d}:\n\n{s}", .{ n, message });
    } else {
        try msg.print(a, "\n# The commit message #{d} will be skipped:\n\n", .{n});
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, message, "\n"), '\n');
        while (it.next()) |l| try msg.print(a, "#{s}{s}\n", .{ if (l.len > 0) " " else "", l });
    }
    st.squash_msg = msg.items;
}

/// The run is over: its files go.
fn endRun(repo: *Repository, st: *State) void {
    st.fixups.clearRetainingCapacity();
    st.squash_msg = null;
    repo.git_dir.deleteFile(repo.io, state_dir ++ "/current-fixups") catch {};
    repo.git_dir.deleteFile(repo.io, state_dir ++ "/message-squash") catch {};
}

/// git's `--cleanup=strip`: no `#` lines, no trailing blanks, no runs of
/// empty lines, none at either end.
fn cleanup(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var blank = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (raw.len > 0 and raw[0] == '#') continue;
        const l = std.mem.trimEnd(u8, raw, " \t\r");
        if (l.len == 0) {
            blank = out.items.len > 0;
            continue;
        }
        if (blank) try out.append(a, '\n');
        blank = false;
        try out.print(a, "{s}\n", .{l});
    }
    return out.items;
}

fn ensureNewline(a: Allocator, m: []const u8) ![]const u8 {
    const t = std.mem.trimEnd(u8, m, "\n");
    return std.mem.concat(a, u8, &.{ t, "\n" });
}

fn finish(repo: *Repository, a: Allocator, st: *const State, opts: Options) !void {
    const head = (try repo.head()).?;
    const who = try common.ident(repo, a, .committer, opts.tz_offset_min);
    var hb: [64]u8 = undefined;
    if (std.mem.startsWith(u8, st.head_name, "refs/")) {
        // A branch that ends where it was is left alone (and unlogged).
        if (!head.eql(st.orig_head)) {
            var tx = repo.refs.transaction();
            defer tx.deinit();
            try tx.update(st.head_name, .{ .direct = head }, null, try std.fmt.allocPrint(a, "{s} (finish): {s} onto {s}", .{ st.reflog_action, st.head_name, st.onto.hex(&hb) }), who);
            try tx.commit();
        }
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

fn writeState(repo: *Repository, a: Allocator, st: *const State, stop: ?Stop) !void {
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
    try writeStateFile(repo, a, "reflog-action", try std.fmt.allocPrint(a, "{s}\n", .{st.reflog_action}));
    var it = st.messages.iterator();
    while (it.next()) |e| try writeStateFile(repo, a, try std.fmt.allocPrint(a, "zg-message-{s}", .{e.key_ptr.hex(&hb)}), e.value_ptr.*);
    if (st.fixups.items.len > 0) {
        try writeStateFile(repo, a, "current-fixups", st.fixups.items);
        try writeStateFile(repo, a, "message-squash", st.squash_msg.?);
    }
    const s = stop orelse return;
    try writeStateFile(repo, a, "stopped-sha", try std.fmt.allocPrint(a, "{s}\n", .{s.id.hex(&hb)}));
    // git adds a newline after a picked commit's message; --continue strips it again.
    try writeStateFile(repo, a, "message", s.message);
    if (s.amend) |m| try writeStateFile(repo, a, "amend", try std.fmt.allocPrint(a, "{s}\n", .{m.hex(&hb)}));
    var script: std.ArrayList(u8) = .empty;
    try script.print(a, "GIT_AUTHOR_NAME='{s}'\nGIT_AUTHOR_EMAIL='{s}'\nGIT_AUTHOR_DATE='@{d} {s}'\n", .{ try sq(a, s.author.name), try sq(a, s.author.email), s.author.time, s.author.tz });
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
            const items = try parseTodo(a, l);
            if (items.len == 0) continue;
            const item = items[0];
            if (item.cmd == .@"break") {
                try st.todo.append(a, .{ .cmd = .@"break", .id = null, .line = l });
                continue;
            }
            const id = git.revparse.resolveCommit(repo, item.rev) catch return error.BadRebaseState;
            try st.todo.append(a, .{ .cmd = item.cmd, .id = id, .line = l });
        }
    }
    // Messages the todo brought, for what is left and the stopped commit.
    var ids: std.ArrayList(Oid) = .empty;
    for (st.todo.items) |s| if (s.id) |id| try ids.append(a, id);
    if (try readOid(repo, a, "stopped-sha")) |id| try ids.append(a, id);
    var hb: [64]u8 = undefined;
    for (ids.items) |id| {
        if (try readStateFile(repo, a, try std.fmt.allocPrint(a, "zg-message-{s}", .{id.hex(&hb)}))) |m| try st.messages.put(a, id, m);
    }
    if (try readStateFile(repo, a, "current-fixups")) |f| try st.fixups.appendSlice(a, std.mem.trimEnd(u8, f, "\n"));
    st.squash_msg = try readStateFile(repo, a, "message-squash");
    if (st.fixups.items.len > 0 and st.squash_msg == null) return error.BadRebaseState;
    return st;
}

fn readOid(repo: *Repository, a: Allocator, name: []const u8) !?Oid {
    const text = (try readStateFile(repo, a, name)) orelse return null;
    return Oid.parseHex(repo.format, std.mem.trimEnd(u8, text, "\n")) catch error.BadRebaseState;
}

fn clearStop(repo: *Repository) void {
    repo.git_dir.deleteFile(repo.io, "REBASE_HEAD") catch {};
    repo.git_dir.deleteFile(repo.io, "MERGE_MSG") catch {};
    inline for (.{ "stopped-sha", "amend", "message", "author-script" }) |f| repo.git_dir.deleteFile(repo.io, state_dir ++ "/" ++ f) catch {};
}

fn clearAll(repo: *Repository, a: Allocator) void {
    _ = a;
    clearStop(repo);
    repo.git_dir.deleteTree(repo.io, state_dir) catch {};
}
