//! The trigger engine (E13.F02.S02.T01): matches workspace file events,
//! SCM events and task events against automations' event triggers,
//! coalesces file bursts per automation with a debounce window, drops
//! events an automation's own run caused, and hands fires (with the event
//! as an untrusted JSON payload) to the scheduler, which applies the
//! shared policy: enabled, chain depth, rate limits, budgets, overlap.
//!
//! Events arrive from any thread (`onFileEvents`, `onScmEvent`,
//! `onTaskEvent`); fires happen in `poll`, which the engine's one task
//! runs after `start` (tests call it directly with a fake clock). The
//! sources (E08's bus, E09's ScmService, F03's TaskStore) are adapted to
//! the plain event types here by their owners, so this package needs no
//! dependency on them.

const std = @import("std");
const runs = @import("../runs/root.zig");
const automation = @import("automation.zig");
const Scheduler = @import("scheduler.zig");
const AutomationRunner = @import("runner.zig");
const glob = @import("glob.zig");
const guard = @import("guard.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Automation = automation.Automation;
const EventMask = automation.EventMask;
const ScmEventKind = automation.ScmEventKind;
const TaskEventKind = automation.TaskEventKind;

pub const Provenance = guard.Provenance;
pub const Skip = Scheduler.Skip;

pub const FileKind = enum { created, modified, deleted, renamed };

pub const FileEvent = struct {
    /// Workspace-relative (either separator).
    path: []const u8,
    kind: FileKind,
    provenance: ?Provenance = null,
};

pub const ScmEvent = struct {
    kind: ScmEventKind,
    change_ids: []const []const u8 = &.{},
    /// Change descriptions (untrusted text).
    descriptions: []const []const u8 = &.{},
    lane: ?[]const u8 = null,
    bookmark: ?[]const u8 = null,
    provenance: ?Provenance = null,
};

pub const Task = struct {
    id: []const u8,
    title: []const u8 = "",
    status: []const u8 = "",
    labels: []const []const u8 = &.{},
    /// 0 for P0 (most urgent) to 3.
    priority: ?u8 = null,
    assignee: ?[]const u8 = null,
};

pub const TaskEvent = struct {
    kind: TaskEventKind,
    task: Task,
    provenance: ?Provenance = null,
};

/// Where fires go (the scheduler; fakes in tests).
pub const FirePort = struct {
    ctx: *anyopaque,
    /// Null when the policy skipped it (recorded in the history).
    fire: *const fn (ctx: *anyopaque, name: []const u8, payload: []const u8, o: Scheduler.EventFire) anyerror!?u64,
    skip: *const fn (ctx: *anyopaque, name: []const u8, skip: Skip) void,

    /// Fires through `s` while this process holds the scheduler lease
    /// (another process fires otherwise).
    pub fn fromScheduler(s: *Scheduler) FirePort {
        return .{ .ctx = s, .fire = schedFire, .skip = schedSkip };
    }

    fn schedFire(ctx: *anyopaque, name: []const u8, payload: []const u8, o: Scheduler.EventFire) anyerror!?u64 {
        const s: *Scheduler = @ptrCast(@alignCast(ctx));
        if (!s.leased()) return null;
        return s.fireEvent(name, payload, o) catch |e| switch (e) {
            error.UnknownAutomation, error.Disabled => null,
            else => e,
        };
    }

    fn schedSkip(ctx: *anyopaque, name: []const u8, skip: Skip) void {
        const s: *Scheduler = @ptrCast(@alignCast(ctx));
        s.recordSkip(name, skip);
    }
};

/// Evaluates an SCM trigger's revset (E09 `ScmService`).
pub const RevsetPort = struct {
    ctx: *anyopaque,
    /// Whether any of `change_ids` is in `revset`.
    contains: *const fn (ctx: *anyopaque, revset: []const u8, change_ids: []const []const u8) anyerror!bool,
};

/// F03's claim protocol: a task-triggered run claims its task first.
pub const ClaimPort = struct {
    ctx: *anyopaque,
    /// False when someone else holds the task.
    claim: *const fn (ctx: *anyopaque, task_id: []const u8, automation: []const u8) anyerror!bool,
};

pub const Options = struct {
    clock: ?Scheduler.Clock = null,
    revsets: ?RevsetPort = null,
    claims: ?ClaimPort = null,
    /// For the self-trigger fallback: paths a run of the automation listed
    /// as outputs are ignored while it runs and `self_window_ms` after.
    registry: ?*runs.RunRegistry = null,
    self_window_ms: i64 = 10_000,
    max_paths: u32 = 1000,
    /// The longest the task sleeps.
    max_sleep_ms: i64 = 60_000,
};

const FileSub = struct { globs: glob.GlobList, mask: EventMask, debounce_ms: u32 };
const ScmSub = struct { kinds: []const ScmEventKind, revset: ?[]const u8 };
const TaskSub = struct { kinds: []const TaskEventKind, query: ?TaskQuery };

const Sub = struct {
    name: []const u8,
    files: []FileSub,
    scm: []ScmSub,
    task: []TaskSub,
};

/// A file burst being coalesced (kept across `setAutomations`).
const Pending = struct {
    paths: std.StringArrayHashMapUnmanaged(EventMask) = .empty,
    dropped: u32 = 0,
    deadline: i64 = 0,
    depth: u8 = 0,

    fn deinit(p: *Pending, gpa: Allocator) void {
        for (p.paths.keys()) |k| gpa.free(k);
        p.paths.deinit(gpa);
    }
};

/// An SCM or task fire waiting for `poll`.
const Work = struct {
    name: []const u8,
    payload: []const u8,
    depth: u8,
    task_id: ?[]const u8 = null,
    revset: ?[]const u8 = null,
    change_ids: []const []const u8 = &.{},

    fn deinit(w: *Work, gpa: Allocator) void {
        gpa.free(w.name);
        gpa.free(w.payload);
        if (w.task_id) |t| gpa.free(t);
        if (w.revset) |r| gpa.free(r);
        for (w.change_ids) |c| gpa.free(c);
        gpa.free(w.change_ids);
    }
};

const TriggerEngine = @This();

gpa: Allocator,
io: Io,
port: FirePort,
o: Options,
mutex: Io.Mutex = .init,
subs_arena: std.heap.ArenaAllocator,
subs: []Sub = &.{},
pending: std.StringArrayHashMapUnmanaged(Pending) = .empty,
work: std.ArrayList(Work) = .empty,
wake_ev: Io.Event = .unset,
stopping: std.atomic.Value(bool) = .init(false),
group: Io.Group = .init,
running: bool = false,
/// Fires handed to the port (tests and the bench).
fired: std.atomic.Value(u64) = .init(0),

pub fn init(gpa: Allocator, io: Io, port: FirePort, o: Options) !*TriggerEngine {
    const t = try gpa.create(TriggerEngine);
    t.* = .{ .gpa = gpa, .io = io, .port = port, .o = o, .subs_arena = .init(gpa) };
    return t;
}

pub fn deinit(t: *TriggerEngine) void {
    t.stop();
    for (t.pending.keys(), t.pending.values()) |k, *p| {
        t.gpa.free(k);
        p.deinit(t.gpa);
    }
    t.pending.deinit(t.gpa);
    for (t.work.items) |*w| w.deinit(t.gpa);
    t.work.deinit(t.gpa);
    t.subs_arena.deinit();
    t.gpa.destroy(t);
}

/// Replaces the subscriptions (disabled automations have none). Bursts
/// already pending for automations that still watch files are kept.
pub fn setAutomations(t: *TriggerEngine, list: []const Automation) !void {
    var arena: std.heap.ArenaAllocator = .init(t.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var subs: std.ArrayList(Sub) = .empty;
    for (list) |*au| {
        if (!au.enabled) continue;
        var files: std.ArrayList(FileSub) = .empty;
        var scm: std.ArrayList(ScmSub) = .empty;
        var task: std.ArrayList(TaskSub) = .empty;
        for (au.triggers) |tr| switch (tr) {
            .files => |f| try files.append(a, .{ .globs = try glob.GlobList.compile(a, f.globs), .mask = f.events, .debounce_ms = f.debounce_ms }),
            .scm => |s| try scm.append(a, .{ .kinds = try a.dupe(ScmEventKind, s.events), .revset = if (s.revset) |r| try a.dupe(u8, r) else null }),
            .task => |k| try task.append(a, .{ .kinds = try a.dupe(TaskEventKind, k.events), .query = if (k.query) |q| try TaskQuery.parse(a, q) else null }),
            else => {},
        };
        if (files.items.len + scm.items.len + task.items.len == 0) continue;
        try subs.append(a, .{ .name = try a.dupe(u8, au.name), .files = files.items, .scm = scm.items, .task = task.items });
    }
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    t.subs_arena.deinit();
    t.subs_arena = arena;
    t.subs = subs.items;
    // Drop bursts of automations that no longer watch files.
    var i: usize = 0;
    while (i < t.pending.count()) {
        const name = t.pending.keys()[i];
        const keep = for (t.subs) |s| {
            if (std.mem.eql(u8, s.name, name) and s.files.len > 0) break true;
        } else false;
        if (keep) {
            i += 1;
            continue;
        }
        var p = t.pending.values()[i];
        p.deinit(t.gpa);
        t.gpa.free(name);
        t.pending.swapRemoveAt(i);
    }
}

/// A batch of workspace file events (E08's bus worker).
pub fn onFileEvents(t: *TriggerEngine, batch: []const FileEvent) void {
    var reg_view: ?*const runs.RunsView = null;
    defer if (reg_view) |v| t.o.registry.?.release(v);
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    const now = t.nowMs();
    var buf: [4096]u8 = undefined;
    for (batch) |ev| {
        const path = guard.normalize(ev.path, &buf) orelse continue;
        if (path.len == 0 or guard.isInternal(path)) continue;
        for (t.subs) |*s| {
            if (s.files.len == 0) continue;
            if (guard.isSelf(ev.provenance, s.name)) continue;
            const fs = for (s.files) |*f| {
                if (maskHas(f.mask, ev.kind) and f.globs.match(path)) break f;
            } else continue;
            if (ev.provenance == null) if (t.o.registry) |reg| {
                if (reg_view == null) reg_view = reg.snapshot();
                if (t.ownOutput(reg_view.?, s.name, path, now)) continue;
            };
            t.addPending(s.name, path, ev.kind, guard.depthFor(ev.provenance), now + fs.debounce_ms) catch {};
        }
    }
    t.wake_ev.set(t.io);
}

/// An SCM event (E09 `ScmService` listener).
pub fn onScmEvent(t: *TriggerEngine, ev: ScmEvent) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    for (t.subs) |*s| {
        if (guard.isSelf(ev.provenance, s.name)) continue;
        const sub = for (s.scm) |*x| {
            if (std.mem.indexOfScalar(ScmEventKind, x.kinds, ev.kind) != null) break x;
        } else continue;
        t.queueScm(s.name, sub, ev) catch {};
    }
    t.wake_ev.set(t.io);
}

/// A task event (F03 `TaskStore` listener).
pub fn onTaskEvent(t: *TriggerEngine, ev: TaskEvent) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    for (t.subs) |*s| {
        if (guard.isSelf(ev.provenance, s.name)) continue;
        for (s.task) |*x| {
            if (std.mem.indexOfScalar(TaskEventKind, x.kinds, ev.kind) == null) continue;
            if (x.query) |*q| if (!q.matches(&ev.task)) continue;
            t.queueTask(s.name, ev) catch {};
            break;
        }
    }
    t.wake_ev.set(t.io);
}

