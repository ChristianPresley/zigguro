//! A Wayland client connection: buffered sends with fds, framing of
//! received messages, the object table and dispatch to handlers, plus
//! `wl_display.error`, `delete_id` and `sync` roundtrips.
//!
//! Receiving and dispatching belong to one thread (the platform thread).
//! `send`, `flush`, `newId` and `destroyed` take a mutex, so a render
//! thread can commit surfaces while the platform thread dispatches.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const wl = @import("wl_gen");
const socket = @import("socket.zig");
const marshal = @import("marshal.zig");
const objects = @import("objects.zig");
const FdQueue = @import("fdqueue.zig").FdQueue;

const log = std.log.scoped(.wayland);

/// See `objects.Handler`.
pub const Handler = objects.Handler;

/// Connection errors. Handler errors pass through `dispatchPending` too.
pub const Error = error{
    /// Neither `WAYLAND_SOCKET` nor `XDG_RUNTIME_DIR` is set.
    NoRuntimeDir,
    /// `WAYLAND_SOCKET` is not an fd number.
    InvalidSocket,
    /// `roundtrip` waited longer than its timeout.
    Timeout,
} || socket.Error || marshal.Error || objects.Error;

/// The last `wl_display.error` the compositor sent.
pub const DisplayError = struct {
    object: u32,
    /// The interface of `object`, or "unknown".
    interface: []const u8,
    code: u32,
    /// Truncated to 255 bytes.
    message: []const u8,
};

const in_capacity = 64 * 1024;
const out_capacity = 64 * 1024;

/// The display object.
pub const display_id: wl.wl_display.Id = @enumFromInt(1);

