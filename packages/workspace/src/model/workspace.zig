//! `Workspace`: one or more root folders with their path store, ignore
//! stack, per-workspace storage, session registry and event bus.
//!
//! `open` does filesystem work (real paths, the workspace file, the state
//! directory and its lock) and must run on a worker; the UI calls
//! `openAsync`, which runs `open` on a `zg_core.runtime.Subsystem` task and hands the
//! result to a callback (which posts to the UI).
//!
//! Lock: the first process to open a workspace owns its storage. A second one
//! gets `read_only = true`: it indexes in memory but never writes the index
//! cache or the session.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const ids = @import("../ids.zig");
const RootId = ids.RootId;
const PathStore = @import("../paths/path_store.zig").PathStore;
const Change = @import("../paths/path_store.zig").Change;
const IgnoreStack = @import("../ignore/ignore_stack.zig").IgnoreStack;
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;
const workspace_file = @import("workspace_file.zig");
const session = @import("session.zig");
const events = @import("../scan/events.zig");

/// E16 trust state of a root.
pub const Trust = enum { unknown, trusted, restricted };

/// One root folder.
pub const Root = struct {
    /// Stable id (index into `Workspace.roots`, never reused).
    id: RootId,
    /// Canonical absolute path.
    abs_path: []const u8,
    /// Display name (unique within the workspace).
    name: []const u8,
    /// Whether path comparison folds case on this root.
    case_insensitive: bool,
    /// A code folder or a notes vault.
    kind: enum { folder, vault } = .folder,
    /// Trust state from E16 (`unknown` until it answers).
    trust: Trust = .unknown,
    /// False once removed; removed roots keep their id slot.
    live: bool = true,
};

/// What to open.
pub const OpenSpec = union(enum) {
    /// One folder (absolute path).
    folder: []const u8,
    /// A `.zigguro/workspace.zon` or other workspace file (absolute path).
    workspace_file: []const u8,
    /// Several folders (absolute paths).
    folders: []const []const u8,
};

/// Open options.
pub const OpenOptions = struct {
    /// The global state directory (see `storage.stateDir`); null runs
    /// without persistence.
    state_dir: ?std.Io.Dir = null,
    /// Override case-insensitivity detection (defaults to the OS norm).
    case_insensitive: ?bool = null,
};

/// Whether filesystems on this OS fold case by default.
pub const default_case_insensitive = builtin.os.tag == .windows or builtin.os.tag.isDarwin();

