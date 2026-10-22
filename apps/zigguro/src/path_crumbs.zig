//! `PathCrumbs`: the editor's breadcrumbs for a file path: the workspace
//! folder, each folder below it and the file. Each segment's dropdown
//! lists the files of its folder (the file's own segment: its siblings),
//! and picking one runs `file.open` with the file's absolute path.
//!
//! A file outside the workspace shows its absolute folders from the root.

const std = @import("std");
const zg_gui = @import("zg_gui");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Crumb = zg_gui.w.Crumb;
const MenuItem = zg_gui.w.MenuItem;

/// The action the dropdown entries run (arg: the absolute path).
pub const open_action = "file.open";
/// The most segments kept (deeper paths keep their last ones).
pub const max_segments = 32;
/// The most files a dropdown lists.
pub const max_entries = 500;

/// See the module doc. Must not move after `set` (the crumbs point into it).
pub const PathCrumbs = struct {
    gpa: Allocator,
    io: Io,
    /// The current path (owned).
    path: []u8 = &.{},
    crumbs: [max_segments]Crumb = undefined,
    folders: [max_segments]Folder = undefined,
    len: usize = 0,

    const Folder = struct { pc: *PathCrumbs, dir: []const u8 };

    /// No segments yet.
    pub fn init(gpa: Allocator, io: Io) PathCrumbs {
        return .{ .gpa = gpa, .io = io };
    }

    /// Frees the path.
    pub fn deinit(pc: *PathCrumbs) void {
        pc.gpa.free(pc.path);
        pc.* = undefined;
    }

    /// The segments to show.
    pub fn items(pc: *const PathCrumbs) []const Crumb {
        return pc.crumbs[0..pc.len];
    }

    /// Shows `abs` (absolute) relative to the workspace folder `root`.
    pub fn set(pc: *PathCrumbs, root: []const u8, abs: []const u8) !void {
        const path = try pc.gpa.dupe(u8, abs);
        pc.gpa.free(pc.path);
        pc.path = path;
        pc.len = 0;
        const sep = std.fs.path.sep;
        const inside = root.len > 0 and std.mem.startsWith(u8, path, root) and path.len > root.len and std.fs.path.isSep(path[root.len]);
        // `start`: where the segments below the first one begin.
        var start: usize = 0;
        if (inside) {
            pc.add(std.fs.path.basename(root), path[0..root.len]);
            start = root.len + 1;
        } else {
            const r = std.fs.path.diskDesignator(path).len;
            const top = if (r < path.len and std.fs.path.isSep(path[r])) r + 1 else r;
            pc.add(if (top > 0) path[0..top] else "/", path[0..top]);
            start = top;
        }
        var i = start;
        while (i <= path.len) {
            const end = std.mem.indexOfScalarPos(u8, path, i, sep) orelse path.len;
            if (end > i) {
                // The file's segment lists its siblings.
                pc.add(path[i..end], if (end == path.len) path[0 .. i - @intFromBool(i > 0)] else path[0..end]);
            }
            i = end + 1;
        }
    }

    fn add(pc: *PathCrumbs, label: []const u8, dir: []const u8) void {
        if (pc.len == max_segments) {
            // Keep the first and the deepest ones.
            std.mem.copyForwards(Crumb, pc.crumbs[1 .. max_segments - 1], pc.crumbs[2..max_segments]);
            std.mem.copyForwards(Folder, pc.folders[1 .. max_segments - 1], pc.folders[2..max_segments]);
            pc.len -= 1;
            for (pc.crumbs[0..pc.len], pc.folders[0..pc.len]) |*c, *f| c.ctx = f;
        }
        pc.folders[pc.len] = .{ .pc = pc, .dir = if (dir.len == 0) "/" else dir };
        pc.crumbs[pc.len] = .{ .label = label, .children = children, .ctx = &pc.folders[pc.len] };
        pc.len += 1;
    }

    /// The files of a segment's folder, sorted, as `file.open` items.
    fn children(ctx: ?*anyopaque, arena: Allocator, out: *std.ArrayList(MenuItem)) void {
        const f: *const Folder = @ptrCast(@alignCast(ctx.?));
        listFiles(f.pc.io, arena, f.dir, out) catch return;
    }
};

/// Appends a `file.open` item per file in `dir` (sorted by name).
pub fn listFiles(io: Io, arena: Allocator, dir_path: []const u8, out: *std.ArrayList(MenuItem)) !void {
    var dir = try Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or names.items.len == max_entries) continue;
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (names.items) |name| {
        const abs = try std.fs.path.join(arena, &.{ dir_path, name });
        try out.append(arena, .{ .action = .{ .label = name, .action = open_action, .arg = abs } });
    }
}

const testing = std.testing;

fn labels(pc: *const PathCrumbs, buf: []u8) []const u8 {
    var n: usize = 0;
    for (pc.items()) |c| {
        @memcpy(buf[n..][0..c.label.len], c.label);
        n += c.label.len;
        buf[n] = '|';
        n += 1;
    }
    return buf[0..n];
}

test "path crumbs: inside and outside the workspace" {
    if (std.fs.path.sep != '/') return error.SkipZigTest;
    var pc: PathCrumbs = .init(testing.allocator, testing.io);
    defer pc.deinit();
    var buf: [256]u8 = undefined;
    try pc.set("/home/me/zigguro", "/home/me/zigguro/packages/gui/src/root.zig");
    try testing.expectEqualStrings("zigguro|packages|gui|src|root.zig|", labels(&pc, &buf));
    // Folders list their own files; the file lists its siblings.
    const folders: []const PathCrumbs.Folder = pc.folders[0..pc.len];
    try testing.expectEqualStrings("/home/me/zigguro", folders[0].dir);
    try testing.expectEqualStrings("/home/me/zigguro/packages", folders[1].dir);
    try testing.expectEqualStrings("/home/me/zigguro/packages/gui/src", folders[4].dir);

    try pc.set("/home/me/zigguro", "/etc/hosts");
    try testing.expectEqualStrings("/|etc|hosts|", labels(&pc, &buf));
    try testing.expectEqualStrings("/etc", pc.folders[2].dir);
}

test "path crumbs: a folder's dropdown lists its files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    var out: std.ArrayList(MenuItem) = .empty;
    try listFiles(io, arena.allocator(), root, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("a.zig", out.items[0].action.label);
    try testing.expect(std.mem.endsWith(u8, out.items[1].action.arg.?, "b.zig"));
}
