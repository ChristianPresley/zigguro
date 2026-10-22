//! In-process fake HTTP server implementing `Transport`: serves canned
//! `(status, headers, body chunks)` per request matcher with optional
//! per-chunk delays, and records every request.

const std = @import("std");
const tp = @import("transport.zig");

const Allocator = std.mem.Allocator;

/// One canned response.
pub const Route = struct {
    /// Matches any method when null.
    method: ?tp.Method = null,
    /// Substring of the URL that selects this route ("" matches all).
    url_contains: []const u8 = "",
    status: u16 = 200,
    headers: []const tp.Header = &.{},
    body: []const u8 = "",
    /// Split the body into chunks of this size (0 = one chunk).
    chunk_size: usize = 0,
    chunk_delay_ms: u32 = 0,
    /// Serve at most once (later requests fall through to the next match).
    once: bool = false,
};

/// A request seen by the fake.
pub const Seen = struct { method: tp.Method, url: []const u8, headers: []const tp.Header, body: []const u8 };

/// The fake transport.
pub const FakeTransport = struct {
    arena: std.heap.ArenaAllocator,
    routes: []const Route,
    used: []bool,
    seen: std.ArrayList(Seen) = .empty,
    mutex: std.Io.Mutex = .init,

    /// A fake serving `routes` (borrowed).
    pub fn init(gpa: Allocator, routes: []const Route) !FakeTransport {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const used = try arena.allocator().alloc(bool, routes.len);
        @memset(used, false);
        return .{ .arena = arena, .routes = routes, .used = used };
    }

    /// Frees recorded requests.
    pub fn deinit(f: *FakeTransport) void {
        f.arena.deinit();
    }

    /// The `Transport` view.
    pub fn transport(f: *FakeTransport) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    /// Requests seen so far.
    pub fn requests(f: *const FakeTransport) []const Seen {
        return f.seen.items;
    }

    fn send(ptr: *anyopaque, io: std.Io, arena: Allocator, req: tp.HttpRequest, sink: tp.ChunkSink) tp.TransportError!tp.Head {
        const f: *FakeTransport = @ptrCast(@alignCast(ptr));
        const route = blk: {
            f.mutex.lock(io) catch return error.Canceled;
            defer f.mutex.unlock(io);
            const a = f.arena.allocator();
            const hs = a.alloc(tp.Header, req.headers.len) catch return error.OutOfMemory;
            for (req.headers, hs) |h, *o| o.* = .{ .name = a.dupe(u8, h.name) catch return error.OutOfMemory, .value = a.dupe(u8, h.value) catch return error.OutOfMemory };
            f.seen.append(a, .{
                .method = req.method,
                .url = a.dupe(u8, req.url) catch return error.OutOfMemory,
                .headers = hs,
                .body = a.dupe(u8, req.body) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
            for (f.routes, 0..) |r, i| {
                if (r.method) |m| if (m != req.method) continue;
                if (std.mem.indexOf(u8, req.url, r.url_contains) == null) continue;
                if (r.once and f.used[i]) continue;
                f.used[i] = true;
                break :blk r;
            }
            return error.Network;
        };
        var rest = route.body;
        const step = if (route.chunk_size == 0) @max(rest.len, 1) else route.chunk_size;
        while (rest.len > 0) {
            if (route.chunk_delay_ms > 0) io.sleep(.fromMilliseconds(route.chunk_delay_ms), .awake) catch return error.Canceled;
            io.checkCancel() catch return error.Canceled;
            const n = @min(step, rest.len);
            sink.on_chunk(sink.ctx, rest[0..n]) catch |e| return switch (e) {
                error.Canceled => error.Canceled,
                error.OutOfMemory => error.OutOfMemory,
                else => error.Aborted,
            };
            rest = rest[n..];
        }
        const hs = arena.dupe(tp.Header, route.headers) catch return error.OutOfMemory;
        return .{ .status = route.status, .headers = hs, .request_id = tp.requestIdFrom(hs) };
    }
};

test "fake_transport_serves_chunks_and_delays" {
    const routes = [_]Route{
        .{ .url_contains = "/once", .body = "first", .once = true },
        .{ .url_contains = "/once", .body = "second", .status = 500 },
        .{ .url_contains = "/chunks", .body = "abcdefg", .chunk_size = 3, .chunk_delay_ms = 1, .headers = &.{.{ .name = "request-id", .value = "req_1" }} },
    };
    var f: FakeTransport = try .init(std.testing.allocator, &routes);
    defer f.deinit();
    const t = f.transport();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Rec = struct {
        n: usize = 0,
        buf: [64]u8 = undefined,
        len: usize = 0,
        fn on(ctx: *anyopaque, b: []const u8) anyerror!void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.n += 1;
            @memcpy(r.buf[r.len..][0..b.len], b);
            r.len += b.len;
        }
    };
    var rec: Rec = .{};
    const h = try t.send(std.testing.io, arena.allocator(), .{ .url = "http://x/chunks", .body = "{}" }, .{ .ctx = &rec, .on_chunk = Rec.on });
    try std.testing.expectEqual(@as(usize, 3), rec.n);
    try std.testing.expectEqualStrings("abcdefg", rec.buf[0..rec.len]);
    try std.testing.expectEqualStrings("req_1", h.request_id.?);
    const a = try t.sendCollect(std.testing.io, arena.allocator(), .{ .url = "http://x/once" });
    const b = try t.sendCollect(std.testing.io, arena.allocator(), .{ .url = "http://x/once" });
    try std.testing.expectEqualStrings("first", a.body);
    try std.testing.expectEqual(@as(u16, 500), b.head.status);
    try std.testing.expectEqual(@as(usize, 3), f.requests().len);
    try std.testing.expectError(error.Network, t.sendCollect(std.testing.io, arena.allocator(), .{ .url = "http://x/none" }));
}
