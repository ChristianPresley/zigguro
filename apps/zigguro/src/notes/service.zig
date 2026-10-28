//! `NotesService`: the notes of the open folder in the IDE (E08.F06 app
//! wiring, #671 #682). The folder is the vault: its `.zigguro/vault.zon`
//! or `.obsidian/` settings when it has them, else the defaults. The
//! service scans the folder's Markdown files on a worker into a
//! `NoteIndex` with a `SearchIndex` attached, reindexes a note when it is
//! saved, and owns the notes sidebar (backlinks, outgoing links,
//! properties, tags) and the note search view with their models.
//!
//! The workbench creates it the first time a notes panel or command is
//! used, points it at the current editor's file (`setActive`) and tells
//! it about saves (`fileChanged`). Edits made from the sidebar go
//! through `Hooks.apply` (the review store when the agent runs), else
//! they are written here, checked against the text they were made from.
//!
//! The scan skips hidden folders and build output (`zig-out`,
//! `.zig-cache`, `node_modules`, `target`); `.gitignore` is not read.
//! Vault-relative paths equal folder-relative ones (the vault is the
//! whole folder). UI thread, except the jobs it spawns.

const std = @import("std");
const builtin = @import("builtin");
const zg_gui = @import("zg_gui");
const zg_notes = @import("zg_notes");
const zg_notes_ui = @import("zg_notes_ui");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = zg_notes.FileId;
const NoteIndex = zg_notes.NoteIndex;
const SearchIndex = zg_notes.search.SearchIndex;
const ports = zg_notes_ui.ports;
const FileChange = ports.FileChange;
const log = std.log.scoped(.notes);

/// What the service asks of the workbench.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Opens absolute `abs`, selecting the bytes `range` (UI thread).
    open: *const fn (ctx: *anyopaque, abs: []const u8, range: ?[2]u32, to_side: bool) void,
    /// Shows the note search with `query` (a tag in the sidebar).
    search: *const fn (ctx: *anyopaque, query: []const u8) void,
    /// The notes changed: rebuild (UI thread).
    changed: *const fn (ctx: *anyopaque) void,
    /// Applies sidebar edits (folder-relative paths) as one accepted
    /// changeset and returns its id; null when it cannot (the service
    /// then writes the files itself).
    apply: ?*const fn (ctx: *anyopaque, label: []const u8, changes: []const FileChange) anyerror!?u64 = null,
};

/// Notes larger than this are not indexed.
const max_note_bytes = 4 << 20;
/// The scan publishes the index every this many notes.
const commit_every = 256;

pub const State = enum(u8) { scanning, ready, failed };

