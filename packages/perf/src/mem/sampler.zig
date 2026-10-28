//! The memory sampler (E14.F04.S01.T02): process memory from the OS, the
//! tag counters and GPU memory, combined into a `Snapshot`.
//!
//! Zero idle wakeups: the worker task is created on the first `observe` or
//! `sampleNow`. While at least one `Observation` is alive (HUD visible,
//! trace session, scenario) it samples every `interval_ns`; with none it
//! sleeps on a futex with no timeout. `sampleNow` asks for one sample.
//! `latest` reads the newest snapshot under a seqlock from any thread.
//!
//! Each sample emits the trace counters `mem.private_bytes`,
//! `mem.rss_bytes`, `mem.gpu_device_local_bytes` and `mem.tag.<name>` for
//! tags with more than 1 MiB live.

const std = @import("std");
const wake_count = @import("../idle/wake_count.zig");
const zg_core = @import("zg_core");
const tags = @import("tags.zig");
const gpu = @import("gpu.zig");
const process = @import("process.zig");

const log = std.log.scoped(.zg_perf_mem);

/// Process, tag and GPU memory at one point in time.
pub const Snapshot = struct {
    /// Monotonic (awake) time of the sample; 0 before the first one.
    t_ns: u64 = 0,
    /// Samples taken so far, this one included.
    sample: u64 = 0,
    process: ?process.ProcessMem = null,
    gpu: ?gpu.GpuMem = null,
    tags: [tags.max_tags]tags.TagStats = @splat(.{}),

    /// Live bytes summed over the tags.
    pub fn taggedLive(s: *const Snapshot) i64 {
        var t: i64 = 0;
        for (s.tags[0..tags.tag_count]) |v| t += v.live;
        return t;
    }

    /// Private bytes not charged to any tag (`private - sum of tags`);
    /// null without process numbers.
    pub fn untracked(s: *const Snapshot) ?i64 {
        const p = s.process orelse return null;
        return @as(i64, @intCast(p.private_bytes)) - s.taggedLive();
    }
};

/// Takes a sample now on the calling thread (blocking: workers, reports
/// and benches only). `scratch` holds the /proc files.
pub fn takeSnapshot(io: std.Io, scratch: []u8) Snapshot {
    var s: Snapshot = .{ .t_ns = zg_core.time.nowNs(io) };
    s.process = process.readProcessMem(io, scratch) catch null;
    s.gpu = gpu.query();
    tags.allTagStats(&s.tags);
    return s;
}

/// Emits the trace counters for `s`.
pub fn emitCounters(s: *const Snapshot) void {
    if (s.process) |p| {
        zg_core.trace.counter("mem.private_bytes", @intCast(p.private_bytes));
        zg_core.trace.counter("mem.rss_bytes", @intCast(p.rss_bytes));
    }
    if (s.gpu) |g| zg_core.trace.counter("mem.gpu_device_local_bytes", @intCast(g.device_local_used));
    inline for (@typeInfo(tags.MemTag).@"enum".fields) |f| {
        const live = s.tags[f.value].live;
        if (live > 1 << 20) zg_core.trace.counter("mem.tag." ++ f.name, live);
    }
}

/// Called on the sampling thread after each sample (the pressure
/// monitor's ceiling check).
pub const OnSample = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, snap: *const Snapshot) void,
};

const snapshot_words = (@sizeOf(Snapshot) + 7) / 8;

