//! An RFC 6455 WebSocket client over `http.Client` connections (proxies,
//! NO_PROXY and TLS roots as for plain HTTP).
//!
//! - Opening handshake: HTTP/1.1 Upgrade with a random key; the server must
//!   answer 101 with a matching `Sec-WebSocket-Accept`, may only pick a
//!   requested subprotocol, and may not enable extensions.
//! - Client frames are always masked with a fresh mask; server frames must
//!   not be. Fragmented messages are reassembled; control frames may
//!   interleave. Text is UTF-8 validated over the whole message.
//! - Protocol violations send the matching close code (1002 protocol, 1007
//!   invalid UTF-8, 1009 too big) and fail the call.
//!
//! `send`, `ping` and `close` are thread-safe; `recv` has a single reader.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const http = @import("http.zig");
const frame = @import("ws_frame.zig");
const Opcode = frame.Opcode;

pub const Options = struct {
    subprotocols: []const []const u8 = &.{},
    headers: []const std.http.Header = &.{},
    max_message_bytes: usize = 64 << 20,
    auto_pong: bool = true,
};

pub const Kind = enum { text, binary };

pub const Message = struct {
    kind: Kind,
    /// Owned by the allocator passed to `recv`.
    data: []u8,
};

pub const CloseInfo = struct { code: u16, reason: []const u8 };

pub const Received = union(enum) { message: Message, closed: CloseInfo };

pub const Error = error{ HandshakeFailed, ProtocolError, InvalidUtf8, MessageTooLarge, ConnectionClosed };

