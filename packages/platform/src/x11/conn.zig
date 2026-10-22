//! An X11 client connection in pure Zig: local socket (abstract, then
//! filesystem), MIT-MAGIC-COOKIE-1 authentication, setup, request
//! serialization with fd passing, 64-bit sequence tracking over the
//! 16-bit wire sequence, reply and error matching, an event queue (with
//! GenericEvent lengths), extension discovery and BIG-REQUESTS.
//!
//! The platform thread owns reading (`reply`, `pollEvent`, `waitEvent`).
//! `request`, `flush` and `newXid` lock, so a render thread can send.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const auth = @import("auth.zig");
const setup_mod = @import("setup.zig");
const proto = @import("proto.zig");
const ext = @import("ext.zig");
const atoms = @import("atoms.zig");
const socket = @import("../wayland/wire/socket.zig");
const FdQueue = @import("../wayland/wire/fdqueue.zig").FdQueue;

const log = std.log.scoped(.x11);

/// Connection errors.
pub const Error = error{
    /// `DISPLAY` is unset or malformed.
    InvalidDisplay,
    /// Remote (TCP) displays are not supported.
    Unsupported,
    /// No X server listens on the display's socket.
    ConnectFailed,
    /// The server closed the connection.
    ConnectionLost,
    /// The server sent something we cannot parse.
    Protocol,
    /// The request was answered with an X error (see `last_error`).
    X11Error,
    /// The XID range is used up.
    XidsExhausted,
    RequestTooLarge,
    SetupFailed,
    AuthenticationRequired,
    SystemResources,
    OutOfMemory,
};

/// A request's sequence number, typed by the request.
pub fn Cookie(comptime R: type) type {
    return struct {
        /// The request this cookie answers.
        pub const Request = R;
        seq: u64,
    };
}

const Pending = struct { seq: u64, discard: bool };

const Stored = struct { seq: u64, is_error: bool, bytes: std.ArrayList(u8) };

/// Options for `connect`.
pub const Options = struct {
    /// Overrides `DISPLAY`.
    display: ?[]const u8 = null,
    /// Query and enable the startup extensions (BIG-REQUESTS, XKB, ...).
    query_extensions: bool = true,
};

