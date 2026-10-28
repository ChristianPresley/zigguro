//! The trace drain (E14.F02.S01.T02): one concurrent task empties the
//! per-thread trace rings (`zg_core.trace.collect` is single-consumer) and
//! fans the events out to its consumers, a `TraceSession` and the
//! `FlightRecorder`.
//!
//! It never wakes on a timer at idle. It runs when a ring reaches a quarter
//! full (`zg_core.trace.fill_hook`), when the frame loop reports activity
//! (`noteActivity`) after the drain parked, every `active_interval_ns`
//! while activity continues, and when a consumer asks (`drainNow`, stop).

const std = @import("std");
const zg_core = @import("zg_core");

const Event = zg_core.trace.Event;
const log = std.log.scoped(.perf_trace);

/// Receives every drained batch, on the drain task (or the thread calling
/// `drainNow`). Batches arrive in order; `thread_name` events repeat.
pub const Consumer = struct {
    ctx: *anyopaque,
    consume: *const fn (ctx: *anyopaque, events: []const Event) void,
};

/// The drain.
pub const Drain = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    group: std.Io.Group = .init,
    /// Guards `consumers` and `buf`, and serializes `collect`.
    mutex: std.Io.Mutex = .init,
    consumers: [max_consumers]?Consumer = @splat(null),
    buf: std.ArrayList(Event) = .empty,
    /// Futex word bumped by every kick.
    kicks: std.atomic.Value(u32) = .init(0),
    /// The task is in an untimed wait (idle).
    parked: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    /// `.awake` ns of the last `noteActivity`.
    last_activity_ns: std.atomic.Value(u64) = .init(0),
    /// Times the task woke from a wait (diagnostics and tests).
    wakeups: std.atomic.Value(u64) = .init(0),
    /// Events delivered to consumers.
    drained: std.atomic.Value(u64) = .init(0),
    running: bool = false,

    /// Consumers at most (a session and the flight recorder, with room).
    pub const max_consumers = 4;
    /// Drain period while frames are being produced.
    pub const active_interval_ns: u64 = 100 * std.time.ns_per_ms;

    /// The drain that `noteActivity`, `kickGlobal` and the ring fill hook
    /// reach; set by `start`.
    pub var global: std.atomic.Value(?*Drain) = .init(null);

    /// A stopped drain.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Drain {
        return .{ .gpa = gpa, .io = io };
    }

    /// Spawns the drain task and makes this the global drain. Without
    /// concurrency in `io` the drain still works through `drainNow`.
    pub fn start(d: *Drain) void {
        zg_core.trace.init(d.io);
        d.stopping.store(false, .release);
        global.store(d, .release);
        zg_core.trace.fill_hook.store(&kickGlobal, .release);
        d.group.concurrent(d.io, loop, .{d}) catch {
            log.info("trace drain task unavailable: draining on demand only", .{});
            return;
        };
        d.running = true;
    }

    /// Final drain, then stops the task.
    pub fn stop(d: *Drain) void {
        if (global.load(.acquire) == d) {
            zg_core.trace.fill_hook.store(null, .release);
            global.store(null, .release);
        }
        d.stopping.store(true, .release);
        d.kick();
        if (d.running) d.group.await(d.io) catch {};
        d.running = false;
        d.drainNow();
    }

    /// Stops (if running) and frees the buffer.
    pub fn deinit(d: *Drain) void {
        if (d.running) d.stop();
        d.buf.deinit(d.gpa);
        d.* = undefined;
    }

    /// Adds a consumer; `error.TooManyConsumers` past `max_consumers`.
    pub fn add(d: *Drain, c: Consumer) error{TooManyConsumers}!void {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        for (&d.consumers) |*slot| if (slot.* == null) {
            slot.* = c;
            return;
        };
        return error.TooManyConsumers;
    }

    /// Removes the consumer with context `ctx`. After return the consumer
    /// is never called again.
    pub fn remove(d: *Drain, ctx: *anyopaque) void {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        for (&d.consumers) |*slot| if (slot.*) |c| if (c.ctx == ctx) {
            slot.* = null;
        };
    }

    /// Wakes the task (any thread; one atomic add and a futex wake).
    pub fn kick(d: *Drain) void {
        _ = d.kicks.fetchAdd(1, .release);
        d.io.futexWake(u32, &d.kicks.raw, 1);
    }

    /// Frame loop, once per frame: a relaxed store, plus a kick only when
    /// the drain parked.
    pub fn noteActivity(d: *Drain, now_ns: u64) void {
        d.last_activity_ns.store(now_ns, .monotonic);
        if (d.parked.load(.monotonic)) {
            d.parked.store(false, .monotonic);
            d.kick();
        }
    }

    /// Collects the rings and feeds every consumer, on the calling thread.
    pub fn drainNow(d: *Drain) void {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        d.buf.clearRetainingCapacity();
        zg_core.trace.collect(d.gpa, &d.buf) catch |err| {
            log.info("trace drain: {t}", .{err});
        };
        if (d.buf.items.len == 0) return;
        for (d.consumers) |slot| if (slot) |c| c.consume(c.ctx, d.buf.items);
        _ = d.drained.fetchAdd(d.buf.items.len, .monotonic);
        // Keep a burst's capacity, but not forever.
        if (d.buf.capacity > 1 << 20) d.buf.clearAndFree(d.gpa);
    }

    fn loop(d: *Drain) std.Io.Cancelable!void {
        const io = d.io;
        while (!d.stopping.load(.acquire)) {
            const seen = d.kicks.load(.acquire);
            d.drainNow();
            if (d.stopping.load(.acquire)) break;
            const now = zg_core.time.nowNs(io);
            const last = d.last_activity_ns.load(.monotonic);
            if (last != 0 and now -| last < active_interval_ns) {
                const deadline: std.Io.Clock.Timestamp = .{ .raw = .fromNanoseconds(@intCast(now + active_interval_ns)), .clock = .awake };
                try io.futexWaitTimeout(u32, &d.kicks.raw, seen, .{ .deadline = deadline });
            } else {
                d.parked.store(true, .release);
                // A kick between `seen` and here changes the word: no lost wake.
                try io.futexWait(u32, &d.kicks.raw, seen);
                d.parked.store(false, .release);
            }
            _ = d.wakeups.fetchAdd(1, .monotonic);
        }
    }
};

