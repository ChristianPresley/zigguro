//! The Windows watcher: one recursive `ReadDirectoryChangesW` per root,
//! overlapped on an I/O completion port that a dedicated thread drains.
//! Each root alternates two change buffers so the next read is queued
//! before the last one is parsed. Renames pair `RENAMED_OLD_NAME` with the
//! following `RENAMED_NEW_NAME`; an old name left alone for 10 ms is a
//! move out. A zero-byte completion or `ERROR_NOTIFY_ENUM_DIR` means the
//! buffer overflowed: the root needs a rescan. Ignore filtering happens
//! after the fact (the kernel watches the whole tree), with each ancestor
//! directory's decision cached per root. Directories that appear are
//! scanned, so their contents are reported like on Linux.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const api = @import("api.zig");
const Coalescer = @import("coalesce.zig").Coalescer;
const Wake = @import("../queue/wake.zig").Wake;
const NativeHandle = @import("../queue/wake.zig").NativeHandle;
const t = @import("../win32/bindings/types.zig");
const k32 = if (builtin.os.tag == .windows) @import("../win32/bindings/kernel32.zig") else struct {};

const FsEvent = api.FsEvent;
const RootId = api.RootId;

/// `FILE_ACTION_*` values (also in kernel32.zig, which builds only on
/// Windows; the parser tests run everywhere).
pub const Action = enum(u32) {
    /// FILE_ACTION_ADDED.
    added = 1,
    /// FILE_ACTION_REMOVED.
    removed = 2,
    /// FILE_ACTION_MODIFIED.
    modified = 3,
    /// FILE_ACTION_RENAMED_OLD_NAME.
    renamed_old = 4,
    /// FILE_ACTION_RENAMED_NEW_NAME.
    renamed_new = 5,
    _,
};

/// One parsed `FILE_NOTIFY_INFORMATION` record.
pub const Record = struct {
    /// What happened.
    action: Action,
    /// Root-relative, `/`-separated WTF-8 path.
    path: []const u8,
};

/// Walks a `FILE_NOTIFY_INFORMATION` chain. Names are converted into
/// `name_buf` (valid until the next call); malformed records end the walk.
pub const Records = struct {
    bytes: []const u8,
    off: ?usize = 0,
    /// Room for the longest name (32 Ki UTF-16 units, 3 bytes each).
    name_buf: [3 * 32 * 1024]u8 = undefined,
    units: [32 * 1024]u16 = undefined,

    /// The next record, or null at the end of the chain.
    pub fn next(r: *Records) ?Record {
        const off = r.off orelse return null;
        const head = @sizeOf(t.FILE_NOTIFY_INFORMATION);
        if (off + head > r.bytes.len) return r.end();
        const next_off = std.mem.readInt(u32, r.bytes[off..][0..4], .little);
        const action = std.mem.readInt(u32, r.bytes[off + 4 ..][0..4], .little);
        const name_len = std.mem.readInt(u32, r.bytes[off + 8 ..][0..4], .little);
        if (name_len % 2 != 0 or name_len / 2 > r.units.len or off + head + name_len > r.bytes.len) return r.end();
        const n = name_len / 2;
        @memcpy(std.mem.sliceAsBytes(r.units[0..n]), r.bytes[off + head ..][0..name_len]);
        const len = std.unicode.wtf16LeToWtf8(&r.name_buf, r.units[0..n]);
        const path = r.name_buf[0..len];
        std.mem.replaceScalar(u8, path, '\\', '/');
        r.off = if (next_off == 0) null else off + next_off;
        return .{ .action = @enumFromInt(action), .path = path };
    }

    fn end(r: *Records) ?Record {
        r.off = null;
        return null;
    }
};

/// How long an unmatched old name waits for its new name.
const move_pair_ns: u64 = 10 * std.time.ns_per_ms;
/// Completion key that stops the thread.
const stop_key = std.math.maxInt(usize);
/// Most cached ancestor decisions per root before the cache is reset.
const max_cached_dirs = 64 * 1024;

const notify_filter: u32 = 0x001 | 0x002 | 0x004 | 0x008 | 0x010 | 0x040; // FILE_NAME | DIR_NAME | ATTRIBUTES | SIZE | LAST_WRITE | CREATION