/// See the module doc.
pub const NotesService = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    hooks: Hooks,
    /// The folder (absolute).
    root: []u8,
    /// Whether the folder is configured as a vault (else the defaults).
    configured: bool,
    /// The vault config's strings.
    arena: std.heap.ArenaAllocator,
    vault: zg_notes.Vault,
    ix: *NoteIndex,
    search: *SearchIndex,

    /// Folder-relative note paths to their ids.
    ids_mutex: Io.Mutex = .init,
    ids: std.StringHashMapUnmanaged(FileId) = .empty,
    next_id: u32 = 0,

    /// Jobs on workers; `idle` is set when none runs.
    jobs_mutex: Io.Mutex = .init,
    jobs: u32 = 0,
    idle: Io.Event = .is_set,
    closing: std.atomic.Value(bool) = .init(false),
    /// What posted wakes call (it outlives the service).
    waker: *Waker = undefined,
    state: std.atomic.Value(State) = .init(.scanning),
    notes: std.atomic.Value(u32) = .init(0),

    sidebar_model: *zg_notes_ui.NotesSidebarModel = undefined,
    sidebar: *zg_notes_ui.SidebarView = undefined,
    search_model: *zg_notes_ui.NoteSearchViewModel = undefined,
    search_view: *zg_notes_ui.SearchView = undefined,
    saved: zg_notes_ui.search_view.SavedSearches,
    /// The current editor's note: its folder-relative path (empty: none)
    /// and id (null until the scan reaches it).
    active_rel: std.ArrayList(u8) = .empty,
    active: ?FileId = null,

    /// The notes of folder `root` (absolute); starts the scan.
    pub fn create(gpa: Allocator, io: Io, app: *zg_gui.App, root: []const u8, hooks: Hooks) !*NotesService {
        const s = try gpa.create(NotesService);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .hooks = hooks,
            .root = try gpa.dupe(u8, root),
            .configured = false,
            .arena = .init(gpa),
            .vault = undefined,
            .ix = undefined,
            .search = undefined,
            .saved = .init(gpa),
        };
        s.waker = try gpa.create(Waker);
        s.waker.* = .{ .gpa = gpa, .svc = s };
        errdefer s.waker.release();
        errdefer {
            s.saved.deinit();
            s.arena.deinit();
            gpa.free(s.root);
        }
        const config: ?zg_notes.VaultConfig = blk: {
            var dir = Io.Dir.cwd().openDir(io, root, .{}) catch break :blk null;
            defer dir.close(io);
            break :blk try zg_notes.vault.detectVault(s.arena.allocator(), io, dir);
        };
        s.configured = config != null;
        s.vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = config orelse .{} };
        s.ix = try NoteIndex.init(gpa, io, &.{s.vault});
        errdefer s.ix.deinit();
        const content: zg_notes.index.mentions.ContentSource = .{ .ctx = s, .read = readNote };
        // Before any note is indexed (notes indexed earlier have no text).
        s.search = try SearchIndex.attach(s.ix, .{ .content = content });
        errdefer s.search.deinit();
        const spawn: ports.Spawn = .{ .ctx = s, .run = spawnPort };
        const notify: ports.Notify = .{ .ctx = s, .f = notifyPort };
        const open: ports.OpenPort = .{ .ctx = s, .open = openPort };
        s.sidebar_model = try .init(.{
            .gpa = gpa,
            .io = io,
            .ix = s.ix,
            .vault = &s.vault,
            .content = content,
            .apply = .{ .ctx = s, .apply = applyPort },
            .spawn = spawn,
            .notify = notify,
        });
        errdefer s.sidebar_model.deinit();
        s.sidebar = try .init(gpa, s.sidebar_model, .{ .open = open, .search = .{ .ctx = s, .f = searchHook } });
        errdefer s.sidebar.deinit();
        s.search_model = try .init(.{
            .gpa = gpa,
            .io = io,
            .ix = s.ix,
            .retriever = zg_notes.search.bm25Retriever(s.search, .{}),
            .content = content,
            .spawn = spawn,
            .notify = notify,
            .open = open,
        });
        errdefer s.search_model.deinit();
        s.search_view = try .init(gpa, s.search_model, .{ .saved = &s.saved });
        s.startJob();
        s.app.spawn(scan, .{s});
        return s;
    }

    /// Stops the scan, waits for running jobs, frees everything.
    pub fn destroy(s: *NotesService) void {
        s.closing.store(true, .release);
        s.idle.waitUncancelable(s.io);
        s.search_view.deinit();
        s.search_model.deinit();
        s.sidebar.deinit();
        s.sidebar_model.deinit();
        // Jobs the models started after the wait (none: closing) and
        // their own stale jobs hold the index; wait once more.
        s.idle.waitUncancelable(s.io);
        s.search.deinit();
        s.ix.deinit();
        // UI thread: no wake runs now; ones still posted find no service.
        s.waker.svc = null;
        s.waker.release();
        var it = s.ids.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.ids.deinit(s.gpa);
        s.active_rel.deinit(s.gpa);
        s.saved.deinit();
        s.arena.deinit();
        s.gpa.free(s.root);
        s.gpa.destroy(s);
    }

    /// The vault-relative path of absolute `abs`, or null outside the
    /// folder. Separators are `/`.
    pub fn relOf(s: *const NotesService, buf: []u8, abs: []const u8) ?[]const u8 {
        if (abs.len <= s.root.len + 1 or !std.mem.startsWith(u8, abs, s.root)) return null;
        if (!std.fs.path.isSep(abs[s.root.len])) return null;
        const rel = abs[s.root.len + 1 ..];
        if (rel.len > buf.len) return null;
        @memcpy(buf[0..rel.len], rel);
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, buf[0..rel.len], '\\', '/');
        return buf[0..rel.len];
    }

    /// The id of indexed note `rel`.
    pub fn idOf(s: *NotesService, rel: []const u8) ?FileId {
        s.ids_mutex.lockUncancelable(s.io);
        defer s.ids_mutex.unlock(s.io);
        return s.ids.get(rel);
    }

    /// The id of note `rel`, made on first use. Any thread.
    fn idFor(s: *NotesService, rel: []const u8) !FileId {
        s.ids_mutex.lockUncancelable(s.io);
        defer s.ids_mutex.unlock(s.io);
        const g = try s.ids.getOrPut(s.gpa, rel);
        if (!g.found_existing) {
            g.key_ptr.* = s.gpa.dupe(u8, rel) catch |e| {
                s.ids.removeByPtr(g.key_ptr);
                return e;
            };
            g.value_ptr.* = .{ .index = s.next_id, .gen = 0 };
            s.next_id += 1;
        }
        return g.value_ptr.*;
    }

    /// The editor shows absolute `abs` (null: no file or not an editor):
    /// the sidebar follows it when it is a note.
    pub fn setActive(s: *NotesService, abs: ?[]const u8) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        s.active_rel.clearRetainingCapacity();
        if (abs) |a| if (s.relOf(&buf, a)) |rel| if (s.vault.isNotePath(rel)) {
            s.active_rel.appendSlice(s.gpa, rel) catch s.active_rel.clearRetainingCapacity();
        };
        s.resolveActive();
    }

    fn resolveActive(s: *NotesService) void {
        s.active = if (s.active_rel.items.len > 0) s.idOf(s.active_rel.items) else null;
        s.sidebar_model.setActiveNote(s.active);
    }

    /// Absolute `abs` was written (a save, or a change on disk): its note
    /// is read and indexed again on a worker.
    pub fn fileChanged(s: *NotesService, abs: []const u8) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = s.relOf(&buf, abs) orelse return;
        if (!s.vault.isNotePath(rel)) return;
        const owned = s.gpa.dupe(u8, rel) catch return;
        s.startJob();
        s.app.spawn(reindexJob, .{ s, owned });
    }

    pub fn stateNow(s: *const NotesService) State {
        return s.state.load(.acquire);
    }

    pub fn noteCount(s: *const NotesService) u32 {
        return s.notes.load(.monotonic);
    }

    // ---- jobs ----

    fn startJob(s: *NotesService) void {
        s.jobs_mutex.lockUncancelable(s.io);
        defer s.jobs_mutex.unlock(s.io);
        s.jobs += 1;
        s.idle.reset();
    }

    fn endJob(s: *NotesService) void {
        s.jobs_mutex.lockUncancelable(s.io);
        defer s.jobs_mutex.unlock(s.io);
        s.jobs -= 1;
        if (s.jobs == 0) s.idle.set(s.io);
    }

    /// Walks the folder and indexes every note.
    fn scan(s: *NotesService) void {
        defer s.endJob();
        s.scanErr() catch |e| {
            log.warn("scanning notes in {s}: {t}", .{ s.root, e });
            s.state.store(.failed, .release);
            s.wake();
            return;
        };
        s.state.store(.ready, .release);
        s.wake();
    }

    fn scanErr(s: *NotesService) !void {
        var dir = try Io.Dir.cwd().openDir(s.io, s.root, .{ .iterate = true });
        defer dir.close(s.io);
        var walker = try dir.walkSelectively(s.gpa);
        defer walker.deinit();
        var rel_buf: std.ArrayList(u8) = .empty;
        defer rel_buf.deinit(s.gpa);
        var since_commit: u32 = 0;
        while (try walker.next(s.io)) |e| {
            if (s.closing.load(.acquire)) return;
            switch (e.kind) {
                .directory => if (!skipDir(e.basename)) try walker.enter(s.io, e),
                .file => {
                    rel_buf.clearRetainingCapacity();
                    try rel_buf.appendSlice(s.gpa, e.path);
                    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, rel_buf.items, '\\', '/');
                    const rel = rel_buf.items;
                    if (!s.vault.isNotePath(rel)) continue;
                    const bytes = e.dir.readFileAlloc(s.io, e.basename, s.gpa, .limited(max_note_bytes)) catch continue;
                    defer s.gpa.free(bytes);
                    try s.ix.indexNote(try s.idFor(rel), .of(0), rel, bytes);
                    _ = s.notes.fetchAdd(1, .monotonic);
                    since_commit += 1;
                    if (since_commit == commit_every) {
                        since_commit = 0;
                        try s.ix.commit();
                    }
                },
                else => {},
            }
        }
        try s.ix.commit();
    }

    fn reindexJob(s: *NotesService, rel: []u8) void {
        defer s.endJob();
        defer s.gpa.free(rel);
        if (s.closing.load(.acquire)) return;
        s.reindex(rel) catch |e| log.warn("indexing {s}: {t}", .{ rel, e });
    }

    /// Reads note `rel` and indexes it (or forgets it when it is gone).
    fn reindex(s: *NotesService, rel: []const u8) !void {
        const abs = try std.fs.path.join(s.gpa, &.{ s.root, rel });
        defer s.gpa.free(abs);
        const bytes = Io.Dir.cwd().readFileAlloc(s.io, abs, s.gpa, .limited(max_note_bytes)) catch |e| switch (e) {
            error.FileNotFound => {
                if (s.idOf(rel)) |id| {
                    try s.ix.removeFile(id);
                    try s.ix.commit();
                }
                return;
            },
            else => return e,
        };
        defer s.gpa.free(bytes);
        const known = s.idOf(rel) != null;
        try s.ix.indexNote(try s.idFor(rel), .of(0), rel, bytes);
        try s.ix.commit();
        if (!known) {
            _ = s.notes.fetchAdd(1, .monotonic);
            s.wake();
        }
    }

    /// Asks the UI thread to rebuild (any thread; one call in flight).
    fn wake(s: *NotesService) void {
        if (s.closing.load(.acquire)) return;
        const w = s.waker;
        if (w.posted.swap(true, .acq_rel)) return;
        _ = w.refs.fetchAdd(1, .monotonic);
        s.app.post(.{ .ctx = w, .f = Waker.run }) catch {
            w.posted.store(false, .release);
            _ = w.refs.fetchSub(1, .monotonic);
        };
    }

    /// A posted wake's target: the service until it is destroyed.
    const Waker = struct {
        gpa: Allocator,
        refs: std.atomic.Value(u32) = .init(1),
        posted: std.atomic.Value(bool) = .init(false),
        /// Read and cleared on the UI thread only.
        svc: ?*NotesService,

        fn release(w: *Waker) void {
            if (w.refs.fetchSub(1, .acq_rel) == 1) w.gpa.destroy(w);
        }

        fn run(ctx: *anyopaque, _: *zg_gui.App) void {
            const w: *Waker = @ptrCast(@alignCast(ctx));
            w.posted.store(false, .release);
            if (w.svc) |s| s.onWake();
            w.release();
        }
    };

    fn onWake(s: *NotesService) void {
        // A note indexed after it became current: the sidebar shows it.
        if (s.active == null and s.active_rel.items.len > 0) s.resolveActive();
        s.hooks.changed(s.hooks.ctx);
    }

    // ---- ports ----

    fn readNote(ctx: *anyopaque, gpa: Allocator, id: FileId, path: []const u8) anyerror!?[]u8 {
        _ = id;
        const s: *NotesService = @ptrCast(@alignCast(ctx));
        const abs = try std.fs.path.join(gpa, &.{ s.root, path });
        defer gpa.free(abs);
        return Io.Dir.cwd().readFileAlloc(s.io, abs, gpa, .limited(max_note_bytes)) catch |e| switch (e) {
            error.OutOfMemory => e,
            else => null,
        };
    }

    const Spawned = struct { f: *const fn (arg: *anyopaque) void, arg: *anyopaque };

    fn spawnPort(ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) void {
        const s: *NotesService = @ptrCast(@alignCast(ctx));
        s.startJob();
        s.app.spawn(runSpawned, .{ s, Spawned{ .f = f, .arg = arg } });
    }

    fn runSpawned(s: *NotesService, j: Spawned) void {
        defer s.endJob();
        j.f(j.arg);
    }

    fn notifyPort(ctx: *anyopaque) void {
        const s: *NotesService = @ptrCast(@alignCast(ctx));
        s.wake();
    }

    fn openPort(ctx: *anyopaque, path: []const u8, range: ?[2]u32, to_side: bool) void {
        const s: *NotesService = @ptrCast(@alignCast(ctx));
        const abs = std.fs.path.join(s.gpa, &.{ s.root, path }) catch return;
        defer s.gpa.free(abs);
        s.hooks.open(s.hooks.ctx, abs, range, to_side);
    }

    fn searchHook(ctx: *anyopaque, query: []const u8) void {
        const s: *NotesService = @ptrCast(@alignCast(ctx));
        s.hooks.search(s.hooks.ctx, query);
    }

    /// Sidebar edits (a property, a linked mention, a new note): through
    /// the host's review store, else written here when each file still
    /// holds the text the edit was made from. Indexed at once.
    fn applyPort(ctx: *anyopaque, label: []const u8, changes: []const FileChange) anyerror!u64 {
        const s: *NotesService = @ptrCast(@alignCast(ctx));
        const id: u64 = blk: {
            if (s.hooks.apply) |f| if (try f(s.hooks.ctx, label, changes)) |id| break :blk id;
            try s.writeChanges(changes);
            break :blk 0;
        };
        for (changes) |c| if (s.vault.isNotePath(c.path)) try s.reindex(c.path);
        return id;
    }

    /// Writes `changes` after checking every base against the disk.
    pub fn writeChanges(s: *NotesService, changes: []const FileChange) !void {
        var abs_list: std.ArrayList([]u8) = .empty;
        defer {
            for (abs_list.items) |a| s.gpa.free(a);
            abs_list.deinit(s.gpa);
        }
        const cwd = Io.Dir.cwd();
        for (changes) |c| {
            const abs = try std.fs.path.join(s.gpa, &.{ s.root, c.path });
            try abs_list.append(s.gpa, abs);
            if (c.base) |base| {
                const now = try cwd.readFileAlloc(s.io, abs, s.gpa, .limited(max_note_bytes));
                defer s.gpa.free(now);
                if (!std.mem.eql(u8, now, base)) return error.FileChanged;
            } else if (cwd.access(s.io, abs, .{})) |_| {
                return error.PathAlreadyExists;
            } else |_| {}
        }
        for (changes, abs_list.items) |c, abs| {
            if (c.base == null) if (std.fs.path.dirname(abs)) |d| try cwd.createDirPath(s.io, d);
            try cwd.writeFile(s.io, .{ .sub_path = abs, .data = c.new });
        }
    }
};

