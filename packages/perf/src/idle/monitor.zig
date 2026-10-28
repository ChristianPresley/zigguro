//! `IdleMonitor` (E14.F05.S02.T01): wakeups per second and CPU percent
//! for the HUD and the idle scenario. It samples at 1 Hz on a worker,
//! only while an `Observation` is alive; with none, the worker sleeps on a
//! futex with no timeout. Its own wakes are noted at
//! `wake_count.monitor_site` and left out of the reported numbers.

const std = @import("std");
const zg_core = @import("zg_core");
const wake = @import("wake_count.zig");
const cpu_time = @import("cpu_time.zig");

const log = std.log.scoped(.zg_perf_idle);

pub const IdleMonitor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    group: std.Io.Group = .init,
    worker: enum { none, running, unavailable } = .none,
    start_mutex: std.Io.Mutex = .init,
    observers: std.atomic.Value(u32) = .init(0),
    gen: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    /// f32 bits of the latest rates; NaN bits before two samples.
    wakes_bits: std.atomic.Value(u32) = .init(@bitCast(std.math.nan(f32))),
    cpu_bits: std.atomic.Value(u32) = .init(@bitCast(std.math.nan(f32))),
    samples: std.atomic.Value(u64) = .init(0),

    pub const Options = struct {
        interval_ns: u64 = std.time.ns_per_s,
    };

    /// Keeps the monitor sampling until `release`.
    pub const Observation = struct {
        monitor: *IdleMonitor,

        pub fn release(o: Observation) void {
            _ = o.monitor.observers.fetchSub(1, .release);
            o.monitor.bump();
        }
    };

    /// Allocates the monitor; no task runs until `observe`.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, opts: Options) error{OutOfMemory}!*IdleMonitor {
        const m = try gpa.create(IdleMonitor);
        m.* = .{ .gpa = gpa, .io = io, .opts = opts };
        return m;
    }

    pub fn observe(m: *IdleMonitor) Observation {
        _ = m.observers.fetchAdd(1, .acquire);
        m.ensureWorker();
        m.bump();
        return .{ .monitor = m };
    }

    /// Wakes per second over the last interval (monitor excluded); null
    /// before two samples.
    pub fn wakeupsPerSecond(m: *const IdleMonitor) ?f32 {
        const v: f32 = @bitCast(m.wakes_bits.load(.acquire));
        return if (std.math.isNan(v)) null else v;
    }

    /// Process CPU time over the last interval, in percent of one core.
    pub fn cpuPercent(m: *const IdleMonitor) ?f32 {
        const v: f32 = @bitCast(m.cpu_bits.load(.acquire));
        return if (std.math.isNan(v)) null else v;
    }

    pub fn stop(m: *IdleMonitor) void {
        m.stopping.store(true, .release);
        m.bump();
        m.group.cancel(m.io);
        m.gpa.destroy(m);
    }

    fn bump(m: *IdleMonitor) void {
        _ = m.gen.fetchAdd(1, .release);
        m.io.futexWake(u32, &m.gen.raw, 1);
    }

    fn ensureWorker(m: *IdleMonitor) void {
        m.start_mutex.lockUncancelable(m.io);
        defer m.start_mutex.unlock(m.io);
        if (m.worker != .none) return;
        m.group.concurrent(m.io, loop, .{m}) catch {
            log.info("idle monitor disabled: no concurrency in this Io", .{});
            m.worker = .unavailable;
            return;
        };
        m.worker = .running;
    }

    const Point = struct { t_ns: u64, wakes: u64, cpu_ns: u64 };

    fn point(m: *IdleMonitor) Point {
        const cpu = cpu_time.processCpuTimes() catch cpu_time.CpuTimes{};
        return .{ .t_ns = zg_core.time.nowNs(m.io), .wakes = wake.totalWakes(), .cpu_ns = cpu.totalNs() };
    }

    fn loop(m: *IdleMonitor) std.Io.Cancelable!void {
        const io = m.io;
        wake.nameThread("idle monitor");
        var prev: ?Point = null;
        while (!m.stopping.load(.acquire)) {
            const g = m.gen.load(.acquire);
            if (m.observers.load(.acquire) == 0) {
                prev = null;
                try io.futexWait(u32, &m.gen.raw, g);
                wake.noteWake(wake.monitor_site, .signal);
                continue;
            }
            const p = m.point();
            if (prev) |q| {
                const dt: f32 = @floatFromInt(@max(1, p.t_ns - q.t_ns));
                const s = dt / std.time.ns_per_s;
                m.wakes_bits.store(@bitCast(@as(f32, @floatFromInt(p.wakes - q.wakes)) / s), .release);
                m.cpu_bits.store(@bitCast(100 * @as(f32, @floatFromInt(p.cpu_ns -| q.cpu_ns)) / dt), .release);
                zg_core.trace.counter("idle.wakeups_per_s_x100", @intFromFloat(100 * @as(f32, @bitCast(m.wakes_bits.load(.monotonic)))));
            }
            prev = p;
            _ = m.samples.fetchAdd(1, .release);
            const deadline: std.Io.Clock.Timestamp = .{ .raw = .fromNanoseconds(@intCast(p.t_ns + m.opts.interval_ns)), .clock = .awake };
            while (!m.stopping.load(.acquire) and m.observers.load(.acquire) > 0) {
                const g2 = m.gen.load(.acquire);
                if (zg_core.time.nowNs(io) >= p.t_ns + m.opts.interval_ns) break;
                try io.futexWaitTimeout(u32, &m.gen.raw, g2, .{ .deadline = deadline });
                wake.noteWake(wake.monitor_site, .timer);
            }
        }
    }
};