/// Fires due bursts and queued events; returns how long to sleep (ms).
pub fn poll(t: *TriggerEngine) i64 {
    var due: std.ArrayList(Work) = .empty;
    defer {
        for (due.items) |*w| w.deinit(t.gpa);
        due.deinit(t.gpa);
    }
    var sleep = t.o.max_sleep_ms;
    {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const now = t.nowMs();
        var i: usize = 0;
        while (i < t.pending.count()) {
            const p = &t.pending.values()[i];
            if (p.deadline > now) {
                sleep = @min(sleep, p.deadline - now);
                i += 1;
                continue;
            }
            const name = t.pending.keys()[i];
            const payload = filesPayload(t.gpa, p) catch {
                i += 1;
                continue;
            };
            due.append(t.gpa, .{ .name = name, .payload = payload, .depth = p.depth }) catch {
                t.gpa.free(payload);
                i += 1;
                continue;
            };
            p.deinit(t.gpa);
            t.pending.swapRemoveAt(i);
        }
        if (due.appendSlice(t.gpa, t.work.items)) |_| t.work.clearRetainingCapacity() else |_| {}
    }
    for (due.items) |*w| t.dispatch(w);
    return @max(sleep, 0);
}

fn dispatch(t: *TriggerEngine, w: *const Work) void {
    if (w.revset) |r| {
        const rp = t.o.revsets orelse return;
        const ok = rp.contains(rp.ctx, r, w.change_ids) catch false;
        if (!ok) return;
    }
    if (w.task_id) |id| if (t.o.claims) |cp| {
        const ok = cp.claim(cp.ctx, id, w.name) catch false;
        if (!ok) {
            t.port.skip(t.port.ctx, w.name, .already_claimed);
            return;
        }
    };
    _ = t.port.fire(t.port.ctx, w.name, w.payload, .{ .depth = w.depth, .task_id = w.task_id }) catch return;
    _ = t.fired.fetchAdd(1, .monotonic);
}

