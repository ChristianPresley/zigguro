//! `git status` (E09.F07.S03.T01): HEAD against the index, the index
//! against the working tree, and untracked and ignored files, with git's
//! two-letter codes (X: staged, Y: unstaged; conflicts as DD, AU, UD, UA,
//! DU, AA, UU; `??` untracked, `!!` ignored).
//!
//! The working tree check trusts an entry whose stat data (size, mtime,
//! ctime, inode) matches unless it is racy (modified no earlier than the
//! index was written), and otherwise hashes the file, applying
//! `core.autocrlf` the way `git add` would. Clean entries whose stat data
//! changed are refreshed in the index (`Options.refresh`), as git does.
//! Untracked directories without tracked files show as `dir/` in normal
//! mode. Not yet: rename detection, `.gitattributes` eol/text rules and
//! submodule dirtiness (only a submodule's HEAD is compared).

const std = @import("std");
const zg_ignore = @import("zg_ignore");
const oid_mod = @import("oid.zig");
const object = @import("object.zig");
const tree_mod = @import("tree.zig");
const index_mod = @import("index/index.zig");
const worktree = @import("worktree.zig");
const Repository = @import("repository.zig").Repository;
const Oid = oid_mod.Oid;
const Index = index_mod.Index;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One side of a status code.
pub const Code = enum(u8) {
    unmodified = ' ',
    added = 'A',
    modified = 'M',
    deleted = 'D',
    type_changed = 'T',
    renamed = 'R',
    unmerged = 'U',
    untracked = '?',
    ignored = '!',
};

pub const Entry = struct {
    /// '/'-separated; untracked directories end in '/'.
    path: []const u8,
    x: Code,
    y: Code,
    /// 0 when absent on that side.
    head_mode: u32 = 0,
    index_mode: u32 = 0,
    worktree_mode: u32 = 0,
    head_oid: ?Oid = null,
    index_oid: ?Oid = null,

    pub fn isConflict(e: Entry) bool {
        return e.x == .unmerged or e.y == .unmerged or (e.x == .added and e.y == .added) or (e.x == .deleted and e.y == .deleted);
    }

    pub fn isStaged(e: Entry) bool {
        return !e.isConflict() and e.x != .unmodified and e.x != .untracked and e.x != .ignored;
    }

    pub fn isUnstaged(e: Entry) bool {
        return !e.isConflict() and e.y != .unmodified and e.y != .untracked and e.y != .ignored;
    }
};

pub const Untracked = enum { no, normal, all };

pub const Options = struct {
    untracked: Untracked = .normal,
    /// Also list ignored files (`--ignored`).
    ignored: bool = false,
    /// Write back stat data of entries found clean by hashing.
    refresh: bool = true,
    /// Only report paths under these ('/'-separated) prefixes.
    pathspec: []const []const u8 = &.{},
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
    /// Entries whose stat data was refreshed (and the index rewritten).
    refreshed: usize = 0,

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }

    /// `git status --porcelain` (v1) lines, for tests and tools.
    pub fn porcelain(r: *const Result, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (r.entries) |e| try out.print(gpa, "{c}{c} {s}\n", .{ @intFromEnum(e.x), @intFromEnum(e.y), e.path });
        return out.toOwnedSlice(gpa);
    }
};

/// One flattened HEAD tree entry.
pub const TreeFile = struct { path: []const u8, mode: u32, oid: Oid };