/// An open workspace.
pub const Workspace = struct {
    gpa: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    root_list: std.ArrayList(Root) = .empty,
    path_store: *PathStore,
    ignore_stack: *IgnoreStack,
    store: ?Storage = null,
    /// True when another process holds the storage lock.
    read_only: bool = false,
    /// The session registry.
    sessions: session.Sessions,
    /// The event bus.
    bus: events.Bus,
    /// The workspace file this was opened from, if any.
    file_path: ?[]const u8 = null,
    /// Raw settings subtree from the workspace file, for E15.
    settings: ?[]const u8 = null,
    /// Non-fatal problems found while opening.
    diagnostics: zg_core.report.Diagnostics,
    default_ci: bool,

    /// Opens a workspace (worker thread).
    pub fn open(gpa: Allocator, io: std.Io, spec: OpenSpec, opts: OpenOptions) !*Workspace {
        const ws = try gpa.create(Workspace);
        errdefer gpa.destroy(ws);
        const ps = try PathStore.init(gpa, io);
        errdefer ps.deinit();
        const st = try IgnoreStack.init(gpa, io, 0);
        errdefer st.deinit();
        ws.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .path_store = ps,
            .ignore_stack = st,
            .sessions = .init(gpa),
            .bus = .init(gpa, io),
            .diagnostics = .init(gpa),
            .default_ci = opts.case_insensitive orelse default_case_insensitive,
        };
        errdefer {
            ws.arena.deinit();
            ws.root_list.deinit(gpa);
            ws.sessions.deinit();
            ws.bus.deinit();
            ws.diagnostics.deinit();
        }
        const a = ws.arena.allocator();
        var identity: []const u8 = "";
        switch (spec) {
            .folder => |p| {
                _ = try ws.addRoot(p, null);
                identity = ws.root_list.items[0].abs_path;
            },
            .folders => |list| {
                for (list) |p| _ = ws.addRoot(p, null) catch |err| switch (err) {
                    error.DuplicateRoot => continue,
                    else => return err,
                };
                var joined: std.ArrayList(u8) = .empty;
                for (ws.root_list.items) |r| {
                    try joined.appendSlice(a, r.abs_path);
                    try joined.append(a, 0);
                }
                identity = joined.items;
            },
            .workspace_file => |p| {
                const real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, p, a);
                ws.file_path = real;
                identity = real;
                const src = try std.Io.Dir.cwd().readFileAllocOptions(io, real, a, .limited(4 << 20), .of(u8), 0);
                const wf = try workspace_file.parse(a, src, &ws.diagnostics);
                ws.settings = wf.settings;
                const base = std.fs.path.dirname(real) orelse "/";
                for (wf.folders) |f| {
                    const abs = try std.fs.path.resolve(a, &.{ base, f.path });
                    _ = ws.addRoot(abs, f.name) catch |err| switch (err) {
                        error.DuplicateRoot => {
                            ws.diagnostics.add(.warn, "duplicate folder {s} ignored", .{f.path});
                            continue;
                        },
                        else => return err,
                    };
                }
                for (wf.vaults) |v| {
                    const abs = try std.fs.path.resolve(a, &.{ base, v });
                    for (ws.root_list.items) |*r| {
                        if (std.mem.eql(u8, r.abs_path, abs)) r.kind = .vault;
                    }
                }
            },
        }
        if (ws.default_ci) {
            const lowered = try a.dupe(u8, identity);
            _ = std.ascii.lowerString(lowered, lowered);
            identity = lowered;
        }
        if (opts.state_dir) |sd| {
            ws.store = try Storage.open(io, sd, identity);
            if (try ws.store.?.lock(io) == .held_by_other) ws.read_only = true;
        }
        return ws;
    }

    /// Callback of `openAsync`: exactly one of `ws` and `err` is set.
    pub const OpenCallback = struct {
        ctx: *anyopaque,
        done: *const fn (ctx: *anyopaque, ws: ?*Workspace, err: ?anyerror) void,
    };

    /// Runs `open` on a task of `sub` and reports through `cb` (on that
    /// task; the callback posts to the UI). `spec` must outlive the task.
    pub fn openAsync(sub: *zg_core.runtime.Subsystem, gpa: Allocator, spec: OpenSpec, opts: OpenOptions, cb: OpenCallback) void {
        sub.spawn(openTask, .{ gpa, sub.io, spec, opts, cb });
    }

    fn openTask(gpa: Allocator, io: std.Io, spec: OpenSpec, opts: OpenOptions, cb: OpenCallback) void {
        const ws = open(gpa, io, spec, opts) catch |err| return cb.done(cb.ctx, null, err);
        cb.done(cb.ctx, ws, null);
    }

    /// Adds a root folder (absolute path; worker). Fails with
    /// `DuplicateRoot` when its canonical path is already open.
    pub fn addRoot(ws: *Workspace, abs_path: []const u8, name: ?[]const u8) !RootId {
        const a = ws.arena.allocator();
        const real = try std.Io.Dir.realPathFileAbsoluteAlloc(ws.io, abs_path, a);
        for (ws.root_list.items) |r| {
            if (r.live and (if (ws.default_ci) std.ascii.eqlIgnoreCase(r.abs_path, real) else std.mem.eql(u8, r.abs_path, real))) return error.DuplicateRoot;
        }
        const base = name orelse std.fs.path.basename(real);
        const id: RootId = .of(@intCast(ws.root_list.items.len));
        const unique = try ws.uniqueName(if (base.len == 0) real else base);
        try ws.root_list.append(ws.gpa, .{ .id = id, .abs_path = real, .name = unique, .case_insensitive = ws.default_ci });
        const sid = try ws.ignore_stack.addRoot();
        std.debug.assert(sid == id);
        ws.ignore_stack.setCaseInsensitive(id, ws.default_ci);
        try ws.path_store.addRoot(id, ws.default_ci);
        ws.bus.publish(.{ .roots_changed = .{ .count = @intCast(ws.liveRootCount()) } }, &.{});
        return id;
    }

    fn uniqueName(ws: *Workspace, base: []const u8) ![]const u8 {
        var n: usize = 1;
        var candidate: []const u8 = try ws.arena.allocator().dupe(u8, base);
        while (ws.rootByName(candidate) != null) {
            n += 1;
            candidate = try std.fmt.allocPrint(ws.arena.allocator(), "{s} ({d})", .{ base, n });
        }
        return candidate;
    }

    /// Removes a root and its nodes.
    pub fn removeRoot(ws: *Workspace, id: RootId) !void {
        const r = &ws.root_list.items[id.index()];
        if (!r.live) return;
        r.live = false;
        var changes: std.ArrayList(Change) = .empty;
        defer changes.deinit(ws.gpa);
        try ws.path_store.removeRoot(id, &changes);
        ws.bus.publish(events.WorkspaceEvent.pathsChanged(ws.path_store.generation, changes.items), changes.items);
        ws.bus.publish(.{ .roots_changed = .{ .count = @intCast(ws.liveRootCount()) } }, &.{});
    }

    fn liveRootCount(ws: *const Workspace) usize {
        var n: usize = 0;
        for (ws.root_list.items) |r| n += @intFromBool(r.live);
        return n;
    }

    /// Every root slot (check `live`).
    pub fn roots(ws: *const Workspace) []const Root {
        return ws.root_list.items;
    }

    /// The root named `name`, if live.
    pub fn rootByName(ws: *const Workspace, name: []const u8) ?*const Root {
        for (ws.root_list.items) |*r| if (r.live and std.mem.eql(u8, r.name, name)) return r;
        return null;
    }

    /// Names of the live roots in order (for session paths). Caller frees
    /// the slice (not the names).
    pub fn rootNames(ws: *const Workspace, gpa: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (ws.root_list.items) |r| if (r.live) try out.append(gpa, r.name);
        return out.toOwnedSlice(gpa);
    }

    /// The path store.
    pub fn paths(ws: *Workspace) *PathStore {
        return ws.path_store;
    }

    /// The ignore stack.
    pub fn ignore(ws: *Workspace) *IgnoreStack {
        return ws.ignore_stack;
    }

    /// The per-workspace storage, or null without a state dir or when
    /// read-only.
    pub fn storage(ws: *Workspace) ?*Storage {
        if (ws.read_only) return null;
        if (ws.store) |*s| return s;
        return null;
    }

    /// Subscribes to workspace events.
    pub fn subscribe(ws: *Workspace, l: events.EventListener) !events.ListenerId {
        return ws.bus.subscribe(l);
    }

    /// Captures and saves the session (when writable), releases the lock
    /// and frees the workspace.
    pub fn close(ws: *Workspace) void {
        if (ws.storage()) |st| {
            if (ws.rootNames(ws.gpa)) |names| {
                defer ws.gpa.free(names);
                if (ws.sessions.capture(names)) |b0| {
                    var b = b0;
                    defer b.deinit();
                    ws.sessions.save(ws.io, st, b.finish(), 0) catch |err| std.log.scoped(.workspace).warn("session save failed: {t}", .{err});
                } else |_| {}
            } else |_| {}
        }
        if (ws.store) |*s| s.close(ws.io);
        ws.path_store.deinit();
        ws.ignore_stack.deinit();
        ws.sessions.deinit();
        ws.bus.deinit();
        ws.diagnostics.deinit();
        ws.root_list.deinit(ws.gpa);
        ws.arena.deinit();
        ws.gpa.destroy(ws);
    }
};

