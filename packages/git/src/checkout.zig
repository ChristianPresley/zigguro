//! Moving the working tree between commits (E09.F09.S01.T03): `git
//! switch`/`git checkout <branch|commit>` with git's two-tree rules,
//! `git restore` (from the index or a commit), and `git clean`.
//!
//! A switch changes only paths that differ between HEAD's tree and the
//! target's. A path with staged or unstaged changes, or an untracked
//! file the target would overwrite, stops the switch with
//! `error.WouldOverwrite` (the paths go to `Options.conflicts`) unless
//! the change already matches the target; other local changes carry
//! over. `force` discards local changes to tracked files instead.
//! Files are written the way git writes them: removed and recreated (so
//! the umask applies), `core.autocrlf=true` turns LF into CRLF in text,
//! symlinks become files when `core.symlinks` is false.

const std = @import("std");
const builtin = @import("builtin");
const object = @import("object.zig");
const tree_mod = @import("tree.zig");
const index_mod = @import("index/index.zig");
const status_mod = @import("status.zig");
const config_mod = @import("config.zig");
const revparse = @import("revparse.zig");
const reflog = @import("refs/reflog.zig");
const commit_cmd = @import("commit_cmd.zig");
const Repository = @import("repository.zig").Repository;
const Oid = @import("oid.zig").Oid;
const Index = index_mod.Index;
const TreeFile = status_mod.TreeFile;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    /// `-b`: create this branch at the target first (`-B`: `force_create`).
    create: ?[]const u8 = null,
    force_create: bool = false,
    /// Check out the commit itself even when it names a branch.
    detach: bool = false,
    /// `-f`: throw away local changes that stand in the way.
    force: bool = false,
    /// Receives the paths that block the switch (owned by its allocator).
    conflicts: ?*std.ArrayList([]const u8) = null,
    conflicts_gpa: ?Allocator = null,
    tz_offset_min: i32 = 0,
};

pub const Outcome = struct {
    /// The branch now checked out, or null when HEAD is detached.
    branch: ?[]const u8,
    head: Oid,
    /// Whether a local branch was made to track a remote one.
    created_tracking: bool = false,
};

/// `git switch <target>` / `git checkout <target>`: a branch name (or a
/// remote branch's short name, which creates a tracking branch), or any
/// revision (detached). Strings in the outcome are owned by `arena`.
pub fn switchTo(repo: *Repository, arena: Allocator, target_in: []const u8, opts: Options) !Outcome {
    // `-` and `@{-N}` name the branch checked out N switches ago.
    var target = target_in;
    if (std.mem.eql(u8, target, "-")) {
        target = try revparse.previousBranch(repo, arena, 1);
    } else if (std.mem.startsWith(u8, target, "@{-") and std.mem.endsWith(u8, target, "}")) {
        const n = std.fmt.parseInt(u32, target[3 .. target.len - 1], 10) catch return error.UnknownRevision;
        target = try revparse.previousBranch(repo, arena, n);
    }
    var branch: ?[]const u8 = null;
    var tracking: ?[]const u8 = null;
    var to: Oid = undefined;
    if (opts.create) |name| {
        to = if (target.len == 0) (try repo.head()) orelse return error.UnbornHead else try revparse.resolveCommit(repo, target);
        branch = name;
    } else if (!opts.detach and (try repo.refs.resolve(try std.fmt.allocPrint(arena, "refs/heads/{s}", .{target}))) != null) {
        branch = target;
        to = (try repo.refs.resolve(try std.fmt.allocPrint(arena, "refs/heads/{s}", .{target}))).?;
    } else if (!opts.detach and (try uniqueRemoteBranch(repo, arena, target)) != null) {
        tracking = (try uniqueRemoteBranch(repo, arena, target)).?;
        branch = target;
        to = (try repo.refs.resolve(tracking.?)).?;
    } else {
        to = try revparse.resolveCommit(repo, target);
    }

    const head = try repo.head();
    try moveTree(repo, head, to, opts.force, opts.conflicts, opts.conflicts_gpa);

    const who = try commit_cmd.ident(repo, arena, repo.envMap(), .committer, nowSecs(repo), opts.tz_offset_min);
    const from_name = try describeHead(repo, arena);
    if (branch) |b| {
        const full = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{b});
        if (opts.create != null or tracking != null) {
            var tx = repo.refs.transaction();
            defer tx.deinit();
            const msg = if (tracking) |tr| try std.fmt.allocPrint(arena, "branch: Created from {s}", .{tr}) else if (target.len == 0) "branch: Created from HEAD" else try std.fmt.allocPrint(arena, "branch: Created from {s}", .{target});
            try tx.update(full, .{ .direct = to }, if (opts.force_create) null else .absent, msg, who);
            try tx.commit();
        }
        if (tracking) |tr| try setUpstream(repo, b, tr);
        try setHead(repo, .{ .symbolic = full }, head, to, who, try std.fmt.allocPrint(arena, "checkout: moving from {s} to {s}", .{ from_name, b }));
    } else {
        var hb: [64]u8 = undefined;
        try setHead(repo, .{ .direct = to }, head, to, who, try std.fmt.allocPrint(arena, "checkout: moving from {s} to {s}", .{ from_name, to.hex(&hb) }));
    }
    return .{ .branch = branch, .head = to, .created_tracking = tracking != null };
}

