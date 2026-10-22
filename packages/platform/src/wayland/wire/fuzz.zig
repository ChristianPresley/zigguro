//! Decoder fuzzing: random messages, with random fd counts, dispatched to
//! one object of every generated interface whose handler decodes events
//! with that interface's `decodeEvent`. Malformed input must give errors,
//! never crashes, leaks or hangs. `zig build fuzz-wl --fuzz` runs the
//! fuzz test; the seeded test keeps 1M messages in the regular test step.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl_gen");
const Connection = @import("connection.zig").Connection;
const FdQueue = @import("fdqueue.zig").FdQueue;
const socket = @import("socket.zig");
const testing = std.testing;

const interfaces = wl.interfaces;
/// Interface k gets id `first_id + k`.
const first_id = 2;

/// Records fds a decoder pops so the handler can close them.
const Popped = struct {
    q: *FdQueue,
    got: [8]i32 = undefined,
    n: usize = 0,

    pub fn pop(p: *Popped) ?i32 {
        const fd = p.q.pop() orelse return null;
        if (p.n == p.got.len) {
            _ = linux.close(fd);
            return -1;
        }
        p.got[p.n] = fd;
        p.n += 1;
        return fd;
    }
};

fn onEvent(_: *anyopaque, _: *Connection, obj: u32, opcode: u16, body: []const u32, fds: *FdQueue) anyerror!void {
    var popped: Popped = .{ .q = fds };
    defer for (popped.got[0..popped.n]) |fd| {
        _ = linux.close(fd);
    };
    inline for (interfaces, 0..) |I, k| {
        if (obj == first_id + k) {
            _ = I.decodeEvent(opcode, body, &popped) catch {};
            return;
        }
    }
}

var handler_ctx: u8 = 0;

const Harness = struct {
    c: *Connection,
    peer: i32,
    spare_fd: i32,

    fn init() !Harness {
        const sp = try socket.pair();
        errdefer _ = linux.close(sp[1]);
        const c = try Connection.fromFd(testing.allocator, testing.io, sp[0]);
        errdefer c.deinit();
        inline for (interfaces) |I| {
            const id = try c.newId(I, .{ .ctx = &handler_ctx, .on_event = onEvent });
            _ = id;
        }
        var pipe: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.SystemResources;
        _ = linux.close(pipe[1]);
        return .{ .c = c, .peer = sp[1], .spare_fd = pipe[0] };
    }

    fn deinit(h: *Harness) void {
        h.c.deinit();
        _ = linux.close(h.peer);
        _ = linux.close(h.spare_fd);
    }

    /// Turns `input` into messages in the receive buffer, then dispatches.
    /// Each message takes 4 control bytes: object, opcode, body words and
    /// fd count (with a flag to corrupt the size), then its body bytes.
    fn feed(h: *Harness, input: []const u8) void {
        const c = h.c;
        c.in_start = 0;
        c.in_end = 0;
        var i: usize = 0;
        while (i + 4 <= input.len) {
            const ctl = input[i..][0..4];
            i += 4;
            const obj: u32 = switch (ctl[0] % 8) {
                0 => 1,
                1 => 0x7fff,
                2 => 0xff000000 + @as(u32, ctl[0]),
                else => first_id + @as(u32, ctl[0] % @as(u32, interfaces.len)),
            };
            const words: usize = ctl[2] % 24;
            const size: u32 = if (ctl[3] & 0x80 != 0) ctl[2] else @intCast(8 + words * 4);
            if (c.in_end + 8 + words * 4 > c.in.len) break;
            const w1 = size << 16 | (ctl[1] % 12);
            std.mem.writeInt(u32, c.in[c.in_end..][0..4], obj, .native);
            std.mem.writeInt(u32, c.in[c.in_end + 4 ..][0..4], w1, .native);
            const body = c.in[c.in_end + 8 ..][0 .. words * 4];
            const take = @min(body.len, input.len - i);
            @memcpy(body[0..take], input[i..][0..take]);
            @memset(body[take..], 0);
            i += take;
            c.in_end += 8 + words * 4;
            var nfds = ctl[3] % 4;
            while (nfds > 0 and c.in_fds.free() > 0) : (nfds -= 1) {
                const d = socket.dupCloexec(h.spare_fd) catch break;
                c.in_fds.push(d) catch unreachable;
            }
        }
        // Dispatch until stuck; errors drop the rest, as a real client
        // would after closing the connection.
        while (true) {
            const n = c.dispatchPending() catch break;
            if (n == 0) break;
        }
        c.in_start = c.in_end;
        c.in_fds.closeAll();
        c.last_error = null;
    }
};

test "wayland dispatch survives 1M seeded random messages" {
    var h = try Harness.init();
    defer h.deinit();
    var prng: std.Random.DefaultPrng = .init(0x5eed_0227);
    const rand = prng.random();
    var buf: [4096]u8 = undefined;
    var messages: usize = 0;
    while (messages < 1_000_000) {
        rand.bytes(&buf);
        // Make most messages well formed so decoders run on their bodies.
        var i: usize = 0;
        while (i + 4 <= buf.len) : (i += 4 + (buf[i + 2] % 24) * 4) {
            if (buf[i + 3] & 0x80 != 0 and rand.boolean()) buf[i + 3] &= 0x7f;
            messages += 1;
        }
        h.feed(&buf);
    }
}

test "fuzz: wayland dispatch never crashes" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            var h = try Harness.init();
            defer h.deinit();
            var buf: [4096]u8 = undefined;
            const n = sm.slice(&buf);
            h.feed(buf[0..n]);
        }
    }.one, .{});
}
