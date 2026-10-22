//! `RateLimiter`: pre-emptive, header-driven rate limiting per lane plus a
//! per-provider cap on in-flight calls. Without snapshots it is permissive,
//! so local servers are only limited by their concurrency cap.
//!
//! Each lane keeps the last reported headroom (requests and input tokens
//! remaining, the reset time) and spends it locally as calls start, so
//! concurrent agents don't all fire into an exhausted window. Waiters are
//! served FIFO per lane. All waits go through `Clock.sleep`, which is
//! cancelable.

const std = @import("std");
const events = @import("events.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Time source; tests inject `FakeClock`.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_fn: *const fn (ctx: ?*anyopaque, io: Io) i64,
    sleep_fn: *const fn (ctx: ?*anyopaque, io: Io, ms: u64) Io.Cancelable!void,

    /// Unix milliseconds.
    pub fn now(c: Clock, io: Io) i64 {
        return c.now_fn(c.ctx, io);
    }

    pub fn sleep(c: Clock, io: Io, ms: u64) Io.Cancelable!void {
        return c.sleep_fn(c.ctx, io, ms);
    }

    /// Wall clock for timestamps, monotonic sleeps.
    pub const real: Clock = .{ .now_fn = realNow, .sleep_fn = realSleep };

    fn realNow(_: ?*anyopaque, io: Io) i64 {
        return Io.Timestamp.now(io, .real).toMilliseconds();
    }

    fn realSleep(_: ?*anyopaque, io: Io, ms: u64) Io.Cancelable!void {
        return io.sleep(.fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64)))), .awake);
    }
};

/// A clock whose sleeps advance time instantly (deterministic tests).
pub const FakeClock = struct {
    now_ms: std.atomic.Value(i64),
    slept_ms: std.atomic.Value(u64) = .init(0),
    sleeps: std.atomic.Value(u32) = .init(0),

    pub fn init(start_ms: i64) FakeClock {
        return .{ .now_ms = .init(start_ms) };
    }

    pub fn clock(f: *FakeClock) Clock {
        return .{ .ctx = f, .now_fn = now, .sleep_fn = sleep };
    }

    pub fn advance(f: *FakeClock, ms: u64) void {
        _ = f.now_ms.fetchAdd(@intCast(ms), .acq_rel);
    }

    fn now(ctx: ?*anyopaque, _: Io) i64 {
        const f: *FakeClock = @ptrCast(@alignCast(ctx.?));
        return f.now_ms.load(.acquire);
    }

    fn sleep(ctx: ?*anyopaque, io: Io, ms: u64) Io.Cancelable!void {
        const f: *FakeClock = @ptrCast(@alignCast(ctx.?));
        try io.checkCancel();
        _ = f.slept_ms.fetchAdd(ms, .monotonic);
        _ = f.sleeps.fetchAdd(1, .monotonic);
        // Concurrent sleepers wake at their own deadlines: time only moves forward.
        const target = f.now_ms.load(.acquire) + @as(i64, @intCast(ms));
        _ = f.now_ms.fetchMax(target, .acq_rel);
    }
};

pub const Kind = enum { messages, count_tokens, models };

/// What a limit applies to: a provider instance, a model class, a call kind.
pub const Lane = struct {
    provider: []const u8,
    model_class: []const u8 = "",
    kind: Kind = .messages,
};

const LaneState = struct {
    req_remaining: ?u64 = null,
    tok_remaining: ?u64 = null,
    req_limit: ?u64 = null,
    tok_limit: ?u64 = null,
    reset_at: ?i64 = null,
    /// From `retry-after`: nothing starts before this.
    blocked_until: ?i64 = null,
    next_ticket: u64 = 0,
    queue: std.ArrayList(u64) = .empty,

    fn refresh(s: *LaneState, now: i64) void {
        if (s.reset_at) |r| if (r <= now) {
            s.req_remaining = s.req_limit;
            s.tok_remaining = s.tok_limit;
            s.reset_at = null;
        };
        if (s.blocked_until) |b| if (b <= now) {
            s.blocked_until = null;
        };
    }

    /// When the head waiter may start, or null if it may start now.
    fn waitUntil(s: *const LaneState, est: u64) ?i64 {
        if (s.blocked_until) |b| return b;
        const r = s.reset_at orelse return null;
        if (s.req_remaining) |n| if (n == 0) return r;
        if (s.tok_remaining) |n| if (n < est) return r;
        return null;
    }

    fn removeTicket(s: *LaneState, t: u64) void {
        for (s.queue.items, 0..) |x, i| if (x == t) {
            _ = s.queue.orderedRemove(i);
            return;
        };
    }
};

const ProviderState = struct {
    max: u32,
    in_flight: u32 = 0,
};

/// Held while a call runs; `release` frees the concurrency slot.
pub const Permit = struct {
    limiter: *RateLimiter,
    provider: *ProviderState,

    pub fn release(p: Permit, io: Io) void {
        const l = p.limiter;
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        p.provider.in_flight -= 1;
        l.cond.broadcast(io);
    }
};