/// Every file of `tree` with its full path, in index order.
pub fn flattenTree(r: *Repository, arena: Allocator, tree: Oid) ![]TreeFile {
    var out: std.ArrayList(TreeFile) = .empty;
    try flattenInto(r, arena, tree, "", &out);
    std.mem.sortUnstable(TreeFile, out.items, {}, struct {
        fn lt(_: void, a: TreeFile, b: TreeFile) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return out.items;
}

fn flattenInto(r: *Repository, arena: Allocator, tree: Oid, prefix: []const u8, out: *std.ArrayList(TreeFile)) !void {
    var obj = try r.odb.read(r.gpa, tree);
    defer obj.deinit(r.gpa);
    if (obj.type != .tree) return error.CorruptObject;
    var it = tree_mod.parseTree(r.format, obj.data);
    while (try it.next()) |e| {
        const path = if (prefix.len == 0) try arena.dupe(u8, e.name) else try std.mem.concat(arena, u8, &.{ prefix, "/", e.name });
        if (e.isTree()) {
            try flattenInto(r, arena, e.oid, path, out);
        } else try out.append(arena, .{ .path = path, .mode = e.mode, .oid = e.oid });
    }
}

/// Computes the status of `repo`'s working tree.
pub fn status(repo: *Repository, opts: Options) !Result {
    var res: Result = .{ .arena = .init(repo.gpa), .entries = &.{} };
    errdefer res.deinit();
    const a = res.arena.allocator();
    var ix = try repo.readIndex();
    defer ix.deinit();

    var list: std.ArrayList(Entry) = .empty;
    const head_files: []TreeFile = if (try repo.head()) |h| try flattenTree(repo, a, try repo.treeOf(h)) else &.{};
    try headVsIndex(a, head_files, &ix, &list);
    const refreshed = try indexVsWorktree(repo, a, &ix, &list);
    if (opts.untracked != .no or opts.ignored) {
        var w: Walker = .{ .repo = repo, .a = a, .ix = &ix, .opts = opts, .out = &list, .casefold = repo.ignoreCase() };
        try w.loadGlobals();
        try w.walk("", repo.work, 0);
    }
    if (refreshed > 0 and opts.refresh) {
        repo.writeIndex(&ix) catch |e| switch (e) {
            // Another git holds the index; the refresh waits for next time.
            error.IndexLocked => {},
            else => return e,
        };
        res.refreshed = refreshed;
    }
    // Merge the staged and unstaged halves of each path, then sort.
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    var merged: std.ArrayList(Entry) = .empty;
    for (list.items) |e| {
        if (merged.items.len > 0) {
            const last = &merged.items[merged.items.len - 1];
            if (std.mem.eql(u8, last.path, e.path) and !last.isConflict() and !e.isConflict()) {
                if (e.x != .unmodified) {
                    last.x = e.x;
                    last.head_mode = e.head_mode;
                    last.head_oid = e.head_oid;
                }
                if (e.y != .unmodified) {
                    last.y = e.y;
                    last.worktree_mode = e.worktree_mode;
                }
                if (e.index_mode != 0) {
                    last.index_mode = e.index_mode;
                    last.index_oid = e.index_oid;
                }
                continue;
            }
        }
        try merged.append(a, e);
    }
    var kept: std.ArrayList(Entry) = .empty;
    for (merged.items) |e| {
        if (e.x == .unmodified and e.y == .unmodified) continue;
        if (opts.pathspec.len > 0 and !inPathspec(e.path, opts.pathspec)) continue;
        try kept.append(a, e);
    }
    res.entries = kept.items;
    return res;
}

fn inPathspec(path: []const u8, specs: []const []const u8) bool {
    for (specs) |s| {
        const t = std.mem.trimEnd(u8, s, "/");
        if (t.len == 0 or std.mem.eql(u8, path, t) or std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), t)) return true;
        if (path.len > t.len and std.mem.startsWith(u8, path, t) and path[t.len] == '/') return true;
    }
    return false;
}

