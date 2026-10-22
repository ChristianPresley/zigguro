//! `zg scm` (E09): repository commands.
//!
//! - `zg scm debug fsck` (E09.F01.S01.T03) checks the object store of the
//!   repository around the current directory and reports every problem it
//!   finds: exit 0 when clean, 1 on corruption or missing objects.
//! - `zg scm lane status` (E09.F06.S03.T01) lists the lanes with their
//!   status and landing ticket.
//!
//! - `zg scm ai describe|resolve` (E09.F06) are in `cmd_scm_ai.zig`.
//!
//! `fsck` and `lane status` exit 2 on a usage error or when there is no repository.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_scm = @import("zg_scm");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const usage =
    \\Usage: zg scm debug fsck [--repo DIR] [--json]
    \\       zg scm lane status [--repo DIR] [--json]
    \\       zg scm ai describe|resolve [REV]   (zg scm ai --help)
    \\
    \\Checks the object store: index checksums and order, that every
    \\record hashes to its ID, that trees, changes and chunked blobs decode,
    \\and that everything they refer to is present. Data files without an
    \\index (left by an interrupted write) are listed but are not errors.
    \\
    \\`lane status` lists every lane: workspace, owner, status, and its
    \\landing ticket (state and the reason a lane came back).
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
    const Cmd = enum { fsck, lane_status };
    const cmd: Cmd = if (argv.len >= 2 and std.mem.eql(u8, argv[0], "debug") and std.mem.eql(u8, argv[1], "fsck"))
        .fsck
    else if (argv.len >= 2 and std.mem.eql(u8, argv[0], "lane") and std.mem.eql(u8, argv[1], "status"))
        .lane_status
    else {
        try err.writeAll(usage);
        return 2;
    };
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

    var repo_dir = locate(io, cwd, repo) catch |e| switch (e) {
        error.NoRepository => {
            try err.writeAll("zg scm: no zg repository here (looked for .zg/repo/store)\n");
            return 2;
        },
        else => return e,
    };
    defer repo_dir.close(io);
    var store_dir = (try storeIn(io, repo_dir)).?;
    defer store_dir.close(io);
    if (cmd == .lane_status) return laneStatus(gpa, io, repo_dir, store_dir, json, out, err);

    const s = try zg_scm.Store.open(gpa, io, store_dir, .{});
    defer s.close();
    var report = try zg_scm.fsck.fsck(s, .{});
    defer report.deinit();
    if (json) try writeJson(&report, out) else try writeText(&report, out);
    return if (report.clean()) 0 else 1;
}

/// The repository directory (`.zg/repo`) at `path`, or the nearest one
/// at or above `cwd`; `error.NoRepository` when there is none.
pub fn locate(io: Io, cwd: Io.Dir, path: ?[]const u8) !Io.Dir {
    return if (path) |r| openRepoAt(io, cwd, r) else findRepo(io, cwd);
}

/// The repository at `path`: a workspace root or the `.zg/repo`
/// directory itself.
fn openRepoAt(io: Io, cwd: Io.Dir, path: []const u8) !Io.Dir {
    var d = cwd.openDir(io, path, .{}) catch return error.NoRepository;
    if (try storeIn(io, d)) |s| {
        var st = s;
        st.close(io);
        return d;
    }
    defer d.close(io);
    var zg = d.openDir(io, ".zg", .{}) catch return error.NoRepository;
    defer zg.close(io);
    return try usable(io, repoDir(io, zg) catch return error.NoRepository);
}

/// `r` when it holds a store, else closed and `NoRepository`.
fn usable(io: Io, r: Io.Dir) !Io.Dir {
    var d = r;
    if (try storeIn(io, d)) |s| {
        var st = s;
        st.close(io);
        return d;
    }
    d.close(io);
    return error.NoRepository;
}