const Root = struct {
    id: RootId,
    /// UTF-8 absolute path without a trailing separator.
    abs: []u8,
    filter: *const api.IgnoreFilter,
    dir: t.HANDLE,
    ov: t.OVERLAPPED = .{},
    /// Two buffers of `buf_len` bytes each, DWORD aligned.
    bufs: []align(4) u8,
    buf_len: u32,
    cur: u1 = 0,
    /// A read is queued (it must complete before the buffers are freed).
    pending: bool = false,
    closing: bool = false,
    /// An old name waiting for its new name.
    old: ?[]u8 = null,
    old_at: u64 = 0,
    /// Ancestor directory → ignored.
    ignored_dirs: std.StringHashMapUnmanaged(bool) = .empty,

    fn clearCache(r: *Root, gpa: std.mem.Allocator) void {
        var it = r.ignored_dirs.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        r.ignored_dirs.clearRetainingCapacity();
    }
};

/// The ReadDirectoryChangesW watcher state behind `api.Watcher`.
pub const Rdcw = struct {
    gpa: std.mem.Allocator,
    io: Io,
    opts: api.WatchOptions,
    iocp: t.HANDLE,
    thread: std.Thread = undefined,
    ready_wake: Wake,
    mutex: Io.Mutex = .init,
    roots: std.AutoArrayHashMapUnmanaged(u32, *Root) = .empty,
    next_root: u32 = 0,
    // Watcher-thread state.
    coalescer: Coalescer,
    records: *Records,
    // Shared ready batch (mutex).
    ready: std.ArrayList(FsEvent) = .empty,
    ready_arena: std.heap.ArenaAllocator,
    delivered_arena: std.heap.ArenaAllocator,

    /// Creates the completion port and starts the watcher thread.
    pub fn init(gpa: std.mem.Allocator, io: Io, opts: api.WatchOptions) api.Error!*Rdcw {
        const iocp = k32.CreateIoCompletionPort(k32.INVALID_HANDLE_VALUE, null, 0, 1) orelse return error.SystemResources;
        errdefer _ = k32.CloseHandle(iocp);
        const self = try gpa.create(Rdcw);
        errdefer gpa.destroy(self);
        const records = try gpa.create(Records);
        errdefer gpa.destroy(records);
        var ready_wake = Wake.init(io) catch return error.SystemResources;
        errdefer ready_wake.deinit();
        self.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .iocp = iocp,
            .ready_wake = ready_wake,
            .coalescer = .init(gpa, opts.debounce_ms),
            .records = records,
            .ready_arena = .init(gpa),
            .delivered_arena = .init(gpa),
        };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return error.SystemResources;
        return self;
    }

    /// Stops the thread (cancelling every read) and frees all state.
    pub fn deinit(self: *Rdcw) void {
        _ = k32.PostQueuedCompletionStatus(self.iocp, 0, stop_key, null);
        self.thread.join();
        const gpa = self.gpa;
        for (self.roots.values()) |r| self.freeRoot(r);
        self.roots.deinit(gpa);
        self.coalescer.deinit();
        self.ready.deinit(gpa);
        self.ready_arena.deinit();
        self.delivered_arena.deinit();
        _ = k32.CloseHandle(self.iocp);
        self.ready_wake.deinit();
        gpa.destroy(self.records);
        gpa.destroy(self);
    }

    /// See `api.Watcher.addRoot`.
    pub fn addRoot(self: *Rdcw, root: []const u8, filter: *const api.IgnoreFilter) api.Error!RootId {
        const abs = try self.gpa.dupe(u8, std.mem.trimEnd(u8, root, "/\\"));
        errdefer self.gpa.free(abs);
        var wbuf: [wide_cap]u16 = undefined;
        const wpath = widePath(&wbuf, abs, "") orelse return error.NotFound;
        const attrs = k32.GetFileAttributesW(wpath);
        if (attrs == k32.INVALID_FILE_ATTRIBUTES or attrs & k32.FILE_ATTRIBUTE_DIRECTORY == 0) return error.NotFound;
        const dir = k32.CreateFileW(wpath, k32.FILE_LIST_DIRECTORY, k32.FILE_SHARE_ALL, null, k32.OPEN_EXISTING, k32.FILE_FLAG_BACKUP_SEMANTICS | k32.FILE_FLAG_OVERLAPPED, null);
        if (dir == k32.INVALID_HANDLE_VALUE) return switch (k32.GetLastError()) {
            k32.ERROR_FILE_NOT_FOUND, k32.ERROR_PATH_NOT_FOUND, k32.ERROR_DIRECTORY => error.NotFound,
            else => error.SystemResources,
        };
        errdefer _ = k32.CloseHandle(dir);
        const buf_len = std.mem.alignForward(u32, std.math.clamp(self.opts.rdcw_buffer_bytes, 1024, 64 * 1024), 4);
        const bufs = try self.gpa.alignedAlloc(u8, .@"4", 2 * @as(usize, buf_len));
        errdefer self.gpa.free(bufs);
        const r = try self.gpa.create(Root);
        errdefer self.gpa.destroy(r);

        self.lock();
        defer self.unlock();
        const id = self.next_root;
        r.* = .{ .id = @enumFromInt(id), .abs = abs, .filter = filter, .dir = dir, .bufs = bufs, .buf_len = buf_len };
        if (k32.CreateIoCompletionPort(dir, self.iocp, id, 0) == null) return error.SystemResources;
        try self.roots.put(self.gpa, id, r);
        if (!self.issue(r)) {
            _ = self.roots.swapRemove(id);
            return error.SystemResources;
        }
        self.next_root += 1;
        return r.id;
    }

    /// See `api.Watcher.removeRoot`. The root is freed once its read
    /// completes as cancelled.
    pub fn removeRoot(self: *Rdcw, id: RootId) void {
        self.lock();
        defer self.unlock();
        const r = self.roots.get(@intFromEnum(id)) orelse return;
        if (r.closing) return;
        r.closing = true;
        if (r.pending) {
            _ = k32.CancelIoEx(r.dir, &r.ov);
        } else {
            _ = self.roots.swapRemove(@intFromEnum(id));
            self.freeRoot(r);
        }
    }

    /// See `api.Watcher.poll`.
    pub fn poll(self: *Rdcw, out: []FsEvent) usize {
        self.lock();
        defer self.unlock();
        _ = self.delivered_arena.reset(.retain_capacity);
        const a = self.delivered_arena.allocator();
        var n: usize = 0;
        while (n < out.len and n < self.ready.items.len) : (n += 1) {
            const e = self.ready.items[n];
            out[n] = e;
            out[n].path = a.dupe(u8, e.path) catch break;
            if (e.old_path) |o| out[n].old_path = a.dupe(u8, o) catch break;
        }
        self.ready.replaceRangeAssumeCapacity(0, n, &.{});
        if (self.ready.items.len == 0) {
            self.ready.clearRetainingCapacity();
            _ = self.ready_arena.reset(.retain_capacity);
            self.ready_wake.consume();
        }
        return n;
    }

    /// See `api.Watcher.waitHandle`.
    pub fn waitHandle(self: *Rdcw) NativeHandle {
        return self.ready_wake.handle();
    }

    /// See `api.Watcher.wait`.
    pub fn wait(self: *Rdcw, timeout_ns: ?u64) bool {
        return self.ready_wake.wait(timeout_ns);
    }

    /// See `api.Watcher.limits`: Windows has no watch limit; each root is
    /// one watch.
    pub fn limits(self: *Rdcw) api.Limits {
        self.lock();
        defer self.unlock();
        return .{ .max_user_watches = null, .watches_in_use = @intCast(self.roots.count()) };
    }

    fn lock(self: *Rdcw) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Rdcw) void {
        self.mutex.unlock(self.io);
    }

    fn freeRoot(self: *Rdcw, r: *Root) void {
        const gpa = self.gpa;
        _ = k32.CloseHandle(r.dir);
        // A read whose cancellation never completed may still write into
        // the root's OVERLAPPED and buffers: leak them rather than reuse.
        if (r.pending) return;
        r.clearCache(gpa);
        r.ignored_dirs.deinit(gpa);
        if (r.old) |o| gpa.free(o);
        gpa.free(r.bufs);
        gpa.free(r.abs);
        gpa.destroy(r);
    }

    /// Queues the next read into the current buffer. Mutex held.
    fn issue(self: *Rdcw, r: *Root) bool {
        _ = self;
        r.ov = .{};
        const buf = r.bufs[@as(usize, r.cur) * r.buf_len ..][0..r.buf_len];
        r.pending = k32.ReadDirectoryChangesW(r.dir, buf.ptr, r.buf_len, 1, notify_filter, null, &r.ov, null) != 0;
        return r.pending;
    }

    // ---- watcher thread ----

    fn now(self: *Rdcw) u64 {
        return @intCast(@max(0, Io.Clock.awake.now(self.io).nanoseconds));
    }

    fn run(self: *Rdcw) void {
        while (true) {
            var timeout = self.coalescer.timeUntilReady(self.now());
            if (self.anyOld()) timeout = @min(timeout orelse move_pair_ns, move_pair_ns);
            const ms: u32 = if (timeout) |ns| @intCast(@min((ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, 60_000)) else k32.INFINITE;
            var bytes: u32 = 0;
            var key: usize = 0;
            var ov: ?*t.OVERLAPPED = null;
            const ok = k32.GetQueuedCompletionStatus(self.iocp, &bytes, &key, &ov, ms) != 0;
            const err = if (ok) 0 else k32.GetLastError();
            if (ov == null and key == stop_key and ok) return self.shutdown();
            if (ov != null) self.complete(key, ok, err, bytes) catch {};
            self.flushOld(self.now(), false) catch {};
            self.deliver(self.now()) catch {};
        }
    }

    /// Cancels every read and waits (up to 2 s) for the cancellations.
    fn shutdown(self: *Rdcw) void {
        self.lock();
        for (self.roots.values()) |r| {
            r.closing = true;
            if (r.pending) _ = k32.CancelIoEx(r.dir, &r.ov);
        }
        self.unlock();
        var waited: u32 = 0;
        while (self.anyPending() and waited < 20) : (waited += 1) {
            var bytes: u32 = 0;
            var key: usize = 0;
            var ov: ?*t.OVERLAPPED = null;
            _ = k32.GetQueuedCompletionStatus(self.iocp, &bytes, &key, &ov, 100);
            if (ov == null) continue;
            self.lock();
            defer self.unlock();
            if (self.roots.get(@intCast(key))) |r| r.pending = false;
        }
    }

    fn anyPending(self: *Rdcw) bool {
        self.lock();
        defer self.unlock();
        for (self.roots.values()) |r| if (r.pending) return true;
        return false;
    }

    fn anyOld(self: *Rdcw) bool {
        self.lock();
        defer self.unlock();
        for (self.roots.values()) |r| if (r.old != null) return true;
        return false;
    }

    fn complete(self: *Rdcw, key: usize, ok: bool, err: u32, bytes: u32) error{OutOfMemory}!void {
        const tnow = self.now();
        self.lock();
        defer self.unlock();
        const r = self.roots.get(@intCast(key)) orelse return;
        r.pending = false;
        if (r.closing) {
            _ = self.roots.swapRemove(@intCast(key));
            self.freeRoot(r);
            return;
        }
        if (!ok) {
            if (err == k32.ERROR_NOTIFY_ENUM_DIR) {
                try self.coalescer.add(.{ .root = r.id, .kind = .rescan_required, .path = "", .is_dir = true, .reason = .overflow }, tnow);
                if (self.issue(r)) return;
            }
            // The root was deleted, renamed or unmounted.
            return self.coalescer.add(.{ .root = r.id, .kind = .rescan_required, .path = "", .is_dir = true, .reason = .root_gone }, tnow);
        }
        if (bytes == 0) {
            try self.coalescer.add(.{ .root = r.id, .kind = .rescan_required, .path = "", .is_dir = true, .reason = .overflow }, tnow);
            if (!self.issue(r)) try self.coalescer.add(.{ .root = r.id, .kind = .rescan_required, .path = "", .is_dir = true, .reason = .root_gone }, tnow);
            return;
        }
        const filled = r.bufs[@as(usize, r.cur) * r.buf_len ..][0..@min(bytes, r.buf_len)];
        r.cur ^= 1;
        const reissued = self.issue(r);
        self.records.bytes = filled;
        self.records.off = 0;
        while (self.records.next()) |rec| try self.handle(r, rec, tnow);
        if (!reissued) try self.coalescer.add(.{ .root = r.id, .kind = .rescan_required, .path = "", .is_dir = true, .reason = .root_gone }, tnow);
    }

    /// One change record. Mutex held.
    fn handle(self: *Rdcw, r: *Root, rec: Record, tnow: u64) error{OutOfMemory}!void {
        if (rec.path.len == 0) return;
        switch (rec.action) {
            .added => {
                const is_dir = self.isDir(r, rec.path);
                if (self.ignoredPath(r, rec.path, is_dir orelse false)) return;
                try self.coalescer.add(.{ .root = r.id, .kind = .created, .path = rec.path, .is_dir = is_dir }, tnow);
                if (is_dir == true) try self.scanNew(r, rec.path, tnow);
            },
            .removed => {
                try self.flushRootOld(r, tnow);
                if (self.ignoredPath(r, rec.path, false)) return;
                try self.coalescer.add(.{ .root = r.id, .kind = .removed, .path = rec.path }, tnow);
            },
            .modified => {
                const is_dir = self.isDir(r, rec.path);
                // A directory's times change with its entries, which are
                // reported themselves.
                if (is_dir == true) return;
                if (self.ignoredPath(r, rec.path, false)) return;
                try self.coalescer.add(.{ .root = r.id, .kind = .modified, .path = rec.path, .is_dir = is_dir }, tnow);
            },
            .renamed_old => {
                try self.flushRootOld(r, tnow);
                r.old = try self.gpa.dupe(u8, rec.path);
                r.old_at = tnow;
            },
            .renamed_new => {
                const is_dir = self.isDir(r, rec.path);
                const old = r.old;
                r.old = null;
                defer if (old) |o| self.gpa.free(o);
                const new_ignored = self.ignoredPath(r, rec.path, is_dir orelse false);
                const old_kept = if (old) |o| !self.ignoredPath(r, o, is_dir orelse false) else false;
                if (new_ignored) {
                    if (old_kept) try self.coalescer.add(.{ .root = r.id, .kind = .removed, .path = old.?, .is_dir = is_dir }, tnow);
                    return;
                }
                if (old_kept) {
                    try self.coalescer.add(.{ .root = r.id, .kind = .renamed, .path = rec.path, .old_path = old.?, .is_dir = is_dir }, tnow);
                } else {
                    try self.coalescer.add(.{ .root = r.id, .kind = .created, .path = rec.path, .is_dir = is_dir }, tnow);
                    if (is_dir == true) try self.scanNew(r, rec.path, tnow);
                }
            },
            _ => {},
        }
    }

    fn flushRootOld(self: *Rdcw, r: *Root, tnow: u64) error{OutOfMemory}!void {
        const o = r.old orelse return;
        r.old = null;
        defer self.gpa.free(o);
        if (!self.ignoredPath(r, o, false)) try self.coalescer.add(.{ .root = r.id, .kind = .removed, .path = o }, tnow);
    }

    /// Old names that found no new name within 10 ms (or all with `all`)
    /// become removals.
    fn flushOld(self: *Rdcw, tnow: u64, all: bool) error{OutOfMemory}!void {
        self.lock();
        defer self.unlock();
        for (self.roots.values()) |r| {
            if (r.old != null and (all or tnow -| r.old_at >= move_pair_ns)) try self.flushRootOld(r, tnow);
        }
    }

    /// Whether `rel` or one of its ancestor directories is ignored.
    fn ignoredPath(self: *Rdcw, r: *Root, rel: []const u8, is_dir: bool) bool {
        if (r.ignored_dirs.count() >= max_cached_dirs) r.clearCache(self.gpa);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| : (i = slash + 1) {
            const dir = rel[0..slash];
            const ignored = r.ignored_dirs.get(dir) orelse blk: {
                const v = r.filter.ignored(dir, true);
                const owned = self.gpa.dupe(u8, dir) catch break :blk v;
                r.ignored_dirs.put(self.gpa, owned, v) catch self.gpa.free(owned);
                break :blk v;
            };
            if (ignored) return true;
        }
        return r.filter.ignored(rel, is_dir);
    }

    /// Whether `rel` is a directory; null when it is gone.
    fn isDir(self: *Rdcw, r: *Root, rel: []const u8) ?bool {
        _ = self;
        var wbuf: [wide_cap]u16 = undefined;
        const w = widePath(&wbuf, r.abs, rel) orelse return null;
        const attrs = k32.GetFileAttributesW(w);
        if (attrs == k32.INVALID_FILE_ATTRIBUTES) return null;
        return attrs & k32.FILE_ATTRIBUTE_DIRECTORY != 0;
    }

    /// Reports every entry under a directory that just appeared (moved in,
    /// or created with contents before its events were read).
    fn scanNew(self: *Rdcw, r: *Root, rel: []const u8, tnow: u64) error{OutOfMemory}!void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var queue: std.ArrayList([]const u8) = .empty;
        try queue.append(arena, try arena.dupe(u8, rel));
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const dir_rel = queue.items[qi];
            const p = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ r.abs, dir_rel });
            std.mem.replaceScalar(u8, p, '/', '\\');
            var dir = Io.Dir.openDirAbsolute(self.io, p, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);
            var it = dir.iterate();
            while (it.next(self.io) catch null) |ent| {
                const child = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_rel, ent.name });
                const is_dir = ent.kind == .directory;
                if (self.ignoredPath(r, child, is_dir)) continue;
                try self.coalescer.add(.{ .root = r.id, .kind = .created, .path = child, .is_dir = is_dir }, tnow);
                if (is_dir) try queue.append(arena, child);
            }
        }
    }

    fn deliver(self: *Rdcw, tnow: u64) error{OutOfMemory}!void {
        if (!self.coalescer.ready(tnow)) return;
        self.lock();
        defer self.unlock();
        var batch: std.ArrayList(FsEvent) = .empty;
        defer batch.deinit(self.gpa);
        try self.coalescer.take(self.ready_arena.allocator(), self.gpa, &batch);
        try self.ready.appendSlice(self.gpa, batch.items);
        if (self.ready.items.len > 0) self.ready_wake.signal();
    }
};