/// Samples memory on a lazily created worker. Create with `start`, end
/// with `stop`.
pub const Sampler = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    group: std.Io.Group = .init,
    /// Guards the worker start.
    start_mutex: std.Io.Mutex = .init,
    worker: enum { none, running, unavailable } = .none,
    /// Guards `scratch` and the seqlock writer side.
    sample_mutex: std.Io.Mutex = .init,
    observers: std.atomic.Value(u32) = .init(0),
    /// One-shot requests from `sampleNow`.
    requests: std.atomic.Value(u32) = .init(0),
    /// Futex word: bumped on every observe, release, request and stop.
    gen: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    /// Samples the worker took (tests).
    iterations: std.atomic.Value(u64) = .init(0),
    /// Seqlock version: odd while a write is in progress.
    version: std.atomic.Value(u64) = .init(0),
    words: [snapshot_words]std.atomic.Value(u64) = @splat(.init(0)),
    samples: u64 = 0,
    /// Set before the first observation; called after each sample.
    on_sample: ?OnSample = null,
    scratch: [32 * 1024]u8 = undefined,

    /// Sampler options.
    pub const Options = struct {
        /// Sampling interval while observed.
        interval_ns: u64 = 500 * std.time.ns_per_ms,
        /// Emit trace counters for each sample.
        counters: bool = true,
    };

    /// Keeps the sampler sampling until `release`.
    pub const Observation = struct {
        sampler: *Sampler,

        pub fn release(o: Observation) void {
            const s = o.sampler;
            _ = s.observers.fetchSub(1, .release);
            s.bump();
        }
    };

    /// Allocates the sampler. No task runs until `observe` or `sampleNow`.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, opts: Options) error{OutOfMemory}!*Sampler {
        const s = try gpa.create(Sampler);
        s.* = .{ .gpa = gpa, .io = io, .opts = opts };
        s.words = @splat(.init(0));
        s.publish(&.{});
        return s;
    }

    /// Samples every `interval_ns` while the returned observation lives.
    pub fn observe(s: *Sampler) Observation {
        _ = s.observers.fetchAdd(1, .acquire);
        _ = s.ensureWorker();
        s.bump();
        return .{ .sampler = s };
    }

    /// Asks for one sample; read it with `latest`. Without concurrency in
    /// the `Io` the sample is taken on the calling thread.
    pub fn sampleNow(s: *Sampler) void {
        _ = s.requests.fetchAdd(1, .release);
        if (!s.ensureWorker()) {
            _ = s.requests.swap(0, .acquire);
            s.sampleSync();
            return;
        }
        s.bump();
    }

    /// Takes a sample on the calling thread and publishes it (blocking).
    pub fn sampleSync(s: *Sampler) void {
        s.sample_mutex.lockUncancelable(s.io);
        defer s.sample_mutex.unlock(s.io);
        var snap = takeSnapshot(s.io, &s.scratch);
        s.samples += 1;
        snap.sample = s.samples;
        s.publish(&snap);
        if (s.opts.counters) emitCounters(&snap);
        if (s.on_sample) |h| h.f(h.ctx, &snap);
    }

    /// The newest snapshot (all zero before the first sample).
    pub fn latest(s: *const Sampler) Snapshot {
        var raw: [snapshot_words]u64 = undefined;
        while (true) {
            const v1 = s.version.load(.acquire);
            if (v1 & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }
            for (&raw, &s.words) |*r, *w| r.* = w.load(.acquire);
            if (s.version.load(.acquire) == v1) break;
        }
        var out: Snapshot = undefined;
        @memcpy(std.mem.asBytes(&out), std.mem.sliceAsBytes(&raw)[0..@sizeOf(Snapshot)]);
        return out;
    }

    /// Stops the worker and frees the sampler.
    pub fn stop(s: *Sampler) void {
        s.stopping.store(true, .release);
        s.bump();
        s.group.cancel(s.io);
        s.gpa.destroy(s);
    }

    fn bump(s: *Sampler) void {
        _ = s.gen.fetchAdd(1, .release);
        s.io.futexWake(u32, &s.gen.raw, 1);
    }

    /// Starts the worker once; false when the `Io` has no concurrency.
    fn ensureWorker(s: *Sampler) bool {
        s.start_mutex.lockUncancelable(s.io);
        defer s.start_mutex.unlock(s.io);
        switch (s.worker) {
            .running => return true,
            .unavailable => return false,
            .none => {},
        }
        s.group.concurrent(s.io, loop, .{s}) catch {
            log.info("memory sampler worker disabled: no concurrency in this Io", .{});
            s.worker = .unavailable;
            return false;
        };
        s.worker = .running;
        return true;
    }

    fn publish(s: *Sampler, snap: *const Snapshot) void {
        var raw: [snapshot_words]u64 = @splat(0);
        @memcpy(std.mem.sliceAsBytes(&raw)[0..@sizeOf(Snapshot)], std.mem.asBytes(snap));
        _ = s.version.fetchAdd(1, .acq_rel);
        for (raw, &s.words) |r, *w| w.store(r, .release);
        _ = s.version.fetchAdd(1, .release);
    }

    fn loop(s: *Sampler) std.Io.Cancelable!void {
        const io = s.io;
        while (!s.stopping.load(.acquire)) {
            const g = s.gen.load(.acquire);
            const observed = s.observers.load(.acquire) > 0;
            const requested = s.requests.swap(0, .acquire) > 0;
            if (!observed and !requested) {
                try io.futexWait(u32, &s.gen.raw, g);
                wake_count.noteWake("perf.mem_sampler", .signal);
                continue;
            }
            s.sampleSync();
            _ = s.iterations.fetchAdd(1, .monotonic);
            if (!observed) continue;
            const deadline: std.Io.Clock.Timestamp = .{ .raw = .fromNanoseconds(@intCast(zg_core.time.nowNs(io) + s.opts.interval_ns)), .clock = .awake };
            // Observers coming and going bump `gen`; keep the interval.
            while (!s.stopping.load(.acquire) and s.requests.load(.acquire) == 0 and s.observers.load(.acquire) > 0) {
                const g2 = s.gen.load(.acquire);
                if (zg_core.time.nowNs(io) >= deadline.raw.nanoseconds) break;
                try io.futexWaitTimeout(u32, &s.gen.raw, g2, .{ .deadline = deadline });
                wake_count.noteWake("perf.mem_sampler", .timer);
            }
        }
    }
};

