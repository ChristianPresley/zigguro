//! Trace zones, counters and frame marks: the low-overhead instrumentation
//! E14 builds on. Compiled out entirely with `-Dtracing=off` (the default):
//! `Zone` is zero-sized and every call is an empty inline function.
//!
//! Usage:
//! ```zig
//! const z = trace.zone(@src(), "layout");
//! defer z.end();
//! ```
//!
//! Each thread records into its own lock-free ring (64 Ki events, allocated
//! from the page allocator on first use and registered in a global list).
//! When a ring is full the newest event is dropped and `dropped` counts it;
//! recording never blocks. `collect` drains every ring (call it from one
//! thread at a time) and `writeChromeJson` emits the Trace Event Format.

const std = @import("std");
const options = @import("zg_options");
const time = @import("time.zig");
const SpscRing = @import("containers/ring_buffer.zig").SpscRing;

/// True unless built with `-Dtracing=off`.
pub const enabled = options.tracing != .off;

/// Static description of a zone or counter call site.
pub const Site = struct { name: []const u8, file: []const u8, line: u32 };

/// Returns the unique static `Site` for a call site (no runtime registration).
pub fn siteFor(comptime src: std.builtin.SourceLocation, comptime name: []const u8) *const Site {
    return &struct {
        const site: Site = .{ .name = name, .file = src.file, .line = src.line };
    }.site;
}

/// An open zone; `end()` records it. 16 bytes when enabled, 0 when disabled.
pub const Zone = if (enabled) struct {
    start: u64,
    site: *const Site,

    /// Records the completed zone into this thread's ring.
    pub fn end(z: Zone) void {
        record(.{ .ts = z.start, .site_or_name = @intFromPtr(z.site), .kind = @intFromEnum(Kind.zone), .tid = 0, .value = @intCast(time.fastTicks() -% z.start) });
    }
} else struct {
    /// No-op when tracing is compiled out.
    pub inline fn end(_: Zone) void {}
};

/// Opens a zone named `name` at `src` (pass `@src()`).
pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: []const u8) Zone {
    if (!enabled) return .{};
    return .{ .start = time.fastTicks(), .site = siteFor(src, name) };
}

/// Records a counter sample.
pub inline fn counter(comptime name: []const u8, value: i64) void {
    if (!enabled) return;
    record(.{ .ts = time.fastTicks(), .site_or_name = @intFromPtr(siteFor(@src(), name)), .kind = @intFromEnum(Kind.counter), .tid = 0, .value = value });
}

const frame_site: Site = .{ .name = "frame", .file = "", .line = 0 };

/// Marks the start of a frame (an instant event named "frame").
pub inline fn frameMark() void {
    if (!enabled) return;
    record(.{ .ts = time.fastTicks(), .site_or_name = @intFromPtr(&frame_site), .kind = @intFromEnum(Kind.instant), .tid = 0, .value = 0 });
}

/// Event kinds stored in `Event.kind`.
pub const Kind = enum(u8) { zone, counter, instant, thread_name };

/// One recorded event. In rings `ts` is in ticks; after `collect` it is
/// nanoseconds on the `.awake` clock and zone `value`s are durations in ns.
/// `site_or_name` is the address of a static `Site`.
pub const Event = extern struct { ts: u64, site_or_name: usize, kind: u8, tid: u32, value: i64 };

/// Events per thread ring.
pub const ring_capacity = 65536;

const Ring = struct {
    events: SpscRing(Event, ring_capacity) = .empty,
    dropped: std.atomic.Value(u64) = .init(0),
    tid: u32,
    name_buf: [32]u8 = @splat(0),
    name_site: Site = .{ .name = "", .file = "", .line = 0 },
    next: ?*Ring = null,
};

threadlocal var local_ring: ?*Ring = null;
var rings: std.atomic.Value(?*Ring) = .init(null);
var calibration: ?time.TickCalibration = null;

