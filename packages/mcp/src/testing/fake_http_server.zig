//! A loopback HTTP server for transport tests. Each connection is served on
//! its own concurrent task, so tests can hold a stream open while other
//! requests proceed. Every request is recorded (method, target, headers,
//! body) before `handler` answers it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One recorded request.
pub const Recorded = struct {
    method: std.http.Method,
    target: []const u8,
    headers: []const std.http.Header,
    body: []const u8,

    /// The first value of header `name` (case-insensitive).
    pub fn header(r: Recorded, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

/// Answers one request: `req` is the live std request, `rec` its record.
pub const Handler = *const fn (srv: *FakeHttpServer, req: *std.http.Server.Request, rec: Recorded) anyerror!void;

/// The server.
pub const FakeHttpServer = struct {
    gpa: Allocator,
    io: Io,
    server: Io.net.Server = undefined,
    port: u16 = 0,
    handler: Handler,
    ctx: ?*anyopaque = null,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    requests: std.ArrayList(Recorded) = .empty,
    /// Connections closed by the peer while a handler was writing.
    disconnects: std.atomic.Value(u32) = .init(0),
    conns: Io.Group = .init,
    accept_future: Io.Future(void) = undefined,

    /// Starts listening on 127.0.0.1 with an ephemeral port.
    pub fn start(self: *FakeHttpServer) !void {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try addr.listen(self.io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.accept_future = try self.io.concurrent(acceptLoop, .{self});
    }

    /// Creates a server (call `start`).
    pub fn init(gpa: Allocator, io: Io, handler: Handler) FakeHttpServer {
        return .{ .gpa = gpa, .io = io, .handler = handler, .arena = .init(gpa) };
    }

    /// Stops accepting, cancels every connection and frees the records.
    pub fn deinit(self: *FakeHttpServer) void {
        self.accept_future.cancel(self.io);
        self.conns.cancel(self.io);
        self.server.deinit(self.io);
        self.requests.deinit(self.gpa);
        self.arena.deinit();
    }

    /// `http://127.0.0.1:<port><path>` in `buf`.
    pub fn url(self: *FakeHttpServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }

    /// A copy of record `i` (valid until `deinit`).
    pub fn request(self: *FakeHttpServer, i: usize) ?Recorded {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (i < self.requests.items.len) self.requests.items[i] else null;
    }

    /// Number of requests received so far.
    pub fn count(self: *FakeHttpServer) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.requests.items.len;
    }

    fn acceptLoop(self: *FakeHttpServer) void {
        while (true) {
            const conn = self.server.accept(self.io) catch return;
            self.conns.concurrent(self.io, serve, .{ self, conn }) catch {
                conn.close(self.io);
                return;
            };
        }
    }

    fn serve(self: *FakeHttpServer, conn: Io.net.Stream) void {
        defer conn.close(self.io);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var sr = conn.reader(self.io, &rbuf);
        var sw = conn.writer(self.io, &wbuf);
        var http: std.http.Server = .init(&sr.interface, &sw.interface);
        while (true) {
            var req = http.receiveHead() catch return;
            const rec = self.record(&req) catch return;
            self.handler(self, &req, rec) catch {
                _ = self.disconnects.fetchAdd(1, .monotonic);
                return;
            };
        }
    }

    fn record(self: *FakeHttpServer, req: *std.http.Server.Request) !Recorded {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const a = self.arena.allocator();
        var hs: std.ArrayList(std.http.Header) = .empty;
        var it = req.iterateHeaders();
        while (it.next()) |h| try hs.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
        const target = try a.dupe(u8, req.head.target);
        const method = req.head.method;
        var body: []const u8 = "";
        if (req.head.content_length != null or req.head.transfer_encoding == .chunked) {
            var bb: [4096]u8 = undefined;
            const rd = try req.readerExpectContinue(&bb);
            body = try rd.allocRemaining(a, .limited(1 << 20));
        }
        const rec: Recorded = .{ .method = method, .target = target, .headers = hs.items, .body = body };
        try self.requests.append(self.gpa, rec);
        return rec;
    }
};

/// Writes an SSE stream response head and returns its body writer.
pub fn startSse(req: *std.http.Server.Request, buf: []u8) !std.http.BodyWriter {
    return req.respondStreaming(buf, .{ .respond_options = .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
    } });
}

/// Writes one SSE `message` event and flushes it to the peer.
pub fn sseEvent(bw: *std.http.BodyWriter, data: []const u8) !void {
    try bw.writer.print("event: message\ndata: {s}\n\n", .{data});
    try bw.writer.flush();
    try bw.flush();
}

/// Responds with a JSON body and `status`.
pub fn respondJson(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    return req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}