/// A connection. Create with `connect` or `fromFd`.
pub const Connection = struct {
    gpa: std.mem.Allocator,
    io: Io,
    sock: i32,
    lock: Io.Mutex = .init,
    table: objects.Table = .{},

    out: [out_capacity]u8 align(4) = undefined,
    out_len: usize = 0,
    out_fds: [socket.max_fds]i32 = undefined,
    out_nfds: usize = 0,

    in: [in_capacity]u8 align(4) = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    in_fds: FdQueue = .{},

    /// Set when the compositor reported a protocol error.
    last_error: ?DisplayError = null,
    error_interface: [64]u8 = undefined,
    error_message: [255]u8 = undefined,

    /// Connects to the compositor: the fd in `WAYLAND_SOCKET` (removed from
    /// `env`, so children do not inherit it), else the socket
    /// `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` (`WAYLAND_DISPLAY` may be an
    /// absolute path; it defaults to `wayland-0`).
    pub fn connect(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map) Error!*Connection {
        if (env.get("WAYLAND_SOCKET")) |s| {
            const fd = std.fmt.parseInt(i32, s, 10) catch return error.InvalidSocket;
            if (fd < 0) return error.InvalidSocket;
            _ = env.swapRemove("WAYLAND_SOCKET");
            try socket.setCloexec(fd);
            return fromFd(gpa, io, fd);
        }
        const name = env.get("WAYLAND_DISPLAY") orelse "wayland-0";
        var buf: [108]u8 = undefined;
        const path = if (std.fs.path.isAbsolute(name)) name else blk: {
            const dir = env.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
            break :blk std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return error.NameTooLong;
        };
        const fd = try socket.connectPath(path);
        errdefer _ = linux.close(fd);
        return fromFd(gpa, io, fd);
    }

    /// Wraps a connected socket; the connection owns `fd` once this
    /// succeeds.
    pub fn fromFd(gpa: std.mem.Allocator, io: Io, fd: i32) Error!*Connection {
        const c = try gpa.create(Connection);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .sock = fd };
        errdefer c.table.deinit(gpa);
        const id = try c.table.alloc(gpa, objects.infoOf(wl.wl_display), 1, null);
        std.debug.assert(id == 1);
        return c;
    }

    /// Closes the socket and every fd still held, and frees `c`.
    pub fn deinit(c: *Connection) void {
        _ = linux.close(c.sock);
        c.in_fds.closeAll();
        for (c.out_fds[0..c.out_nfds]) |fd| _ = linux.close(fd);
        c.table.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    /// The socket, to poll for input (`fd` in the design; named so that
    /// locals called `fd` do not shadow it).
    pub fn pollFd(c: *const Connection) i32 {
        return c.sock;
    }

    /// Allocates an id for a new object of interface `I` at its highest
    /// known version. Pass it to the request that creates the object.
    pub fn newId(c: *Connection, comptime I: type, handler: ?Handler) Error!I.Id {
        return c.newIdVersion(I, I.version, handler);
    }

    /// Like `newId` with an explicit version: the bound version for
    /// globals, the parent's version (`version(parent)`) for the rest.
    pub fn newIdVersion(c: *Connection, comptime I: type, ver: u32, handler: ?Handler) Error!I.Id {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        return @enumFromInt(try c.table.alloc(c.gpa, objects.infoOf(I), ver, handler));
    }

    /// Sets or clears the handler of `obj` (for example of an object an
    /// event created, which starts without one).
    pub fn setHandler(c: *Connection, obj: u32, handler: ?Handler) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.table.get(obj)) |o| o.handler = handler;
    }

    /// The version of `obj`, or 0 if it does not exist.
    pub fn version(c: *Connection, obj: u32) u32 {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        return if (c.table.get(obj)) |o| o.version else 0;
    }

    /// Debug check from generated encoders: `obj` must be at least
    /// version `since` for the request being sent.
    pub fn checkSince(c: *Connection, obj: u32, since: u32) void {
        const v = c.version(obj);
        if (v != 0 and v < since) std.debug.panic("wayland: request needs version {d}, object {d} has {d}", .{ since, obj, v });
    }

    /// Called by generated encoders after a destructor request.
    pub fn destroyed(c: *Connection, obj: u32) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        c.table.destroy(obj);
    }

    /// Queues a request; generated encoders call this. The fds are
    /// duplicated, so the caller may close its own copies at once.
    pub fn send(c: *Connection, obj: u32, opcode: u16, args: anytype, fds: []const i32) Error!void {
        const size = 8 + marshal.bodySize(args);
        if (size > marshal.max_message) return error.MessageTooLarge;
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.out_len + size > out_capacity or c.out_nfds + fds.len > socket.max_fds) try c.flushLocked();
        var dups: [socket.max_fds]i32 = undefined;
        for (fds, 0..) |f, i| dups[i] = socket.dupCloexec(f) catch |err| {
            for (dups[0..i]) |d| _ = linux.close(d);
            return err;
        };
        _ = marshal.encode(c.out[c.out_len..], obj, opcode, args) catch unreachable; // size checked above
        c.out_len += size;
        @memcpy(c.out_fds[c.out_nfds..][0..fds.len], dups[0..fds.len]);
        c.out_nfds += fds.len;
    }

    /// Writes every queued request to the socket.
    pub fn flush(c: *Connection) Error!void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        try c.flushLocked();
    }

    fn flushLocked(c: *Connection) Error!void {
        var off: usize = 0;
        while (off < c.out_len) {
            const n = try socket.sendMsg(c.sock, c.out[off..c.out_len], c.out_fds[0..c.out_nfds]);
            for (c.out_fds[0..c.out_nfds]) |f| _ = linux.close(f);
            c.out_nfds = 0;
            off += n;
        }
        c.out_len = 0;
    }

    /// Reads what the socket has without blocking; returns the byte count
    /// (0 when nothing is there, or when buffered messages must be
    /// dispatched first).
    pub fn readSocket(c: *Connection) Error!usize {
        if (c.in_start == c.in_end) {
            c.in_start = 0;
            c.in_end = 0;
        } else if (c.in_start > 0) {
            const rest = c.in_end - c.in_start;
            std.mem.copyForwards(u8, c.in[0..rest], c.in[c.in_start..c.in_end]);
            c.in_start = 0;
            c.in_end = rest;
        }
        if (c.in_end == in_capacity or c.in_fds.free() < socket.max_fds) return 0;
        const n = socket.recvMsg(c.sock, c.in[c.in_end..], &c.in_fds, true) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
        c.in_end += n;
        return n;
    }

    /// Dispatches every complete message in the buffer; returns how many.
    /// A message whose fds have not all arrived waits for the next read.
    pub fn dispatchPending(c: *Connection) anyerror!usize {
        var count: usize = 0;
        while (c.in_end - c.in_start >= 8) {
            const h = marshal.Header.read(c.in[c.in_start..][0..8]);
            if (h.size < 8 or h.size % 4 != 0) return error.Protocol;
            if (c.in_end - c.in_start < h.size) break;
            if (h.size > marshal.max_message) log.debug("{d}-byte message for object {d}", .{ h.size, h.obj });
            const body: []const u32 = @ptrCast(@alignCast(c.in[c.in_start + 8 .. c.in_start + h.size]));

            if (h.obj == 1) {
                c.in_start += h.size;
                count += 1;
                try c.displayEvent(h.opcode, body);
                continue;
            }
            const o: objects.Object = blk: {
                c.lock.lockUncancelable(c.io);
                defer c.lock.unlock(c.io);
                break :blk if (c.table.get(h.obj)) |p| p.* else .{};
            };
            if (o.state == .free) {
                // Unknown object: its fd count is unknown too.
                log.debug("event {d} for unknown object {d}", .{ h.opcode, h.obj });
                c.in_start += h.size;
                count += 1;
                continue;
            }
            if (h.opcode >= o.info.event_fds.len) return error.Protocol;
            const nfds = o.info.event_fds[h.opcode];
            if (c.in_fds.count() < nfds) break;
            c.in_start += h.size;
            count += 1;
            if (o.state == .zombie) {
                c.in_fds.closeN(nfds);
                continue;
            }
            if (try o.info.created(h.opcode, body)) |made| {
                c.lock.lockUncancelable(c.io);
                defer c.lock.unlock(c.io);
                try c.table.insertServer(c.gpa, made.id, made.info, o.version);
            }
            if (o.handler) |hd| {
                const before = c.in_fds.count();
                defer {
                    const used = before -| c.in_fds.count();
                    if (used < nfds) c.in_fds.closeN(nfds - used);
                }
                try hd.on_event(hd.ctx, c, h.obj, h.opcode, body, &c.in_fds);
            } else c.in_fds.closeN(nfds);
            if (o.info.event_destructors[h.opcode]) c.destroyed(h.obj);
        }
        return count;
    }

    fn displayEvent(c: *Connection, opcode: u16, body: []const u32) Error!void {
        var no_fds: FdQueue = .{};
        const ev = wl.wl_display.decodeEvent(opcode, body, &no_fds) catch return error.Protocol;
        switch (ev) {
            .@"error" => |e| {
                const obj: u32 = e.object_id;
                const iface = blk: {
                    c.lock.lockUncancelable(c.io);
                    defer c.lock.unlock(c.io);
                    break :blk if (c.table.get(obj)) |o| o.info.name else "unknown";
                };
                const in_len = @min(iface.len, c.error_interface.len);
                @memcpy(c.error_interface[0..in_len], iface[0..in_len]);
                const msg_len = @min(e.message.len, c.error_message.len);
                @memcpy(c.error_message[0..msg_len], e.message[0..msg_len]);
                c.last_error = .{ .object = obj, .interface = c.error_interface[0..in_len], .code = e.code, .message = c.error_message[0..msg_len] };
                log.info("{s}@{d}: error {d}: {s}", .{ iface, obj, e.code, e.message });
                return error.Protocol;
            },
            .delete_id => |d| {
                c.lock.lockUncancelable(c.io);
                defer c.lock.unlock(c.io);
                c.table.deleteId(d.id) catch log.debug("delete_id for unknown id {d}", .{d.id});
            },
        }
    }

    /// Blocks until the socket is readable or `timeout_ns` passes; false
    /// on timeout.
    pub fn waitReadable(c: *Connection, timeout_ns: ?u64) bool {
        var pfd = [1]linux.pollfd{.{ .fd = c.sock, .events = linux.POLL.IN, .revents = 0 }};
        var ts: linux.timespec = undefined;
        const tsp: ?*linux.timespec = if (timeout_ns) |ns| blk: {
            ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            break :blk &ts;
        } else null;
        while (true) {
            const rc = linux.ppoll(&pfd, 1, tsp, null);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc > 0,
                .INTR => continue,
                else => return true, // let the read report it
            }
        }
    }

    /// Sends `wl_display.sync` and dispatches until its callback fires:
    /// every earlier request has then been handled by the compositor.
    pub fn roundtrip(c: *Connection) anyerror!void {
        return c.roundtripTimeout(null);
    }

    /// `roundtrip` that gives up with `error.Timeout`.
    pub fn roundtripTimeout(c: *Connection, timeout_ns: ?u64) anyerror!void {
        var done = false;
        const cb = try c.newId(wl.wl_callback, .{ .ctx = &done, .on_event = onSyncDone });
        errdefer c.setHandler(@intFromEnum(cb), null);
        try wl.wl_display.sync(c, display_id, cb);
        try c.flush();
        const start = Io.Clock.awake.now(c.io).nanoseconds;
        while (true) {
            _ = try c.dispatchPending();
            if (done) return;
            var left: ?u64 = null;
            if (timeout_ns) |t| {
                const spent: u64 = @intCast(@max(0, Io.Clock.awake.now(c.io).nanoseconds - start));
                if (spent >= t) return error.Timeout;
                left = t - spent;
            }
            if (!c.waitReadable(left)) continue;
            _ = try c.readSocket();
        }
    }

    fn onSyncDone(ctx: *anyopaque, _: *Connection, _: u32, _: u16, _: []const u32, _: *FdQueue) anyerror!void {
        const done: *bool = @ptrCast(ctx);
        done.* = true;
    }
};