test "idle_monitor: excludes own wakes" {
    const m = try IdleMonitor.start(std.testing.allocator, std.testing.io, .{ .interval_ns = 20 * std.time.ns_per_ms });
    defer m.stop();
    const o = m.observe();
    if (m.worker != .running) {
        o.release();
        return error.SkipZigTest;
    }
    var waited: u32 = 0;
    while (m.samples.load(.acquire) < 4 and waited < 400) : (waited += 1) try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    o.release();
    try std.testing.expect(m.samples.load(.acquire) >= 4);
    // Nothing else in this test wakes on purpose; the monitor's own timer
    // wakes (50/s) are not counted. Other test threads may add a few.
    try std.testing.expect(m.wakeupsPerSecond().? < 50);
    try std.testing.expect(m.cpuPercent().? >= 0);
}

test "idle_monitor: attributes an injected timer" {
    const m = try IdleMonitor.start(std.testing.allocator, std.testing.io, .{ .interval_ns = 100 * std.time.ns_per_ms });
    defer m.stop();
    const o = m.observe();
    defer o.release();
    if (m.worker != .running) return error.SkipZigTest;
    // A 100 Hz timer that notes its wakes.
    const T = struct {
        fn run(stop: *std.atomic.Value(bool)) void {
            wake.nameThread("injected timer");
            while (!stop.load(.acquire)) {
                std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch return;
                wake.noteWake("test.injected_timer", .timer);
            }
        }
    };
    var stop_flag: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, T.run, .{&stop_flag});
    var waited: u32 = 0;
    while (m.samples.load(.acquire) < 4 and waited < 400) : (waited += 1) try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    stop_flag.store(true, .release);
    t.join();
    const rate = m.wakeupsPerSecond().?;
    try std.testing.expect(rate > 30);
    var snap: [64]wake.ThreadWakes = undefined;
    const n = @min(wake.wakeSnapshot(&snap), snap.len);
    const found = for (snap[0..n]) |s| {
        if (std.mem.eql(u8, s.name, "injected timer")) break std.mem.eql(u8, s.last_site, "test.injected_timer") and s.count > 5;
    } else false;
    try std.testing.expect(found);
}
