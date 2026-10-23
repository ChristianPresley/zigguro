//! `RunRegistry` (E13.F01.S01.T01): every run's record, the status state
//! machine, immutable refcounted `RunsView` snapshots for the UI, event
//! fan-out, JSONL journals written by one writer task, the binary index
//! and crash recovery.
//!
//! Threading: `create`/`update`/`remove` may be called from any thread.
//! They mutate the record list under `mutex`, encode the journal line,
//! hand it to the writer task (no file I/O on the calling thread) and
//! publish a new `RunsView`. A view is copy-on-write: unchanged records
//! are shared between views, a changed record is a fresh allocation, and
//! the old one is freed once no live view can still reach it.
//! `snapshot` is O(1): it bumps the current view's refcount under a lock
//! held for two instructions.

const std = @import("std");
const run = @import("run.zig");
const journal = @import("journal.zig");
const index = @import("index.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = run.RunId;
const RunRecord = run.RunRecord;
const RunStatus = run.RunStatus;
const RunEvent = run.RunEvent;
const Update = run.Update;

const n_status = @typeInfo(RunStatus).@"enum".fields.len;

pub const Listener = struct {
    ctx: *anyopaque,
    /// Called on the thread that made the change, after the new view is
    /// published. Must not subscribe or unsubscribe.
    on_event: *const fn (ctx: *anyopaque, e: RunEvent) void,
};
pub const ListenerId = u32;

/// An immutable snapshot of every run, newest first.
pub const RunsView = struct {
    version: u64,
    runs: []const *const RunRecord,
    by_status: [n_status][]const u32,
    refs: u32,
    retired: bool = false,

    /// Indices into `runs` of the runs with status `s`, newest first.
    pub fn byStatus(v: *const RunsView, s: RunStatus) []const u32 {
        return v.by_status[@intFromEnum(s)];
    }

    pub fn get(v: *const RunsView, id: RunId) ?*const RunRecord {
        const i = v.indexOf(id) orelse return null;
        return v.runs[i];
    }

    pub fn indexOf(v: *const RunsView, id: RunId) ?usize {
        var lo: usize = 0;
        var hi: usize = v.runs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (v.runs[mid].id.order(id)) {
                .eq => return mid,
                .gt => lo = mid + 1, // newest first: larger ids come first
                .lt => hi = mid,
            }
        }
        return null;
    }
};

/// One record and the arena that owns its strings.
const Box = struct {
    arena: std.heap.ArenaAllocator,
    rec: RunRecord,
    /// The first view version that no longer contains this box.
    retired_at: u64 = 0,
    /// Built from an index row only: spec strings other than the title are
    /// empty until `loadDetail`.
    partial: bool = false,
};

const Op = union(enum) {
    create: struct { id: RunId, line: []u8 },
    append: struct { id: RunId, line: []u8, sync: bool, close: bool },
    truncate: struct { id: RunId, len: u64 },
    delete: RunId,
};

pub const Retention = struct {
    max_age_ms: ?i64 = 90 * std.time.ms_per_day,
    max_count: ?u32 = 5_000,
    now_ms: i64,
    /// Returns true for a run that must be kept (e.g. its changeset is
    /// still pending review).
    protect: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, r: *const RunRecord) bool } = null,
};

pub const LoadOptions = struct {
    /// Whether a live host owns the non-terminal runs; null probes
    /// `runs/host.lock` (E13.F01.S01.T03).
    host_alive: ?bool = null,
};

pub const LoadReport = struct {
    runs: u32 = 0,
    from_index: u32 = 0,
    from_journal: u32 = 0,
    interrupted: u32 = 0,
    truncated: u32 = 0,
    index_rebuilt: bool = false,
};

pub const Options = struct {
    /// Milliseconds since the epoch; defaults to `Clock.real`.
    clock: ?*const fn (ctx: ?*anyopaque) i64 = null,
    clock_ctx: ?*anyopaque = null,
    /// Minimum time between index writes (the index is also written on
    /// `flush` and `deinit`).
    index_debounce_ms: i64 = 2_000,
};