const testing = std.testing;
const fake = @import("../testing/fake_compositor.zig");

const Pair = struct {
    c: *Connection,
    fc: *fake.FakeCompositor,

    fn init() !Pair {
        const fc = try fake.FakeCompositor.init(testing.allocator);
        errdefer fc.deinit();
        return .{ .c = try Connection.fromFd(testing.allocator, testing.io, fc.client_fd), .fc = fc };
    }

    fn deinit(p: Pair) void {
        p.c.deinit();
        p.fc.deinit();
    }

    /// Reads and dispatches until the socket is empty. (One `recvmsg`
    /// stops where ancillary data starts, so this can take several.)
    fn pump(p: Pair) !usize {
        var total: usize = 0;
        while (true) {
            const n = try p.c.readSocket();
            total += try p.c.dispatchPending();
            if (n == 0) return total;
        }
    }
};

fn makePipe() ![2]i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.SystemResources;
    return fds;
}

fn isOpen(f: i32) bool {
    return linux.errno(linux.fcntl(f, linux.F.GETFD, 0)) == .SUCCESS;
}

test "requests: every argument type survives encode and decode" {
    const p = try Pair.init();
    defer p.deinit();
    const c = p.c;
    const reg = try c.newId(wl.wl_registry, null);
    try wl.wl_registry.bind(c, reg, 7, "wl_shm", 1, 3);
    const pool = try c.newId(wl.wl_shm_pool, null);
    const pipe = try makePipe();
    try wl.wl_shm.createPool(c, @enumFromInt(3), pool, pipe[0], 4096);
    for (pipe) |f| _ = linux.close(f); // send duplicated it
    try wl.wl_surface.attach(c, @enumFromInt(9), null, -3, 4);
    try wl.wl_data_offer.accept(c, @enumFromInt(11), 42, null);
    try wl.wl_data_offer.accept(c, @enumFromInt(11), 43, "text/plain");
    try c.flush();

    const fc = p.fc;
    var r = try fc.recv();
    try testing.expectEqual(@intFromEnum(reg), r.obj);
    const b = (try wl.wl_registry.decodeRequest(r.opcode, r.body, &fc.fds)).bind;
    try testing.expectEqual(7, b.name);
    try testing.expectEqualStrings("wl_shm", b.interface);
    try testing.expectEqual(1, b.interface_version);
    try testing.expectEqual(3, b.id);
    r = try fc.recv();
    const cp = (try wl.wl_shm.decodeRequest(r.opcode, r.body, &fc.fds)).create_pool;
    try testing.expectEqual(pool, cp.id);
    try testing.expectEqual(4096, cp.size);
    try testing.expect(isOpen(cp.fd));
    _ = linux.close(cp.fd);
    r = try fc.recv();
    const at = (try wl.wl_surface.decodeRequest(r.opcode, r.body, &fc.fds)).attach;
    try testing.expectEqual(null, at.buffer);
    try testing.expectEqual(-3, at.x);
    try testing.expectEqual(4, at.y);
    r = try fc.recv();
    const a1 = (try wl.wl_data_offer.decodeRequest(r.opcode, r.body, &fc.fds)).accept;
    try testing.expectEqual(42, a1.serial);
    try testing.expectEqual(null, a1.mime_type);
    r = try fc.recv();
    const a2 = (try wl.wl_data_offer.decodeRequest(r.opcode, r.body, &fc.fds)).accept;
    try testing.expectEqualStrings("text/plain", a2.mime_type.?);
    try testing.expectEqual(0, fc.fds.count());
}