pub fn start(t: *TriggerEngine) !void {
    if (t.running) return;
    t.running = true;
    t.stopping.store(false, .release);
    t.group.concurrent(t.io, loop, .{t}) catch |e| {
        t.running = false;
        return e;
    };
}

pub fn stop(t: *TriggerEngine) void {
    if (!t.running) return;
    t.stopping.store(true, .release);
    t.wake_ev.set(t.io);
    t.group.await(t.io) catch {};
    t.running = false;
}

fn loop(t: *TriggerEngine) void {
    while (!t.stopping.load(.acquire)) {
        const ms = t.poll();
        if (t.stopping.load(.acquire)) break;
        t.wake_ev.waitTimeout(t.io, .{ .duration = .{ .raw = .fromMilliseconds(@max(ms, 1)), .clock = .awake } }) catch {};
        t.wake_ev.reset();
    }
}

fn nowMs(t: *const TriggerEngine) i64 {
    if (t.o.clock) |c| return c.nowRealMs(c.ctx);
    return @intCast(@divFloor(Io.Clock.real.now(t.io).nanoseconds, std.time.ns_per_ms));
}

fn maskHas(m: EventMask, k: FileKind) bool {
    return switch (k) {
        .created => m.created,
        .modified => m.modified,
        .deleted => m.deleted,
        .renamed => m.renamed,
    };
}

