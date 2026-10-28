//! An open git repository (E09.F07): its working tree, `$GIT_DIR` and
//! common dir, object format, ref store, object database and config,
//! the handle the index, status and staging operations take.

const std = @import("std");
const oid_mod = @import("oid.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const worktree = @import("worktree.zig");
const config_mod = @import("config.zig");
const index_mod = @import("index/index.zig");
const Odb = @import("odb.zig").Odb;
const refs = @import("refs/refs.zig");
const RefStore = refs.RefStore;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Config = config_mod.Config;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const OpenOptions = struct {
    /// Environment: HOME, XDG_CONFIG_HOME, GIT_CONFIG_* and
    /// GIT_CEILING_DIRECTORIES.
    env: ?*const std.process.Environ.Map = null,
    /// The system gitconfig; null probes git's usual location.
    system_config: ?[]const u8 = null,
    /// `-c key=value` overrides.
    overrides: []const []const u8 = &.{},
};

pub const Repository = struct {
    gpa: Allocator,
    io: Io,
    /// Absolute paths: the working tree's top, `$GIT_DIR`, the common dir.
    root: []u8,
    git_dir_path: []u8,
    common_dir_path: []u8,
    work: Io.Dir,
    git_dir: Io.Dir,
    objects: Io.Dir,
    format: ObjectFormat,
    refs: RefStore,
    odb: *Odb,
    config: Config,
    /// The user's home directory (from the environment), owned.
    home: ?[]u8 = null,
    /// The environment it was opened with (borrowed).
    env: ?*const std.process.Environ.Map = null,

    /// Opens the repository whose working tree holds `abs_path`; null
    /// when there is none (stopping at `GIT_CEILING_DIRECTORIES`).
    pub fn discover(gpa: Allocator, io: Io, abs_path: []const u8, opts: OpenOptions) !?*Repository {
        var d = (try worktree.discover(gpa, io, abs_path)) orelse return null;
        defer d.deinit(gpa);
        // Discovery never walks up into a ceiling directory: a repository
        // at or above a ceiling that `abs_path` lies below stays hidden.
        if (opts.env) |env| if (env.get("GIT_CEILING_DIRECTORIES")) |ceil| {
            var it = std.mem.tokenizeScalar(u8, ceil, std.fs.path.delimiter);
            while (it.next()) |c| {
                const cd = std.mem.trimEnd(u8, c, "/\\");
                if (cd.len == 0) continue;
                if (below(abs_path, cd) and (std.mem.eql(u8, cd, d.root) or below(cd, d.root))) return null;
            }
        };
        return try open(gpa, io, d.root, d.git_dir, opts);
    }

    /// Opens a repository from its working tree top and `$GIT_DIR`.
    pub fn open(gpa: Allocator, io: Io, root: []const u8, git_dir_path: []const u8, opts: OpenOptions) !*Repository {
        const r = try gpa.create(Repository);
        errdefer gpa.destroy(r);
        const root_dup = try gpa.dupe(u8, root);
        errdefer gpa.free(root_dup);
        const gd_dup = try gpa.dupe(u8, git_dir_path);
        errdefer gpa.free(gd_dup);
        var work = try Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
        errdefer work.close(io);
        var git_dir = try Io.Dir.openDirAbsolute(io, git_dir_path, .{ .iterate = true });
        errdefer git_dir.close(io);
        const common_path = try commonDirPath(gpa, io, git_dir, git_dir_path);
        errdefer gpa.free(common_path);
        var rs = try RefStore.open(gpa, io, git_dir, .sha1, .{});
        errdefer rs.close();

        const home = try homeDir(gpa, opts.env);
        errdefer if (home) |h| gpa.free(h);
        const sys = opts.system_config orelse systemConfigPath();
        var cfg = try loadConfig(gpa, io, gd_dup, common_path, home, opts, sys, &rs);
        errdefer cfg.deinit();
        const fmt: ObjectFormat = if (cfg.get("extensions.objectformat")) |f| ObjectFormat.fromName(f) orelse return error.UnsupportedObjectFormat else .sha1;
        rs.format = fmt;
        var objects = try rs.common_dir.openDir(io, "objects", .{ .iterate = true });
        errdefer objects.close(io);
        const odb = try Odb.open(gpa, io, objects, fmt, .{});
        r.* = .{
            .gpa = gpa,
            .io = io,
            .root = root_dup,
            .git_dir_path = gd_dup,
            .common_dir_path = common_path,
            .work = work,
            .git_dir = git_dir,
            .objects = objects,
            .format = fmt,
            .refs = rs,
            .odb = odb,
            .config = cfg,
            .home = home,
            .env = opts.env,
        };
        // RefStore keeps a copy of the borrowed dir handle.
        r.refs.git_dir = r.git_dir;
        if (!r.refs.owns_common) r.refs.common_dir = r.git_dir;
        return r;
    }

    pub fn close(r: *Repository) void {
        const gpa = r.gpa;
        r.odb.close();
        r.objects.close(r.io);
        r.refs.close();
        r.config.deinit();
        r.git_dir.close(r.io);
        r.work.close(r.io);
        gpa.free(r.root);
        gpa.free(r.git_dir_path);
        gpa.free(r.common_dir_path);
        if (r.home) |h| gpa.free(h);
        gpa.destroy(r);
    }

    pub fn envMap(r: *const Repository) ?*const std.process.Environ.Map {
        return r.env;
    }

    /// Reads the config again (after `git config` edits).
    pub fn reloadConfig(r: *Repository, opts: OpenOptions) !void {
        const next = try loadConfig(r.gpa, r.io, r.git_dir_path, r.common_dir_path, r.home, opts, opts.system_config orelse systemConfigPath(), &r.refs);
        r.config.deinit();
        r.config = next;
    }

    /// The commit HEAD points at; null when the branch is unborn.
    pub fn head(r: *Repository) !?Oid {
        return r.refs.resolve("HEAD");
    }

    /// The branch HEAD names (`refs/heads/x`), owned; null when detached.
    pub fn headRef(r: *Repository, gpa: Allocator) !?[]const u8 {
        const v = (try r.refs.read(gpa, "HEAD")) orelse return null;
        return switch (v) {
            .symbolic => |s| s,
            .direct => null,
        };
    }

    /// The root tree of `commit`.
    pub fn treeOf(r: *Repository, commit: Oid) !Oid {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const obj = try r.odb.read(arena.allocator(), commit);
        if (obj.type != .commit) return error.NotACommit;
        const c = try commit_mod.parseCommit(arena.allocator(), r.format, obj.data);
        return c.tree;
    }

    /// The index (empty when there is none).
    pub fn readIndex(r: *Repository) !index_mod.Index {
        return index_mod.Index.read(r.gpa, r.io, r.git_dir, r.format);
    }

    pub fn writeIndex(r: *Repository, ix: *const index_mod.Index) !void {
        try ix.write(r.gpa, r.io, r.git_dir);
    }

    /// Whether `core.ignoreCase` is set.
    pub fn ignoreCase(r: *const Repository) bool {
        return r.config.getBool("core.ignorecase") orelse false;
    }
};

/// Whether `path` lies strictly inside directory `dir`.
fn below(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and std.fs.path.isSep(path[dir.len]);
}

fn commonDirPath(gpa: Allocator, io: Io, git_dir: Io.Dir, git_dir_path: []const u8) ![]u8 {
    const text = git_dir.readFileAlloc(io, "commondir", gpa, .limited(4096)) catch |e| switch (e) {
        error.FileNotFound => return gpa.dupe(u8, git_dir_path),
        else => return e,
    };
    defer gpa.free(text);
    const p = std.mem.trim(u8, text, " \r\n");
    if (std.fs.path.isAbsolute(p)) return gpa.dupe(u8, p);
    return std.fs.path.resolve(gpa, &.{ git_dir_path, p });
}

fn homeDir(gpa: Allocator, env: ?*const std.process.Environ.Map) !?[]u8 {
    const e = env orelse return null;
    const h = e.get("HOME") orelse e.get("USERPROFILE") orelse return null;
    return try gpa.dupe(u8, h);
}

/// Where git keeps the system gitconfig on this platform.
fn systemConfigPath() ?[]const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "C:\\Program Files\\Git\\etc\\gitconfig",
        .macos => "/usr/local/etc/gitconfig",
        else => "/etc/gitconfig",
    };
}

