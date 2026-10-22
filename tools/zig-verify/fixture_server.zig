//! A loopback HTTP server for the setup-zig fixture test: serves fixed
//! routes, answers 404 for anything else, and counts requests per route.

const std = @import("std");
const Io = std.Io;

pub const Route = struct {
    path: []const u8,
    status: std.http.Status = .ok,
    body: []const u8 = "",
    hits: std.atomic.Value(u32) = .init(0),
};

pub const FixtureServer = struct {
    server: Io.net.Server,
    port: u16,
    routes: []Route,
    future: Io.Future(Io.Cancelable!void) = undefined,

    pub fn start(self: *FixtureServer, io: Io) !void {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.future = try io.concurrent(run, .{ self, io });
    }

    pub fn stop(self: *FixtureServer, io: Io) void {
        self.future.cancel(io) catch {};
        self.server.deinit(io);
    }

    /// `http://127.0.0.1:<port><path>`.
    pub fn url(self: *const FixtureServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }

    pub fn hits(self: *const FixtureServer, path: []const u8) u32 {
        for (self.routes) |*r| if (std.mem.eql(u8, r.path, path)) return r.hits.load(.monotonic);
        return 0;
    }

    fn run(self: *FixtureServer, io: Io) Io.Cancelable!void {
        while (true) {
            const conn = self.server.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            defer conn.close(io);
            var rbuf: [8192]u8 = undefined;
            var wbuf: [64 * 1024]u8 = undefined;
            var sr = conn.reader(io, &rbuf);
            var sw = conn.writer(io, &wbuf);
            var http: std.http.Server = .init(&sr.interface, &sw.interface);
            var req = http.receiveHead() catch continue;
            const target = req.head.target;
            const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
            for (self.routes) |*r| {
                if (!std.mem.eql(u8, r.path, path)) continue;
                _ = r.hits.fetchAdd(1, .monotonic);
                req.respond(r.body, .{ .status = r.status, .keep_alive = false }) catch {};
                break;
            } else req.respond("not found", .{ .status = .not_found, .keep_alive = false }) catch {};
        }
    }
};
