const std = @import("std");
const progress = @import("progress.zig");
const protocol = @import("../gen/protocol.zig");
const testing = std.testing;

const Events = struct {
    seen: std.ArrayList(u8) = .empty,
    partial: std.ArrayList(u8) = .empty,
    canceled: usize = 0,

    fn deinit(e: *Events) void {
        e.seen.deinit(testing.allocator);
        e.partial.deinit(testing.allocator);
    }

    fn listener(e: *Events) progress.ProgressListener {
        return .{ .ctx = e, .func = onEvent };
    }

    fn onEvent(ctx: ?*anyopaque, ev: progress.ProgressEvent) void {
        const e: *Events = @ptrCast(@alignCast(ctx.?));
        e.seen.print(testing.allocator, "{d} {t} {s} {?s} {?d}\n", .{ ev.server, ev.kind, ev.title orelse "-", ev.message, ev.percentage }) catch @panic("oom");
    }

    fn sink(e: *Events) progress.PartialSink {
        return .{ .ctx = e, .func = onPartial };
    }

    fn onPartial(ctx: ?*anyopaque, json: []const u8) void {
        const e: *Events = @ptrCast(@alignCast(ctx.?));
        e.partial.print(testing.allocator, "{s}\n", .{json}) catch @panic("oom");
    }

    fn canceler(e: *Events) progress.Canceler {
        return .{ .ctx = e, .func = onCancel };
    }

    fn onCancel(ctx: ?*anyopaque, _: protocol.ProgressToken) void {
        const e: *Events = @ptrCast(@alignCast(ctx.?));
        e.canceled += 1;
    }
};

fn send(t: *progress.ProgressTracker, server: u32, json: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    t.onProgress(server, json, arena.allocator());
}

test "progress: begin/report/end routing, partial-result forwarding, cancel" {
    var t: progress.ProgressTracker = .init(testing.allocator, testing.io);
    defer t.deinit();
    t.min_interval = .fromSeconds(3600);
    var ev: Events = .{};
    defer ev.deinit();
    try t.subscribe(ev.listener());
    try t.addServer(1, ev.canceler());
    try t.addServer(2, null);

    // Unknown tokens are dropped.
    send(&t, 1, "{\"token\": \"nope\", \"value\": {\"kind\": \"begin\", \"title\": \"x\"}}");
    try testing.expectEqual(@as(usize, 0), ev.seen.items.len);

    try t.create(1, .{ .integer = 5 });
    send(&t, 1, "{\"token\": 5, \"value\": {\"kind\": \"begin\", \"title\": \"Indexing\", \"cancellable\": true, \"percentage\": 0}}");
    try testing.expectEqual(@as(u32, 1), t.activeCount(1));
    try testing.expectEqual(@as(u32, 0), t.activeCount(2));
    // Reports within the interval are coalesced away.
    send(&t, 1, "{\"token\": 5, \"value\": {\"kind\": \"report\", \"message\": \"a.zig\", \"percentage\": 50}}");
    t.cancel(1, .{ .integer = 5 });
    try testing.expectEqual(@as(usize, 1), ev.canceled);
    send(&t, 1, "{\"token\": 5, \"value\": {\"kind\": \"end\", \"message\": \"done\"}}");
    try testing.expectEqual(@as(u32, 0), t.activeCount(1));
    // An ended server token is gone.
    send(&t, 1, "{\"token\": 5, \"value\": {\"kind\": \"begin\", \"title\": \"again\"}}");
    t.cancel(1, .{ .integer = 5 });
    try testing.expectEqual(@as(usize, 1), ev.canceled);

    // Reports pass once the interval allows.
    t.min_interval = .fromNanoseconds(0);
    var buf: [32]u8 = undefined;
    const tok = try t.issue(2, &buf);
    var jbuf: [128]u8 = undefined;
    send(&t, 2, try std.fmt.bufPrint(&jbuf, "{{\"token\": \"{s}\", \"value\": {{\"kind\": \"begin\", \"title\": \"Build\"}}}}", .{tok.string}));
    send(&t, 2, try std.fmt.bufPrint(&jbuf, "{{\"token\": \"{s}\", \"value\": {{\"kind\": \"report\", \"percentage\": 150}}}}", .{tok.string}));
    // Not cancellable: no cancel is sent (and server 2 has no canceler).
    t.cancel(2, tok);
    try testing.expectEqual(@as(usize, 1), ev.canceled);
    // Releasing an active issued token ends it.
    t.release(2, tok);
    try testing.expectEqual(@as(u32, 0), t.activeCount(2));

    // Partial results go to the sink, not the listeners.
    const ptok = try t.issue(1, &buf);
    try t.addPartial(1, ptok, ev.sink());
    send(&t, 1, try std.fmt.bufPrint(&jbuf, "{{\"token\": \"{s}\", \"value\": [{{\"uri\": \"file:///a\"}}]}}", .{ptok.string}));
    t.release(1, ptok);
    send(&t, 1, try std.fmt.bufPrint(&jbuf, "{{\"token\": \"{s}\", \"value\": [2]}}", .{ptok.string}));

    try testing.expectEqualStrings(
        \\1 begin Indexing null 0
        \\1 end Indexing done null
        \\2 begin Build null null
        \\2 report Build null 100
        \\2 end Build null null
        \\
    , ev.seen.items);
    try testing.expectEqualStrings("[{\"uri\":\"file:///a\"}]\n", ev.partial.items);
}

test "progress: removing a server ends its progress" {
    var t: progress.ProgressTracker = .init(testing.allocator, testing.io);
    defer t.deinit();
    var ev: Events = .{};
    defer ev.deinit();
    try t.subscribe(ev.listener());
    try t.addServer(3, null);
    try t.create(3, .{ .string = "s" });
    try t.create(3, .{ .integer = 1 });
    send(&t, 3, "{\"token\": \"s\", \"value\": {\"kind\": \"begin\", \"title\": \"Load\"}}");
    var buf: [32]u8 = undefined;
    try t.addPartial(3, try t.issue(3, &buf), ev.sink());
    t.removeServer(3);
    try testing.expectEqual(@as(u32, 0), t.activeCount(3));
    try testing.expectEqualStrings("3 begin Load null null\n3 end Load null null\n", ev.seen.items);
}
