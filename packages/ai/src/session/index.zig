//! `SessionIndex`: the metadata of every session of one workspace
//! (E10.F08.S01.T02), for the session picker and `zg sessions`. Kept in
//! `index.zon` next to the session files, written atomically and at most
//! once a second. A missing or corrupt index is rebuilt from the session
//! files by reading only each header line and the last 4 KiB.
//!
//! Thread-safe: the title worker updates entries while the UI lists them.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const SessionId = proto.SessionId;
pub const Origin = records.Origin;

/// The index file name inside the workspace's sessions directory.
pub const file_name = "index.zon";
/// Version of the `index.zon` layout; another version is rebuilt.
pub const format_version: u32 = 1;
/// Minimum time between two index writes.
pub const debounce_ms: i64 = 1000;
/// Bytes read from the end of a session file when rebuilding.
pub const tail_bytes = 4096;

/// What the index knows about one session. Strings are owned by the index
/// (copied on `upsert`).
pub const SessionMeta = struct {
    id: SessionId,
    title: ?[]const u8 = null,
    /// A name the user gave the session (wins over `title` for display,
    /// and stops automatic titles).
    name: ?[]const u8 = null,
    created_ms: i64,
    updated_ms: i64,
    /// Git branch at the last update.
    branch: ?[]const u8 = null,
    model: []const u8 = "",
    messages: u32 = 0,
    cost_micros: u64 = 0,
    /// The session this one was forked from.
    parent: ?SessionId = null,
    pinned: bool = false,
    origin: Origin = .gui,
    /// Size of the session file.
    bytes: u64 = 0,

    /// The name, else the title, else "".
    pub fn label(m: *const SessionMeta) []const u8 {
        return m.name orelse m.title orelse "";
    }
};

/// Filters shared by the session picker and the CLI. Null fields match all.
pub const Filter = struct {
    branch: ?[]const u8 = null,
    origin: ?Origin = null,
    /// `updated_ms >= since_ms`.
    since_ms: ?i64 = null,
    /// `updated_ms < until_ms`.
    until_ms: ?i64 = null,
    /// Case-insensitive substring of the title or the name.
    text: ?[]const u8 = null,
    pinned: ?bool = null,

    /// Whether `m` passes every set filter.
    pub fn matches(f: Filter, m: *const SessionMeta) bool {
        if (f.branch) |b| if (m.branch == null or !std.mem.eql(u8, b, m.branch.?)) return false;
        if (f.origin) |o| if (o != m.origin) return false;
        if (f.since_ms) |s| if (m.updated_ms < s) return false;
        if (f.until_ms) |u| if (m.updated_ms >= u) return false;
        if (f.pinned) |p| if (p != m.pinned) return false;
        if (f.text) |t| {
            const in_title = if (m.title) |x| std.ascii.indexOfIgnoreCase(x, t) != null else false;
            const in_name = if (m.name) |x| std.ascii.indexOfIgnoreCase(x, t) != null else false;
            if (!in_title and !in_name) return false;
        }
        return true;
    }
};

/// One `index.zon` entry (ids as ULID text).
const Entry = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    name: ?[]const u8 = null,
    created_ms: i64 = 0,
    updated_ms: i64 = 0,
    branch: ?[]const u8 = null,
    model: []const u8 = "",
    messages: u32 = 0,
    cost_micros: u64 = 0,
    parent: ?[]const u8 = null,
    pinned: bool = false,
    origin: Origin = .gui,
    bytes: u64 = 0,
};

const IndexFile = struct {
    version: u32,
    sessions: []const Entry,
};

