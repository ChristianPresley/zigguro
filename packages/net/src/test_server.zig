//! A plain-HTTP loopback server for zg_net tests. Each request is handed to
//! `handler`; the server stops after `max` requests or when stopped.

const std = @import("std");
const Io = std.Io;

/// A plain-HTTP loopback server answering `handler` for up to `max` requests.
pub const TestServer = struct {
    server: Io.net.Server,
    port: u16,
    served: std.atomic.Value(u32) = .init(0),
    handler: *const fn (*TestServer, *std.http.Server.Request) anyerror!void,
    ctx: ?*anyopaque = null,
    max: u32,
    future: Io.Future(Io.Cancelable!void) = undefined,

    pub fn start(self: *TestServer, io: Io) !void {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.future = try io.concurrent(run, .{ self, io });
    }

    pub fn stop(self: *TestServer, io: Io) void {
        self.future.cancel(io) catch {};
        self.server.deinit(io);
    }

    fn run(self: *TestServer, io: Io) Io.Cancelable!void {
        while (self.served.load(.monotonic) < self.max) {
            const conn = self.server.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            defer conn.close(io);
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var sr = conn.reader(io, &rbuf);
            var sw = conn.writer(io, &wbuf);
            var http: std.http.Server = .init(&sr.interface, &sw.interface);
            while (self.served.load(.monotonic) < self.max) {
                var req = http.receiveHead() catch break;
                _ = self.served.fetchAdd(1, .monotonic);
                self.handler(self, &req) catch break;
            }
        }
    }

    pub fn url(self: *TestServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }
};
