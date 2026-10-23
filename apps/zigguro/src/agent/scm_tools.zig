//! The repository tools for the workbench agent, as `zg agent` has them
//! (apps/zg/src/scm_tools.zig; apps cannot import each other): when the
//! working folder is inside a zg repository, zg_scm's `ToolExporter` is
//! handed to the tool registry as `Services.scm`, so the agent gets
//! `scm_log`, `scm_show`, `scm_status` and `scm_op_log`. Lane submission
//! is left out until the review queue offers zg_scm a review port.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_scm = @import("zg_scm");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Exporter = zg_scm.ai.agent_tools.ToolExporter(zg_ai.tools.adapters.foreign);

pub const ScmTools = struct {
    io: Io,
    repo_dir: Io.Dir,
    store_dir: Io.Dir,
    ix_dir: Io.Dir,
    store: *zg_scm.Store,
    index: *zg_scm.CommitIndex,
    x: Exporter,

    /// The tools for the repository at or above `cwd`, or null when there
    /// is none. Must not move after `exporter`.
    pub fn open(gpa: Allocator, io: Io, cwd: Io.Dir) !?ScmTools {
        var repo_dir = findRepo(io, cwd) catch |e| switch (e) {
            error.NoRepository => return null,
            else => return e,
        };
        errdefer repo_dir.close(io);
        var store_dir = (try storeIn(io, repo_dir)).?;
        errdefer store_dir.close(io);
        var ix_dir = try repo_dir.createDirPathOpen(io, "index", .{ .open_options = .{ .iterate = true } });
        errdefer ix_dir.close(io);
        const store = try zg_scm.Store.open(gpa, io, store_dir, .{});
        errdefer store.close();
        const index = try zg_scm.CommitIndex.open(gpa, io, ix_dir, store, .{});
        return .{
            .io = io,
            .repo_dir = repo_dir,
            .store_dir = store_dir,
            .ix_dir = ix_dir,
            .store = store,
            .index = index,
            .x = .{ .src = .{ .gpa = gpa, .io = io, .repo_dir = repo_dir, .store = store, .index = index } },
        };
    }

    pub fn exporter(t: *ScmTools) zg_ai.tools.adapters.foreign.Exporter {
        return t.x.exporter();
    }

    pub fn close(t: *ScmTools) void {
        t.index.close();
        t.store.close();
        t.ix_dir.close(t.io);
        t.store_dir.close(t.io);
        t.repo_dir.close(t.io);
    }
};

/// Walks up from `cwd` to the nearest directory with a usable `.zg/repo`.
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

/// `store/` under `repo` when it has a `seg/` directory.
fn storeIn(io: Io, repo: Io.Dir) !?Io.Dir {
    var s = repo.openDir(io, "store", .{}) catch return null;
    var seg = s.openDir(io, "seg", .{}) catch {
        s.close(io);
        return null;
    };
    seg.close(io);
    return s;
}

const testing = std.testing;

test "ScmTools: none outside a repository, the read-only tools inside one" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expect((try ScmTools.open(gpa, io, tmp.dir)) == null);

    var repo_dir = try tmp.dir.createDirPathOpen(io, "ws/.zg/repo", .{});
    defer repo_dir.close(io);
    var seg = try repo_dir.createDirPathOpen(io, "store/seg", .{});
    seg.close(io);
    {
        var store_dir = try repo_dir.openDir(io, "store", .{});
        defer store_dir.close(io);
        const s = try zg_scm.Store.open(gpa, io, store_dir, .{ .fsync = false });
        defer s.close();
        const meta: zg_scm.OpMeta = .{ .start_ms = 1, .end_ms = 1, .description = "init", .user = "t", .host = "h", .workspace = "default", .actor = .human, .tags = &.{} };
        const r0 = try zg_scm.Repo.init(gpa, io, repo_dir, s, .{}, meta);
        r0.close();
    }
    // Found from a folder below the workspace root too.
    var sub = try tmp.dir.createDirPathOpen(io, "ws/src", .{});
    defer sub.close(io);
    var tools = (try ScmTools.open(gpa, io, sub)).?;
    defer tools.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const e = tools.exporter();
    const list = try e.list(e.ctx, arena.allocator());
    try testing.expectEqual(@as(usize, 4), list.len);
    for (list) |tool| try testing.expect(tool.read_only);
    const res = try e.call(e.ctx, io, arena.allocator(), "scm_status", "{}");
    try testing.expect(std.mem.indexOf(u8, res.json, "no working-copy commit") != null);
}