/// The staged half: HEAD's files against the index's.
fn headVsIndex(a: Allocator, head: []const TreeFile, ix: *const Index, out: *std.ArrayList(Entry)) !void {
    var h: usize = 0;
    var i: usize = 0;
    const es = ix.entries.items;
    while (h < head.len or i < es.len) {
        if (i < es.len and es[i].flags.stage != 0) {
            // A conflict: every stage of the path.
            const path = es[i].path;
            var have = [_]bool{ false, false, false, false };
            var mode: u32 = 0;
            while (i < es.len and std.mem.eql(u8, es[i].path, path)) : (i += 1) {
                have[es[i].flags.stage] = true;
                mode = es[i].mode;
            }
            while (h < head.len and std.mem.order(u8, head[h].path, path) != .gt) h += 1;
            const xy: [2]Code = if (have[1] and have[2] and have[3]) .{ .unmerged, .unmerged } else if (have[2] and have[3]) .{ .added, .added } else if (have[1] and have[2]) .{ .unmerged, .deleted } else if (have[1] and have[3]) .{ .deleted, .unmerged } else if (have[2]) .{ .added, .unmerged } else if (have[3]) .{ .unmerged, .added } else .{ .deleted, .deleted };
            try out.append(a, .{ .path = path, .x = xy[0], .y = xy[1], .index_mode = mode });
            continue;
        }
        // Intent-to-add entries are not in the index as far as HEAD goes.
        if (i < es.len and es[i].flags.intent_to_add) {
            i += 1;
            continue;
        }
        const o: std.math.Order = if (h >= head.len) .gt else if (i >= es.len) .lt else std.mem.order(u8, head[h].path, es[i].path);
        switch (o) {
            .lt => {
                try out.append(a, .{ .path = head[h].path, .x = .deleted, .y = .unmodified, .head_mode = head[h].mode, .head_oid = head[h].oid });
                h += 1;
            },
            .gt => {
                try out.append(a, .{ .path = es[i].path, .x = .added, .y = .unmodified, .index_mode = es[i].mode, .index_oid = es[i].oid });
                i += 1;
            },
            .eq => {
                const e = es[i];
                const hf = head[h];
                const x: Code = if (typeOf(hf.mode) != typeOf(e.mode)) .type_changed else if (!hf.oid.eql(e.oid) or hf.mode != e.mode) .modified else .unmodified;
                try out.append(a, .{ .path = e.path, .x = x, .y = .unmodified, .head_mode = hf.mode, .head_oid = hf.oid, .index_mode = e.mode, .index_oid = e.oid });
                h += 1;
                i += 1;
            },
        }
    }
}

fn typeOf(mode: u32) u32 {
    return mode & 0o170000;
}

/// The worktree file's git mode, or null when it is missing or not a
/// file git tracks there.
fn worktreeMode(repo: *const Repository, st: Io.File.Stat, index_mode: u32) ?u32 {
    const filemode = repo.config.getBool("core.filemode") orelse true;
    const symlinks = repo.config.getBool("core.symlinks") orelse true;
    return switch (st.kind) {
        .file => blk: {
            // Without symlink support a link is checked out as a file.
            if (typeOf(index_mode) == tree_mod.mode_symlink and !symlinks) break :blk tree_mod.mode_symlink;
            const keep: u32 = if (index_mode == tree_mod.mode_exec) tree_mod.mode_exec else tree_mod.mode_file;
            if (comptime !Io.File.Permissions.has_executable_bit) break :blk keep;
            if (!filemode) break :blk keep;
            break :blk if (st.permissions.toMode() & 0o100 != 0) tree_mod.mode_exec else tree_mod.mode_file;
        },
        .sym_link => tree_mod.mode_symlink,
        .directory => if (index_mode == tree_mod.mode_gitlink) tree_mod.mode_gitlink else null,
        else => null,
    };
}

fn statMatches(e: index_mod.Entry, st: Io.File.Stat, trust_ctime: bool) bool {
    if (e.size != @as(u32, @truncate(st.size))) return false;
    if (!e.mtime.eql(.fromNanos(st.mtime.nanoseconds))) return false;
    if (trust_ctime and !e.ctime.eql(.fromNanos(st.ctime.nanoseconds))) return false;
    if (e.ino != 0 and e.ino != @as(u32, @truncate(@as(u64, @intCast(st.inode))))) return false;
    return true;
}

/// Whether the entry was written in the same instant as the index or
/// later: its stat data cannot prove the file unchanged.
fn racy(ix: *const Index, e: index_mod.Entry) bool {
    const t = ix.file_mtime orelse return true;
    if (e.mtime.sec != t.sec) return e.mtime.sec > t.sec;
    return e.mtime.nsec >= t.nsec;
}