/// Walks up from `cwd` to the nearest directory with a `.zg/repo`.
fn findRepo(io: Io, cwd: Io.Dir) !Io.Dir {
    var d = try cwd.openDir(io, ".", .{});
    defer d.close(io);
    var last_buf: [std.fs.max_path_bytes]u8 = undefined;
    var last: []const u8 = "";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        if (d.openDir(io, ".zg", .{})) |zg_dir| {
            var zg = zg_dir;
            defer zg.close(io);
            if (repoDir(io, zg)) |r| {
                if (usable(io, r)) |ok| return ok else |_| {}
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
pub fn storeIn(io: Io, repo: Io.Dir) !?Io.Dir {
    var s = repo.openDir(io, "store", .{}) catch return null;
    var seg = s.openDir(io, "seg", .{}) catch {
        s.close(io);
        return null;
    };
    seg.close(io);
    return s;
}

fn laneStatus(gpa: Allocator, io: Io, repo_dir: Io.Dir, store_dir: Io.Dir, json: bool, out: *Io.Writer, err: *Io.Writer) !u8 {
    const s = try zg_scm.Store.open(gpa, io, store_dir, .{});
    defer s.close();
    const r = zg_scm.Repo.load(gpa, io, repo_dir, s, .{}, .head) catch |e| switch (e) {
        error.NotInitialized, error.NoOpHeads => {
            try err.writeAll("zg scm: the repository has no operation log yet\n");
            return 2;
        },
        else => return e,
    };
    defer r.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lanes = r.view().lanes;
    if (!json) {
        if (lanes.len == 0) try out.writeAll("no lanes\n");
        for (lanes) |l| {
            try out.print("{s}  {s}  workspace {s}, owner {s}", .{ l.name, l.status, l.workspace, l.owner });
            if (zg_scm.ai.landing.laneState(a, l)) |st| {
                try out.print(", ticket {d} {t}", .{ st.ticket, st.state });
                if (st.reason.len > 0) try out.print(": {s}", .{std.mem.sliceTo(st.reason, '\n')});
            }
            try out.writeByte('\n');
        }
        return 0;
    }
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try js.objectField("lanes");
    try js.beginArray();
    for (lanes) |l| {
        try js.beginObject();
        inline for (.{ "name", "workspace", "owner", "status", "policy" }) |f| {
            try js.objectField(f);
            try js.write(@field(l, f));
        }
        try js.objectField("base");
        if (l.base) |b| try js.print("\"{f}\"", .{b}) else try js.write(null);
        try js.objectField("landing");
        if (zg_scm.ai.landing.laneState(a, l)) |st| {
            try js.beginObject();
            try js.objectField("ticket");
            try js.write(st.ticket);
            try js.objectField("state");
            try js.write(@tagName(st.state));
            try js.objectField("reason");
            try js.write(st.reason);
            try js.endObject();
        } else try js.write(null);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try out.writeByte('\n');
    return 0;
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

test "zg scm lane status: text and JSON" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    var repo_dir = try tmp.dir.createDirPathOpen(io, "ws/.zg/repo", .{});
    defer repo_dir.close(io);
    var store_dir = try repo_dir.createDirPathOpen(io, "store/seg", .{});
    store_dir.close(io);
    store_dir = try repo_dir.openDir(io, "store", .{});
    defer store_dir.close(io);
    {
        const s = try zg_scm.Store.open(gpa, io, store_dir, .{ .fsync = false });
        defer s.close();
        const meta: zg_scm.OpMeta = .{ .start_ms = 1, .end_ms = 1, .description = "init", .user = "t", .host = "h", .workspace = "default", .actor = .human, .tags = &.{} };
        const r0 = try zg_scm.Repo.init(gpa, io, repo_dir, s, .{}, meta);
        defer r0.close();
        const tx = try r0.startTransaction(meta);
        try tx.mutRepo().setLane(.{ .name = "fix-parser", .workspace = "ws1", .owner = "agent-1", .base = null, .status = "landing", .policy = "", .updated_ms = 1, .extra = &.{
            .{ .key = "landing", .value = "{\"ticket\":3,\"state\":\"returned_conflict\",\"target\":\"main\",\"reason\":\"src/a.zig\"}" },
        } });
        const r1 = try tx.commit();
        r1.close();
    }

    try testing.expectEqual(@as(u8, 0), try runIn(gpa, io, tmp.dir, &.{ "lane", "status", "--repo", "ws" }, &out.writer, &err.writer));
    try testing.expectEqualStrings("fix-parser  landing  workspace ws1, owner agent-1, ticket 3 returned_conflict: src/a.zig\n", out.written());

    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runIn(gpa, io, tmp.dir, &.{ "lane", "status", "--repo", "ws/.zg/repo", "--json" }, &out.writer, &err.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    const lane = parsed.value.object.get("lanes").?.array.items[0].object;
    try testing.expectEqualStrings("fix-parser", lane.get("name").?.string);
    try testing.expectEqualStrings("returned_conflict", lane.get("landing").?.object.get("state").?.string);
}
