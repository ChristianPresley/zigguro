//! Finding a file's committed version (E09 IDE integration): discovers the
//! git repository around a path, including linked worktrees (`.git` is a
//! file naming the worktree's git dir, whose `commondir` holds objects and
//! shared refs), and reads a path's blob at `HEAD`. Editors use it as the
//! base of the gutter's change bars.

const std = @import("std");
const oid_mod = @import("oid.zig");
const object = @import("object.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const Odb = @import("odb.zig").Odb;
const RefStore = @import("refs/refs.zig").RefStore;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A repository found around a path. Paths are absolute.
pub const Discovered = struct {
    /// The working tree's top directory.
    root: []u8,
    /// This worktree's `$GIT_DIR`.
    git_dir: []u8,

    pub fn deinit(d: *Discovered, gpa: Allocator) void {
        gpa.free(d.root);
        gpa.free(d.git_dir);
    }

    /// `abs` relative to `root` with '/' separators, or null when `abs`
    /// is outside the working tree.
    pub fn relative(d: *const Discovered, gpa: Allocator, abs: []const u8) !?[]u8 {
        if (!std.mem.startsWith(u8, abs, d.root)) return null;
        var rest = abs[d.root.len..];
        if (rest.len > 0 and !std.fs.path.isSep(rest[0]) and !std.fs.path.isSep(d.root[d.root.len - 1])) return null;
        while (rest.len > 0 and std.fs.path.isSep(rest[0])) rest = rest[1..];
        if (rest.len == 0) return null;
        const out = try gpa.dupe(u8, rest);
        for (out) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        return out;
    }
};

/// The repository whose working tree holds `abs_path` (a file or a
/// directory), walking up to the filesystem root; null when there is none.
pub fn discover(gpa: Allocator, io: Io, abs_path: []const u8) !?Discovered {
    var dir_path: []const u8 = abs_path;
    while (true) {
        if (try gitDirAt(gpa, io, dir_path)) |git_dir| {
            return .{ .root = try gpa.dupe(u8, dir_path), .git_dir = git_dir };
        }
        dir_path = std.fs.path.dirname(dir_path) orelse return null;
    }
}

/// `<dir>/.git` as a git dir: the directory itself, or the target of a
/// `gitdir:` file.
fn gitDirAt(gpa: Allocator, io: Io, dir: []const u8) !?[]u8 {
    const dot = try std.fs.path.join(gpa, &.{ dir, ".git" });
    defer gpa.free(dot);
    if (Io.Dir.openDirAbsolute(io, dot, .{})) |d_| {
        var d = d_;
        defer d.close(io);
        if (d.access(io, "HEAD", .{})) |_| return try gpa.dupe(u8, dot) else |_| return null;
    } else |e| switch (e) {
        error.FileNotFound => return null,
        error.NotDir => {},
        else => return null,
    }
    var buf: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, dot, &buf) catch return null;
    const line = std.mem.trim(u8, text, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const target = std.mem.trim(u8, line[prefix.len..], " \t");
    if (std.fs.path.isAbsolute(target)) return try gpa.dupe(u8, target);
    return try std.fs.path.resolve(gpa, &.{ dir, target });
}

/// The object format from `config` (`extensions.objectformat`).
fn formatOf(io: Io, common: Io.Dir) ObjectFormat {
    var buf: [16 << 10]u8 = undefined;
    const text = common.readFile(io, "config", &buf) catch return .sha1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..eq], " \t"), "objectformat")) continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[eq + 1 ..], " \t"), "sha256")) return .sha256;
    }
    return .sha1;
}

/// The contents of `rel` (a '/'-separated path in the working tree) at
/// `HEAD`, owned by the caller; null when HEAD is unborn or has no file
/// there.
pub fn readHeadFile(gpa: Allocator, io: Io, d: *const Discovered, rel: []const u8) !?[]u8 {
    var git_dir = try Io.Dir.openDirAbsolute(io, d.git_dir, .{});
    defer git_dir.close(io);
    // RefStore finds the common dir; the object format lives there.
    var rs = try RefStore.open(gpa, io, git_dir, .sha1, .{});
    defer rs.close();
    const fmt = formatOf(io, rs.common_dir);
    rs.format = fmt;
    const head = (try rs.resolve("HEAD")) orelse return null;

    var objects = try rs.common_dir.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);
    const odb = try Odb.open(gpa, io, objects, fmt, .{});
    defer odb.close();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var obj = try odb.read(arena, head);
    if (obj.type != .commit) return error.CorruptObject;
    const c = try commit_mod.parseCommit(arena, fmt, obj.data);
    var cur = c.tree;
    var parts = std.mem.tokenizeScalar(u8, rel, '/');
    while (parts.next()) |name| {
        obj = try odb.read(arena, cur);
        if (obj.type != .tree) return null;
        var it = tree_mod.parseTree(fmt, obj.data);
        const last = parts.peek() == null;
        cur = while (try it.next()) |e| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            if (last and (e.isTree() or e.mode == tree_mod.mode_gitlink)) return null;
            if (!last and !e.isTree()) return null;
            break e.oid;
        } else return null;
    }
    var blob = try odb.read(gpa, cur);
    if (blob.type != .blob) {
        blob.deinit(gpa);
        return null;
    }
    return blob.data;
}

