const std = @import("std");
const proto = @import("zg_ai_proto");
const rl = @import("ratelimit.zig");
const guard = @import("guarded.zig");
const retry = @import("retry.zig");
const Provider = @import("Provider.zig");
const events = @import("events.zig");
const request = @import("request.zig");
const scripted = @import("scripted.zig");
const MessageAssembler = @import("assembler.zig").MessageAssembler;

const testing = std.testing;
const io = testing.io;
const Step = scripted.ScriptedProvider.Step;

const lane: rl.Lane = .{ .provider = "anthropic", .model_class = "m" };

test "limiter_waits_until_reset" {
    var fc = rl.FakeClock.init(1_000_000);
    var l = rl.RateLimiter.init(testing.allocator, fc.clock());
    defer l.deinit();
    // No snapshot: permissive.
    (try l.acquire(io, lane, 100)).release(io);
    try testing.expectEqual(@as(u32, 0), fc.sleeps.load(.monotonic));
    l.update(io, lane, .{ .requests_limit = 50, .requests_remaining = 0, .reset_at_ms = 1_005_000 });
    const p = try l.acquire(io, lane, 100);
    p.release(io);
    try testing.expectEqual(@as(u64, 5_000), fc.slept_ms.load(.monotonic));
    try testing.expectEqual(@as(i64, 1_005_000), fc.now_ms.load(.monotonic));
    // The window reset to the limit: 49 more start without waiting.
    for (0..49) |_| (try l.acquire(io, lane, 0)).release(io);
    try testing.expectEqual(@as(u32, 1), fc.sleeps.load(.monotonic));
    // Other lanes are independent.
    (try l.acquire(io, .{ .provider = "anthropic", .model_class = "other" }, 0)).release(io);
    try testing.expectEqual(@as(u32, 1), fc.sleeps.load(.monotonic));
}

test "limiter token headroom and retry-after" {
    var fc = rl.FakeClock.init(0);
    var l = rl.RateLimiter.init(testing.allocator, fc.clock());
    defer l.deinit();
    l.update(io, lane, .{ .input_tokens_remaining = 1_000, .reset_at_ms = 60_000 });
    (try l.acquire(io, lane, 800)).release(io);
    try testing.expectEqual(@as(u32, 0), fc.sleeps.load(.monotonic));
    // 200 left: an 800-token call waits for the reset.
    (try l.acquire(io, lane, 800)).release(io);
    try testing.expectEqual(@as(i64, 60_000), fc.now_ms.load(.monotonic));
    // A stale snapshot from the old window can't raise headroom.
    l.update(io, lane, .{ .requests_remaining = 7, .reset_at_ms = 50_000 });
    l.update(io, lane, .{ .retry_after_ms = 3_000 });
    (try l.acquire(io, lane, 0)).release(io);
    try testing.expectEqual(@as(i64, 63_000), fc.now_ms.load(.monotonic));
}

test "concurrency cap" {
    var l = rl.RateLimiter.init(testing.allocator, .real);
    defer l.deinit();
    try l.setMaxConcurrent(io, "ollama", 1);
    const p1 = try l.acquire(io, .{ .provider = "ollama" }, 0);
    var fut = try io.concurrent(struct {
        fn f(lim: *rl.RateLimiter) !void {
            (try lim.acquire(io, .{ .provider = "ollama" }, 0)).release(io);
        }
    }.f, .{&l});
    try io.sleep(.fromMilliseconds(20), .awake);
    // Still blocked behind p1.
    l.mutex.lockUncancelable(io);
    const in_flight = l.providers.get("ollama").?.in_flight;
    l.mutex.unlock(io);
    try testing.expectEqual(@as(u32, 1), in_flight);
    p1.release(io);
    try fut.await(io);
}

test "cancel while queued" {
    var l = rl.RateLimiter.init(testing.allocator, .real);
    defer l.deinit();
    try l.setMaxConcurrent(io, "x", 1);
    const p1 = try l.acquire(io, .{ .provider = "x" }, 0);
    var fut = try io.concurrent(struct {
        fn f(lim: *rl.RateLimiter) !void {
            (try lim.acquire(io, .{ .provider = "x" }, 0)).release(io);
        }
    }.f, .{&l});
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, fut.cancel(io));
    p1.release(io);
    // The canceled waiter left the queue: the lane still works.
    (try l.acquire(io, .{ .provider = "x" }, 0)).release(io);
}

fn collect(list: *std.ArrayList(events.StreamEvent)) events.EventSink {
    return .{ .ctx = list, .emit = struct {
        fn f(ctx: *anyopaque, ev: events.StreamEvent) void {
            const l: *std.ArrayList(events.StreamEvent) = @ptrCast(@alignCast(ctx));
            l.append(testing.allocator, ev) catch {};
        }
    }.f };
}

