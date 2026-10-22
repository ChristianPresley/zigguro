//! A D-Bus connection over a Unix socket: address parsing, SASL, `Hello`,
//! method calls with replies, signal subscriptions and fd passing.
//!
//! One `Bus` is shared by every user in the process. `call`, `emit`,
//! `addMatch` and `removeMatch` may run on any thread: sends are serialised
//! by a lock, and replies and signals are dispatched by the reader, which is
//! either the bus's own thread or the platform loop calling `pump` when
//! `pollFd` is readable. Replies arrive through a `Pending` the caller waits on
//! with a deadline (never on the UI thread), or through a callback.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Io = std.Io;
const auth = @import("auth.zig");
const marshal = @import("marshal.zig");
const message = @import("message.zig");
const Value = @import("variant.zig").Value;

const log = std.log.scoped(.dbus);

/// Errors from bus operations.
pub const Error = error{
    OutOfMemory,
    InvalidAddress,
    NoSessionBus,
    ConnectFailed,
    AuthRejected,
    AuthProtocol,
    Disconnected,
    Malformed,
    TooLarge,
    InvalidObjectPath,
    InvalidSignature,
    InvalidString,
    TypeMismatch,
    InvalidMatchRule,
    FdPassingUnsupported,
    Timeout,
    SystemResources,
};

/// One transport from a D-Bus address.
pub const Transport = union(enum) {
    path: []const u8,
    abstract: []const u8,
};

/// Iterates the supported transports of an address such as
/// `unix:path=/run/user/1000/bus;unix:abstract=/tmp/x,guid=...`. Entries
/// that are not `unix:path=` or `unix:abstract=` are skipped.
pub const AddressIterator = struct {
    rest: []const u8,
    buf: [108]u8 = undefined,

    /// Iterates `address`.
    pub fn init(address: []const u8) AddressIterator {
        return .{ .rest = address };
    }

    /// The next transport, with `%xx` escapes decoded into the iterator's
    /// buffer (valid until the next call), or null at the end.
    pub fn next(it: *AddressIterator) error{InvalidAddress}!?Transport {
        while (it.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, it.rest, ';') orelse it.rest.len;
            const entry = it.rest[0..end];
            it.rest = if (end < it.rest.len) it.rest[end + 1 ..] else "";
            if (!std.mem.startsWith(u8, entry, "unix:")) continue;
            var kvs = std.mem.splitScalar(u8, entry["unix:".len..], ',');
            while (kvs.next()) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.InvalidAddress;
                const key = kv[0..eq];
                const is_path = std.mem.eql(u8, key, "path");
                if (!is_path and !std.mem.eql(u8, key, "abstract")) continue;
                const v = try unescape(kv[eq + 1 ..], &it.buf);
                if (v.len == 0) return error.InvalidAddress;
                return if (is_path) .{ .path = v } else .{ .abstract = v };
            }
        }
        return null;
    }
};

fn unescape(s: []const u8, out: []u8) error{InvalidAddress}![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n >= out.len) return error.InvalidAddress;
        if (s[i] == '%') {
            if (i + 3 > s.len) return error.InvalidAddress;
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.InvalidAddress;
            i += 3;
        } else {
            out[n] = s[i];
            i += 1;
        }
    }
    return out[0..n];
}

/// Connection options.
pub const Options = struct {
    /// Ask the server for fd passing.
    negotiate_fd: bool = true,
    /// Dispatch on a thread owned by the bus. When false, the owner polls
    /// `pollFd` and calls `pump` when it is readable.
    own_thread: bool = true,
};

/// A match rule, as given to `addMatch`. Values are views into the rule.
pub const Rule = struct {
    type: ?message.Type = null,
    sender: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    path: ?[]const u8 = null,
    path_namespace: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    arg0: ?[]const u8 = null,

    /// Parses `key='value'` pairs separated by commas. Values containing
    /// backslash escapes are not supported.
    pub fn parse(text: []const u8) error{InvalidMatchRule}!Rule {
        var r: Rule = .{};
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and (text[i] == ' ' or text[i] == ',')) i += 1;
            if (i >= text.len) break;
            const eq = std.mem.indexOfScalarPos(u8, text, i, '=') orelse return error.InvalidMatchRule;
            const key = std.mem.trim(u8, text[i..eq], " ");
            var j = eq + 1;
            var value: []const u8 = undefined;
            if (j < text.len and text[j] == '\'') {
                const close = std.mem.indexOfScalarPos(u8, text, j + 1, '\'') orelse return error.InvalidMatchRule;
                value = text[j + 1 .. close];
                j = close + 1;
            } else {
                const comma = std.mem.indexOfScalarPos(u8, text, j, ',') orelse text.len;
                value = text[j..comma];
                j = comma;
            }
            if (std.mem.indexOfScalar(u8, value, '\\') != null) return error.InvalidMatchRule;
            if (std.mem.eql(u8, key, "type")) {
                r.type = if (std.mem.eql(u8, value, "signal")) .signal else if (std.mem.eql(u8, value, "method_call")) .method_call else if (std.mem.eql(u8, value, "method_return")) .method_return else if (std.mem.eql(u8, value, "error")) .@"error" else return error.InvalidMatchRule;
            } else if (std.mem.eql(u8, key, "sender")) {
                r.sender = value;
            } else if (std.mem.eql(u8, key, "interface")) {
                r.interface = value;
            } else if (std.mem.eql(u8, key, "member")) {
                r.member = value;
            } else if (std.mem.eql(u8, key, "path")) {
                r.path = value;
            } else if (std.mem.eql(u8, key, "path_namespace")) {
                r.path_namespace = value;
            } else if (std.mem.eql(u8, key, "destination")) {
                r.destination = value;
            } else if (std.mem.eql(u8, key, "arg0")) {
                r.arg0 = value;
            } else return error.InvalidMatchRule;
            i = j;
        }
        return r;
    }

    /// Whether `m` matches. A `sender` that is a well-known name cannot be
    /// checked locally (messages carry unique names), so it is left to the
    /// bus, which only routes matching signals to us.
    pub fn matches(r: *const Rule, m: *const message.Message) bool {
        const h = &m.header;
        if (r.type) |t| if (t != h.type) return false;
        if (!optEql(r.interface, h.interface)) return false;
        if (!optEql(r.member, h.member)) return false;
        if (!optEql(r.path, h.path)) return false;
        if (r.destination) |d| if (h.destination == null or !std.mem.eql(u8, d, h.destination.?)) return false;
        if (r.sender) |s| if (s.len > 0 and s[0] == ':') if (h.sender == null or !std.mem.eql(u8, s, h.sender.?)) return false;
        if (r.path_namespace) |ns| {
            const p = h.path orelse return false;
            const inside = std.mem.eql(u8, ns, "/") or std.mem.eql(u8, p, ns) or
                (std.mem.startsWith(u8, p, ns) and p.len > ns.len and p[ns.len] == '/');
            if (!inside) return false;
        }
        if (r.arg0) |a| {
            if (h.signature.len == 0 or h.signature[0] != 's') return false;
            var d: marshal.Decoder = .{ .buf = m.body, .big_endian = m.big_endian, .arena = undefined };
            const s = d.readString() catch return false;
            if (!std.mem.eql(u8, s, a)) return false;
        }
        return true;
    }
};

