const std = @import("std");
const engine_mod = @import("engine.zig");
const providers = @import("providers.zig");
const context = @import("context.zig");
const scheduler = @import("scheduler.zig");

const testing = std.testing;
const Io = std.Io;
const gpa = testing.allocator;
const ms = std.time.ns_per_ms;

/// A provider that streams `chunks`, optionally waiting on `gate` after
/// the first one.
const FakeProvider = struct {
    chunks: []const []const u8 = &.{},
    gate: ?*Io.Event = null,
    fail: ?anyerror = null,
    calls: std.atomic.Value(u32) = .init(0),
    canceled: std.atomic.Value(bool) = .init(false),
    last_prefix: [64]u8 = undefined,
    last_prefix_len: usize = 0,

    fn provider(p: *FakeProvider) providers.FimProvider {
        return .{ .ctx = p, .vtable = &.{ .complete = complete }, .caps = .{ .server_side_template = true } };
    }

    fn complete(ctx: *anyopaque, io: Io, _: std.mem.Allocator, req: *const context.CompletionRequest, sink: providers.Sink) anyerror!void {
        const p: *FakeProvider = @ptrCast(@alignCast(ctx));
        _ = p.calls.fetchAdd(1, .monotonic);
        const tail = req.prefix[req.prefix.len -| p.last_prefix.len..];
        @memcpy(p.last_prefix[0..tail.len], tail);
        p.last_prefix_len = tail.len;
        if (p.fail) |e| return e;
        for (p.chunks, 0..) |c, i| {
            try sink.text(sink.ctx, c);
            if (i == 0) if (p.gate) |g| g.wait(io) catch |err| {
                p.canceled.store(true, .release);
                return err;
            };
        }
    }
};

const Got = struct {
    text: []u8,
    hide: u32,
    final: bool,
    from_cache: bool,
};

