//! A hashed timer wheel: 512 slots of intrusive lists at a fixed
//! resolution (5 ms for the request scheduler). Insert and remove are O(1)
//! and never allocate; `advance` visits only the slots that came due.
//! Not thread-safe: the owner holds its lock around every call.

const std = @import("std");

pub const slot_count = 512;

/// Embed in the timed object; recover it with `@fieldParentPtr`.
pub const Node = struct {
    next: ?*Node = null,
    prev: ?*Node = null,
    /// The tick the node fires at.
    due_tick: u64 = 0,
    armed: bool = false,
};

pub const TimerWheel = struct {
    resolution_ns: u64,
    slots: [slot_count]?*Node = @splat(null),
    /// Every tick up to and including this one has been processed.
    tick: u64,
    count: usize = 0,

    pub fn init(resolution_ns: u64, now_ns: u64) TimerWheel {
        return .{ .resolution_ns = resolution_ns, .tick = now_ns / resolution_ns };
    }

    /// Arms `n` to fire at `due_ns` (rounded up to the resolution; at the
    /// earliest the next tick). Re-arms it if already armed.
    pub fn insert(w: *TimerWheel, n: *Node, due_ns: u64) void {
        if (n.armed) w.remove(n);
        const t = @max(std.math.divCeil(u64, due_ns, w.resolution_ns) catch unreachable, w.tick + 1);
        n.due_tick = t;
        const head = &w.slots[@intCast(t % slot_count)];
        n.prev = null;
        n.next = head.*;
        if (head.*) |h| h.prev = n;
        head.* = n;
        n.armed = true;
        w.count += 1;
    }

    /// Disarms `n`; does nothing if it is not armed.
    pub fn remove(w: *TimerWheel, n: *Node) void {
        if (!n.armed) return;
        if (n.prev) |p| p.next = n.next else w.slots[@intCast(n.due_tick % slot_count)] = n.next;
        if (n.next) |x| x.prev = n.prev;
        n.next = null;
        n.prev = null;
        n.armed = false;
        w.count -= 1;
    }

    /// Disarms every node due at or before `now_ns` and passes it to
    /// `fire(ctx, node)`. The callback must not touch the wheel.
    pub fn advance(w: *TimerWheel, now_ns: u64, ctx: anytype, comptime fire: fn (@TypeOf(ctx), *Node) void) void {
        const now_tick = now_ns / w.resolution_ns;
        if (now_tick <= w.tick) return;
        // More than one lap: every slot is visited once.
        const span = @min(now_tick - w.tick, slot_count);
        var i: u64 = 1;
        while (i <= span) : (i += 1) {
            const slot = &w.slots[@intCast((w.tick + i) % slot_count)];
            var it = slot.*;
            while (it) |n| {
                it = n.next;
                if (n.due_tick > now_tick) continue;
                w.remove(n);
                fire(ctx, n);
            }
        }
        w.tick = now_tick;
    }

    /// The tick of the earliest armed node, in ns (null when empty). O(slots).
    pub fn nextDueNs(w: *const TimerWheel) ?u64 {
        if (w.count == 0) return null;
        var best: ?u64 = null;
        for (w.slots) |head| {
            var it = head;
            while (it) |n| : (it = n.next) {
                if (best == null or n.due_tick < best.?) best = n.due_tick;
            }
        }
        return best.? * w.resolution_ns;
    }
};

test "timer wheel: fires in order of slots, laps, re-arm and remove" {
    const Fired = struct {
        list: [8]u64 = undefined,
        n: usize = 0,
        fn fire(f: *@This(), node: *Node) void {
            f.list[f.n] = node.due_tick;
            f.n += 1;
        }
    };
    var w: TimerWheel = .init(5, 1000);
    var a: Node = .{};
    var b: Node = .{};
    var c: Node = .{};
    var d: Node = .{};
    w.insert(&a, 1000); // at the earliest the next tick
    w.insert(&b, 1012);
    w.insert(&c, 1000 + 5 * slot_count * 2 + 5); // two laps out
    w.insert(&d, 1050);
    w.remove(&d);
    w.remove(&d);
    try std.testing.expectEqual(@as(usize, 3), w.count);
    try std.testing.expectEqual(@as(?u64, 1005), w.nextDueNs());

    var f: Fired = .{};
    w.advance(1004, &f, Fired.fire);
    try std.testing.expectEqual(@as(usize, 0), f.n);
    w.advance(1015, &f, Fired.fire);
    try std.testing.expectEqualSlices(u64, &.{ 201, 203 }, f.list[0..f.n]);
    // c shares slots with earlier laps but is not due until its own tick.
    w.advance(1000 + 5 * slot_count, &f, Fired.fire);
    try std.testing.expectEqual(@as(usize, 2), f.n);
    w.insert(&a, 1000 + 5 * slot_count + 100);
    w.advance(1000 + 5 * slot_count * 3, &f, Fired.fire);
    try std.testing.expectEqual(@as(usize, 4), f.n);
    try std.testing.expectEqual(@as(usize, 0), w.count);
    try std.testing.expect(!a.armed and !c.armed);
}