fn maskAdd(m: *EventMask, k: FileKind) void {
    switch (k) {
        .created => m.created = true,
        .modified => m.modified = true,
        .deleted => m.deleted = true,
        .renamed => m.renamed = true,
    }
}

/// A run of `name` that is running, or ended within the window, listed
/// `path` as an output.
fn ownOutput(t: *const TriggerEngine, v: *const runs.RunsView, name: []const u8, path: []const u8, now: i64) bool {
    var buf: [4096]u8 = undefined;
    for (v.runs) |rec| {
        if (!AutomationRunner.isAutomation(rec, name)) continue;
        if (rec.ended_ms) |e| if (now - e > t.o.self_window_ms) continue;
        for (rec.outputs) |out| switch (out) {
            .file => |f| if (guard.normalize(f, &buf)) |p| if (std.mem.eql(u8, p, path)) return true,
            else => {},
        };
    }
    return false;
}

fn addPending(t: *TriggerEngine, name: []const u8, path: []const u8, kind: FileKind, depth: u8, deadline: i64) !void {
    const gp = try t.pending.getOrPut(t.gpa, name);
    if (!gp.found_existing) {
        gp.key_ptr.* = t.gpa.dupe(u8, name) catch |e| {
            t.pending.swapRemoveAt(gp.index);
            return e;
        };
        gp.value_ptr.* = .{};
    }
    const p = gp.value_ptr;
    p.deadline = deadline;
    p.depth = @max(p.depth, depth);
    if (p.paths.getPtr(path)) |m| {
        maskAdd(m, kind);
        return;
    }
    if (p.paths.count() >= t.o.max_paths) {
        p.dropped +|= 1;
        return;
    }
    const key = try t.gpa.dupe(u8, path);
    errdefer t.gpa.free(key);
    var m: EventMask = .{ .created = false, .modified = false, .deleted = false, .renamed = false };
    maskAdd(&m, kind);
    try p.paths.put(t.gpa, key, m);
}