/// A connection.
pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    sock: i32,
    setup_arena: std.heap.ArenaAllocator,
    /// The server's setup reply.
    setup: setup_mod.Setup = undefined,
    /// The screen from `DISPLAY`.
    screen_index: u32 = 0,

    lock: Io.Mutex = .init,
    out: std.ArrayList(u8) = .empty,
    out_fds: [socket.max_fds]i32 = undefined,
    out_nfds: usize = 0,
    seq_sent: u64 = 0,
    /// The last request that will produce a reply.
    seq_answered_by: u64 = 0,
    pending: std.ArrayList(Pending) = .empty,
    pending_head: usize = 0,

    in: std.ArrayList(u8) = .empty,
    in_start: usize = 0,
    in_fds: FdQueue = .{},
    seq_read: u64 = 0,
    stored: std.ArrayList(Stored) = .empty,
    spare: std.ArrayList(std.ArrayList(u8)) = .empty,
    current_reply: std.ArrayList(u8) = .empty,
    events: std.ArrayList(u8) = .empty,
    events_start: usize = 0,
    current_event: std.ArrayList(u8) = .empty,

    /// The last error: for a failed `reply`, or an unchecked request.
    last_error: ?proto.XError = null,
    /// Errors for requests nobody waited on.
    async_errors: usize = 0,

    xid_next: u32 = 0,
    xid_inc: u32 = 1,
    /// Startup extensions, by `ext.startup` index.
    extensions: [ext.startup.len]?ext.ExtInfo = @splat(null),
    /// In 4-byte units; raised by BIG-REQUESTS.
    max_request_words: u32 = 0,
    big_requests: bool = false,

    /// Connects to `opts.display` or `DISPLAY` from `env`.
    pub fn connect(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, opts: Options) Error!*Conn {
        const name = opts.display orelse env.get("DISPLAY") orelse return error.InvalidDisplay;
        const d = try auth.parseDisplay(name);
        if (!d.isLocal()) return error.Unsupported;
        const fd = try connectLocal(d.display);
        errdefer _ = linux.close(fd);

        var auth_bytes: ?[]u8 = null;
        defer if (auth_bytes) |b| gpa.free(b);
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const xauth_path: ?[]const u8 = env.get("XAUTHORITY") orelse if (env.get("HOME")) |h|
            std.fmt.bufPrint(&path_buf, "{s}/.Xauthority", .{h}) catch null
        else
            null;
        var uts: linux.utsname = undefined;
        _ = linux.uname(&uts);
        const host = std.mem.sliceTo(&uts.nodename, 0);
        const cookie: ?auth.Cookie = if (xauth_path) |p| try auth.readXauthority(gpa, io, p, d.display, host, &auth_bytes) else null;

        const c = try fromFd(gpa, io, fd, cookie, opts);
        c.screen_index = if (d.screen < c.setup.screens.len) d.screen else 0;
        return c;
    }

    /// Runs setup over a connected socket (owned by the connection once
    /// this succeeds).
    pub fn fromFd(gpa: std.mem.Allocator, io: Io, fd: i32, cookie: ?auth.Cookie, opts: Options) Error!*Conn {
        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .sock = fd, .setup_arena = .init(gpa) };
        errdefer c.freeState();
        try c.handshake(cookie);
        if (opts.query_extensions) try c.queryStartupExtensions();
        return c;
    }

    fn freeState(c: *Conn) void {
        c.setup_arena.deinit();
        c.out.deinit(c.gpa);
        c.pending.deinit(c.gpa);
        c.in.deinit(c.gpa);
        for (c.stored.items) |*s| s.bytes.deinit(c.gpa);
        c.stored.deinit(c.gpa);
        for (c.spare.items) |*s| s.deinit(c.gpa);
        c.spare.deinit(c.gpa);
        c.current_reply.deinit(c.gpa);
        c.events.deinit(c.gpa);
        c.current_event.deinit(c.gpa);
        c.in_fds.closeAll();
        for (c.out_fds[0..c.out_nfds]) |f| _ = linux.close(f);
    }

    /// Closes the connection.
    pub fn deinit(c: *Conn) void {
        _ = linux.close(c.sock);
        c.freeState();
        c.gpa.destroy(c);
    }

    /// The socket, to poll for input.
    pub fn pollFd(c: *const Conn) i32 {
        return c.sock;
    }

    /// The default screen.
    pub fn screen(c: *const Conn) *const setup_mod.Screen {
        return &c.setup.screens[c.screen_index];
    }

    fn handshake(c: *Conn, cookie: ?auth.Cookie) Error!void {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(c.gpa);
        const ck = cookie orelse auth.Cookie{ .name = "", .data = "" };
        try setup_mod.writeRequest(&req, c.gpa, ck.name, ck.data);
        try c.sendAll(req.items, &.{});
        try c.fill(8);
        const total = setup_mod.replyLen(c.in.items[0..8]);
        try c.fill(total);
        c.setup = setup_mod.parse(c.setup_arena.allocator(), c.in.items[0..total]) catch |err| return switch (err) {
            error.Malformed => error.Protocol,
            else => |e| e,
        };
        c.in_start = total;
        if (c.setup.screens.len == 0) return error.Protocol;
        const mask = c.setup.resource_id_mask;
        if (mask == 0) return error.Protocol;
        c.xid_inc = mask & (~mask +% 1);
        c.max_request_words = c.setup.max_request_length;
    }

    fn queryStartupExtensions(c: *Conn) Error!void {
        var cookies: [ext.startup.len]Cookie(proto.QueryExtension) = undefined;
        for (ext.startup, 0..) |name, i| cookies[i] = try c.request(proto.QueryExtension, .{ .name_len = @intCast(name.len), .name = name }, &.{});
        for (cookies, 0..) |ck, i| {
            const r = try c.reply(ck);
            if (r.present) c.extensions[i] = .{ .major_opcode = r.major_opcode, .first_event = r.first_event, .first_error = r.first_error };
        }
        if (c.extension("BIG-REQUESTS") != null) {
            const r = try c.reply(try c.request(proto.BigReqEnable, .{}, &.{}));
            c.max_request_words = r.max_request_length;
            c.big_requests = true;
        }
    }

    /// The cached info of a startup extension, if the server has it.
    pub fn extension(c: *const Conn, name: []const u8) ?ext.ExtInfo {
        return c.extensions[ext.index(name) orelse return null];
    }

    /// A new resource id.
    pub fn newXid(c: *Conn) Error!u32 {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.xid_next > c.setup.resource_id_mask or (c.xid_next == 0 and c.xid_inc == 0)) {
            log.info("XID range exhausted", .{});
            return error.XidsExhausted;
        }
        const id = c.setup.resource_id_base | c.xid_next;
        c.xid_next +%= c.xid_inc;
        if (c.xid_next == 0) c.xid_next = c.setup.resource_id_mask +% 1; // wrapped: mark exhausted
        return id;
    }

    /// Queues request `req` with `fds` attached; returns its cookie. For
    /// extension requests the extension must be present.
    pub fn request(c: *Conn, comptime R: type, req: R, fds: []const i32) Error!Cookie(R) {
        const major: u8 = if (@hasDecl(R, "extension")) (c.extension(R.extension) orelse return error.Unsupported).major_opcode else 0;
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        const has_reply = @hasDecl(R, "Reply");
        // Keep a reply in flight at least every 64k requests, so 16-bit
        // sequence numbers stay unambiguous.
        if (!has_reply and c.seq_sent + 1 - c.seq_answered_by >= 0xff00) _ = try c.queueLocked(proto.GetInputFocus, .{}, &.{}, 0, true);
        return .{ .seq = try c.queueLocked(R, req, fds, major, false) };
    }

    fn queueLocked(c: *Conn, comptime R: type, req: R, fds: []const i32, major: u8, discard: bool) Error!u64 {
        const size = proto.requestSize(R, req) + 4;
        if (size / 4 > @max(c.max_request_words, 1) + 1) return error.RequestTooLarge;
        if (c.out_nfds + fds.len > socket.max_fds or c.out.items.len + size > 64 * 1024) try c.flushLocked();
        var dups: [socket.max_fds]i32 = undefined;
        for (fds, 0..) |f, i| dups[i] = socket.dupCloexec(f) catch |err| {
            for (dups[0..i]) |x| _ = linux.close(x);
            return switch (err) {
                error.Protocol => error.Protocol,
                else => error.SystemResources,
            };
        };
        try c.out.ensureUnusedCapacity(c.gpa, size);
        const n = try proto.writeRequest(c.out.unusedCapacitySlice(), R, req, major, c.big_requests);
        c.out.items.len += n;
        @memcpy(c.out_fds[c.out_nfds..][0..fds.len], dups[0..fds.len]);
        c.out_nfds += fds.len;
        c.seq_sent += 1;
        if (@hasDecl(R, "Reply") or discard) {
            try c.pending.append(c.gpa, .{ .seq = c.seq_sent, .discard = discard });
            c.seq_answered_by = c.seq_sent;
        }
        return c.seq_sent;
    }

    /// Sends every queued request.
    pub fn flush(c: *Conn) Error!void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        try c.flushLocked();
    }

    fn flushLocked(c: *Conn) Error!void {
        if (c.out.items.len == 0) return;
        try c.sendAll(c.out.items, c.out_fds[0..c.out_nfds]);
        for (c.out_fds[0..c.out_nfds]) |f| _ = linux.close(f);
        c.out_nfds = 0;
        c.out.clearRetainingCapacity();
    }

    fn sendAll(c: *Conn, bytes: []const u8, fds: []const i32) Error!void {
        var off: usize = 0;
        var pass = fds;
        while (off < bytes.len) {
            off += socket.sendMsg(c.sock, bytes[off..], pass) catch |err| return mapSock(err);
            pass = &.{};
        }
    }

    fn mapSock(err: socket.Error) Error {
        return switch (err) {
            error.ConnectionLost, error.WouldBlock => error.ConnectionLost,
            error.Protocol => error.Protocol,
            error.SystemResources => error.SystemResources,
            error.NameTooLong, error.ConnectFailed => error.ConnectFailed,
        };
    }

    /// Reads until `n` unread bytes are buffered (setup only).
    fn fill(c: *Conn, n: usize) Error!void {
        while (c.in.items.len - c.in_start < n) _ = try c.readOnce(true);
    }

    /// One recvmsg; returns false when nothing was there (non-blocking).
    fn readOnce(c: *Conn, block: bool) Error!bool {
        if (c.in_start == c.in.items.len) {
            c.in.clearRetainingCapacity();
            c.in_start = 0;
        } else if (c.in_start > 0 and c.in_start >= c.in.capacity / 2) {
            const rest = c.in.items.len - c.in_start;
            std.mem.copyForwards(u8, c.in.items[0..rest], c.in.items[c.in_start..]);
            c.in.shrinkRetainingCapacity(rest);
            c.in_start = 0;
        }
        try c.in.ensureUnusedCapacity(c.gpa, 64 * 1024);
        if (c.in_fds.free() < socket.max_fds) return error.Protocol;
        const n = socket.recvMsg(c.sock, c.in.unusedCapacitySlice(), &c.in_fds, !block) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return mapSock(err),
        };
        c.in.items.len += n;
        return true;
    }

    /// Extends a 16-bit wire sequence to the full count.
    pub fn extendSeq(c: *Conn, wire: u16) u64 {
        var full = (c.seq_read & ~@as(u64, 0xffff)) | wire;
        if (full < c.seq_read) full += 0x10000;
        if (full > c.seq_sent and full >= 0x10000) full -= 0x10000;
        c.seq_read = full;
        return full;
    }

    /// Splits buffered bytes into replies, errors and events.
    fn process(c: *Conn) Error!void {
        while (true) {
            const avail = c.in.items[c.in_start..];
            if (avail.len < 32) return;
            const kind = avail[0];
            const len: usize = if (kind == 1 or (kind & 0x7f) == proto.generic_event)
                32 + @as(usize, std.mem.readInt(u32, avail[4..8], .little)) * 4
            else
                32;
            if (avail.len < len) {
                try c.in.ensureTotalCapacity(c.gpa, c.in_start + len);
                return;
            }
            const msg = avail[0..len];
            c.in_start += len;
            switch (kind) {
                0, 1 => {
                    const seq = c.extendSeq(std.mem.readInt(u16, msg[2..4], .little));
                    try c.response(seq, kind == 0, msg);
                },
                else => {
                    // KeymapNotify carries no sequence number.
                    if ((kind & 0x7f) != 11) _ = c.extendSeq(std.mem.readInt(u16, msg[2..4], .little));
                    try c.events.appendSlice(c.gpa, msg);
                },
            }
        }
    }

    fn response(c: *Conn, seq: u64, is_error: bool, msg: []const u8) Error!void {
        c.lock.lockUncancelable(c.io);
        // Requests before `seq` that expected a response and got none are
        // done (their reply cannot come any more).
        while (c.pending_head < c.pending.items.len and c.pending.items[c.pending_head].seq < seq) c.pending_head += 1;
        const p: ?Pending = if (c.pending_head < c.pending.items.len and c.pending.items[c.pending_head].seq == seq) c.pending.items[c.pending_head] else null;
        if (p != null) c.pending_head += 1;
        if (c.pending_head == c.pending.items.len) {
            c.pending.clearRetainingCapacity();
            c.pending_head = 0;
        }
        c.lock.unlock(c.io);

        if (p == null or p.?.discard) {
            if (is_error) {
                const e = proto.XError.parse(msg[0..32]);
                c.last_error = e;
                c.async_errors += 1;
                log.debug("X error {d} for request {d} (major {d}, minor {d}, value 0x{x})", .{ e.code, seq, e.major_opcode, e.minor_opcode, e.bad_value });
            }
            return;
        }
        var buf = c.spare.pop() orelse std.ArrayList(u8).empty;
        buf.clearRetainingCapacity();
        buf.appendSlice(c.gpa, msg) catch |err| {
            buf.deinit(c.gpa);
            return err;
        };
        c.stored.append(c.gpa, .{ .seq = seq, .is_error = is_error, .bytes = buf }) catch |err| {
            buf.deinit(c.gpa);
            return err;
        };
    }

    fn takeStored(c: *Conn, seq: u64) ?Stored {
        for (c.stored.items, 0..) |s, i| if (s.seq == seq) return c.stored.orderedRemove(i);
        return null;
    }

    fn answered(c: *Conn, seq: u64) bool {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        for (c.pending.items[c.pending_head..]) |p| if (p.seq == seq) return false;
        return true;
    }

    /// Waits for the reply to `cookie`. Views in the reply (strings,
    /// lists) stay valid until the next `reply` call. An X error gives
    /// `error.X11Error` with `last_error` set.
    pub fn reply(c: *Conn, cookie: anytype) Error!@TypeOf(cookie).Request.Reply {
        const R = @TypeOf(cookie).Request;
        try c.flush();
        while (true) {
            if (c.takeStored(cookie.seq)) |s| {
                // Recycle the previous reply's buffer; keep this one alive.
                var prev = c.current_reply;
                prev.clearRetainingCapacity();
                c.spare.append(c.gpa, prev) catch prev.deinit(c.gpa);
                c.current_reply = s.bytes;
                if (s.is_error) {
                    c.last_error = proto.XError.parse(s.bytes.items[0..32]);
                    return error.X11Error;
                }
                return R.Reply.decode(s.bytes.items, &c.in_fds) catch error.Protocol;
            }
            if (c.answered(cookie.seq)) return error.Protocol; // never coming
            _ = try c.readOnce(true);
            try c.process();
        }
    }

    /// A round trip: every earlier request has been processed when it
    /// returns.
    pub fn sync(c: *Conn) Error!void {
        _ = try c.reply(try c.request(proto.GetInputFocus, .{}, &.{}));
    }

    /// Sends `req` and waits until the server has processed it, returning
    /// `error.X11Error` if it failed.
    pub fn checked(c: *Conn, comptime R: type, req: R, fds: []const i32) Error!void {
        const ck = try c.request(R, req, fds);
        const before = c.async_errors;
        try c.sync();
        if (c.async_errors != before) if (c.last_error) |e| {
            if (c.extendSeqPeek(e.sequence) == ck.seq) return error.X11Error;
        };
    }

    fn extendSeqPeek(c: *const Conn, wire: u16) u64 {
        var full = (c.seq_read & ~@as(u64, 0xffff)) | wire;
        if (full > c.seq_read) full -%= 0x10000;
        return full;
    }

    /// The next queued event without blocking: reads what the socket has
    /// first. The bytes are valid until the next `pollEvent`/`waitEvent`.
    pub fn pollEvent(c: *Conn) Error!?[]const u8 {
        if (c.events_start == c.events.items.len) {
            if (try c.readOnce(false)) try c.process();
        }
        return c.nextQueued();
    }

    /// Blocks for the next event.
    pub fn waitEvent(c: *Conn) Error![]const u8 {
        try c.flush();
        while (true) {
            if (c.nextQueued()) |e| return e;
            _ = try c.readOnce(true);
            try c.process();
        }
    }

    fn nextQueued(c: *Conn) ?[]const u8 {
        const q = c.events.items[c.events_start..];
        if (q.len == 0) {
            c.events.clearRetainingCapacity();
            c.events_start = 0;
            return null;
        }
        const len: usize = if ((q[0] & 0x7f) == proto.generic_event) 32 + @as(usize, std.mem.readInt(u32, q[4..8], .little)) * 4 else 32;
        c.current_event.clearRetainingCapacity();
        c.current_event.appendSlice(c.gpa, q[0..len]) catch return null;
        c.events_start += len;
        if (c.events_start == c.events.items.len) {
            c.events.clearRetainingCapacity();
            c.events_start = 0;
        }
        return c.current_event.items;
    }

    /// Interns `names` with one round trip (all requests, then all replies).
    pub fn internAtoms(c: *Conn, comptime names: []const []const u8) Error!atoms.AtomTable(names) {
        var t: atoms.AtomTable(names) = .{};
        var cookies: [names.len]Cookie(proto.InternAtom) = undefined;
        inline for (names, 0..) |n, i| cookies[i] = try c.request(proto.InternAtom, .{ .name_len = n.len, .name = n }, &.{});
        for (cookies, 0..) |ck, i| t.ids[i] = (try c.reply(ck)).atom;
        return t;
    }
};

