//! `zg scm` (E09): repository commands. For now `zg scm debug fsck`
//! (E09.F01.S01.T03), which checks the object store of the repository
//! around the current directory and reports every problem it finds.
//!
//! Exit 0 when the store is clean, 1 on corruption or missing objects,
//! 2 on a usage error or when there is no repository.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_scm = @import("zg_scm");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const usage =
    \\Usage: zg scm debug fsck [--repo DIR] [--json]
    \\
    \\Checks the object store: index checksums and order, that every
    \\record hashes to its ID, that trees, changes and chunked blobs decode,
    \\and that everything they refer to is present. Data files without an
    \\index (left by an interrupted write) are listed but are not errors.
    \\
    \\--repo DIR   a workspace (or its .zg/repo); default: the nearest one
    \\             at or above the current directory
    \\--json       one JSON object instead of text
    \\
;

pub fn run(rt: *zg_core.Runtime, argv: []const []const u8) !u8 {
    var obuf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), rt.io, &obuf);
    defer out_w.interface.flush() catch {};
    var ebuf: [1024]u8 = undefined;
    var err_w: Io.File.Writer = .init(.stderr(), rt.io, &ebuf);
    defer err_w.interface.flush() catch {};
    return runIn(rt.gpa, rt.io, Io.Dir.cwd(), argv, &out_w.interface, &err_w.interface);
}

/// `run` with the working directory and output streams given.
pub fn runIn(gpa: Allocator, io: Io, cwd: Io.Dir, argv: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    if (argv.len >= 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h"))) {
        try out.writeAll(usage);
        return 0;
    }
    if (argv.len < 2 or !std.mem.eql(u8, argv[0], "debug") or !std.mem.eql(u8, argv[1], "fsck")) {
        try err.writeAll(usage);
        return 2;
    }
    var repo: ?[]const u8 = null;
    var json = false;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--repo") and i + 1 < argv.len) {
            i += 1;
            repo = argv[i];
        } else {
            try err.print("zg scm: unknown argument {s}\n{s}", .{ a, usage });
            return 2;
        }
    }

    var store_dir = (if (repo) |r| openStoreAt(io, cwd, r) else findStore(io, cwd)) catch |e| switch (e) {
        error.NoRepository => {
            try err.writeAll("zg scm: no zg repository here (looked for .zg/repo/store)\n");
            return 2;
        },
        else => return e,
    };
    defer store_dir.close(io);

    const s = try zg_scm.Store.open(gpa, io, store_dir, .{});
    defer s.close();
    var report = try zg_scm.fsck.fsck(s, .{});
    defer report.deinit();
    if (json) try writeJson(&report, out) else try writeText(&report, out);
    return if (report.clean()) 0 else 1;
}

/// The store of the repository at `path`: a workspace root or the
/// `.zg/repo` directory itself.
fn openStoreAt(io: Io, cwd: Io.Dir, path: []const u8) !Io.Dir {
    var d = cwd.openDir(io, path, .{}) catch return error.NoRepository;
    defer d.close(io);
    if (try storeIn(io, d)) |s| return s;
    var zg = d.openDir(io, ".zg", .{}) catch return error.NoRepository;
    defer zg.close(io);
    var r = repoDir(io, zg) catch return error.NoRepository;
    defer r.close(io);
    return (try storeIn(io, r)) orelse error.NoRepository;
}

/// Walks up from `cwd` to the nearest directory with a `.zg/repo`.
fn findStore(io: Io, cwd: Io.Dir) !Io.Dir {
    var d = try cwd.openDir(io, ".", .{});
    defer d.close(io);
    var last_buf: [std.fs.max_path_bytes]u8 = undefined;
    var last: []const u8 = "";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        if (d.openDir(io, ".zg", .{})) |zg_dir| {
            var zg = zg_dir;
            defer zg.close(io);
            if (repoDir(io, zg)) |r_dir| {
                var r = r_dir;
                defer r.close(io);
                if (try storeIn(io, r)) |s| return s;
            } else |_| {}
        } else |_| {}
        // Stop at the filesystem root, where ".." is the directory itself.
        const here = path_buf[0 .. d.realPath(io, &path_buf) catch return error.NoRepository];
        if (std.mem.eql(u8, here, last)) return error.NoRepository;
        @memcpy(last_buf[0..here.len], here);
        last = last_buf[0..here.len];
        const up = d.openDir(io, "..", .{}) catch return error.NoRepository;
        d.close(io);
        d = up;
    }
}

