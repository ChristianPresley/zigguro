//! Memory pressure (E14.F04.S02.T01): caches register `Reclaimer`s, and
//! the `PressureMonitor` asks them to shrink when a tag passes its ceiling
//! or the OS reports pressure (Linux PSI, Windows memory resource
//! notifications; see pressure_linux.zig and pressure_windows.zig).
//!
//! Zero idle wakeups: the reclaim worker sleeps on a futex and the OS
//! source blocks in poll / WaitForMultipleObjects with no timeout. Only
//! Windows' critical state wakes every 5 s, and only while memory is low.
//!
//! E14 owns the mechanism, not the caches: docs/perf/memory.md lists what
//! each epic is expected to register.

const std = @import("std");
const wake_count = @import("../idle/wake_count.zig");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const tags = @import("tags.zig");
const sampler = @import("sampler.zig");
const budget = @import("../budget.zig");
const pressure_linux = @import("pressure_linux.zig");
const pressure_windows = @import("pressure_windows.zig");

const MemTag = tags.MemTag;
const log = std.log.scoped(.zg_perf_mem);

/// How hard to reclaim.
pub const Pressure = enum(u8) {
    none,
    /// A ceiling breach or PSI `some`: trim what is cheap to rebuild.
    moderate,
    /// PSI `full` or Windows low memory: free as much as is sensible.
    critical,
};

/// A cache that can give memory back. `reclaim` frees up to
/// `target_bytes` and returns what it freed; it runs on the reclaim
/// worker, must return within 5 ms, and should work in slices of 2 ms or
/// less (data owned by the UI thread: post the work there in slices).
pub const Reclaimer = struct {
    ctx: *anyopaque,
    tag: MemTag,
    name: []const u8,
    reclaim: *const fn (ctx: *anyopaque, level: Pressure, target_bytes: u64) u64,
    reclaimable: *const fn (ctx: *anyopaque) u64,
};

/// A registration; `none` when the registry was full.
pub const ReclaimerId = enum(u32) { none = 0, _ };

/// Room for registered reclaimers.
pub const max_reclaimers = 64;

const Slot = struct { used: bool = false, r: Reclaimer = undefined };
var slots: [max_reclaimers]Slot = @splat(.{});
/// Held while (un)registering and for the whole of a reclaim run, so a
/// reclaimer is never called after `unregisterReclaimer` returns.
var registry_mutex: std.atomic.Mutex = .unlocked;

fn lockRegistry() void {
    while (!registry_mutex.tryLock()) std.Thread.yield() catch {};
}

/// Registers `r`; `none` (and a warning) when all slots are taken.
pub fn registerReclaimer(r: Reclaimer) ReclaimerId {
    lockRegistry();
    defer registry_mutex.unlock();
    for (&slots, 0..) |*s, i| if (!s.used) {
        s.* = .{ .used = true, .r = r };
        return @enumFromInt(i + 1);
    };
    log.warn("reclaimer registry full; {s} not registered", .{r.name});
    return .none;
}

/// Removes a registration; waits for a running reclaim to finish.
pub fn unregisterReclaimer(id: ReclaimerId) void {
    if (id == .none) return;
    lockRegistry();
    defer registry_mutex.unlock();
    slots[@intFromEnum(id) - 1].used = false;
}

/// What one reclaim run did.
pub const ReclaimResult = struct {
    target: u64 = 0,
    freed: u64 = 0,
    reclaimable: u64 = 0,
    calls: u32 = 0,
    /// The longest single `reclaim` call.
    max_call_ns: u64 = 0,
};