/// UTF-16 units for any path (`\\?\` plus 32 Ki).
const wide_cap = 32 * 1024 + 8;

/// `abs\rel` as a NUL-terminated UTF-16 path, with the `\\?\` prefix when
/// it is too long for the classic APIs; null when it does not fit.
fn widePath(buf: *[wide_cap]u16, abs: []const u8, rel: []const u8) ?[:0]const u16 {
    var utf8: [3 * 32 * 1024]u8 = undefined;
    const joined = if (rel.len == 0)
        std.fmt.bufPrint(&utf8, "{s}", .{abs}) catch return null
    else
        std.fmt.bufPrint(&utf8, "{s}\\{s}", .{ abs, rel }) catch return null;
    std.mem.replaceScalar(u8, joined, '/', '\\');
    var n: usize = 0;
    const long = joined.len >= 248 and !std.mem.startsWith(u8, joined, "\\\\");
    if (long) {
        for ("\\\\?\\") |c| {
            buf[n] = c;
            n += 1;
        }
    }
    const len = std.unicode.wtf8ToWtf16Le(buf[n .. wide_cap - 1], joined) catch return null;
    n += len;
    buf[n] = 0;
    return buf[0..n :0];
}

const testing = std.testing;

/// Builds a FILE_NOTIFY_INFORMATION chain for the parser tests.
fn chain(out: []align(4) u8, entries: []const struct { action: u32, name: []const u16 }) []const u8 {
    var off: usize = 0;
    for (entries, 0..) |e, i| {
        const head = @sizeOf(t.FILE_NOTIFY_INFORMATION);
        const size = std.mem.alignForward(usize, head + e.name.len * 2, 4);
        const next: u32 = if (i + 1 == entries.len) 0 else @intCast(size);
        std.mem.writeInt(u32, out[off..][0..4], next, .little);
        std.mem.writeInt(u32, out[off + 4 ..][0..4], e.action, .little);
        std.mem.writeInt(u32, out[off + 8 ..][0..4], @intCast(e.name.len * 2), .little);
        @memcpy(out[off + head ..][0 .. e.name.len * 2], std.mem.sliceAsBytes(e.name));
        off += size;
    }
    return out[0..off];
}

