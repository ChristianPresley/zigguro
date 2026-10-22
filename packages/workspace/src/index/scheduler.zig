//! The indexer scheduler: per-file jobs on background workers, ordered by
//! priority (open, visible, recent, background), pausable and cancelable.
//!
//! Each job stats the file, consults the `Cache` (an unchanged file is
//! re-read only for plugins whose version changed or that lost its data),
//! classifies the content, and hands the bytes to every plugin that wants
//! them. Plugins `commit` after every 256 files or 50 ms, and when the
//! queue drains.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zg_core = @import("zg_core");
const ids = @import("../ids.zig");
const FileId = ids.FileId;
const RootId = ids.RootId;
const path_store = @import("../paths/path_store.zig");
const PathStore = path_store.PathStore;
const Snapshot = path_store.Snapshot;
const Change = path_store.Change;
const cc = @import("content_class.zig");
const ContentClass = cc.ContentClass;
const IndexConfig = cc.IndexConfig;
const plugin_mod = @import("plugin.zig");
const IndexPlugin = plugin_mod.IndexPlugin;
const FileRef = plugin_mod.FileRef;
const PluginOutput = plugin_mod.PluginOutput;
const Cache = @import("cache.zig").Cache;

const log = std.log.scoped(.indexer);

/// Job priority; lower runs first.
pub const Priority = enum(u2) { open = 0, visible = 1, recent = 2, background = 3 };

/// Files per plugin commit.
pub const commit_files = 256;
/// Longest a plugin batch stays uncommitted.
pub const commit_ns = 50 * std.time.ns_per_ms;
/// Files larger than this are memory-mapped instead of read.
pub const mmap_threshold = 4 << 20;

const not_queued: u8 = 0xFF;

const Lane = struct {
    items: std.ArrayList(FileId) = .empty,
    head: usize = 0,

    fn push(l: *Lane, gpa: Allocator, id: FileId) !void {
        if (l.head > 0 and l.head == l.items.items.len) {
            l.items.clearRetainingCapacity();
            l.head = 0;
        }
        try l.items.append(gpa, id);
    }

    fn pop(l: *Lane) ?FileId {
        if (l.head == l.items.items.len) return null;
        const id = l.items.items[l.head];
        l.head += 1;
        return id;
    }
};

/// Counters (read with `stats`).
pub const Stats = struct {
    /// Files handed to at least one plugin.
    indexed: u64 = 0,
    /// Files skipped because the cache said they were unchanged.
    cached: u64 = 0,
    /// Bytes read.
    bytes: u64 = 0,
    /// Jobs waiting.
    queued: u64 = 0,
};

