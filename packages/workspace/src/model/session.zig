//! Session state: what was open where, so reopening a workspace puts every
//! editor, cursor, explorer expansion and search back.
//!
//! - Providers (explorer, editor host, search view, notes) register a
//!   `capture` callback. Capture runs on the UI thread and only copies small
//!   POD state into a `SessionBuilder` arena.
//! - Serialization (`std.zon.stringify`) and the write happen on a worker,
//!   at `<storage>/session.zon`. The previous good copy is kept as
//!   `session.prev.zon`; a corrupt `session.zon` falls back to it.
//! - Paths are stored as `<root-name>/<rel>`, so moving the workspace folder
//!   keeps the session; when a root was renamed, `resolvePath` falls back to
//!   the root at the same position.
//! - Limits: 200 editors and 5 000 expanded paths (oldest dropped), 2 MB.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Storage = @import("storage.zig").Storage;

/// Editors stored at most.
pub const max_editors = 200;
/// Expanded explorer paths stored at most.
pub const max_expanded = 5000;
/// Session file size cap.
pub const max_bytes = 2 << 20;

/// The persisted session.
pub const SessionState = struct {
    /// Format version.
    version: u32 = 1,
    /// Root names in workspace order, for the root-order fallback.
    roots: []const []const u8 = &.{},
    /// Open editors, ordered per group.
    editors: []const EditorEntry = &.{},
    /// Explorer state.
    explorer: ExplorerState = .{},
    /// Workspace search state.
    search: ?SearchState = null,
    /// Notes state.
    notes: NotesState = .{},
    /// Agent sessions shown in the agent pane (E10 ULIDs as 26-char text;
    /// ZON integers cannot hold 128 bits).
    agent_sessions: []const []const u8 = &.{},

    /// One open editor.
    pub const EditorEntry = struct {
        /// Dock group id (E04 layout).
        group: u32 = 0,
        /// `<root-name>/<rel>`.
        path: []const u8,
        pinned: bool = false,
        active: bool = false,
        /// Cursor line and UTF-8 byte column.
        cursor: [2]u64 = .{ 0, 0 },
        /// Selection anchor.
        anchor: [2]u64 = .{ 0, 0 },
        scroll_line: u64 = 0,
        /// Opaque editor view state (E05).
        view_state: ?[]const u8 = null,
    };
    /// Explorer expansion and selection.
    pub const ExplorerState = struct {
        expanded: []const []const u8 = &.{},
        selected: ?[]const u8 = null,
        scroll_row: u64 = 0,
    };
    /// The search view's query.
    pub const SearchState = struct { query: []const u8, flags: u16 = 0, include: []const u8 = "", exclude: []const u8 = "" };
    /// Notes UI state.
    pub const NotesState = struct { graph_open: bool = false, last_daily: ?[]const u8 = null };
};

/// Collects state from providers during a capture. Everything is copied into
/// the builder's arena.
pub const SessionBuilder = struct {
    arena: std.heap.ArenaAllocator,
    editors: std.ArrayList(SessionState.EditorEntry) = .empty,
    expanded: std.ArrayList([]const u8) = .empty,
    state: SessionState = .{},

    /// A builder using `gpa`.
    pub fn init(gpa: Allocator) SessionBuilder {
        return .{ .arena = .init(gpa) };
    }

    /// Frees the builder.
    pub fn deinit(b: *SessionBuilder) void {
        b.arena.deinit();
    }

    /// The builder's allocator (for providers copying strings).
    pub fn allocator(b: *SessionBuilder) Allocator {
        return b.arena.allocator();
    }

    /// Adds an editor (path and view state are copied).
    pub fn addEditor(b: *SessionBuilder, e: SessionState.EditorEntry) !void {
        var c = e;
        c.path = try b.allocator().dupe(u8, e.path);
        if (e.view_state) |v| c.view_state = try b.allocator().dupe(u8, v);
        try b.editors.append(b.allocator(), c);
    }

    /// Adds an expanded explorer path (copied).
    pub fn addExpanded(b: *SessionBuilder, path: []const u8) !void {
        try b.expanded.append(b.allocator(), try b.allocator().dupe(u8, path));
    }

    /// The assembled state, applying the editor and expansion limits.
    pub fn finish(b: *SessionBuilder) SessionState {
        var s = b.state;
        const e = b.editors.items;
        s.editors = e[e.len -| max_editors..];
        const x = b.expanded.items;
        s.explorer.expanded = x[x.len -| max_expanded..];
        return s;
    }
};

