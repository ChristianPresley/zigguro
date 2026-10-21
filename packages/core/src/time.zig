//! Monotonic time helpers on `std.Io.Clock` (0.16 replaced `std.time.Timer`
//! and `Instant` with `Io.Timestamp`/`Io.Clock`), plus a raw cycle counter for
//! trace zones.

const std = @import("std");
const builtin = @import("builtin");

/// Nanoseconds on the monotonic `.awake` clock. Never blocks.
pub fn nowNs(io: std.Io) u64 {
    const t = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(0, t.nanoseconds));
}

/// Measures elapsed monotonic time.
pub const Stopwatch = struct {
    started: std.Io.Timestamp,

    /// Starts a stopwatch now.
    pub fn start(io: std.Io) Stopwatch {
        return .{ .started = std.Io.Timestamp.now(io, .awake) };
    }

    /// Nanoseconds since start (or the previous lap), then restarts.
    pub fn lapNs(s: *Stopwatch, io: std.Io) u64 {
        const now = std.Io.Timestamp.now(io, .awake);
        const d = s.started.durationTo(now).nanoseconds;
        s.started = now;
        return @intCast(@max(0, d));
    }

    /// Nanoseconds since start without restarting.
    pub fn readNs(s: *const Stopwatch, io: std.Io) u64 {
        const d = s.started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        return @intCast(@max(0, d));
    }
};

/// True when `fastTicks` reads a hardware counter (x86_64 TSC or the
/// aarch64 virtual counter) rather than falling back to `nowNs`.
pub const has_fast_ticks = switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => true,
    else => false,
};

var fallback_io: ?std.Io = null;

/// Sets the `Io` used by `fastTicks` on targets without a cycle counter.
pub fn setFallbackIo(io: std.Io) void {
    fallback_io = io;
}

/// A raw, monotonically increasing tick count: `rdtsc` on x86_64,
/// `cntvct_el0` on aarch64, otherwise `nowNs` via `setFallbackIo` (0 if unset).
/// Convert with a `TickCalibration`.
pub inline fn fastTicks() u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            asm volatile ("rdtsc"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
            );
            return (@as(u64, hi) << 32) | lo;
        },
        .aarch64 => return asm volatile ("mrs %[r], cntvct_el0"
            : [r] "=r" (-> u64),
        ),
        else => return if (fallback_io) |io| nowNs(io) else 0,
    }
}

/// Maps ticks to nanoseconds using two (ticks, ns) anchor points.
pub const TickCalibration = struct {
    ticks0: u64,
    ns0: u64,
    ns_per_tick: f64 = 1.0,

    /// Records the first anchor.
    pub fn begin(io: std.Io) TickCalibration {
        return .{ .ticks0 = fastTicks(), .ns0 = nowNs(io) };
    }

    /// Records a second anchor and computes the rate; call after a few ms.
    pub fn finish(c: *TickCalibration, io: std.Io) void {
        const t1 = fastTicks();
        const n1 = nowNs(io);
        if (!has_fast_ticks or t1 <= c.ticks0) {
            c.ns_per_tick = 1.0;
            return;
        }
        c.ns_per_tick = @as(f64, @floatFromInt(n1 -| c.ns0)) / @as(f64, @floatFromInt(t1 - c.ticks0));
    }

    /// Converts an absolute tick value to `.awake` nanoseconds.
    pub fn toNs(c: TickCalibration, ticks: u64) u64 {
        if (ticks >= c.ticks0) return c.ns0 + c.durationNs(ticks - c.ticks0);
        return c.ns0 -| c.durationNs(c.ticks0 - ticks);
    }

    /// Converts a tick delta to nanoseconds.
    pub fn durationNs(c: TickCalibration, ticks: u64) u64 {
        return @intFromFloat(@as(f64, @floatFromInt(ticks)) * c.ns_per_tick);
    }
};

test "time: Stopwatch monotonic" {
    const io = std.testing.io;
    var sw = Stopwatch.start(io);
    var prev = nowNs(io);
    for (0..1000) |_| {
        const n = nowNs(io);
        try std.testing.expect(n >= prev);
        prev = n;
    }
    try std.testing.expect(sw.readNs(io) <= sw.lapNs(io) + 1_000_000_000);
}

test "time: tick calibration is monotonic and positive" {
    const io = std.testing.io;
    setFallbackIo(io);
    var cal = TickCalibration.begin(io);
    try io.sleep(.fromMilliseconds(2), .awake);
    cal.finish(io);
    try std.testing.expect(cal.ns_per_tick > 0);
    const a = fastTicks();
    const b = fastTicks();
    try std.testing.expect(b >= a);
    try std.testing.expect(cal.toNs(b) >= cal.toNs(a));
}
