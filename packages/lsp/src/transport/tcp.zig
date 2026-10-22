//! A transport over a TCP connection, and the helpers `ServerProcess` uses
//! for servers that listen on a port (`tcp_connect`, `tcp_listen_child`).
//!
//! Hosts are IP literals or `localhost` (no DNS). Only loopback addresses
//! are allowed unless the caller passes `allow_remote` (the
//! `lsp.allowRemote` setting).

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Transport = @import("Transport.zig");

pub const ConnectOptions = struct {
    allow_remote: bool = false,
    /// Keep retrying refused connections until this much time has passed
    /// (for servers that are still starting up); zero tries once.
    retry_for: Io.Duration = .zero,
    retry_step: Io.Duration = .fromMilliseconds(50),
};

/// Parses `host` (an IP literal or `localhost`) and checks the loopback
/// rule.
pub fn resolveAddress(host: []const u8, port: u16, allow_remote: bool) !net.IpAddress {
    const text = if (std.ascii.eqlIgnoreCase(host, "localhost")) "127.0.0.1" else host;
    const addr = net.IpAddress.parse(text, port) catch return error.InvalidHost;
    if (!allow_remote and !isLoopback(addr)) return error.RemoteNotAllowed;
    return addr;
}

/// True for 127.0.0.0/8, ::1 and IPv4-mapped loopback.
pub fn isLoopback(addr: net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &(.{0} ** 15 ++ .{1})) or
            (std.mem.eql(u8, a.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }) and a.bytes[12] == 127),
    };
}

/// Asks the OS for a free loopback port by binding `127.0.0.1:0`. Racy (the
/// port may be taken before the server binds it) but standard.
pub fn pickFreePort(io: Io) !u16 {
    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

/// Owns one TCP stream.
pub const TcpTransport = struct {
    transport: Transport,
    gpa: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    shut: std.atomic.Value(bool) = .init(false),
    r: net.Stream.Reader,
    w: net.Stream.Writer,
    read_buf: [Transport.buffer_size]u8,
    write_buf: [Transport.buffer_size]u8,

    const vtable: Transport.VTable = .{ .close = closeImpl, .deinit = deinitImpl };

    /// Connects to `host:port`, retrying refused connections per `opts`.
    pub fn connect(gpa: std.mem.Allocator, io: Io, host: []const u8, port: u16, opts: ConnectOptions) !*TcpTransport {
        const addr = try resolveAddress(host, port, opts.allow_remote);
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = opts.retry_for, .clock = .awake });
        const stream = while (true) {
            break addr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
                error.ConnectionRefused => {
                    if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return err;
                    try io.sleep(opts.retry_step, .awake);
                    continue;
                },
                else => return err,
            };
        };
        return adopt(gpa, io, stream);
    }

    /// Takes ownership of a connected `stream`.
    pub fn adopt(gpa: std.mem.Allocator, io: Io, stream: net.Stream) !*TcpTransport {
        const t = gpa.create(TcpTransport) catch |err| {
            stream.close(io);
            return err;
        };
        t.* = .{
            .transport = undefined,
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .r = undefined,
            .w = undefined,
            .read_buf = undefined,
            .write_buf = undefined,
        };
        t.r = stream.reader(io, &t.read_buf);
        t.w = stream.writer(io, &t.write_buf);
        t.transport = .{ .reader = &t.r.interface, .writer = &t.w.interface, .vtable = &vtable };
        return t;
    }

    fn closeImpl(tr: *Transport) void {
        const t: *TcpTransport = @alignCast(@fieldParentPtr("transport", tr));
        if (t.shut.swap(true, .acq_rel)) return;
        t.stream.shutdown(t.io, .both) catch {};
    }

    fn deinitImpl(tr: *Transport) void {
        closeImpl(tr);
        const t: *TcpTransport = @alignCast(@fieldParentPtr("transport", tr));
        t.stream.close(t.io);
        t.gpa.destroy(t);
    }
};
