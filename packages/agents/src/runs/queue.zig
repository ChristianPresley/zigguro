//! The run queue (E13.F01.S01.T02): runs waiting for a host slot, in
//! priority order (interactive > background > task > triggered >
//! scheduled > workflow > workflow_worker), FIFO by `RunId` within a
//! priority. A run is runnable when both the global cap and its kind's cap
//! have room.

const std = @import("std");
const run = @import("run.zig");

const RunId = run.RunId;
const RunKind = run.RunKind;

pub fn priority(k: RunKind) u8 {
    return switch (k) {
        .interactive => 0,
        .background => 1,
        .task => 2,
        .triggered => 3,
        .scheduled => 4,
        .workflow => 5,
        .workflow_worker => 6,
    };
}

/// Runs holding a slot, in total and per kind.
pub const Counts = struct {
    total: u16 = 0,
    per_kind: std.EnumArray(RunKind, u16) = .initFill(0),

    pub fn add(c: *Counts, k: RunKind) void {
        c.total += 1;
        c.per_kind.getPtr(k).* += 1;
    }

    pub fn sub(c: *Counts, k: RunKind) void {
        c.total -= 1;
        c.per_kind.getPtr(k).* -= 1;
    }
};

pub const Limits = struct {
    max_concurrent: u16 = 6,
    max_per_kind: std.EnumArray(RunKind, u16) = .initFill(64),
};

const Entry = struct { id: RunId, kind: RunKind };

fn before(_: void, a: Entry, b: Entry) std.math.Order {
    const pa = priority(a.kind);
    const pb = priority(b.kind);
    if (pa != pb) return std.math.order(pa, pb);
    return a.id.order(b.id);
}

pub const RunQueue = struct {
    heap: std.PriorityQueue(Entry, void, before) = .empty,

    pub fn deinit(q: *RunQueue, gpa: std.mem.Allocator) void {
        q.heap.deinit(gpa);
    }

    pub fn push(q: *RunQueue, gpa: std.mem.Allocator, id: RunId, kind: RunKind) std.mem.Allocator.Error!void {
        try q.heap.push(gpa, .{ .id = id, .kind = kind });
    }

    pub fn len(q: *const RunQueue) usize {
        return q.heap.items.len;
    }

    /// Removes `id` if queued.
    pub fn remove(q: *RunQueue, id: RunId) bool {
        for (q.heap.items, 0..) |e, i| if (e.id.eql(id)) {
            _ = q.heap.popIndex(i);
            return true;
        };
        return false;
    }

    /// The best queued run that fits the limits, removed from the queue.
    /// A kind at its cap does not block lower priorities.
    pub fn popRunnable(q: *RunQueue, running: *const Counts, limits: Limits) ?RunId {
        if (running.total >= limits.max_concurrent) return null;
        var best: ?usize = null;
        for (q.heap.items, 0..) |e, i| {
            if (running.per_kind.get(e.kind) >= limits.max_per_kind.get(e.kind)) continue;
            if (best == null or before({}, e, q.heap.items[best.?]) == .lt) best = i;
        }
        const i = best orelse return null;
        return q.heap.popIndex(i).id;
    }
};

const testing = std.testing;

test "queue_respects_limits_and_priority" {
    const gpa = testing.allocator;
    var q: RunQueue = .{};
    defer q.deinit(gpa);
    const kinds = [_]RunKind{ .scheduled, .background, .interactive, .task, .triggered, .workflow_worker };
    var ids: [20]RunId = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = .fromInt(@as(u128, i + 1) << 80);
        try q.push(gpa, id.*, kinds[i % kinds.len]);
    }
    var limits: Limits = .{ .max_concurrent = 6 };
    limits.max_per_kind.set(.interactive, 2);
    var counts: Counts = .{};
    var got: std.ArrayList(RunId) = .empty;
    defer got.deinit(gpa);
    while (q.popRunnable(&counts, limits)) |id| {
        try got.append(gpa, id);
        const k = kinds[(@as(usize, @intCast(id.toInt() >> 80)) - 1) % kinds.len];
        counts.add(k);
    }
    // Cap 6: 2 interactive (cap), then 4 background, all FIFO.
    try testing.expectEqual(@as(usize, 6), got.items.len);
    try testing.expect(got.items[0].eql(ids[2]));
    try testing.expect(got.items[1].eql(ids[8]));
    try testing.expect(got.items[2].eql(ids[1]));
    try testing.expect(got.items[3].eql(ids[7]));
    try testing.expect(got.items[4].eql(ids[13]));
    try testing.expect(got.items[5].eql(ids[19]));
    // A freed background slot goes to the next best: the third interactive
    // is still capped, so a task runs.
    counts.sub(.background);
    const next = q.popRunnable(&counts, limits).?;
    try testing.expect(next.eql(ids[3]));
    try testing.expect(q.remove(ids[0]));
    try testing.expect(!q.remove(ids[0]));
}
