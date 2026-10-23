//! The scheduler (E13.F02.S01.T02): owns a workspace's scheduled
//! automations, sleeps until the earliest due time, and fires through the
//! automation runner, applying catch-up, overlap, rate-limit and budget
//! policy and persisting what it fired. One process fires: the one
//! holding the lease (`lease.zig`).
//!
//! Timing: the loop sleeps on the awake clock for at most 60 s at a time
//! and re-reads the wall clock on each wake, so wall-clock jumps (NTP,
//! manual changes, suspend) cost at most a minute of error. Nothing else
//! wakes it except `setAutomations`, `fireNow` and `wake`.
//!
//! Due handling: a fire at most `grace_ms` late runs as `scheduled`. A
//! later one (the machine slept or the app was closed) gathers every fire
//! missed in the last 7 days: with `catch_up = latest` the most recent one
//! runs once as `catch_up` and the rest are recorded as
//! `asleep_discarded`; with `none` all are discarded.
//!
//! Wall clock jumps: forward is a missed fire (above); backward keeps the
//! next due time, so nothing fires twice, unless the jump is over an hour,
//! when the schedule restarts from the new time.
//!
//! The scan for the earliest due time is linear: workspaces have tens of
//! automations, and it runs once per wake.

const std = @import("std");
const zg_core = @import("zg_core");
const runs = @import("../runs/root.zig");
const cron = @import("cron.zig");
const zone_mod = @import("zone.zig");
const auto = @import("automation.zig");
const jitter = @import("jitter.zig");
const state = @import("state.zig");
const lease_mod = @import("lease.zig");
const history = @import("history.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Automation = auto.Automation;
const RunId = runs.RunId;

pub const FireReason = history.FireReason;
pub const Skip = history.Skip;

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    /// Wall-clock unix milliseconds.
    nowRealMs: *const fn (ctx: ?*anyopaque) i64,
};

pub const FireRequest = struct {
    automation: []const u8,
    fire_id: u64,
    due_unix_ms: i64,
    reason: FireReason,
    /// How many automation runs led to this one (event triggers).
    depth: u8 = 0,
};

/// Turns fires into runs (`runner.zig`'s `AutomationRunner`; fakes in
/// tests). Called with the scheduler's lock held: implementations must not
/// call back into the scheduler, except `wake`.
pub const RunnerIface = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fire: *const fn (ctx: *anyopaque, a: *const Automation, req: FireRequest, payload: ?[]const u8) anyerror!?RunId,
        /// A run of `name` has not ended.
        isRunning: *const fn (ctx: *anyopaque, name: []const u8) bool,
        /// Stops `name`'s runs gracefully (overlap `replace`).
        stopRunning: *const fn (ctx: *anyopaque, name: []const u8) void,
        /// `name`'s cost this calendar month, in micro-USD.
        monthCostMicros: *const fn (ctx: *anyopaque, name: []const u8) u64,
        /// A one-time warning for the user (budget exhausted, chain limit).
        warn: *const fn (ctx: *anyopaque, name: []const u8, message: []const u8) void,
    };
};

pub const Options = struct {
    /// Mixed into the jitter so workspaces differ.
    workspace_key: []const u8 = "",
    grace_ms: i64 = 90_000,
    /// The longest sleep.
    max_sleep_ms: i64 = 60_000,
    catch_up_window_ms: i64 = 7 * std.time.ms_per_day,
    /// Across all automations (`agents.automations.max_runs_per_hour`).
    global_max_runs_per_hour: u32 = 60,
    /// Null runs the loop only when `poll` is called (tests).
    clock: ?Clock = null,
    /// Missed fires recorded one by one, at most (the most recent).
    max_discard_records: u32 = 50,
};

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    def: Automation,
    zon: []const u8,
    expr: ?cron.CronExpr = null,
    once_ms: ?i64 = null,
    jitter_ms: i64 = 0,
    /// Nominal (unjittered) next due time; null when nothing is scheduled.
    next_due_ms: ?i64 = null,
    last_due_ms: i64 = 0,
    last_fire_id: u64 = 0,
    last_status: state.Status = .none,
    completed: bool = false,
    /// Fire times in the last hour.
    fires: std.ArrayList(i64) = .empty,
    /// One fire held back by overlap `queue`.
    pending: ?FireRequest = null,
    budget_warned: bool = false,

    fn name(e: *const Entry) []const u8 {
        return e.def.name;
    }
};