pub const WebSocket = struct {
    client: *http.Client,
    raw: http.Client.Raw,
    io: Io,
    opts: Options,
    send_mutex: Io.Mutex = .init,
    close_sent: bool = false,
    close_received: bool = false,
    /// Subprotocol the server selected, if any (points into `proto_buf`).
    protocol: ?[]const u8 = null,
    proto_buf: [64]u8 = undefined,
    close_reason_buf: [123]u8 = undefined,

    /// Connects to a `ws://` or `wss://` URL and performs the handshake.
    pub fn connect(client: *http.Client, gpa: Allocator, url: []const u8, opts: Options) !*WebSocket {
        _ = gpa;
        const uri = try std.Uri.parse(url);
        const protocol: std.http.Client.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "wss"))
            .tls
        else if (std.ascii.eqlIgnoreCase(uri.scheme, "ws"))
            .plain
        else
            return error.UnsupportedUriScheme;
        var host_buf: [Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        const port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80);
        const raw = try client.connectRaw(host, port, protocol);
        errdefer client.releaseRaw(raw);
        const ws = try client.gpa.create(WebSocket);
        errdefer client.gpa.destroy(ws);
        ws.* = .{ .client = client, .raw = raw, .io = client.io, .opts = opts };
        try ws.handshake(uri, host.bytes, port, protocol);
        return ws;
    }

    fn handshake(ws: *WebSocket, uri: std.Uri, host: []const u8, port: u16, protocol: std.http.Client.Protocol) !void {
        var nonce: [16]u8 = undefined;
        ws.io.random(&nonce);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &nonce);
        const w = ws.raw.conn.writer();
        try w.writeAll("GET ");
        try uri.writeToStream(w, .{ .path = true, .query = true });
        if (uri.path.isEmpty()) try w.writeByte('/');
        try w.writeAll(" HTTP/1.1\r\nHost: ");
        try w.writeAll(host);
        const default_port: u16 = if (protocol == .tls) 443 else 80;
        if (port != default_port) try w.print(":{d}", .{port});
        try w.print("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n", .{key});
        if (ws.opts.subprotocols.len > 0) {
            try w.writeAll("Sec-WebSocket-Protocol: ");
            for (ws.opts.subprotocols, 0..) |p, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeAll(p);
            }
            try w.writeAll("\r\n");
        }
        try w.print("User-Agent: {s}\r\n", .{ws.client.cfg.user_agent});
        for (ws.opts.headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        try w.writeAll("\r\n");
        try ws.raw.conn.flush();

        var expect_buf: [28]u8 = undefined;
        const expect = frame.acceptKey(key, &expect_buf);
        const r = ws.raw.conn.reader();
        const status_line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) return error.HandshakeFailed;
        var upgrade_ok = false;
        var connection_ok = false;
        var accept_ok = false;
        var total: usize = status_line.len;
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            total += line.len;
            if (total > 16 << 10) return error.HandshakeFailed;
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.HandshakeFailed;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                upgrade_ok = std.ascii.eqlIgnoreCase(value, "websocket");
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                connection_ok = hasToken(value, "upgrade");
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                accept_ok = std.mem.eql(u8, value, expect);
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
                if (value.len != 0) return error.HandshakeFailed;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
                var requested = false;
                for (ws.opts.subprotocols) |p| requested = requested or std.mem.eql(u8, p, value);
                if (!requested or value.len > ws.proto_buf.len) return error.HandshakeFailed;
                @memcpy(ws.proto_buf[0..value.len], value);
                ws.protocol = ws.proto_buf[0..value.len];
            }
        }
        if (!upgrade_ok or !connection_ok or !accept_ok) return error.HandshakeFailed;
    }

    /// Sends one unfragmented data message.
    pub fn send(ws: *WebSocket, kind: Kind, data: []const u8) !void {
        return ws.writeFrame(if (kind == .text) .text else .binary, data);
    }

    pub fn ping(ws: *WebSocket, payload: []const u8) !void {
        if (payload.len > 125) return error.ProtocolError;
        return ws.writeFrame(.ping, payload);
    }

    fn writeFrame(ws: *WebSocket, op: Opcode, data: []const u8) !void {
        try ws.send_mutex.lock(ws.io);
        defer ws.send_mutex.unlock(ws.io);
        return ws.writeFrameLocked(op, data);
    }

    fn writeFrameLocked(ws: *WebSocket, op: Opcode, data: []const u8) !void {
        if (ws.close_sent) return error.ConnectionClosed;
        if (op == .close) ws.close_sent = true;
        var mask: [4]u8 = undefined;
        ws.io.random(&mask);
        var hbuf: [14]u8 = undefined;
        const w = ws.raw.conn.writer();
        try w.writeAll(frame.encodeHeader(&hbuf, .{ .fin = true, .opcode = op, .masked = true, .len = data.len, .mask = mask }));
        var chunk: [4096]u8 = undefined;
        var off: usize = 0;
        while (off < data.len) {
            const n = @min(chunk.len, data.len - off);
            @memcpy(chunk[0..n], data[off..][0..n]);
            frame.applyMask(mask, off, chunk[0..n]);
            try w.writeAll(chunk[0..n]);
            off += n;
        }
        try ws.raw.conn.flush();
    }

    fn sendClose(ws: *WebSocket, code: u16, reason: []const u8) void {
        var body: [125]u8 = undefined;
        std.mem.writeInt(u16, body[0..2], code, .big);
        const r = reason[0..@min(reason.len, 123)];
        @memcpy(body[2..][0..r.len], r);
        ws.send_mutex.lockUncancelable(ws.io);
        defer ws.send_mutex.unlock(ws.io);
        if (ws.close_sent) return;
        ws.writeFrameLocked(.close, body[0 .. 2 + r.len]) catch {};
    }

    fn fail(ws: *WebSocket, code: u16, err: Error) Error {
        ws.sendClose(code, "");
        return err;
    }

    /// Receives the next data message, answering pings on the way, or the
    /// peer's close (echoed back if we had not sent one).
    pub fn recv(ws: *WebSocket, gpa: Allocator) !Received {
        if (ws.close_received) return error.ConnectionClosed;
        const r = ws.raw.conn.reader();
        var msg: std.ArrayList(u8) = .empty;
        errdefer msg.deinit(gpa);
        var kind: ?Kind = null;
        while (true) {
            const first = try r.peekArray(2);
            const size = frame.headerSize(first.*);
            const d = frame.decodeHeader(try r.peek(size)) catch return ws.fail(1002, error.ProtocolError);
            r.toss(d.size);
            const h = d.header;
            if (h.rsv != 0 or h.masked or !h.opcode.isKnown()) return ws.fail(1002, error.ProtocolError);
            if (h.opcode.isControl()) {
                if (!h.fin or h.len > 125) return ws.fail(1002, error.ProtocolError);
                var payload: [125]u8 = undefined;
                const p = payload[0..@intCast(h.len)];
                try r.readSliceAll(p);
                switch (h.opcode) {
                    .ping => if (ws.opts.auto_pong) ws.writeFrame(.pong, p) catch {},
                    .pong => {},
                    .close => return ws.handleClose(p),
                    else => unreachable,
                }
                continue;
            }
            switch (h.opcode) {
                .continuation => if (kind == null) return ws.fail(1002, error.ProtocolError),
                .text, .binary => {
                    if (kind != null) return ws.fail(1002, error.ProtocolError);
                    kind = if (h.opcode == .text) .text else .binary;
                },
                else => unreachable,
            }
            if (msg.items.len + h.len > ws.opts.max_message_bytes) return ws.fail(1009, error.MessageTooLarge);
            const start = msg.items.len;
            try msg.resize(gpa, start + @as(usize, @intCast(h.len)));
            try r.readSliceAll(msg.items[start..]);
            if (!h.fin) continue;
            if (kind.? == .text and !zg_core.utf8.validate(msg.items)) return ws.fail(1007, error.InvalidUtf8);
            return .{ .message = .{ .kind = kind.?, .data = try msg.toOwnedSlice(gpa) } };
        }
    }

    fn handleClose(ws: *WebSocket, p: []const u8) !Received {
        ws.close_received = true;
        if (p.len == 1) return ws.fail(1002, error.ProtocolError);
        var info: CloseInfo = .{ .code = 1005, .reason = "" };
        if (p.len >= 2) {
            info.code = std.mem.readInt(u16, p[0..2], .big);
            const reason = p[2..];
            if (!zg_core.utf8.validate(reason)) return ws.fail(1007, error.InvalidUtf8);
            @memcpy(ws.close_reason_buf[0..reason.len], reason);
            info.reason = ws.close_reason_buf[0..reason.len];
        }
        ws.sendClose(if (p.len >= 2) info.code else 1000, "");
        return .{ .closed = info };
    }

    /// Starts the closing handshake and waits up to 2 s for the peer's
    /// close; data frames that arrive meanwhile are discarded.
    pub fn close(ws: *WebSocket, code: u16, reason: []const u8) !void {
        ws.sendClose(code, reason);
        if (ws.close_received) return;
        const deadline: zg_core.runtime.Deadline = .after(ws.io, .fromSeconds(2));
        _ = zg_core.runtime.withDeadline(ws.io, deadline, drainUntilClose, .{ws}) catch {};
    }

    fn drainUntilClose(ws: *WebSocket) !void {
        var arena: std.heap.ArenaAllocator = .init(ws.client.gpa);
        defer arena.deinit();
        while (!ws.close_received) {
            _ = arena.reset(.retain_capacity);
            _ = ws.recv(arena.allocator()) catch return;
        }
    }

    pub fn deinit(ws: *WebSocket) void {
        ws.client.releaseRaw(ws.raw);
        ws.client.gpa.destroy(ws);
    }
};