const EventLog = struct {
    kb: u32 = 0,
    ptr: u32 = 0,
    seat: u32 = 0,
    dev: u32 = 0,
    serial: u32 = 0,
    keys: [2]u32 = .{ 0, 0 },
    keymap_size: u32 = 0,
    keymap_fd_open: bool = false,
    x: f64 = 0,
    y: f64 = 0,
    caps: wl.wl_seat.Capability = .{},
    offer: u32 = 0,
    mime: [32]u8 = undefined,
    mime_len: usize = 0,

    fn handler(l: *EventLog) Handler {
        return .{ .ctx = l, .on_event = on };
    }

    fn on(ctx: *anyopaque, conn: *Connection, obj: u32, opcode: u16, body: []const u32, fds: *FdQueue) anyerror!void {
        const l: *EventLog = @ptrCast(@alignCast(ctx));
        if (obj == l.kb) {
            switch (try wl.wl_keyboard.decodeEvent(opcode, body, fds)) {
                .enter => |e| {
                    l.serial = e.serial;
                    @memcpy(std.mem.asBytes(&l.keys), e.keys[0..8]);
                },
                .keymap => |k| {
                    l.keymap_size = k.size;
                    l.keymap_fd_open = isOpen(k.fd);
                    _ = linux.close(k.fd);
                },
                else => {},
            }
        } else if (obj == l.ptr) {
            const m = (try wl.wl_pointer.decodeEvent(opcode, body, fds)).motion;
            l.x = m.surface_x.toF64();
            l.y = m.surface_y.toF64();
        } else if (obj == l.seat) {
            l.caps = (try wl.wl_seat.decodeEvent(opcode, body, fds)).capabilities.capabilities;
        } else if (obj == l.dev) {
            l.offer = @intFromEnum((try wl.wl_data_device.decodeEvent(opcode, body, fds)).data_offer.id);
            conn.setHandler(l.offer, l.handler());
        } else if (obj == l.offer) {
            const o = (try wl.wl_data_offer.decodeEvent(opcode, body, fds)).offer;
            l.mime_len = o.mime_type.len;
            @memcpy(l.mime[0..o.mime_type.len], o.mime_type);
        }
    }
};