/// Connects to display `n`: the abstract socket `@/tmp/.X11-unix/X<n>`,
/// then the filesystem path.
fn connectLocal(n: u32) Error!i32 {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "/tmp/.X11-unix/X{d}", .{n}) catch unreachable;
    for ([_]bool{ true, false }) |abstract| {
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        const base = @offsetOf(linux.sockaddr.un, "path");
        const off: usize = @intFromBool(abstract);
        @memcpy(addr.path[off..][0..name.len], name);
        const len: u32 = @intCast(base + off + name.len + @intFromBool(!abstract));
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        const sock: i32 = @intCast(rc);
        while (true) switch (linux.errno(linux.connect(sock, &addr, len))) {
            .SUCCESS => return sock,
            .INTR => continue,
            else => {
                _ = linux.close(sock);
                break;
            },
        };
    }
    return error.ConnectFailed;
}

const testing = std.testing;

test "Xvfb: setup, BIG-REQUESTS, XKEYBOARD, atoms and a mapped window" {
    var x = XvfbForTest.start(0) catch return error.SkipZigTest;
    defer x.stop();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("DISPLAY", x.display());
    const c = try Conn.connect(testing.allocator, testing.io, &env, .{});
    defer c.deinit();
    try testing.expect(c.big_requests);
    try testing.expect(c.max_request_words > 65535);
    try testing.expect(c.extension("XKEYBOARD") != null);
    const t = try c.internAtoms(&.{ "WM_PROTOCOLS", "UTF8_STRING" });
    try testing.expect(t.get("UTF8_STRING") != 0);
    const s = c.screen();
    const wid = try c.newXid();
    try c.checked(proto.CreateWindow, .{
        .data = s.root_depth,
        .wid = wid,
        .parent = s.root,
        .x = 0,
        .y = 0,
        .width = 64,
        .height = 64,
        .visual = s.root_visual,
        .values = .{ .values = .{ .background_pixel = s.black_pixel } },
    }, &.{});
    try c.checked(proto.MapWindow, .{ .window = wid }, &.{});
    // A bad window fails its checked request and nothing else.
    try testing.expectError(error.X11Error, c.checked(proto.MapWindow, .{ .window = wid + 1 }, &.{}));
    try testing.expectEqual(proto.ErrorCode.window, c.last_error.?.code);
    try c.sync();
}