fn hasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |t| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t"), token)) return true;
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A loopback server that upgrades one connection and runs `script`.
const EchoServer = struct {
    server: Io.net.Server,
    port: u16,
    script: *const fn (*std.http.Server.WebSocket) anyerror!void,
    future: Io.Future(Io.Cancelable!void) = undefined,

    fn start(self: *EchoServer, io: Io) !void {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.future = try io.concurrent(run, .{ self, io });
    }

    fn stop(self: *EchoServer, io: Io) void {
        self.future.cancel(io) catch {};
        self.server.deinit(io);
    }

    fn run(self: *EchoServer, io: Io) Io.Cancelable!void {
        const conn = self.server.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        defer conn.close(io);
        var rbuf: [1 << 16]u8 = undefined;
        var wbuf: [1 << 16]u8 = undefined;
        var sr = conn.reader(io, &rbuf);
        var sw = conn.writer(io, &wbuf);
        var srv: std.http.Server = .init(&sr.interface, &sw.interface);
        var req = srv.receiveHead() catch return;
        const key = switch (req.upgradeRequested()) {
            .websocket => |k| k orelse return,
            else => return,
        };
        var ws = req.respondWebSocket(.{ .key = key }) catch return;
        ws.flush() catch return;
        self.script(&ws) catch {};
    }

    fn url(self: *EchoServer, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "ws://127.0.0.1:{d}/chat?x=1", .{self.port}) catch unreachable;
    }
};