test "events: every argument type, fds and server-created objects" {
    const p = try Pair.init();
    defer p.deinit();
    var l: EventLog = .{};
    const kb = try p.c.newId(wl.wl_keyboard, l.handler());
    const ptr = try p.c.newId(wl.wl_pointer, l.handler());
    const seat = try p.c.newId(wl.wl_seat, l.handler());
    const dev = try p.c.newId(wl.wl_data_device, l.handler());
    l.kb = @intFromEnum(kb);
    l.ptr = @intFromEnum(ptr);
    l.seat = @intFromEnum(seat);
    l.dev = @intFromEnum(dev);

    const fc = p.fc;
    const keys = [2]u32{ 30, 48 };
    try wl.wl_keyboard.server.enter(fc, kb, 5, @enumFromInt(9), std.mem.asBytes(&keys));
    const pipe = try makePipe();
    defer for (pipe) |f| {
        _ = linux.close(f);
    };
    try wl.wl_keyboard.server.keymap(fc, kb, .xkb_v1, pipe[0], 100);
    try wl.wl_pointer.server.motion(fc, ptr, 1, .fromF64(1.5), .fromF64(-2.25));
    try wl.wl_seat.server.capabilities(fc, seat, .{ .pointer = true, .keyboard = true });
    const offer: wl.wl_data_offer.Id = @enumFromInt(objects.server_base);
    try wl.wl_data_device.server.dataOffer(fc, dev, offer);
    try wl.wl_data_offer.server.offer(fc, offer, "text/plain");

    try testing.expectEqual(6, try p.pump());
    try testing.expectEqual(5, l.serial);
    try testing.expectEqual(keys, l.keys);
    try testing.expectEqual(100, l.keymap_size);
    try testing.expect(l.keymap_fd_open);
    try testing.expectEqual(1.5, l.x);
    try testing.expectEqual(-2.25, l.y);
    try testing.expect(l.caps.pointer and l.caps.keyboard and !l.caps.touch);
    try testing.expectEqual(objects.server_base, l.offer);
    try testing.expectEqualStrings("text/plain", l.mime[0..l.mime_len]);
    try testing.expectEqual(0, p.c.in_fds.count());
}

