//! The chunked trace event store (E14.F02.S01.T02): drained events land
//! in fixed 4096-event chunks (128 KiB) under a byte cap. Freed chunks go
//! back to a free list, so a long recording or a rolling flight-recorder
//! window does not churn the allocator. Thread names are kept apart, one
//! per thread, so dropping old chunks never loses them and repeated drains
//! never duplicate them.

const std = @import("std");
const zg_core = @import("zg_core");

const Event = zg_core.trace.Event;
const Kind = zg_core.trace.Kind;

/// Events per chunk.
pub const chunk_events = 4096;

/// One chunk of events, in drain order.
pub const Chunk = struct {
    len: u32 = 0,
    /// Earliest event time in the chunk.
    min_ts: u64 = std.math.maxInt(u64),
    /// Latest time any event in the chunk covers (zone end included).
    max_ts: u64 = 0,
    next: ?*Chunk = null,
    events: [chunk_events]Event = undefined,
};

/// The event store. Single-threaded: the drain owns it.
pub const Store = struct {
    gpa: std.mem.Allocator,
    max_bytes: u64,
    head: ?*Chunk = null,
    tail: ?*Chunk = null,
    free: ?*Chunk = null,
    live_chunks: u64 = 0,
    events: u64 = 0,
    /// The latest `thread_name` event per thread.
    names: std.ArrayList(Event) = .empty,

    /// A store that holds at most `max_bytes` of chunks (at least one).
    pub fn init(gpa: std.mem.Allocator, max_bytes: u64) Store {
        return .{ .gpa = gpa, .max_bytes = max_bytes };
    }

    /// Frees every chunk.
    pub fn deinit(s: *Store) void {
        freeList(s.gpa, s.head);
        freeList(s.gpa, s.free);
        s.names.deinit(s.gpa);
        s.* = undefined;
    }

    fn freeList(gpa: std.mem.Allocator, first: ?*Chunk) void {
        var c = first;
        while (c) |chunk| {
            c = chunk.next;
            gpa.destroy(chunk);
        }
    }

    /// Bytes held by live chunks.
    pub fn bytes(s: *const Store) u64 {
        return s.live_chunks * @sizeOf(Chunk);
    }

    fn newChunk(s: *Store) error{Full}!*Chunk {
        if ((s.live_chunks + 1) * @sizeOf(Chunk) > @max(s.max_bytes, @sizeOf(Chunk))) return error.Full;
        const c = if (s.free) |f| blk: {
            s.free = f.next;
            break :blk f;
        } else s.gpa.create(Chunk) catch return error.Full;
        c.* = .{};
        if (s.tail) |t| t.next = c else s.head = c;
        s.tail = c;
        s.live_chunks += 1;
        return c;
    }

    fn noteName(s: *Store, e: Event) error{Full}!void {
        for (s.names.items) |*n| if (n.tid == e.tid) {
            n.* = e;
            return;
        };
        s.names.append(s.gpa, e) catch return error.Full;
    }

    /// Appends `evs`. On `error.Full` the events that fit were stored.
    pub fn appendSlice(s: *Store, evs: []const Event) error{Full}!void {
        var i: usize = 0;
        while (i < evs.len) {
            const e = evs[i];
            if (e.kind == @intFromEnum(Kind.thread_name)) {
                try s.noteName(e);
                i += 1;
                continue;
            }
            const c = blk: {
                if (s.tail) |t| if (t.len < chunk_events) break :blk t;
                break :blk try s.newChunk();
            };
            c.events[c.len] = e;
            c.len += 1;
            const end = if (e.kind == @intFromEnum(Kind.zone)) e.ts +| @as(u64, @intCast(@max(0, e.value))) else e.ts;
            c.max_ts = @max(c.max_ts, end);
            c.min_ts = @min(c.min_ts, e.ts);
            s.events += 1;
            i += 1;
        }
    }

    /// Returns the leading chunks whose events all end before `ts` to the
    /// free list (the flight recorder's rolling window).
    pub fn dropOlderThan(s: *Store, ts: u64) void {
        while (s.head) |c| {
            // Keep the chunk being filled.
            if (c.max_ts >= ts or c == s.tail) break;
            s.dropHead();
        }
    }

    /// Drops the oldest chunks until at most `max` bytes are held (an
    /// event storm outrunning the time window). Keeps the chunk being
    /// filled.
    pub fn trimToBytes(s: *Store, max: u64) void {
        while (s.bytes() > max and s.head != null and s.head != s.tail) s.dropHead();
    }

    fn dropHead(s: *Store) void {
        const c = s.head.?;
        s.head = c.next;
        s.events -= c.len;
        s.live_chunks -= 1;
        c.next = s.free;
        s.free = c;
    }

    /// The earliest event time held, or null when empty.
    pub fn oldestTs(s: *const Store) ?u64 {
        var c = s.head;
        while (c) |chunk| : (c = chunk.next) if (chunk.len != 0) return chunk.min_ts;
        return null;
    }

    /// Drops every event (keeps thread names and the free list).
    pub fn clear(s: *Store) void {
        s.dropOlderThan(std.math.maxInt(u64));
        if (s.head) |c| {
            s.events -= c.len;
            c.len = 0;
            c.max_ts = 0;
            c.min_ts = std.math.maxInt(u64);
        }
    }

    /// Iterates thread names first, then each chunk's events in order.
    pub fn iterator(s: *const Store) Iterator {
        return .{ .names = s.names.items, .chunk = s.head };
    }

    /// See `iterator`.
    pub const Iterator = struct {
        names: []const Event,
        chunk: ?*const Chunk,

        /// The next run of events, or null.
        pub fn next(it: *Iterator) ?[]const Event {
            if (it.names.len != 0) {
                defer it.names = &.{};
                return it.names;
            }
            while (it.chunk) |c| {
                it.chunk = c.next;
                if (c.len != 0) return c.events[0..c.len];
            }
            return null;
        }
    };

    /// Copies every event (names first) into `out`.
    pub fn copyAll(s: *const Store, gpa: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
        var it = s.iterator();
        while (it.next()) |run| try out.appendSlice(gpa, run);
    }
};