test "FILE_NOTIFY_INFORMATION chain parser" {
    var buf: [512]u8 align(4) = undefined;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const bytes = chain(&buf, &.{
        .{ .action = 1, .name = L("src\\main.zig") },
        .{ .action = 4, .name = L("a.txt") },
        .{ .action = 5, .name = L("b.txt") },
        // U+1F600 as a surrogate pair, and a lone surrogate kept as WTF-8.
        .{ .action = 3, .name = &.{ 0xD83D, 0xDE00, '.', 'x' } },
        .{ .action = 2, .name = &.{ 'z', 0xD800 } },
    });
    const r = try testing.allocator.create(Records);
    defer testing.allocator.destroy(r);
    r.* = .{ .bytes = bytes };
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    while (r.next()) |rec| try got.print(testing.allocator, "{d}:{s};", .{ @intFromEnum(rec.action), rec.path });
    try testing.expectEqualStrings("1:src/main.zig;4:a.txt;5:b.txt;3:\u{1F600}.x;2:z\xed\xa0\x80;", got.items);

    // Truncated and odd-length records end the walk.
    r.* = .{ .bytes = bytes[0..10] };
    try testing.expectEqual(@as(?Record, null), r.next());
    var odd: [64]u8 align(4) = undefined;
    const ob = chain(&odd, &.{.{ .action = 1, .name = L("ab") }});
    std.mem.writeInt(u32, odd[8..12], 3, .little);
    r.* = .{ .bytes = ob };
    try testing.expectEqual(@as(?Record, null), r.next());
}

