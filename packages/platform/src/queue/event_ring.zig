//! The single-producer single-consumer event ring from the platform thread
//! to the UI thread. Push and pop are wait-free and allocation-free. When the
//! ring is full the producer coalesces mergeable events in place and, if
//! nothing merges, waits on a futex for the consumer instead of dropping.

const std = @import("std");
const Io = std.Io;
const types = @import("../api/types.zig");
const Event = @import("../api/event.zig").Event;

/// The outcome of `push`.
pub const PushResult = enum {
    /// The event was queued.
    ok,
    /// The ring is full; nothing was queued.
    full,
};

/// How far back `pushCoalescing` looks for a mergeable event.
pub const coalesce_window = 64;

/// A ring of `capacity` events (a power of two). One thread pushes, one
/// thread pops.
pub fn EventRing(comptime capacity: u32) type {
    if (capacity == 0 or !std.math.isPowerOfTwo(capacity)) @compileError("EventRing capacity must be a power of two");
    return struct {
        const Ring = @This();
        const mask = capacity - 1;

        /// Next slot the consumer reads. Written by the consumer only.
        head: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
        /// Next slot the producer writes. Written by the producer only.
        tail: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
        /// Set while the producer waits for space; the consumer then wakes
        /// the futex on `head`.
        producer_waiting: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
        /// Held by the consumer while it copies out, and by the producer
        /// while it rewrites queued slots during coalescing.
        slots_lock: std.atomic.Value(bool) = .init(false),
        /// Futex provider.
        io: Io,
        /// The slots.
        buf: [capacity]Event = undefined,

        /// The ring's capacity.
        pub const len = capacity;

        /// Queues `ev`. Producer thread only.
        pub fn push(r: *Ring, ev: Event) PushResult {
            const tail = r.tail.raw;
            const head = r.head.load(.acquire);
            if (tail -% head >= capacity) return .full;
            r.buf[tail & mask] = ev;
            r.tail.store(tail +% 1, .release);
            return .ok;
        }

        /// Queues `ev`. If the ring is full, merges `ev` into a queued event
        /// of the same kind and window (pointer moves, scrolls, configures
        /// and frames); otherwise blocks until the consumer makes room. Key,
        /// button, text and IME events are never dropped. Producer only.
        pub fn pushCoalescing(r: *Ring, ev: Event) void {
            while (true) {
                if (r.push(ev) == .ok) return;
                if (r.coalesce(ev)) return;
                const head = r.head.load(.acquire);
                r.producer_waiting.store(1, .seq_cst);
                // Recheck after announcing, so a pop between the failed
                // push and the store is not missed.
                if (r.tail.raw -% r.head.load(.seq_cst) < capacity) {
                    r.producer_waiting.store(0, .monotonic);
                    continue;
                }
                r.io.futexWaitUncancelable(u32, &r.head.raw, head);
                r.producer_waiting.store(0, .monotonic);
            }
        }

        fn coalesce(r: *Ring, ev: Event) bool {
            if (!mergeable(ev)) return false;
            const ev_win = ev.window();
            r.lock();
            defer r.unlock();
            const head = r.head.load(.acquire);
            const tail = r.tail.raw;
            var i = tail;
            var steps: u32 = 0;
            while (i != head and steps < coalesce_window) : (steps += 1) {
                i -%= 1;
                const slot = &r.buf[i & mask];
                if (!std.meta.eql(slot.window(), ev_win)) continue;
                // An event of another kind for the same window is a barrier:
                // merging across it would reorder that window's input.
                if (std.meta.activeTag(slot.*) != std.meta.activeTag(ev)) return false;
                return merge(slot, ev);
            }
            return false;
        }

        /// Moves up to `out.len` events into `out`; returns how many.
        /// Consumer thread only.
        pub fn popMany(r: *Ring, out: []Event) usize {
            if (out.len == 0) return 0;
            r.lock();
            const head = r.head.raw;
            const tail = r.tail.load(.acquire);
            const n: u32 = @intCast(@min(tail -% head, out.len));
            for (0..n) |k| out[k] = r.buf[(head +% @as(u32, @intCast(k))) & mask];
            r.head.store(head +% n, .seq_cst);
            r.unlock();
            if (n > 0 and r.producer_waiting.load(.seq_cst) != 0) r.io.futexWake(u32, &r.head.raw, 1);
            return n;
        }

        /// Events currently queued (approximate when called concurrently).
        pub fn count(r: *const Ring) u32 {
            return r.tail.load(.acquire) -% r.head.load(.acquire);
        }

        fn lock(r: *Ring) void {
            while (r.slots_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        }

        fn unlock(r: *Ring) void {
            r.slots_lock.store(false, .release);
        }
    };
}

/// Whether `ev` may be merged into an earlier event of the same kind.
pub fn mergeable(ev: Event) bool {
    return switch (ev) {
        .pointer_move, .scroll, .window_configure, .frame => true,
        else => false,
    };
}

/// Merges `ev` into `slot` (same tag). Moves, configures and frames take the
/// newer value; scrolls add their deltas when unit, source and phase match.
fn merge(slot: *Event, ev: Event) bool {
    switch (ev) {
        .pointer_move, .window_configure, .frame => slot.* = ev,
        .scroll => |s| {
            const old = &slot.scroll;
            if (old.unit != s.unit or old.source != s.source or old.phase != s.phase) return false;
            if (s.phase != .none and s.phase != .update) return false;
            old.dx += s.dx;
            old.dy += s.dy;
        },
        else => return false,
    }
    return true;
}

const testing = std.testing;

fn win(n: u32) types.WindowId {
    return @enumFromInt(n);
}

fn keyEv(seq: u32) Event {
    return .{ .key = .{ .win = win(1), .ev = .{ .key = .key_a, .keysym = seq, .codepoint = 0, .mods = .{}, .action = .press, .text = .empty, .native_scancode = 0, .time_ns = 0 } } };
}

fn moveEv(seq: u64) Event {
    return .{ .pointer_move = .{ .win = win(1), .pos_px = .{ @floatFromInt(seq), 0 }, .mods = .{}, .time_ns = seq } };
}

fn scrollEv(dy: f32) Event {
    return .{ .scroll = .{ .win = win(1), .dx = 0, .dy = dy, .unit = .lines, .source = .wheel, .phase = .none } };
}

test "push and popMany keep order and report full" {
    var r: EventRing(4) = .{ .io = testing.io };
    for (0..4) |i| try testing.expectEqual(PushResult.ok, r.push(keyEv(@intCast(i))));
    try testing.expectEqual(PushResult.full, r.push(keyEv(9)));
    var out: [8]Event = undefined;
    try testing.expectEqual(3, r.popMany(out[0..3]));
    for (0..3) |i| try testing.expectEqual(@as(u32, @intCast(i)), out[i].key.ev.keysym);
    try testing.expectEqual(1, r.popMany(&out));
    try testing.expectEqual(0, r.popMany(&out));
}

test "coalesce scroll sums deltas" {
    var r: EventRing(4) = .{ .io = testing.io };
    _ = r.push(keyEv(0));
    _ = r.push(moveEv(1));
    _ = r.push(scrollEv(1));
    _ = r.push(scrollEv(2));
    r.pushCoalescing(scrollEv(3));
    r.pushCoalescing(scrollEv(-0.5));
    var out: [8]Event = undefined;
    try testing.expectEqual(4, r.popMany(&out));
    try testing.expect(out[0] == .key);
    try testing.expectEqual(@as(f32, 1), out[1].pointer_move.pos_px[0]);
    try testing.expectEqual(@as(f32, 1), out[2].scroll.dy);
    try testing.expectEqual(@as(f32, 4.5), out[3].scroll.dy);
    try testing.expect(!mergeable(keyEv(0)));
    try testing.expect(!mergeable(.{ .text_input = .{ .win = win(1), .text = .empty } }));
}

test "ring spsc stress 10M" {
    const total: u32 = if (@import("builtin").mode == .Debug) 1_000_000 else 10_000_000;
    const Ring = EventRing(4096);
    const r = try testing.allocator.create(Ring);
    defer testing.allocator.destroy(r);
    r.* = .{ .io = testing.io };
    const Producer = struct {
        fn run(ring: *Ring, n: u32) void {
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                // Three moves per key: moves may coalesce, keys must not.
                ring.pushCoalescing(keyEv(i));
                for (0..3) |k| ring.pushCoalescing(moveEv(3 * @as(u64, i) + k));
            }
        }
    };
    const Check = struct {
        next_key: u32 = 0,
        last_seq: ?u64 = null,
        fn take(c: *@This(), evs: []const Event) !void {
            for (evs) |e| switch (e) {
                .key => |k| {
                    try testing.expectEqual(c.next_key, k.ev.keysym);
                    c.next_key += 1;
                },
                .pointer_move => |m| {
                    // Coalescing loses only intermediate positions, never reorders.
                    if (c.last_seq) |l| try testing.expect(m.time_ns > l);
                    c.last_seq = m.time_ns;
                },
                else => return error.UnexpectedEvent,
            };
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{ r, total });
    var check: Check = .{};
    var out: [256]Event = undefined;
    while (check.next_key < total) check.take(out[0..r.popMany(&out)]) catch |err| {
        // Keep draining so the producer can finish before the ring is freed.
        while (check.next_key < total) {
            const n = r.popMany(&out);
            for (out[0..n]) |e| if (e == .key) {
                check.next_key += 1;
            };
        }
        t.join();
        return err;
    };
    t.join();
    while (r.count() > 0) try check.take(out[0..r.popMany(&out)]);
    try testing.expectEqual(3 * @as(u64, total) - 1, check.last_seq.?);
}