test "fd arrives before bytes, and after bytes" {
    const p = try Pair.init();
    defer p.deinit();
    var l: EventLog = .{};
    const kb = try p.c.newId(wl.wl_keyboard, l.handler());
    l.kb = @intFromEnum(kb);
    const pipe = try makePipe();
    defer for (pipe) |f| {
        _ = linux.close(f);
    };
    var buf: [64]u8 align(4) = undefined;
    const msg = try fake.FakeCompositor.encode(&buf, @intFromEnum(kb), 0, .{ wl.wl_keyboard.KeymapFormat.xkb_v1, @as(u32, 77) });

    // The fd rides on the first 4 bytes; the rest follows later.
    try p.fc.sendBytes(msg[0..4], &.{pipe[0]});
    try testing.expectEqual(0, try p.pump());
    try p.fc.sendBytes(msg[4..], &.{});
    try testing.expectEqual(1, try p.pump());
    try testing.expectEqual(77, l.keymap_size);

    // All bytes first; the message waits for its fd.
    l.keymap_size = 0;
    try p.fc.sendBytes(msg[0 .. msg.len - 4], &.{});
    try testing.expectEqual(0, try p.pump());
    try p.fc.sendBytes(msg[msg.len - 4 ..], &.{pipe[1]});
    try testing.expectEqual(1, try p.pump());
    try testing.expectEqual(77, l.keymap_size);
    try testing.expect(l.keymap_fd_open);
}

test "partial header across reads" {
    const p = try Pair.init();
    defer p.deinit();
    var l: EventLog = .{};
    l.ptr = @intFromEnum(try p.c.newId(wl.wl_pointer, l.handler()));
    var buf: [64]u8 align(4) = undefined;
    const msg = try fake.FakeCompositor.encode(&buf, l.ptr, 2, .{ @as(u32, 1), Fixed.fromInt(3), Fixed.fromInt(4) });
    for (msg[0 .. msg.len - 1], 0..) |_, i| {
        try p.fc.sendBytes(msg[i..][0..1], &.{});
        try testing.expectEqual(0, try p.pump());
    }
    try p.fc.sendBytes(msg[msg.len - 1 ..], &.{});
    try testing.expectEqual(1, try p.pump());
    try testing.expectEqual(3, l.x);
    try testing.expectEqual(4, l.y);
}

const Fixed = wl.Fixed;

test "delete_id reuse ordering; events for zombies are dropped and their fds closed" {
    const p = try Pair.init();
    defer p.deinit();
    var l: EventLog = .{};
    const a = try p.c.newId(wl.wl_callback, null);
    const kb = try p.c.newId(wl.wl_keyboard, l.handler());
    l.kb = @intFromEnum(kb);
    try testing.expectEqual(2, @intFromEnum(a));
    try wl.wl_callback.server.done(p.fc, a, 1);
    try testing.expectEqual(1, try p.pump());
    // a is a zombie: its id is not reused yet.
    try testing.expectEqual(4, @intFromEnum(try p.c.newId(wl.wl_callback, null)));

    // A keyboard released by the client still gets a keymap in flight.
    try wl.wl_keyboard.release(p.c, kb);
    const pipe = try makePipe();
    defer _ = linux.close(pipe[1]);
    try wl.wl_keyboard.server.keymap(p.fc, kb, .xkb_v1, pipe[0], 5);
    _ = linux.close(pipe[0]);
    try testing.expectEqual(1, try p.pump());
    try testing.expectEqual(0, l.keymap_size);
    try testing.expectEqual(0, p.c.in_fds.count());
    // The duplicate the client received was closed: the pipe has no reader.
    try testing.expectEqual(linux.E.PIPE, linux.errno(linux.write(pipe[1], "x", 1)));

    try wl.wl_display.server.deleteId(p.fc, display_id, @intFromEnum(a));
    try wl.wl_display.server.deleteId(p.fc, display_id, @intFromEnum(kb));
    try testing.expectEqual(2, try p.pump());
    try testing.expectEqual(@intFromEnum(kb), @intFromEnum(try p.c.newId(wl.wl_callback, null)));
    try testing.expectEqual(@intFromEnum(a), @intFromEnum(try p.c.newId(wl.wl_callback, null)));
    try testing.expectEqual(5, @intFromEnum(try p.c.newId(wl.wl_callback, null)));
}

