//! `NotificationRouter` (E13.F01.S03.T01): the one pipeline for agent
//! notifications. `post` (any thread) copies the notification, decides
//! under a short lock (policy, de-duplication, grouping) and queues it; a
//! worker task delivers to the OS backend and the toast sink, so delivery
//! never runs on the UI thread. Clicks come back through `activation()`
//! and go to the callbacks registered with `onActivated`.

const std = @import("std");
const zg_core = @import("zg_core");
const n_mod = @import("notification.zig");
const policy = @import("policy.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Notification = n_mod.Notification;
const RunId = n_mod.RunId;

pub const Policy = policy.Policy;
pub const FocusState = policy.FocusState;
pub const Route = policy.Route;

/// A notification or one of its actions was clicked (the action id is
/// "default" for the body). Called on the thread the OS backend reports
/// on: hand off to the UI thread before touching UI state.
pub const ActivationCallback = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, key: []const u8, action: []const u8, xdg_token: ?[]const u8) void,
};

pub const Stats = struct {
    posted: u64 = 0,
    suppressed: u64 = 0,
    toasts: u64 = 0,
    os: u64 = 0,
    replaced: u64 = 0,
    os_errors: u64 = 0,
};

const Msg = struct {
    arena: std.heap.ArenaAllocator,
    n: Notification,
    route: Route,
    admit: policy.Admit,
};

const NotificationRouter = @This();

gpa: Allocator,
io: Io,
rt: *zg_core.Runtime,
os: ?n_mod.OsBackend = null,
toasts: ?n_mod.ToastSink,
clock: Clock,

mutex: Io.Mutex = .init,
pol: Policy,
focused: bool = false,
visible: std.ArrayList(RunId) = .empty,
coalescer: policy.Coalescer,
stats: Stats = .{},
callbacks: std.ArrayList(ActivationCallback) = .empty,
/// Backend ids by slot (for `replaces`).
os_ids: std.AutoHashMapUnmanaged(u32, u64) = .empty,

// Worker state, under `qmu`.
qmu: Io.Mutex = .init,
qcond: Io.Condition = .init,
idle_cond: Io.Condition = .init,
queue: std.ArrayList(*Msg) = .empty,
closing: bool = false,
busy: bool = false,
group: Io.Group = .init,
inline_delivery: bool = false,

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    /// Milliseconds; defaults to the real clock.
    now: ?*const fn (ctx: ?*anyopaque) i64 = null,
};

pub const Options = struct {
    clock: Clock = .{},
    /// Deliver on the calling thread (tests without concurrency).
    inline_delivery: bool = false,
};

pub fn init(gpa: Allocator, rt: *zg_core.Runtime, os: ?n_mod.OsBackend, toasts: ?n_mod.ToastSink, pol: Policy, opts: Options) !*NotificationRouter {
    const r = try gpa.create(NotificationRouter);
    errdefer gpa.destroy(r);
    r.* = .{
        .gpa = gpa,
        .io = rt.io,
        .rt = rt,
        .os = os,
        .toasts = toasts,
        .clock = opts.clock,
        .pol = pol,
        .coalescer = .init(gpa),
        .inline_delivery = opts.inline_delivery,
    };
    if (!r.inline_delivery) r.group.concurrent(r.io, worker, .{r}) catch {
        r.inline_delivery = true;
    };
    return r;
}

/// Delivers what is queued, stops the worker and frees the router (and
/// the OS backend).
pub fn deinit(r: *NotificationRouter) void {
    r.qmu.lockUncancelable(r.io);
    r.closing = true;
    r.qcond.signal(r.io);
    r.qmu.unlock(r.io);
    if (!r.inline_delivery) r.group.await(r.io) catch {};
    for (r.queue.items) |m| r.freeMsg(m);
    r.queue.deinit(r.gpa);
    if (r.os) |o| o.deinit();
    r.visible.deinit(r.gpa);
    r.coalescer.deinit();
    r.callbacks.deinit(r.gpa);
    r.os_ids.deinit(r.gpa);
    r.gpa.destroy(r);
}

/// Replaces the OS backend (after it is created with `activation()`).
/// The router owns it from now on.
pub fn setOsBackend(r: *NotificationRouter, os: ?n_mod.OsBackend) void {
    r.flush();
    r.mutex.lockUncancelable(r.io);
    const old = r.os;
    r.os = os;
    r.os_ids.clearRetainingCapacity();
    r.mutex.unlock(r.io);
    if (old) |o| o.deinit();
}

/// What OS backends call when a notification is clicked.
pub fn activation(r: *NotificationRouter) n_mod.ActivateFn {
    return .{ .ctx = r, .f = activate };
}

fn activate(ctx: *anyopaque, key: []const u8, action: []const u8, token: ?[]const u8) void {
    const r: *NotificationRouter = @ptrCast(@alignCast(ctx));
    var buf: [8]ActivationCallback = undefined;
    const cbs = blk: {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const n = @min(buf.len, r.callbacks.items.len);
        @memcpy(buf[0..n], r.callbacks.items[0..n]);
        break :blk buf[0..n];
    };
    for (cbs) |cb| cb.f(cb.ctx, key, action, token);
}

pub fn onActivated(r: *NotificationRouter, cb: ActivationCallback) Allocator.Error!void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    try r.callbacks.append(r.gpa, cb);
}

/// Live settings reload.
pub fn setPolicy(r: *NotificationRouter, p: Policy) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.pol = p;
}

