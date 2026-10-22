//! The request scheduler every feature service uses to issue requests tied
//! to a document version: per-(document, feature) debouncing,
//! cancel-on-supersede (`$/cancelRequest` through `Client.cancel`), one
//! `ContentModified` retry, and interactive-before-background priority.
//!
//! Each key has at most one pending timer and one request in flight.
//! `schedule` resets the timer and cancels the request in flight. When the
//! timer fires, `RunFn` runs on the wheel worker (never the UI thread) with
//! the document version at fire time and a `CancelToken`; the service binds
//! the token to its request and calls `done` when the result arrived.
//!
//! Timers live on one hashed wheel (5 ms resolution, 512 slots) driven by
//! `poll`: `start` runs it on a worker, tests call it directly with a
//! `ManualClock`.
//!
//! Interactive features (completion, hover, signature help, navigation)
//! fire as soon as they are due. A background key that comes due while an
//! interactive request is in flight waits for it, at most 500 ms
//! (many servers are single-threaded). Background keys are "auto": a
//! document change re-runs them for the new version.
//!
//! `schedule` for a known key and `onDocChanged` never allocate (a key's
//! entry is allocated on first use and reused afterwards).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const Client = @import("../client/Client.zig");
const Feature = @import("../client/caps.zig").Feature;
const wheel_mod = @import("timer_wheel.zig");

/// Identifies an open document (E05 assigns them).
pub const DocId = u64;

pub const SchedKey = struct { doc: DocId, feature: Feature, slot: u16 = 0 };

/// A monotonic nanosecond clock; injectable for tests.
pub const Clock = struct {
    ctx: ?*anyopaque,
    nowNs: *const fn (ctx: ?*anyopaque) u64,

    pub fn real(io: *const Io) Clock {
        return .{ .ctx = @constCast(io), .nowNs = struct {
            fn f(ctx: ?*anyopaque) u64 {
                const p: *const Io = @ptrCast(@alignCast(ctx.?));
                return zg_core.time.nowNs(p.*);
            }
        }.f };
    }
};

/// A clock that only moves when told to.
pub const ManualClock = struct {
    ns: std.atomic.Value(u64) = .init(1_000_000_000),

    pub fn clock(m: *ManualClock) Clock {
        return .{ .ctx = m, .nowNs = struct {
            fn f(ctx: ?*anyopaque) u64 {
                const p: *ManualClock = @ptrCast(@alignCast(ctx.?));
                return p.ns.load(.acquire);
            }
        }.f };
    }

    pub fn advance(m: *ManualClock, d: Io.Duration) void {
        _ = m.ns.fetchAdd(@intCast(d.nanoseconds), .acq_rel);
    }
};

/// Cancellation of one run of a key. Canceled when the key is
/// rescheduled, its document changes or is canceled, or the scheduler
/// stops.
pub const CancelToken = struct {
    entry: *Entry,
    gen: u32,

    pub fn isCanceled(t: CancelToken) bool {
        return t.entry.gen.load(.acquire) != t.gen;
    }

    /// Ties the run to request `h`: canceling it then calls `c.cancel(h)`
    /// (which sends `$/cancelRequest`). Cancels at once if already
    /// canceled.
    pub fn bind(t: CancelToken, c: *Client, h: Client.ReqHandle) void {
        const s = t.entry.sched;
        s.mutex.lockUncancelable(s.io);
        const live = !t.isCanceled();
        if (live) t.entry.bound = .{ .client = c, .handle = h };
        s.mutex.unlock(s.io);
        if (!live) c.cancel(h);
    }

    /// The run finished (its result arrived or it gave up).
    pub fn done(t: CancelToken) void {
        const s = t.entry.sched;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (t.isCanceled() or !t.entry.inflight) return;
        _ = s.endFlight(t.entry);
    }
};

pub const RunFn = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, version: u64, token: CancelToken) void,
};

const Entry = struct {
    sched: *RequestScheduler,
    key: SchedKey,
    node: wheel_mod.Node = .{},
    gen: std.atomic.Value(u32) = .init(0),
    run: ?RunFn = null,
    debounce_ns: u64 = 0,
    /// When it first came due (for the starvation cap).
    due_since_ns: ?u64 = null,
    inflight: bool = false,
    bound: ?struct { client: *Client, handle: Client.ReqHandle } = null,
    /// A ContentModified retry waits for the next document change.
    retry_pending: bool = false,
    retried: bool = false,
};

const max_keys_per_doc = 32;

const Doc = struct {
    version: u64 = 0,
    keys: [max_keys_per_doc]*Entry = undefined,
    len: u8 = 0,
};

/// Debounce defaults (E15 `lsp.debounce.<feature>` overrides them).
pub fn defaultDebounce(f: Feature) Io.Duration {
    const ms: i64 = switch (f) {
        .document_highlight => 50,
        .inlay_hint => 100,
        .semantic_tokens_full, .semantic_tokens_delta, .semantic_tokens_range => 150,
        .diagnostic_pull => 200,
        .code_lens => 250,
        .folding_range, .document_symbol => 300,
        else => 0,
    };
    return .fromMilliseconds(ms);
}