/// Anchors the tick-to-ns calibration; call once at startup with the
/// runtime's `io` (cheap: two clock reads). `collect` finishes it.
pub fn init(io: std.Io) void {
    if (!enabled) return;
    time.setFallbackIo(io);
    calibration = .begin(io);
    calibrate_io = io;
}

var calibrate_io: ?std.Io = null;

fn threadRing() ?*Ring {
    if (local_ring) |r| return r;
    const r = std.heap.page_allocator.create(Ring) catch return null;
    r.* = .{ .tid = @truncate(@as(u64, @intCast(std.Thread.getCurrentId()))) };
    var head = rings.load(.acquire);
    while (true) {
        r.next = head;
        head = rings.cmpxchgWeak(head, r, .acq_rel, .acquire) orelse break;
    }
    local_ring = r;
    return r;
}

fn record(e: Event) void {
    const r = threadRing() orelse return;
    var ev = e;
    ev.tid = r.tid;
    if (!r.events.push(ev)) _ = r.dropped.fetchAdd(1, .monotonic);
}

/// Names the calling thread in exported traces (truncated to 32 bytes).
pub fn setThreadName(name: []const u8) void {
    if (!enabled) return;
    const r = threadRing() orelse return;
    const n = @min(name.len, r.name_buf.len);
    @memcpy(r.name_buf[0..n], name[0..n]);
    r.name_site = .{ .name = r.name_buf[0..n], .file = "", .line = 0 };
}

/// Total events dropped because a ring was full.
pub fn droppedCount() u64 {
    var total: u64 = 0;
    var r = rings.load(.acquire);
    while (r) |ring| : (r = ring.next) total += ring.dropped.load(.monotonic);
    return total;
}

/// Drains every thread ring into `out`, converting ticks to nanoseconds.
/// Appends one `thread_name` event per named thread. Not reentrant: call
/// from one thread at a time.
pub fn collect(gpa: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    if (!enabled) return;
    var cal: time.TickCalibration = calibration orelse .{ .ticks0 = 0, .ns0 = 0 };
    if (calibration != null) if (calibrate_io) |io| cal.finish(io);
    var r = rings.load(.acquire);
    while (r) |ring| : (r = ring.next) {
        if (ring.name_site.name.len != 0) {
            try out.append(gpa, .{ .ts = 0, .site_or_name = @intFromPtr(&ring.name_site), .kind = @intFromEnum(Kind.thread_name), .tid = ring.tid, .value = 0 });
        }
        while (ring.events.pop()) |e| {
            var ev = e;
            ev.ts = cal.toNs(e.ts);
            if (e.kind == @intFromEnum(Kind.zone)) ev.value = @intCast(cal.durationNs(@intCast(e.value)));
            try out.append(gpa, ev);
        }
    }
}

/// Writes `events` (from `collect`) as a Trace Event Format JSON array:
/// `X` complete events for zones, `C` counters, `i` instants and `M`
/// thread-name metadata. Times are microseconds.
pub fn writeChromeJson(events: []const Event, w: *std.Io.Writer) !void {
    try w.writeAll("[");
    for (events, 0..) |e, i| {
        if (i != 0) try w.writeAll(",\n");
        const site: *const Site = @ptrFromInt(e.site_or_name);
        const ts_us = @as(f64, @floatFromInt(e.ts)) / 1000.0;
        try w.writeAll("{\"name\":");
        try std.json.Stringify.encodeJsonString(site.name, .{}, w);
        switch (@as(Kind, @enumFromInt(e.kind))) {
            .zone => try w.print(",\"ph\":\"X\",\"ts\":{d:.3},\"dur\":{d:.3},\"pid\":1,\"tid\":{d}", .{ ts_us, @as(f64, @floatFromInt(e.value)) / 1000.0, e.tid }),
            .counter => try w.print(",\"ph\":\"C\",\"ts\":{d:.3},\"pid\":1,\"tid\":{d},\"args\":{{\"value\":{d}}}", .{ ts_us, e.tid, e.value }),
            .instant => try w.print(",\"ph\":\"i\",\"s\":\"t\",\"ts\":{d:.3},\"pid\":1,\"tid\":{d}", .{ ts_us, e.tid }),
            .thread_name => {
                try w.print(",\"ph\":\"M\",\"pid\":1,\"tid\":{d},\"args\":{{\"name\":", .{e.tid});
                try std.json.Stringify.encodeJsonString(site.name, .{}, w);
                try w.writeAll("}");
            },
        }
        try w.writeAll("}");
    }
    try w.writeAll("]\n");
}