/// Folders the scan does not enter.
fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for ([_][]const u8{ "zig-out", "node_modules", "target", "__pycache__" }) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

// ---- tests ----

const testing = std.testing;

const Rec = struct {
    wakes: u32 = 0,
    opened: [256]u8 = undefined,
    opened_len: usize = 0,
    range: ?[2]u32 = null,

    fn open(ctx: *anyopaque, abs: []const u8, range: ?[2]u32, _: bool) void {
        const r: *Rec = @ptrCast(@alignCast(ctx));
        @memcpy(r.opened[0..abs.len], abs);
        r.opened_len = abs.len;
        r.range = range;
    }
    fn search(_: *anyopaque, _: []const u8) void {}
    fn changed(ctx: *anyopaque) void {
        const r: *Rec = @ptrCast(@alignCast(ctx));
        r.wakes += 1;
    }
    fn hooks(r: *Rec) Hooks {
        return .{ .ctx = r, .open = open, .search = search, .changed = changed };
    }
};

fn tmpRoot(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(testing.io, buf)];
}

test "notes service: scans the folder's notes, follows the editor and finds notes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "# Alpha\n\nSee [[b]] for the zebra facts.\n" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.md", .data = "---\ntags: [animal]\n---\n# Bravo\n\nStripes.\n" });
    try tmp.dir.createDirPath(io, "zig-out");
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/c.md", .data = "# Build output\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = 1;\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);

    const t = try zg_gui.testing.TestApp.init(gpa, .{});
    defer t.deinit();
    var rec: Rec = .{};
    const s = try NotesService.create(gpa, io, &t.app, root, rec.hooks());
    defer s.destroy();
    // No runtime: the scan ran inline.
    try testing.expectEqual(State.ready, s.stateNow());
    try testing.expectEqual(@as(u32, 2), s.noteCount());
    try testing.expect(!s.configured);
    try testing.expect(s.idOf("sub/b.md") != null);
    try testing.expect(s.idOf("zig-out/c.md") == null);
    _ = t.app.drainMessages();
    try testing.expect(rec.wakes > 0);

    // The sidebar follows the editor: b's backlinks list a.
    const b_abs = try std.fs.path.join(gpa, &.{ root, "sub", "b.md" });
    defer gpa.free(b_abs);
    s.setActive(b_abs);
    try s.sidebar_model.sync();
    try testing.expectEqualStrings("Bravo", s.sidebar_model.title);
    try testing.expectEqual(@as(usize, 1), s.sidebar_model.backlinks.len);
    try testing.expectEqualStrings("a.md", s.sidebar_model.backlinks[0].path);
    // A file that is not a note clears it.
    const z_abs = try std.fs.path.join(gpa, &.{ root, "main.zig" });
    defer gpa.free(z_abs);
    s.setActive(z_abs);
    try s.sidebar_model.sync();
    try testing.expect(s.sidebar_model.active == null);

    // Search finds a note by its text and opens it in the editor.
    s.search_model.o.debounce_ms = 0;
    s.search_model.setQuery("zebra");
    try s.search_model.sync();
    try testing.expectEqual(@as(usize, 1), s.search_model.shown.rows.len);
    try testing.expectEqualStrings("a.md", s.search_model.shown.rows[0].path);
    s.search_model.openSelected(false);
    try testing.expect(std.mem.endsWith(u8, rec.opened[0..rec.opened_len], "a.md"));
}