/// Asks reclaimers (all, or `only` that tag's) to free memory, largest
/// `reclaimable()` first, until `target` bytes are freed. A null target
/// means 50 % of the total reclaimable. Blocking: the reclaim worker and
/// tests only.
pub fn runReclaim(io: std.Io, level: Pressure, only: ?MemTag, target: ?u64) ReclaimResult {
    const zone = zg_core.trace.zone(@src(), "mem.reclaim");
    defer zone.end();
    lockRegistry();
    defer registry_mutex.unlock();
    var order: [max_reclaimers]struct { r: *const Reclaimer, avail: u64 } = undefined;
    var n: usize = 0;
    var res: ReclaimResult = .{};
    for (&slots) |*s| {
        if (!s.used) continue;
        if (only) |t| if (s.r.tag != t) continue;
        const avail = s.r.reclaimable(s.r.ctx);
        res.reclaimable += avail;
        order[n] = .{ .r = &s.r, .avail = avail };
        n += 1;
    }
    std.mem.sort(@TypeOf(order[0]), order[0..n], {}, struct {
        fn gt(_: void, a: @TypeOf(order[0]), b: @TypeOf(order[0])) bool {
            return a.avail > b.avail;
        }
    }.gt);
    res.target = target orelse res.reclaimable / 2;
    for (order[0..n]) |o| {
        if (res.freed >= res.target) break;
        if (o.avail == 0) continue;
        const t0 = zg_core.time.nowNs(io);
        const freed = o.r.reclaim(o.r.ctx, level, @min(o.avail, res.target - res.freed));
        const dt = zg_core.time.nowNs(io) -| t0;
        res.calls += 1;
        res.freed += freed;
        res.max_call_ns = @max(res.max_call_ns, dt);
        if (dt > 5 * std.time.ns_per_ms) log.warn("reclaimer {s} took {d} ms (limit 5)", .{ o.r.name, dt / std.time.ns_per_ms });
    }
    zg_core.trace.counter("mem.reclaim_bytes", @intCast(res.freed));
    return res;
}

var ceilings: [tags.max_tags]std.atomic.Value(u64) = @splat(.init(0));

/// Sets `tag`'s ceiling in bytes (0: none).
pub fn setCeiling(tag: MemTag, bytes: u64) void {
    ceilings[@intFromEnum(tag)].store(bytes, .monotonic);
}

/// `tag`'s ceiling in bytes, 0 when it has none.
pub fn ceiling(tag: MemTag) u64 {
    return ceilings[@intFromEnum(tag)].load(.monotonic);
}

/// Sets ceilings from the `mem.tag.<name>` byte budgets in budgets.zon.
pub fn loadBudgetCeilings() void {
    inline for (@typeInfo(MemTag).@"enum".fields) |f| {
        if (budget.byId("mem.tag." ++ f.name)) |b| {
            if (b.metric == .bytes) setCeiling(@enumFromInt(f.value), @intFromFloat(b.limit));
        }
    }
}

/// Ceiling breaches in `snap` not reported in the last `debounce_ns`:
/// a bit per tag. Updates `last_ns`.
pub fn ceilingBreaches(snap: *const sampler.Snapshot, last_ns: *[tags.max_tags]u64, now_ns: u64, debounce_ns: u64) u32 {
    var mask: u32 = 0;
    for (0..tags.tag_count) |i| {
        const c = ceilings[i].load(.monotonic);
        if (c == 0 or snap.tags[i].live <= @as(i64, @intCast(c))) continue;
        if (last_ns[i] != 0 and now_ns -| last_ns[i] < debounce_ns) continue;
        last_ns[i] = now_ns;
        mask |= @as(u32, 1) << @intCast(i);
    }
    return mask;
}