// ---- behaviour (Windows, or wine64 with `-fwine`) ----

const tu = @import("test_util.zig");
const NameList = @import("ignore.zig").NameList;

test "rdcw: create/modify/delete" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try tu.Fixture.init(&.none, null);
    defer f.deinit();
    const io = testing.io;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "1" });
    var s: tu.Seen = .{};
    defer s.deinit();
    try tu.collect(&f.w, &s, struct {
        fn ok(x: *const tu.Seen) bool {
            return x.has(.created, "a.txt");
        }
    }.ok);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "22" });
    try tu.collect(&f.w, &s, struct {
        fn ok(x: *const tu.Seen) bool {
            return x.has(.modified, "a.txt");
        }
    }.ok);
    try f.tmp.dir.deleteFile(io, "a.txt");
    try tu.collect(&f.w, &s, struct {
        fn ok(x: *const tu.Seen) bool {
            return x.has(.removed, "a.txt");
        }
    }.ok);
}

test "rdcw: nested directories and their files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try tu.Fixture.init(&.none, null);
    defer f.deinit();
    const io = testing.io;
    try f.tmp.dir.createDirPath(io, "x/y/z");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "x/y/z/deep.txt", .data = "d" });
    var s: tu.Seen = .{};
    defer s.deinit();
    try tu.collect(&f.w, &s, struct {
        fn ok(x: *const tu.Seen) bool {
            return x.hasPath("x") and x.hasPath("x/y") and x.hasPath("x/y/z") and x.hasPath("x/y/z/deep.txt");
        }
    }.ok);
    for (s.list.items) |e| if (std.mem.eql(u8, e.path, "x/y")) try testing.expectEqual(@as(?bool, true), e.is_dir);
}

