//! The one-shot loopback redirect listener for native apps (RFC 8252
//! section 7.3). It binds an ephemeral port on 127.0.0.1 (or [::1] when no
//! IPv4 loopback exists), never a wildcard address, and lives only for one
//! authorization request.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const url = @import("../url.zig");

/// The redirect parameters. All strings are owned; free with `deinit`.
pub const Callback = struct {
    code: ?[]const u8 = null,
    state: []const u8,
    iss: ?[]const u8 = null,
    err: ?[]const u8 = null,
    err_description: ?[]const u8 = null,

    pub fn deinit(self: Callback, gpa: Allocator) void {
        inline for (.{ self.code, self.iss, self.err, self.err_description }) |s| if (s) |v| gpa.free(v);
        gpa.free(self.state);
    }
};

const done_page =
    \\<!doctype html><html><head><meta charset="utf-8"><title>Signed in</title></head>
    \\<body style="font-family:sans-serif;margin:3em">
    \\<p>Zigguro received the sign-in response. You can close this tab.</p></body></html>
;

pub const Loopback = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,
    v6: bool,

    /// Binds `127.0.0.1:0`, falling back to `[::1]:0`.
    pub fn listen(io: Io) !Loopback {
        const v4: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var v6 = false;
        const server = v4.listen(io, .{}) catch |err4| blk: {
            const a6: Io.net.IpAddress = .{ .ip6 = .loopback(0) };
            v6 = true;
            break :blk a6.listen(io, .{}) catch return err4;
        };
        const lb: Loopback = .{ .io = io, .server = server, .port = server.socket.address.getPort(), .v6 = v6 };
        std.debug.assert(isLoopback(lb.server.socket.address));
        return lb;
    }

    /// The bound address (always a loopback address).
    pub fn address(self: *const Loopback) Io.net.IpAddress {
        return self.server.socket.address;
    }

    /// `http://127.0.0.1:{port}/callback` (or the `[::1]` form).
    pub fn redirectUri(self: *const Loopback, buf: []u8) []const u8 {
        const h = if (self.v6) "[::1]" else "127.0.0.1";
        return std.fmt.bufPrint(buf, "http://{s}:{d}/callback", .{ h, self.port }) catch unreachable;
    }

    /// Serves requests until a `GET /callback` carrying `expected_state`
    /// arrives, `deadline` passes (`error.Timeout`) or the caller is
    /// canceled. Other paths get a 404; a wrong or missing state gets a 400
    /// and the listener keeps waiting, so a local page cannot end the flow.
    pub fn awaitCallback(self: *Loopback, gpa: Allocator, expected_state: []const u8, deadline: zg_core.runtime.Deadline) !Callback {
        const io = self.io;
        var done: Io.Event = .unset;
        var fut = try io.concurrent(serve, .{ self, gpa, expected_state, &done });
        while (true) {
            done.waitTimeout(io, deadline.timeout()) catch |err| switch (err) {
                error.Timeout => if (!deadline.expired(io)) continue else {
                    drop(&fut, io, gpa);
                    return error.Timeout;
                },
                error.Canceled => {
                    drop(&fut, io, gpa);
                    return error.Canceled;
                },
            };
            break;
        }
        return fut.await(io);
    }

    pub fn close(self: *Loopback) void {
        self.server.deinit(self.io);
    }

    fn drop(fut: anytype, io: Io, gpa: Allocator) void {
        if (fut.cancel(io)) |cb| cb.deinit(gpa) else |_| {}
    }

    fn serve(self: *Loopback, gpa: Allocator, expected_state: []const u8, done: *Io.Event) !Callback {
        const io = self.io;
        defer done.set(io);
        while (true) {
            const conn = self.server.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            defer conn.close(io);
            if (try handle(io, conn, gpa, expected_state)) |cb| return cb;
        }
    }

    fn handle(io: Io, conn: Io.net.Stream, gpa: Allocator, expected_state: []const u8) !?Callback {
        var rbuf: [8192]u8 = undefined;
        var wbuf: [1024]u8 = undefined;
        var sr = conn.reader(io, &rbuf);
        var sw = conn.writer(io, &wbuf);
        var http: std.http.Server = .init(&sr.interface, &sw.interface);
        var req = http.receiveHead() catch return null;
        const target = req.head.target;
        const q = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. q orelse target.len];
        const query = if (q) |i| target[i + 1 ..] else "";
        if (req.head.method != .GET or !std.mem.eql(u8, path, "/callback")) {
            req.respond("not found", .{ .status = .not_found, .keep_alive = false }) catch {};
            return null;
        }
        const state = (try url.queryParam(gpa, query, "state")) orelse {
            req.respond("unexpected request", .{ .status = .bad_request, .keep_alive = false }) catch {};
            return null;
        };
        if (!std.mem.eql(u8, state, expected_state)) {
            gpa.free(state);
            req.respond("unexpected request", .{ .status = .bad_request, .keep_alive = false }) catch {};
            return null;
        }
        var cb: Callback = .{ .state = state };
        errdefer cb.deinit(gpa);
        cb.code = try url.queryParam(gpa, query, "code");
        cb.iss = try url.queryParam(gpa, query, "iss");
        cb.err = try url.queryParam(gpa, query, "error");
        cb.err_description = try url.queryParam(gpa, query, "error_description");
        req.respond(done_page, .{ .keep_alive = false, .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-store" },
        } }) catch {};
        return cb;
    }
};