/// The scheduler.
pub const Scheduler = struct {
    gpa: Allocator,
    io: Io,
    cfg: IndexConfig,
    paths: *PathStore,
    cache: ?*Cache,
    roots: std.ArrayList(?Io.Dir) = .empty,
    plugins: std.ArrayList(IndexPlugin) = .empty,
    /// Plugins whose cached results are stale (version changed).
    stale: std.ArrayList(bool) = .empty,

    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    lanes: [4]Lane = @splat(.{}),
    /// `FileId.index` -> lane it is queued in (`not_queued` otherwise).
    lane_of: std.ArrayList(u8) = .empty,
    queued: u64 = 0,
    in_flight: u32 = 0,
    /// `FileId.index` -> path hash of what the plugins hold for it.
    indexed: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    stopping: bool = false,
    paused: std.atomic.Value(bool) = .init(false),

    group: Io.Group = .init,
    started: bool = false,
    workers: u32 = 0,
    commit_lock: Io.Mutex = .init,
    since_commit: std.atomic.Value(u32) = .init(0),
    last_commit: std.atomic.Value(i64) = .init(0),

    n_indexed: std.atomic.Value(u64) = .init(0),
    n_cached: std.atomic.Value(u64) = .init(0),
    n_bytes: std.atomic.Value(u64) = .init(0),

    /// A stopped scheduler over `paths`; `cache` (optional) is consulted
    /// and updated but owned by the caller.
    pub fn init(gpa: Allocator, io: Io, paths: *PathStore, cache: ?*Cache, cfg: IndexConfig) !*Scheduler {
        const s = try gpa.create(Scheduler);
        s.* = .{ .gpa = gpa, .io = io, .cfg = cfg, .paths = paths, .cache = cache };
        return s;
    }

    /// Stops the workers and frees the scheduler.
    pub fn deinit(s: *Scheduler) void {
        s.stop();
        const gpa = s.gpa;
        for (s.roots.items) |d| if (d) |dd| dd.close(s.io);
        s.roots.deinit(gpa);
        s.plugins.deinit(gpa);
        s.stale.deinit(gpa);
        for (&s.lanes) |*l| l.items.deinit(gpa);
        s.lane_of.deinit(gpa);
        s.indexed.deinit(gpa);
        gpa.destroy(s);
    }

    /// Makes `root` readable at `abs_path`.
    pub fn addRoot(s: *Scheduler, root: RootId, abs_path: []const u8) !void {
        const d = try Io.Dir.openDirAbsolute(s.io, abs_path, .{});
        errdefer d.close(s.io);
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        while (s.roots.items.len <= root.index()) try s.roots.append(s.gpa, null);
        if (s.roots.items[root.index()]) |old| old.close(s.io);
        s.roots.items[root.index()] = d;
    }

    /// Registers a plugin (before `start`).
    pub fn register(s: *Scheduler, p: IndexPlugin) !void {
        std.debug.assert(!s.started);
        var stale = false;
        if (s.cache) |c| {
            stale = if (c.pluginVersion(p.name)) |v| v != p.version else c.count() > 0;
            try c.setPluginVersion(p.name, p.version);
        }
        try s.plugins.append(s.gpa, p);
        try s.stale.append(s.gpa, stale);
    }

    /// Starts the workers (`paused` holds them until `resume`).
    pub fn start(s: *Scheduler, paused: bool) void {
        s.paused.store(paused, .release);
        s.started = true;
        const n = s.workerCount();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            s.group.concurrent(s.io, worker, .{s}) catch {
                // No concurrency available: jobs run when `waitIdle` drives them.
                return;
            };
            s.workers += 1;
        }
    }

    fn workerCount(s: *const Scheduler) u32 {
        if (s.cfg.max_workers != 0) return s.cfg.max_workers;
        const cpus = std.Thread.getCpuCount() catch 2;
        return @intCast(@max(1, cpus / 2));
    }

    /// Stops the workers; queued jobs stay queued.
    pub fn stop(s: *Scheduler) void {
        if (!s.started) return;
        s.lock.lockUncancelable(s.io);
        s.stopping = true;
        s.cond.broadcast(s.io);
        s.lock.unlock(s.io);
        s.group.cancel(s.io);
        s.started = false;
        s.workers = 0;
        s.commitAll();
    }

    /// Holds the workers after their current file.
    pub fn pause(s: *Scheduler) void {
        s.paused.store(true, .release);
    }

    /// Releases paused workers.
    pub fn @"resume"(s: *Scheduler) void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        s.paused.store(false, .release);
        s.cond.broadcast(s.io);
    }

    /// Queues `id` (or moves it to a higher lane if already queued).
    pub fn enqueue(s: *Scheduler, id: FileId, prio: Priority) !void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        try s.enqueueLocked(id, prio);
        s.cond.signal(s.io);
    }

    /// Moves queued files to `prio` (or queues them).
    pub fn boost(s: *Scheduler, files: []const FileId, prio: Priority) !void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        for (files) |id| try s.enqueueLocked(id, prio);
        s.cond.broadcast(s.io);
    }

    fn enqueueLocked(s: *Scheduler, id: FileId, prio: Priority) !void {
        const i = id.index;
        while (s.lane_of.items.len <= i) try s.lane_of.append(s.gpa, not_queued);
        const cur = s.lane_of.items[i];
        const want = @intFromEnum(prio);
        if (cur != not_queued and cur <= want) return;
        // A lower-lane entry left behind is skipped when popped.
        try s.lanes[want].push(s.gpa, id);
        if (cur == not_queued) s.queued += 1;
        s.lane_of.items[i] = want;
    }

    /// Queues every file of the snapshot at background priority.
    pub fn enqueueAll(s: *Scheduler, snap: *const Snapshot) !void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        var it = snap.iterFiles(null);
        while (it.next()) |id| try s.enqueueLocked(id, .background);
        s.cond.broadcast(s.io);
    }

    /// Feeds PathStore changes: added and modified files are queued at
    /// background priority, removed ones dropped from every plugin now.
    pub fn onChanges(s: *Scheduler, changes: []const Change) !void {
        const snap = s.paths.snapshot();
        defer snap.release();
        for (changes) |c| switch (c.what) {
            .added, .modified, .renamed => if (snap.contains(c.id) and !snap.info(c.id).isDir()) try s.enqueue(c.id, .background),
            .removed => s.forget(c.id),
        };
    }

    /// Drops a file from every plugin and the cache.
    pub fn forget(s: *Scheduler, id: FileId) void {
        s.lock.lockUncancelable(s.io);
        const kv = s.indexed.fetchRemove(id.index);
        if (id.index < s.lane_of.items.len and s.lane_of.items[id.index] != not_queued) {
            s.lane_of.items[id.index] = not_queued;
            s.queued -= 1;
        }
        s.lock.unlock(s.io);
        const h = (kv orelse return).value;
        const ref: FileRef = .{ .id = id, .root = .of(0), .rel = "", .path_hash = h };
        for (s.plugins.items) |p| p.remove(p.ctx, &ref);
        if (s.cache) |c| c.remove(h);
    }

    /// Blocks until the queue is empty and no job runs (tests, shutdown).
    /// With no workers (no concurrency), runs the jobs itself.
    pub fn waitIdle(s: *Scheduler) void {
        if (s.workers == 0) {
            var w: Worker = .{ .s = s };
            defer w.deinit();
            while (s.next(false) catch null) |id| w.job(id);
            s.commitAll();
            return;
        }
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        while (s.queued > 0 or s.in_flight > 0) s.cond.waitUncancelable(s.io, &s.lock);
    }

    /// Current counters.
    pub fn stats(s: *Scheduler) Stats {
        s.lock.lockUncancelable(s.io);
        const q = s.queued;
        s.lock.unlock(s.io);
        return .{ .indexed = s.n_indexed.load(.monotonic), .cached = s.n_cached.load(.monotonic), .bytes = s.n_bytes.load(.monotonic), .queued = q };
    }

    /// Pops the next job; with `block`, waits for one (or for stop).
    fn next(s: *Scheduler, block: bool) Io.Cancelable!?FileId {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        while (true) {
            if (s.stopping) return null;
            if (!s.paused.load(.acquire)) {
                for (&s.lanes, 0..) |*l, li| while (l.pop()) |id| {
                    if (id.index >= s.lane_of.items.len or s.lane_of.items[id.index] != li) continue; // moved or dropped
                    s.lane_of.items[id.index] = not_queued;
                    s.queued -= 1;
                    s.in_flight += 1;
                    return id;
                };
            }
            if (!block) return null;
            try s.cond.wait(s.io, &s.lock);
        }
    }

    fn done(s: *Scheduler) void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        s.in_flight -= 1;
        if (s.queued == 0 and s.in_flight == 0) s.cond.broadcast(s.io);
    }

    fn worker(s: *Scheduler) Io.Cancelable!void {
        var w: Worker = .{ .s = s };
        defer w.deinit();
        while (true) {
            const id = (s.next(false) catch null) orelse blk: {
                // Queue drained: let plugins publish before sleeping.
                if (s.since_commit.load(.acquire) > 0) s.commitAll();
                break :blk (try s.next(true)) orelse return;
            };
            w.job(id);
            s.maybeCommit();
        }
    }

    fn noteIndexed(s: *Scheduler, id: FileId, h: u64) void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        s.indexed.put(s.gpa, id.index, h) catch {};
    }

    fn maybeCommit(s: *Scheduler) void {
        const n = s.since_commit.load(.acquire);
        const now: i64 = @intCast(Io.Timestamp.now(s.io, .awake).nanoseconds);
        if (n >= commit_files or (n > 0 and now - s.last_commit.load(.acquire) >= commit_ns)) s.commitAll();
    }

    fn commitAll(s: *Scheduler) void {
        if (!s.commit_lock.tryLock()) return; // someone else is committing
        defer s.commit_lock.unlock(s.io);
        s.since_commit.store(0, .release);
        s.last_commit.store(@intCast(Io.Timestamp.now(s.io, .awake).nanoseconds), .release);
        const z = zg_core.trace.zone(@src(), "index.commit");
        defer z.end();
        for (s.plugins.items) |p| p.commit(p.ctx);
    }
};

