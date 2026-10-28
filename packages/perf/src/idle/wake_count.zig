//! Wakeup attribution (E14.F05.S02.T01). Code calls `noteWake` right
//! after every blocking wait returns; each thread counts its own wakes
//! (plain stores into a per-thread record, registered once in a global
//! list) and, with tracing on, records the instant `perf.wake` at the
//! call site with the reason as its value. docs/perf/threading.md lists
//! the call sites; `zig build test-wake-sites` keeps new waits annotated.

const std = @import("std");
const zg_core = @import("zg_core");

/// Why a wait returned.
pub const WakeReason = enum(u8) { input, timer, mailbox, io_completion, frame, present, signal, unknown };

pub const reason_count = @typeInfo(WakeReason).@"enum".fields.len;

/// The site whose wakes are the idle monitor's own (excluded from the
/// reported count).
pub const monitor_site = "perf.idle_monitor";

const ThreadRec = struct {
    tid: u32,
    name: [24]u8 = @splat(0),
    name_len: std.atomic.Value(u8) = .init(0),
    count: std.atomic.Value(u64) = .init(0),
    monitor_count: std.atomic.Value(u64) = .init(0),
    by_reason: [reason_count]std.atomic.Value(u64) = @splat(.init(0)),
    last_site: std.atomic.Value(?*const zg_core.trace.Site) = .init(null),
    next: ?*ThreadRec = null,
};

var threads: std.atomic.Value(?*ThreadRec) = .init(null);
threadlocal var my_rec: ?*ThreadRec = null;

fn rec() ?*ThreadRec {
    if (my_rec) |r| return r;
    return newRec();
}

noinline fn newRec() ?*ThreadRec {
    const r = std.heap.page_allocator.create(ThreadRec) catch return null;
    r.* = .{ .tid = @truncate(std.Thread.getCurrentId()) };
    var head = threads.load(.monotonic);
    while (true) {
        r.next = head;
        head = threads.cmpxchgWeak(head, r, .release, .monotonic) orelse break;
    }
    my_rec = r;
    return r;
}

fn bump(v: *std.atomic.Value(u64)) void {
    v.store(v.load(.monotonic) + 1, .monotonic);
}

/// Counts a wake of this thread at `site` (a static name such as
/// "gui.host.wait").
pub inline fn noteWake(comptime site: []const u8, reason: WakeReason) void {
    noteWakeAt(zg_core.trace.siteFor(@src(), site), comptime std.mem.eql(u8, site, monitor_site), reason);
}

fn noteWakeAt(site: *const zg_core.trace.Site, own: bool, reason: WakeReason) void {
    zg_core.trace.recordRaw(.instant, site, @intFromEnum(reason));
    const r = rec() orelse return;
    if (own) return bump(&r.monitor_count);
    bump(&r.count);
    bump(&r.by_reason[@intFromEnum(reason)]);
    r.last_site.store(site, .monotonic);
}

/// Names this thread in snapshots (first 24 bytes).
pub fn nameThread(name: []const u8) void {
    const r = rec() orelse return;
    const n = @min(name.len, r.name.len);
    @memcpy(r.name[0..n], name[0..n]);
    r.name_len.store(@intCast(n), .release);
}

/// One thread's wakes.
pub const ThreadWakes = struct {
    tid: u32,
    name: []const u8,
    count: u64,
    /// Wakes of the idle monitor itself (not in `count`).
    monitor_count: u64,
    by_reason: [reason_count]u64,
    last_site: []const u8,
};

/// Fills `out` with every thread that ever noted a wake; returns how many
/// threads there are (may exceed `out.len`).
pub fn wakeSnapshot(out: []ThreadWakes) usize {
    var n: usize = 0;
    var it = threads.load(.acquire);
    while (it) |r| : (it = r.next) {
        defer n += 1;
        if (n >= out.len) continue;
        var by: [reason_count]u64 = undefined;
        for (&by, &r.by_reason) |*b, *v| b.* = v.load(.monotonic);
        out[n] = .{
            .tid = r.tid,
            .name = r.name[0..r.name_len.load(.acquire)],
            .count = r.count.load(.monotonic),
            .monitor_count = r.monitor_count.load(.monotonic),
            .by_reason = by,
            .last_site = if (r.last_site.load(.monotonic)) |s| s.name else "",
        };
    }
    return n;
}

/// Wakes of all threads, the monitor's own excluded.
pub fn totalWakes() u64 {
    var t: u64 = 0;
    var it = threads.load(.acquire);
    while (it) |r| : (it = r.next) t += r.count.load(.monotonic);
    return t;
}

test "wake: counts per thread and snapshot" {
    const W = struct {
        fn run(n: u32) void {
            nameThread("wake-test");
            for (0..n) |_| noteWake("test.wait", .timer);
            noteWake(monitor_site, .timer);
        }
    };
    const before = totalWakes();
    const t1 = try std.Thread.spawn(.{}, W.run, .{3});
    const t2 = try std.Thread.spawn(.{}, W.run, .{5});
    t1.join();
    t2.join();
    try std.testing.expectEqual(before + 8, totalWakes());
    var snap: [64]ThreadWakes = undefined;
    const n = @min(wakeSnapshot(&snap), snap.len);
    var seen: u32 = 0;
    for (snap[0..n]) |s| if (std.mem.eql(u8, s.name, "wake-test")) {
        seen += 1;
        try std.testing.expect(s.count == 3 or s.count == 5);
        try std.testing.expectEqual(s.count, s.by_reason[@intFromEnum(WakeReason.timer)]);
        try std.testing.expectEqual(@as(u64, 1), s.monitor_count);
        try std.testing.expectEqualStrings("test.wait", s.last_site);
    };
    try std.testing.expect(seen >= 2);
}
