//! The xdg-desktop-portal request pattern. A call passes a `handle_token`;
//! the answer arrives as a `Response(u response, a{sv} results)` signal on
//! the request object `/org/freedesktop/portal/desktop/request/<sender>/<token>`.
//! The match is added before the call, so a Response that races the
//! method reply is not lost. Old portals that return a different handle
//! are followed with `adoptHandle`.

const std = @import("std");
const dbus = struct {
    const conn = @import("../dbus/conn.zig");
    const marshal = @import("../dbus/marshal.zig");
    const variant = @import("../dbus/variant.zig");
};
const Bus = dbus.conn.Bus;
const Value = dbus.variant.Value;

/// The portal service name.
pub const destination = "org.freedesktop.portal.Desktop";
/// The portal object path.
pub const object_path = "/org/freedesktop/portal/desktop";
/// The D-Bus error a missing portal gives.
pub const service_unknown = "org.freedesktop.DBus.Error.ServiceUnknown";

/// The `response` codes.
pub const Code = enum(u32) {
    success = 0,
    cancelled = 1,
    other = 2,
    _,
};

/// A finished request: its code and decoded results (in `arena`).
pub const Response = struct {
    code: Code,
    /// The portal (or the bus) is missing: fall back to built-in UI.
    unavailable: bool = false,
    /// The `a{sv}` results.
    results: dbus.variant.Dict,
    arena: std.heap.ArenaAllocator,

    /// Frees the results.
    pub fn deinit(r: *Response) void {
        r.arena.deinit();
    }

    /// Result `key`, through its variant.
    pub fn get(r: *const Response, key: []const u8) ?Value {
        return if (r.results.get(key)) |v| v.unwrap() else null;
    }
};

/// Called once with the response (on the bus reader thread). The
/// callee owns the response and must `deinit` it.
pub const Callback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, r: *Response) void,
};

var token_counter: std.atomic.Value(u32) = .init(0);