/// UI thread, when focus or the visible runs change.
pub fn setFocus(r: *NotificationRouter, f: FocusState) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.focused = f.window_focused;
    r.visible.clearRetainingCapacity();
    r.visible.appendSlice(r.gpa, f.visible_runs) catch {};
}

pub fn nowMs(r: *const NotificationRouter) i64 {
    if (r.clock.now) |f| return f(r.clock.ctx);
    return @intCast(@divFloor(Io.Clock.real.now(r.io).nanoseconds, std.time.ns_per_ms));
}

/// Posts `n` from any thread. Strings are copied; never blocks on
/// delivery.
pub fn post(r: *NotificationRouter, n: Notification) void {
    r.postInner(n) catch {};
}

fn postInner(r: *NotificationRouter, n: Notification) !void {
    const m = try r.gpa.create(Msg);
    m.* = .{ .arena = .init(r.gpa), .n = undefined, .route = .none, .admit = undefined };
    var queued = false;
    defer if (!queued) r.freeMsg(m);
    const a = m.arena.allocator();
    m.n = try clone(a, n);
    const now = r.nowMs();
    {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.stats.posted += 1;
        m.route = policy.route(r.pol, .{ .window_focused = r.focused, .visible_runs = r.visible.items }, &m.n);
        if (m.route == .none) {
            r.stats.suppressed += 1;
            return;
        }
        if (m.route == .os and r.os == null) m.route = .toast;
        m.admit = try r.coalescer.admit(r.pol, m.n.key, m.n.group, now);
        if (m.admit.replace) r.stats.replaced += 1;
        switch (m.route) {
            .toast => r.stats.toasts += 1,
            .os => r.stats.os += 1,
            .none => unreachable,
        }
    }
    if (m.admit.count > 1) {
        m.n.body = m.n.title;
        m.n.title = if (m.n.progress) |p|
            try std.fmt.allocPrint(a, "{d}/{d} done", .{ p.done, p.total })
        else
            try std.fmt.allocPrint(a, "{d} updates", .{m.admit.count});
    }
    r.qmu.lockUncancelable(r.io);
    defer r.qmu.unlock(r.io);
    try r.queue.append(r.gpa, m);
    queued = true;
    if (r.inline_delivery) r.drainLocked() else r.qcond.signal(r.io);
}

/// Blocks until every queued notification is delivered.
pub fn flush(r: *NotificationRouter) void {
    r.qmu.lockUncancelable(r.io);
    defer r.qmu.unlock(r.io);
    if (r.inline_delivery) return r.drainLocked();
    r.qcond.signal(r.io);
    while (r.queue.items.len != 0 or r.busy) r.idle_cond.waitUncancelable(r.io, &r.qmu);
}

fn worker(r: *NotificationRouter) void {
    r.qmu.lockUncancelable(r.io);
    defer r.qmu.unlock(r.io);
    while (true) {
        while (r.queue.items.len == 0 and !r.closing) r.qcond.waitUncancelable(r.io, &r.qmu);
        r.drainLocked();
        r.idle_cond.broadcast(r.io);
        if (r.closing and r.queue.items.len == 0) return;
    }
}

/// Called with `qmu` held; drops it around delivery.
fn drainLocked(r: *NotificationRouter) void {
    r.busy = true;
    defer r.busy = false;
    while (r.queue.items.len != 0) {
        var batch = r.queue;
        r.queue = .empty;
        r.qmu.unlock(r.io);
        for (batch.items) |m| {
            r.deliver(m);
            r.freeMsg(m);
        }
        batch.deinit(r.gpa);
        r.qmu.lockUncancelable(r.io);
    }
}

fn deliver(r: *NotificationRouter, m: *Msg) void {
    if (!r.inline_delivery) r.rt.assertNotUi();
    const slot = m.admit.slot;
    if (m.route == .os) os: {
        const os, const prev = blk: {
            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);
            break :blk .{ r.os orelse break :os, if (m.admit.replace) r.os_ids.get(slot) else null };
        };
        const id = os.show(&m.n, prev) catch {
            r.mutex.lockUncancelable(r.io);
            r.stats.os_errors += 1;
            r.mutex.unlock(r.io);
            break :os;
        };
        r.mutex.lockUncancelable(r.io);
        r.os_ids.put(r.gpa, slot, id) catch {};
        r.mutex.unlock(r.io);
    }
    // Every delivered notification lands in the notification center.
    if (r.toasts) |t| t.deliver(t.ctx, &m.n, slot, m.route == .toast);
}

fn freeMsg(r: *NotificationRouter, m: *Msg) void {
    m.arena.deinit();
    r.gpa.destroy(m);
}

fn clone(a: Allocator, n: Notification) Allocator.Error!Notification {
    var c = n;
    c.key = try a.dupe(u8, n.key);
    if (n.group) |g| c.group = try a.dupe(u8, g);
    c.title = try a.dupe(u8, n.title);
    c.body = try a.dupe(u8, n.body);
    const acts = try a.alloc(n_mod.NotifyAction, n.actions.len);
    for (acts, n.actions) |*d, s| d.* = .{ .id = try a.dupe(u8, s.id), .label = try a.dupe(u8, s.label) };
    c.actions = acts;
    return c;
}

/// The decision alone (the bench's `notify/decide`).
pub fn decide(r: *NotificationRouter, n: *const Notification) Allocator.Error!policy.Admit {
    const now = r.nowMs();
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const rt_ = policy.route(r.pol, .{ .window_focused = r.focused, .visible_runs = r.visible.items }, n);
    if (rt_ == .none) return .{ .slot = 0, .replace = false };
    return r.coalescer.admit(r.pol, n.key, n.group, now);
}
