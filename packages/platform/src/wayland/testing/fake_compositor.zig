//! A scriptable compositor end of a `socketpair`, for tests of the wire
//! layer and of everything built on it. Events are sent with the
//! generated `server` encoders (`wl.wl_callback.server.done(fc, ...)`),
//! which call `FakeCompositor.send`; requests are read back with `recv`
//! and decoded with the generated `decodeRequest`.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl_gen");
const socket = @import("../wire/socket.zig");
const marshal = @import("../wire/marshal.zig");
const FdQueue = @import("../wire/fdqueue.zig").FdQueue;

/// One request as received; `body` is valid until the next `recv`.
pub const Request = struct {
    obj: u32,
    opcode: u16,
    body: []const u32,
};

/// A global to advertise from `serveCore`.
pub const Global = struct {
    name: u32,
    interface: [:0]const u8,
    version: u32,
};

/// The compositor side of a socketpair.
pub const FakeCompositor = struct {
    gpa: std.mem.Allocator,
    sock: i32,
    /// The client end: pass it to `Connection.fromFd`, which takes it over.
    client_fd: i32,
    in: [64 * 1024]u8 align(4) = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    /// Fds received with requests.
    fds: FdQueue = .{},
    /// Requests `serveCore` did not answer itself, as (object, opcode).
    other: std.ArrayList(struct { u32, u16 }) = .empty,

    /// Makes a socketpair.
    pub fn init(gpa: std.mem.Allocator) !*FakeCompositor {
        const sp = try socket.pair();
        const fc = try gpa.create(FakeCompositor);
        fc.* = .{ .gpa = gpa, .sock = sp[0], .client_fd = sp[1] };
        return fc;
    }

    /// Closes the compositor end and frees `fc` (not `client_fd`).
    pub fn deinit(fc: *FakeCompositor) void {
        _ = linux.close(fc.sock);
        fc.fds.closeAll();
        fc.other.deinit(fc.gpa);
        fc.gpa.destroy(fc);
    }

    /// Sends one event now; the generated `server` encoders call this.
    pub fn send(fc: *FakeCompositor, obj: u32, opcode: u16, args: anytype, fds: []const i32) !void {
        var buf: [marshal.max_message]u8 align(4) = undefined;
        const n = try marshal.encode(&buf, obj, opcode, args);
        try fc.sendBytes(buf[0..n], fds);
    }

    /// Sends raw bytes with `fds` attached to the first byte.
    pub fn sendBytes(fc: *FakeCompositor, bytes: []const u8, fds: []const i32) !void {
        var off: usize = 0;
        var pass = fds;
        while (off < bytes.len) {
            off += try socket.sendMsg(fc.sock, bytes[off..], pass);
            pass = &.{};
        }
    }

    /// Encodes an event without sending it, for tests that split messages.
    pub fn encode(buf: []u8, obj: u32, opcode: u16, args: anytype) ![]u8 {
        return buf[0..try marshal.encode(buf, obj, opcode, args)];
    }

    /// Blocks until one whole request has arrived.
    pub fn recv(fc: *FakeCompositor) !Request {
        while (true) {
            const avail = fc.in_end - fc.in_start;
            if (avail >= 8) {
                const h = marshal.Header.read(fc.in[fc.in_start..][0..8]);
                if (h.size < 8 or h.size % 4 != 0) return error.Protocol;
                if (avail >= h.size) {
                    const body: []const u32 = @ptrCast(@alignCast(fc.in[fc.in_start + 8 .. fc.in_start + h.size]));
                    fc.in_start += h.size;
                    return .{ .obj = h.obj, .opcode = h.opcode, .body = body };
                }
            }
            if (fc.in_start > 0) {
                std.mem.copyForwards(u8, fc.in[0..avail], fc.in[fc.in_start..fc.in_end]);
                fc.in_start = 0;
                fc.in_end = avail;
            }
            fc.in_end += try socket.recvMsg(fc.sock, fc.in[fc.in_end..], &fc.fds, false);
        }
    }

    /// Plays a minimal compositor until `syncs` sync requests have been
    /// answered: `get_registry` gets `globals`, `sync` gets `done` and
    /// `delete_id`, and destructor-free requests are logged in `other`.
    pub fn serveCore(fc: *FakeCompositor, globals: []const Global, syncs: usize) !void {
        var answered: usize = 0;
        while (answered < syncs) {
            const r = try fc.recv();
            if (r.obj == 1) {
                switch (try wl.wl_display.decodeRequest(r.opcode, r.body, &fc.fds)) {
                    .sync => |s| {
                        try wl.wl_callback.server.done(fc, s.callback, 0);
                        try wl.wl_display.server.deleteId(fc, @enumFromInt(1), @intFromEnum(s.callback));
                        answered += 1;
                    },
                    .get_registry => |g| for (globals) |x| try wl.wl_registry.server.global(fc, g.registry, x.name, x.interface, x.version),
                }
            } else try fc.other.append(fc.gpa, .{ r.obj, r.opcode });
        }
    }

    /// `serveCore` for a thread; failures panic the test.
    pub fn serveCoreThread(fc: *FakeCompositor, globals: []const Global, syncs: usize) void {
        fc.serveCore(globals, syncs) catch |err| std.debug.panic("fake compositor: {s}", .{@errorName(err)});
    }
};