test "trace: zone size matches the tracing mode" {
    if (enabled) {
        try std.testing.expect(@sizeOf(Zone) <= 16);
    } else {
        comptime std.debug.assert(@sizeOf(Zone) == 0);
    }
}

test "trace: zones from 4 threads collected and nested correctly" {
    if (!enabled) return error.SkipZigTest;
    init(std.testing.io);
    const gpa = std.testing.allocator;
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);
    try collect(gpa, &events); // drain anything earlier tests recorded
    events.clearRetainingCapacity();
    const Worker = struct {
        fn run() void {
            setThreadName("worker");
            for (0..100) |_| {
                const outer = zone(@src(), "outer");
                {
                    const inner = zone(@src(), "inner");
                    inner.end();
                }
                outer.end();
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{});
    for (threads) |t| t.join();
    try collect(gpa, &events);
    var zones: usize = 0;
    var i: usize = 0;
    while (i < events.items.len) : (i += 1) {
        const e = events.items[i];
        if (e.kind != @intFromEnum(Kind.zone)) continue;
        zones += 1;
        const site: *const Site = @ptrFromInt(e.site_or_name);
        if (std.mem.eql(u8, site.name, "inner")) {
            // The enclosing outer zone ends after inner on the same thread.
            const o = events.items[i + 1];
            try std.testing.expectEqual(e.tid, o.tid);
            try std.testing.expect(o.ts <= e.ts);
            try std.testing.expect(o.ts + @as(u64, @intCast(o.value)) + 1000 >= e.ts + @as(u64, @intCast(e.value)));
        }
    }
    try std.testing.expectEqual(@as(usize, 800), zones);
}

test "trace: chrome json parses with std.json" {
    const gpa = std.testing.allocator;
    const s1 = siteFor(@src(), "layout \"q\"");
    const s2 = siteFor(@src(), "bytes");
    const evs = [_]Event{
        .{ .ts = 1000, .site_or_name = @intFromPtr(s1), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 500 },
        .{ .ts = 2000, .site_or_name = @intFromPtr(s2), .kind = @intFromEnum(Kind.counter), .tid = 1, .value = 42 },
        .{ .ts = 3000, .site_or_name = @intFromPtr(&frame_site), .kind = @intFromEnum(Kind.instant), .tid = 2, .value = 0 },
        .{ .ts = 0, .site_or_name = @intFromPtr(s2), .kind = @intFromEnum(Kind.thread_name), .tid = 2, .value = 0 },
    };
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try writeChromeJson(&evs, &buf.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, buf.written(), .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqualStrings("X", arr[0].object.get("ph").?.string);
    try std.testing.expectEqualStrings("layout \"q\"", arr[0].object.get("name").?.string);
}

test "trace: ring overflow increments dropped" {
    if (!enabled) return error.SkipZigTest;
    const Worker = struct {
        fn run() void {
            for (0..ring_capacity + 10) |_| zone(@src(), "spam").end();
        }
    };
    const before = droppedCount();
    const t = try std.Thread.spawn(.{}, Worker.run, .{});
    t.join();
    try std.testing.expect(droppedCount() >= before + 10);
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try collect(std.testing.allocator, &events);
}