/// One pending portal request.
pub const Request = struct {
    gpa: std.mem.Allocator,
    bus: *Bus,
    token_buf: [16]u8 = undefined,
    token_len: usize = 0,
    path_buf: [160]u8 = undefined,
    path_len: usize = 0,
    matches: [2]?dbus.conn.MatchId = .{ null, null },
    callback: ?Callback,
    lock: std.Io.Mutex = .init,
    /// 0 waiting, 1 done.
    state: std.atomic.Value(u32) = .init(0),
    /// 1 once the call's reply was handled. A Response can come first, and
    /// the reply handler still holds the request until then.
    replied: std.atomic.Value(u32) = .init(0),
    response: ?Response = null,

    /// Predicts the request path and subscribes to its Response. Pass
    /// `token()` as the call's `handle_token`. With a callback, the
    /// response goes there; otherwise `wait` for it.
    pub fn begin(gpa: std.mem.Allocator, bus: *Bus, callback: ?Callback) !*Request {
        const r = try gpa.create(Request);
        errdefer gpa.destroy(r);
        r.* = .{ .gpa = gpa, .bus = bus, .callback = callback };
        const n = token_counter.fetchAdd(1, .monotonic);
        r.token_len = (std.fmt.bufPrint(&r.token_buf, "zg{d}", .{n}) catch unreachable).len;
        r.path_len = (try predictPath(&r.path_buf, bus.unique_name, r.token())).len;
        r.matches[0] = try r.subscribe(r.path());
        return r;
    }

    /// The token for `handle_token`.
    pub fn token(r: *const Request) []const u8 {
        return r.token_buf[0..r.token_len];
    }

    /// The predicted request path.
    pub fn path(r: *const Request) []const u8 {
        return r.path_buf[0..r.path_len];
    }

    fn subscribe(r: *Request, p: []const u8) !dbus.conn.MatchId {
        var buf: [256]u8 = undefined;
        const rule = try std.fmt.bufPrint(&buf, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{p});
        return r.bus.addMatch(rule, .{ .ctx = r, .func = onResponse });
    }

    /// Follows the handle the call returned when it differs from the
    /// prediction (portals before version 0.9).
    pub fn adoptHandle(r: *Request, handle: []const u8) !void {
        if (std.mem.eql(u8, handle, r.path()) or r.matches[1] != null) return;
        r.matches[1] = try r.subscribe(handle);
    }

    fn onResponse(ctx: ?*anyopaque, in: *const dbus.conn.Incoming) void {
        const r: *Request = @ptrCast(@alignCast(ctx.?));
        if (r.state.load(.acquire) != 0) return;
        var resp: Response = .{ .code = .other, .results = .{ .key_sig = "s", .value_sig = "v" }, .arena = .init(r.gpa) };
        // Decode a copy of the body in our own arena: strings are views
        // into the buffer, and the message is gone after this call.
        const arena = resp.arena.allocator();
        const decoded = blk: {
            const body = arena.dupe(u8, in.msg.body) catch break :blk error.OutOfMemory;
            var d: dbus.marshal.Decoder = .{ .buf = body, .big_endian = in.msg.big_endian, .arena = arena };
            break :blk d.decodeAll(in.msg.header.signature);
        };
        if (decoded) |a| {
            if (a.len == 2 and a[0] == .u32 and a[1] == .dict) {
                resp.code = @enumFromInt(a[0].u32);
                resp.results = a[1].dict;
            }
        } else |_| {}
        r.finish(resp);
    }

    /// Completes the request without a Response (the call failed);
    /// `unavailable` when no portal answered.
    pub fn fail(r: *Request, code: Code, unavailable: bool) void {
        if (r.state.load(.acquire) != 0) return;
        r.finish(.{ .code = code, .unavailable = unavailable, .results = .{ .key_sig = "s", .value_sig = "v" }, .arena = .init(r.gpa) });
    }

    /// A reply handler for the portal call: follows the returned handle,
    /// or fails the request when the call errored.
    pub fn replyHandler(r: *Request) dbus.conn.ReplyHandler {
        return .{ .ctx = r, .func = onReply };
    }

    fn onReply(ctx: ?*anyopaque, result: dbus.conn.Error!*dbus.conn.Reply) void {
        const r: *Request = @ptrCast(@alignCast(ctx.?));
        defer {
            r.replied.store(1, .release);
            r.bus.io.futexWake(u32, &r.replied.raw, 1);
        }
        const reply = result catch {
            r.fail(.other, true);
            return;
        };
        if (reply.errorName()) |name| {
            const missing = std.mem.eql(u8, name, service_unknown) or std.mem.eql(u8, name, "org.freedesktop.DBus.Error.NameHasNoOwner") or std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownMethod") or std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownInterface");
            r.fail(.other, missing);
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const a = reply.args(arena.allocator()) catch return;
        if (a.len == 1) if (a[0].asString()) |h| r.adoptHandle(h) catch {};
    }

    fn finish(r: *Request, resp: Response) void {
        r.lock.lockUncancelable(r.bus.io);
        if (r.state.load(.acquire) != 0) {
            r.lock.unlock(r.bus.io);
            var dropped = resp;
            dropped.deinit();
            return;
        }
        var owned = resp;
        if (r.callback) |cb| {
            r.state.store(1, .release);
            r.lock.unlock(r.bus.io);
            cb.func(cb.ctx, &owned);
            return;
        }
        r.response = owned;
        r.state.store(1, .release);
        r.lock.unlock(r.bus.io);
        r.bus.io.futexWake(u32, &r.state.raw, 1);
    }

    /// Waits for the response (requests without a callback) and for the
    /// call's reply, so the request can be freed afterwards.
    pub fn wait(r: *Request, timeout_ns: ?u64) !Response {
        const io = r.bus.io;
        const deadline: ?i96 = if (timeout_ns) |t| std.Io.Clock.awake.now(io).nanoseconds + t else null;
        for ([_]*std.atomic.Value(u32){ &r.state, &r.replied }) |word| {
            while (word.load(.acquire) == 0) {
                var t: std.Io.Timeout = .none;
                if (deadline) |d| {
                    const left = d - std.Io.Clock.awake.now(io).nanoseconds;
                    if (left <= 0) return error.Timeout;
                    t = .{ .duration = .{ .raw = .fromNanoseconds(left), .clock = .awake } };
                }
                io.futexWaitTimeout(u32, &word.raw, 0, t) catch {};
            }
        }
        r.lock.lockUncancelable(io);
        defer r.lock.unlock(io);
        const resp = r.response orelse return error.Timeout;
        r.response = null;
        return resp;
    }

    /// True once both the response (or failure) and the call's reply
    /// were handled: nothing on the bus refers to the request any more
    /// except its matches, which `deinit` removes.
    pub fn settled(r: *const Request) bool {
        return r.state.load(.acquire) != 0 and r.replied.load(.acquire) != 0;
    }

    /// Unsubscribes and frees the request. Safe once it has `settled`
    /// (`wait` returned, or the callback ran and the reply came).
    pub fn deinit(r: *Request) void {
        for (r.matches) |m| if (m) |id| r.bus.removeMatch(id);
        r.free();
    }

    /// Frees the request after its bus was closed: closing fails the
    /// pending call, and the bus drops the matches itself.
    pub fn free(r: *Request) void {
        if (r.response) |*resp| resp.deinit();
        r.gpa.destroy(r);
    }
};