fn setupRename(d: Io.Dir) !void {
    try d.createDirPath(testing.io, "sub/inner");
    try d.writeFile(testing.io, .{ .sub_path = "old.txt", .data = "o" });
}

test "rdcw: rename within root, move out, move a directory in" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    const io = testing.io;
    try outside.dir.createDirPath(io, "incoming/deep");
    try outside.dir.writeFile(io, .{ .sub_path = "incoming/deep/file", .data = "x" });
    try outside.dir.writeFile(io, .{ .sub_path = "unused", .data = "x" });
    var f = try tu.Fixture.init(&.none, setupRename);
    defer f.deinit();
    try f.tmp.dir.rename("old.txt", f.tmp.dir, "new.txt", io);
    try f.tmp.dir.rename("sub", f.tmp.dir, "moved", io);
    var s: tu.Seen = .{};
    defer s.deinit();
    try tu.collect(&f.w, &s, struct {
        fn ok(x: *const tu.Seen) bool {
            return x.has(.renamed, "new.txt") and x.has(.renamed, "moved");
        }
    }.ok);
    for (s.list.items) |e| if (e.kind == .renamed and std.mem.eql(u8, e.path, "new.txt")) try testing.expectEqualStrings("old.txt", e.old_path.?);
    try f.tmp.dir.rename("new.txt", outside.dir, "gone.txt", io);
    try outside.dir.rename("incoming", f.tmp.dir, "incoming", io);
    try tu.collect(&f.w, &s, struct {
        fn ok(x: *const tu.Seen) bool {
            return x.has(.removed, "new.txt") and x.has(.created, "incoming") and x.hasPath("incoming/deep/file");
        }
    }.ok);
}