const Scheduler = @This();

gpa: Allocator,
io: Io,
zone: zone_mod.ZoneResolver,
state_dir: Io.Dir,
history_dir: ?Io.Dir,
runner: RunnerIface,
o: Options,
mutex: Io.Mutex = .init,
entries: std.ArrayList(*Entry) = .empty,
next_fire_id: u64 = 1,
global_fires: std.ArrayList(i64) = .empty,
saved: state.File = .{},
saved_arena: std.heap.ArenaAllocator,
dirty: bool = false,
lease: ?lease_mod.Lease = null,
last_lease_try_ms: ?i64 = null,
wake_ev: Io.Event = .unset,
stopping: std.atomic.Value(bool) = .init(false),
group: Io.Group = .init,
running: bool = false,
/// Loop iterations (for the idle-wakeup budget).
wakeups: std.atomic.Value(u64) = .init(0),

/// `state_dir` is `.zigguro/state` (state and lease); `history_dir` is
/// `.zigguro/runs/automations`. Both stay open for the scheduler's life.
pub fn init(gpa: Allocator, io: Io, z: zone_mod.ZoneResolver, state_dir: Io.Dir, history_dir: ?Io.Dir, runner: RunnerIface, o: Options) !*Scheduler {
    const s = try gpa.create(Scheduler);
    errdefer gpa.destroy(s);
    s.* = .{ .gpa = gpa, .io = io, .zone = z, .state_dir = state_dir, .history_dir = history_dir, .runner = runner, .o = o, .saved_arena = .init(gpa) };
    s.saved = try state.load(s.saved_arena.allocator(), io, state_dir);
    s.next_fire_id = @max(s.saved.next_fire_id, 1);
    return s;
}

pub fn deinit(s: *Scheduler) void {
    s.stop();
    for (s.entries.items) |e| s.freeEntry(e);
    s.entries.deinit(s.gpa);
    s.global_fires.deinit(s.gpa);
    s.saved_arena.deinit();
    s.gpa.destroy(s);
}

fn freeEntry(s: *Scheduler, e: *Entry) void {
    e.fires.deinit(s.gpa);
    e.arena.deinit();
    s.gpa.destroy(e);
}

pub fn nowMs(s: *const Scheduler) i64 {
    if (s.o.clock) |c| return c.nowRealMs(c.ctx);
    return @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_ms));
}

// ---- automations ----

/// Replaces the set of automations. Unchanged ones keep their runtime
/// state; new ones start from the persisted state (so fires missed while
/// the app was closed are caught up). Wakes the loop.
pub fn setAutomations(s: *Scheduler, list: []const Automation) !void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const now = s.nowMs();
    var next: std.ArrayList(*Entry) = .empty;
    defer next.deinit(s.gpa);
    errdefer for (next.items) |e| if (std.mem.indexOfScalar(*Entry, s.entries.items, e) == null) s.freeEntry(e);
    for (list) |a| {
        const zon = try auto.toZon(s.gpa, &a);
        defer s.gpa.free(zon);
        if (s.findLocked(a.name)) |old| if (std.mem.eql(u8, old.zon, zon)) {
            try next.append(s.gpa, old);
            continue;
        };
        const e = try s.gpa.create(Entry);
        e.* = .{ .arena = .init(s.gpa), .def = undefined, .zon = undefined };
        errdefer s.freeEntry(e);
        const ar = e.arena.allocator();
        e.def = try auto.clone(ar, a);
        e.zon = try ar.dupe(u8, zon);
        if (s.findLocked(a.name)) |old| {
            e.last_due_ms = old.last_due_ms;
            e.last_fire_id = old.last_fire_id;
            e.last_status = old.last_status;
            e.completed = old.completed;
            try e.fires.appendSlice(s.gpa, old.fires.items);
        } else if (state.find(s.saved, a.name)) |st| {
            e.last_due_ms = st.last_due_ms;
            e.last_fire_id = st.last_fire_id;
            e.last_status = st.last_status;
            e.completed = st.completed;
        }
        s.plan(e, now);
        try next.append(s.gpa, e);
    }
    for (s.entries.items) |old| {
        if (std.mem.indexOfScalar(*Entry, next.items, old) == null) s.freeEntry(old);
    }
    s.entries.clearRetainingCapacity();
    try s.entries.appendSlice(s.gpa, next.items);
    s.dirty = true;
    s.wake_ev.set(s.io);
}