/// Writes a raw unmasked server frame.
fn rawFrame(ws: *std.http.Server.WebSocket, fin: bool, op: Opcode, payload: []const u8) !void {
    var h: [14]u8 = undefined;
    try ws.output.writeAll(frame.encodeHeader(&h, .{ .fin = fin, .opcode = op, .masked = false, .len = payload.len }));
    try ws.output.writeAll(payload);
    try ws.output.flush();
}

/// Reads one masked client frame and returns its unmasked payload.
fn readClientFrame(ws: *std.http.Server.WebSocket, buf: []u8) !struct { op: Opcode, data: []u8 } {
    const first = try ws.input.peekArray(2);
    const d = try frame.decodeHeader(try ws.input.peek(frame.headerSize(first.*)));
    ws.input.toss(d.size);
    if (d.header.len > buf.len) return error.FrameTooLarge;
    const data = buf[0..@intCast(d.header.len)];
    try ws.input.readSliceAll(data);
    frame.applyMask(d.header.mask, 0, data);
    return .{ .op = d.header.opcode, .data = data };
}

const Fixture = struct {
    rt: zg_core.Runtime,
    env: std.process.Environ.Map,
    client: *http.Client,

    fn init(f: *Fixture) !void {
        f.rt.initTesting();
        f.env = .init(testing.allocator);
        f.client = try http.Client.init(&f.rt, .{ .proxy = .none, .environ_map = &f.env });
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.env.deinit();
        _ = f.rt.deinit();
    }
};

test "websocket: echo text and binary, then close handshake" {
    const io = testing.io;
    var srv: EchoServer = .{ .server = undefined, .port = 0, .script = struct {
        fn s(ws: *std.http.Server.WebSocket) !void {
            const buf = try std.heap.page_allocator.alloc(u8, 1 << 17);
            defer std.heap.page_allocator.free(buf);
            while (true) {
                const f = try readClientFrame(ws, buf);
                if (f.op == .close) {
                    try rawFrame(ws, true, .close, f.data);
                    return;
                }
                try rawFrame(ws, true, f.op, f.data);
            }
        }
    }.s };
    try srv.start(io);
    defer srv.stop(io);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var ubuf: [64]u8 = undefined;
    const ws = try WebSocket.connect(f.client, testing.allocator, srv.url(&ubuf), .{});
    defer ws.deinit();
    try ws.send(.text, "héllo");
    const big = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);
    try ws.send(.binary, big);
    const a = (try ws.recv(testing.allocator)).message;
    defer testing.allocator.free(a.data);
    try testing.expectEqual(Kind.text, a.kind);
    try testing.expectEqualStrings("héllo", a.data);
    const b = (try ws.recv(testing.allocator)).message;
    defer testing.allocator.free(b.data);
    try testing.expectEqualSlices(u8, big, b.data);
    try ws.close(1000, "bye");
    try testing.expect(ws.close_received);
}