fn queueScm(t: *TriggerEngine, name: []const u8, sub: *const ScmSub, ev: ScmEvent) !void {
    var w: Work = .{ .name = try t.gpa.dupe(u8, name), .payload = &.{}, .depth = guard.depthFor(ev.provenance) };
    errdefer w.deinit(t.gpa);
    w.payload = try scmPayload(t.gpa, ev);
    if (sub.revset) |r| {
        w.revset = try t.gpa.dupe(u8, r);
        const ids = try t.gpa.alloc([]const u8, ev.change_ids.len);
        var n: usize = 0;
        errdefer {
            for (ids[0..n]) |c| t.gpa.free(c);
            t.gpa.free(ids);
        }
        for (ev.change_ids) |c| {
            ids[n] = try t.gpa.dupe(u8, c);
            n += 1;
        }
        w.change_ids = ids;
    }
    try t.work.append(t.gpa, w);
}

fn queueTask(t: *TriggerEngine, name: []const u8, ev: TaskEvent) !void {
    var w: Work = .{ .name = try t.gpa.dupe(u8, name), .payload = &.{}, .depth = guard.depthFor(ev.provenance) };
    errdefer w.deinit(t.gpa);
    w.payload = try taskPayload(t.gpa, ev);
    w.task_id = try t.gpa.dupe(u8, ev.task.id);
    try t.work.append(t.gpa, w);
}

// ---- payloads (untrusted data for the run) ----

fn filesPayload(gpa: Allocator, p: *const Pending) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("event");
    try js.write("files");
    try js.objectField("paths");
    try js.beginArray();
    for (p.paths.keys(), p.paths.values()) |path, m| {
        try js.beginObject();
        try js.objectField("path");
        try js.write(path);
        try js.objectField("kinds");
        try js.beginArray();
        inline for (.{ "created", "modified", "deleted", "renamed" }) |f| if (@field(m, f)) try js.write(f);
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("truncated");
    try js.write(p.dropped > 0);
    try js.endObject();
    return out.toOwnedSlice();
}

