//! Staging (E09.F07.S03.T01): `git add` (paths, `-A`, `-u`), partial
//! (hunk or line) staging through `stageBlob`, `git add -N`, unstaging
//! (`git restore --staged`), and `git rm` / `git rm --cached`.
//!
//! Each call reads the index, changes it and writes it back under
//! `index.lock`. Content is cleaned the way `git add` cleans it
//! (`core.autocrlf` true or input turns CRLF into LF in text files).
//! Partial content comes from the caller (zg_scm's selection applier);
//! zg_git never imports zg_scm.

const std = @import("std");
const object = @import("object.zig");
const tree_mod = @import("tree.zig");
const index_mod = @import("index/index.zig");
const status_mod = @import("status.zig");
const config_mod = @import("config.zig");
const Repository = @import("repository.zig").Repository;
const Oid = @import("oid.zig").Oid;
const Index = index_mod.Index;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const AddOptions = struct {
    /// `-u`: only tracked files (no new files).
    update_only: bool = false,
};

/// `git add <paths>` (an empty list or "." means everything, as
/// `git add -A`). Ignored untracked files are skipped. Returns how many
/// paths changed in the index.
pub fn add(repo: *Repository, paths: []const []const u8, opts: AddOptions) !usize {
    var ix = try repo.readIndex();
    defer ix.deinit();
    const n = try addInto(repo, &ix, paths, opts);
    if (n > 0) try repo.writeIndex(&ix);
    return n;
}

/// `add` on an index the caller writes.
pub fn addInto(repo: *Repository, ix: *Index, paths: []const []const u8, opts: AddOptions) !usize {
    const spec = try normalizeSpec(repo.gpa, paths);
    defer repo.gpa.free(spec);
    var st = try status_mod.status(repo, .{ .untracked = if (opts.update_only) .no else .all, .refresh = false, .pathspec = spec });
    defer st.deinit();
    var n: usize = 0;
    for (st.entries) |e| {
        if (e.y == .unmodified and !e.isConflict()) continue;
        if (e.isConflict()) {
            // Adding a conflicted path resolves it with the worktree file.
            if (try statOf(repo, e.path)) |s| {
                try addFile(repo, ix, e.path, s);
            } else _ = ix.remove(e.path);
        } else if (e.y == .deleted) {
            _ = ix.remove(e.path);
        } else if (try statOf(repo, e.path)) |s| {
            try addFile(repo, ix, e.path, s);
        } else continue;
        n += 1;
    }
    return n;
}