pub const RateLimiter = struct {
    gpa: Allocator,
    clock: Clock = .real,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    arena: std.heap.ArenaAllocator,
    lanes: std.StringHashMapUnmanaged(*LaneState) = .empty,
    providers: std.StringHashMapUnmanaged(*ProviderState) = .empty,
    /// In-flight cap for providers without `setMaxConcurrent`.
    default_max_concurrent: u32 = 8,

    pub fn init(gpa: Allocator, clock: Clock) RateLimiter {
        return .{ .gpa = gpa, .clock = clock, .arena = .init(gpa) };
    }

    pub fn deinit(l: *RateLimiter) void {
        var it = l.lanes.valueIterator();
        while (it.next()) |s| s.*.queue.deinit(l.gpa);
        l.lanes.deinit(l.gpa);
        l.providers.deinit(l.gpa);
        l.arena.deinit();
    }

    /// Sets a provider instance's in-flight cap (`ai.providers.<id>.maxConcurrent`).
    pub fn setMaxConcurrent(l: *RateLimiter, io: Io, provider: []const u8, n: u32) Allocator.Error!void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        (try l.providerState(provider)).max = @max(n, 1);
        l.cond.broadcast(io);
    }

    /// Waits for headroom on `lane` and a free slot on its provider.
    pub fn acquire(l: *RateLimiter, io: Io, lane: Lane, est_input_tokens: u64) (Io.Cancelable || Allocator.Error)!Permit {
        try l.mutex.lock(io);
        var locked = true;
        defer if (locked) l.mutex.unlock(io);
        const ps = try l.providerState(lane.provider);
        const ls = try l.laneState(lane);
        const ticket = ls.next_ticket;
        ls.next_ticket += 1;
        try ls.queue.append(l.gpa, ticket);
        errdefer if (locked) {
            ls.removeTicket(ticket);
            l.cond.broadcast(io);
        };
        while (ls.queue.items[0] != ticket) try l.cond.wait(io, &l.mutex);
        while (true) {
            const now = l.clock.now(io);
            ls.refresh(now);
            const until = ls.waitUntil(est_input_tokens) orelse break;
            l.mutex.unlock(io);
            locked = false;
            const slept = l.clock.sleep(io, @intCast(@max(until - now, 1)));
            l.mutex.lockUncancelable(io);
            locked = true;
            try slept;
        }
        if (ls.req_remaining) |*n| n.* -|= 1;
        if (ls.tok_remaining) |*n| n.* -|= est_input_tokens;
        while (ps.in_flight >= ps.max) try l.cond.wait(io, &l.mutex);
        ps.in_flight += 1;
        ls.removeTicket(ticket);
        l.cond.broadcast(io);
        return .{ .limiter = l, .provider = ps };
    }

    /// Folds a provider's rate-limit snapshot into `lane`. A later reset
    /// time starts a new window; within a window the lower remaining wins,
    /// so out-of-order responses can't undo local spending.
    pub fn update(l: *RateLimiter, io: Io, lane: Lane, snap: events.RateLimitSnapshot) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const ls = l.laneState(lane) catch return;
        const now = l.clock.now(io);
        if (snap.retry_after_ms) |ra| {
            const until = now + @as(i64, @intCast(ra));
            ls.blocked_until = @max(ls.blocked_until orelse until, until);
        }
        if (snap.requests_limit) |v| ls.req_limit = v;
        if (snap.input_tokens_remaining == null) {
            if (snap.tokens_limit) |v| ls.tok_limit = v;
        }
        const reset: ?i64 = snap.reset_at_ms orelse if (snap.reset_ms) |r| now + @as(i64, @intCast(r)) else null;
        const tok = snap.input_tokens_remaining orelse snap.tokens_remaining;
        // A reset later than the one we track is a new server window. With
        // no tracked reset (we refreshed locally at the old reset) local
        // spending in the new window still counts, so take the minimum.
        const new_window = reset != null and ls.reset_at != null and reset.? > ls.reset_at.?;
        if (reset != null and ls.reset_at == null and reset.? > now) ls.reset_at = reset;
        if (new_window) {
            ls.reset_at = reset;
            if (snap.requests_remaining) |v| ls.req_remaining = v;
            if (tok) |v| ls.tok_remaining = v;
        } else {
            if (snap.requests_remaining) |v| ls.req_remaining = @min(ls.req_remaining orelse v, v);
            if (tok) |v| ls.tok_remaining = @min(ls.tok_remaining orelse v, v);
        }
        l.cond.broadcast(io);
    }

    fn providerState(l: *RateLimiter, name: []const u8) Allocator.Error!*ProviderState {
        if (l.providers.get(name)) |p| return p;
        const a = l.arena.allocator();
        const p = try a.create(ProviderState);
        p.* = .{ .max = l.default_max_concurrent };
        try l.providers.put(l.gpa, try a.dupe(u8, name), p);
        return p;
    }

    fn laneState(l: *RateLimiter, lane: Lane) Allocator.Error!*LaneState {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\x00{s}\x00{t}", .{ lane.provider, lane.model_class, lane.kind }) catch lane.provider;
        if (l.lanes.get(key)) |s| return s;
        const a = l.arena.allocator();
        const s = try a.create(LaneState);
        s.* = .{};
        try l.lanes.put(l.gpa, try a.dupe(u8, key), s);
        return s;
    }
};