pub const Error = error{ UnknownRun, InvalidTransition, NotTerminal } || Allocator.Error;

pub const host_lock_name = "host.lock";

gpa: Allocator,
io: Io,
/// `.zigguro/runs`; null keeps everything in memory.
dir: ?Io.Dir,
opts: Options,

mutex: Io.Mutex = .init,
/// Ascending by id.
boxes: std.ArrayList(*Box) = .empty,
version: u64 = 0,
/// The last id `create` handed out.
last_id: u128 = 0,

view_mu: Io.Mutex = .init,
current: *RunsView,
/// Live views, ascending by version (the current one is last).
views: std.ArrayList(*RunsView) = .empty,
retired: std.ArrayList(*Box) = .empty,

listen_mu: Io.Mutex = .init,
listeners: std.ArrayList(struct { id: ListenerId, l: Listener }) = .empty,
next_listener: ListenerId = 1,

// Writer task state, under `wmu`.
wmu: Io.Mutex = .init,
wcond: Io.Condition = .init,
idle_cond: Io.Condition = .init,
pending: std.ArrayList(Op) = .empty,
closing: bool = false,
busy: bool = false,
index_dirty: bool = false,
index_requested: bool = false,
group: Io.Group = .init,
/// No writer task (no concurrency): ops run inline under `wmu`.
inline_writes: bool = false,
/// The thread that last did journal I/O (tests).
io_thread: std.atomic.Value(u64) = .init(0),
/// Writer-owned state.
files: std.AutoHashMapUnmanaged(u128, OpenJournal) = .empty,
last_index_ms: i64 = 0,
write_errors: std.atomic.Value(u32) = .init(0),

const RunRegistry = @This();

const OpenJournal = struct { file: Io.File, off: u64 };

pub fn init(gpa: Allocator, io: Io, dir: ?Io.Dir, opts: Options) !*RunRegistry {
    const r = try gpa.create(RunRegistry);
    errdefer gpa.destroy(r);
    const v = try gpa.create(RunsView);
    errdefer gpa.destroy(v);
    v.* = .{ .version = 0, .runs = &.{}, .by_status = @splat(&.{}), .refs = 1 };
    r.* = .{ .gpa = gpa, .io = io, .dir = dir, .opts = opts, .current = v };
    errdefer r.views.deinit(gpa);
    try r.views.append(gpa, v);
    if (dir) |d| {
        // Runs are local state: keep them out of the user's commits.
        d.writeFile(io, .{ .sub_path = ".gitignore", .data = "*\n", .flags = .{ .exclusive = true } }) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => {},
        };
        r.group.concurrent(io, writerLoop, .{r}) catch {
            r.inline_writes = true;
        };
    }
    return r;
}

/// Stops the writer (after it drains and writes the index) and frees
/// everything. Outstanding snapshots must have been released.
pub fn deinit(r: *RunRegistry) void {
    if (r.dir != null) {
        r.wmu.lockUncancelable(r.io);
        r.closing = true;
        r.index_requested = true;
        r.wcond.signal(r.io);
        r.wmu.unlock(r.io);
        if (r.inline_writes) {
            r.wmu.lockUncancelable(r.io);
            r.drainLocked();
            r.wmu.unlock(r.io);
        } else r.group.await(r.io) catch {};
    }
    for (r.pending.items) |op| r.freeOp(op);
    r.pending.deinit(r.gpa);
    var it = r.files.valueIterator();
    while (it.next()) |f| f.file.close(r.io);
    r.files.deinit(r.gpa);
    for (r.boxes.items) |b| destroyBox(r.gpa, b);
    r.boxes.deinit(r.gpa);
    for (r.retired.items) |b| destroyBox(r.gpa, b);
    r.retired.deinit(r.gpa);
    for (r.views.items) |v| r.freeView(v);
    r.views.deinit(r.gpa);
    r.listeners.deinit(r.gpa);
    r.gpa.destroy(r);
}