/// Kicks the global drain (the ring fill hook).
pub fn kickGlobal() void {
    if (Drain.global.load(.acquire)) |d| d.kick();
}

/// Frame loop hook: reports activity to the global drain, if any. One
/// atomic load when no drain runs.
pub fn noteActivity(now_ns: u64) void {
    if (Drain.global.load(.acquire)) |d| d.noteActivity(now_ns);
}

const Counter = struct {
    events: usize = 0,
    batches: usize = 0,
    fn consume(ctx: *anyopaque, evs: []const Event) void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        c.events += evs.len;
        c.batches += 1;
    }
};

test "drain: no drain wakeups without activity" {
    const io = std.testing.io;
    var d = Drain.init(std.testing.allocator, io);
    defer d.deinit();
    var c: Counter = .{};
    try d.add(.{ .ctx = &c, .consume = Counter.consume });
    d.start();
    if (!d.running) return error.SkipZigTest;
    // Let the first pass park, then sit idle.
    const t0 = zg_core.time.nowNs(io);
    while (!d.parked.load(.acquire)) {
        if (zg_core.time.nowNs(io) - t0 > std.time.ns_per_s) return error.TestUnexpectedResult;
        std.Thread.yield() catch {};
    }
    const before = d.wakeups.load(.acquire);
    try io.sleep(.fromMilliseconds(300), .awake);
    try std.testing.expectEqual(before, d.wakeups.load(.acquire));
    // Activity wakes it.
    d.noteActivity(zg_core.time.nowNs(io));
    const t1 = zg_core.time.nowNs(io);
    while (d.wakeups.load(.acquire) == before) {
        if (zg_core.time.nowNs(io) - t1 > std.time.ns_per_s) return error.TestUnexpectedResult;
        std.Thread.yield() catch {};
    }
    d.stop();
    d.remove(&c);
}

test "drain: consumers receive collected events" {
    var d = Drain.init(std.testing.allocator, std.testing.io);
    defer d.deinit();
    var c: Counter = .{};
    try d.add(.{ .ctx = &c, .consume = Counter.consume });
    d.start();
    zg_core.trace.zone(@src(), "perf.drain_test").end();
    d.stop();
    if (zg_core.trace.enabled) try std.testing.expect(c.events >= 1);
    d.remove(&c);
    var extra: [Drain.max_consumers]Counter = @splat(.{});
    for (extra[0..Drain.max_consumers]) |*e| try d.add(.{ .ctx = e, .consume = Counter.consume });
    try std.testing.expectError(error.TooManyConsumers, d.add(.{ .ctx = &c, .consume = Counter.consume }));
}
