//! A per-thread shadow stack of open trace zones, kept through the
//! `zg_core.trace.ZoneHook` so another thread (the stall watchdog) can see
//! what a stuck thread is doing. Only threads that opt in pay for it.

const std = @import("std");
const zg_core = @import("zg_core");
const Site = zg_core.trace.Site;

/// True when trace zones are compiled in (`-Dtracing=zones|full`).
pub const enabled = zg_core.trace.enabled;

/// Sites stored per stack; deeper zones still count in `depth`.
pub const capacity = 32;

/// The open zones of one thread, innermost last.
pub const ShadowStack = struct {
    /// `*const Site` as usize; 0 = empty.
    sites: [capacity]std.atomic.Value(usize) = @splat(.init(0)),
    /// Open zone count (may exceed `capacity`).
    depth: std.atomic.Value(u8) = .init(0),
    /// The owning thread's id.
    tid: u32 = 0,

    /// Pushes `site` (owner thread; relaxed stores).
    pub fn push(s: *ShadowStack, site: *const Site) void {
        const d = s.depth.load(.monotonic);
        if (d < capacity) s.sites[d].store(@intFromPtr(site), .monotonic);
        s.depth.store(d +| 1, .release);
    }

    /// Pops the innermost zone (owner thread).
    pub fn pop(s: *ShadowStack) void {
        const d = s.depth.load(.monotonic);
        if (d == 0) return;
        if (d <= capacity) s.sites[d - 1].store(0, .monotonic);
        s.depth.store(d - 1, .release);
    }

    /// Copies up to 16 outermost open sites into `out` from any thread and
    /// returns how many were written. Best effort: a racing push or pop may
    /// show a slightly stale stack, but every pointer returned is a static
    /// site (they live forever).
    pub fn snapshot(s: *const ShadowStack, out: *[16]?*const Site) u8 {
        const d = @min(s.depth.load(.acquire), capacity, out.len);
        var n: u8 = 0;
        for (0..d) |i| {
            const v = s.sites[i].load(.monotonic);
            if (v == 0) break;
            out[n] = @ptrFromInt(v);
            n += 1;
        }
        for (out[n..]) |*o| o.* = null;
        return n;
    }
};

threadlocal var current: ?*ShadowStack = null;

fn hookBegin(site: *const Site) void {
    if (current) |s| s.push(site);
}

fn hookEnd() void {
    if (current) |s| s.pop();
}

const hook: zg_core.trace.ZoneHook = .{ .begin = hookBegin, .end = hookEnd };

const max_threads = 8;
var registry: [max_threads]std.atomic.Value(?*ShadowStack) = @splat(.init(null));

/// Gives the calling thread a shadow stack (idempotent) and installs the
/// zone hook. The stack lives for the process (page allocator).
pub fn enableForCurrentThread() *ShadowStack {
    if (current) |s| return s;
    const s = std.heap.page_allocator.create(ShadowStack) catch @panic("zg_perf: out of memory for a shadow stack");
    s.* = .{ .tid = @truncate(@as(u64, @intCast(std.Thread.getCurrentId()))) };
    for (&registry) |*slot| {
        if (slot.cmpxchgStrong(null, s, .acq_rel, .acquire) == null) break;
    }
    current = s;
    zg_core.trace.zone_hook = &hook;
    return s;
}

/// The calling thread's stack, if it opted in.
pub fn forCurrentThread() ?*ShadowStack {
    return current;
}

/// The stack of thread `tid`, if it opted in.
pub fn forThread(tid: u32) ?*ShadowStack {
    for (&registry) |*slot| if (slot.load(.acquire)) |s| if (s.tid == tid) return s;
    return null;
}

/// Formats `sites[0..n]` as `a > b > c`.
pub fn writeStack(w: *std.Io.Writer, sites: []const ?*const Site) std.Io.Writer.Error!void {
    for (sites, 0..) |site, i| {
        if (i != 0) try w.writeAll(" > ");
        try w.writeAll(if (site) |x| x.name else "?");
    }
}

test "shadow: overflow depth counts" {
    var s: ShadowStack = .{};
    const site = zg_core.trace.siteFor(@src(), "deep");
    for (0..40) |_| s.push(site);
    try std.testing.expectEqual(@as(u8, 40), s.depth.load(.monotonic));
    var out: [16]?*const Site = undefined;
    try std.testing.expectEqual(@as(u8, 16), s.snapshot(&out));
    for (0..40) |_| s.pop();
    try std.testing.expectEqual(@as(u8, 0), s.depth.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 0), s.snapshot(&out));
    s.pop(); // underflow is ignored
}

test "shadow: zone hook pushes and pops" {
    if (!enabled) return error.SkipZigTest;
    const T = struct {
        fn run(ok: *bool) void {
            const s = enableForCurrentThread();
            const a = zg_core.trace.zone(@src(), "a");
            const b = zg_core.trace.zone(@src(), "b");
            var out: [16]?*const Site = undefined;
            const n = s.snapshot(&out);
            ok.* = n == 2 and std.mem.eql(u8, out[0].?.name, "a") and std.mem.eql(u8, out[1].?.name, "b") and forThread(s.tid) == s;
            b.end();
            a.end();
            ok.* = ok.* and s.depth.load(.monotonic) == 0;
            zg_core.trace.zone_hook = null;
        }
    };
    var ok = false;
    const t = try std.Thread.spawn(.{}, T.run, .{&ok});
    t.join();
    try std.testing.expect(ok);
    var events: std.ArrayList(zg_core.trace.Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try zg_core.trace.collect(std.testing.allocator, &events);
}

test "shadow: snapshot from other thread" {
    var s: ShadowStack = .{};
    var stop: std.atomic.Value(bool) = .init(false);
    const Reader = struct {
        fn run(st: *const ShadowStack, done: *std.atomic.Value(bool), bad: *bool) void {
            var out: [16]?*const Site = undefined;
            while (!done.load(.acquire)) {
                const n = st.snapshot(&out);
                if (n > 16) bad.* = true;
                for (out[0..n]) |o| if (o == null or o.?.name.len == 0) {
                    bad.* = true;
                };
            }
        }
    };
    var bad = false;
    const t = try std.Thread.spawn(.{}, Reader.run, .{ &s, &stop, &bad });
    const sa = zg_core.trace.siteFor(@src(), "x");
    const sb = zg_core.trace.siteFor(@src(), "y");
    for (0..1_000_000) |i| {
        s.push(sa);
        if (i % 3 == 0) s.push(sb);
        if (i % 3 == 0) s.pop();
        s.pop();
    }
    stop.store(true, .release);
    t.join();
    try std.testing.expect(!bad);
    try std.testing.expect(s.depth.load(.monotonic) <= capacity);
}
