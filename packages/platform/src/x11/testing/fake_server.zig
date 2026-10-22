//! A scriptable X server end of a `socketpair`, for tests of `Conn`.
//! Responses are written before the client asks for them, so tests run
//! on one thread: the socket buffer holds them until the client reads.

const std = @import("std");
const linux = std.os.linux;
const setup = @import("../setup.zig");
const proto = @import("../proto.zig");
const socket = @import("../../wayland/wire/socket.zig");
const FdQueue = @import("../../wayland/wire/fdqueue.zig").FdQueue;
const Conn = @import("../conn.zig").Conn;

/// The server side of a socketpair.
pub const FakeServer = struct {
    gpa: std.mem.Allocator,
    sock: i32,
    /// The client end: pass it to `Conn.fromFd`, which takes it over.
    client_fd: i32,
    /// Fds received with requests.
    fds: FdQueue = .{},

    /// Makes a socketpair.
    pub fn init(gpa: std.mem.Allocator) !*FakeServer {
        const sp = try socket.pair();
        const fs = try gpa.create(FakeServer);
        fs.* = .{ .gpa = gpa, .sock = sp[0], .client_fd = sp[1] };
        return fs;
    }

    /// Closes the server end and frees `fs` (not `client_fd`).
    pub fn deinit(fs: *FakeServer) void {
        _ = linux.close(fs.sock);
        fs.fds.closeAll();
        fs.gpa.destroy(fs);
    }

    /// Sends raw bytes with `fds` attached.
    pub fn sendBytes(fs: *FakeServer, bytes: []const u8, fds: []const i32) !void {
        var off: usize = 0;
        var pass = fds;
        while (off < bytes.len) {
            off += try socket.sendMsg(fs.sock, bytes[off..], pass);
            pass = &.{};
        }
    }

    /// Sends a successful setup reply for `s`.
    pub fn sendSetup(fs: *FakeServer, s: setup.Setup) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(fs.gpa);
        try setup.writeReply(&out, fs.gpa, s);
        try fs.sendBytes(out.items, &.{});
    }

    /// Sends a reply for wire sequence `seq`: `word8` at offset 8 and
    /// `extra` after the 32-byte header (padded to 4 bytes).
    pub fn sendReply(fs: *FakeServer, seq: u16, data: u8, word8: u32, extra: []const u8, fds: []const i32) !void {
        var buf: [32 + 256]u8 = @splat(0);
        const words = (extra.len + 3) / 4;
        buf[0] = 1;
        buf[1] = data;
        std.mem.writeInt(u16, buf[2..4], seq, .little);
        std.mem.writeInt(u32, buf[4..8], @intCast(words), .little);
        std.mem.writeInt(u32, buf[8..12], word8, .little);
        @memcpy(buf[32..][0..extra.len], extra);
        try fs.sendBytes(buf[0 .. 32 + words * 4], fds);
    }

    /// Sends an error for wire sequence `seq`.
    pub fn sendError(fs: *FakeServer, seq: u16, code: u8, major: u8, bad_value: u32) !void {
        var buf: [32]u8 = @splat(0);
        buf[1] = code;
        std.mem.writeInt(u16, buf[2..4], seq, .little);
        std.mem.writeInt(u32, buf[4..8], bad_value, .little);
        buf[10] = major;
        try fs.sendBytes(&buf, &.{});
    }

    /// Sends a core event `code` with wire sequence `seq`.
    pub fn sendEvent(fs: *FakeServer, code: u8, seq: u16, detail: u8) !void {
        var buf: [32]u8 = @splat(0);
        buf[0] = code;
        buf[1] = detail;
        std.mem.writeInt(u16, buf[2..4], seq, .little);
        try fs.sendBytes(&buf, &.{});
    }

    /// Sends a GenericEvent for `ext_opcode` carrying `extra` past the
    /// 32 bytes (a multiple of 4).
    pub fn sendGenericEvent(fs: *FakeServer, ext_opcode: u8, seq: u16, evtype: u16, extra: []const u8) !void {
        var buf: [32 + 256]u8 = @splat(0);
        buf[0] = proto.generic_event;
        buf[1] = ext_opcode;
        std.mem.writeInt(u16, buf[2..4], seq, .little);
        std.mem.writeInt(u32, buf[4..8], @intCast(extra.len / 4), .little);
        std.mem.writeInt(u16, buf[8..10], evtype, .little);
        @memcpy(buf[32..][0..extra.len], extra);
        try fs.sendBytes(buf[0 .. 32 + extra.len], &.{});
    }

    /// Reads whatever the client has sent (without blocking) into `buf`.
    pub fn recvAvailable(fs: *FakeServer, buf: []u8) ![]u8 {
        var n: usize = 0;
        while (n < buf.len) {
            n += socket.recvMsg(fs.sock, buf[n..], &fs.fds, true) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
        }
        return buf[0..n];
    }

    /// Reads and drops the client's setup request.
    pub fn takeSetupRequest(fs: *FakeServer) !void {
        var buf: [256]u8 = undefined;
        _ = try fs.recvAvailable(&buf);
    }

    /// A connected `Conn` over this socketpair, set up with
    /// `setup.test_setup` and no extensions.
    pub fn connect(fs: *FakeServer) !*Conn {
        try fs.sendSetup(setup.test_setup);
        const c = try Conn.fromFd(fs.gpa, std.testing.io, fs.client_fd, null, .{ .query_extensions = false });
        try fs.takeSetupRequest();
        return c;
    }
};

