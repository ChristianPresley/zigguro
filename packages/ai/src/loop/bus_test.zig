const std = @import("std");
const zg_core = @import("zg_core");
const busm = @import("bus.zig");
const ev = @import("events.zig");

const testing = std.testing;
const io = testing.io;
const Envelope = ev.Envelope;

/// Collects sequence numbers (and merged delta texts) from a subscriber.
const Sink = struct {
    mutex: std.Io.Mutex = .init,
    seqs: std.ArrayList(u64) = .empty,
    text: std.ArrayList(u8) = .empty,
    structural: u32 = 0,
    sleep_ms: u32 = 0,
    batches: u32 = 0,

    fn deinit(s: *Sink) void {
        s.seqs.deinit(testing.allocator);
        s.text.deinit(testing.allocator);
    }

    fn sub(s: *Sink, mode: @FieldType(busm.Subscriber, "mode"), cap: u32) busm.Subscriber {
        return .{ .ctx = s, .on_events = on, .mode = mode, .capacity = cap };
    }

    fn on(ctx: *anyopaque, batch: []const Envelope) void {
        const s: *Sink = @ptrCast(@alignCast(ctx));
        if (s.sleep_ms > 0) io.sleep(.fromMilliseconds(s.sleep_ms), .awake) catch {};
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.batches += 1;
        for (batch) |e| {
            s.seqs.append(testing.allocator, e.seq) catch {};
            if (e.ev.isDelta()) s.text.appendSlice(testing.allocator, e.ev.stream.text_delta.text) catch {} else s.structural += 1;
        }
    }
};

test "order_preserved_many_subscribers" {
    var bus = busm.Bus.init(testing.allocator, io);
    var sinks: [4]Sink = .{ .{}, .{}, .{}, .{} };
    defer for (&sinks) |*s| s.deinit();
    _ = try bus.subscribe(sinks[0].sub(.inline_, 0));
    for (sinks[1..]) |*s| _ = try bus.subscribe(s.sub(.queued, 16));
    for (0..1000) |i| bus.publish(.{ .turn_started = @intCast(i) });
    bus.deinit();
    for (sinks) |s| {
        try testing.expectEqual(@as(usize, 1000), s.seqs.items.len);
        for (s.seqs.items, 1..) |q, want| try testing.expectEqual(@as(u64, want), q);
    }
}

test "slow_subscriber_isolated" {
    var bus = busm.Bus.init(testing.allocator, io);
    var slow: Sink = .{ .sleep_ms = 50 };
    defer slow.deinit();
    var fast: Sink = .{};
    defer fast.deinit();
    _ = try bus.subscribe(slow.sub(.queued, 4096));
    _ = try bus.subscribe(fast.sub(.queued, 4096));
    const t0 = std.Io.Timestamp.now(io, .awake);
    for (0..100) |i| bus.publish(.{ .turn_started = @intCast(i) });
    // The fast subscriber sees everything long before the slow one wakes.
    while (true) {
        fast.mutex.lockUncancelable(io);
        const n = fast.seqs.items.len;
        fast.mutex.unlock(io);
        if (n == 100) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 40);
    bus.deinit();
    try testing.expectEqual(@as(usize, 100), slow.seqs.items.len);
}

test "coalesce_text_never_structural" {
    var bus = busm.Bus.init(testing.allocator, io);
    var s: Sink = .{ .sleep_ms = 20 };
    defer s.deinit();
    _ = try bus.subscribe(s.sub(.queued, 8));
    // One contiguous buffer sliced into deltas, as the transcript arena does.
    const text = "abcdefghijklmnopqrstuvwxyz" ** 4;
    bus.publish(.{ .turn_started = 1 });
    for (0..text.len) |i| {
        bus.publish(.{ .stream = .{ .text_delta = .{ .index = 0, .text = text[i .. i + 1] } } });
        if (i % 26 == 25) bus.publish(.{ .stream = .{ .block_stop = .{ .index = 0 } } });
    }
    bus.publish(.{ .turn_finished = .{ .turn = 1, .reason = .end_turn } });
    bus.deinit();
    try testing.expectEqualStrings(text, s.text.items);
    try testing.expectEqual(@as(u32, 6), s.structural);
    // Deltas were merged: fewer events than published.
    try testing.expect(s.seqs.items.len < text.len + 6);
}

test "unsubscribe_during_publish_safe" {
    var bus = busm.Bus.init(testing.allocator, io);
    defer bus.deinit();
    var a: Sink = .{};
    defer a.deinit();
    const id = try bus.subscribe(a.sub(.queued, 64));
    var fut = try io.concurrent(struct {
        fn f(b: *busm.Bus) void {
            for (0..5000) |i| b.publish(.{ .turn_started = @intCast(i) });
        }
    }.f, .{&bus});
    try io.sleep(.fromMilliseconds(1), .awake);
    bus.unsubscribe(id);
    fut.await(io);
    // Whatever arrived is a gapless prefix.
    for (a.seqs.items, 1..) |q, want| try testing.expectEqual(@as(u64, want), q);
}

test "ui_bridge_one_post_per_frame" {
    const Post = struct {
        n: std.atomic.Value(u32) = .init(0),
        fn post(ctx: *anyopaque, _: zg_core.runtime.UiMsg) zg_core.runtime.Runtime.PostError!void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            _ = p.n.fetchAdd(1, .monotonic);
        }
    };
    var p: Post = .{};
    var ui = busm.UiBridge.init(testing.allocator, io, .{ .ctx = &p, .post = Post.post }, .{ .kind = 7 });
    defer ui.deinit();
    var bus = busm.Bus.init(testing.allocator, io);
    defer bus.deinit();
    _ = try bus.subscribe(ui.subscriber());
    for (0..1000) |_| bus.publish(.{ .stream = .{ .text_delta = .{ .index = 0, .text = "x" } } });
    try testing.expectEqual(@as(u32, 1), p.n.load(.monotonic));
    var out: std.ArrayList(Envelope) = .empty;
    defer out.deinit(testing.allocator);
    try ui.drain(testing.allocator, &out);
    try testing.expectEqual(@as(usize, 1000), out.items.len);
    bus.publish(.{ .status = .idle });
    try testing.expectEqual(@as(u32, 2), p.n.load(.monotonic));
}

test "no allocation per published event" {
    var s: Sink = .{};
    defer s.deinit();
    var counting = zg_core.alloc.CountingAllocator.init(testing.allocator);
    var bus = busm.Bus.init(counting.allocator(), io);
    defer bus.deinit();
    _ = try bus.subscribe(s.sub(.queued, 4096));
    _ = try bus.subscribe(s.sub(.inline_, 0));
    const before = counting.allocs.load(.monotonic);
    for (0..1000) |i| bus.publish(.{ .turn_started = @intCast(i) });
    try testing.expectEqual(before, counting.allocs.load(.monotonic));
}