const overloaded = [_]Step{
    .{ .event = .{ .message_start = .{ .id = "a", .model = "m" } } },
    .{ .event = .{ .provider_error = .{ .status = 529, .kind = "overloaded_error", .message = "busy" } } },
    .{ .fail = error.Overloaded },
};

test "retries then succeeds; sink sees one attempt" {
    var fc = rl.FakeClock.init(0);
    var l = rl.RateLimiter.init(testing.allocator, fc.clock());
    defer l.deinit();
    const turns = [_][]const Step{ &overloaded, &overloaded, scripted.script.text("ok") };
    const sp = try scripted.ScriptedProvider.init(testing.allocator, &turns, .all);
    const Count = struct {
        n: u32 = 0,
        fn f(ctx: *anyopaque, r: guard.Retrying) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.n += 1;
            std.debug.assert(r.status == 529);
        }
    };
    var count: Count = .{};
    const p = try guard.guarded(testing.allocator, sp.provider(), &l, .{ .instance = "anthropic", .clock = fc.clock(), .seed = 9, .listener = .{ .ctx = &count, .on_retry = Count.f } });
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var evs: std.ArrayList(events.StreamEvent) = .empty;
    defer evs.deinit(testing.allocator);
    const req: request.Request = .{ .model = "m", .messages = &.{} };
    const resp = try p.stream(io, arena.allocator(), &req, collect(&evs));
    try testing.expectEqual(@as(u32, 2), count.n);
    try testing.expectEqual(@as(usize, 3), sp.requests().len);
    // The fold of the forwarded events equals the response.
    var asm_: MessageAssembler = .init(arena.allocator());
    for (evs.items) |ev| try asm_.feed(ev);
    const msg = try asm_.finish();
    try testing.expectEqualStrings("ok", msg.content[0].text.text);
    try testing.expectEqualStrings(resp.message.content[0].text.text, msg.content[0].text.text);
    for (evs.items) |ev| try testing.expect(ev != .provider_error);
}

test "gives up after max attempts and forwards the error" {
    var fc = rl.FakeClock.init(0);
    var l = rl.RateLimiter.init(testing.allocator, fc.clock());
    defer l.deinit();
    const turns = [_][]const Step{ &overloaded, &overloaded };
    const sp = try scripted.ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = try guard.guarded(testing.allocator, sp.provider(), &l, .{ .instance = "a", .clock = fc.clock(), .seed = 1, .policy = .{ .max_attempts = 2 } });
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var evs: std.ArrayList(events.StreamEvent) = .empty;
    defer evs.deinit(testing.allocator);
    const req: request.Request = .{ .model = "m", .messages = &.{} };
    try testing.expectError(error.Overloaded, p.stream(io, arena.allocator(), &req, collect(&evs)));
    try testing.expectEqual(@as(usize, 2), sp.requests().len);
    try testing.expectEqual(@as(usize, 2), evs.items.len);
    try testing.expect(evs.items[0] == .message_start);
    try testing.expectEqual(@as(u16, 529), evs.items[1].provider_error.status);
}

test "mid_stream_error_not_retried_after_content" {
    var fc = rl.FakeClock.init(0);
    var l = rl.RateLimiter.init(testing.allocator, fc.clock());
    defer l.deinit();
    const partial = [_]Step{
        .{ .event = .{ .message_start = .{ .id = "a", .model = "m" } } },
        .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } },
        .{ .event = .{ .text_delta = .{ .index = 0, .text = "half" } } },
        .{ .fail = error.Network },
    };
    const turns = [_][]const Step{ &partial, scripted.script.text("never") };
    const sp = try scripted.ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = try guard.guarded(testing.allocator, sp.provider(), &l, .{ .instance = "a", .clock = fc.clock(), .seed = 1 });
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var evs: std.ArrayList(events.StreamEvent) = .empty;
    defer evs.deinit(testing.allocator);
    const req: request.Request = .{ .model = "m", .messages = &.{} };
    try testing.expectError(error.Network, p.stream(io, arena.allocator(), &req, collect(&evs)));
    try testing.expectEqual(@as(usize, 1), sp.requests().len);
    try testing.expectEqual(@as(usize, 3), evs.items.len);
}

test "auth errors are not retried" {
    var fc = rl.FakeClock.init(0);
    var l = rl.RateLimiter.init(testing.allocator, fc.clock());
    defer l.deinit();
    const bad = [_]Step{ .{ .event = .{ .provider_error = .{ .status = 401, .kind = "authentication_error" } } }, .{ .fail = error.Auth } };
    const turns = [_][]const Step{&bad};
    const sp = try scripted.ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = try guard.guarded(testing.allocator, sp.provider(), &l, .{ .instance = "a", .clock = fc.clock(), .seed = 1 });
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: request.Request = .{ .model = "m", .messages = &.{} };
    try testing.expectError(error.Auth, p.stream(io, arena.allocator(), &req, .discard));
    try testing.expectEqual(@as(u32, 0), fc.sleeps.load(.monotonic));
}

