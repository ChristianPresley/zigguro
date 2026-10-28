//! The file watcher behind `workspace/didChangeWatchedFiles` (E07.F01.S02.T07):
//! once a language server registers file watchers, one recursive watcher
//! on the workspace folder starts (never before: watching scans the whole
//! tree) and its changes go to the manager's watch bridge from a worker,
//! which matches them against the registrations and sends them on the
//! next `tick`. Build output, caches and `.git` are not watched.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_platform = @import("zg_platform");
const zg_codeintel = @import("zg_codeintel");

const fswatch = zg_platform.fswatch;
const Manager = zg_codeintel.Manager;
const FsEvent = Manager.FsEvent;
const log = std.log.scoped(.lsp_watch);

pub const LspWatch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mgr: *Manager,
    root: []const u8,
    started: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    sub: zg_core.runtime.Subsystem,
    names: fswatch.NameList = .{ .names = &.{ ".git", ".zig-cache", "zig-cache", "zig-out", "node_modules" } },

    pub fn init(gpa: std.mem.Allocator, io: std.Io, mgr: *Manager, root: []const u8) LspWatch {
        return .{ .gpa = gpa, .io = io, .mgr = mgr, .root = root, .sub = .init(io) };
    }

    /// Starts watching once a server asks for file changes. UI thread,
    /// every tick; `lw` must not move once started.
    pub fn poll(lw: *LspWatch) void {
        if (lw.started or lw.root.len == 0) return;
        if (lw.mgr.watch) |*b| {
            if (!b.active()) return;
        } else return;
        lw.started = true;
        lw.sub.spawnLoop(run, .{lw}) catch |e| log.warn("file watcher not started: {t}", .{e});
    }

    pub fn deinit(lw: *LspWatch) void {
        lw.stop.store(true, .release);
        lw.sub.join() catch {};
    }

    fn run(lw: *LspWatch) std.Io.Cancelable!void {
        var w = fswatch.Watcher.init(lw.gpa, lw.io, .{}) catch |e| {
            log.warn("file watcher: {t}", .{e});
            return;
        };
        defer w.deinit();
        const filter = lw.names.filter();
        _ = w.addRoot(lw.root, &filter) catch |e| {
            log.warn("watching {s}: {t}", .{ lw.root, e });
            return;
        };
        var raw: [512]fswatch.FsEvent = undefined;
        var out: std.ArrayList(FsEvent) = .empty;
        defer out.deinit(lw.gpa);
        var arena: std.heap.ArenaAllocator = .init(lw.gpa);
        defer arena.deinit();
        while (!lw.stop.load(.acquire)) {
            if (!w.wait(250 * std.time.ns_per_ms)) continue;
            while (true) {
                const n = w.poll(&raw);
                if (n == 0) break;
                out.clearRetainingCapacity();
                _ = arena.reset(.retain_capacity);
                convert(arena.allocator(), lw.root, raw[0..n], &out) catch break;
                lw.mgr.onFsEvents(out.items);
            }
        }
    }
};

/// Watcher events (relative to `root`) as bridge events (absolute).
pub fn convert(a: std.mem.Allocator, root: []const u8, events: []const fswatch.FsEvent, out: *std.ArrayList(FsEvent)) !void {
    for (events) |e| {
        const path = try join(a, root, e.path);
        switch (e.kind) {
            .created => try out.append(a, .{ .path = path, .kind = .created }),
            .modified => try out.append(a, .{ .path = path, .kind = .changed }),
            .removed => try out.append(a, .{ .path = path, .kind = .deleted }),
            .renamed => {
                if (e.old_path) |old| try out.append(a, .{ .path = try join(a, root, old), .kind = .deleted });
                try out.append(a, .{ .path = path, .kind = .created });
            },
            .attrib => {},
            .rescan_required => try out.append(a, .{ .path = path, .kind = .rescan_required }),
        }
    }
}

fn join(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return root;
    const sep: u8 = if (@import("builtin").os.tag == .windows) '\\' else '/';
    const out = try a.alloc(u8, root.len + 1 + rel.len);
    @memcpy(out[0..root.len], root);
    out[root.len] = sep;
    @memcpy(out[root.len + 1 ..], rel);
    if (sep == '\\') std.mem.replaceScalar(u8, out[root.len + 1 ..], '/', '\\');
    return out;
}

test "lsp_watch: watcher events become absolute bridge events" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(FsEvent) = .empty;
    const root: fswatch.api.RootId = @enumFromInt(0);
    try convert(arena.allocator(), "/w", &.{
        .{ .root = root, .kind = .created, .path = "a.zig" },
        .{ .root = root, .kind = .modified, .path = "src/b.zig" },
        .{ .root = root, .kind = .attrib, .path = "c" },
        .{ .root = root, .kind = .renamed, .path = "new.zig", .old_path = "old.zig" },
        .{ .root = root, .kind = .rescan_required, .path = "" },
    }, &out);
    const sep = if (@import("builtin").os.tag == .windows) "\\" else "/";
    try testing.expectEqual(@as(usize, 5), out.items.len);
    try testing.expectEqualStrings("/w" ++ sep ++ "src" ++ sep ++ "b.zig", out.items[1].path);
    try testing.expectEqual(FsEvent.Kind.deleted, out.items[2].kind);
    try testing.expectEqualStrings("/w" ++ sep ++ "old.zig", out.items[2].path);
    try testing.expectEqual(FsEvent.Kind.created, out.items[3].kind);
    try testing.expectEqualStrings("/w", out.items[4].path);
}
