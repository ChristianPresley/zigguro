//! Three-way merges of git trees (E09.F09.S01.T01) and applying the
//! result to the index and worktree the way `git merge` leaves them.
//!
//! Per path: a side that kept the base's version takes the other side's;
//! both sides changing a regular text file merge line by line with
//! zg_scm's content merge, conflicts written with git's `merge` markers.
//! Everything else that changed on both sides (modify/delete, differing
//! modes, binary files, symlinks) is a conflict left in index stages 1,
//! 2 and 3. There is no rename detection: a rename is a delete plus an
//! add.

const std = @import("std");
const git = @import("zg_git");
const merge_mod = @import("../merge/merge.zig");
const content_merge = @import("../merge/content_merge.zig");
const materialize = @import("../merge/materialize.zig");
const Repository = git.Repository;
const Oid = git.oid.Oid;
const TreeFile = git.status.TreeFile;
const Index = git.index.Index;
const tree = git.tree;
const Allocator = std.mem.Allocator;

pub const Side = struct { mode: u32, oid: Oid };

pub const ConflictKind = enum {
    /// Both sides edited the same lines.
    content,
    /// Both sides added the path with different content.
    add_add,
    /// One side changed the file, the other deleted it.
    modify_delete,
    /// The content merged but the sides set different modes.
    mode,
    /// Content git does not merge by lines (binary, symlinks, submodules).
    binary,
};

pub const Conflict = struct {
    path: []const u8,
    kind: ConflictKind,
    base: ?Side,
    ours: ?Side,
    theirs: ?Side,
    /// The worktree text with markers; null keeps the side that has the
    /// file (ours when both do).
    text: ?[]const u8,
};

/// Marker labels: `<<<<<<< ours`, `>>>>>>> theirs`.
pub const Labels = struct {
    ours: []const u8 = "HEAD",
    base: []const u8 = "merged common ancestors",
    theirs: []const u8,
};

pub const Result = struct {
    /// Every path that merged, in index order.
    files: []const TreeFile,
    conflicts: []const Conflict,

    pub fn conflictPaths(r: Result, a: Allocator) ![]const []const u8 {
        const out = try a.alloc([]const u8, r.conflicts.len);
        for (r.conflicts, out) |c, *o| o.* = c.path;
        return out;
    }
};

fn sideMap(a: Allocator, files: []const TreeFile) !std.StringHashMapUnmanaged(Side) {
    var m: std.StringHashMapUnmanaged(Side) = .empty;
    try m.ensureTotalCapacity(a, @intCast(files.len));
    for (files) |f| m.putAssumeCapacity(f.path, .{ .mode = f.mode, .oid = f.oid });
    return m;
}

fn same(x: ?Side, y: ?Side) bool {
    if (x == null or y == null) return x == null and y == null;
    return x.?.mode == y.?.mode and x.?.oid.eql(y.?.oid);
}

fn isRegular(mode: u32) bool {
    return mode == tree.mode_file or mode == tree.mode_exec;
}

/// The merged mode, or null when the sides changed it differently.
fn mergeMode(b: ?Side, o: Side, t: Side) ?u32 {
    if (o.mode == t.mode) return o.mode;
    if (b) |base| {
        if (base.mode == o.mode) return t.mode;
        if (base.mode == t.mode) return o.mode;
    }
    return null;
}