test "cancel_during_backoff_fast" {
    var l = rl.RateLimiter.init(testing.allocator, .real);
    defer l.deinit();
    const slow = [_]Step{ .{ .event = .{ .provider_error = .{ .status = 429, .kind = "rate_limit_error", .retry_after_ms = 10_000 } } }, .{ .fail = error.RateLimited } };
    const turns = [_][]const Step{ &slow, &slow };
    const sp = try scripted.ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = try guard.guarded(testing.allocator, sp.provider(), &l, .{ .instance = "a", .seed = 1 });
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: request.Request = .{ .model = "m", .messages = &.{} };
    var fut = try io.concurrent(Provider.stream, .{ p, io, arena.allocator(), &req, events.EventSink.discard });
    try io.sleep(.fromMilliseconds(20), .awake);
    const start = std.Io.Timestamp.now(io, .awake);
    try testing.expectError(error.Canceled, fut.cancel(io));
    const took = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expect(took < 100);
    try testing.expectEqual(@as(usize, 1), sp.requests().len);
}

/// A provider that enforces a fixed-window RPM limit on a fake clock and
/// reports Anthropic-style headroom.
const BucketServer = struct {
    clock: *rl.FakeClock,
    mutex: std.Io.Mutex = .init,
    limit: u64,
    window_ms: i64 = 60_000,
    window_start: i64 = 0,
    used: u64 = 0,
    served: u32 = 0,
    rejected: u32 = 0,

    fn provider(s: *BucketServer) Provider {
        return .{ .ptr = s, .vtable = &.{ .stream = stream, .deinit = struct {
            fn f(_: *anyopaque) void {}
        }.f }, .id = .scripted, .caps = .all };
    }

    fn stream(ptr: *anyopaque, io_: std.Io, arena: std.mem.Allocator, req: *const request.Request, sink: events.EventSink) Provider.StreamError!request.Response {
        _ = req;
        const s: *BucketServer = @ptrCast(@alignCast(ptr));
        s.mutex.lockUncancelable(io_);
        const now = s.clock.now_ms.load(.acquire);
        while (now >= s.window_start + s.window_ms) {
            s.window_start += s.window_ms;
            s.used = 0;
        }
        const reset = s.window_start + s.window_ms;
        if (s.used >= s.limit) {
            s.rejected += 1;
            s.mutex.unlock(io_);
            sink.send(.{ .rate_limit = .{ .requests_limit = s.limit, .requests_remaining = 0, .reset_at_ms = reset, .retry_after_ms = @intCast(reset - now) } });
            sink.send(.{ .provider_error = .{ .status = 429, .kind = "rate_limit_error", .retry_after_ms = @intCast(reset - now) } });
            return error.RateLimited;
        }
        s.used += 1;
        s.served += 1;
        const remaining = s.limit - s.used;
        s.mutex.unlock(io_);
        sink.send(.{ .rate_limit = .{ .requests_limit = s.limit, .requests_remaining = remaining, .reset_at_ms = reset } });
        var a: MessageAssembler = .init(arena);
        const evs = [_]events.StreamEvent{
            .{ .message_start = .{ .id = "x", .model = "m" } },
            .{ .block_start = .{ .index = 0, .kind = .text } },
            .{ .text_delta = .{ .index = 0, .text = "ok" } },
            .{ .block_stop = .{ .index = 0 } },
            .{ .stop = .end_turn },
        };
        for (evs) |ev| {
            a.feed(ev) catch return error.Protocol;
            sink.send(ev);
        }
        return .{ .message = a.finish() catch return error.Protocol, .stop = .end_turn, .usage = .{} };
    }
};

test "ten_agents_no_429" {
    var fc = rl.FakeClock.init(0);
    var l = rl.RateLimiter.init(testing.allocator, fc.clock());
    defer l.deinit();
    var server: BucketServer = .{ .clock = &fc, .limit = 50 };
    const g = try guard.Guarded.create(testing.allocator, server.provider(), &l, .{ .instance = "anthropic", .clock = fc.clock(), .seed = 3 });
    const p = g.provider();
    defer p.deinit();
    const Agent = struct {
        fn run(prov: Provider) !void {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const req: request.Request = .{ .model = "m", .messages = &.{} };
            for (0..15) |_| _ = try prov.stream(io, arena.allocator(), &req, .discard);
        }
    };
    // Prime the lane with one call so the limiter knows the window.
    try Agent.run(p);
    var group: std.Io.Group = .init;
    for (0..10) |_| group.async(io, struct {
        fn f(prov: Provider) void {
            Agent.run(prov) catch |e| std.debug.panic("agent failed: {t}", .{e});
        }
    }.f, .{p});
    try group.await(io);
    try testing.expectEqual(@as(u32, 165), server.served);
    try testing.expectEqual(@as(u32, 0), server.rejected);
}