test "workspace: open folder, add root, remove root, close flushes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/src");
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.createDirPath(io, "state");
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const proj = try std.fs.path.join(gpa, &.{ base, "proj" });
    defer gpa.free(proj);
    const docs = try std.fs.path.join(gpa, &.{ base, "docs" });
    defer gpa.free(docs);
    var state = try tmp.dir.openDir(io, "state", .{});
    defer state.close(io);

    const ws = try Workspace.open(gpa, io, .{ .folder = proj }, .{ .state_dir = state, .case_insensitive = false });
    try std.testing.expectEqual(@as(usize, 1), ws.roots().len);
    try std.testing.expectEqualStrings("proj", ws.roots()[0].name);
    try std.testing.expect(!ws.read_only);
    const d = try ws.addRoot(docs, null);
    try std.testing.expectError(error.DuplicateRoot, ws.addRoot(docs, null));
    try std.testing.expectEqual(@as(u16, 1), d.index());
    // The second process (handle) sees the lock and goes read-only.
    const ws2 = try Workspace.open(gpa, io, .{ .folder = proj }, .{ .state_dir = state, .case_insensitive = false });
    try std.testing.expect(ws2.read_only);
    try std.testing.expect(ws2.storage() == null);
    ws2.close();
    // A session provider is captured on close.
    const P = struct {
        fn cap(_: *anyopaque, b: *session.SessionBuilder) void {
            b.addEditor(.{ .path = "proj/src/main.zig", .active = true }) catch {};
        }
    };
    var dummy: u8 = 0;
    try ws.sessions.register("editors", .{ .ctx = &dummy, .capture = P.cap });
    try ws.removeRoot(d);
    try std.testing.expect(!ws.roots()[1].live);
    ws.close();

    const ws3 = try Workspace.open(gpa, io, .{ .folder = proj }, .{ .state_dir = state, .case_insensitive = false });
    defer ws3.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = (try session.Sessions.load(io, arena.allocator(), ws3.storage().?)).?;
    try std.testing.expectEqualStrings("proj/src/main.zig", s.editors[0].path);
}