/// Per-worker state: the read buffer.
const Worker = struct {
    s: *Scheduler,
    buf: []u8 = &.{},

    fn deinit(w: *Worker) void {
        w.s.gpa.free(w.buf);
    }

    fn job(w: *Worker, id: FileId) void {
        const s = w.s;
        defer s.done();
        const z = zg_core.trace.zone(@src(), "index.file");
        defer z.end();
        w.run(id) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {}, // vanished mid-read
            else => log.warn("indexing file {d} failed: {t}", .{ id.index, err }),
        };
    }

    fn run(w: *Worker, id: FileId) !void {
        const s = w.s;
        const snap = s.paths.snapshot();
        defer snap.release();
        if (!snap.contains(id) or snap.info(id).isDir()) return;
        const root = snap.rootOf(id) orelse return;
        var pbuf: [4096]u8 = undefined;
        const rel = snap.pathOf(id, &pbuf);
        const dir = (if (root.index() < s.roots.items.len) s.roots.items[root.index()] else null) orelse return;
        const ref: FileRef = .{ .id = id, .root = root, .rel = rel, .path_hash = plugin_mod.pathHash(root, rel) };

        var file = try dir.openFile(s.io, rel, .{});
        defer file.close(s.io);
        const st = try file.stat(s.io);
        const mtime: i128 = st.mtime.nanoseconds;

        // Which plugins need the bytes?
        var need: [32]bool = @splat(true);
        const np = @min(s.plugins.items.len, need.len);
        const cached = if (s.cache) |c| c.get(ref.path_hash) else null;
        if (cached) |rec| if (rec.size == st.size and rec.mtime_ns == mtime) {
            var any = false;
            for (s.plugins.items[0..np], 0..) |p, i| {
                const has = if (p.has) |h| h(p.ctx, &ref) else true;
                need[i] = s.stale.items[i] or !has;
                any = any or need[i];
            }
            if (!any) {
                s.noteIndexed(id, ref.path_hash);
                _ = s.n_cached.fetchAdd(1, .monotonic);
                return;
            }
        };

        // Read (or map) the content.
        var mm: ?Io.File.MemoryMap = null;
        defer if (mm) |*m| m.destroy(s.io);
        var bytes: []const u8 = &.{};
        const size = st.size;
        var class: ContentClass = .too_large;
        if (size <= s.cfg.max_file_bytes) {
            if (size > mmap_threshold) {
                mm = try file.createMemoryMap(s.io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = false });
                try mm.?.read(s.io);
                bytes = mm.?.memory;
            } else {
                if (w.buf.len < size or w.buf.len == 0) {
                    s.gpa.free(w.buf);
                    w.buf = &.{};
                    w.buf = try s.gpa.alloc(u8, @max(s.cfg.read_buf, std.math.ceilPowerOfTwoAssert(usize, @max(1, @as(usize, @intCast(size))))));
                }
                const n = try file.readPositionalAll(s.io, w.buf[0..@intCast(size)], 0);
                bytes = w.buf[0..n];
            }
            class = cc.classify(bytes[0..@min(bytes.len, cc.head_len)], bytes.len, rel, &s.cfg);
        }
        _ = s.n_bytes.fetchAdd(bytes.len, .monotonic);

        // UTF-16 is transcoded once for every plugin.
        var text = bytes;
        var transcoded: ?[]u8 = null;
        defer if (transcoded) |t| s.gpa.free(t);
        if (class == .text_utf16le or class == .text_utf16be) {
            transcoded = try cc.utf16ToUtf8(s.gpa, bytes[2..], class == .text_utf16be);
            text = transcoded.?;
        }

        for (s.plugins.items[0..np], 0..) |p, i| {
            if (!need[i]) continue;
            if (!p.wants(p.ctx, &ref, class)) {
                p.remove(p.ctx, &ref);
                continue;
            }
            var out: PluginOutput = .{};
            p.index(p.ctx, &ref, if (class.isText()) text else &.{}, class, &out) catch |err| {
                log.warn("plugin {s} failed on '{s}': {t}", .{ p.name, rel, err });
            };
        }
        s.noteIndexed(id, ref.path_hash);
        _ = s.n_indexed.fetchAdd(1, .monotonic);
        _ = s.since_commit.fetchAdd(1, .release);
        if (s.cache) |c| try c.put(ref.path_hash, .{ .size = size, .mtime_ns = mtime, .class = class });
    }
};
