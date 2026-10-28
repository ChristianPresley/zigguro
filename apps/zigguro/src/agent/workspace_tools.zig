//! `WorkspaceTools`: the agent's read-only workspace tools in the IDE
//! (E08.F08.S02.T01, #690): `list_dir`, `glob`, `find_files` and `grep`
//! from zg_workspace over a scan of the working folder (ignore files
//! respected). The scan starts with the tools; a call made more than
//! `rescan_ms` after the last scan rescans first (unchanged entries keep
//! their ids), so files the agent or the user created are seen without a
//! file watcher. Tool calls run on the agent's workers, one scan at a time.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_workspace = @import("zg_workspace");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;
const tools = zg_workspace.ai.tools;
const Inner = tools.ToolExporter(foreign);
const log = std.log.scoped(.workspace_tools);

/// A call this long after the last scan rescans the folder first.
pub const rescan_ms = 2000;
/// Files larger than this are not searched by `grep`.
pub const max_grep_bytes = 4 << 20;

/// See the module doc.
pub const WorkspaceTools = struct {
    gpa: Allocator,
    io: Io,
    ws: *zg_workspace.Workspace,
    roots: [1]tools.Root,
    inner: Inner = undefined,
    mutex: Io.Mutex = .init,
    job: ?*zg_workspace.scanner.ScanJob = null,
    scanned_at: ?Io.Timestamp = null,

    /// Tools over folder `root` (absolute); starts the first scan.
    pub fn create(gpa: Allocator, io: Io, root: []const u8) !*WorkspaceTools {
        const t = try gpa.create(WorkspaceTools);
        errdefer gpa.destroy(t);
        const ws = try zg_workspace.Workspace.open(gpa, io, .{ .folder = root }, .{});
        errdefer ws.close();
        t.* = .{ .gpa = gpa, .io = io, .ws = ws, .roots = .{.{ .id = .of(0), .name = ws.roots()[0].name }} };
        t.inner = .{ .src = .{ .store = ws.paths(), .roots = &t.roots, .read = .{ .ctx = t, .read = readFile } } };
        t.job = zg_workspace.Scanner.start(gpa, io, zg_workspace.Scanner.forWorkspace(ws, .of(0)), "", .{}) catch |e| blk: {
            log.warn("scanning {s}: {t}", .{ root, e });
            break :blk null;
        };
        return t;
    }

    pub fn destroy(t: *WorkspaceTools) void {
        if (t.job) |j| {
            j.cancel();
            j.deinit();
        }
        t.ws.close();
        t.gpa.destroy(t);
    }

    /// The exporter the agent host registers; `t` must outlive the agent.
    pub fn exporter(t: *WorkspaceTools) foreign.Exporter {
        var e = t.inner.exporter();
        e.ctx = t;
        e.list = list;
        e.call = call;
        return e;
    }

    /// Finishes the running scan, or rescans when the last one is stale.
    pub fn refresh(t: *WorkspaceTools) void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        if (t.job == null) {
            const fresh = if (t.scanned_at) |at| at.untilNow(t.io, .awake).toMilliseconds() < rescan_ms else false;
            if (fresh) return;
            t.job = zg_workspace.Scanner.start(t.gpa, t.io, zg_workspace.Scanner.forWorkspace(t.ws, .of(0)), "", .{}) catch |e| {
                log.warn("rescanning: {t}", .{e});
                return;
            };
        }
        const j = t.job.?;
        j.wait();
        j.deinit();
        t.job = null;
        t.scanned_at = .now(t.io, .awake);
    }

    fn list(ctx: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        const t: *WorkspaceTools = @ptrCast(@alignCast(ctx));
        const e = t.inner.exporter();
        return e.list(e.ctx, arena);
    }

    fn call(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        const t: *WorkspaceTools = @ptrCast(@alignCast(ctx));
        t.refresh();
        const e = t.inner.exporter();
        return e.call(e.ctx, io, arena, tool, input_json);
    }

    fn readFile(ctx: *anyopaque, arena: Allocator, root: zg_workspace.RootId, rel: []const u8) ?[]const u8 {
        const t: *WorkspaceTools = @ptrCast(@alignCast(ctx));
        _ = root;
        const abs = std.fs.path.join(arena, &.{ t.ws.roots()[0].abs_path, rel }) catch return null;
        return Io.Dir.cwd().readFileAlloc(t.io, abs, arena, .limited(max_grep_bytes)) catch null;
    }
};

const testing = std.testing;

test "workspace tools: grep and glob see the folder, and files made later" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1; // TODO tidy\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "out/\n" });
    try tmp.dir.createDirPath(io, "out");
    try tmp.dir.writeFile(io, .{ .sub_path = "out/gen.zig", .data = "// TODO generated\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    const t = try WorkspaceTools.create(gpa, io, root);
    defer t.destroy();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const x = t.exporter();
    const names = try x.list(x.ctx, a);
    try testing.expectEqual(@as(usize, 4), names.len);

    var r = try x.call(x.ctx, io, a, "grep", "{\"pattern\":\"TODO\"}");
    try testing.expect(std.mem.indexOf(u8, r.json, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, r.json, "gen.zig") == null);

    // A file made after the scan shows up once the scan is stale.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "// TODO new\n" });
    t.scanned_at = .fromNanoseconds(0);
    r = try x.call(x.ctx, io, a, "glob", "{\"pattern\":\"*.zig\"}");
    try testing.expect(std.mem.indexOf(u8, r.json, "b.zig") != null);
}