test "workspace: open a workspace file with relative folders and a vault" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "app/.zigguro");
    try tmp.dir.createDirPath(io, "notes");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/.zigguro/workspace.zon", .data =
        \\.{ .folders = .{ .{ .path = ".." }, .{ .path = "../../notes", .name = "Notes" }, .{ .path = "../../app" } },
        \\   .vaults = .{"../../notes"}, .settings = .{ .x = 1 } }
    });
    const file = try tmp.dir.realPathFileAlloc(io, "app/.zigguro/workspace.zon", gpa);
    defer gpa.free(file);
    const ws = try Workspace.open(gpa, io, .{ .workspace_file = file }, .{ .case_insensitive = false });
    defer ws.close();
    try std.testing.expectEqual(@as(usize, 2), ws.roots().len);
    try std.testing.expectEqualStrings("Notes", ws.roots()[1].name);
    try std.testing.expectEqual(.vault, ws.roots()[1].kind);
    try std.testing.expectEqualStrings(".{ .x = 1 }", ws.settings.?);
    try std.testing.expectEqual(@as(usize, 1), ws.diagnostics.messages.items.len);
}

test "workspace: openAsync reports through the callback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    var sub = zg_core.runtime.Subsystem.init(io);
    const R = struct {
        ws: ?*Workspace = null,
        err: ?anyerror = null,
        fn done(ctx: *anyopaque, ws: ?*Workspace, err: ?anyerror) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.ws = ws;
            r.err = err;
        }
    };
    var r: R = .{};
    Workspace.openAsync(&sub, gpa, .{ .folder = base }, .{}, .{ .ctx = &r, .done = R.done });
    var bad: R = .{};
    Workspace.openAsync(&sub, gpa, .{ .folder = "/definitely/not/here/zg" }, .{}, .{ .ctx = &bad, .done = R.done });
    try sub.join();
    try std.testing.expect(r.ws != null);
    r.ws.?.close();
    try std.testing.expect(bad.err != null);
}