/// Watches ceilings and OS pressure and runs reclaims on its worker.
pub const PressureMonitor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    group: std.Io.Group = .init,
    /// The last level reported and when (`.awake` ns).
    level: std.atomic.Value(Pressure) = .init(.none),
    level_ns: std.atomic.Value(u64) = .init(0),
    /// Requests for the worker: a level and a tag mask.
    pending_level: std.atomic.Value(u8) = .init(0),
    pending_tags: std.atomic.Value(u32) = .init(0),
    gen: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    /// Reclaim runs and the last result (tests, the command).
    runs: std.atomic.Value(u32) = .init(0),
    last: ReclaimResult = .{},
    ceiling_last_ns: [tags.max_tags]u64 = @splat(0),
    os: OsSource = .none,

    const OsSource = union(enum) {
        none,
        linux: *pressure_linux.Psi,
        windows: *pressure_windows.Notifications,
    };

    pub const Options = struct {
        /// Watch the OS source (PSI or Windows notifications).
        os_source: bool = true,
        /// At most one ceiling reclaim per tag per this.
        ceiling_debounce_ns: u64 = 5 * std.time.ns_per_s,
        /// `current()` falls back to `none` this long after the last
        /// report without a newer one (PSI has no "pressure ended" event).
        level_hold_ns: u64 = 10 * std.time.ns_per_s,
    };

    /// Starts the reclaim worker and the OS source. Null without
    /// concurrency in the `Io`.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, opts: Options) error{OutOfMemory}!?*PressureMonitor {
        const m = try gpa.create(PressureMonitor);
        m.* = .{ .gpa = gpa, .io = io, .opts = opts };
        m.group.concurrent(io, worker, .{m}) catch {
            log.info("pressure monitor disabled: no concurrency in this Io", .{});
            gpa.destroy(m);
            return null;
        };
        if (opts.os_source) m.startOs();
        return m;
    }

    fn startOs(m: *PressureMonitor) void {
        const sink: OsSink = .{ .ctx = m, .report = osReport };
        switch (builtin.os.tag) {
            .linux => if (pressure_linux.Psi.open(m.gpa, sink) catch null) |p| {
                m.group.concurrent(m.io, pressure_linux.Psi.run, .{p}) catch {
                    p.close();
                    return;
                };
                m.os = .{ .linux = p };
            },
            .windows => if (pressure_windows.Notifications.open(m.gpa, sink) catch null) |n| {
                m.group.concurrent(m.io, pressure_windows.Notifications.run, .{n}) catch {
                    n.close();
                    return;
                };
                m.os = .{ .windows = n };
            },
            else => {},
        }
    }

    fn osReport(ctx: *anyopaque, level: Pressure) void {
        const m: *PressureMonitor = @ptrCast(@alignCast(ctx));
        m.report(level);
    }

    /// A pressure level reported by an OS source or `simulate`.
    pub fn report(m: *PressureMonitor, level: Pressure) void {
        m.level.store(level, .release);
        m.level_ns.store(zg_core.time.nowNs(m.io), .release);
        if (level == .none) return;
        _ = m.pending_level.fetchMax(@intFromEnum(level), .acq_rel);
        m.bump();
    }

    /// Acts as if the OS reported `level` (tests and the command
    /// `perf.memory.simulatePressure`).
    pub fn simulate(m: *PressureMonitor, level: Pressure) void {
        m.report(level);
    }

    /// The current pressure level.
    pub fn current(m: *const PressureMonitor) Pressure {
        const l = m.level.load(.acquire);
        if (l == .none) return .none;
        if (zg_core.time.nowNs(m.io) -| m.level_ns.load(.acquire) > m.opts.level_hold_ns) return .none;
        return l;
    }

    /// Checks `snap` against the ceilings and schedules a moderate reclaim
    /// for each breached tag (debounced). Install with `samplerHook`.
    pub fn checkCeilings(m: *PressureMonitor, snap: *const sampler.Snapshot) void {
        const mask = ceilingBreaches(snap, &m.ceiling_last_ns, zg_core.time.nowNs(m.io), m.opts.ceiling_debounce_ns);
        if (mask == 0) return;
        _ = m.pending_tags.fetchOr(mask, .acq_rel);
        m.bump();
    }

    /// A `Sampler.on_sample` hook that calls `checkCeilings`.
    pub fn samplerHook(m: *PressureMonitor) sampler.OnSample {
        return .{ .ctx = m, .f = struct {
            fn f(ctx: *anyopaque, snap: *const sampler.Snapshot) void {
                const pm: *PressureMonitor = @ptrCast(@alignCast(ctx));
                pm.checkCeilings(snap);
            }
        }.f };
    }

    /// Stops the OS source and the worker, and frees the monitor.
    pub fn stop(m: *PressureMonitor) void {
        m.stopping.store(true, .release);
        switch (m.os) {
            .none => {},
            .linux => |p| if (builtin.os.tag == .linux) p.requestStop(),
            .windows => |n| if (builtin.os.tag == .windows) n.requestStop(),
        }
        m.bump();
        m.group.await(m.io) catch {};
        switch (m.os) {
            .none => {},
            .linux => |p| if (builtin.os.tag == .linux) p.close(),
            .windows => |n| if (builtin.os.tag == .windows) n.close(),
        }
        m.gpa.destroy(m);
    }

    fn bump(m: *PressureMonitor) void {
        _ = m.gen.fetchAdd(1, .release);
        m.io.futexWake(u32, &m.gen.raw, 1);
    }

    fn worker(m: *PressureMonitor) std.Io.Cancelable!void {
        while (!m.stopping.load(.acquire)) {
            const g = m.gen.load(.acquire);
            const level: Pressure = @enumFromInt(m.pending_level.swap(0, .acq_rel));
            const mask = m.pending_tags.swap(0, .acq_rel);
            if (level == .none and mask == 0) {
                try m.io.futexWait(u32, &m.gen.raw, g);
                wake_count.noteWake("perf.pressure", .signal);
                continue;
            }
            if (level != .none) m.finishRun(runReclaim(m.io, level, null, null));
            for (0..tags.tag_count) |i| {
                if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
                const tag: MemTag = @enumFromInt(i);
                const live: u64 = @intCast(@max(0, tags.tagStats(tag).live));
                const keep = ceiling(tag) / 10 * 8;
                if (live > keep) m.finishRun(runReclaim(m.io, .moderate, tag, live - keep));
            }
        }
    }

    fn finishRun(m: *PressureMonitor, r: ReclaimResult) void {
        m.last = r;
        _ = m.runs.fetchAdd(1, .release);
        log.info("reclaimed {d} of {d} bytes ({d} reclaimable, {d} calls)", .{ r.freed, r.target, r.reclaimable, r.calls });
    }
};