fn isLoopback(a: Io.net.IpAddress) bool {
    return switch (a) {
        .ip4 => |v| v.bytes[0] == 127,
        .ip6 => |v| std.mem.eql(u8, &v.bytes, &(([_]u8{0} ** 15) ++ [_]u8{1})),
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Sends one raw HTTP/1.1 GET to the listener and returns the status code.
fn rawGet(io: Io, port: u16, target: []const u8) !u16 {
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const s = try addr.connect(io, .{ .mode = .stream });
    defer s.close(io);
    var wbuf: [512]u8 = undefined;
    var w = s.writer(io, &wbuf);
    try w.interface.print("GET {s} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n", .{target});
    try w.interface.flush();
    var rbuf: [2048]u8 = undefined;
    var r = s.reader(io, &rbuf);
    const line = try r.interface.takeDelimiterInclusive('\n');
    return std.fmt.parseInt(u16, line[9..12], 10);
}

const Browser = struct {
    fn run(io: Io, port: u16, codes: *[3]u16) !void {
        codes[0] = try rawGet(io, port, "/favicon.ico");
        codes[1] = try rawGet(io, port, "/callback?code=evil&state=wrong");
        codes[2] = try rawGet(io, port, "/callback?code=abc%2F1&state=s-1&iss=https%3A%2F%2Fas.example");
    }
};

test "loopback: binds only to loopback with an ephemeral port" {
    var lb = try Loopback.listen(testing.io);
    defer lb.close();
    try testing.expect(isLoopback(lb.address()));
    try testing.expect(lb.port != 0);
    var buf: [64]u8 = undefined;
    const uri = lb.redirectUri(&buf);
    try testing.expect(std.mem.startsWith(u8, uri, "http://127.0.0.1:") or std.mem.startsWith(u8, uri, "http://[::1]:"));
    try testing.expect(std.mem.endsWith(u8, uri, "/callback"));
}

test "loopback: wrong path 404, wrong state ignored, then the callback" {
    const io = testing.io;
    var lb = try Loopback.listen(io);
    defer lb.close();
    if (lb.v6) return error.SkipZigTest;
    var codes: [3]u16 = .{ 0, 0, 0 };
    var browser = try io.concurrent(Browser.run, .{ io, lb.port, &codes });
    const cb = try lb.awaitCallback(testing.allocator, "s-1", .after(io, .fromSeconds(10)));
    defer cb.deinit(testing.allocator);
    try browser.await(io);
    try testing.expectEqual([3]u16{ 404, 400, 200 }, codes);
    try testing.expectEqualStrings("abc/1", cb.code.?);
    try testing.expectEqualStrings("https://as.example", cb.iss.?);
    try testing.expectEqual(@as(?[]const u8, null), cb.err);
}

test "loopback: error response is returned to the caller" {
    const io = testing.io;
    var lb = try Loopback.listen(io);
    defer lb.close();
    if (lb.v6) return error.SkipZigTest;
    const Denier = struct {
        fn run(io2: Io, port: u16) !void {
            _ = try rawGet(io2, port, "/callback?error=access_denied&error_description=no+thanks&state=st");
        }
    };
    var browser = try io.concurrent(Denier.run, .{ io, lb.port });
    const cb = try lb.awaitCallback(testing.allocator, "st", .after(io, .fromSeconds(10)));
    defer cb.deinit(testing.allocator);
    try browser.await(io);
    try testing.expectEqual(@as(?[]const u8, null), cb.code);
    try testing.expectEqualStrings("access_denied", cb.err.?);
    try testing.expectEqualStrings("no thanks", cb.err_description.?);
}

test "loopback: times out" {
    const io = testing.io;
    var lb = try Loopback.listen(io);
    defer lb.close();
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    try testing.expectError(error.Timeout, lb.awaitCallback(testing.allocator, "x", .after(io, .fromMilliseconds(50))));
    try testing.expect(t0.untilNow(io).raw.toMilliseconds() >= 50);
}