/// Splits a request stream into (major opcode, length in bytes) pairs.
pub fn requestOpcodes(bytes: []const u8, out: []u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i + 4 <= bytes.len and n < out.len) : (n += 1) {
        out[n] = bytes[i];
        var len: usize = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .little) * 4;
        if (len == 0) len = @as(usize, std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little)) * 4;
        i += len;
    }
    return n;
}

const testing = std.testing;

test "setup is parsed and XIDs come from the base and mask" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    try testing.expectEqual(2, c.setup.screens.len);
    try testing.expectEqual(1920, c.screen().width_px);
    try testing.expectEqual(0x00400000, try c.newXid());
    try testing.expectEqual(0x00400001, try c.newXid());
}

test "an error is matched to its request's sequence" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    const a = try c.request(proto.InternAtom, .{ .name_len = 3, .name = "BAD" }, &.{});
    const b = try c.request(proto.InternAtom, .{ .name_len = 4, .name = "GOOD" }, &.{});
    try fs.sendError(1, proto.ErrorCode.value, proto.InternAtom.opcode, 7);
    try fs.sendReply(2, 0, 301, "", &.{});
    try testing.expectError(error.X11Error, c.reply(a));
    try testing.expectEqual(proto.ErrorCode.value, c.last_error.?.code);
    try testing.expectEqual(1, c.last_error.?.sequence);
    try testing.expectEqual(301, (try c.reply(b)).atom);
}

test "checked reports an error for a void request" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    try fs.sendError(1, proto.ErrorCode.window, proto.MapWindow.opcode, 0x99);
    try fs.sendReply(2, 0, 0, "", &.{});
    try testing.expectError(error.X11Error, c.checked(proto.MapWindow, .{ .window = 0x99 }, &.{}));
    // The next one succeeds: only its GetInputFocus is answered.
    try fs.sendReply(4, 0, 0, "", &.{});
    try c.checked(proto.MapWindow, .{ .window = 0x98 }, &.{});
}

test "16-bit sequence numbers wrap" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    c.seq_sent = 0xfffe;
    c.seq_read = 0xfffe;
    c.seq_answered_by = 0xfffe;
    var cookies: [3]@import("../conn.zig").Cookie(proto.InternAtom) = undefined;
    for (&cookies) |*ck| ck.* = try c.request(proto.InternAtom, .{ .name_len = 1, .name = "A" }, &.{});
    try testing.expectEqual(0x10001, cookies[2].seq);
    try fs.sendReply(0xffff, 0, 10, "", &.{});
    try fs.sendReply(0x0000, 0, 11, "", &.{});
    try fs.sendReply(0x0001, 0, 12, "", &.{});
    try testing.expectEqual(10, (try c.reply(cookies[0])).atom);
    try testing.expectEqual(11, (try c.reply(cookies[1])).atom);
    try testing.expectEqual(12, (try c.reply(cookies[2])).atom);
    try testing.expectEqual(0x10001, c.seq_read);
}

test "a void request stream keeps a reply in flight every 0xff00 requests" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    c.seq_sent = 0xff00;
    const ck = try c.request(proto.NoOperation, .{}, &.{});
    try testing.expectEqual(0xff02, ck.seq);
    try testing.expectEqual(1, c.pending.items.len);
    try testing.expect(c.pending.items[0].discard);
}

test "GenericEvent lengths split the event stream" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    try fs.sendGenericEvent(131, 0, 2, &(@as([8]u8, @splat(0xab))));
    try fs.sendEvent(12, 0, 0); // Expose
    const g = (try c.pollEvent()).?;
    try testing.expectEqual(40, g.len);
    try testing.expectEqual(0xab, g[39]);
    const e = (try c.pollEvent()).?;
    try testing.expectEqual(32, e.len);
    try testing.expectEqual(12, e[0]);
    try testing.expectEqual(null, try c.pollEvent());
}