pub fn nowMs(r: *const RunRegistry) i64 {
    if (r.opts.clock) |c| return c(r.opts.clock_ctx);
    return @intCast(@divFloor(Io.Clock.real.now(r.io).nanoseconds, std.time.ns_per_ms));
}

// ---- views ----

/// The current view, retained; pair with `release`.
pub fn snapshot(r: *RunRegistry) *const RunsView {
    r.view_mu.lockUncancelable(r.io);
    defer r.view_mu.unlock(r.io);
    r.current.refs += 1;
    return r.current;
}

pub fn release(r: *RunRegistry, v: *const RunsView) void {
    r.view_mu.lockUncancelable(r.io);
    defer r.view_mu.unlock(r.io);
    r.releaseLocked(@constCast(v));
}

fn releaseLocked(r: *RunRegistry, v: *RunsView) void {
    v.refs -= 1;
    if (v.refs != 0) return;
    for (r.views.items, 0..) |x, i| if (x == v) {
        _ = r.views.orderedRemove(i);
        break;
    };
    r.freeView(v);
    // Boxes retired at or before the oldest live view are unreachable.
    const min_live = r.views.items[0].version;
    var i: usize = 0;
    while (i < r.retired.items.len) {
        const b = r.retired.items[i];
        if (b.retired_at <= min_live) {
            destroyBox(r.gpa, b);
            _ = r.retired.swapRemove(i);
        } else i += 1;
    }
}

fn freeView(r: *RunRegistry, v: *RunsView) void {
    r.gpa.free(v.runs);
    for (v.by_status) |s| r.gpa.free(s);
    r.gpa.destroy(v);
}

/// Builds and installs a view of `boxes`; `retire` (already removed from
/// `boxes`) becomes unreachable from it. Caller holds `mutex`.
fn publishLocked(r: *RunRegistry, retire: ?*Box) Allocator.Error!void {
    const n = r.boxes.items.len;
    const v = try r.gpa.create(RunsView);
    errdefer r.gpa.destroy(v);
    const runs = try r.gpa.alloc(*const RunRecord, n);
    errdefer r.gpa.free(runs);
    var counts: [n_status]u32 = @splat(0);
    for (r.boxes.items, 0..) |b, i| {
        runs[n - 1 - i] = &b.rec;
        counts[@intFromEnum(b.rec.status)] += 1;
    }
    var by: [n_status][]u32 = undefined;
    var made: usize = 0;
    errdefer for (by[0..made]) |s| r.gpa.free(s);
    for (&by, counts) |*s, c| {
        s.* = try r.gpa.alloc(u32, c);
        made += 1;
    }
    var fill: [n_status]u32 = @splat(0);
    for (runs, 0..) |rec, i| {
        const k = @intFromEnum(rec.status);
        by[k][fill[k]] = @intCast(i);
        fill[k] += 1;
    }
    r.view_mu.lockUncancelable(r.io);
    defer r.view_mu.unlock(r.io);
    try r.views.ensureUnusedCapacity(r.gpa, 1);
    if (retire != null) try r.retired.ensureUnusedCapacity(r.gpa, 1);
    r.version += 1;
    v.* = .{ .version = r.version, .runs = runs, .by_status = undefined, .refs = 1 };
    for (&v.by_status, by) |*d, s| d.* = s;
    if (retire) |b| {
        b.retired_at = r.version;
        r.retired.appendAssumeCapacity(b);
    }
    r.views.appendAssumeCapacity(v);
    const old = r.current;
    r.current = v;
    r.releaseLocked(old);
}

// ---- records ----

fn destroyBox(gpa: Allocator, b: *Box) void {
    b.arena.deinit();
    gpa.destroy(b);
}

/// A box holding a deep copy of `rec`.
fn newBox(r: *RunRegistry, rec: RunRecord) Allocator.Error!*Box {
    const b = try r.gpa.create(Box);
    b.* = .{ .arena = .init(r.gpa), .rec = undefined };
    errdefer destroyBox(r.gpa, b);
    b.rec = try run.deepClone(RunRecord, b.arena.allocator(), rec);
    return b;
}