test "sampler: no worker without observation" {
    const s = try Sampler.start(std.testing.allocator, std.testing.io, .{ .counters = false });
    defer s.stop();
    try std.testing.expect(s.worker == .none);
    try std.testing.expectEqual(@as(u64, 0), s.iterations.load(.monotonic));
    const snap = s.latest();
    try std.testing.expectEqual(@as(u64, 0), snap.sample);
    try std.testing.expect(snap.process == null);
}

test "sampler: observation samples, release stops" {
    const s = try Sampler.start(std.testing.allocator, std.testing.io, .{ .interval_ns = 5 * std.time.ns_per_ms, .counters = false });
    defer s.stop();
    const o = s.observe();
    if (s.worker != .running) {
        o.release();
        return error.SkipZigTest;
    }
    var waited: u32 = 0;
    while (s.iterations.load(.monotonic) < 3 and waited < 400) : (waited += 1) {
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    o.release();
    try std.testing.expect(s.iterations.load(.monotonic) >= 3);
    try std.testing.expect(s.latest().sample >= 3);
    // Settled: no more samples without an observation.
    try std.testing.io.sleep(.fromMilliseconds(20), .awake);
    const settled = s.iterations.load(.monotonic);
    try std.testing.io.sleep(.fromMilliseconds(30), .awake);
    try std.testing.expectEqual(settled, s.iterations.load(.monotonic));
}

test "sampler: sampleNow takes one sample" {
    const s = try Sampler.start(std.testing.allocator, std.testing.io, .{ .counters = false });
    defer s.stop();
    s.sampleNow();
    var waited: u32 = 0;
    while (s.latest().sample == 0 and waited < 400) : (waited += 1) {
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    const snap = s.latest();
    try std.testing.expectEqual(@as(u64, 1), snap.sample);
    if (@import("builtin").os.tag == .linux) try std.testing.expect(snap.process.?.rss_bytes > 0);
}

test "sampler: seqlock consistent under concurrent writes" {
    const s = try Sampler.start(std.testing.allocator, std.testing.io, .{ .counters = false });
    defer s.stop();
    const n = if (@import("builtin").mode == .Debug) 20_000 else 200_000;
    const Writer = struct {
        fn run(sp: *Sampler) void {
            var snap: Snapshot = .{};
            for (1..n + 1) |i| {
                // Every field carries `i`; a torn read mixes values.
                snap.t_ns = i;
                snap.sample = i;
                snap.process = .{ .private_bytes = i, .rss_bytes = i, .peak_rss_bytes = i };
                for (&snap.tags) |*t| t.* = .{ .live = @intCast(i), .peak = i, .allocs = i, .frees = i };
                sp.publish(&snap);
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Writer.run, .{s});
    var reads: u64 = 0;
    while (true) : (reads += 1) {
        const snap = s.latest();
        const i = snap.sample;
        try std.testing.expectEqual(i, snap.t_ns);
        if (snap.process) |p| try std.testing.expectEqual(i, p.rss_bytes);
        for (snap.tags) |tg| try std.testing.expectEqual(i, tg.allocs);
        if (i == n) break;
    }
    t.join();
    try std.testing.expect(reads > 0);
}