fn optEql(want: ?[]const u8, have: ?[]const u8) bool {
    const w = want orelse return true;
    const h = have orelse return false;
    return std.mem.eql(u8, w, h);
}

/// A reply owned by the caller.
pub const Reply = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
    msg: message.Message,
    /// Received fds; `takeFd` moves one out, `deinit` closes the rest.
    fds: []i32,

    /// Frees the reply and closes fds not taken.
    pub fn deinit(r: *Reply) void {
        for (r.fds) |fd| if (fd >= 0) closeFd(fd);
        r.gpa.free(r.fds);
        r.gpa.free(r.bytes);
        r.* = undefined;
    }

    /// Whether the call failed.
    pub fn isError(r: *const Reply) bool {
        return r.msg.header.type == .@"error";
    }

    /// The D-Bus error name, for an error reply.
    pub fn errorName(r: *const Reply) ?[]const u8 {
        return r.msg.header.error_name;
    }

    /// Decodes the body; containers go in `arena`.
    pub fn args(r: *const Reply, arena: std.mem.Allocator) marshal.DecodeError![]Value {
        return r.msg.args(arena, r.fds);
    }

    /// Takes ownership of fd `index`.
    pub fn takeFd(r: *Reply, index: usize) ?i32 {
        if (index >= r.fds.len or r.fds[index] < 0) return null;
        defer r.fds[index] = -1;
        return r.fds[index];
    }
};

/// Called on the reader with a reply or `error.Disconnected`. The reply is
/// freed after the callback returns.
pub const ReplyHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, reply: Error!*Reply) void,
};

/// A signal or method call as seen by a handler: views valid only during
/// the call.
pub const Incoming = struct {
    msg: *const message.Message,
    /// The signal's fds; set an entry to -1 to keep it, the rest are closed.
    fds: []i32,
    arena: std.mem.Allocator,

    /// Decodes the body into the dispatch arena.
    pub fn args(in: *const Incoming) marshal.DecodeError![]Value {
        return in.msg.args(in.arena, in.fds);
    }
};

/// Called on the reader for each matching signal. A handler may call bus
/// methods but must not wait on a `Pending` (the reader would deadlock).
pub const SignalHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, in: *const Incoming) void,
};

/// Answers method calls to this connection (services and test fakes).
/// Runs on the reader; returns false to let the bus reply
/// `UnknownMethod`. Reply with `Bus.replyTo` or `Bus.replyError`.
pub const MethodHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, bus: *Bus, in: *const Incoming) bool,
};

/// Identifies one subscription.
pub const MatchId = enum(u32) { _ };

const Slot = struct {
    /// 0 waiting, 1 replied, 2 disconnected.
    state: std.atomic.Value(u32) = .init(0),
    refs: std.atomic.Value(u32),
    reply: ?Reply = null,
    handler: ?ReplyHandler = null,

    fn release(s: *Slot, gpa: std.mem.Allocator) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        if (s.reply) |*r| r.deinit();
        gpa.destroy(s);
    }
};

/// A call awaiting its reply.
pub const Pending = struct {
    gpa: std.mem.Allocator,
    io: Io,
    slot: ?*Slot,
    /// The call's serial.
    serial: u32,

    /// Waits up to `timeout_ns` (forever when null) and returns the reply,
    /// which may be an error reply. On `error.Timeout` the call is still
    /// pending and `wait` may be called again.
    pub fn wait(p: *Pending, timeout_ns: ?u64) Error!Reply {
        const slot = p.slot orelse return error.Disconnected;
        const io = p.io;
        const deadline: ?i96 = if (timeout_ns) |ns| nowNs(io) + ns else null;
        while (true) {
            switch (slot.state.load(.acquire)) {
                1 => {
                    const r = slot.reply.?;
                    slot.reply = null;
                    p.deinit();
                    return r;
                },
                2 => return error.Disconnected,
                else => {},
            }
            const timeout: Io.Timeout = if (deadline) |d| blk: {
                const left = d - nowNs(io);
                if (left <= 0) return error.Timeout;
                break :blk .{ .duration = .{ .raw = .fromNanoseconds(left), .clock = .awake } };
            } else .none;
            io.futexWaitTimeout(u32, &slot.state.raw, 0, timeout) catch {};
        }
    }

    /// Drops interest in the reply. Safe after `wait` returned, and after
    /// the bus is gone.
    pub fn deinit(p: *Pending) void {
        if (p.slot) |s| s.release(p.gpa);
        p.slot = null;
    }
};

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