/// Where OS sources report levels.
pub const OsSink = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, level: Pressure) void,
};

const FakeCache = struct {
    tag: MemTag = .syntax,
    held: u64,
    slice: u64 = 1 << 20,
    calls: u32 = 0,
    order: *std.ArrayList(u64) = undefined,

    fn reclaimer(c: *FakeCache, name: []const u8) Reclaimer {
        return .{ .ctx = c, .tag = c.tag, .name = name, .reclaim = reclaim, .reclaimable = reclaimable };
    }

    fn reclaim(ctx: *anyopaque, _: Pressure, target: u64) u64 {
        const c: *FakeCache = @ptrCast(@alignCast(ctx));
        c.calls += 1;
        c.order.append(std.testing.allocator, c.held) catch {};
        // Frees in slices, like a real cache dropping entries.
        var freed: u64 = 0;
        while (freed < target and c.held > 0) {
            const n = @min(c.slice, c.held);
            c.held -= n;
            freed += n;
        }
        return freed;
    }

    fn reclaimable(ctx: *anyopaque) u64 {
        const c: *FakeCache = @ptrCast(@alignCast(ctx));
        return c.held;
    }
};

test "pressure: simulate critical runs reclaimers in order" {
    var order: std.ArrayList(u64) = .empty;
    defer order.deinit(std.testing.allocator);
    var small: FakeCache = .{ .held = 8 << 20, .order = &order };
    var big: FakeCache = .{ .held = 64 << 20, .order = &order };
    var mid: FakeCache = .{ .held = 24 << 20, .order = &order };
    const ids = [_]ReclaimerId{ registerReclaimer(small.reclaimer("small")), registerReclaimer(big.reclaimer("big")), registerReclaimer(mid.reclaimer("mid")) };
    defer for (ids) |id| unregisterReclaimer(id);
    const m = (try PressureMonitor.start(std.testing.allocator, std.testing.io, .{ .os_source = false })) orelse return error.SkipZigTest;
    defer m.stop();
    m.simulate(.critical);
    try std.testing.expectEqual(Pressure.critical, m.current());
    var waited: u32 = 0;
    while (m.runs.load(.acquire) == 0 and waited < 200) : (waited += 1) try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expectEqual(@as(u32, 1), m.runs.load(.acquire));
    const r = m.last;
    // 50 % of 96 MiB: the largest cache alone covers it.
    try std.testing.expectEqual(@as(u64, 96 << 20), r.reclaimable);
    try std.testing.expect(r.freed >= r.reclaimable / 2);
    try std.testing.expectEqual(@as(u64, 64 << 20), order.items[0]);
    try std.testing.expectEqual(@as(u32, 0), small.calls);
}

