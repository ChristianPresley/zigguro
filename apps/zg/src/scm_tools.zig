//! The repository tools for `zg agent` (E10.F06.S03.T01, E09 side): when
//! the working directory is inside a zg repository, zg_scm's
//! `ToolExporter` is handed to the tool registry as `Services.scm`, so
//! the agent gets `scm_log`, `scm_show`, `scm_status` and `scm_op_log`.
//! Lane submission needs a review port, which the headless agent does
//! not have, so it is left out.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_scm = @import("zg_scm");
const cmd_scm = @import("cmd_scm.zig");

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
        var repo_dir = cmd_scm.locate(io, cwd, null) catch |e| switch (e) {
            error.NoRepository => return null,
            else => return e,
        };
        errdefer repo_dir.close(io);
        var store_dir = (try cmd_scm.storeIn(io, repo_dir)).?;
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
    var ws = try tmp.dir.openDir(io, "ws", .{});
    defer ws.close(io);
    var tools = (try ScmTools.open(gpa, io, ws)).?;
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