const Match = struct {
    id: MatchId,
    text: []u8,
    rule: Rule,
    handler: SignalHandler,
};

/// Where a call goes.
pub const Target = struct {
    destination: ?[]const u8,
    path: []const u8,
    interface: ?[]const u8,
    member: []const u8,
};

const bus_name = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";
const max_fds_per_recv = 253;

/// A connection to a message bus.
pub const Bus = struct {
    gpa: std.mem.Allocator,
    io: Io,
    sock: i32,
    /// Whether fds can be passed.
    unix_fd: bool,
    /// The server guid.
    guid: [32]u8,
    /// Our unique name, from `Hello`.
    unique_name: []const u8 = "",
    next_serial: std.atomic.Value(u32) = .init(1),
    send_lock: Io.Mutex = .init,
    lock: Io.Mutex = .init,
    pending: std.AutoHashMapUnmanaged(u32, *Slot) = .empty,
    matches: std.ArrayList(Match) = .empty,
    next_match: u32 = 1,
    closed: bool = false,
    in: std.ArrayList(u8) = .empty,
    in_start: usize = 0,
    in_fds: std.ArrayList(i32) = .empty,
    dispatch_arena: std.heap.ArenaAllocator,
    handlers_scratch: std.ArrayList(SignalHandler) = .empty,
    reader: ?std.Thread = null,
    method_handler: ?MethodHandler = null,

    /// Connects to the session bus: `DBUS_SESSION_BUS_ADDRESS`, else
    /// `unix:path=$XDG_RUNTIME_DIR/bus`.
    pub fn connectSession(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, opts: Options) Error!*Bus {
        if (env.get("DBUS_SESSION_BUS_ADDRESS")) |a| return connectAddress(gpa, io, a, opts);
        const dir = env.get("XDG_RUNTIME_DIR") orelse return error.NoSessionBus;
        var buf: [128]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/bus", .{dir}) catch return error.InvalidAddress;
        return connectTransport(gpa, io, .{ .path = p }, opts);
    }

    /// Connects to `address`, trying each supported transport in order,
    /// then authenticates and calls `Hello`.
    pub fn connectAddress(gpa: std.mem.Allocator, io: Io, address: []const u8, opts: Options) Error!*Bus {
        var it: AddressIterator = .init(address);
        var last: Error = error.InvalidAddress;
        while (try it.next()) |t| {
            return connectTransport(gpa, io, t, opts) catch |err| {
                last = err;
                continue;
            };
        }
        return last;
    }

    fn connectTransport(gpa: std.mem.Allocator, io: Io, t: Transport, opts: Options) Error!*Bus {
        const sock = try connectUnix(t);
        errdefer closeFd(sock);
        const b = try gpa.create(Bus);
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .io = io, .sock = sock, .unix_fd = false, .guid = undefined, .dispatch_arena = .init(gpa) };
        errdefer b.freeState();
        try b.authenticate(opts.negotiate_fd);

        var p = try b.callRaw(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "Hello" }, "", "", &.{}, null);
        defer p.deinit();
        while (p.slot.?.state.load(.acquire) == 0) try b.pump();
        var r = try p.wait(0);
        defer r.deinit();
        if (r.isError()) return error.ConnectFailed;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = r.args(arena.allocator()) catch return error.Malformed;
        if (a.len != 1 or a[0] != .string) return error.Malformed;
        b.unique_name = try gpa.dupe(u8, a[0].string);

        if (opts.own_thread) b.reader = std.Thread.spawn(.{}, readerMain, .{b}) catch return error.SystemResources;
        return b;
    }

    /// Disconnects, fails pending calls and frees the bus.
    pub fn deinit(b: *Bus) void {
        _ = linux.shutdown(b.sock, linux.SHUT.RDWR);
        if (b.reader) |t| t.join() else b.failAll();
        closeFd(b.sock);
        b.freeState();
        b.gpa.destroy(b);
    }

    fn freeState(b: *Bus) void {
        for (b.matches.items) |m| b.gpa.free(m.text);
        b.matches.deinit(b.gpa);
        b.pending.deinit(b.gpa);
        b.in.deinit(b.gpa);
        for (b.in_fds.items) |fd| closeFd(fd);
        b.in_fds.deinit(b.gpa);
        b.handlers_scratch.deinit(b.gpa);
        b.dispatch_arena.deinit();
        if (b.unique_name.len > 0) b.gpa.free(b.unique_name);
    }

    /// The socket, for owners that dispatch with `pump`.
    pub fn pollFd(b: *const Bus) i32 {
        return b.sock;
    }

    /// Reads once (blocking until data arrives) and dispatches every
    /// complete message. Only for buses without their own thread.
    pub fn pump(b: *Bus) Error!void {
        try b.recvSome();
        try b.processInput();
    }

    /// Calls a method; `args` are checked against `sig` at comptime.
    pub fn call(b: *Bus, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, comptime sig: []const u8, args: anytype) Error!Pending {
        var body: marshal.Encoder = .init(b.gpa, 0);
        defer body.deinit();
        try marshal.encode(&body, sig, args);
        return b.callRaw(.{ .destination = dest, .path = path, .interface = iface, .member = member }, sig, body.buf.items, body.fds.items, null);
    }

    /// Calls a method and runs `handler` on the reader with the reply.
    pub fn callAsync(b: *Bus, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, comptime sig: []const u8, args: anytype, handler: ReplyHandler) Error!void {
        var body: marshal.Encoder = .init(b.gpa, 0);
        defer body.deinit();
        try marshal.encode(&body, sig, args);
        var p = try b.callRaw(.{ .destination = dest, .path = path, .interface = iface, .member = member }, sig, body.buf.items, body.fds.items, handler);
        p.deinit();
    }

    /// Calls a method with an already-marshalled body. `fds` stay owned by
    /// the caller.
    pub fn callRaw(b: *Bus, t: Target, sig: []const u8, body: []const u8, fds: []const i32, handler: ?ReplyHandler) Error!Pending {
        if (fds.len > 0 and !b.unix_fd) return error.FdPassingUnsupported;
        const serial = b.nextSerial();
        const slot = try b.gpa.create(Slot);
        slot.* = .{ .refs = .init(2), .handler = handler };
        {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            if (b.closed) {
                b.gpa.destroy(slot);
                return error.Disconnected;
            }
            b.pending.put(b.gpa, serial, slot) catch {
                b.gpa.destroy(slot);
                return error.OutOfMemory;
            };
        }
        var p: Pending = .{ .gpa = b.gpa, .io = b.io, .slot = slot, .serial = serial };
        b.sendMessage(.{
            .type = .method_call,
            .serial = serial,
            .destination = t.destination,
            .path = t.path,
            .interface = t.interface,
            .member = t.member,
            .signature = sig,
            .unix_fds = @intCast(fds.len),
        }, body, fds) catch |err| {
            b.forget(serial);
            p.deinit();
            return err;
        };
        return p;
    }

    fn forget(b: *Bus, serial: u32) void {
        b.lock.lockUncancelable(b.io);
        const kv = b.pending.fetchRemove(serial);
        b.lock.unlock(b.io);
        if (kv) |e| e.value.release(b.gpa);
    }

    /// Emits a signal.
    pub fn emit(b: *Bus, path: []const u8, iface: []const u8, member: []const u8, comptime sig: []const u8, args: anytype) Error!void {
        var body: marshal.Encoder = .init(b.gpa, 0);
        defer body.deinit();
        try marshal.encode(&body, sig, args);
        if (body.fds.items.len > 0 and !b.unix_fd) return error.FdPassingUnsupported;
        try b.sendMessage(.{
            .type = .signal,
            .serial = b.nextSerial(),
            .path = path,
            .interface = iface,
            .member = member,
            .signature = sig,
            .unix_fds = @intCast(body.fds.items.len),
        }, body.buf.items, body.fds.items);
    }

    /// Sets the handler for incoming method calls. Set it before the
    /// connection is visible to callers (for example before RequestName).
    pub fn setMethodHandler(b: *Bus, handler: ?MethodHandler) void {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.method_handler = handler;
    }

    /// Replies to method call `in` with `args` of signature `sig`.
    pub fn replyTo(b: *Bus, in: *const Incoming, comptime sig: []const u8, args: anytype) Error!void {
        var body: marshal.Encoder = .init(b.gpa, 0);
        defer body.deinit();
        try marshal.encode(&body, sig, args);
        if (body.fds.items.len > 0 and !b.unix_fd) return error.FdPassingUnsupported;
        try b.sendMessage(.{
            .type = .method_return,
            .serial = b.nextSerial(),
            .reply_serial = in.msg.header.serial,
            .destination = in.msg.header.sender,
            .signature = sig,
            .unix_fds = @intCast(body.fds.items.len),
        }, body.buf.items, body.fds.items);
    }

    /// Replies to method call `in` with error `name` and `text`.
    pub fn replyError(b: *Bus, in: *const Incoming, name: []const u8, text: []const u8) Error!void {
        var body: marshal.Encoder = .init(b.gpa, 0);
        defer body.deinit();
        try marshal.encode(&body, "s", .{text});
        try b.sendMessage(.{
            .type = .@"error",
            .serial = b.nextSerial(),
            .reply_serial = in.msg.header.serial,
            .destination = in.msg.header.sender,
            .error_name = name,
            .signature = "s",
        }, body.buf.items, &.{});
    }

    /// Subscribes `handler` to signals matching `rule`. Each subscriber has
    /// its own match, so removing one leaves the others.
    pub fn addMatch(b: *Bus, rule: []const u8, handler: SignalHandler) Error!MatchId {
        const text = try b.gpa.dupe(u8, rule);
        errdefer b.gpa.free(text);
        const parsed = try Rule.parse(text);
        const id: MatchId = blk: {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            if (b.closed) return error.Disconnected;
            const id: MatchId = @enumFromInt(b.next_match);
            b.next_match += 1;
            try b.matches.append(b.gpa, .{ .id = id, .text = text, .rule = parsed, .handler = handler });
            break :blk id;
        };
        // The bus counts identical rules per connection, so each
        // subscriber adds (and later removes) its own copy.
        b.sendBusCall("AddMatch", text) catch |err| {
            b.removeLocal(id);
            return err;
        };
        return id;
    }

    /// Removes one subscription. Its handler may still be running, or run
    /// once more, if a signal is being dispatched concurrently.
    pub fn removeMatch(b: *Bus, id: MatchId) void {
        const text = b.takeLocal(id) orelse return;
        defer b.gpa.free(text);
        b.sendBusCall("RemoveMatch", text) catch {};
    }

    fn takeLocal(b: *Bus, id: MatchId) ?[]u8 {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        for (b.matches.items, 0..) |m, i| if (m.id == id) {
            _ = b.matches.orderedRemove(i);
            return m.text;
        };
        return null;
    }

    fn removeLocal(b: *Bus, id: MatchId) void {
        if (b.takeLocal(id)) |t| b.gpa.free(t);
    }

    /// Sends a call to the bus whose reply nobody awaits; error replies are
    /// logged by the reader.
    fn sendBusCall(b: *Bus, member: []const u8, rule: []const u8) Error!void {
        var body: marshal.Encoder = .init(b.gpa, 0);
        defer body.deinit();
        try marshal.encode(&body, "s", .{rule});
        try b.sendMessage(.{
            .type = .method_call,
            .serial = b.nextSerial(),
            .destination = bus_name,
            .path = bus_path,
            .interface = bus_name,
            .member = member,
            .signature = "s",
        }, body.buf.items, &.{});
    }

    fn nextSerial(b: *Bus) u32 {
        while (true) {
            const s = b.next_serial.fetchAdd(1, .monotonic);
            if (s != 0) return s;
        }
    }

    fn sendMessage(b: *Bus, h: message.Header, body: []const u8, fds: []const i32) Error!void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(b.gpa);
        try message.write(b.gpa, &out, h, body);
        try b.sendAll(out.items, fds);
    }

    fn sendAll(b: *Bus, bytes: []const u8, fds: []const i32) Error!void {
        b.send_lock.lockUncancelable(b.io);
        defer b.send_lock.unlock(b.io);
        var off: usize = 0;
        var pass_fds = fds;
        while (off < bytes.len) {
            const n = try sendChunk(b.sock, bytes[off..], pass_fds);
            pass_fds = &.{};
            off += n;
        }
    }

    fn authenticate(b: *Bus, negotiate_fd: bool) Error!void {
        var c: auth.Client = .init(linux.getuid(), negotiate_fd);
        try b.sendAll(c.initial(), &.{});
        while (true) {
            const line = try b.readLine();
            switch (try c.onLine(line)) {
                .send => |s| try b.sendAll(s, &.{}),
                .begin => |s| {
                    try b.sendAll(s, &.{});
                    break;
                },
            }
        }
        b.guid = c.guid;
        b.unix_fd = c.unix_fd;
    }

    fn readLine(b: *Bus) Error![]const u8 {
        while (true) {
            const avail = b.in.items[b.in_start..];
            if (std.mem.indexOf(u8, avail, "\r\n")) |i| {
                b.in_start += i + 2;
                return avail[0..i];
            }
            if (avail.len > 16 * 1024) return error.AuthProtocol;
            try b.recvSome();
        }
    }

    fn recvSome(b: *Bus) Error!void {
        if (b.in_start == b.in.items.len) {
            b.in.clearRetainingCapacity();
            b.in_start = 0;
        } else if (b.in_start > 0 and b.in_start >= b.in.capacity / 2) {
            const rest = b.in.items.len - b.in_start;
            std.mem.copyForwards(u8, b.in.items[0..rest], b.in.items[b.in_start..]);
            b.in.shrinkRetainingCapacity(rest);
            b.in_start = 0;
        }
        try b.in.ensureUnusedCapacity(b.gpa, 64 * 1024);
        const spare = b.in.unusedCapacitySlice();
        var iov = [1]std.posix.iovec{.{ .base = spare.ptr, .len = spare.len }};
        var control: [cmsgSpace(max_fds_per_recv * 4)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var msg: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const n = while (true) {
            const rc = linux.recvmsg(b.sock, &msg, linux.MSG.CMSG_CLOEXEC);
            switch (linux.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => continue,
                .NOMEM, .NOBUFS => return error.SystemResources,
                else => return error.Disconnected,
            }
        };
        try b.collectFds(control[0..msg.controllen]);
        if (msg.flags & linux.MSG.CTRUNC != 0) return error.Malformed;
        if (n == 0) return error.Disconnected;
        b.in.items.len += n;
    }

    fn collectFds(b: *Bus, control: []const u8) Error!void {
        var off: usize = 0;
        while (off + @sizeOf(linux.cmsghdr) <= control.len) {
            const h: *align(1) const linux.cmsghdr = @ptrCast(control[off..].ptr);
            if (h.len < @sizeOf(linux.cmsghdr) or off + h.len > control.len) break;
            if (h.level == linux.SOL.SOCKET and h.type == linux.SCM.RIGHTS) {
                const data = control[off + @sizeOf(linux.cmsghdr) .. off + h.len];
                var i: usize = 0;
                while (i + 4 <= data.len) : (i += 4) {
                    const fd_in = std.mem.readInt(i32, data[i..][0..4], builtin.cpu.arch.endian());
                    b.in_fds.append(b.gpa, fd_in) catch {
                        closeFd(fd_in);
                        return error.OutOfMemory;
                    };
                }
            }
            off += std.mem.alignForward(usize, h.len, @alignOf(linux.cmsghdr));
        }
    }

    fn processInput(b: *Bus) Error!void {
        while (true) {
            const avail = b.in.items[b.in_start..];
            if (avail.len < 16) return;
            const n = message.frameLen(avail[0..16]) catch |err| return switch (err) {
                error.TooLarge => error.TooLarge,
                error.Malformed => error.Malformed,
            };
            if (avail.len < n) {
                try b.in.ensureTotalCapacity(b.gpa, b.in_start + n);
                return;
            }
            try b.handleMessage(avail[0..n]);
            b.in_start += n;
        }
    }

    fn handleMessage(b: *Bus, raw: []const u8) Error!void {
        const m = message.parse(raw) catch return error.Malformed;
        const nfds = m.header.unix_fds;
        if (nfds > b.in_fds.items.len) return error.Malformed;
        const fds = try b.gpa.dupe(i32, b.in_fds.items[0..nfds]);
        b.in_fds.replaceRangeAssumeCapacity(0, nfds, &.{});
        var fds_owned = true;
        defer if (fds_owned) {
            for (fds) |f| if (f >= 0) closeFd(f);
            b.gpa.free(fds);
        };
        switch (m.header.type) {
            .method_return, .@"error" => {
                const rs = m.header.reply_serial.?;
                b.lock.lockUncancelable(b.io);
                const kv = b.pending.fetchRemove(rs);
                b.lock.unlock(b.io);
                const slot = (kv orelse {
                    if (m.header.type == .@"error") log.warn("error reply {s} to serial {d}", .{ m.header.error_name.?, rs });
                    return;
                }).value;
                const bytes = try b.gpa.dupe(u8, raw);
                var reply: Reply = .{ .gpa = b.gpa, .bytes = bytes, .msg = message.parse(bytes) catch unreachable, .fds = fds };
                fds_owned = false;
                if (slot.handler) |hd| {
                    hd.func(hd.ctx, &reply);
                    reply.deinit();
                } else {
                    slot.reply = reply;
                    slot.state.store(1, .release);
                    b.io.futexWake(u32, &slot.state.raw, 1);
                }
                slot.release(b.gpa);
            },
            .signal => b.dispatchSignal(&m, fds),
            .method_call => try b.answerCall(&m, fds),
            _ => {},
        }
    }

    fn dispatchSignal(b: *Bus, m: *const message.Message, fds: []i32) void {
        b.handlers_scratch.clearRetainingCapacity();
        {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            for (b.matches.items) |*match| if (match.rule.matches(m)) {
                b.handlers_scratch.append(b.gpa, match.handler) catch break;
            };
        }
        if (b.handlers_scratch.items.len == 0) return;
        defer _ = b.dispatch_arena.reset(.retain_capacity);
        const in: Incoming = .{ .msg = m, .fds = fds, .arena = b.dispatch_arena.allocator() };
        for (b.handlers_scratch.items) |hd| hd.func(hd.ctx, &in);
    }

    /// Answers `org.freedesktop.DBus.Peer.Ping`, passes other calls to the
    /// method handler, and answers the rest with `UnknownMethod`.
    fn answerCall(b: *Bus, m: *const message.Message, fds: []i32) Error!void {
        const h = &m.header;
        const ping = optEql("org.freedesktop.DBus.Peer", h.interface) and std.mem.eql(u8, h.member.?, "Ping");
        if (ping) {
            if (h.flags.no_reply_expected) return;
            return b.sendMessage(.{ .type = .method_return, .serial = b.nextSerial(), .reply_serial = h.serial, .destination = h.sender }, "", &.{});
        }
        const handler = blk: {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            break :blk b.method_handler;
        };
        if (handler) |hd| {
            defer _ = b.dispatch_arena.reset(.retain_capacity);
            const in: Incoming = .{ .msg = m, .fds = fds, .arena = b.dispatch_arena.allocator() };
            if (hd.func(hd.ctx, b, &in)) return;
        }
        if (h.flags.no_reply_expected) return;
        var body: marshal.Encoder = .init(b.gpa, 0);
        defer body.deinit();
        try marshal.encode(&body, "s", .{"No such method"});
        try b.sendMessage(.{
            .type = .@"error",
            .serial = b.nextSerial(),
            .reply_serial = h.serial,
            .destination = h.sender,
            .error_name = "org.freedesktop.DBus.Error.UnknownMethod",
            .signature = "s",
        }, body.buf.items, &.{});
    }

    fn failAll(b: *Bus) void {
        var slots: std.ArrayList(*Slot) = .empty;
        defer slots.deinit(b.gpa);
        {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            b.closed = true;
            var it = b.pending.valueIterator();
            while (it.next()) |s| slots.append(b.gpa, s.*) catch {};
            b.pending.clearRetainingCapacity();
        }
        for (slots.items) |s| {
            if (s.handler) |hd| {
                hd.func(hd.ctx, error.Disconnected);
            } else {
                s.state.store(2, .release);
                b.io.futexWake(u32, &s.state.raw, 1);
            }
            s.release(b.gpa);
        }
    }

    fn readerMain(b: *Bus) void {
        while (true) b.pump() catch |err| {
            if (err != error.Disconnected) log.warn("bus connection closed: {s}", .{@errorName(err)});
            break;
        };
        b.failAll();
    }
};