fn scmPayload(gpa: Allocator, ev: ScmEvent) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("event");
    try js.write("scm");
    try js.objectField("kind");
    try js.write(@tagName(ev.kind));
    try js.objectField("change_ids");
    try js.write(ev.change_ids);
    try js.objectField("descriptions");
    try js.write(ev.descriptions);
    if (ev.lane) |l| {
        try js.objectField("lane");
        try js.write(l);
    }
    if (ev.bookmark) |b| {
        try js.objectField("bookmark");
        try js.write(b);
    }
    try js.endObject();
    return out.toOwnedSlice();
}

fn taskPayload(gpa: Allocator, ev: TaskEvent) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try js.beginObject();
    try js.objectField("event");
    try js.write("task");
    try js.objectField("kind");
    try js.write(@tagName(ev.kind));
    try js.objectField("task");
    try js.write(ev.task);
    try js.endObject();
    return out.toOwnedSlice();
}

// ---- task queries ----

/// F03's query syntax, the part triggers use: `status:ready`,
/// `label:agent` (each must be present), `assignee:name`,
/// `priority:P1` or `priority:>=P1` (at least as urgent; also `<=`, `>`,
/// `<`), and bare words, which must all occur in the title (ignoring
/// case).
pub const TaskQuery = struct {
    status: ?[]const u8 = null,
    labels: []const []const u8 = &.{},
    assignee: ?[]const u8 = null,
    priority: ?struct { op: Op, value: u8 } = null,
    words: []const []const u8 = &.{},

    pub const Op = enum { eq, at_least, at_most, more, less };

    pub fn parse(a: Allocator, q: []const u8) !TaskQuery {
        var r: TaskQuery = .{};
        var labels: std.ArrayList([]const u8) = .empty;
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, q, " \t");
        while (it.next()) |tok| {
            const colon = std.mem.indexOfScalar(u8, tok, ':') orelse {
                try words.append(a, try a.dupe(u8, tok));
                continue;
            };
            const key = tok[0..colon];
            const val = tok[colon + 1 ..];
            if (val.len == 0) return error.InvalidTaskQuery;
            if (std.mem.eql(u8, key, "status")) {
                r.status = try a.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "label")) {
                try labels.append(a, try a.dupe(u8, val));
            } else if (std.mem.eql(u8, key, "assignee")) {
                r.assignee = try a.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "priority")) {
                var v = val;
                var op: Op = .eq;
                for ([_]struct { []const u8, Op }{ .{ ">=", .at_least }, .{ "<=", .at_most }, .{ ">", .more }, .{ "<", .less } }) |p| {
                    if (std.mem.startsWith(u8, v, p[0])) {
                        op = p[1];
                        v = v[p[0].len..];
                        break;
                    }
                }
                if (v.len != 2 or (v[0] != 'P' and v[0] != 'p') or v[1] < '0' or v[1] > '3') return error.InvalidTaskQuery;
                r.priority = .{ .op = op, .value = v[1] - '0' };
            } else return error.InvalidTaskQuery;
        }
        r.labels = labels.items;
        r.words = words.items;
        return r;
    }

    pub fn matches(q: *const TaskQuery, t: *const Task) bool {
        if (q.status) |s| if (!std.ascii.eqlIgnoreCase(s, t.status)) return false;
        if (q.assignee) |a| if (t.assignee == null or !std.ascii.eqlIgnoreCase(a, t.assignee.?)) return false;
        for (q.labels) |l| {
            const has = for (t.labels) |tl| {
                if (std.ascii.eqlIgnoreCase(l, tl)) break true;
            } else false;
            if (!has) return false;
        }
        if (q.priority) |p| {
            const v = t.priority orelse return false;
            // Lower numbers are more urgent: ">=P1" is P0 or P1.
            const ok = switch (p.op) {
                .eq => v == p.value,
                .at_least => v <= p.value,
                .at_most => v >= p.value,
                .more => v < p.value,
                .less => v > p.value,
            };
            if (!ok) return false;
        }
        for (q.words) |w| if (std.ascii.indexOfIgnoreCase(t.title, w) == null) return false;
        return true;
    }
};