fn ev(ts: u64) Event {
    return .{ .ts = ts, .site_or_name = 0, .kind = @intFromEnum(Kind.instant), .tid = 1, .value = 0 };
}

test "store: append until full" {
    var s = Store.init(std.testing.allocator, 2 * @sizeOf(Chunk));
    defer s.deinit();
    var batch: [1000]Event = undefined;
    for (&batch, 0..) |*e, i| e.* = ev(i);
    var stored: usize = 0;
    while (true) {
        s.appendSlice(&batch) catch break;
        stored += batch.len;
    }
    try std.testing.expectEqual(@as(u64, 2 * chunk_events), s.events);
    try std.testing.expectEqual(@as(u64, 2 * @sizeOf(Chunk)), s.bytes());
    try std.testing.expect(stored < 2 * chunk_events);
    var it = s.iterator();
    var n: usize = 0;
    while (it.next()) |run| n += run.len;
    try std.testing.expectEqual(@as(usize, 2 * chunk_events), n);
}

test "store: dropOlderThan frees chunks to pool" {
    var s = Store.init(std.testing.allocator, 1 << 30);
    defer s.deinit();
    const name: Event = .{ .ts = 0, .site_or_name = 0, .kind = @intFromEnum(Kind.thread_name), .tid = 1, .value = 0 };
    try s.appendSlice(&.{name});
    var ts: u64 = 0;
    for (0..4) |_| {
        var batch: [chunk_events]Event = undefined;
        for (&batch) |*e| {
            e.* = ev(ts);
            ts += 1;
        }
        try s.appendSlice(&batch);
    }
    try std.testing.expectEqual(@as(u64, 4), s.live_chunks);
    s.dropOlderThan(2 * chunk_events);
    try std.testing.expectEqual(@as(u64, 2), s.live_chunks);
    try std.testing.expectEqual(@as(u64, 2 * chunk_events), s.events);
    try std.testing.expect(s.free != null);
    // Reuse from the free list, not the allocator.
    const freed = s.free.?;
    try s.appendSlice(&.{ev(ts)});
    try std.testing.expectEqual(freed, s.tail.?);
    // Names survive and come first.
    var it = s.iterator();
    try std.testing.expectEqual(@as(u8, @intFromEnum(Kind.thread_name)), it.next().?[0].kind);
    s.clear();
    try std.testing.expectEqual(@as(u64, 0), s.events);
    try std.testing.expectEqual(@as(usize, 1), s.names.items.len);
}