fn cmsgSpace(n: usize) usize {
    return @sizeOf(linux.cmsghdr) + std.mem.alignForward(usize, n, @alignOf(linux.cmsghdr));
}

fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

fn connectUnix(t: Transport) Error!i32 {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    const base = @offsetOf(linux.sockaddr.un, "path");
    const len: u32 = switch (t) {
        .path => |p| blk: {
            if (p.len >= addr.path.len) return error.InvalidAddress;
            @memcpy(addr.path[0..p.len], p);
            break :blk @intCast(base + p.len + 1);
        },
        .abstract => |a| blk: {
            if (a.len + 1 > addr.path.len) return error.InvalidAddress;
            @memcpy(addr.path[1..][0..a.len], a);
            break :blk @intCast(base + 1 + a.len);
        },
    };
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    const sock: i32 = @intCast(rc);
    while (true) {
        switch (linux.errno(linux.connect(sock, &addr, len))) {
            .SUCCESS => return sock,
            .INTR => continue,
            else => {
                closeFd(sock);
                return error.ConnectFailed;
            },
        }
    }
}

fn sendChunk(sock: i32, bytes: []const u8, fds: []const i32) Error!usize {
    var iov = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    var control: [cmsgSpace(max_fds_per_recv * 4)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
    if (fds.len > 0) {
        if (fds.len > max_fds_per_recv) return error.TooLarge;
        const data_len = fds.len * 4;
        const h: *linux.cmsghdr = @ptrCast(&control);
        h.* = .{ .len = @sizeOf(linux.cmsghdr) + data_len, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
        @memcpy(control[@sizeOf(linux.cmsghdr)..][0..data_len], std.mem.sliceAsBytes(fds));
        msg.control = &control;
        msg.controllen = cmsgSpace(data_len);
    }
    while (true) {
        const rc = linux.sendmsg(sock, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR, .AGAIN => continue,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.Disconnected,
        }
    }
}

const testing = std.testing;

test "address parsing: escapes, multiple transports, defaults" {
    var it: AddressIterator = .init("tcp:host=x;unix:abstract=/tmp/dbus%2dab,guid=1;unix:path=/run/user/1000/bus");
    const a = (try it.next()).?;
    try testing.expectEqualStrings("/tmp/dbus-ab", a.abstract);
    const p = (try it.next()).?;
    try testing.expectEqualStrings("/run/user/1000/bus", p.path);
    try testing.expectEqual(null, try it.next());
    var bad: AddressIterator = .init("unix:path=/a%zz");
    try testing.expectError(error.InvalidAddress, bad.next());
    var trunc: AddressIterator = .init("unix:path=/a%2");
    try testing.expectError(error.InvalidAddress, trunc.next());
}

test "match rules parse and match" {
    const r = try Rule.parse("type='signal',interface='org.freedesktop.portal.Request',member='Response',path='/org/freedesktop/portal/desktop/request/1_2/t'");
    try testing.expectEqual(message.Type.signal, r.type.?);
    try testing.expectEqualStrings("Response", r.member.?);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try message.write(testing.allocator, &out, .{ .type = .signal, .serial = 1, .path = "/org/freedesktop/portal/desktop/request/1_2/t", .interface = "org.freedesktop.portal.Request", .member = "Response", .sender = ":1.5" }, "");
    const m = try message.parse(out.items);
    try testing.expect(r.matches(&m));
    const other = try Rule.parse("type='signal',member='Other'");
    try testing.expect(!other.matches(&m));
    const ns = try Rule.parse("path_namespace='/org/freedesktop/portal'");
    try testing.expect(ns.matches(&m));
    const ns2 = try Rule.parse("path_namespace='/org/freedesktop/por'");
    try testing.expect(!ns2.matches(&m));
    const snd = try Rule.parse("sender=':1.6'");
    try testing.expect(!snd.matches(&m));
    const well_known = try Rule.parse("sender='org.freedesktop.portal.Desktop'");
    try testing.expect(well_known.matches(&m));
    try testing.expectError(error.InvalidMatchRule, Rule.parse("bogus='x'"));
    try testing.expectError(error.InvalidMatchRule, Rule.parse("member='unterminated"));
}

/// A private `dbus-daemon` for tests, or null when none is installed.
/// A private `dbus-daemon` for integration tests (tests only).
pub const TestDaemon = struct {
    child: std.process.Child,
    tmp: testing.TmpDir,
    addr_buf: [300]u8 = undefined,
    addr_len: usize = 0,

    /// Starts it; false when dbus-daemon is not installed.
    pub fn start(d: *TestDaemon) !bool {
        d.tmp = testing.tmpDir(.{});
        var pbuf: [256]u8 = undefined;
        const n = try d.tmp.dir.realPath(testing.io, &pbuf);
        const addr = try std.fmt.bufPrint(&d.addr_buf, "unix:path={s}/bus", .{pbuf[0..n]});
        d.addr_len = addr.len;
        var arg_buf: [320]u8 = undefined;
        const arg = try std.fmt.bufPrint(&arg_buf, "--address={s}", .{addr});
        d.child = std.process.spawn(testing.io, .{
            .argv = &.{ "dbus-daemon", "--session", "--nofork", "--nopidfile", arg },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch {
            d.tmp.cleanup();
            return false;
        };
        // Wait for the socket to appear.
        var tries: usize = 0;
        while (tries < 200) : (tries += 1) {
            if (d.tmp.dir.access(testing.io, "bus", .{})) |_| return true else |_| {}
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        d.stop();
        return error.DaemonDidNotStart;
    }

    /// The bus address.
    pub fn address(d: *const TestDaemon) []const u8 {
        return d.addr_buf[0..d.addr_len];
    }

    /// Kills the daemon and removes its directory.
    pub fn stop(d: *TestDaemon) void {
        d.child.kill(testing.io);
        d.tmp.cleanup();
    }
};

fn listNamesHas(b: *Bus, name: []const u8) !bool {
    var p = try b.call(bus_name, bus_path, bus_name, "ListNames", "", .{});
    defer p.deinit();
    var r = try p.wait(5 * std.time.ns_per_s);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try r.args(arena.allocator());
    for (a[0].array.items) |v| if (std.mem.eql(u8, v.string, name)) return true;
    return false;
}

test "integration: Hello and ListNames against dbus-daemon" {
    var d: TestDaemon = undefined;
    if (!try d.start()) return error.SkipZigTest;
    defer d.stop();
    const b = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer b.deinit();
    try testing.expect(std.mem.startsWith(u8, b.unique_name, ":"));
    try testing.expect(b.unix_fd);
    try testing.expect(try listNamesHas(b, b.unique_name));

    // An error reply comes back as a Reply.
    var p = try b.call("org.example.Missing", "/x", "org.example.Missing", "Nope", "", .{});
    defer p.deinit();
    var r = try p.wait(5 * std.time.ns_per_s);
    defer r.deinit();
    try testing.expect(r.isError());
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.ServiceUnknown", r.errorName().?);
}

const Counter = struct {
    hits: std.atomic.Value(u32) = .init(0),
    last: std.atomic.Value(u32) = .init(0),

    fn handler(c: *Counter) SignalHandler {
        return .{ .ctx = c, .func = on };
    }

    fn on(ctx: ?*anyopaque, in: *const Incoming) void {
        const c: *Counter = @ptrCast(@alignCast(ctx.?));
        const a = in.args() catch return;
        c.last.store(a[0].u32, .release);
        _ = c.hits.fetchAdd(1, .acq_rel);
        testing.io.futexWake(u32, &c.hits.raw, 1);
    }

    fn waitFor(c: *Counter, n: u32) !void {
        var tries: usize = 0;
        while (c.hits.load(.acquire) < n) : (tries += 1) {
            if (tries > 500) return error.Timeout;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
    }
};

/// Round-trips a call so every earlier message has been routed.
fn sync(b: *Bus) !void {
    var p = try b.call(bus_name, bus_path, bus_name, "GetId", "", .{});
    defer p.deinit();
    var r = try p.wait(5 * std.time.ns_per_s);
    r.deinit();
}

test "integration: two subscribers to the same signal both receive it; removing one keeps the other" {
    var d: TestDaemon = undefined;
    if (!try d.start()) return error.SkipZigTest;
    defer d.stop();
    const listener = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer listener.deinit();
    const sender = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer sender.deinit();

    const rule = "type='signal',interface='org.zigguro.Test',member='Ping',path='/org/zigguro/test'";
    var a: Counter = .{};
    var c: Counter = .{};
    const id_a = try listener.addMatch(rule, a.handler());
    _ = try listener.addMatch(rule, c.handler());
    try sync(listener);

    try sender.emit("/org/zigguro/test", "org.zigguro.Test", "Ping", "u", .{@as(u32, 1)});
    try a.waitFor(1);
    try c.waitFor(1);

    listener.removeMatch(id_a);
    try sync(listener);
    try sender.emit("/org/zigguro/test", "org.zigguro.Test", "Ping", "u", .{@as(u32, 2)});
    try c.waitFor(2);
    try testing.expectEqual(2, c.last.load(.acquire));
    try sync(listener);
    try testing.expectEqual(1, a.hits.load(.acquire));
}

test "integration: call from a non-owner thread" {
    var d: TestDaemon = undefined;
    if (!try d.start()) return error.SkipZigTest;
    defer d.stop();
    const b = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer b.deinit();
    var results: [4]bool = @splat(false);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, struct {
        fn run(bus: *Bus, out: *bool) void {
            out.* = listNamesHas(bus, bus.unique_name) catch false;
        }
    }.run, .{ b, &results[i] });
    for (threads) |t| t.join();
    for (results) |r| try testing.expect(r);
}

test "integration: fds travel with a message" {
    var d: TestDaemon = undefined;
    if (!try d.start()) return error.SkipZigTest;
    defer d.stop();
    const listener = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer listener.deinit();
    const sender = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer sender.deinit();

    const Got = struct {
        fd: std.atomic.Value(i32) = .init(-1),
        fn on(ctx: ?*anyopaque, in: *const Incoming) void {
            const g: *@This() = @ptrCast(@alignCast(ctx.?));
            const args = in.args() catch return;
            const fd_in = args[0].unix_fd;
            for (in.fds) |*f| if (f.* == fd_in) {
                f.* = -1;
            };
            g.fd.store(fd_in, .release);
        }
    };
    var got: Got = .{};
    _ = try listener.addMatch("type='signal',member='Fd'", .{ .ctx = &got, .func = Got.on });
    try sync(listener);

    var pipe: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer closeFd(pipe[0]);
    try sender.emit("/t", "org.zigguro.Test", "Fd", "h", .{pipe[1]});
    closeFd(pipe[1]);

    var tries: usize = 0;
    while (got.fd.load(.acquire) < 0) : (tries += 1) {
        if (tries > 500) return error.Timeout;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    const w = got.fd.load(.acquire);
    defer closeFd(w);
    try testing.expectEqual(3, linux.write(w, "abc", 3));
    var buf: [3]u8 = undefined;
    try testing.expectEqual(3, linux.read(pipe[0], &buf, 3));
    try testing.expectEqualStrings("abc", &buf);
}

test "integration: pending calls fail when the bus goes away" {
    var d: TestDaemon = undefined;
    if (!try d.start()) return error.SkipZigTest;
    const b = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer b.deinit();
    // Whether the call races the reader noticing EOF or not, it fails.
    d.stop();
    var p = b.call(bus_name, bus_path, bus_name, "GetId", "", .{}) catch |err| {
        try testing.expect(err == error.Disconnected);
        return;
    };
    defer p.deinit();
    try testing.expectError(error.Disconnected, p.wait(5 * std.time.ns_per_s));
}

test "integration: method handler answers calls; unhandled calls get UnknownMethod" {
    var d: TestDaemon = undefined;
    if (!try d.start()) return error.SkipZigTest;
    defer d.stop();
    const service = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer service.deinit();
    const Echo = struct {
        fn on(_: ?*anyopaque, bus: *Bus, in: *const Incoming) bool {
            if (!std.mem.eql(u8, in.msg.header.member.?, "Echo")) return false;
            const a = in.args() catch return false;
            if (std.mem.eql(u8, a[0].string, "fail")) {
                bus.replyError(in, "org.zigguro.Error.Failed", "asked to fail") catch {};
            } else bus.replyTo(in, "su", .{ a[0].string, @as(u32, 7) }) catch {};
            return true;
        }
    };
    service.setMethodHandler(.{ .ctx = null, .func = Echo.on });
    const client = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer client.deinit();

    var p = try client.call(service.unique_name, "/", "org.zigguro.Test", "Echo", "s", .{"hi"});
    defer p.deinit();
    var r = try p.wait(5 * std.time.ns_per_s);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try r.args(arena.allocator());
    try testing.expectEqualStrings("hi", a[0].string);
    try testing.expectEqual(7, a[1].u32);

    var p2 = try client.call(service.unique_name, "/", "org.zigguro.Test", "Echo", "s", .{"fail"});
    defer p2.deinit();
    var r2 = try p2.wait(5 * std.time.ns_per_s);
    defer r2.deinit();
    try testing.expectEqualStrings("org.zigguro.Error.Failed", r2.errorName().?);

    var p3 = try client.call(service.unique_name, "/", "org.zigguro.Test", "Other", "", .{});
    defer p3.deinit();
    var r3 = try p3.wait(5 * std.time.ns_per_s);
    defer r3.deinit();
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownMethod", r3.errorName().?);
}
