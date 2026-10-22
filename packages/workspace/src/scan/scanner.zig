//! The parallel directory scanner: fills the `PathStore` for a root (or a
//! subtree of it) as fast as the filesystem allows.
//!
//! N workers share one mutex-guarded stack of directory tasks (owners pop
//! the newest task, which keeps the walk depth-first and local). A worker
//! lists a directory, loads its `.gitignore`/`.zgignore` before judging the
//! entries, skips ignored ones, queues child directories, and batches the
//! upserts. Batches are applied under the job's writer lock, which also
//! publishes `paths_changed` and `scan_progress` on the workspace bus.
//!
//! Files are not stat'ed (`Dir.Entry` carries no size or mtime); they get
//! `stat_pending` and the indexer stats them when it reads them. Rescanning
//! an existing subtree compares each listing with the previous snapshot:
//! unchanged nodes keep their `FileId`s, vanished ones are removed.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ids = @import("../ids.zig");
const RootId = ids.RootId;
const FileId = ids.FileId;
const path_store = @import("../paths/path_store.zig");
const PathStore = path_store.PathStore;
const Snapshot = path_store.Snapshot;
const NodeInfo = path_store.NodeInfo;
const NodeKind = path_store.NodeKind;
const Delta = path_store.Delta;
const Change = path_store.Change;
const IgnoreStack = @import("../ignore/ignore_stack.zig").IgnoreStack;
const events = @import("events.zig");

const log = std.log.scoped(.scanner);

/// Largest ignore file read.
pub const max_ignore_file = 1 << 20;

/// Scan options.
pub const ScanOptions = struct {
    /// Worker count; 0 means CPU count minus one, clamped to 1..16.
    max_workers: u8 = 0,
    /// Descend into symlinked directories (cycles are detected).
    follow_symlinks: bool = true,
    /// Root-relative directories to scan first (expanded explorer folders,
    /// restored session paths).
    priority_dirs: []const []const u8 = &.{},
    /// Stat every file for size and mtime instead of leaving `stat_pending`.
    stat_files: bool = false,
    /// Keep ignored entries (flagged `ignored`, never descended).
    include_ignored: bool = false,
    /// Ops per batch before a worker flushes.
    batch_ops: u32 = 2048,
    /// Longest a worker holds a non-empty batch.
    batch_ns: u64 = 8 * std.time.ns_per_ms,
};

/// What `Scanner.start` needs from its owner. `Workspace` provides one via
/// `forWorkspace`; tests can build it directly.
pub const Target = struct {
    /// The path tree to fill.
    paths: *PathStore,
    /// The ignore stack (`loadDir` is called as ignore files are found).
    ignore: *IgnoreStack,
    /// Where events go; null publishes nothing.
    bus: ?*events.Bus = null,
    /// The root being scanned.
    root: RootId,
    /// Its absolute path.
    abs_path: []const u8,
    /// Whether names compare case-insensitively on this root.
    case_insensitive: bool = false,
};

/// Entry point.
pub const Scanner = struct {
    /// Starts scanning `rel_dir` (`""` for the whole root) and returns
    /// immediately; `ScanJob.wait` blocks until the scan is done.
    pub fn start(gpa: Allocator, io: Io, target: Target, rel_dir: []const u8, opts: ScanOptions) !*ScanJob {
        const job = try gpa.create(ScanJob);
        errdefer gpa.destroy(job);
        var root_dir = try Io.Dir.openDirAbsolute(io, target.abs_path, .{ .iterate = true });
        errdefer root_dir.close(io);
        job.* = .{
            .gpa = gpa,
            .io = io,
            .target = target,
            .root_dir = root_dir,
            .opts = opts,
            .old = target.paths.snapshot(),
            .started = Io.Timestamp.now(io, .awake),
        };
        errdefer job.old.release();
        try job.seed(rel_dir);
        job.spawnWorkers();
        return job;
    }

    /// The `Target` for root `root` of a workspace.
    pub fn forWorkspace(ws: anytype, root: RootId) Target {
        const r = ws.roots()[root.index()];
        return .{
            .paths = ws.paths(),
            .ignore = ws.ignore(),
            .bus = &ws.bus,
            .root = root,
            .abs_path = r.abs_path,
            .case_insensitive = r.case_insensitive,
        };
    }
};