/// Features the user is waiting on: they never wait for others.
pub fn isInteractive(f: Feature) bool {
    return switch (f) {
        .completion, .completion_resolve, .hover, .signature_help, .definition, .declaration, .type_definition, .implementation, .references, .prepare_rename, .rename => true,
        else => false,
    };
}

/// Features whose results are retried once on ContentModified.
pub fn retriesOnContentModified(f: Feature) bool {
    return switch (f) {
        .semantic_tokens_full, .semantic_tokens_delta, .semantic_tokens_range, .inlay_hint, .code_lens, .folding_range, .document_symbol, .document_highlight, .diagnostic_pull, .document_link, .inline_value => true,
        else => false,
    };
}

pub const resolution_ns: u64 = 5 * std.time.ns_per_ms;
pub const starvation_cap_ns: u64 = 500 * std.time.ns_per_ms;

pub const RequestScheduler = struct {
    gpa: Allocator,
    io: Io,
    clock: Clock,
    mutex: Io.Mutex = .init,
    wheel: wheel_mod.TimerWheel,
    entries: std.AutoHashMapUnmanaged(SchedKey, *Entry) = .empty,
    docs: std.AutoHashMapUnmanaged(DocId, Doc) = .empty,
    free_list: std.ArrayList(*Entry) = .empty,
    /// Interactive runs in flight.
    interactive: u32 = 0,
    overrides: std.EnumArray(Feature, ?Io.Duration) = .initFill(null),
    loop: ?zg_core.runtime.Subsystem = null,
    wake: Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn init(rt: *zg_core.Runtime, clock: Clock) RequestScheduler {
        return .{
            .gpa = rt.gpa,
            .io = rt.io,
            .clock = clock,
            .wheel = .init(resolution_ns, clock.nowNs(clock.ctx)),
        };
    }

    pub fn deinit(s: *RequestScheduler) void {
        s.stop();
        var it = s.entries.valueIterator();
        while (it.next()) |e| s.gpa.destroy(e.*);
        for (s.free_list.items) |e| s.gpa.destroy(e);
        s.entries.deinit(s.gpa);
        s.docs.deinit(s.gpa);
        s.free_list.deinit(s.gpa);
        s.* = undefined;
    }

    /// Runs the wheel on a worker until `stop`.
    pub fn start(s: *RequestScheduler) !void {
        s.loop = .init(s.io);
        try s.loop.?.spawnLoop(wheelLoop, .{s});
    }

    pub fn stop(s: *RequestScheduler) void {
        if (s.loop) |*l| {
            s.stopping.store(true, .release);
            s.wake.set(s.io);
            l.shutdown();
            s.loop = null;
        }
    }

    fn wheelLoop(s: *RequestScheduler) Io.Cancelable!void {
        while (!s.stopping.load(.acquire)) {
            s.poll();
            s.wake.waitTimeout(s.io, .{ .duration = .{ .raw = .fromNanoseconds(resolution_ns), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
            s.wake.reset();
        }
    }

    pub fn setDebounce(s: *RequestScheduler, f: Feature, d: ?Io.Duration) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.overrides.set(f, d);
    }

    pub fn debounceFor(s: *RequestScheduler, f: Feature) Io.Duration {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.overrides.get(f) orelse defaultDebounce(f);
    }

    /// (Re)arms `key` to run `run` after `debounce`, canceling its pending
    /// run and its request in flight. UI-thread safe.
    pub fn schedule(s: *RequestScheduler, key: SchedKey, debounce: Io.Duration, run: RunFn) !void {
        var victim: ?Victim = null;
        defer if (victim) |v| v.cancel();
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const e = try s.entry(key);
        victim = s.cancelEntry(e);
        e.run = run;
        e.retried = false;
        e.retry_pending = false;
        e.debounce_ns = @intCast(@max(0, debounce.nanoseconds));
        s.arm(e, e.debounce_ns);
    }

    /// The document changed (every keystroke, UI thread): its requests in
    /// flight are canceled, and auto keys and pending ContentModified
    /// retries run again for `new_version`. O(keys of the document).
    pub fn onDocChanged(s: *RequestScheduler, doc: DocId, new_version: u64) void {
        var victims: [max_keys_per_doc]?Victim = @splat(null);
        defer for (victims) |v| if (v) |x| x.cancel();
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const d = s.docs.getPtr(doc) orelse return;
        d.version = new_version;
        for (d.keys[0..d.len], 0..) |e, i| {
            const auto = !isInteractive(e.key.feature) and e.run != null;
            const retry = e.retry_pending;
            if (!auto and !retry and !e.inflight and !e.node.armed) continue;
            victims[i] = s.cancelEntry(e);
            if (retry) {
                e.retry_pending = false;
                e.retried = true;
            }
            if (auto or retry) s.arm(e, e.debounce_ns);
        }
    }

    /// A request for `key` failed with ContentModified: retry it once,
    /// after the next document change, for the features that allow it.
    /// Returns whether a retry is pending.
    pub fn onContentModified(s: *RequestScheduler, key: SchedKey) bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const e = s.entries.get(key) orelse return false;
        if (!retriesOnContentModified(key.feature) or e.retried or e.run == null) return false;
        if (e.inflight) _ = s.endFlight(e);
        e.retry_pending = true;
        return true;
    }

    /// Cancels everything for `doc` (it closed) and forgets its keys.
    pub fn cancelDoc(s: *RequestScheduler, doc: DocId) void {
        var victims: [max_keys_per_doc]?Victim = @splat(null);
        defer for (victims) |v| if (v) |x| x.cancel();
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const kv = s.docs.fetchRemove(doc) orelse return;
        for (kv.value.keys[0..kv.value.len], 0..) |e, i| {
            victims[i] = s.cancelEntry(e);
            _ = s.entries.remove(e.key);
            e.run = null;
            // Reused later: tokens of this entry stay canceled (gen moved).
            s.free_list.append(s.gpa, e) catch s.gpa.destroy(e);
        }
    }

    /// The version `onDocChanged` last reported for `doc` (0 if none).
    pub fn version(s: *RequestScheduler, doc: DocId) u64 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return if (s.docs.get(doc)) |d| d.version else 0;
    }

    /// Fires every due key. The wheel worker calls it every 5 ms.
    pub fn poll(s: *RequestScheduler) void {
        var due: std.ArrayList(Fire) = .empty;
        defer due.deinit(s.gpa);
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            const now = s.clock.nowNs(s.clock.ctx);
            var c: Collect = .{ .s = s, .now = now, .out = &due };
            s.wheel.advance(now, &c, Collect.fire);
        }
        for (due.items) |f| f.run.func(f.run.ctx, f.version, f.token);
    }

    const Fire = struct { run: RunFn, version: u64, token: CancelToken };

    const Collect = struct {
        s: *RequestScheduler,
        now: u64,
        out: *std.ArrayList(Fire),

        fn fire(c: *Collect, n: *wheel_mod.Node) void {
            const s = c.s;
            const e: *Entry = @fieldParentPtr("node", n);
            const run = e.run orelse return;
            const interactive = isInteractive(e.key.feature);
            if (!interactive and s.interactive > 0) {
                const since = e.due_since_ns orelse c.now;
                e.due_since_ns = since;
                if (c.now - since < starvation_cap_ns) {
                    s.wheel.insert(&e.node, c.now + resolution_ns);
                    return;
                }
            }
            e.due_since_ns = null;
            c.out.append(s.gpa, .{
                .run = run,
                .version = if (s.docs.get(e.key.doc)) |d| d.version else 0,
                .token = .{ .entry = e, .gen = e.gen.load(.acquire) },
            }) catch return;
            e.inflight = true;
            if (interactive) s.interactive += 1;
        }
    };

    // ------------------------------------------------------------ internals

    /// A request to cancel once the lock is released.
    const Victim = struct {
        client: *Client,
        handle: Client.ReqHandle,

        fn cancel(v: Victim) void {
            v.client.cancel(v.handle);
        }
    };

    fn entry(s: *RequestScheduler, key: SchedKey) !*Entry {
        if (s.entries.get(key)) |e| return e;
        const gop = try s.docs.getOrPut(s.gpa, key.doc);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const d = gop.value_ptr;
        if (d.len == max_keys_per_doc) return error.TooManyKeys;
        try s.entries.ensureUnusedCapacity(s.gpa, 1);
        const reused = s.free_list.pop();
        const e = reused orelse try s.gpa.create(Entry);
        // A reused entry keeps counting, so its old tokens stay canceled.
        const gen = if (reused != null) e.gen.load(.acquire) else 0;
        e.* = .{ .sched = s, .key = key };
        e.gen.store(gen, .release);
        s.entries.putAssumeCapacity(key, e);
        d.keys[d.len] = e;
        d.len += 1;
        return e;
    }

    fn arm(s: *RequestScheduler, e: *Entry, delay_ns: u64) void {
        s.wheel.insert(&e.node, s.clock.nowNs(s.clock.ctx) + delay_ns);
        if (delay_ns == 0 and s.loop != null) s.wake.set(s.io);
    }

    /// Disarms `e` and cancels its run in flight; returns the request to
    /// cancel after unlocking.
    fn cancelEntry(s: *RequestScheduler, e: *Entry) ?Victim {
        s.wheel.remove(&e.node);
        e.due_since_ns = null;
        _ = e.gen.fetchAdd(1, .acq_rel);
        if (!e.inflight) return null;
        return s.endFlight(e);
    }

    fn endFlight(s: *RequestScheduler, e: *Entry) ?Victim {
        e.inflight = false;
        if (isInteractive(e.key.feature)) s.interactive -|= 1;
        const b = e.bound orelse return null;
        e.bound = null;
        return .{ .client = b.client, .handle = b.handle };
    }
};