/// The unstaged half: each merged entry against its file.
fn indexVsWorktree(repo: *Repository, a: Allocator, ix: *Index, out: *std.ArrayList(Entry)) !usize {
    const trust_ctime = repo.config.getBool("core.trustctime") orelse true;
    var refreshed: usize = 0;
    for (ix.entries.items) |*e| {
        if (e.flags.stage != 0) continue;
        if (e.flags.skip_worktree or e.flags.assume_valid) continue;
        const st = repo.work.statFile(repo.io, e.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                try out.append(a, .{ .path = e.path, .x = .unmodified, .y = .deleted, .index_mode = e.mode, .index_oid = e.oid });
                continue;
            },
            else => return err,
        };
        if (e.flags.intent_to_add) {
            try out.append(a, .{ .path = e.path, .x = .unmodified, .y = .added, .index_mode = e.mode, .worktree_mode = worktreeMode(repo, st, e.mode) orelse 0 });
            continue;
        }
        const wm = worktreeMode(repo, st, e.mode) orelse {
            // A directory (or something else) where a file was.
            try out.append(a, .{ .path = e.path, .x = .unmodified, .y = .deleted, .index_mode = e.mode, .index_oid = e.oid });
            continue;
        };
        if (typeOf(wm) != typeOf(e.mode)) {
            try out.append(a, .{ .path = e.path, .x = .unmodified, .y = .type_changed, .index_mode = e.mode, .index_oid = e.oid, .worktree_mode = wm });
            continue;
        }
        if (wm == tree_mod.mode_gitlink) {
            if (try submoduleMoved(repo, e.*)) try out.append(a, .{ .path = e.path, .x = .unmodified, .y = .modified, .index_mode = e.mode, .index_oid = e.oid, .worktree_mode = wm });
            continue;
        }
        const mode_changed = wm != e.mode;
        if (!mode_changed and statMatches(e.*, st, trust_ctime) and !racy(ix, e.*)) continue;
        // Size alone proves a change (unless the index never recorded it).
        const changed = mode_changed or (e.size != 0 and e.size != @as(u32, @truncate(st.size)) and wm != tree_mod.mode_symlink and !autocrlf(repo)) or
            !(try hashWorktree(repo, e.path, wm, st)).eql(e.oid);
        if (changed) {
            try out.append(a, .{ .path = e.path, .x = .unmodified, .y = .modified, .index_mode = e.mode, .index_oid = e.oid, .worktree_mode = wm });
            continue;
        }
        // Clean: remember the stat data so the next check is cheap.
        if (!statMatches(e.*, st, trust_ctime) or e.size == 0) {
            setStat(e, st);
            ix.changed = true;
            refreshed += 1;
        }
    }
    return refreshed;
}

/// Copies stat data from `st` into an entry.
pub fn setStat(e: *index_mod.Entry, st: Io.File.Stat) void {
    e.mtime = .fromNanos(st.mtime.nanoseconds);
    e.ctime = .fromNanos(st.ctime.nanoseconds);
    e.ino = @truncate(@as(u64, @intCast(st.inode)));
    e.size = @truncate(st.size);
}

fn submoduleMoved(repo: *Repository, e: index_mod.Entry) !bool {
    const abs = try std.fs.path.join(repo.gpa, &.{ repo.root, e.path });
    defer repo.gpa.free(abs);
    var d = (try worktree.discover(repo.gpa, repo.io, abs)) orelse return false;
    defer d.deinit(repo.gpa);
    // Uninitialized: the directory belongs to the outer repository.
    if (!std.mem.eql(u8, d.root, abs)) return false;
    const h = (worktree.headId(repo.gpa, repo.io, &d) catch return true) orelse return true;
    return !h.eql(e.oid);
}

fn autocrlf(repo: *const Repository) bool {
    const v = repo.config.get("core.autocrlf") orelse return false;
    return std.ascii.eqlIgnoreCase(v, "input") or (@import("config.zig").parseBool(v) orelse false);
}