/// Computes an entry's schedule and first due time.
fn plan(s: *Scheduler, e: *Entry, now: i64) void {
    e.next_due_ms = null;
    if (!e.def.enabled or e.completed) return;
    if (e.def.schedule()) |sch| {
        e.expr = cron.CronExpr.parse(sch.cron) catch return;
        const j = sch.jitter_s orelse jitter.defaultS(&e.expr.?);
        e.jitter_ms = @as(i64, jitter.offsetS(s.o.workspace_key, e.def.name, j)) * 1000;
        // From the last handled due time, so missed fires are seen.
        const from = if (e.last_due_ms > 0 and e.last_due_ms <= now) e.last_due_ms else now;
        e.next_due_ms = s.cronAfter(e, from);
    } else if (e.def.once()) |o| {
        const l = auto.parseLocal(o.at) orelse return;
        const t: i64 = switch (s.zone.fromLocal(s.zone.ctx, l)) {
            .unique => |x| x,
            .ambiguous => |x| x[0],
            .gap => |x| x,
        };
        e.once_ms = t * 1000;
        e.next_due_ms = e.once_ms;
    }
}

/// The nominal due time after `after_ms` (whole seconds), or null.
fn cronAfter(s: *Scheduler, e: *const Entry, after_ms: i64) ?i64 {
    const t = e.expr.?.next(s.zone, @divFloor(after_ms, 1000)) orelse return null;
    return t * 1000;
}

fn findLocked(s: *Scheduler, name: []const u8) ?*Entry {
    for (s.entries.items) |e| if (std.mem.eql(u8, e.name(), name)) return e;
    return null;
}

/// The next `out.len` fire times (unix ms, jitter included) of `name`
/// from now, for the UI. Returns how many were filled.
pub fn nextFires(s: *Scheduler, name: []const u8, out: []i64) usize {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const e = s.findLocked(name) orelse return 0;
    var due = e.next_due_ms orelse return 0;
    var n: usize = 0;
    while (n < out.len) {
        out[n] = due + e.jitter_ms;
        n += 1;
        if (e.expr == null) break;
        due = s.cronAfter(e, due) orelse break;
    }
    return n;
}

/// The next `out.len` fire times (unix ms, jitter included) of a
/// scheduled or one-off automation after `now_ms`, without a scheduler
/// (tools, CLI, the editor preview). Returns how many were filled.
pub fn upcoming(a: *const Automation, z: zone_mod.ZoneResolver, workspace_key: []const u8, now_ms: i64, out: []i64) usize {
    if (!a.enabled) return 0;
    if (a.schedule()) |sch| {
        const expr = cron.CronExpr.parse(sch.cron) catch return 0;
        const j: i64 = @as(i64, jitter.offsetS(workspace_key, a.name, sch.jitter_s orelse jitter.defaultS(&expr))) * 1000;
        var t = @divFloor(now_ms - j, 1000);
        var n: usize = 0;
        while (n < out.len) : (n += 1) {
            t = expr.next(z, t) orelse break;
            out[n] = t * 1000 + j;
        }
        return n;
    }
    if (a.once()) |o| {
        const l = auto.parseLocal(o.at) orelse return 0;
        const t: i64 = switch (z.fromLocal(z.ctx, l)) {
            .unique => |x| x,
            .ambiguous => |x| x[0],
            .gap => |x| x,
        };
        if (t * 1000 <= now_ms or out.len == 0) return 0;
        out[0] = t * 1000;
        return 1;
    }
    return 0;
}