fn setupIgnored(d: Io.Dir) !void {
    try d.createDirPath(testing.io, ".git/objects");
    try d.createDirPath(testing.io, "src");
}

/// Wine 9 reports changes at the root's own level but none inside
/// directories that existed when the watch started, so the test that needs
/// those runs only on Windows.
fn underWine() bool {
    const ntdll = k32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse return false;
    return k32.GetProcAddress(ntdll, "wine_get_version") != null;
}

test "rdcw: events under ignored directories are dropped" {
    if (builtin.os.tag != .windows or underWine()) return error.SkipZigTest;
    var nl: NameList = .{ .names = &.{".git"} };
    const filter = nl.filter();
    var f = try tu.Fixture.init(&filter, setupIgnored);
    defer f.deinit();
    const io = testing.io;
    try testing.expectEqual(@as(u32, 1), f.w.limits().watches_in_use);
    try f.tmp.dir.writeFile(io, .{ .sub_path = ".git/objects/x", .data = "x" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "x" });
    var s: tu.Seen = .{};
    defer s.deinit();
    try tu.collect(&f.w, &s, struct {
        fn ok(x: *const tu.Seen) bool {
            return x.hasPath("src/main.zig");
        }
    }.ok);
    for (s.list.items) |e| try testing.expect(!std.mem.startsWith(u8, e.path, ".git"));
}