/// A registered capture callback.
pub const SessionProvider = struct {
    /// Passed back to `capture`.
    ctx: *anyopaque,
    /// Copies the provider's state into the builder (UI thread).
    capture: *const fn (ctx: *anyopaque, b: *SessionBuilder) void,
};

/// The session registry and persistence for one workspace.
pub const Sessions = struct {
    gpa: Allocator,
    providers: std.StringArrayHashMapUnmanaged(SessionProvider) = .empty,
    dirty: bool = false,
    last_save_ns: i96 = 0,

    /// Debounce interval of `scheduleSave`.
    pub const debounce_ns = std.time.ns_per_s;

    /// An empty registry.
    pub fn init(gpa: Allocator) Sessions {
        return .{ .gpa = gpa };
    }

    /// Frees the registry.
    pub fn deinit(s: *Sessions) void {
        s.providers.deinit(s.gpa);
    }

    /// Registers (or replaces) the provider for `key` (`key` must outlive
    /// the registry).
    pub fn register(s: *Sessions, key: []const u8, p: SessionProvider) !void {
        try s.providers.put(s.gpa, key, p);
    }

    /// Removes a provider.
    pub fn unregister(s: *Sessions, key: []const u8) void {
        _ = s.providers.orderedRemove(key);
    }

    /// Marks the session dirty; `due` reports when the debounced save is due.
    pub fn scheduleSave(s: *Sessions) void {
        s.dirty = true;
    }

    /// Whether a scheduled save is due at `now_ns` (1 s debounce).
    pub fn due(s: *const Sessions, now_ns: i96) bool {
        return s.dirty and now_ns - s.last_save_ns >= debounce_ns;
    }

    /// Runs every provider into a fresh builder (UI thread). The caller owns
    /// the builder and passes `finish()` to `save` on a worker.
    pub fn capture(s: *Sessions, roots: []const []const u8) !SessionBuilder {
        var b: SessionBuilder = .init(s.gpa);
        errdefer b.deinit();
        const a = b.allocator();
        const rs = try a.alloc([]const u8, roots.len);
        for (rs, roots) |*d, r| d.* = try a.dupe(u8, r);
        b.state.roots = rs;
        for (s.providers.values()) |p| p.capture(p.ctx, &b);
        return b;
    }

    /// Serializes `state` and writes it atomically, keeping the previous
    /// file as `session.prev.zon` (worker).
    pub fn save(s: *Sessions, io: std.Io, storage: *Storage, state: SessionState, now_ns: i96) !void {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        try std.zon.stringify.serialize(state, .{}, &out.writer);
        if (out.written().len > max_bytes) return error.SessionTooLarge;
        storage.root.rename("session.zon", storage.root, "session.prev.zon", io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try storage.atomicWrite(io, "session.zon", out.written());
        s.dirty = false;
        s.last_save_ns = now_ns;
    }

    /// Loads the session (worker), falling back to `session.prev.zon` when
    /// the current file is missing or corrupt. Memory belongs to `arena`.
    pub fn load(io: std.Io, arena: Allocator, storage: *Storage) !?SessionState {
        for ([_][]const u8{ "session.zon", "session.prev.zon" }) |name| {
            const bytes = (try storage.readAlloc(io, arena, name, max_bytes)) orelse continue;
            const z = try arena.dupeZ(u8, bytes);
            const st = std.zon.parse.fromSliceAlloc(SessionState, arena, z, null, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseZon => {
                    if (!@import("builtin").is_test) std.log.scoped(.session).warn("{s} is unreadable; trying the previous copy", .{name});
                    continue;
                },
            };
            return st;
        }
        return null;
    }
};

/// A session path resolved against the current roots.
pub const Resolved = struct { root: u16, rel: []const u8 };

/// Resolves `<root-name>/<rel>` against `current_roots` (names in workspace
/// order). When no current root has that name, the root that sat at the
/// same position in `saved_roots` is used.
pub fn resolvePath(path: []const u8, saved_roots: []const []const u8, current_roots: []const []const u8) ?Resolved {
    const slash = std.mem.indexOfScalar(u8, path, '/');
    const name = if (slash) |sl| path[0..sl] else path;
    const rel = if (slash) |sl| path[sl + 1 ..] else "";
    for (current_roots, 0..) |r, i| if (std.mem.eql(u8, r, name)) return .{ .root = @intCast(i), .rel = rel };
    for (saved_roots, 0..) |r, i| {
        if (std.mem.eql(u8, r, name) and i < current_roots.len) return .{ .root = @intCast(i), .rel = rel };
    }
    return null;
}

test "session: roundtrip with 50 editors and 1000 expanded dirs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var st = try Storage.open(io, tmp.dir, "ws");
    defer st.close(io);
    var sessions: Sessions = .init(gpa);
    defer sessions.deinit();
    const Fake = struct {
        fn capture(_: *anyopaque, b: *SessionBuilder) void {
            var buf: [64]u8 = undefined;
            for (0..50) |i| b.addEditor(.{ .group = @intCast(i % 3), .path = std.fmt.bufPrint(&buf, "app/src/f{d}.zig", .{i}) catch unreachable, .cursor = .{ i, 4 }, .active = i == 7 }) catch {};
            for (0..1000) |i| b.addExpanded(std.fmt.bufPrint(&buf, "app/d{d}", .{i}) catch unreachable) catch {};
            b.state.search = .{ .query = "TODO", .include = "*.zig" };
        }
    };
    var dummy: u8 = 0;
    try sessions.register("fake", .{ .ctx = &dummy, .capture = Fake.capture });
    var b = try sessions.capture(&.{"app"});
    defer b.deinit();
    const state = b.finish();
    try sessions.save(io, &st, state, 0);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const back = (try Sessions.load(io, arena.allocator(), &st)).?;
    try std.testing.expectEqual(@as(usize, 50), back.editors.len);
    try std.testing.expectEqual(@as(usize, 1000), back.explorer.expanded.len);
    try std.testing.expectEqualStrings("app/src/f7.zig", back.editors[7].path);
    try std.testing.expect(back.editors[7].active);
    try std.testing.expectEqual(@as(u64, 7), back.editors[7].cursor[0]);
    try std.testing.expectEqualStrings("TODO", back.search.?.query);
    try std.testing.expectEqualStrings("app", back.roots[0]);
}

