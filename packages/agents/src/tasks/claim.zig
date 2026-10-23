//! Task claims (E13.F03.S02.T01): a run takes a task before working on
//! it, so no two agents work on the same task. The lock file
//! (`lease.zig`) decides who holds a claim across processes; the task's
//! `claimed_by` and `status` follow it in the Markdown (auto-applied
//! fields, written once per claim and once per release). Leases expire:
//! `maintain` renews the leases of live runs and releases expired ones,
//! putting their tasks back in `ready` with a line in the agent log.

const std = @import("std");
const runs = @import("../runs/root.zig");
const task_mod = @import("task.zig");
const view_mod = @import("view.zig");
const query_mod = @import("query.zig");
const ids = @import("ids.zig");
const lease = @import("lease.zig");
const TaskStore = @import("store.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = runs.RunId;
const TaskId = task_mod.TaskId;
const Status = task_mod.Status;
const Task = task_mod.Task;

pub const default_lease_s: u32 = 900;
/// Live runs' leases are renewed when this much of them has passed.
pub const renew_after_s: u32 = 300;
/// `claimNext` tries at most this many candidates.
pub const max_attempts = 16;

pub const Claim = struct { id: TaskId, run: RunId, until_s: i64 };

pub const ClaimResult = union(enum) {
    ok: Claim,
    taken_by: RunId,
    /// Unfinished dependencies (valid until the next claim).
    blocked: []const TaskId,
    not_ready: Status,
    not_found,
};

pub const Outcome = enum {
    /// Status done.
    done,
    /// Status review.
    review,
    /// Back to ready, with the error in the log.
    failed,
    /// Back to ready.
    abandoned,
    /// The lease ran out (the reaper); back to ready.
    expired,
};

/// Whether a run is still going (RunHost), for lease renewal.
pub const ActivePort = struct {
    ctx: *anyopaque,
    isActive: *const fn (ctx: *anyopaque, run: RunId) bool,
};

pub const Options = struct {
    lease_s: u32 = default_lease_s,
    grace_s: i64 = lease.default_grace_s,
    /// Written into lock files (diagnostics).
    host: []const u8 = "",
    pid: u32 = 0,
};

pub const ClaimOptions = struct {
    /// The user dispatched a backlog task explicitly.
    allow_backlog: bool = false,
};

pub const Error = error{NotClaimed} || TaskStore.Error || Io.Dir.OpenError;

const ClaimManager = @This();

gpa: Allocator,
io: Io,
store: *TaskStore,
dir: Io.Dir,
locks: lease.Locks,
o: Options,
mutex: Io.Mutex = .init,
blocked: std.ArrayList(TaskId) = .empty,

/// Opens (and creates) `.claims` in the store's directory.
pub fn init(gpa: Allocator, store: *TaskStore, o: Options) !*ClaimManager {
    const io = store.io;
    try store.dir.createDirPath(io, lease.dir_name);
    const dir = try store.dir.openDir(io, lease.dir_name, .{ .iterate = true });
    errdefer dir.close(io);
    // Claims are machine state, never committed.
    dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*\n", .flags = .{ .exclusive = true } }) catch {};
    const c = try gpa.create(ClaimManager);
    c.* = .{ .gpa = gpa, .io = io, .store = store, .dir = dir, .locks = .{ .io = io, .dir = dir, .grace_s = o.grace_s }, .o = o };
    return c;
}

pub fn deinit(c: *ClaimManager) void {
    c.dir.close(c.io);
    c.blocked.deinit(c.gpa);
    c.gpa.destroy(c);
}

fn nowS(c: *const ClaimManager) i64 {
    return @divFloor(c.store.nowMs(), 1000);
}

fn runText(buf: *[32]u8, run: RunId) []const u8 {
    return std.fmt.bufPrint(buf, "{f}", .{run}) catch unreachable;
}

pub fn claim(c: *ClaimManager, id: TaskId, run: RunId, lease_s: u32) !ClaimResult {
    return c.claimWith(id, run, lease_s, .{});
}

/// Takes task `id` for `run`: it must be ready (or backlog, when
/// allowed), with every dependency finished, and not held by another run.
pub fn claimWith(c: *ClaimManager, id: TaskId, run: RunId, lease_s: u32, opts: ClaimOptions) !ClaimResult {
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    {
        const v = c.store.view();
        defer c.store.release(v);
        const t = v.get(id) orelse return .not_found;
        if (t.status != .ready and !(opts.allow_backlog and t.status == .backlog)) return .{ .not_ready = t.status };
        c.blocked.clearRetainingCapacity();
        try v.blockedBy(id, &c.blocked, c.gpa);
        if (c.blocked.items.len > 0) return .{ .blocked = c.blocked.items };
    }
    const now = c.nowS();
    const until = now + lease_s;
    var name_buf: [32]u8 = undefined;
    const name = lease.lockName(&name_buf, id);
    switch (try c.locks.acquire(name, .{ .run = run, .until_s = until, .pid = c.o.pid, .host = c.o.host }, now)) {
        .taken => |h| return .{ .taken_by = h.run },
        .ok => {},
    }
    var rb: [32]u8 = undefined;
    _ = c.store.update(id, .{ .status = .in_progress, .claimed_by = @as(?[]const u8, runText(&rb, run)) }, .{ .agent = .{ .run = run } }) catch |e| {
        _ = c.locks.release(name, run) catch {};
        return e;
    };
    return .{ .ok = .{ .id = id, .run = run, .until_s = until } };
}

/// Claims the most urgent ready, unblocked, unclaimed task matching `q`
/// (priority, then due date, then id).
pub fn claimNext(c: *ClaimManager, run: RunId, q: *const query_mod.Query, lease_s: u32) !?TaskId {
    var cand: std.ArrayList(TaskId) = .empty;
    defer cand.deinit(c.gpa);
    {
        const v = c.store.view();
        defer c.store.release(v);
        var idx: std.ArrayList(u32) = .empty;
        defer idx.deinit(c.gpa);
        try query_mod.evalQueryAt(v, q, c.store.today(), &idx, c.gpa);
        var keep: std.ArrayList(u32) = .empty;
        defer keep.deinit(c.gpa);
        for (idx.items) |i| if (v.readyToClaim(v.tasks[i].id)) try keep.append(c.gpa, i);
        std.mem.sort(u32, keep.items, v, struct {
            fn less(vv: *const view_mod.TasksView, a: u32, b: u32) bool {
                const ta = &vv.tasks[a];
                const tb = &vv.tasks[b];
                if (ta.priority != tb.priority) return ta.priority < tb.priority;
                if ((ta.due == null) != (tb.due == null)) return ta.due != null;
                if (ta.due) |da| {
                    const o = query_mod.cmpDate(da, tb.due.?);
                    if (o != .eq) return o == .lt;
                }
                return ta.id < tb.id;
            }
        }.less);
        for (keep.items[0..@min(keep.items.len, max_attempts)]) |i| try cand.append(c.gpa, v.tasks[i].id);
    }
    for (cand.items) |id| switch (try c.claim(id, run, lease_s)) {
        .ok => return id,
        else => {},
    };
    return null;
}

/// Extends `run`'s lease on `id` by the default lease.
pub fn renew(c: *ClaimManager, id: TaskId, run: RunId) !void {
    var name_buf: [32]u8 = undefined;
    const name = lease.lockName(&name_buf, id);
    if (!try c.locks.renew(name, .{ .run = run, .until_s = c.nowS() + c.o.lease_s, .pid = c.o.pid, .host = c.o.host })) return error.NotClaimed;
}

/// Ends `run`'s claim on `id` with `outcome`; `note` goes to the agent
/// log for failures and releases.
pub fn release(c: *ClaimManager, id: TaskId, run: RunId, outcome: Outcome, note: ?[]const u8) !void {
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    var name_buf: [32]u8 = undefined;
    const name = lease.lockName(&name_buf, id);
    var rb: [32]u8 = undefined;
    const rt = runText(&rb, run);
    if (!try c.locks.release(name, run)) {
        // No lock of ours: fine only when the task still names the run
        // (the lock was reaped, or never written by an older version).
        const v = c.store.view();
        defer c.store.release(v);
        const t = v.get(id) orelse return error.TaskNotFound;
        if (t.claimed_by == null or !std.mem.eql(u8, t.claimed_by.?, rt)) return error.NotClaimed;
    }
    const status: Status = switch (outcome) {
        .done => .done,
        .review => .review,
        .failed, .abandoned, .expired => .ready,
    };
    _ = try c.store.update(id, .{ .status = status, .claimed_by = @as(?[]const u8, null) }, .{ .agent = .{ .run = run } });
    var lb: [512]u8 = undefined;
    var ts_buf: [32]u8 = undefined;
    const ts = timestamp(&ts_buf, c.nowS());
    const line: ?[]const u8 = switch (outcome) {
        .done, .review => null,
        .failed => std.fmt.bufPrint(&lb, "{s} run {s} failed: {s}", .{ ts, rt, note orelse "no reason given" }) catch null,
        .abandoned => std.fmt.bufPrint(&lb, "{s} released by run {s}{s}{s}", .{ ts, rt, if (note != null) ": " else "", note orelse "" }) catch null,
        .expired => std.fmt.bufPrint(&lb, "{s} claim by run {s} expired", .{ ts, rt }) catch null,
    };
    if (line) |l| try c.store.appendAgentLog(id, l);
}

pub const Maintenance = struct { renewed: u32 = 0, reaped: u32 = 0 };

/// Renews the leases of runs `active` says are live (once `renew_after_s`
/// of them has passed) and releases expired ones. Call it every 60 s.
pub fn maintain(c: *ClaimManager, active: ?ActivePort) !Maintenance {
    const now = c.nowS();
    var m: Maintenance = .{};
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| c.gpa.free(n);
        names.deinit(c.gpa);
    }
    var it = c.dir.iterate();
    while (try it.next(c.io)) |e| {
        if (e.kind != .file or lease.taskOf(e.name) == null) continue;
        try names.append(c.gpa, try c.gpa.dupe(u8, e.name));
    }
    for (names.items) |name| {
        const id = lease.taskOf(name).?;
        var buf: [512]u8 = undefined;
        const info = (try c.locks.read(name, &buf)) orelse continue;
        if (info.run.eql(.zero)) continue;
        const live = if (active) |a| a.isActive(a.ctx, info.run) else false;
        if (live) {
            if (info.until_s - now <= @as(i64, c.o.lease_s) - renew_after_s) {
                c.renew(id, info.run) catch continue;
                m.renewed += 1;
            }
            continue;
        }
        if (info.until_s < now - c.o.grace_s) {
            const run = info.run;
            c.release(id, run, .expired, null) catch |e| switch (e) {
                error.TaskNotFound => {
                    // The task is gone: just drop its lock.
                    _ = c.locks.release(name, run) catch {};
                    continue;
                },
                else => return e,
            };
            m.reaped += 1;
        }
    }
    return m;
}

/// Releases expired claims (no renewals); the count.
pub fn reapExpired(c: *ClaimManager) !u32 {
    return (try c.maintain(null)).reaped;
}

/// `2026-10-23 12:00Z`.
fn timestamp(buf: []u8, s: i64) []const u8 {
    const days = @divFloor(s, 86_400);
    const rem: u32 = @intCast(s - days * 86_400);
    const z = @import("../sched/zone.zig").civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}Z", .{ z.year, z.month, z.day, rem / 3600, rem / 60 % 60 }) catch "";
}