test "notes service: a saved note is indexed again; sidebar edits are written and indexed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "# Alpha\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const t = try zg_gui.testing.TestApp.init(gpa, .{});
    defer t.deinit();
    var rec: Rec = .{};
    const s = try NotesService.create(gpa, io, &t.app, root, rec.hooks());
    defer s.destroy();

    // A new note saved from the editor joins the index.
    try tmp.dir.writeFile(io, .{ .sub_path = "new.md", .data = "# New\n\nLinks [[a]].\n" });
    const n_abs = try std.fs.path.join(gpa, &.{ root, "new.md" });
    defer gpa.free(n_abs);
    s.fileChanged(n_abs);
    try testing.expectEqual(@as(u32, 2), s.noteCount());
    const a_abs = try std.fs.path.join(gpa, &.{ root, "a.md" });
    defer gpa.free(a_abs);
    s.setActive(a_abs);
    try s.sidebar_model.sync();
    try testing.expectEqual(@as(usize, 1), s.sidebar_model.backlinks.len);

    // A property set in the sidebar is written to the file (no review
    // store hooked up) and indexed.
    _ = try s.sidebar_model.setProperty("status", .{ .string = "draft" });
    const now = try tmp.dir.readFileAlloc(io, "a.md", gpa, .limited(4096));
    defer gpa.free(now);
    try testing.expect(std.mem.indexOf(u8, now, "status: draft") != null);
    // An edit made from stale text is refused.
    try testing.expectError(error.FileChanged, s.writeChanges(&.{.{ .path = "a.md", .base = "# Alpha\n", .new = "x" }}));
}