const DirTask = struct {
    /// Root-relative path (owned by `ScanJob.gpa`).
    rel: []u8,
    depth: u16,
    /// Reached through a symlink: open with `follow_symlinks`.
    via_link: bool = false,
};

/// A running scan.
pub const ScanJob = struct {
    gpa: Allocator,
    io: Io,
    target: Target,
    root_dir: Io.Dir,
    opts: ScanOptions,
    /// The tree as it was when the scan started (for rescan sweeps).
    old: *const Snapshot,
    started: Io.Timestamp,

    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    tasks: std.ArrayList(DirTask) = .empty,
    /// Queued plus in-progress directories.
    pending: u32 = 0,
    /// Priority directories already queued (their parents must not queue
    /// them again).
    queued_priority: std.StringHashMapUnmanaged(void) = .empty,
    visited_lock: Io.Mutex = .init,
    /// Real paths of directories reached through symlinks.
    visited: std.StringHashMapUnmanaged(void) = .empty,

    group: Io.Group = .init,
    active_workers: std.atomic.Value(u32) = .init(0),
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    writer_lock: Io.Mutex = .init,
    changes: std.ArrayList(Change) = .empty,
    last_progress: Io.Timestamp = .zero,
    /// The first error `apply` returned, if any.
    apply_error: ?anyerror = null,

    /// Directories listed so far.
    dirs: std.atomic.Value(u32) = .init(0),
    /// Entries recorded so far.
    files: std.atomic.Value(u32) = .init(0),
    /// Test hook: directory reads started.
    readdir_calls: std.atomic.Value(u32) = .init(0),

    fn seed(job: *ScanJob, rel_dir: []const u8) !void {
        for (job.opts.priority_dirs) |p| {
            if (p.len == 0 or !isUnder(p, rel_dir)) continue;
            if (job.target.ignore.isIgnoredFast(job.target.root, p, true)) continue;
            // The ancestors' ignore files decide what is visible inside `p`.
            try job.preloadIgnores(p);
            const owned = try job.gpa.dupe(u8, p);
            errdefer job.gpa.free(owned);
            const gop = try job.queued_priority.getOrPut(job.gpa, owned);
            if (gop.found_existing) {
                job.gpa.free(owned);
                continue;
            }
            try job.push(.{ .rel = try job.gpa.dupe(u8, p), .depth = depthOf(p) });
        }
        try job.preloadIgnores(rel_dir);
        try job.push(.{ .rel = try job.gpa.dupe(u8, rel_dir), .depth = depthOf(rel_dir) });
    }

    /// Loads the ignore files of every proper ancestor of `rel`.
    fn preloadIgnores(job: *ScanJob, rel: []const u8) !void {
        if (rel.len == 0) return;
        var end: usize = 0;
        while (true) {
            const dir = rel[0..end];
            try job.loadIgnoreFiles(dir);
            end = (std.mem.indexOfScalarPos(u8, rel, end + @intFromBool(end > 0), '/') orelse return);
        }
    }

    fn loadIgnoreFiles(job: *ScanJob, rel_dir: []const u8) !void {
        var d = (if (rel_dir.len == 0) job.root_dir else job.root_dir.openDir(job.io, rel_dir, .{}) catch return);
        defer if (rel_dir.len != 0) d.close(job.io);
        const gi = readSmall(job.io, d, ".gitignore", job.gpa);
        defer if (gi) |b| job.gpa.free(b);
        const zi = readSmall(job.io, d, ".zgignore", job.gpa);
        defer if (zi) |b| job.gpa.free(b);
        if (gi != null or zi != null) try job.target.ignore.loadDir(job.target.root, rel_dir, gi, zi);
    }

    fn push(job: *ScanJob, t: DirTask) !void {
        job.lock.lockUncancelable(job.io);
        defer job.lock.unlock(job.io);
        job.tasks.append(job.gpa, t) catch |err| {
            job.gpa.free(t.rel);
            return err;
        };
        job.pending += 1;
        job.cond.signal(job.io);
    }

    fn workerCount(job: *const ScanJob) u32 {
        if (job.opts.max_workers != 0) return job.opts.max_workers;
        const cpus = std.Thread.getCpuCount() catch 2;
        return @intCast(std.math.clamp(cpus -| 1, 1, 16));
    }

    fn spawnWorkers(job: *ScanJob) void {
        const n = job.workerCount();
        job.active_workers.store(n, .release);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            job.group.concurrent(job.io, worker, .{job}) catch {
                // No more concurrency: the rest run as plain async tasks
                // (inline on a single-threaded Io).
                while (i < n) : (i += 1) job.group.async(job.io, worker, .{job});
                return;
            };
        }
    }

    /// Requests cancellation and waits for the workers. The path store
    /// keeps every batch applied so far (each batch is atomic).
    pub fn cancel(job: *ScanJob) void {
        job.abort();
        job.group.cancel(job.io);
    }

    /// Blocks until the scan finishes (or was canceled).
    pub fn wait(job: *ScanJob) void {
        job.group.await(job.io) catch {};
    }

    /// Whether every directory was listed.
    pub fn isDone(job: *const ScanJob) bool {
        return job.done.load(.acquire);
    }

    /// Waits for the workers, then frees the job.
    pub fn deinit(job: *ScanJob) void {
        const gpa = job.gpa;
        job.wait();
        for (job.tasks.items) |t| gpa.free(t.rel);
        job.tasks.deinit(gpa);
        var it = job.queued_priority.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        job.queued_priority.deinit(gpa);
        var vt = job.visited.keyIterator();
        while (vt.next()) |k| gpa.free(k.*);
        job.visited.deinit(gpa);
        job.changes.deinit(gpa);
        job.old.release();
        job.root_dir.close(job.io);
        gpa.destroy(job);
    }

    fn worker(job: *ScanJob) Io.Cancelable!void {
        var b: Batch = .{ .arena = .init(job.gpa) };
        defer b.arena.deinit();
        defer job.workerExit();
        const buf = job.gpa.alignedAlloc(u8, .of(usize), reader_buffer_len) catch return job.abort();
        defer job.gpa.free(buf);
        var names: std.ArrayList(Listed) = .empty;
        defer names.deinit(job.gpa);
        var name_arena: std.heap.ArenaAllocator = .init(job.gpa);
        defer name_arena.deinit();
        while (true) {
            const task = blk: {
                job.lock.lockUncancelable(job.io);
                defer job.lock.unlock(job.io);
                while (true) {
                    if (job.canceled.load(.acquire)) return;
                    if (job.tasks.items.len > 0) break;
                    // Going idle: publish what this worker holds first.
                    if (b.ops.items.len > 0) {
                        job.lock.unlock(job.io);
                        job.flush(&b);
                        job.lock.lockUncancelable(job.io);
                        continue;
                    }
                    if (job.pending == 0) return;
                    try job.cond.wait(job.io, &job.lock);
                }
                break :blk job.tasks.pop().?;
            };
            defer job.finishTask(task);
            _ = name_arena.reset(.retain_capacity);
            job.scanDir(&b, task, buf, &names, name_arena.allocator()) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => {
                    log.err("scan of '{s}' ran out of memory", .{task.rel});
                    job.abort();
                },
            };
            if (b.ops.items.len >= job.opts.batch_ops or b.age(job.io) >= job.opts.batch_ns) job.flush(&b);
        }
    }

    /// Stops every worker (the scan stays incomplete).
    fn abort(job: *ScanJob) void {
        job.canceled.store(true, .release);
        job.lock.lockUncancelable(job.io);
        job.cond.broadcast(job.io);
        job.lock.unlock(job.io);
    }

    fn finishTask(job: *ScanJob, t: DirTask) void {
        job.gpa.free(t.rel);
        job.lock.lockUncancelable(job.io);
        defer job.lock.unlock(job.io);
        job.pending -= 1;
        if (job.pending == 0) job.cond.broadcast(job.io);
    }

    fn workerExit(job: *ScanJob) void {
        if (job.active_workers.fetchSub(1, .acq_rel) != 1) return;
        // Last worker out: every batch has been flushed.
        const complete = !job.canceled.load(.acquire) and job.pending == 0;
        job.done.store(complete, .release);
        job.publishProgress(complete);
    }

    const Listed = struct { name: []const u8, kind: Io.File.Kind };

    fn scanDir(job: *ScanJob, b: *Batch, task: DirTask, buf: []align(@alignOf(usize)) u8, names: *std.ArrayList(Listed), na: Allocator) error{ Canceled, OutOfMemory }!void {
        const io = job.io;
        const root = job.target.root;
        const ign = job.target.ignore;
        _ = job.readdir_calls.fetchAdd(1, .monotonic);
        var dir = (if (task.rel.len == 0)
            job.root_dir
        else
            job.root_dir.openDir(io, task.rel, .{ .iterate = true, .follow_symlinks = task.via_link })) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.AccessDenied, error.PermissionDenied => return job.markUnreadable(b, task),
            error.FileNotFound, error.NotDir => return,
            else => {
                log.warn("cannot open '{s}': {t}", .{ task.rel, err });
                return;
            },
        };
        defer if (task.rel.len != 0) dir.close(io);

        // 1. List everything (names are copied: the reader reuses its buffer).
        names.clearRetainingCapacity();
        var reader: Io.Dir.Reader = .init(dir, buf);
        var entries: [256]Io.Dir.Entry = undefined;
        var has_gitignore = false;
        var has_zgignore = false;
        while (true) {
            const n = reader.read(io, &entries) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.AccessDenied, error.PermissionDenied => return job.markUnreadable(b, task),
                else => {
                    log.warn("cannot list '{s}': {t}", .{ task.rel, err });
                    break;
                },
            };
            if (n == 0) {
                if (reader.state == .finished) break;
                continue;
            }
            for (entries[0..n]) |e| {
                if (std.mem.eql(u8, e.name, ".git") and e.kind == .directory) continue; // hard ignore, never listed
                if (std.mem.eql(u8, e.name, ".gitignore")) has_gitignore = true;
                if (std.mem.eql(u8, e.name, ".zgignore")) has_zgignore = true;
                try names.append(job.gpa, .{ .name = try na.dupe(u8, e.name), .kind = e.kind });
            }
        }
        _ = job.dirs.fetchAdd(1, .monotonic);

        // 2. This directory's ignore files apply to its entries.
        if (has_gitignore or has_zgignore) {
            const gi = if (has_gitignore) readSmall(io, dir, ".gitignore", job.gpa) else null;
            defer if (gi) |x| job.gpa.free(x);
            const zi = if (has_zgignore) readSmall(io, dir, ".zgignore", job.gpa) else null;
            defer if (zi) |x| job.gpa.free(x);
            try ign.loadDir(root, task.rel, gi, zi);
        } else if (job.isRescan()) {
            ign.unloadDir(root, task.rel);
        }

        // 3. The previous listing, for the rescan sweep.
        const old_dir: ?FileId = job.old.lookup(root, task.rel);
        const old_children: []const FileId = if (old_dir) |d| job.old.children(d) else &.{};
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        if (old_children.len > 0) try seen.ensureTotalCapacity(na, @intCast(names.items.len));

        // 4. Judge and record each entry.
        const a = b.arena.allocator();
        var path_buf: [4096]u8 = undefined;
        for (names.items) |e| {
            const rel = joinRel(&path_buf, task.rel, e.name) orelse continue;
            var kind = mapKind(e.kind);
            var stat: ?Io.File.Stat = null;
            if (e.kind == .sym_link or e.kind == .unknown) {
                stat = dir.statFile(io, e.name, .{ .follow_symlinks = true }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => null, // dangling link or a race
                };
                kind = if (e.kind == .sym_link)
                    (if (stat != null and stat.?.kind == .directory) .symlink_dir else .symlink_file)
                else if (stat) |s| mapKind(s.kind) else .other;
            }
            const is_dir = kind == .dir or kind == .symlink_dir;
            const verdict = ign.isIgnoredInVisibleDir(root, rel, is_dir);
            if (verdict.isIgnored() and !job.opts.include_ignored) continue;
            if (old_children.len > 0) seen.putAssumeCapacity(e.name, {});

            var info: NodeInfo = .init(kind, 0, 0);
            info.flags.hidden = e.name[0] == '.';
            info.flags.ignored = verdict.isIgnored();
            if (!is_dir) {
                const old_info: ?NodeInfo = if (old_children.len > 0) job.oldInfo(rel) else null;
                const want_stat = job.opts.stat_files or (old_info != null and !old_info.?.flags.stat_pending);
                if (want_stat and stat == null) stat = dir.statFile(io, e.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => null,
                };
                if (want_stat and stat != null) {
                    const s = stat.?;
                    const flags = info.flags;
                    info = .init(kind, s.size, s.mtime.nanoseconds);
                    info.flags = flags;
                    if (old_info) |o| { // keep the indexer's classification
                        info.flags.binary = o.flags.binary;
                        info.flags.too_large = o.flags.too_large;
                    }
                } else info.flags.stat_pending = true;
            }

            var descend = is_dir and !verdict.isIgnored();
            if (kind == .symlink_dir) {
                if (!job.opts.follow_symlinks) {
                    descend = false;
                } else if (descend and try job.isCycle(dir, e.name)) {
                    info.flags.cycle = true;
                    descend = false;
                }
            }
            if (descend) info.flags.loading = true;
            try b.add(job.io, .{ .upsert = .{ .root = root, .rel = try a.dupe(u8, rel), .info = info } });
            _ = job.files.fetchAdd(1, .monotonic);

            if (descend and !job.queued_priority.contains(rel)) {
                try job.push(.{ .rel = try job.gpa.dupe(u8, rel), .depth = task.depth + 1, .via_link = task.via_link or kind == .symlink_dir });
            }
        }

        // 5. Sweep: what the old listing had and this one does not.
        for (old_children) |c| {
            const name = job.old.basename(c);
            if (seen.contains(name)) continue;
            if (job.target.case_insensitive and containsFold(&seen, name)) continue;
            const rel = joinRel(&path_buf, task.rel, name) orelse continue;
            try b.add(job.io, .{ .remove = .{ .root = root, .rel = try a.dupe(u8, rel) } });
        }
        try b.add(job.io, .{ .set_children_complete = .{ .root = root, .rel_dir = try a.dupe(u8, task.rel) } });
    }

    fn isRescan(job: *const ScanJob) bool {
        return job.old.fileCount() > 0;
    }

    fn oldInfo(job: *const ScanJob, rel: []const u8) ?NodeInfo {
        const id = job.old.lookup(job.target.root, rel) orelse return null;
        return job.old.info(id);
    }

    fn markUnreadable(job: *ScanJob, b: *Batch, task: DirTask) error{OutOfMemory}!void {
        if (task.rel.len == 0) {
            log.warn("cannot read root '{s}'", .{job.target.abs_path});
            return;
        }
        var info: NodeInfo = .init(if (task.via_link) .symlink_dir else .dir, 0, 0);
        info.flags.unreadable = true;
        info.flags.hidden = task.rel[if (std.mem.lastIndexOfScalar(u8, task.rel, '/')) |i| i + 1 else 0] == '.';
        const a = b.arena.allocator();
        try b.add(job.io, .{ .upsert = .{ .root = job.target.root, .rel = try a.dupe(u8, task.rel), .info = info } });
        try b.add(job.io, .{ .set_children_complete = .{ .root = job.target.root, .rel_dir = try a.dupe(u8, task.rel) } });
    }

    /// Whether following the symlinked directory `name` in `dir` would loop:
    /// its target contains the link itself, or was already entered through
    /// another link.
    fn isCycle(job: *ScanJob, dir: Io.Dir, name: []const u8) error{ Canceled, OutOfMemory }!bool {
        const target = realPath(job.io, dir, name, job.gpa) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return true, // cannot resolve: do not descend
        };
        var keep = false;
        defer if (!keep) job.gpa.free(target);
        const here = realPath(job.io, dir, ".", job.gpa) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return true,
        };
        defer job.gpa.free(here);
        if (isUnder(here, target)) return true;
        job.visited_lock.lockUncancelable(job.io);
        defer job.visited_lock.unlock(job.io);
        const gop = try job.visited.getOrPut(job.gpa, target);
        if (gop.found_existing) return true;
        keep = true;
        return false;
    }

    fn flush(job: *ScanJob, b: *Batch) void {
        if (b.ops.items.len == 0) return;
        job.writer_lock.lockUncancelable(job.io);
        defer job.writer_lock.unlock(job.io);
        job.changes.clearRetainingCapacity();
        const delta: Delta = .{ .ops = b.ops.items };
        job.target.paths.applyWith(&delta, &job.changes, job.gpa) catch |err| {
            log.err("applying scan batch failed: {t}", .{err});
            if (job.apply_error == null) job.apply_error = err;
        };
        if (job.target.bus) |bus| if (job.changes.items.len > 0) {
            const gen = job.target.paths.snapshot();
            defer gen.release();
            bus.publish(.pathsChanged(gen.generation, job.changes.items), job.changes.items);
        };
        b.reset();
        const now = Io.Timestamp.now(job.io, .awake);
        if (job.last_progress.durationTo(now).nanoseconds >= job.opts.batch_ns) {
            job.last_progress = now;
            job.publishProgressLocked(false);
        }
    }

    fn publishProgress(job: *ScanJob, complete: bool) void {
        job.writer_lock.lockUncancelable(job.io);
        defer job.writer_lock.unlock(job.io);
        job.publishProgressLocked(complete);
    }

    fn publishProgressLocked(job: *ScanJob, complete: bool) void {
        const bus = job.target.bus orelse return;
        bus.publish(.{ .scan_progress = .{
            .root = job.target.root,
            .dirs = job.dirs.load(.monotonic),
            .files = job.files.load(.monotonic),
            .done = complete,
        } }, &.{});
    }
};