test "pressure: ceiling breach debounced" {
    var snap: sampler.Snapshot = .{};
    var last: [tags.max_tags]u64 = @splat(0);
    setCeiling(.notes, 10 << 20);
    defer setCeiling(.notes, 0);
    const i = @intFromEnum(MemTag.notes);
    snap.tags[i].live = 12 << 20;
    const s = std.time.ns_per_s;
    try std.testing.expectEqual(@as(u32, 1) << i, ceilingBreaches(&snap, &last, 100 * s, 5 * s));
    try std.testing.expectEqual(@as(u32, 0), ceilingBreaches(&snap, &last, 103 * s, 5 * s));
    try std.testing.expectEqual(@as(u32, 1) << i, ceilingBreaches(&snap, &last, 106 * s, 5 * s));
    snap.tags[i].live = 9 << 20;
    try std.testing.expectEqual(@as(u32, 0), ceilingBreaches(&snap, &last, 120 * s, 5 * s));
}

test "pressure: ceiling reclaim targets 80 % of the ceiling" {
    var order: std.ArrayList(u64) = .empty;
    defer order.deinit(std.testing.allocator);
    var cache: FakeCache = .{ .tag = .workspace, .held = 32 << 20, .order = &order };
    const id = registerReclaimer(cache.reclaimer("index pages"));
    defer unregisterReclaimer(id);
    // Only this tag's reclaimers run, with the given target.
    var other: FakeCache = .{ .tag = .ai, .held = 32 << 20, .order = &order };
    const id2 = registerReclaimer(other.reclaimer("transcripts"));
    defer unregisterReclaimer(id2);
    const r = runReclaim(std.testing.io, .moderate, .workspace, 6 << 20);
    try std.testing.expectEqual(@as(u64, 6 << 20), r.freed);
    try std.testing.expectEqual(@as(u32, 0), other.calls);
}

test "pressure: reclaimer slices do not exceed 2 ms" {
    var order: std.ArrayList(u64) = .empty;
    defer order.deinit(std.testing.allocator);
    var caches: [4]FakeCache = undefined;
    var ids: [4]ReclaimerId = undefined;
    for (&caches, &ids, 0..) |*c, *id, k| {
        c.* = .{ .held = (k + 1) << 22, .slice = 64 << 10, .order = &order };
        id.* = registerReclaimer(c.reclaimer("fake"));
    }
    defer for (ids) |id| unregisterReclaimer(id);
    const r = runReclaim(std.testing.io, .critical, null, null);
    try std.testing.expect(r.freed >= r.target);
    try std.testing.expect(r.max_call_ns < 2 * std.time.ns_per_ms);
}

test "pressure: unregistered reclaimers are not called" {
    var order: std.ArrayList(u64) = .empty;
    defer order.deinit(std.testing.allocator);
    var c: FakeCache = .{ .held = 1 << 20, .order = &order };
    unregisterReclaimer(registerReclaimer(c.reclaimer("gone")));
    _ = runReclaim(std.testing.io, .critical, null, null);
    try std.testing.expectEqual(@as(u32, 0), c.calls);
}

test {
    _ = pressure_linux;
    _ = pressure_windows;
}