const testing = std.testing;

fn writeObject(odb: *Odb, t: object.ObjectType, data: []const u8) !oid_mod.Oid {
    return odb.writeLoose(t, data);
}

test "worktree: discover and read HEAD files, linked worktrees too" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);

    // main/.git with one commit: README and src/lib.zig.
    try tmp.dir.createDirPath(io, "main/.git/objects");
    try tmp.dir.createDirPath(io, "main/.git/refs/heads");
    try tmp.dir.createDirPath(io, "main/src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.git/HEAD", .data = "ref: refs/heads/main\n" });
    var objects = try tmp.dir.openDir(io, "main/.git/objects", .{ .iterate = true });
    defer objects.close(io);
    const odb = try Odb.open(gpa, io, objects, .sha1, .{});
    defer odb.close();
    const readme = try writeObject(odb, .blob, "hello\n");
    const lib = try writeObject(odb, .blob, "pub fn f() void {}\n");
    var w: Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try tree_mod.serializeTree(&.{.{ .mode = tree_mod.mode_file, .name = "lib.zig", .oid = lib }}, &w.writer);
    const src = try writeObject(odb, .tree, w.written());
    w.clearRetainingCapacity();
    try tree_mod.serializeTree(&.{
        .{ .mode = tree_mod.mode_file, .name = "README", .oid = readme },
        .{ .mode = tree_mod.mode_tree, .name = "src", .oid = src },
    }, &w.writer);
    const root_tree = try writeObject(odb, .tree, w.written());
    w.clearRetainingCapacity();
    const who: commit_mod.Ident = .{ .name = "t", .email = "t@example.com", .time = 1, .tz = "+0000" };
    const c: commit_mod.Commit = .{ .tree = root_tree, .parents = &.{}, .author = who, .committer = who, .message = "init\n" };
    try commit_mod.serializeCommit(&c, &w.writer);
    const head = try writeObject(odb, .commit, w.written());
    var hex: [64]u8 = undefined;
    const ref_text = try std.fmt.allocPrint(gpa, "{s}\n", .{head.hex(&hex)});
    defer gpa.free(ref_text);
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.git/refs/heads/main", .data = ref_text });

    const deep = try std.fs.path.join(gpa, &.{ base, "main", "src", "deep" });
    defer gpa.free(deep);
    var d = (try discover(gpa, io, deep)).?;
    defer d.deinit(gpa);
    const file = try std.fs.path.join(gpa, &.{ base, "main", "src", "lib.zig" });
    defer gpa.free(file);
    const rel = (try d.relative(gpa, file)).?;
    defer gpa.free(rel);
    try testing.expectEqualStrings("src/lib.zig", rel);
    const got = (try readHeadFile(gpa, io, &d, rel)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("pub fn f() void {}\n", got);
    try testing.expectEqual(@as(?[]u8, null), try readHeadFile(gpa, io, &d, "src/missing.zig"));
    try testing.expectEqual(@as(?[]u8, null), try readHeadFile(gpa, io, &d, "src"));
    try testing.expectEqual(@as(?[]u8, null), try readHeadFile(gpa, io, &d, "README/x"));

    // A linked worktree: .git is a file; HEAD is per worktree.
    try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/wt/HEAD", .data = ref_text });
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/wt/commondir", .data = "../..\n" });
    try tmp.dir.createDirPath(io, "wt");
    const wt_git = try std.fmt.allocPrint(gpa, "gitdir: {s}/main/.git/worktrees/wt\n", .{base});
    defer gpa.free(wt_git);
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = wt_git });
    const wt_file = try std.fs.path.join(gpa, &.{ base, "wt", "README" });
    defer gpa.free(wt_file);
    var d2 = (try discover(gpa, io, wt_file)).?;
    defer d2.deinit(gpa);
    try testing.expect(std.mem.endsWith(u8, d2.root, "wt"));
    const got2 = (try readHeadFile(gpa, io, &d2, "README")).?;
    defer gpa.free(got2);
    try testing.expectEqualStrings("hello\n", got2);

    // Outside any repository.
    try testing.expectEqual(@as(?[]u8, null), try d.relative(gpa, wt_file));
}