const reader_buffer_len = 64 * 1024;

comptime {
    std.debug.assert(reader_buffer_len >= Io.Dir.Reader.min_buffer_len);
}

/// One worker's pending ops; strings live in its arena.
const Batch = struct {
    arena: std.heap.ArenaAllocator,
    ops: std.ArrayList(Delta.Op) = .empty,
    since: ?Io.Timestamp = null,

    fn add(b: *Batch, io: Io, op: Delta.Op) error{OutOfMemory}!void {
        if (b.since == null) b.since = Io.Timestamp.now(io, .awake);
        try b.ops.append(b.arena.allocator(), op);
    }

    fn age(b: *const Batch, io: Io) u64 {
        const s = b.since orelse return 0;
        return @intCast(@max(0, s.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds));
    }

    fn reset(b: *Batch) void {
        b.ops = .empty;
        _ = b.arena.reset(.retain_capacity);
        b.since = null;
    }
};

fn mapKind(k: Io.File.Kind) NodeKind {
    return switch (k) {
        .file => .file,
        .directory => .dir,
        .sym_link => .symlink_file,
        else => .other,
    };
}

fn joinRel(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    if (dir.len == 0) {
        if (name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const n = dir.len + 1 + name.len;
    if (n > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = '/';
    @memcpy(buf[dir.len + 1 .. n], name);
    return buf[0..n];
}

/// Whether `path` is `dir` or inside it (`/`-separated; `""` contains all).
fn isUnder(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/' or path[dir.len] == std.fs.path.sep;
}

fn depthOf(rel: []const u8) u16 {
    if (rel.len == 0) return 0;
    return @intCast(std.mem.count(u8, rel, "/") + 1);
}

fn containsFold(set: *const std.StringHashMapUnmanaged(void), name: []const u8) bool {
    var it = set.keyIterator();
    while (it.next()) |k| if (std.ascii.eqlIgnoreCase(k.*, name)) return true;
    return false;
}

/// `Dir.realPathFileAlloc` without the sentinel, so the result frees as a
/// plain slice.
fn realPath(io: Io, dir: Io.Dir, name: []const u8, gpa: Allocator) ![]u8 {
    const z = try dir.realPathFileAlloc(io, name, gpa);
    defer gpa.free(z);
    return gpa.dupe(u8, z);
}

fn readSmall(io: Io, dir: Io.Dir, name: []const u8, gpa: Allocator) ?[]u8 {
    return dir.readFileAlloc(io, name, gpa, .limited(max_ignore_file)) catch null;
}