fn findLocked(r: *RunRegistry, id: RunId) ?usize {
    var lo: usize = 0;
    var hi: usize = r.boxes.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (r.boxes.items[mid].rec.id.order(id)) {
            .eq => return mid,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

fn insertPos(r: *RunRegistry, id: RunId) usize {
    var i = r.boxes.items.len;
    while (i > 0 and r.boxes.items[i - 1].rec.id.order(id) == .gt) i -= 1;
    return i;
}

/// Records a new run (status `queued`) with a fresh id.
/// Ids are strictly increasing within one registry, so runs created in
/// the same millisecond keep their creation order.
pub fn create(r: *RunRegistry, spec: run.RunSpec) Error!RunId {
    var id = RunId.generate(r.io);
    {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (id.toInt() <= r.last_id) id = .fromInt(r.last_id + 1);
        r.last_id = id.toInt();
    }
    return r.createWithId(id, spec);
}

pub fn createWithId(r: *RunRegistry, id: RunId, spec: run.RunSpec) Error!RunId {
    const now = r.nowMs();
    const b = try r.newBox(.{ .id = id, .spec = spec, .created_ms = now });
    {
        errdefer destroyBox(r.gpa, b);
        const line = try r.encode(struct {
            fn f(w: *Io.Writer, rec: *const RunRecord) Io.Writer.Error!void {
                try journal.writeCreate(w, rec);
            }
        }.f, &b.rec);
        errdefer r.gpa.free(line);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        try r.boxes.insert(r.gpa, r.insertPos(id), b);
        errdefer _ = r.boxes.orderedRemove(r.findLocked(id).?);
        try r.publishLocked(null);
        r.enqueue(.{ .create = .{ .id = id, .line = line } });
    }
    r.emit(.{ .run = id, .revision = 1, .kind = .created });
    return id;
}

fn encode(r: *RunRegistry, comptime f: anytype, arg: anytype) Allocator.Error![]u8 {
    if (r.dir == null) return &.{};
    var aw: Io.Writer.Allocating = .init(r.gpa);
    errdefer aw.deinit();
    f(&aw.writer, arg) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn eventKind(u: Update) run.EventKind {
    return switch (u) {
        .status => .status,
        .summary => .summary,
        .cost => .cost,
        .output => .output,
        .question => .question,
        else => .changed,
    };
}

/// Applies one change. Status changes must follow `run.allowed`; setting
/// the current status again is a no-op.
pub fn update(r: *RunRegistry, id: RunId, u: Update) Error!void {
    const ev: RunEvent = blk: {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const i = r.findLocked(id) orelse return error.UnknownRun;
        const old = r.boxes.items[i];
        if (u == .status) {
            if (old.rec.status == u.status) return;
            if (!run.canTransition(old.rec.status, u.status)) return error.InvalidTransition;
        }
        var tmp: std.heap.ArenaAllocator = .init(r.gpa);
        defer tmp.deinit();
        var rec = old.rec;
        try journal.apply(tmp.allocator(), &rec, u);
        const b = try r.newBox(rec);
        b.partial = old.partial;
        errdefer destroyBox(r.gpa, b);
        const line = try r.encodeUpdate(rec.revision, u);
        errdefer r.gpa.free(line);
        r.boxes.items[i] = b;
        errdefer r.boxes.items[i] = old;
        try r.publishLocked(old);
        const terminal = u == .status and u.status.isTerminal();
        r.enqueue(.{ .append = .{ .id = id, .line = line, .sync = terminal, .close = terminal } });
        break :blk .{ .run = id, .revision = rec.revision, .kind = eventKind(u) };
    };
    r.emit(ev);
}

fn encodeUpdate(r: *RunRegistry, seq: u64, u: Update) Allocator.Error![]u8 {
    if (r.dir == null) return &.{};
    var aw: Io.Writer.Allocating = .init(r.gpa);
    errdefer aw.deinit();
    journal.writeUpdate(&aw.writer, seq, r.nowMs(), u) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Removes a terminal run (and its journal directory when `delete_files`).
pub fn remove(r: *RunRegistry, id: RunId, delete_files: bool) Error!void {
    const rev = blk: {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const i = r.findLocked(id) orelse return error.UnknownRun;
        const b = r.boxes.items[i];
        if (!b.rec.status.isTerminal()) return error.NotTerminal;
        _ = r.boxes.orderedRemove(i);
        r.publishLocked(b) catch |e| {
            r.boxes.insertAssumeCapacity(i, b);
            return e;
        };
        if (delete_files and r.dir != null) r.enqueue(.{ .delete = id });
        break :blk b.rec.revision;
    };
    r.emit(.{ .run = id, .revision = rev + 1, .kind = .removed });
}

/// Removes old terminal runs: older than `max_age_ms`, then the oldest
/// beyond `max_count` (which counts unprotected terminal runs only). Never removes active or protected runs. Returns
/// how many were removed.
pub fn sweep(r: *RunRegistry, keep: Retention) Error!u32 {
    var doomed: std.ArrayList(RunId) = .empty;
    defer doomed.deinit(r.gpa);
    {
        const v = r.snapshot();
        defer r.release(v);
        var kept: u32 = 0;
        // Newest first: count what is kept, doom the rest.
        for (v.runs) |rec| {
            const terminal = rec.status.isTerminal();
            const protected = if (keep.protect) |p| p.f(p.ctx, rec) else false;
            const too_old = if (keep.max_age_ms) |a| keep.now_ms - (rec.ended_ms orelse rec.created_ms) > a else false;
            const over = if (keep.max_count) |c| kept >= c else false;
            if (!terminal or protected) continue;
            if (too_old or over) {
                try doomed.append(r.gpa, rec.id);
            } else kept += 1;
        }
    }
    var n: u32 = 0;
    for (doomed.items) |id| {
        r.remove(id, true) catch |e| switch (e) {
            error.UnknownRun, error.NotTerminal => continue,
            else => return e,
        };
        n += 1;
    }
    return n;
}

pub fn subscribe(r: *RunRegistry, l: Listener) Allocator.Error!ListenerId {
    r.listen_mu.lockUncancelable(r.io);
    defer r.listen_mu.unlock(r.io);
    const id = r.next_listener;
    try r.listeners.append(r.gpa, .{ .id = id, .l = l });
    r.next_listener += 1;
    return id;
}

pub fn unsubscribe(r: *RunRegistry, id: ListenerId) void {
    r.listen_mu.lockUncancelable(r.io);
    defer r.listen_mu.unlock(r.io);
    for (r.listeners.items, 0..) |x, i| if (x.id == id) {
        _ = r.listeners.orderedRemove(i);
        return;
    };
}

fn emit(r: *RunRegistry, e: RunEvent) void {
    r.listen_mu.lockUncancelable(r.io);
    defer r.listen_mu.unlock(r.io);
    for (r.listeners.items) |x| x.l.on_event(x.l.ctx, e);
}

// ---- writer ----

fn enqueue(r: *RunRegistry, op: Op) void {
    if (r.dir == null) return r.freeOp(op);
    r.wmu.lockUncancelable(r.io);
    defer r.wmu.unlock(r.io);
    r.pending.append(r.gpa, op) catch {
        // Out of memory: the line is lost; the index still has the state.
        r.freeOp(op);
        _ = r.write_errors.fetchAdd(1, .monotonic);
        return;
    };
    r.index_dirty = true;
    if (r.inline_writes) r.drainLocked() else r.wcond.signal(r.io);
}

fn freeOp(r: *RunRegistry, op: Op) void {
    switch (op) {
        .create => |c| r.gpa.free(c.line),
        .append => |a| r.gpa.free(a.line),
        .truncate, .delete => {},
    }
}

/// Blocks until every queued journal line is written, then writes the
/// index.
pub fn flush(r: *RunRegistry) void {
    if (r.dir == null) return;
    r.wmu.lockUncancelable(r.io);
    defer r.wmu.unlock(r.io);
    r.index_requested = true;
    if (r.inline_writes) return r.drainLocked();
    r.wcond.signal(r.io);
    while (r.pending.items.len != 0 or r.busy or r.index_requested) r.idle_cond.waitUncancelable(r.io, &r.wmu);
}

fn writerLoop(r: *RunRegistry) void {
    r.wmu.lockUncancelable(r.io);
    defer r.wmu.unlock(r.io);
    while (true) {
        while (r.pending.items.len == 0 and !r.closing and !r.index_requested) r.wcond.waitUncancelable(r.io, &r.wmu);
        r.drainLocked();
        r.idle_cond.broadcast(r.io);
        if (r.closing and r.pending.items.len == 0) return;
    }
}

/// Writes every pending op and, when due, the index. Called with `wmu`
/// held; drops it around file I/O.
fn drainLocked(r: *RunRegistry) void {
    r.busy = true;
    defer r.busy = false;
    while (r.pending.items.len != 0) {
        var batch = r.pending;
        r.pending = .empty;
        r.wmu.unlock(r.io);
        for (batch.items) |op| {
            r.writeOp(op) catch {
                _ = r.write_errors.fetchAdd(1, .monotonic);
            };
            r.freeOp(op);
        }
        batch.deinit(r.gpa);
        r.wmu.lockUncancelable(r.io);
    }
    const now = r.nowMs();
    if (r.index_dirty and (r.index_requested or r.closing or now - r.last_index_ms >= r.opts.index_debounce_ms)) {
        r.index_dirty = false;
        r.wmu.unlock(r.io);
        r.writeIndex() catch {
            _ = r.write_errors.fetchAdd(1, .monotonic);
        };
        r.last_index_ms = now;
        r.wmu.lockUncancelable(r.io);
    }
    r.index_requested = false;
}

fn journalPath(id: RunId) [26 + "/run.jsonl".len]u8 {
    return id.text() ++ "/run.jsonl".*;
}

fn writeOp(r: *RunRegistry, op: Op) !void {
    const dir = r.dir.?;
    r.io_thread.store(std.Thread.getCurrentId(), .monotonic);
    switch (op) {
        .create => |c| {
            const name = c.id.text();
            try dir.createDirPath(r.io, &name);
            const path = journalPath(c.id);
            const f = try dir.createFile(r.io, &path, .{ .truncate = true });
            errdefer f.close(r.io);
            try f.writePositionalAll(r.io, c.line, 0);
            try f.sync(r.io);
            try r.cacheFile(c.id, .{ .file = f, .off = c.line.len });
        },
        .append => |a| {
            const j = try r.journalFile(a.id);
            try j.file.writePositionalAll(r.io, a.line, j.off);
            j.off += a.line.len;
            if (a.sync) try j.file.sync(r.io);
            if (a.close) r.closeFile(a.id);
        },
        .truncate => |t| {
            const j = try r.journalFile(t.id);
            try j.file.setLength(r.io, t.len);
            j.off = t.len;
        },
        .delete => |id| {
            r.closeFile(id);
            const name = id.text();
            try dir.deleteTree(r.io, &name);
        },
    }
}

fn journalFile(r: *RunRegistry, id: RunId) !*OpenJournal {
    if (r.files.getPtr(id.toInt())) |j| return j;
    const path = journalPath(id);
    const f = try r.dir.?.openFile(r.io, &path, .{ .mode = .read_write });
    errdefer f.close(r.io);
    try r.cacheFile(id, .{ .file = f, .off = try f.length(r.io) });
    return r.files.getPtr(id.toInt()).?;
}

fn cacheFile(r: *RunRegistry, id: RunId, j: OpenJournal) !void {
    if (r.files.count() >= 64) {
        var it = r.files.iterator();
        const victim = it.next().?;
        victim.value_ptr.file.close(r.io);
        r.files.removeByPtr(victim.key_ptr);
    }
    try r.files.put(r.gpa, id.toInt(), j);
}

fn closeFile(r: *RunRegistry, id: RunId) void {
    if (r.files.fetchRemove(id.toInt())) |kv| kv.value.file.close(r.io);
}

pub const index_name = "index.bin";

fn writeIndex(r: *RunRegistry) !void {
    const v = r.snapshot();
    defer r.release(v);
    const rows = try r.gpa.alloc(index.Row, v.runs.len);
    defer r.gpa.free(rows);
    // Oldest first, like the journal directories sort.
    for (v.runs, 0..) |rec, i| rows[v.runs.len - 1 - i] = .of(rec);
    const bytes = try index.encode(r.gpa, rows);
    defer r.gpa.free(bytes);
    var af = try r.dir.?.createFileAtomic(r.io, index_name, .{ .replace = true });
    defer af.deinit(r.io);
    try af.file.writeStreamingAll(r.io, bytes);
    try af.replace(r.io);
}

// ---- load and recovery ----

const Loaded = struct {
    id: RunId,
    replay: ?journal.Replay = null,
    arena: std.heap.ArenaAllocator,
    failed: bool = false,
};

/// Loads every run under `dir`: the index for terminal runs it covers,
/// journals for the rest (or for all of them when the index is missing,
/// corrupt or from another version). Non-terminal runs not owned by a
/// live host become `interrupted`; torn journal tails are truncated.
/// Call once, before other use, from a worker.
pub fn load(r: *RunRegistry, lo: LoadOptions) !LoadReport {
    const dir = r.dir orelse return .{};
    var rep: LoadReport = .{};
    const gpa = r.gpa;

    // Run directories on disk.
    var ids: std.ArrayList(RunId) = .empty;
    defer ids.deinit(gpa);
    {
        var d = try dir.openDir(r.io, ".", .{ .iterate = true });
        defer d.close(r.io);
        var it = d.iterate();
        while (try it.next(r.io)) |e| {
            if (e.kind != .directory) continue;
            const id = RunId.parse(e.name) catch continue;
            try ids.append(gpa, id);
        }
    }
    std.mem.sort(RunId, ids.items, {}, struct {
        fn lt(_: void, a: RunId, b: RunId) bool {
            return a.order(b) == .lt;
        }
    }.lt);

    // The index, when it is trustworthy.
    const index_bytes: ?[]u8 = dir.readFileAlloc(r.io, index_name, gpa, .limited(1 << 30)) catch null;
    defer if (index_bytes) |b| gpa.free(b);
    const rows: ?[]index.Row = if (index_bytes) |b| index.decode(gpa, b) catch null else null;
    defer if (rows) |rs| gpa.free(rs);
    rep.index_rebuilt = rows == null;

    var by_id: std.AutoHashMapUnmanaged(u128, *const index.Row) = .empty;
    defer by_id.deinit(gpa);
    if (rows) |rs| for (rs) |*row| try by_id.put(gpa, row.id.toInt(), row);

    // Journals to replay: every directory without a terminal index row.
    var todo: std.ArrayList(Loaded) = .empty;
    defer {
        for (todo.items) |*l| l.arena.deinit();
        todo.deinit(gpa);
    }
    var skeletons: std.ArrayList(*const index.Row) = .empty;
    defer skeletons.deinit(gpa);
    for (ids.items) |id| {
        if (by_id.get(id.toInt())) |row| if (row.status.isTerminal()) {
            try skeletons.append(gpa, row);
            continue;
        };
        try todo.append(gpa, .{ .id = id, .arena = .init(gpa) });
    }
    {
        var g: Io.Group = .init;
        var i: usize = 0;
        while (i < todo.items.len) : (i += 64) {
            const end = @min(i + 64, todo.items.len);
            g.async(r.io, replayChunk, .{ r, todo.items[i..end] });
        }
        try g.await(r.io);
    }

    const host_alive = lo.host_alive orelse r.probeHostAlive();

    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    var interrupted: std.ArrayList(RunId) = .empty;
    defer interrupted.deinit(gpa);
    for (skeletons.items) |row| {
        const b = try r.newBox(.{
            .id = row.id,
            .spec = .{ .kind = row.kind, .title = row.title, .prompt = "" },
            .status = row.status,
            .created_ms = row.created_ms,
            .started_ms = row.started_ms,
            .ended_ms = row.ended_ms,
            .cost = row.cost,
            .revision = row.revision,
        });
        b.partial = true;
        try r.boxes.append(gpa, b);
        rep.from_index += 1;
    }
    for (todo.items) |*l| {
        const rp = l.replay orelse continue;
        const b = try r.newBox(rp.record);
        try r.boxes.append(gpa, b);
        rep.from_journal += 1;
        if (rp.torn) {
            rep.truncated += 1;
            r.enqueue(.{ .truncate = .{ .id = l.id, .len = rp.good_len } });
        }
        if (!rp.record.status.isTerminal() and !host_alive) try interrupted.append(gpa, l.id);
    }
    std.mem.sort(*Box, r.boxes.items, {}, struct {
        fn lt(_: void, a: *Box, b: *Box) bool {
            return a.rec.id.order(b.rec.id) == .lt;
        }
    }.lt);
    rep.runs = @intCast(r.boxes.items.len);
    try r.publishLocked(null);
    r.wmu.lockUncancelable(r.io);
    r.index_dirty = true;
    r.wmu.unlock(r.io);

    // Recovery happens through `update` so it is journalled; release the
    // lock first.
    r.mutex.unlock(r.io);
    defer r.mutex.lockUncancelable(r.io);
    const now = r.nowMs();
    for (interrupted.items) |id| {
        r.update(id, .{ .error_ = "host exited unexpectedly" }) catch continue;
        r.update(id, .{ .ended = now }) catch {};
        r.update(id, .{ .status = .interrupted }) catch continue;
        rep.interrupted += 1;
    }
    return rep;
}

fn replayChunk(r: *RunRegistry, items: []Loaded) void {
    for (items) |*l| {
        const path = journalPath(l.id);
        const bytes = r.dir.?.readFileAlloc(r.io, &path, r.gpa, .limited(256 << 20)) catch {
            l.failed = true;
            continue;
        };
        defer r.gpa.free(bytes);
        var tmp: std.heap.ArenaAllocator = .init(r.gpa);
        defer tmp.deinit();
        const rp = journal.replay(tmp.allocator(), bytes) catch {
            l.failed = true;
            continue;
        };
        var out = rp;
        out.record = run.deepClone(RunRecord, l.arena.allocator(), rp.record) catch {
            l.failed = true;
            continue;
        };
        l.replay = out;
    }
}

/// True when another process holds `host.lock` (a live `zg agents host`).
fn probeHostAlive(r: *RunRegistry) bool {
    const f = r.dir.?.createFile(r.io, host_lock_name, .{ .truncate = false }) catch return false;
    defer f.close(r.io);
    const got = f.tryLock(r.io, .exclusive) catch return false;
    if (got) f.unlock(r.io);
    return !got;
}

/// Replaces a record built from the index with its full journal replay
/// (spec, outputs, summary). No-op for complete records.
pub fn loadDetail(r: *RunRegistry, id: RunId) !void {
    {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const i = r.findLocked(id) orelse return error.UnknownRun;
        if (!r.boxes.items[i].partial) return;
    }
    var l: Loaded = .{ .id = id, .arena = .init(r.gpa) };
    defer l.arena.deinit();
    replayChunk(r, (&l)[0..1]);
    const rp = l.replay orelse return error.InvalidJournal;
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const i = r.findLocked(id) orelse return error.UnknownRun;
    const old = r.boxes.items[i];
    const b = try r.newBox(rp.record);
    errdefer destroyBox(r.gpa, b);
    r.boxes.items[i] = b;
    errdefer r.boxes.items[i] = old;
    try r.publishLocked(old);
}

/// Whether `id`'s record lacks its journal detail (built from the index).
pub fn isPartial(r: *RunRegistry, id: RunId) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const i = r.findLocked(id) orelse return false;
    return r.boxes.items[i].partial;
}

test {
    _ = @import("registry_test.zig");
}