test "websocket: fragmented message with interleaved ping" {
    const io = testing.io;
    var srv: EchoServer = .{ .server = undefined, .port = 0, .script = struct {
        fn s(ws: *std.http.Server.WebSocket) !void {
            try rawFrame(ws, false, .text, "frag");
            try rawFrame(ws, true, .ping, "p1");
            try rawFrame(ws, false, .continuation, "men");
            try rawFrame(ws, true, .continuation, "ted");
            var buf: [256]u8 = undefined;
            const pong = try readClientFrame(ws, &buf);
            if (pong.op != .pong or !std.mem.eql(u8, pong.data, "p1")) return error.NoPong;
            try rawFrame(ws, true, .text, "pong ok");
            try rawFrame(ws, true, .close, &.{ 0x03, 0xe8, 'o', 'k' });
            _ = try readClientFrame(ws, &buf);
        }
    }.s };
    try srv.start(io);
    defer srv.stop(io);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var ubuf: [64]u8 = undefined;
    const ws = try WebSocket.connect(f.client, testing.allocator, srv.url(&ubuf), .{});
    defer ws.deinit();
    const m = (try ws.recv(testing.allocator)).message;
    defer testing.allocator.free(m.data);
    try testing.expectEqualStrings("fragmented", m.data);
    const m2 = (try ws.recv(testing.allocator)).message;
    defer testing.allocator.free(m2.data);
    try testing.expectEqualStrings("pong ok", m2.data);
    const c = (try ws.recv(testing.allocator)).closed;
    try testing.expectEqual(@as(u16, 1000), c.code);
    try testing.expectEqualStrings("ok", c.reason);
}

test "websocket: invalid UTF-8 closes with 1007" {
    const io = testing.io;
    const Seen = struct {
        var code: u16 = 0;
    };
    Seen.code = 0;
    var srv: EchoServer = .{ .server = undefined, .port = 0, .script = struct {
        fn s(ws: *std.http.Server.WebSocket) !void {
            try rawFrame(ws, true, .text, "\xff\xfe");
            var buf: [256]u8 = undefined;
            const c = try readClientFrame(ws, &buf);
            if (c.op == .close and c.data.len >= 2) Seen.code = std.mem.readInt(u16, c.data[0..2], .big);
        }
    }.s };
    try srv.start(io);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var ubuf: [64]u8 = undefined;
    const ws = try WebSocket.connect(f.client, testing.allocator, srv.url(&ubuf), .{});
    defer ws.deinit();
    try testing.expectError(error.InvalidUtf8, ws.recv(testing.allocator));
    try srv.future.await(io);
    srv.server.deinit(io);
    try testing.expectEqual(@as(u16, 1007), Seen.code);
}

test "websocket: masked server frame is a protocol error" {
    const io = testing.io;
    var srv: EchoServer = .{ .server = undefined, .port = 0, .script = struct {
        fn s(ws: *std.http.Server.WebSocket) !void {
            var h: [14]u8 = undefined;
            try ws.output.writeAll(frame.encodeHeader(&h, .{ .fin = true, .opcode = .text, .masked = true, .len = 1, .mask = .{ 1, 1, 1, 1 } }));
            try ws.output.writeAll("x");
            try ws.output.flush();
            var buf: [256]u8 = undefined;
            _ = readClientFrame(ws, &buf) catch {};
        }
    }.s };
    try srv.start(io);
    defer srv.stop(io);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var ubuf: [64]u8 = undefined;
    const ws = try WebSocket.connect(f.client, testing.allocator, srv.url(&ubuf), .{});
    defer ws.deinit();
    try testing.expectError(error.ProtocolError, ws.recv(testing.allocator));
}