/// The blob id `git add` would give the file at `rel`.
pub fn hashWorktree(repo: *Repository, rel: []const u8, mode: u32, st: Io.File.Stat) !Oid {
    const gpa = repo.gpa;
    if (mode == tree_mod.mode_symlink and st.kind == .sym_link) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try repo.work.readLink(repo.io, rel, &buf);
        return object.hashObject(repo.format, .blob, buf[0..n]);
    }
    const data = try repo.work.readFileAlloc(repo.io, rel, gpa, .unlimited);
    defer gpa.free(data);
    if (mode != tree_mod.mode_symlink and autocrlf(repo) and isText(data)) {
        const norm = try crlfToLf(gpa, data);
        defer gpa.free(norm);
        return object.hashObject(repo.format, .blob, norm);
    }
    return object.hashObject(repo.format, .blob, data);
}

/// git's binary sniff: no NUL in the first 8000 bytes.
pub fn isText(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data[0..@min(data.len, 8000)], 0) == null;
}

/// CRLF pairs to LF (lone CRs stay).
pub fn crlfToLf(gpa: Allocator, data: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, data.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
        out[n] = data[i];
        n += 1;
    }
    return gpa.realloc(out, n);
}

/// The ignore rules in force while walking: one level per directory with
/// a .gitignore, then info/exclude and core.excludesFile.
const Walker = struct {
    repo: *Repository,
    a: Allocator,
    ix: *const Index,
    opts: Options,
    out: *std.ArrayList(Entry),
    casefold: bool,
    levels: std.ArrayList(Level) = .empty,
    info_exclude: zg_ignore.RuleList = .empty,
    excludes_file: zg_ignore.RuleList = .empty,

    const Level = struct { base: []const u8, rules: zg_ignore.RuleList };

    fn loadGlobals(w: *Walker) !void {
        const io = w.repo.io;
        if (readSmall(w.a, io, w.repo.git_dir, "info/exclude")) |t| {
            w.info_exclude = try zg_ignore.parseRules(w.a, t, .git_info_exclude);
        } else |_| {}
        const path: ?[]const u8 = if (w.repo.config.get("core.excludesfile")) |p|
            try expandHome(w.a, p, w.repo.home)
        else if (w.repo.home) |h|
            try std.fs.path.join(w.a, &.{ h, ".config", "git", "ignore" })
        else
            null;
        if (path) |p| if (readSmall(w.a, io, Io.Dir.cwd(), p)) |t| {
            w.excludes_file = try zg_ignore.parseRules(w.a, t, .core_excludes_file);
        } else |_| {};
    }

    fn ignored(w: *const Walker, rel: []const u8, is_dir: bool) bool {
        var i = w.levels.items.len;
        while (i > 0) {
            i -= 1;
            const l = w.levels.items[i];
            const sub = if (l.base.len == 0) rel else rel[l.base.len + 1 ..];
            if (l.rules.match(sub, is_dir, w.casefold)) |h| return !h.rule.negate;
        }
        if (w.info_exclude.match(rel, is_dir, w.casefold)) |h| return !h.rule.negate;
        if (w.excludes_file.match(rel, is_dir, w.casefold)) |h| return !h.rule.negate;
        return false;
    }

    fn report(w: *Walker, path: []const u8, code: Code) !void {
        try w.out.append(w.a, .{ .path = path, .x = code, .y = code });
    }

    /// Walks directory `rel` (open as `dir`), reporting untracked and
    /// ignored entries. `depth` guards against loops.
    fn walk(w: *Walker, rel: []const u8, dir: Io.Dir, depth: u16) anyerror!void {
        if (depth > 256) return;
        const pushed = try w.pushLevel(rel, dir);
        defer if (pushed) {
            w.levels.items.len -= 1;
        };
        var it = dir.iterate();
        var names: std.ArrayList(struct { []const u8, Io.File.Kind }) = .empty;
        while (try it.next(w.repo.io)) |ent| {
            if (std.mem.eql(u8, ent.name, ".git")) continue;
            try names.append(w.a, .{ try w.a.dupe(u8, ent.name), ent.kind });
        }
        for (names.items) |n| {
            const path = if (rel.len == 0) n[0] else try std.mem.concat(w.a, u8, &.{ rel, "/", n[0] });
            var kind = n[1];
            if (kind == .unknown) kind = (dir.statFile(w.repo.io, n[0], .{ .follow_symlinks = false }) catch continue).kind;
            const is_dir = kind == .directory;
            const r = w.ix.range(path);
            if (r[1] > r[0]) continue; // tracked (a file or a submodule)
            if (is_dir and w.ix.hasUnder(path)) {
                var sub = dir.openDir(w.repo.io, n[0], .{ .iterate = true }) catch continue;
                defer sub.close(w.repo.io);
                try w.walk(path, sub, depth + 1);
                continue;
            }
            if (w.ignored(path, is_dir)) {
                if (w.opts.ignored) try w.report(if (is_dir) try std.mem.concat(w.a, u8, &.{ path, "/" }) else path, .ignored);
                continue;
            }
            if (w.opts.untracked == .no) continue;
            if (!is_dir) {
                if (kind == .file or kind == .sym_link) try w.report(path, .untracked);
                continue;
            }
            var sub = dir.openDir(w.repo.io, n[0], .{ .iterate = true }) catch continue;
            defer sub.close(w.repo.io);
            // A nested repository shows as one untracked directory.
            const nested = if (sub.access(w.repo.io, ".git", .{})) |_| true else |_| false;
            if (w.opts.untracked == .all and !nested) {
                try w.walk(path, sub, depth + 1);
            } else if (nested or try w.hasVisible(path, sub, depth + 1)) {
                try w.report(try std.mem.concat(w.a, u8, &.{ path, "/" }), .untracked);
            }
        }
    }

    /// Whether an untracked directory holds any file that is not ignored.
    fn hasVisible(w: *Walker, rel: []const u8, dir: Io.Dir, depth: u16) anyerror!bool {
        if (depth > 256) return false;
        const pushed = try w.pushLevel(rel, dir);
        defer if (pushed) {
            w.levels.items.len -= 1;
        };
        var it = dir.iterate();
        while (try it.next(w.repo.io)) |ent| {
            if (std.mem.eql(u8, ent.name, ".git")) continue;
            const path = try std.mem.concat(w.a, u8, &.{ rel, "/", ent.name });
            var kind = ent.kind;
            if (kind == .unknown) kind = (dir.statFile(w.repo.io, ent.name, .{ .follow_symlinks = false }) catch continue).kind;
            const is_dir = kind == .directory;
            if (w.ignored(path, is_dir)) continue;
            if (!is_dir) {
                if (kind == .file or kind == .sym_link) return true;
                continue;
            }
            var sub = dir.openDir(w.repo.io, ent.name, .{ .iterate = true }) catch continue;
            defer sub.close(w.repo.io);
            if (sub.access(w.repo.io, ".git", .{})) |_| return true else |_| {}
            if (try w.hasVisible(path, sub, depth + 1)) return true;
        }
        return false;
    }

    fn pushLevel(w: *Walker, rel: []const u8, dir: Io.Dir) !bool {
        const text = readSmall(w.a, w.repo.io, dir, ".gitignore") catch return false;
        const rules = try zg_ignore.parseRules(w.a, text, .gitignore);
        try w.levels.append(w.a, .{ .base = rel, .rules = rules });
        return true;
    }
};

fn readSmall(a: Allocator, io: Io, dir: Io.Dir, sub: []const u8) ![]u8 {
    return dir.readFileAlloc(io, sub, a, .limited(16 << 20));
}

fn expandHome(a: Allocator, p: []const u8, home: ?[]const u8) ![]const u8 {
    if (std.mem.startsWith(u8, p, "~/")) if (home) |h| return std.fs.path.join(a, &.{ h, p[2..] });
    return p;
}