/// `/org/freedesktop/portal/desktop/request/<sender>/<token>`, where the
/// sender loses its ':' and has '.' replaced by '_'.
pub fn predictPath(out: []u8, unique_name: []const u8, tok: []const u8) error{NameTooLong}![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(object_path ++ "/request/") catch return error.NameTooLong;
    for (unique_name) |c| switch (c) {
        ':' => {},
        '.' => w.writeByte('_') catch return error.NameTooLong,
        else => w.writeByte(c) catch return error.NameTooLong,
    };
    w.print("/{s}", .{tok}) catch return error.NameTooLong;
    return w.buffered();
}

/// Percent-decodes a `file://` URI into an absolute path; null for other
/// schemes or remote hosts.
pub fn fileUriToPath(out: []u8, uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, prefix)) return null;
    var rest = uri[prefix.len..];
    if (!std.mem.startsWith(u8, rest, "/")) {
        // file://host/path: only localhost is ours.
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (!std.ascii.eqlIgnoreCase(rest[0..slash], "localhost")) return null;
        rest = rest[slash..];
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (n += 1) {
        if (n == out.len) return null;
        if (rest[i] == '%') {
            if (i + 2 >= rest.len) return null;
            out[n] = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            out[n] = rest[i];
            i += 1;
        }
    }
    if (std.mem.indexOfScalar(u8, out[0..n], 0) != null) return null;
    return out[0..n];
}

const testing = std.testing;

test "request path prediction" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/org/freedesktop/portal/desktop/request/1_42/zg7", try predictPath(&buf, ":1.42", "zg7"));
    var small: [8]u8 = undefined;
    try testing.expectError(error.NameTooLong, predictPath(&small, ":1.42", "zg7"));
}

test "uris → paths decoding" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/My File#1.txt", fileUriToPath(&buf, "file:///home/u/My%20File%231.txt").?);
    try testing.expectEqualStrings("/tmp/ä", fileUriToPath(&buf, "file:///tmp/%C3%A4").?);
    try testing.expectEqualStrings("/x", fileUriToPath(&buf, "file://localhost/x").?);
    try testing.expectEqual(null, fileUriToPath(&buf, "file://other/x"));
    try testing.expectEqual(null, fileUriToPath(&buf, "https://example.com/x"));
    try testing.expectEqual(null, fileUriToPath(&buf, "file:///bad%2"));
    try testing.expectEqual(null, fileUriToPath(&buf, "file:///nul%00"));
}