test "an fd sent with a reply lands in the fd queue" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    var p: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true })));
    defer _ = linux.close(p[0]);
    const ck = try c.request(proto.GetInputFocus, .{}, &.{});
    try fs.sendReply(1, 0, 0x42, "", &.{p[1]});
    _ = linux.close(p[1]);
    try testing.expectEqual(0x42, (try c.reply(ck)).focus);
    try testing.expectEqual(1, c.in_fds.count());
    const got = c.in_fds.pop().?;
    defer _ = linux.close(got);
    try testing.expectEqual(1, linux.write(got, "x", 1));
    var b: [1]u8 = undefined;
    try testing.expectEqual(1, linux.read(p[0], &b, 1));
}

test "an fd sent with a request reaches the server" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    var p: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true })));
    defer for (p) |f| {
        _ = linux.close(f);
    };
    _ = try c.request(proto.NoOperation, .{}, &.{p[1]});
    try c.flush();
    var buf: [64]u8 = undefined;
    try testing.expectEqual(4, (try fs.recvAvailable(&buf)).len);
    try testing.expectEqual(1, fs.fds.count());
}

test "interning atoms is pipelined in one round trip" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    for (0..3) |i| try fs.sendReply(@intCast(i + 1), 0, @intCast(300 + i), "", &.{});
    const t = try c.internAtoms(&.{ "WM_PROTOCOLS", "WM_DELETE_WINDOW", "UTF8_STRING" });
    try testing.expectEqual(302, t.get("UTF8_STRING"));
    try testing.expectEqualStrings("WM_PROTOCOLS", t.name(300).?);
    // All three requests went out before the first reply was read.
    var buf: [256]u8 = undefined;
    var ops: [8]u8 = undefined;
    const n = requestOpcodes(try fs.recvAvailable(&buf), &ops);
    try testing.expectEqualSlices(u8, &.{ 16, 16, 16 }, ops[0..n]);
}

test "a reply longer than the read buffer chunk is reassembled" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    const ck = try c.request(proto.GetProperty, .{ .window = 1, .property = 2 }, &.{});
    var val: [200]u8 = undefined;
    for (&val, 0..) |*v, i| v.* = @truncate(i);
    var buf: [32 + 200]u8 = @splat(0);
    buf[0] = 1;
    buf[1] = 8;
    std.mem.writeInt(u16, buf[2..4], 1, .little);
    std.mem.writeInt(u32, buf[4..8], 50, .little);
    std.mem.writeInt(u32, buf[8..12], 31, .little); // type STRING
    std.mem.writeInt(u32, buf[16..20], 200, .little);
    @memcpy(buf[32..], &val);
    // Two writes: the client sees the header before the body.
    try fs.sendBytes(buf[0..40], &.{});
    try fs.sendBytes(buf[40..], &.{});
    const r = try c.reply(ck);
    try testing.expectEqual(31, r.type);
    try testing.expectEqualSlices(u8, &val, r.value);
}

test "requests, replies and events allocate nothing after warm-up" {
    var counting: @import("zg_core").alloc.CountingAllocator = .init(testing.allocator);
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    try fs.sendSetup(setup.test_setup);
    const c = try Conn.fromFd(counting.allocator(), testing.io, fs.client_fd, null, .{ .query_extensions = false });
    defer c.deinit();
    try fs.takeSetupRequest();
    var sink: [4096]u8 = undefined;
    var seq: u16 = 0;
    var warm: u64 = 0;
    var warm_bytes: u64 = 0;
    for (0..1000) |i| {
        if (i == 10) {
            warm = counting.allocs.load(.monotonic);
            warm_bytes = counting.bytes_total.load(.monotonic);
        }
        _ = try c.request(proto.MapWindow, .{ .window = 1 }, &.{});
        const ck = try c.request(proto.GetInputFocus, .{}, &.{});
        seq +%= 2;
        try fs.sendEvent(12, seq, 0);
        try fs.sendGenericEvent(131, seq, 2, &(@as([8]u8, @splat(1))));
        try fs.sendReply(seq, 0, 7, "", &.{});
        try testing.expectEqual(7, (try c.reply(ck)).focus);
        try testing.expectEqual(32, (try c.pollEvent()).?.len);
        try testing.expectEqual(40, (try c.pollEvent()).?.len);
        _ = try fs.recvAvailable(&sink);
    }
    try testing.expectEqual(warm, counting.allocs.load(.monotonic));
    try testing.expectEqual(warm_bytes, counting.bytes_total.load(.monotonic));
}