/// Merges tree `theirs` into `ours` given their common `base` (null: no
/// common ancestor, every path is an add). Allocates in `a`; merged
/// blobs are written to the object store.
pub fn mergeTrees(repo: *Repository, a: Allocator, base: ?Oid, ours: Oid, theirs: Oid, labels: Labels) !Result {
    const bf: []const TreeFile = if (base) |b| try git.status.flattenTree(repo, a, b) else &.{};
    const of = try git.status.flattenTree(repo, a, ours);
    const tf = try git.status.flattenTree(repo, a, theirs);
    var bm = try sideMap(a, bf);
    var om = try sideMap(a, of);
    var tm = try sideMap(a, tf);

    var all: std.StringArrayHashMapUnmanaged(void) = .empty;
    for ([_][]const TreeFile{ bf, of, tf }) |list| for (list) |f| try all.put(a, f.path, {});
    const paths = try a.dupe([]const u8, all.keys());
    std.mem.sortUnstable([]const u8, paths, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var files: std.ArrayList(TreeFile) = .empty;
    var conflicts: std.ArrayList(Conflict) = .empty;
    for (paths) |p| {
        const b = bm.get(p);
        const o = om.get(p);
        const t = tm.get(p);
        const keep: ?Side = if (same(o, t)) o else if (same(b, o)) t else if (same(b, t)) o else {
            if (try mergeBoth(repo, a, p, b, o, t, labels)) |c| {
                switch (c) {
                    .file => |f| try files.append(a, f),
                    .conflict => |x| try conflicts.append(a, x),
                }
            }
            continue;
        };
        if (keep) |k| try files.append(a, .{ .path = p, .mode = k.mode, .oid = k.oid });
    }
    try checkDirectoryFile(a, files.items, conflicts.items);
    return .{ .files = files.items, .conflicts = conflicts.items };
}

const Merged = union(enum) { file: TreeFile, conflict: Conflict };

fn mergeBoth(repo: *Repository, a: Allocator, p: []const u8, b: ?Side, o: ?Side, t: ?Side, labels: Labels) !?Merged {
    const ours = o orelse return .{ .conflict = .{ .path = p, .kind = .modify_delete, .base = b, .ours = o, .theirs = t, .text = null } };
    const theirs = t orelse return .{ .conflict = .{ .path = p, .kind = .modify_delete, .base = b, .ours = o, .theirs = t, .text = null } };
    const add_add = b == null;
    const mode = mergeMode(b, ours, theirs);
    const textual = isRegular(ours.mode) and isRegular(theirs.mode) and (b == null or isRegular(b.?.mode));
    if (!textual) return .{ .conflict = .{ .path = p, .kind = .binary, .base = b, .ours = o, .theirs = t, .text = null } };
    if (ours.oid.eql(theirs.oid)) {
        // Only the modes disagree.
        return .{ .conflict = .{ .path = p, .kind = .mode, .base = b, .ours = o, .theirs = t, .text = null } };
    }
    const ob = (try repo.odb.read(a, ours.oid)).data;
    const tb = (try repo.odb.read(a, theirs.oid)).data;
    const bb: []const u8 = if (b) |x| (try repo.odb.read(a, x.oid)).data else "";
    if (content_merge.isBinary(ob) or content_merge.isBinary(tb) or content_merge.isBinary(bb)) {
        return .{ .conflict = .{ .path = p, .kind = .binary, .base = b, .ours = o, .theirs = t, .text = null } };
    }
    const terms = [_][]const u8{ ob, bb, tb };
    const r = try content_merge.mergeContent(a, .{ .values = &terms }, .{});
    if (r.clean) |text| {
        const id = try repo.odb.writeLoose(.blob, text);
        if (mode) |m| return .{ .file = .{ .path = p, .mode = m, .oid = id } };
        return .{ .conflict = .{ .path = p, .kind = .mode, .base = b, .ours = o, .theirs = t, .text = text } };
    }
    var aw: std.Io.Writer.Allocating = .init(a);
    const file_terms = [_]?[]const u8{ ob, bb, tb };
    try materialize.materialize(a, .{ .values = &file_terms }, r.hunks, .{
        .style = .merge,
        .labels = &.{ labels.ours, labels.base, labels.theirs },
    }, &aw.writer);
    return .{ .conflict = .{ .path = p, .kind = if (add_add) .add_add else .content, .base = b, .ours = o, .theirs = t, .text = aw.written() } };
}

/// A file in the result where the other side has a directory is not
/// handled (git renames one of them aside).
fn checkDirectoryFile(a: Allocator, files: []const TreeFile, conflicts: []const Conflict) !void {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    for (files) |f| try set.put(a, f.path, {});
    for (conflicts) |c| try set.put(a, c.path, {});
    var it = set.keyIterator();
    while (it.next()) |k| {
        var d = std.fs.path.dirnamePosix(k.*);
        while (d) |dir| : (d = std.fs.path.dirnamePosix(dir)) {
            if (set.contains(dir)) return error.DirectoryFileConflict;
        }
    }
}

/// Where the result differs from `ours`.
fn touched(om: *const std.StringHashMapUnmanaged(Side), rm: *const std.StringHashMapUnmanaged(Side), conflicted: *const std.StringHashMapUnmanaged(void), p: []const u8) bool {
    if (conflicted.contains(p)) return true;
    return !same(om.get(p), rm.get(p));
}

/// Local state that applying `r` over `ours` would lose: staged changes
/// (anywhere when `clean_index`, else on touched paths), worktree edits
/// to touched paths, and untracked files where the result puts a file.
pub fn blockers(repo: *Repository, a: Allocator, ours: []const TreeFile, r: Result, clean_index: bool) ![]const []const u8 {
    var om = try sideMap(a, ours);
    var rm = try sideMap(a, r.files);
    var cm: std.StringHashMapUnmanaged(void) = .empty;
    for (r.conflicts) |c| try cm.put(a, c.path, {});
    var st = try git.status.status(repo, .{ .untracked = .all, .refresh = false });
    defer st.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    for (st.entries) |e| {
        const hit = touched(&om, &rm, &cm, e.path);
        const block = switch (e.x) {
            .untracked => hit and (rm.contains(e.path) or cm.contains(e.path)),
            .ignored => false,
            else => (e.x != .unmodified and (clean_index or hit)) or (e.y != .unmodified and hit),
        };
        if (block) try out.append(a, try a.dupe(u8, e.path));
    }
    return out.items;
}

/// Writes `r` into the index `ix` and the worktree, which hold `ours`
/// (as `blockers` checked): changed files are written, removed ones
/// deleted, conflicts staged as 1/2/3 with their marker text written.
pub fn apply(repo: *Repository, a: Allocator, ix: *Index, ours: []const TreeFile, r: Result) !void {
    var om = try sideMap(a, ours);
    var rm = try sideMap(a, r.files);
    var cm: std.StringHashMapUnmanaged(void) = .empty;
    for (r.conflicts) |c| try cm.put(a, c.path, {});
    for (ours) |f| {
        if (rm.contains(f.path) or cm.contains(f.path)) continue;
        _ = ix.remove(f.path);
        git.checkout.removeWorktreeFile(repo, f.path);
    }
    for (r.files) |f| {
        if (same(om.get(f.path), .{ .mode = f.mode, .oid = f.oid }) and ix.find(f.path, 0) != null) continue;
        try git.checkout.writeEntry(repo, ix, f.path, f.mode, f.oid);
    }
    for (r.conflicts) |c| {
        _ = ix.remove(c.path);
        inline for (.{ .{ c.base, 1 }, .{ c.ours, 2 }, .{ c.theirs, 3 } }) |s| {
            if (s[0]) |side| try ix.addStage(.{ .mode = side.mode, .oid = side.oid, .path = c.path }, s[1]);
        }
        if (c.text) |text| {
            const mode = (c.ours orelse c.theirs.?).mode;
            try git.checkout.writeContent(repo, c.path, mode, text);
        } else if (c.ours == null) {
            try git.checkout.writeFile(repo, c.path, c.theirs.?.mode, c.theirs.?.oid);
        }
    }
}