fn normalizeSpec(gpa: Allocator, paths: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths) |p| {
        if (std.mem.eql(u8, p, ".") or p.len == 0) {
            out.clearRetainingCapacity();
            return out.toOwnedSlice(gpa);
        }
        try out.append(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

fn statOf(repo: *Repository, rel: []const u8) !?Io.File.Stat {
    return repo.work.statFile(repo.io, rel, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => null,
        else => e,
    };
}

/// The index mode for a worktree file.
fn modeFor(repo: *const Repository, ix: *const Index, rel: []const u8, st: Io.File.Stat) !u32 {
    const old: ?u32 = if (ix.find(rel, 0)) |i| ix.entries.items[i].mode else null;
    switch (st.kind) {
        .sym_link => return tree_mod.mode_symlink,
        .directory => return error.IsDir,
        .file => {},
        else => return error.UnsupportedFileType,
    }
    const filemode = repo.config.getBool("core.filemode") orelse true;
    if (comptime !Io.File.Permissions.has_executable_bit) return if (old == tree_mod.mode_exec) tree_mod.mode_exec else tree_mod.mode_file;
    if (!filemode) return if (old == tree_mod.mode_exec) tree_mod.mode_exec else tree_mod.mode_file;
    return if (st.permissions.toMode() & 0o100 != 0) tree_mod.mode_exec else tree_mod.mode_file;
}

/// Writes the blob for the worktree file `rel` and stages it.
fn addFile(repo: *Repository, ix: *Index, rel: []const u8, st: Io.File.Stat) !void {
    const mode = try modeFor(repo, ix, rel, st);
    const gpa = repo.gpa;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const data: []u8 = if (st.kind == .sym_link) blk: {
        const n = try repo.work.readLink(repo.io, rel, &link_buf);
        break :blk try gpa.dupe(u8, link_buf[0..n]);
    } else try repo.work.readFileAlloc(repo.io, rel, gpa, .unlimited);
    defer gpa.free(data);
    const clean = try cleanContent(repo, gpa, data, mode);
    defer if (clean.ptr != data.ptr) gpa.free(clean);
    const id = try repo.odb.writeLoose(.blob, clean);
    var e: index_mod.Entry = .{ .mode = mode, .oid = id, .path = rel };
    status_mod.setStat(&e, st);
    try ix.add(e);
}

/// What `git add` stores for `data`: CRLF to LF in text files when
/// `core.autocrlf` is true or input. Returns `data` itself when nothing
/// changes.
pub fn cleanContent(repo: *const Repository, gpa: Allocator, data: []u8, mode: u32) ![]u8 {
    if (mode == tree_mod.mode_symlink) return data;
    const v = repo.config.get("core.autocrlf") orelse return data;
    const on = std.ascii.eqlIgnoreCase(v, "input") or (config_mod.parseBool(v) orelse false);
    if (!on or !status_mod.isText(data) or std.mem.indexOf(u8, data, "\r\n") == null) return data;
    return status_mod.crlfToLf(gpa, data);
}

/// Stages `content` as `rel` (hunk or line staging: the caller builds
/// the partial content). `whole_file` copies the worktree's stat data,
/// otherwise the entry's stat data is zeroed so the next status hashes
/// the file. Returns the blob id.
pub fn stageBlob(repo: *Repository, rel: []const u8, content: []const u8, mode: u32, whole_file: bool) !Oid {
    var ix = try repo.readIndex();
    defer ix.deinit();
    const id = try repo.odb.writeLoose(.blob, content);
    var e: index_mod.Entry = .{ .mode = mode, .oid = id, .path = rel };
    if (whole_file) if (try statOf(repo, rel)) |st| status_mod.setStat(&e, st);
    try ix.add(e);
    try repo.writeIndex(&ix);
    return id;
}

/// `git add -N`: records that `rel` will be added (an empty blob entry
/// with intent-to-add).
pub fn intentToAdd(repo: *Repository, rel: []const u8) !void {
    var ix = try repo.readIndex();
    defer ix.deinit();
    if (ix.find(rel, 0) != null) return;
    const st = (try statOf(repo, rel)) orelse return error.FileNotFound;
    const id = object.hashObject(repo.format, .blob, "");
    _ = try repo.odb.writeLoose(.blob, "");
    try ix.add(.{ .mode = try modeFor(repo, &ix, rel, st), .oid = id, .path = rel, .flags = .{ .intent_to_add = true } });
    try repo.writeIndex(&ix);
}

/// `git restore --staged <paths>`: each path (a file or directory; none
/// means everything) goes back to its HEAD version in the index, or
/// leaves the index when HEAD does not have it. Returns how many entries
/// changed.
pub fn unstage(repo: *Repository, paths: []const []const u8) !usize {
    var ix = try repo.readIndex();
    defer ix.deinit();
    const n = try unstageInto(repo, &ix, paths);
    if (n > 0) try repo.writeIndex(&ix);
    return n;
}

pub fn unstageInto(repo: *Repository, ix: *Index, paths: []const []const u8) !usize {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try normalizeSpec(a, paths);
    const head: []const status_mod.TreeFile = if (try repo.head()) |h| try status_mod.flattenTree(repo, a, try repo.treeOf(h)) else &.{};
    var n: usize = 0;
    // Entries without a HEAD version leave; changed ones go back.
    var i: usize = 0;
    while (i < ix.entries.items.len) {
        const e = ix.entries.items[i];
        if (!matchesSpec(e.path, spec)) {
            i += 1;
            continue;
        }
        const hf = findTree(head, e.path);
        if (hf == null) {
            _ = ix.remove(e.path);
            n += 1;
            continue;
        }
        if (e.flags.stage != 0 or !hf.?.oid.eql(e.oid) or hf.?.mode != e.mode or e.flags.intent_to_add) {
            try ix.add(.{ .mode = hf.?.mode, .oid = hf.?.oid, .path = e.path });
            n += 1;
        }
        i = ix.range(e.path)[1];
    }
    // HEAD files missing from the index come back.
    for (head) |hf| {
        if (!matchesSpec(hf.path, spec)) continue;
        if (ix.range(hf.path)[1] > ix.range(hf.path)[0]) continue;
        try ix.add(.{ .mode = hf.mode, .oid = hf.oid, .path = hf.path });
        n += 1;
    }
    return n;
}

fn findTree(head: []const status_mod.TreeFile, path: []const u8) ?status_mod.TreeFile {
    var lo: usize = 0;
    var hi: usize = head.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, head[mid].path, path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return head[mid],
        }
    }
    return null;
}