test "session: corrupt file falls back to prev" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var st = try Storage.open(io, tmp.dir, "ws");
    defer st.close(io);
    var sessions: Sessions = .init(gpa);
    defer sessions.deinit();
    try sessions.save(io, &st, .{ .editors = &.{.{ .path = "r/a" }} }, 0);
    try sessions.save(io, &st, .{ .editors = &.{.{ .path = "r/b" }} }, 0);
    try st.atomicWrite(io, "session.zon", ".{ .editors = .{ .{ .path = ");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const back = (try Sessions.load(io, arena.allocator(), &st)).?;
    try std.testing.expectEqualStrings("r/a", back.editors[0].path);
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var empty = try Storage.open(io, tmp2.dir, "none");
    defer empty.close(io);
    try std.testing.expect(try Sessions.load(io, arena.allocator(), &empty) == null);
}

test "session: path with renamed root name resolves by root order fallback" {
    const saved = [_][]const u8{ "app", "docs" };
    const now = [_][]const u8{ "application", "docs" };
    const a = resolvePath("app/src/main.zig", &saved, &now).?;
    try std.testing.expectEqual(@as(u16, 0), a.root);
    try std.testing.expectEqualStrings("src/main.zig", a.rel);
    const d = resolvePath("docs/x.md", &saved, &now).?;
    try std.testing.expectEqual(@as(u16, 1), d.root);
    try std.testing.expect(resolvePath("gone/x", &saved, &now) == null);
}

test "session: limits and debounce" {
    var b: SessionBuilder = .init(std.testing.allocator);
    defer b.deinit();
    for (0..max_editors + 5) |i| try b.addEditor(.{ .path = if (i == 0) "first" else "x" });
    const s = b.finish();
    try std.testing.expectEqual(@as(usize, max_editors), s.editors.len);
    var sessions: Sessions = .init(std.testing.allocator);
    defer sessions.deinit();
    try std.testing.expect(!sessions.due(10 * std.time.ns_per_s));
    sessions.scheduleSave();
    try std.testing.expect(sessions.due(10 * std.time.ns_per_s));
    sessions.last_save_ns = 10 * std.time.ns_per_s;
    try std.testing.expect(!sessions.due(10 * std.time.ns_per_s + 5));
}