fn loadConfig(gpa: Allocator, io: Io, git_dir: []const u8, common: []const u8, home: ?[]const u8, opts: OpenOptions, sys: ?[]const u8, rs: *RefStore) !Config {
    var branch_buf: ?[]const u8 = null;
    defer if (branch_buf) |b| gpa.free(b);
    if (rs.read(gpa, "HEAD") catch null) |v| switch (v) {
        .symbolic => |s| branch_buf = s,
        .direct => {},
    };
    const branch: ?[]const u8 = if (branch_buf) |b| (if (std.mem.startsWith(u8, b, "refs/heads/")) b["refs/heads/".len..] else b) else null;
    return Config.load(gpa, io, .{
        .git_dir = git_dir,
        .common_dir = common,
        .home = home,
        .xdg_config_home = if (opts.env) |e| e.get("XDG_CONFIG_HOME") else null,
        .env = opts.env,
        .system_file = sys,
        .branch = branch,
        .overrides = opts.overrides,
    });
}

test "repository: open, HEAD and config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "r/.git/objects");
    try tmp.dir.createDirPath(io, "r/.git/refs/heads");
    try tmp.dir.createDirPath(io, "r/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "r/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "r/.git/config", .data = "[core]\n\tignorecase = true\n" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const sub = try std.fs.path.join(gpa, &.{ base, "r", "sub" });
    defer gpa.free(sub);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("HOME", base);
    const r = (try Repository.discover(gpa, io, sub, .{ .env = &env })).?;
    defer r.close();
    try std.testing.expect(std.mem.endsWith(u8, r.root, "r"));
    try std.testing.expect(r.ignoreCase());
    try std.testing.expect((try r.head()) == null);
    const hr = (try r.headRef(gpa)).?;
    defer gpa.free(hr);
    try std.testing.expectEqualStrings("refs/heads/main", hr);
    // A ceiling inside the tree hides the repository from below it.
    try env.put("GIT_CEILING_DIRECTORIES", sub);
    const deeper = try std.fs.path.join(gpa, &.{ sub, "x" });
    defer gpa.free(deeper);
    try tmp.dir.createDirPath(io, "r/sub/x");
    try std.testing.expect((try Repository.discover(gpa, io, deeper, .{ .env = &env })) == null);
}