const FakeHost = struct {
    io: Io,
    text: []const u8 = "fn f() u32 {\n    re\n}\n",
    cursor: usize = 19,
    version: u64 = 1,
    mutex: Io.Mutex = .init,
    queue: std.ArrayList(*anyopaque) = .empty,
    posted: Io.Event = .unset,
    got: std.ArrayList(Got) = .empty,
    failures: u32 = 0,

    fn host(h: *FakeHost) engine_mod.Host {
        return .{ .ctx = h, .snapshot = snapshot, .post = post, .deliver = deliver, .failed = failed };
    }

    fn snapshot(ctx: *anyopaque, _: u64, arena: std.mem.Allocator) anyerror!?engine_mod.Snapshot {
        const h: *FakeHost = @ptrCast(@alignCast(ctx));
        return .{
            .text = try arena.dupe(u8, h.text),
            .cursor = h.cursor,
            .version = h.version,
            .options = .{ .path = "a.zig", .language = "zig" },
        };
    }

    fn post(ctx: *anyopaque, arg: *anyopaque) void {
        const h: *FakeHost = @ptrCast(@alignCast(ctx));
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.queue.append(gpa, arg) catch unreachable;
        h.posted.set(h.io);
    }

    fn deliver(ctx: *anyopaque, d: engine_mod.Delivery) void {
        const h: *FakeHost = @ptrCast(@alignCast(ctx));
        h.got.append(gpa, .{ .text = gpa.dupe(u8, d.text) catch unreachable, .hide = d.hide, .final = d.final, .from_cache = d.from_cache }) catch unreachable;
    }

    fn failed(ctx: *anyopaque, _: anyerror) void {
        const h: *FakeHost = @ptrCast(@alignCast(ctx));
        h.failures += 1;
    }

    /// Runs the posted drains, waiting for at least one.
    fn pump(h: *FakeHost) !void {
        try h.posted.waitTimeout(h.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        while (true) {
            h.mutex.lockUncancelable(h.io);
            h.posted.reset();
            const item = if (h.queue.items.len > 0) h.queue.orderedRemove(0) else null;
            h.mutex.unlock(h.io);
            const it = item orelse return;
            engine_mod.CompletionEngine.runPosted(it);
        }
    }

    /// Pumps until a final delivery arrives after the first `after`.
    fn pumpFinal(h: *FakeHost, after: usize) !void {
        while (h.got.items.len <= after or !h.got.items[h.got.items.len - 1].final) try h.pump();
    }

    fn last(h: *const FakeHost) Got {
        return h.got.items[h.got.items.len - 1];
    }

    fn deinit(h: *FakeHost) void {
        for (h.got.items) |g| gpa.free(g.text);
        h.got.deinit(gpa);
        h.queue.deinit(gpa);
    }
};

fn key(v: u64) scheduler.Edit {
    return .{ .origin = .user, .inserted = 1, .version = v };
}

test "engine: debounced request streams, then a cache hit paints without a request" {
    var fp: FakeProvider = .{ .chunks = &.{ "tu", "rn 1;" } };
    var h: FakeHost = .{ .io = testing.io };
    defer h.deinit();
    var e: engine_mod.CompletionEngine = .init(gpa, testing.io, fp.provider(), h.host(), .{}, 7);
    defer e.deinit();
    try e.open(1, 0);

    e.onEdit(1, key(1), 0);
    try e.tick(59 * ms);
    try testing.expectEqual(@as(usize, 0), e.running());
    try e.tick(60 * ms);
    try h.pumpFinal(0);
    try testing.expectEqualStrings("turn 1;", h.last().text);
    try testing.expect(!h.last().from_cache);
    try testing.expectEqualStrings("    re", fp.last_prefix[fp.last_prefix_len - 6 .. fp.last_prefix_len]);
    try testing.expectEqual(@as(usize, 0), e.running());

    // Same spot again: from the cache, no provider call.
    e.invoke(1, 100 * ms);
    try e.tick(100 * ms);
    try testing.expect(h.last().from_cache);
    try testing.expectEqualStrings("turn 1;", h.last().text);
    try testing.expectEqual(@as(u32, 1), fp.calls.load(.monotonic));

    // A non-typing edit drops the document's cache.
    e.onEdit(1, .{ .origin = .agent, .inserted = 10, .version = 1 }, 200 * ms);
    e.invoke(1, 300 * ms);
    const before = h.got.items.len;
    try e.tick(300 * ms);
    try h.pumpFinal(before);
    try testing.expect(!h.last().from_cache);
    try testing.expectEqual(@as(u32, 2), fp.calls.load(.monotonic));
}

test "engine: a consistent keystroke keeps the request and hides the typed bytes" {
    var gate: Io.Event = .unset;
    var fp: FakeProvider = .{ .chunks = &.{ "turn", " 1;" }, .gate = &gate };
    var h: FakeHost = .{ .io = testing.io, .version = 0 };
    defer h.deinit();
    var e: engine_mod.CompletionEngine = .init(gpa, testing.io, fp.provider(), h.host(), .{}, 7);
    defer e.deinit();
    try e.open(1, 0);
    e.invoke(1, 0);
    try e.tick(0);
    try h.pump();
    try testing.expectEqualStrings("turn", h.last().text);

    e.typed(1, "t");
    try testing.expectEqual(@as(u32, 1), h.last().hide);
    try testing.expect(!h.last().final);
    gate.set(testing.io);
    try h.pumpFinal(h.got.items.len);
    try testing.expectEqualStrings("turn 1;", h.last().text);
    try testing.expectEqual(@as(u32, 1), h.last().hide);
}

test "engine: an inconsistent keystroke cancels; nothing more is delivered" {
    var gate: Io.Event = .unset;
    var fp: FakeProvider = .{ .chunks = &.{ "turn", " 1;" }, .gate = &gate };
    var h: FakeHost = .{ .io = testing.io, .version = 0 };
    defer h.deinit();
    var e: engine_mod.CompletionEngine = .init(gpa, testing.io, fp.provider(), h.host(), .{}, 7);
    defer e.deinit();
    try e.open(1, 0);
    e.invoke(1, 0);
    try e.tick(0);
    try h.pump();
    const n = h.got.items.len;

    e.typed(1, "x");
    try testing.expectEqual(@as(usize, 0), e.running());
    try testing.expect(fp.canceled.load(.acquire));
    try testing.expectEqual(n, h.got.items.len);

    // An undo cancels too.
    gate.reset();
    e.invoke(1, 0);
    try e.tick(0);
    try h.pump();
    e.onEdit(1, .{ .origin = .undo, .inserted = 0, .version = 0 }, 1);
    try testing.expectEqual(@as(usize, 0), e.running());
}

test "engine: a stale snapshot starts nothing; failures reach the host" {
    var fp: FakeProvider = .{ .fail = error.BadStatus };
    var h: FakeHost = .{ .io = testing.io, .version = 5 };
    defer h.deinit();
    var e: engine_mod.CompletionEngine = .init(gpa, testing.io, fp.provider(), h.host(), .{}, 7);
    defer e.deinit();
    try e.open(1, 0);
    // The document moved on (version 5) before the trigger (version 1).
    e.onEdit(1, key(1), 0);
    try e.tick(1000 * ms);
    try testing.expectEqual(@as(u32, 0), fp.calls.load(.monotonic));

    e.onEdit(1, key(5), 2000 * ms);
    try e.tick(3000 * ms);
    try h.pump();
    try testing.expectEqual(@as(u32, 1), h.failures);
    try testing.expectEqual(@as(usize, 0), h.got.items.len);
    try testing.expectEqual(@as(usize, 0), e.running());
}