test "MSG_CTRUNC is a protocol error" {
    const p = try Pair.init();
    defer p.deinit();
    const pipe = try makePipe();
    defer for (pipe) |f| {
        _ = linux.close(f);
    };
    // 40 fds in one message: more than the 28 the receiver has room for.
    var fds: [40]i32 = @splat(pipe[0]);
    const data_len = fds.len * 4;
    var control: [@sizeOf(linux.cmsghdr) + data_len]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const h: *linux.cmsghdr = @ptrCast(&control);
    h.* = .{ .len = control.len, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
    @memcpy(control[@sizeOf(linux.cmsghdr)..], std.mem.sliceAsBytes(&fds));
    var iov = [1]std.posix.iovec_const{.{ .base = "abcd", .len = 4 }};
    const msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sendmsg(p.fc.sock, &msg, 0)));
    try testing.expectError(error.Protocol, p.c.readSocket());
    p.c.in_fds.closeAll();
}

test "display.error surfaces with the object's interface" {
    const p = try Pair.init();
    defer p.deinit();
    const reg = try p.c.newId(wl.wl_registry, null);
    try wl.wl_display.server.@"error"(p.fc, display_id, @intFromEnum(reg), 3, "bad bind");
    try testing.expectError(error.Protocol, p.pump());
    const e = p.c.last_error.?;
    try testing.expectEqual(@intFromEnum(reg), e.object);
    try testing.expectEqualStrings("wl_registry", e.interface);
    try testing.expectEqual(3, e.code);
    try testing.expectEqualStrings("bad bind", e.message);
}

test "EOF is ConnectionLost; malformed sizes are protocol errors" {
    var p = try Pair.init();
    defer p.c.deinit();
    const bad = [2]u32{ 5, (6 << 16) | 0 };
    try p.fc.sendBytes(std.mem.asBytes(&bad), &.{});
    p.fc.deinit();
    try testing.expectError(error.Protocol, p.pump());
    p.c.in_start = p.c.in_end;
    try testing.expectError(error.ConnectionLost, p.c.readSocket());
}

test "registry: roundtrip collects globals, bind negotiates versions, removal callbacks" {
    const p = try Pair.init();
    defer p.deinit();
    const globals = [_]fake.Global{
        .{ .name = 1, .interface = "wl_compositor", .version = 6 },
        .{ .name = 2, .interface = "wl_seat", .version = 9 },
        .{ .name = 3, .interface = "wl_output", .version = 2 },
    };
    const t = try std.Thread.spawn(.{}, fake.FakeCompositor.serveCoreThread, .{ p.fc, &globals, 1 });
    const reg = try Registry.init(p.c);
    t.join();
    defer reg.deinit();
    try testing.expectEqual(3, reg.globals.items.len);
    try testing.expectEqual(6, reg.find("wl_compositor").?.version);

    const comp = (try reg.bind(wl.wl_compositor, 4, 5, null)).?;
    try testing.expectEqual(5, p.c.version(@intFromEnum(comp)));
    const seat = (try reg.bind(wl.wl_seat, 1, 99, null)).?;
    try testing.expectEqual(wl.wl_seat.version, p.c.version(@intFromEnum(seat)));
    try testing.expectEqual(null, try reg.bind(wl.wl_output, 3, 4, null));
    try testing.expectEqual(null, try reg.bind(wl.wl_shm, 1, 1, null));
    try p.c.flush();
    const r = try p.fc.recv();
    const b = (try wl.wl_registry.decodeRequest(r.opcode, r.body, &p.fc.fds)).bind;
    try testing.expectEqualStrings("wl_compositor", b.interface);
    try testing.expectEqual(5, b.interface_version);

    const Removed = struct {
        name: u32 = 0,
        fn on(ctx: *anyopaque, g: registry.Global) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.name = g.name;
        }
    };
    var removed: Removed = .{};
    reg.onGlobalRemove(.{ .ctx = &removed, .on_remove = Removed.on });
    try wl.wl_registry.server.globalRemove(p.fc, reg.id, 3);
    _ = try p.pump();
    try testing.expectEqual(3, removed.name);
    try testing.expectEqual(null, reg.find("wl_output"));
}