test "rdcw: a small buffer loses nothing without a rescan" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var w = try api.Watcher.init(testing.allocator, io, .{ .debounce_ms = 5, .rdcw_buffer_bytes = 1024 });
    defer w.deinit();
    _ = try w.addRoot(buf[0..n], &.none);
    const total = 2000;
    var name_buf: [32]u8 = undefined;
    for (0..total) |i| try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "f{d}", .{i}), .data = "x" });
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }
    var rescanned = false;
    var out: [1024]FsEvent = undefined;
    var idle: u32 = 0;
    while (idle < 50 and !rescanned and seen.count() < total) {
        if (!w.wait(10 * std.time.ns_per_ms)) {
            idle += 1;
            continue;
        }
        idle = 0;
        for (out[0..w.poll(&out)]) |e| {
            if (e.kind == .rescan_required) rescanned = true;
            if (e.kind != .created or seen.contains(e.path)) continue;
            try seen.put(testing.allocator, try testing.allocator.dupe(u8, e.path), {});
        }
    }
    try testing.expect(rescanned or seen.count() == total);
}

test "rdcw: removeRoot and a missing root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try tu.Fixture.init(&.none, null);
    defer f.deinit();
    f.w.removeRoot(f.root);
    try testing.expectError(error.NotFound, f.w.addRoot("C:\\zg-no-such-dir-41", &.none));
}