/// A private Xvfb for tests; an absent Xvfb skips. `-noreset` keeps the
/// server up between clients (by default it regenerates when the last
/// one leaves, and a client connecting then fails its handshake).
pub const XvfbForTest = struct {
    child: std.process.Child,
    name_buf: [16]u8,
    name_len: usize,

    /// Starts Xvfb on a free display number derived from `seed` and the
    /// pid. Parallel test processes can pick the same number: the lock
    /// file must name our child, or the next number is tried. The server
    /// is ready once its socket accepts a connection (the socket file
    /// exists from bind(), before it listens).
    pub fn start(seed: u32) !XvfbForTest {
        var x: XvfbForTest = undefined;
        const pid: u32 = @intCast(linux.getpid());
        var attempt: u32 = 0;
        while (attempt < 8) : (attempt += 1) {
            const n = 450 + (seed * 37 + attempt * 101 + pid) % 400;
            var lock_buf: [32]u8 = undefined;
            const lock = try std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{n});
            if (Io.Dir.cwd().access(testing.io, lock, .{})) |_| continue else |_| {}
            x.name_len = (try std.fmt.bufPrint(&x.name_buf, ":{d}", .{n})).len;
            x.child = try std.process.spawn(testing.io, .{
                .argv = &.{ "Xvfb", x.display(), "-nolisten", "tcp", "-noreset", "-screen", "0", "640x480x24" },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            switch (try x.waitReady(n, lock)) {
                .ready => return x,
                .taken => x.child.kill(testing.io),
            }
        }
        return error.XvfbDidNotStart;
    }

    fn waitReady(x: *XvfbForTest, n: u32, lock: []const u8) !enum { ready, taken } {
        errdefer x.child.kill(testing.io);
        const want: i64 = x.child.id.?;
        var tries: usize = 0;
        while (tries < 300) : (tries += 1) {
            var buf: [32]u8 = undefined;
            if (Io.Dir.cwd().readFile(testing.io, lock, &buf)) |text| {
                const owner = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \n"), 10) catch -1;
                if (owner > 0 and owner != want) return .taken;
                if (owner == want) if (connectLocal(n)) |sock| {
                    _ = linux.close(sock);
                    return .ready;
                } else |_| {};
            } else |_| {}
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.XvfbDidNotStart;
    }

    /// The `DISPLAY` value.
    pub fn display(x: *const XvfbForTest) []const u8 {
        return x.name_buf[0..x.name_len];
    }

    /// Stops Xvfb.
    pub fn stop(x: *XvfbForTest) void {
        x.child.kill(testing.io);
    }
};