// ---- the loop ----

/// Starts the loop (`clock` must be null: the loop uses the real clock).
pub fn start(s: *Scheduler) !void {
    std.debug.assert(!s.running);
    s.running = true;
    s.stopping.store(false, .release);
    s.group.concurrent(s.io, loop, .{s}) catch |e| {
        s.running = false;
        return e;
    };
}

/// Stops the loop and releases the lease. Idempotent.
pub fn stop(s: *Scheduler) void {
    if (s.running) {
        s.stopping.store(true, .release);
        s.wake_ev.set(s.io);
        s.group.await(s.io) catch {};
        s.running = false;
    }
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    s.saveLocked();
    if (s.lease) |l| l.release(s.io);
    s.lease = null;
}

/// Makes the loop look again now (a run ended, so a queued fire may go).
pub fn wake(s: *Scheduler) void {
    s.wake_ev.set(s.io);
}

fn loop(s: *Scheduler) void {
    while (!s.stopping.load(.acquire)) {
        const ms = s.poll();
        if (s.stopping.load(.acquire)) break;
        s.wake_ev.waitTimeout(s.io, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }) catch {};
        s.wake_ev.reset();
    }
}

/// Handles everything due now and returns how long to sleep (ms).
pub fn poll(s: *Scheduler) i64 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    _ = s.wakeups.fetchAdd(1, .monotonic);
    const now = s.nowMs();
    if (s.lease == null) {
        const due_try = if (s.last_lease_try_ms) |t| now - t >= lease_mod.retry_ms or now < t else true;
        if (due_try) {
            s.last_lease_try_ms = now;
            s.lease = lease_mod.Lease.tryAcquire(s.io, s.state_dir) catch null;
        }
        if (s.lease == null) return std.math.clamp(lease_mod.retry_ms - (now - s.last_lease_try_ms.?), 1, s.o.max_sleep_ms);
    }
    pruneHour(&s.global_fires, now);
    for (s.entries.items) |e| s.processDue(e, now);
    for (s.entries.items) |e| {
        if (e.pending) |p| if (!s.runner.vtable.isRunning(s.runner.ctx, e.name())) {
            e.pending = null;
            s.startFire(e, p, null, now);
        };
    }
    if (s.dirty) s.saveLocked();
    var sleep = s.o.max_sleep_ms;
    for (s.entries.items) |e| if (e.next_due_ms) |d| {
        sleep = @min(sleep, d + e.jitter_ms - now);
    };
    return @max(sleep, 1);
}

fn processDue(s: *Scheduler, e: *Entry, now: i64) void {
    // A big backward jump: restart the schedule from now.
    if (e.expr != null and e.last_due_ms > now + std.time.ms_per_hour) {
        e.last_due_ms = 0;
        e.next_due_ms = s.cronAfter(e, now);
    }
    while (e.next_due_ms) |due| {
        if (due + e.jitter_ms > now) return;
        const late = now - (due + e.jitter_ms);
        const reason: FireReason = if (e.expr == null) .once else .scheduled;
        if (late <= s.o.grace_ms) {
            s.handle(e, due, reason, now);
            e.next_due_ms = if (e.expr != null) s.cronAfter(e, due) else null;
            continue;
        }
        // Missed: keep the most recent ones in a ring, count the rest.
        var ring: [64]i64 = undefined;
        const cap = @min(ring.len, @as(usize, s.o.max_discard_records) + 1);
        var seen: usize = 0;
        var d: ?i64 = due;
        const window_start = now - s.o.catch_up_window_ms;
        if (e.expr != null and due < window_start) d = s.cronAfter(e, window_start - 1);
        while (d) |x| {
            if (x + e.jitter_ms > now) break;
            ring[seen % cap] = x;
            seen += 1;
            d = if (e.expr != null) s.cronAfter(e, x) else null;
        }
        if (seen == 0) {
            // Everything missed was older than the window.
            e.next_due_ms = d;
            continue;
        }
        const latest = ring[(seen - 1) % cap];
        const kept = @min(seen, cap);
        var i: usize = seen - kept;
        while (i < seen - 1) : (i += 1) s.record(e, ring[i % cap], .catch_up, null, .asleep_discarded, 0, now);
        if (e.def.catch_up == .latest) {
            s.handle(e, latest, if (e.expr == null) .once else .catch_up, now);
        } else {
            s.record(e, latest, .catch_up, null, .asleep_discarded, 0, now);
            e.last_due_ms = latest;
            e.last_status = .skipped;
            if (e.expr == null) e.completed = true;
            s.dirty = true;
        }
        e.next_due_ms = d;
    }
}