fn nowSecs(repo: *Repository) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s));
}

/// The short branch name HEAD is on, or its commit id.
fn describeHead(repo: *Repository, a: Allocator) ![]const u8 {
    if (try repo.headRef(a)) |r| return if (std.mem.startsWith(u8, r, "refs/heads/")) r["refs/heads/".len..] else r;
    var hb: [64]u8 = undefined;
    const h = (try repo.head()) orelse return "HEAD";
    return a.dupe(u8, h.hex(&hb));
}

/// `refs/remotes/<remote>/<name>` when exactly one remote has `name`.
fn uniqueRemoteBranch(repo: *Repository, a: Allocator, name: []const u8) !?[]const u8 {
    var list = try repo.refs.iterate(repo.gpa, "refs/remotes/");
    defer list.deinit();
    var found: ?[]const u8 = null;
    for (list.refs) |r| {
        const rest = r.name["refs/remotes/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        if (!std.mem.eql(u8, rest[slash + 1 ..], name)) continue;
        if (found != null) return null;
        found = try a.dupe(u8, r.name);
    }
    return found;
}

/// Writes branch.<b>.remote and .merge for `tracking`
/// (refs/remotes/<remote>/<branch>).
pub fn setUpstream(repo: *Repository, b: []const u8, tracking: []const u8) !void {
    const rest = tracking["refs/remotes/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUpstream;
    var kb: [512]u8 = undefined;
    var vb: [512]u8 = undefined;
    const cfg = try std.fs.path.join(repo.gpa, &.{ repo.common_dir_path, "config" });
    defer repo.gpa.free(cfg);
    try config_mod.setValue(repo.gpa, repo.io, cfg, try std.fmt.bufPrint(&kb, "branch.{s}.remote", .{b}), rest[0..slash]);
    try config_mod.setValue(repo.gpa, repo.io, cfg, try std.fmt.bufPrint(&kb, "branch.{s}.merge", .{b}), try std.fmt.bufPrint(&vb, "refs/heads/{s}", .{rest[slash + 1 ..]}));
    try repo.reloadConfig(.{ .env = repo.env });
}

/// Points HEAD at `v` and logs the move in HEAD's reflog.
pub fn setHead(repo: *Repository, v: @import("refs/refs.zig").RefValue, old: ?Oid, new: Oid, who: @import("commit.zig").Ident, msg: []const u8) !void {
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.update("HEAD", v, null, msg, who);
    try tx.commit();
    // Symbolic updates are not logged by the transaction.
    if (v == .symbolic) {
        var aw: std.Io.Writer.Allocating = .init(repo.gpa);
        defer aw.deinit();
        try reflog.formatLine(&aw.writer, old orelse Oid.zero(repo.format), new, who, msg);
        try reflog.append(repo.io, repo.git_dir, "HEAD", aw.written());
    }
}

/// Moves index and working tree from commit `from` (null: nothing) to
/// commit `to` with the two-tree rules (or discarding local changes when
/// `force`).
pub fn moveTree(repo: *Repository, from: ?Oid, to: Oid, force: bool, conflicts: ?*std.ArrayList([]const u8), cgpa: ?Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const h_files: []const TreeFile = if (from) |f| try status_mod.flattenTree(repo, a, try repo.treeOf(f)) else &.{};
    const t_files = try status_mod.flattenTree(repo, a, try repo.treeOf(to));
    var ix = try repo.readIndex();
    defer ix.deinit();
    if (force) {
        try resetTo(repo, a, &ix, t_files, .hard);
        try repo.writeIndex(&ix);
        return;
    }
    for (ix.entries.items) |e| if (e.flags.stage != 0) return error.UnmergedEntries;

    var st = try status_mod.status(repo, .{ .untracked = .all, .refresh = false });
    defer st.deinit();
    var dirty: std.StringHashMapUnmanaged(status_mod.Entry) = .empty;
    for (st.entries) |e| try dirty.put(a, e.path, e);

    var hmap: std.StringHashMapUnmanaged(TreeFile) = .empty;
    for (h_files) |f| try hmap.put(a, f.path, f);
    var tmap: std.StringHashMapUnmanaged(TreeFile) = .empty;
    for (t_files) |f| try tmap.put(a, f.path, f);

    // The paths that differ between the trees.
    var changed: std.ArrayList([]const u8) = .empty;
    for (h_files) |f| {
        const t = tmap.get(f.path);
        if (t == null or !t.?.oid.eql(f.oid) or t.?.mode != f.mode) try changed.append(a, f.path);
    }
    for (t_files) |f| if (!hmap.contains(f.path)) try changed.append(a, f.path);

    var blocked: std.ArrayList([]const u8) = .empty;
    for (changed.items) |p| {
        const t = tmap.get(p);
        const ie: ?index_mod.Entry = if (ix.find(p, 0)) |i| ix.entries.items[i] else null;
        const d = dirty.get(p);
        // Already as the target wants (both absent counts).
        const index_is_target = if (ie) |e| (t != null and e.oid.eql(t.?.oid) and e.mode == t.?.mode) else t == null;
        if (d) |de| if (de.x == .untracked) {
            if (t != null) try blocked.append(a, p);
            continue;
        };
        // The index already holds the target: local edits carry over.
        if (index_is_target) continue;
        if (d != null) {
            try blocked.append(a, p);
            continue;
        }
        // A new target file under a path that is an untracked file.
        if (t != null and !hmap.contains(p)) {
            var it = std.mem.splitScalar(u8, p, '/');
            var len: usize = 0;
            while (it.next()) |part| {
                len += part.len;
                if (len >= p.len) break;
                if (dirty.get(p[0..len])) |pe| if (pe.x == .untracked) try blocked.append(a, p[0..len]);
                len += 1;
            }
        }
    }
    if (blocked.items.len > 0) {
        if (conflicts) |c| for (blocked.items) |p| try c.append(cgpa.?, try cgpa.?.dupe(u8, p));
        return error.WouldOverwrite;
    }

    for (changed.items) |p| {
        const t = tmap.get(p);
        const ie: ?index_mod.Entry = if (ix.find(p, 0)) |i| ix.entries.items[i] else null;
        if (t) |tf| {
            if (ie) |e| if (e.oid.eql(tf.oid) and e.mode == tf.mode) continue;
            try writeEntry(repo, &ix, tf.path, tf.mode, tf.oid);
        } else {
            if (ie == null) continue;
            _ = ix.remove(p);
            removeWorktreeFile(repo, p);
        }
    }
    try repo.writeIndex(&ix);
}

pub const ResetMode = enum { soft, mixed, hard };

/// Index (mixed) and worktree (hard) to `files`: entries whose blob and
/// mode already match keep their stat data.
pub fn resetTo(repo: *Repository, a: Allocator, ix: *Index, files: []const TreeFile, mode: ResetMode) !void {
    if (mode == .soft) return;
    var tmap: std.StringHashMapUnmanaged(TreeFile) = .empty;
    for (files) |f| try tmap.put(a, f.path, f);
    // Entries the target does not have go (and their files, when hard).
    var gone: std.ArrayList([]const u8) = .empty;
    for (ix.entries.items) |e| {
        if (tmap.get(e.path)) |t| if (e.flags.stage == 0 and !e.flags.intent_to_add and t.oid.eql(e.oid) and t.mode == e.mode) continue;
        if (gone.items.len == 0 or !std.mem.eql(u8, gone.items[gone.items.len - 1], e.path)) try gone.append(a, try a.dupe(u8, e.path));
    }
    var dirty: std.StringHashMapUnmanaged(void) = .empty;
    if (mode == .hard) {
        var st = try status_mod.status(repo, .{ .untracked = .no, .refresh = false });
        defer st.deinit();
        for (st.entries) |e| if (e.y != .unmodified) try dirty.put(a, try a.dupe(u8, e.path), {});
    }
    for (gone.items) |p| {
        _ = ix.remove(p);
        if (mode == .hard and !tmap.contains(p)) removeWorktreeFile(repo, p);
    }
    for (files) |f| {
        if (ix.find(f.path, 0) != null) {
            // Unchanged in the index; the worktree may still differ.
            if (mode == .hard and dirty.contains(f.path)) try writeEntry(repo, ix, f.path, f.mode, f.oid);
            continue;
        }
        if (mode == .hard) {
            try writeEntry(repo, ix, f.path, f.mode, f.oid);
        } else try ix.add(.{ .mode = f.mode, .oid = f.oid, .path = f.path });
    }
}

/// Writes blob `id` to the worktree file `rel` and stages it with the
/// new file's stat data.
pub fn writeEntry(repo: *Repository, ix: *Index, rel: []const u8, mode: u32, id: Oid) !void {
    try writeFile(repo, rel, mode, id);
    const st = try repo.work.statFile(repo.io, rel, .{ .follow_symlinks = false });
    var e: index_mod.Entry = .{ .mode = mode, .oid = id, .path = rel };
    status_mod.setStat(&e, st);
    try ix.add(e);
}

/// Writes blob `id` as worktree file `rel` with git's smudge rules.
pub fn writeFile(repo: *Repository, rel: []const u8, mode: u32, id: Oid) !void {
    const gpa = repo.gpa;
    if (mode == tree_mod.mode_gitlink) {
        // A submodule: only its directory.
        try repo.work.createDirPath(repo.io, rel);
        return;
    }
    var blob = try repo.odb.read(gpa, id);
    defer blob.deinit(gpa);
    try writeContent(repo, rel, mode, blob.data);
}

/// Writes `content` (blob bytes, before smudging) as worktree file `rel`,
/// replacing what is there; used for blobs and for merged text with
/// conflict markers.
pub fn writeContent(repo: *Repository, rel: []const u8, mode: u32, content: []const u8) !void {
    const gpa = repo.gpa;
    if (std.fs.path.dirnamePosix(rel)) |dir| try makeParents(repo, dir);
    // Replace whatever is there.
    repo.work.deleteFile(repo.io, rel) catch |e| switch (e) {
        error.FileNotFound => {},
        error.IsDir => repo.work.deleteDir(repo.io, rel) catch return error.DirectoryInTheWay,
        else => return e,
    };
    const symlinks = repo.config.getBool("core.symlinks") orelse (builtin.os.tag != .windows);
    if (mode == tree_mod.mode_symlink and symlinks) {
        try repo.work.symLink(repo.io, content, rel, .{});
        return;
    }
    const data = try smudge(repo, gpa, content, mode);
    defer if (data.ptr != content.ptr) gpa.free(data);
    const perms: Io.File.Permissions = if (mode == tree_mod.mode_exec) .executable_file else .default_file;
    try repo.work.writeFile(repo.io, .{ .sub_path = rel, .data = data, .flags = .{ .permissions = perms } });
}

/// Creates the directories of `dir`, removing a file that stands where
/// a directory must go.
fn makeParents(repo: *Repository, dir: []const u8) !void {
    repo.work.createDirPath(repo.io, dir) catch |e| switch (e) {
        error.NotDir => {
            var it = std.mem.splitScalar(u8, dir, '/');
            var len: usize = 0;
            while (it.next()) |part| {
                len += part.len;
                const sub = dir[0..len];
                const st = repo.work.statFile(repo.io, sub, .{ .follow_symlinks = false }) catch {
                    len += 1;
                    continue;
                };
                if (st.kind != .directory) try repo.work.deleteFile(repo.io, sub);
                len += 1;
            }
            try repo.work.createDirPath(repo.io, dir);
        },
        else => return e,
    };
}

/// LF to CRLF in text when `core.autocrlf` is true.
fn smudge(repo: *const Repository, gpa: Allocator, data: []const u8, mode: u32) ![]const u8 {
    if (mode == tree_mod.mode_symlink) return data;
    const v = repo.config.get("core.autocrlf") orelse return data;
    if (!(config_mod.parseBool(v) orelse false)) return data;
    if (!status_mod.isText(data) or std.mem.indexOfScalar(u8, data, '\n') == null) return data;
    // Files that already have CRLF are left alone, as git does.
    if (std.mem.indexOf(u8, data, "\r\n") != null) return data;
    const n = std.mem.count(u8, data, "\n");
    var out = try gpa.alloc(u8, data.len + n);
    var j: usize = 0;
    for (data) |c| {
        if (c == '\n') {
            out[j] = '\r';
            j += 1;
        }
        out[j] = c;
        j += 1;
    }
    return out;
}

/// Deletes a worktree file and the directories it leaves empty.
pub fn removeWorktreeFile(repo: *Repository, rel: []const u8) void {
    repo.work.deleteFile(repo.io, rel) catch |e| switch (e) {
        error.IsDir => {},
        else => {},
    };
    var d = std.fs.path.dirnamePosix(rel);
    while (d) |dir| : (d = std.fs.path.dirnamePosix(dir)) {
        repo.work.deleteDir(repo.io, dir) catch return;
    }
}

pub const RestoreSource = union(enum) {
    /// The index (`git restore <paths>`: discard unstaged changes).
    index,
    /// A commit (`git restore --source=<rev> --staged --worktree`).
    commit: Oid,
};

/// `git restore`: puts the paths' content back from `source`. From a
/// commit both index and worktree change; paths the commit lacks are
/// removed. Returns how many files changed.
pub fn restore(repo: *Repository, paths: []const []const u8, source: RestoreSource) !usize {
    var arena_state: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ix = try repo.readIndex();
    defer ix.deinit();
    var n: usize = 0;
    switch (source) {
        .index => {
            var st = try status_mod.status(repo, .{ .untracked = .no, .refresh = false, .pathspec = paths });
            defer st.deinit();
            for (st.entries) |e| {
                if (e.y == .unmodified) continue;
                if (e.isConflict()) {
                    // The "ours" version resolves nothing; leave conflicts.
                    continue;
                }
                const i = ix.find(e.path, 0) orelse continue;
                const ie = ix.entries.items[i];
                if (ie.flags.intent_to_add) continue;
                try writeEntry(repo, &ix, ie.path, ie.mode, ie.oid);
                n += 1;
            }
        },
        .commit => |c| {
            const files = try status_mod.flattenTree(repo, a, try repo.treeOf(c));
            var sel: std.ArrayList(TreeFile) = .empty;
            for (files) |f| if (matches(f.path, paths)) try sel.append(a, f);
            var gone: std.ArrayList([]const u8) = .empty;
            for (ix.entries.items) |e| if (matches(e.path, paths)) {
                const keep = for (sel.items) |f| {
                    if (std.mem.eql(u8, f.path, e.path)) break true;
                } else false;
                if (!keep) try gone.append(a, try a.dupe(u8, e.path));
            };
            for (gone.items) |p| {
                if (ix.remove(p)) n += 1;
                removeWorktreeFile(repo, p);
            }
            for (sel.items) |f| {
                try writeEntry(repo, &ix, f.path, f.mode, f.oid);
                n += 1;
            }
        },
    }
    try repo.writeIndex(&ix);
    return n;
}

fn matches(path: []const u8, spec: []const []const u8) bool {
    if (spec.len == 0) return true;
    for (spec) |s| {
        const t = std.mem.trimEnd(u8, s, "/");
        if (t.len == 0 or std.mem.eql(u8, t, ".") or std.mem.eql(u8, path, t)) return true;
        if (path.len > t.len and std.mem.startsWith(u8, path, t) and path[t.len] == '/') return true;
    }
    return false;
}

/// `git clean -f [-d] [-x]`: deletes untracked files (and directories
/// with `dirs`; ignored ones too with `ignored`). Returns the paths
/// removed, owned by `gpa`.
pub fn clean(repo: *Repository, gpa: Allocator, paths: []const []const u8, dirs: bool, ignored: bool) ![][]const u8 {
    var st = try status_mod.status(repo, .{ .untracked = .normal, .ignored = ignored, .refresh = false, .pathspec = paths });
    defer st.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    for (st.entries) |e| {
        if (e.x != .untracked and e.x != .ignored) continue;
        const is_dir = std.mem.endsWith(u8, e.path, "/");
        if (is_dir and !dirs) continue;
        const p = std.mem.trimEnd(u8, e.path, "/");
        if (is_dir) try repo.work.deleteTree(repo.io, p) else try repo.work.deleteFile(repo.io, p);
        try out.append(gpa, try gpa.dupe(u8, e.path));
    }
    return out.toOwnedSlice(gpa);
}

/// `git reset [--soft|--mixed|--hard] <commit>`: moves the current
/// branch (or detached HEAD) and resets the index and worktree as
/// `mode` says. ORIG_HEAD keeps the old commit.
pub fn reset(repo: *Repository, target: Oid, mode: ResetMode, msg_rev: []const u8, tz_offset_min: i32) !void {
    var arena_state: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (mode != .hard) {
        var probe = try repo.readIndex();
        defer probe.deinit();
        if (mode == .soft) for (probe.entries.items) |e| if (e.flags.stage != 0) return error.UnmergedEntries;
    }
    const old = try repo.head();
    const files = try status_mod.flattenTree(repo, a, try repo.treeOf(target));
    var ix = try repo.readIndex();
    defer ix.deinit();
    try resetTo(repo, a, &ix, files, mode);
    if (mode != .soft) try repo.writeIndex(&ix);
    if (old) |o| {
        var hb: [64]u8 = undefined;
        const line = try std.fmt.allocPrint(a, "{s}\n", .{o.hex(&hb)});
        try @import("config.zig").writeLocked(repo.io, try std.fs.path.join(a, &.{ repo.git_dir_path, "ORIG_HEAD" }), line);
    }
    const who = try commit_cmd.ident(repo, a, repo.envMap(), .committer, nowSecs(repo), tz_offset_min);
    const ref = (try repo.headRef(a)) orelse "HEAD";
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.update(ref, .{ .direct = target }, null, try std.fmt.allocPrint(a, "reset: moving to {s}", .{msg_rev}), who);
    try tx.commit();
    if (mode == .hard) for ([_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE", "CHERRY_PICK_HEAD", "REVERT_HEAD" }) |f| {
        repo.git_dir.deleteFile(repo.io, f) catch {};
    };
}