/// `.zg/repo`: a directory in the main workspace; in a secondary one, a
/// file holding the path of the main workspace's `.zg/repo`.
fn repoDir(io: Io, zg: Io.Dir) !Io.Dir {
    if (zg.openDir(io, "repo", .{})) |d| return d else |e| switch (e) {
        error.NotDir => {},
        else => return e,
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const text = try zg.readFile(io, "repo", &buf);
    return Io.Dir.cwd().openDir(io, std.mem.trim(u8, text, " \t\r\n"), .{});
}

/// `store/` under `repo` when it has a `seg/` directory (fsck must not
/// create a store).
fn storeIn(io: Io, repo: Io.Dir) !?Io.Dir {
    var s = repo.openDir(io, "store", .{}) catch return null;
    var seg = s.openDir(io, "seg", .{}) catch {
        s.close(io);
        return null;
    };
    seg.close(io);
    return s;
}

fn writeText(r: *const zg_scm.fsck.FsckReport, out: *Io.Writer) !void {
    try out.print("{f}", .{r.*});
    try out.writeAll(if (r.clean()) "store ok\n" else "store damaged\n");
}

fn writeJson(r: *const zg_scm.fsck.FsckReport, out: *Io.Writer) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try js.objectField("clean");
    try js.write(r.clean());
    try js.objectField("segments");
    try js.write(r.segments);
    try js.objectField("objects");
    try js.write(r.objects);
    try js.objectField("corrupt");
    try js.beginArray();
    for (r.corrupt.items) |c| {
        try js.beginObject();
        try js.objectField("segment");
        try js.write(c.segment);
        if (c.id) |id| {
            try js.objectField("id");
            try js.print("\"{f}\"", .{id});
        }
        try js.objectField("reason");
        try js.write(c.reason);
        try js.endObject();
    }
    try js.endArray();
    for ([_]struct { []const u8, []const zg_scm.ObjectId }{
        .{ "missing", r.missing.items },
        .{ "dangling", r.dangling.items },
    }) |list| {
        try js.objectField(list[0]);
        try js.beginArray();
        for (list[1]) |id| try js.print("\"{f}\"", .{id});
        try js.endArray();
    }
    try js.objectField("unpublished");
    try js.write(r.unpublished.items);
    try js.endObject();
    try out.writeByte('\n');
}

const testing = std.testing;

test "zg scm debug fsck: clean, damaged, and no repository" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    try testing.expectEqual(@as(u8, 2), try runIn(gpa, io, tmp.dir, &.{ "debug", "fsck" }, &out.writer, &err.writer));
    try testing.expect(std.mem.indexOf(u8, err.written(), "no zg repository") != null);

    // A workspace with one object, checked from a subdirectory.
    try tmp.dir.createDirPath(io, "ws/src/deep");
    var store_dir = try tmp.dir.createDirPathOpen(io, "ws/.zg/repo/store", .{});
    defer store_dir.close(io);
    {
        const s = try zg_scm.Store.open(gpa, io, store_dir, .{ .fsync = false });
        defer s.close();
        var b = s.batch();
        _ = try b.put(.blob, "hello fsck");
        try b.commit();
    }
    var deep = try tmp.dir.openDir(io, "ws/src/deep", .{});
    defer deep.close(io);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runIn(gpa, io, deep, &.{ "debug", "fsck" }, &out.writer, &err.writer));
    try testing.expect(std.mem.endsWith(u8, out.written(), "store ok\n"));

    // Flip a byte in the record: fsck fails with a precise report.
    var seg_dir = try store_dir.openDir(io, "seg", .{ .iterate = true });
    defer seg_dir.close(io);
    var it = seg_dir.iterate();
    while (try it.next(io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".zgs")) continue;
        var buf: [4096]u8 = undefined;
        const data = try seg_dir.readFile(io, e.name, &buf);
        const at = std.mem.indexOf(u8, data, "hello fsck").?;
        data[at] = 'j';
        try seg_dir.writeFile(io, .{ .sub_path = e.name, .data = data });
    }
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), try runIn(gpa, io, tmp.dir, &.{ "debug", "fsck", "--repo", "ws", "--json" }, &out.writer, &err.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(false, parsed.value.object.get("clean").?.bool);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("corrupt").?.array.items.len);
}