const registry = @import("registry.zig");
const Registry = registry.Registry;

test "roundtrip times out when the compositor is silent" {
    const p = try Pair.init();
    defer p.deinit();
    try testing.expectError(error.Timeout, p.c.roundtripTimeout(20 * std.time.ns_per_ms));
}

/// Counts allocations.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
    }
};

test "100k events and requests allocate nothing after warm-up" {
    var counting: CountingAllocator = .{ .child = testing.allocator };
    const fc = try fake.FakeCompositor.init(testing.allocator);
    defer fc.deinit();
    const c = try Connection.fromFd(counting.allocator(), testing.io, fc.client_fd);
    defer c.deinit();
    var l: EventLog = .{};
    l.ptr = @intFromEnum(try c.newId(wl.wl_pointer, l.handler()));
    const surf = try c.newId(wl.wl_surface, null);
    const warm = counting.count;
    var batch: [1000 * 20]u8 align(4) = undefined;
    var len: usize = 0;
    while (len < batch.len) len += (try fake.FakeCompositor.encode(batch[len..], l.ptr, 2, .{ @as(u32, 1), Fixed.fromInt(1), Fixed.fromInt(2) })).len;
    var seen: usize = 0;
    for (0..100) |_| {
        try fc.sendBytes(&batch, &.{});
        var got: usize = 0;
        while (got < 1000) got += try (Pair{ .c = c, .fc = fc }).pump();
        seen += got;
        try wl.wl_surface.damage(c, surf, 0, 0, 1, 1);
        try c.flush();
        _ = try fc.recv();
    }
    try testing.expectEqual(100_000, seen);
    try testing.expectEqual(warm, counting.count);
}

test "weston: connect, registry lists wl_compositor, roundtrip under 5 ms" {
    var w = WestonForTest.start() catch return error.SkipZigTest;
    defer w.stop();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", w.dir_path);
    try env.put("WAYLAND_DISPLAY", "zg-test");
    const c = try Connection.connect(testing.allocator, testing.io, &env);
    defer c.deinit();
    const reg = try Registry.init(c);
    defer reg.deinit();
    try testing.expect(reg.find("wl_compositor") != null);
    const t0 = Io.Clock.awake.now(testing.io).nanoseconds;
    try c.roundtrip();
    const took = Io.Clock.awake.now(testing.io).nanoseconds - t0;
    try testing.expect(took < 5 * std.time.ns_per_ms);
}

/// A headless weston on a private runtime dir; absent weston skips.
const WestonForTest = struct {
    tmp: testing.TmpDir,
    path_buf: [Io.Dir.max_path_bytes]u8,
    dir_path: []const u8,
    child: std.process.Child,

    fn start() !WestonForTest {
        var w: WestonForTest = undefined;
        w.tmp = testing.tmpDir(.{});
        errdefer w.tmp.cleanup();
        const n = try w.tmp.dir.realPath(testing.io, &w.path_buf);
        w.dir_path = w.path_buf[0..n];
        var env: std.process.Environ.Map = .init(testing.allocator);
        defer env.deinit();
        try env.put("XDG_RUNTIME_DIR", w.dir_path);
        w.child = try std.process.spawn(testing.io, .{
            .argv = &.{ "weston", "--backend=headless", "--socket=zg-test", "--idle-time=0", "--no-config" },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        errdefer w.child.kill(testing.io);
        var tries: usize = 0;
        while (tries < 200) : (tries += 1) {
            if (w.tmp.dir.access(testing.io, "zg-test", .{})) |_| return w else |_| {}
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.WestonDidNotStart;
    }

    fn stop(w: *WestonForTest) void {
        w.child.kill(testing.io);
        w.tmp.cleanup();
    }
};