/// One due time: policy, then the fire.
fn handle(s: *Scheduler, e: *Entry, due: i64, reason: FireReason, now: i64) void {
    e.last_due_ms = due;
    s.dirty = true;
    if (e.expr == null) e.completed = true;
    if (s.policySkip(e, now)) |skip| {
        s.record(e, due, reason, null, skip, 0, now);
        e.last_status = .skipped;
        return;
    }
    const req: FireRequest = .{ .automation = e.name(), .fire_id = 0, .due_unix_ms = due, .reason = reason };
    if (s.runner.vtable.isRunning(s.runner.ctx, e.name())) switch (e.def.overlap) {
        .skip => {
            s.record(e, due, reason, null, .overlap, 0, now);
            e.last_status = .skipped;
            return;
        },
        .queue => {
            // At most one waits; an older waiting fire gives way.
            if (e.pending) |old| s.record(e, old.due_unix_ms, old.reason, null, .overlap, 0, now);
            e.pending = req;
            return;
        },
        .replace => s.runner.vtable.stopRunning(s.runner.ctx, e.name()),
    };
    s.startFire(e, req, null, now);
}

/// Budget and rate limits, or null to go ahead.
fn policySkip(s: *Scheduler, e: *Entry, now: i64) ?Skip {
    if (e.def.budgets.monthly_cap_micro_usd) |cap| {
        if (s.runner.vtable.monthCostMicros(s.runner.ctx, e.name()) >= cap) {
            if (!e.budget_warned) {
                e.budget_warned = true;
                s.runner.vtable.warn(s.runner.ctx, e.name(), "Monthly budget reached: scheduled runs are skipped until next month.");
            }
            return .budget_exhausted;
        }
    }
    pruneHour(&e.fires, now);
    if (e.def.max_runs_per_hour) |m| if (e.fires.items.len >= m) return .rate_limited;
    if (s.global_fires.items.len >= s.o.global_max_runs_per_hour) return .rate_limited;
    return null;
}

fn startFire(s: *Scheduler, e: *Entry, req0: FireRequest, payload: ?[]const u8, now: i64) void {
    var req = req0;
    req.fire_id = s.next_fire_id;
    s.next_fire_id += 1;
    s.dirty = true;
    e.last_fire_id = req.fire_id;
    const run = s.runner.vtable.fire(s.runner.ctx, &e.def, req, payload) catch {
        s.record(e, req.due_unix_ms, req.reason, null, .failed, req.fire_id, now);
        e.last_status = .failed;
        return;
    };
    e.fires.append(s.gpa, now) catch {};
    s.global_fires.append(s.gpa, now) catch {};
    e.last_status = .fired;
    s.record(e, req.due_unix_ms, req.reason, run, null, req.fire_id, now);
}

fn record(s: *Scheduler, e: *const Entry, due: i64, reason: FireReason, run: ?RunId, skip: ?Skip, fire: u64, now: i64) void {
    const dir = s.history_dir orelse return;
    history.append(s.io, dir, e.name(), .{ .t = now, .due = due, .fire = fire, .reason = reason, .run = run, .skip = skip }) catch {};
}