fn matchesSpec(path: []const u8, spec: []const []const u8) bool {
    if (spec.len == 0) return true;
    for (spec) |s| {
        const t = std.mem.trimEnd(u8, s, "/");
        if (std.mem.eql(u8, path, t)) return true;
        if (path.len > t.len and std.mem.startsWith(u8, path, t) and path[t.len] == '/') return true;
    }
    return false;
}

pub const RemoveOptions = struct {
    /// `--cached`: keep the worktree files.
    cached: bool = false,
};

/// `git rm` (`-r` for directories): drops the paths from the index and,
/// unless `cached`, deletes the files. Returns how many entries went.
pub fn remove(repo: *Repository, paths: []const []const u8, opts: RemoveOptions) !usize {
    var ix = try repo.readIndex();
    defer ix.deinit();
    var gone: std.ArrayList([]const u8) = .empty;
    defer gone.deinit(repo.gpa);
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    for (ix.entries.items) |e| if (matchesSpec(e.path, paths)) {
        if (gone.items.len == 0 or !std.mem.eql(u8, gone.items[gone.items.len - 1], e.path)) try gone.append(repo.gpa, try arena.allocator().dupe(u8, e.path));
    };
    if (gone.items.len == 0) return error.PathspecDidNotMatch;
    for (gone.items) |p| {
        _ = ix.remove(p);
        if (!opts.cached) repo.work.deleteFile(repo.io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
    try repo.writeIndex(&ix);
    if (!opts.cached) for (gone.items) |p| removeEmptyParents(repo, p);
    return gone.items.len;
}

fn removeEmptyParents(repo: *Repository, rel: []const u8) void {
    var d = std.fs.path.dirnamePosix(rel);
    while (d) |dir| : (d = std.fs.path.dirnamePosix(dir)) {
        repo.work.deleteDir(repo.io, dir) catch return;
    }
}

const testing = std.testing;

/// A fresh repository in `tmp` with an isolated environment.
pub const TestRepo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    env: std.process.Environ.Map,
    repo: *Repository,

    pub fn init(gpa: Allocator, io: Io) !*TestRepo {
        const t = try gpa.create(TestRepo);
        errdefer gpa.destroy(t);
        t.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer t.tmp.cleanup();
        try t.tmp.dir.createDirPath(io, ".git/objects");
        try t.tmp.dir.createDirPath(io, ".git/refs/heads");
        try t.tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
        try t.tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n" });
        t.root = try t.tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(t.root);
        t.env = .init(gpa);
        try t.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try t.env.put("HOME", t.root);
        try t.env.put("GIT_AUTHOR_NAME", "A U Thor");
        try t.env.put("GIT_AUTHOR_EMAIL", "author@example.com");
        try t.env.put("GIT_COMMITTER_NAME", "C O Mitter");
        try t.env.put("GIT_COMMITTER_EMAIL", "committer@example.com");
        const gd = try std.fs.path.join(gpa, &.{ t.root, ".git" });
        defer gpa.free(gd);
        t.repo = try Repository.open(gpa, io, t.root, gd, .{ .env = &t.env });
        return t;
    }

    pub fn deinit(t: *TestRepo, gpa: Allocator) void {
        t.repo.close();
        t.env.deinit();
        gpa.free(t.root);
        t.tmp.cleanup();
        gpa.destroy(t);
    }

    pub fn porcelain(t: *TestRepo, gpa: Allocator) ![]u8 {
        var st = try status_mod.status(t.repo, .{});
        defer st.deinit();
        return st.porcelain(gpa);
    }
};

test "stage: add, add -u, intent-to-add, unstage and rm" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try TestRepo.init(gpa, io);
    defer t.deinit(gpa);
    const d = t.tmp.dir;
    try d.createDirPath(io, "src");
    try d.writeFile(io, .{ .sub_path = "a.txt", .data = "a\n" });
    try d.writeFile(io, .{ .sub_path = "src/b.zig", .data = "b\n" });
    try d.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try d.writeFile(io, .{ .sub_path = "x.log", .data = "l\n" });
    try testing.expectEqual(@as(usize, 3), try add(t.repo, &.{}, .{}));
    var s = try t.porcelain(gpa);
    try testing.expectEqualStrings("A  .gitignore\nA  a.txt\nA  src/b.zig\n", s);
    gpa.free(s);

    // -u skips new files; a deleted tracked file is staged as gone.
    try d.writeFile(io, .{ .sub_path = "a.txt", .data = "a2\n" });
    try d.writeFile(io, .{ .sub_path = "new.txt", .data = "n\n" });
    try d.deleteFile(io, "src/b.zig");
    try testing.expectEqual(@as(usize, 2), try add(t.repo, &.{}, .{ .update_only = true }));
    s = try t.porcelain(gpa);
    try testing.expectEqualStrings("A  .gitignore\nA  a.txt\n?? new.txt\n", s);
    gpa.free(s);

    try intentToAdd(t.repo, "new.txt");
    s = try t.porcelain(gpa);
    try testing.expectEqualStrings("A  .gitignore\nA  a.txt\n A new.txt\n", s);
    gpa.free(s);

    // Without a HEAD, unstaging removes the entries.
    try testing.expectEqual(@as(usize, 1), try unstage(t.repo, &.{"a.txt"}));
    s = try t.porcelain(gpa);
    try testing.expectEqualStrings("A  .gitignore\n?? a.txt\n A new.txt\n", s);
    gpa.free(s);

    // Partial content.
    const id = try stageBlob(t.repo, "a.txt", "partial\n", tree_mod.mode_file, false);
    try testing.expect(id.eql(object.hashObject(.sha1, .blob, "partial\n")));
    s = try t.porcelain(gpa);
    try testing.expectEqualStrings("A  .gitignore\nAM a.txt\n A new.txt\n", s);
    gpa.free(s);

    try testing.expectEqual(@as(usize, 1), try remove(t.repo, &.{"a.txt"}, .{ .cached = true }));
    try testing.expect(try statOf(t.repo, "a.txt") != null);
    try testing.expectEqual(@as(usize, 1), try remove(t.repo, &.{".gitignore"}, .{}));
    try testing.expect(try statOf(t.repo, ".gitignore") == null);
    try testing.expectError(error.PathspecDidNotMatch, remove(t.repo, &.{"nope"}, .{}));
}

test "stage: autocrlf cleans CRLF in text files" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try TestRepo.init(gpa, io);
    defer t.deinit(gpa);
    try t.tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\n\tautocrlf = true\n" });
    try t.repo.reloadConfig(.{ .env = &t.env });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "w.txt", .data = "one\r\ntwo\r\n" });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "bin.dat", .data = "a\r\n\x00b" });
    _ = try add(t.repo, &.{}, .{});
    var ix = try t.repo.readIndex();
    defer ix.deinit();
    try testing.expect(ix.entries.items[ix.find("w.txt", 0).?].oid.eql(object.hashObject(.sha1, .blob, "one\ntwo\n")));
    try testing.expect(ix.entries.items[ix.find("bin.dat", 0).?].oid.eql(object.hashObject(.sha1, .blob, "a\r\n\x00b")));
    const s = try t.porcelain(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings("A  bin.dat\nA  w.txt\n", s);
}