pub const SessionIndex = struct {
    gpa: Allocator,
    io: Io,
    /// The workspace's sessions directory (borrowed).
    dir: Io.Dir,
    entries: std.ArrayList(SessionMeta) = .empty,
    by_id: std.AutoHashMapUnmanaged(SessionId, u32) = .empty,
    mutex: Io.Mutex = .init,
    dirty: bool = false,
    /// Monotonic ms of the last write (debounce).
    last_save_ms: ?i64 = null,
    /// True when `load` rebuilt the index from the session files.
    rebuilt: bool = false,
    /// Index writes so far (tests check the debounce).
    saves: u32 = 0,

    /// Loads `index.zon` from `dir`, or rebuilds it from the session files
    /// when it is missing, corrupt or of another version.
    pub fn load(gpa: Allocator, io: Io, dir: Io.Dir) !SessionIndex {
        var ix: SessionIndex = .{ .gpa = gpa, .io = io, .dir = dir };
        errdefer ix.deinit();
        if (try ix.readIndex()) return ix;
        try ix.rebuild();
        return ix;
    }

    pub fn deinit(ix: *SessionIndex) void {
        for (ix.entries.items) |*m| freeStrings(ix.gpa, m);
        ix.entries.deinit(ix.gpa);
        ix.by_id.deinit(ix.gpa);
    }

    /// Number of sessions.
    pub fn count(ix: *SessionIndex) usize {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        return ix.entries.items.len;
    }

    /// Inserts or replaces the entry of `m.id` (strings are copied) and
    /// marks the index dirty; `flush` writes it.
    pub fn upsert(ix: *SessionIndex, m: SessionMeta) Allocator.Error!void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        try ix.upsertLocked(m);
    }

    fn upsertLocked(ix: *SessionIndex, m: SessionMeta) Allocator.Error!void {
        var copy = m;
        try dupeStrings(ix.gpa, &copy);
        errdefer freeStrings(ix.gpa, &copy);
        if (ix.by_id.get(m.id)) |i| {
            freeStrings(ix.gpa, &ix.entries.items[i]);
            ix.entries.items[i] = copy;
        } else {
            try ix.entries.ensureUnusedCapacity(ix.gpa, 1);
            try ix.by_id.put(ix.gpa, m.id, @intCast(ix.entries.items.len));
            ix.entries.appendAssumeCapacity(copy);
        }
        ix.dirty = true;
    }

    /// Sets the title of `id` unless the user named it. False when the
    /// session is unknown or named.
    pub fn setTitle(ix: *SessionIndex, id: SessionId, title: []const u8) Allocator.Error!bool {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        const i = ix.by_id.get(id) orelse return false;
        const m = &ix.entries.items[i];
        if (m.name != null) return false;
        const t = try ix.gpa.dupe(u8, title);
        if (m.title) |old| ix.gpa.free(old);
        m.title = t;
        ix.dirty = true;
        return true;
    }

    /// A copy of the entry of `id` (strings borrowed from the index until
    /// the next update of that entry).
    pub fn get(ix: *SessionIndex, id: SessionId) ?SessionMeta {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        const i = ix.by_id.get(id) orelse return null;
        return ix.entries.items[i];
    }

    /// Removes the entry of `id`; true when it existed.
    pub fn remove(ix: *SessionIndex, id: SessionId) bool {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        return ix.removeLocked(id);
    }

    fn removeLocked(ix: *SessionIndex, id: SessionId) bool {
        const kv = ix.by_id.fetchRemove(id) orelse return false;
        const i = kv.value;
        freeStrings(ix.gpa, &ix.entries.items[i]);
        _ = ix.entries.swapRemove(i);
        if (i < ix.entries.items.len) ix.by_id.putAssumeCapacity(ix.entries.items[i].id, i);
        ix.dirty = true;
        return true;
    }

    /// Appends the entries passing `f` to `out`, most recently updated
    /// first. The pointers stay valid until the index changes.
    pub fn list(ix: *SessionIndex, gpa: Allocator, f: Filter, out: *std.ArrayList(*const SessionMeta)) Allocator.Error!void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        const start = out.items.len;
        for (ix.entries.items) |*m| if (f.matches(m)) try out.append(gpa, m);
        std.mem.sort(*const SessionMeta, out.items[start..], {}, newerFirst);
    }

    fn newerFirst(_: void, a: *const SessionMeta, b: *const SessionMeta) bool {
        if (a.updated_ms != b.updated_ms) return a.updated_ms > b.updated_ms;
        return a.id > b.id;
    }

    /// Writes the index when it is dirty and the last write was at least
    /// `debounce_ms` ago. Returns whether it wrote.
    pub fn flush(ix: *SessionIndex) !bool {
        const now = Io.Timestamp.now(ix.io, .awake).toMilliseconds();
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        if (!ix.dirty) return false;
        if (ix.last_save_ms) |t| if (now - t < debounce_ms) return false;
        try ix.writeLocked(now);
        return true;
    }

    /// Writes the index now (on exit, or after a sweep).
    pub fn save(ix: *SessionIndex) !void {
        const now = Io.Timestamp.now(ix.io, .awake).toMilliseconds();
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        try ix.writeLocked(now);
    }

    fn writeLocked(ix: *SessionIndex, now: i64) !void {
        var arena: std.heap.ArenaAllocator = .init(ix.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list_ = try a.alloc(Entry, ix.entries.items.len);
        for (ix.entries.items, list_) |m, *e| {
            const id = proto.agent_ref.format(m.id);
            e.* = .{
                .id = try a.dupe(u8, &id),
                .title = m.title,
                .name = m.name,
                .created_ms = m.created_ms,
                .updated_ms = m.updated_ms,
                .branch = m.branch,
                .model = m.model,
                .messages = m.messages,
                .cost_micros = m.cost_micros,
                .parent = if (m.parent) |p| try a.dupe(u8, &proto.agent_ref.format(p)) else null,
                .pinned = m.pinned,
                .origin = m.origin,
                .bytes = m.bytes,
            };
        }
        var out: Io.Writer.Allocating = .init(a);
        std.zon.stringify.serialize(IndexFile{ .version = format_version, .sessions = list_ }, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
        try out.writer.writeByte('\n');
        try writeAtomic(ix.io, ix.dir, file_name, out.written());
        ix.dirty = false;
        ix.last_save_ms = now;
        ix.saves += 1;
    }

    /// Reads `index.zon`; false when it is missing or unusable.
    fn readIndex(ix: *SessionIndex) !bool {
        const bytes = ix.dir.readFileAlloc(ix.io, file_name, ix.gpa, .limited(256 << 20)) catch |e| switch (e) {
            error.FileNotFound => return false,
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer ix.gpa.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(ix.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try a.dupeZ(u8, bytes);
        const file = std.zon.parse.fromSliceAlloc(IndexFile, a, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => return false,
        };
        if (file.version != format_version) return false;
        for (file.sessions) |e| {
            const id = proto.agent_ref.parse(e.id) catch return ix.reset();
            const parent: ?SessionId = if (e.parent) |p| proto.agent_ref.parse(p) catch return ix.reset() else null;
            try ix.upsertLocked(.{
                .id = id,
                .title = e.title,
                .name = e.name,
                .created_ms = e.created_ms,
                .updated_ms = e.updated_ms,
                .branch = e.branch,
                .model = e.model,
                .messages = e.messages,
                .cost_micros = e.cost_micros,
                .parent = parent,
                .pinned = e.pinned,
                .origin = e.origin,
                .bytes = e.bytes,
            });
        }
        ix.dirty = false;
        return true;
    }

    /// Drops every entry (before a rebuild); returns false.
    fn reset(ix: *SessionIndex) bool {
        for (ix.entries.items) |*m| freeStrings(ix.gpa, m);
        ix.entries.clearRetainingCapacity();
        ix.by_id.clearRetainingCapacity();
        return false;
    }

    /// Rebuilds the index from the `.jsonl` files of the directory.
    pub fn rebuild(ix: *SessionIndex) !void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        _ = ix.reset();
        var it = ix.dir.iterate();
        while (try it.next(ix.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".jsonl")) continue;
            var arena: std.heap.ArenaAllocator = .init(ix.gpa);
            defer arena.deinit();
            const m = scanFile(arena.allocator(), ix.io, ix.dir, e.name) catch continue;
            try ix.upsertLocked(m);
        }
        ix.rebuilt = true;
        ix.dirty = true;
    }
};

/// Reads the header line and the last `tail_bytes` of one session file.
pub fn scanFile(arena: Allocator, io: Io, dir: Io.Dir, name: []const u8) !SessionMeta {
    const f = try dir.openFile(io, name, .{});
    defer f.close(io);
    const size = try f.length(io);
    // Header: the first line (a few hundred bytes; grow if needed).
    var hbuf: std.ArrayList(u8) = .empty;
    var off: u64 = 0;
    const hend: usize = while (off < size and hbuf.items.len < 1 << 20) {
        const want: usize = @intCast(@min(4096, size - off));
        try hbuf.ensureUnusedCapacity(arena, want);
        const n = try f.readPositionalAll(io, hbuf.unusedCapacitySlice()[0..want], off);
        if (n == 0) return error.InvalidSession;
        const before = hbuf.items.len;
        hbuf.items.len += n;
        off += n;
        if (std.mem.indexOfScalarPos(u8, hbuf.items, before, '\n')) |i| break i;
    } else return error.InvalidSession;
    const hline = records.decode(arena, hbuf.items[0..hend]) catch return error.InvalidSession;
    if (hline.record != .header) return error.InvalidSession;
    const h = hline.record.header;
    var m: SessionMeta = .{
        .id = h.session,
        .created_ms = h.created_ms,
        .updated_ms = h.created_ms,
        .model = h.model,
        .parent = if (h.parent) |p| p.session else null,
        .origin = h.origin,
        .bytes = size,
    };
    // Tail: complete lines of the last `tail_bytes`.
    const tstart = if (size > tail_bytes) size - tail_bytes else hend + 1;
    if (tstart >= size) return m;
    const tbuf = try arena.alloc(u8, @intCast(size - tstart));
    const n = try f.readPositionalAll(io, tbuf, tstart);
    var text = tbuf[0..n];
    if (tstart > hend + 1) {
        // Skip the partial first line.
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return m;
        text = text[nl + 1 ..];
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const line = records.decode(arena, l) catch continue;
        if (line.t > m.updated_ms) m.updated_ms = line.t;
        switch (line.record) {
            .title => |t| m.title = t,
            .usage => |u| m.model = u.model,
            else => {},
        }
    }
    return m;
}

fn dupeStrings(gpa: Allocator, m: *SessionMeta) Allocator.Error!void {
    const orig = m.*;
    m.title = null;
    m.name = null;
    m.branch = null;
    m.model = "";
    errdefer freeStrings(gpa, m);
    if (orig.title) |t| m.title = try gpa.dupe(u8, t);
    if (orig.name) |t| m.name = try gpa.dupe(u8, t);
    if (orig.branch) |t| m.branch = try gpa.dupe(u8, t);
    m.model = try gpa.dupe(u8, orig.model);
}

fn freeStrings(gpa: Allocator, m: *SessionMeta) void {
    if (m.title) |t| gpa.free(t);
    if (m.name) |t| gpa.free(t);
    if (m.branch) |t| gpa.free(t);
    gpa.free(m.model);
    m.title = null;
    m.name = null;
    m.branch = null;
    m.model = "";
}

/// Atomic replace of `dir/name` (temp file, then rename; on Windows the
/// rename is retried a few times because a reader may briefly hold it).
pub fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var af = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        af.replace(io) catch |err| switch (err) {
            error.AccessDenied => if (builtin.os.tag == .windows and attempt < 3) {
                try io.sleep(.fromMilliseconds(10), .awake);
                continue;
            } else return err,
            else => return err,
        };
        return;
    }
}