fn pruneHour(list: *std.ArrayList(i64), now: i64) void {
    var keep: usize = 0;
    for (list.items) |t| if (now - t < std.time.ms_per_hour and t <= now) {
        list.items[keep] = t;
        keep += 1;
    };
    list.shrinkRetainingCapacity(keep);
}

fn saveLocked(s: *Scheduler) void {
    if (!s.dirty) return;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(state.Entry) = .empty;
    // Keep entries of automations not loaded right now (a file being
    // edited must not lose its last due time).
    for (s.saved.automations) |old| {
        if (s.findLocked(old.name) == null) list.append(a, old) catch return;
    }
    for (s.entries.items) |e| list.append(a, .{
        .name = e.name(),
        .last_due_ms = e.last_due_ms,
        .last_fire_id = e.last_fire_id,
        .last_status = e.last_status,
        .completed = e.completed,
    }) catch return;
    const f: state.File = .{ .next_fire_id = s.next_fire_id, .automations = list.items };
    state.save(s.gpa, s.io, s.state_dir, f) catch return;
    // Keep a copy for the next merge.
    s.saved_arena.deinit();
    s.saved_arena = .init(s.gpa);
    s.saved = .{
        .next_fire_id = f.next_fire_id,
        .automations = runs.run.deepClone([]const state.Entry, s.saved_arena.allocator(), f.automations) catch &.{},
    };
    s.dirty = false;
}

// ---- manual and event fires ----

pub const FireError = error{ UnknownAutomation, Disabled, AlreadyRunning } || Allocator.Error;

/// Fires `name` now ("Run now"): no rate limit and no budget check, and
/// a run still going is not replaced. A disabled automation does not run.
/// Returns the fire id.
pub fn fireNow(s: *Scheduler, name: []const u8) FireError!u64 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const e = s.findLocked(name) orelse return error.UnknownAutomation;
    // Disabled includes repository automations not yet approved.
    if (!e.def.enabled) return error.Disabled;
    const now = s.nowMs();
    if (s.runner.vtable.isRunning(s.runner.ctx, name)) return error.AlreadyRunning;
    const id = s.next_fire_id;
    s.startFire(e, .{ .automation = e.name(), .fire_id = 0, .due_unix_ms = now, .reason = .manual }, null, now);
    s.saveLocked();
    s.wake_ev.set(s.io);
    return id;
}

/// An event trigger matched (`triggers.zig`): the same policy as
/// scheduled fires, with an untrusted payload. Returns the fire id, or
/// null when skipped (the skip is in the history).
pub fn fireEvent(s: *Scheduler, name: []const u8, payload: ?[]const u8, depth: u8) FireError!?u64 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const e = s.findLocked(name) orelse return error.UnknownAutomation;
    if (!e.def.enabled) return error.Disabled;
    const now = s.nowMs();
    if (depth > e.def.max_chain_depth) {
        s.record(e, now, .triggered, null, .chain_limit, 0, now);
        s.runner.vtable.warn(s.runner.ctx, name, "Automation chain limit reached: a run triggered by another automation was not started.");
        return null;
    }
    if (s.policySkip(e, now)) |skip| {
        s.record(e, now, .triggered, null, skip, 0, now);
        return null;
    }
    if (s.runner.vtable.isRunning(s.runner.ctx, name)) switch (e.def.overlap) {
        .skip, .queue => {
            // Event payloads are not held back: the next event brings
            // the current state.
            s.record(e, now, .triggered, null, .overlap, 0, now);
            return null;
        },
        .replace => s.runner.vtable.stopRunning(s.runner.ctx, name),
    };
    const id = s.next_fire_id;
    s.startFire(e, .{ .automation = e.name(), .fire_id = 0, .due_unix_ms = now, .reason = .triggered, .depth = depth }, payload, now);
    s.saveLocked();
    return id;
}

/// The lease is ours (this process fires).
pub fn leased(s: *Scheduler) bool {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.lease != null;
}
