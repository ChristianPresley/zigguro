//! The Streamable HTTP server transport (E11.F05.S02.T01): one endpoint
//! (`/mcp`) serving modern (2026-07-28) requests and legacy sessions
//! (2025-03-26 to 2025-11-25) side by side.
//!
//! Every request first passes the security checks, before its body is
//! read: `Host` names this loopback listener (unless `allow_remote`),
//! `Origin` (when sent) is allowed, and the bearer token matches. Then:
//!
//! - POST, modern: the routing headers must match the body (`-32020`).
//!   Each request gets its own short-lived connection; its answer is JSON,
//!   or an SSE stream once the handler sends anything before it (progress,
//!   logs), when the request asked for progress or logs, or when the
//!   answer takes longer than `keepalive_interval` (so a client that went
//!   away is noticed and the handler canceled).
//! - POST, legacy: `initialize` mints an `Mcp-Session-Id`; later requests
//!   carry it (400 without, 404 when unknown or ended). Server requests
//!   made during a call ride on that call's SSE stream; the client's
//!   answers come back as POST bodies (202).
//! - GET: a legacy session's stream for notifications outside any call;
//!   405 for modern clients. No resumability (`Last-Event-ID` ignored).
//! - DELETE: ends a session (200); 405 otherwise.
//!
//! SSE streams get a `:` comment every `keepalive_interval`. The 2024-11-05
//! HTTP+SSE server mode is not implemented.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../../protocol/root.zig");
const Server = @import("../Server.zig");
const validate = @import("http_validate.zig");

const message = zg_jsonrpc.message;
const errors = protocol.errors;
const log = std.log.scoped(.mcp_http_server);

pub const HttpServerOptions = struct {
    /// Loopback with an ephemeral port by default.
    address: Io.net.IpAddress = .{ .ip4 = .loopback(0) },
    path: []const u8 = "/mcp",
    /// Accept non-loopback binds and any `Host`. Logs a warning.
    allow_remote: bool = false,
    /// Required as `Authorization: Bearer <hex>` when set (the IDE hub).
    bearer_token: ?[32]u8 = null,
    /// Requests with an `Origin` not listed here get 403.
    allowed_origins: []const []const u8 = &.{},
    enable_legacy_sessions: bool = true,
    keepalive_interval: Io.Duration = .fromSeconds(15),
    max_body_bytes: u32 = 16 * 1024 * 1024,
};

/// A running HTTP endpoint for one `Server`. Deinit it before the server.
pub const HttpListener = struct {
    server: *Server,
    gpa: Allocator,
    io: Io,
    opts: HttpServerOptions,
    net: Io.net.Server,
    /// The bound port (for discovery files).
    port: u16,
    accept_future: Io.Future(void) = undefined,
    conns: Io.Group = .init,
    mutex: Io.Mutex = .init,
    sessions: std.ArrayList(*Session) = .empty,

    /// Stops accepting, ends every connection and session.
    pub fn deinit(l: *HttpListener) void {
        l.accept_future.cancel(l.io);
        l.conns.cancel(l.io);
        l.net.deinit(l.io);
        l.mutex.lockUncancelable(l.io);
        const all = l.sessions.toOwnedSlice(l.gpa) catch &.{};
        l.mutex.unlock(l.io);
        for (all) |sess| sess.end();
        l.gpa.free(all);
        l.gpa.destroy(l);
    }

    /// `http://127.0.0.1:<port><path>` in `buf`.
    pub fn url(l: *const HttpListener, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ l.port, l.opts.path }) catch unreachable;
    }

    fn acceptLoop(l: *HttpListener) void {
        while (true) {
            const stream = l.net.accept(l.io) catch return;
            l.conns.concurrent(l.io, serveConn, .{ l, stream }) catch {
                stream.close(l.io);
                return;
            };
        }
    }

    fn serveConn(l: *HttpListener, stream: Io.net.Stream) void {
        defer stream.close(l.io);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var sr = stream.reader(l.io, &rbuf);
        var sw = stream.writer(l.io, &wbuf);
        var http: std.http.Server = .init(&sr.interface, &sw.interface);
        while (true) {
            var req = http.receiveHead() catch return;
            var arena: std.heap.ArenaAllocator = .init(l.gpa);
            defer arena.deinit();
            const keep = l.handle(&req, arena.allocator()) catch return;
            if (!keep) return;
        }
    }

    /// Answers one request; false closes the connection.
    fn handle(l: *HttpListener, req: *std.http.Server.Request, a: Allocator) !bool {
        // Head strings live in the read buffer, which the body overwrites.
        var list: std.ArrayList(std.http.Header) = .empty;
        var it = req.iterateHeaders();
        while (it.next()) |h| try list.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
        const hs: validate.Headers = .{ .list = list.items };
        const target = try a.dupe(u8, req.head.target);

        if (!validate.hostAllowed(hs.get("host"), l.port, l.opts.allow_remote))
            return reject(req, .forbidden, errors.invalid_request, "Forbidden: Host is not this server", &.{});
        if (!validate.originAllowed(hs.get("origin"), l.opts.allowed_origins))
            return reject(req, .forbidden, errors.invalid_request, "Forbidden: Origin not allowed", &.{});
        if (!validate.bearerAllowed(hs.get("authorization"), l.opts.bearer_token))
            return reject(req, .unauthorized, errors.invalid_request, "Unauthorized", &.{.{ .name = "www-authenticate", .value = "Bearer realm=\"zigguro\"" }});
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        if (!std.mem.eql(u8, path, l.opts.path)) return reject(req, .not_found, errors.invalid_request, "Not found", &.{});

        return switch (req.head.method) {
            .POST => l.post(req, a, hs),
            .GET => l.get(req, hs),
            .DELETE => l.delete(req, hs),
            else => reject(req, .method_not_allowed, errors.invalid_request, "Method not allowed", &.{}),
        };
    }

    fn post(l: *HttpListener, req: *std.http.Server.Request, a: Allocator, hs: validate.Headers) !bool {
        if (req.head.content_length) |n| if (n > l.opts.max_body_bytes)
            return reject(req, .payload_too_large, errors.invalid_request, "Body too large", &.{});
        var bbuf: [4096]u8 = undefined;
        const rd = try req.readerExpectContinue(&bbuf);
        const body = rd.allocRemaining(a, .limited(l.opts.max_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return reject(req, .payload_too_large, errors.invalid_request, "Body too large", &.{}),
            else => return err,
        };
        const msg = switch (message.parse(a, body)) {
            .single => |m| m,
            .batch => return respondError(req, .bad_request, .null, errors.invalid_request, "Batches are not supported"),
            .invalid => |e| return respondError(req, .bad_request, .null, e.code, e.message),
        };
        const session_id = hs.get("mcp-session-id");
        switch (msg) {
            .response, .notification => {
                if (session_id) |sid| {
                    const sess = l.acquire(sid) orelse return respondError(req, .not_found, .null, errors.invalid_request, "Unknown session");
                    defer sess.release();
                    sess.conn.receive(body);
                }
                // Modern notifications have no session to act on.
                try req.respond("", .{ .status = .accepted });
                return true;
            },
            .request => |r| {
                if (std.mem.eql(u8, r.method, "initialize")) {
                    if (!l.opts.enable_legacy_sessions) return respondError(req, .not_found, r.id, errors.method_not_found, "Method not found");
                    return l.initialize(req, a, r.id, body);
                }
                if (session_id) |sid| {
                    const sess = l.acquire(sid) orelse return respondError(req, .not_found, r.id, errors.invalid_request, "Unknown or ended session");
                    defer sess.release();
                    if (hs.get("mcp-protocol-version")) |v| {
                        const rev = protocol.Revision.parse(v);
                        if (rev == null or rev.? != sess.revision()) return respondError(req, .bad_request, r.id, errors.invalid_request, "Invalid MCP-Protocol-Version");
                    }
                    return l.sessionRequest(req, sess, r.id, body);
                }
                return l.modern(req, a, hs, r, body);
            },
        }
    }

    fn modern(l: *HttpListener, req: *std.http.Server.Request, a: Allocator, hs: validate.Headers, r: message.Request, body: []const u8) !bool {
        const params: Value = if (r.params) |p| protocol.codec.parseValue(a, p.bytes) catch .null else .{ .object = .empty };
        const has_pv = params == .object and if (params.object.get("_meta")) |m| m == .object and m.object.get(protocol.meta_keys.protocol_version) != null else false;
        if (!has_pv) return respondError(req, .bad_request, r.id, errors.invalid_request, "Missing Mcp-Session-Id (legacy) or _meta protocolVersion (modern)");
        if (protocol.Method.fromString(r.method) == null) return respondError(req, .not_found, r.id, errors.method_not_found, "Method not found");
        var tool_schema: ?Value = null;
        if (std.mem.eql(u8, r.method, "tools/call")) if (params.object.get("name")) |n| if (n == .string) {
            if (l.server.registry.snapshot().tool(n.string)) |t| tool_schema = t.def.input_schema;
        };
        if (try validate.checkModern(a, hs, r.method, params, tool_schema)) |why|
            return respondError(req, .bad_request, r.id, errors.header_mismatch, why);
        const meta = params.object.get("_meta").?.object;
        const eager = meta.get(protocol.meta_keys.progress_token) != null or meta.get(protocol.meta_keys.log_level) != null;

        var w: Waiter = .{ .gpa = l.gpa, .io = l.io, .id = r.id };
        defer w.deinit();
        const conn = try l.server.connect(.{ .ctx = &w, .send = Waiter.sendThunk }, null);
        conn.receive(body);
        const outcome = l.deliver(req, &w, eager, &.{});
        // A client that went away cancels the handler (closing the connection).
        l.server.disconnect(conn);
        return outcome;
    }

    fn initialize(l: *HttpListener, req: *std.http.Server.Request, a: Allocator, id: protocol.RequestId, body: []const u8) !bool {
        _ = a;
        const sess = try Session.create(l);
        // Ours until the answer is written; the listener's list takes the first.
        _ = sess.refs.fetchAdd(1, .monotonic);
        defer sess.release();
        var w: Waiter = .{ .gpa = l.gpa, .io = l.io, .id = id };
        defer w.deinit();
        try sess.add(&w);
        sess.conn.receive(body);
        sess.remove(&w);
        const ok = blk: {
            w.mutex.lockUncancelable(l.io);
            defer w.mutex.unlock(l.io);
            break :blk w.final != null and std.mem.indexOf(u8, w.final.?, "\"result\"") != null;
        };
        if (!ok) {
            sess.end();
            return l.deliver(req, &w, false, &.{});
        }
        l.mutex.lockUncancelable(l.io);
        l.sessions.append(l.gpa, sess) catch {
            l.mutex.unlock(l.io);
            sess.end();
            return error.OutOfMemory;
        };
        l.mutex.unlock(l.io);
        return l.deliver(req, &w, false, &.{.{ .name = "mcp-session-id", .value = &sess.id }});
    }

    fn sessionRequest(l: *HttpListener, req: *std.http.Server.Request, sess: *Session, id: protocol.RequestId, body: []const u8) !bool {
        var w: Waiter = .{ .gpa = l.gpa, .io = l.io, .id = id };
        defer w.deinit();
        try sess.add(&w);
        defer sess.remove(&w);
        sess.conn.receive(body);
        // Legacy: a disconnect is not a cancellation.
        return l.deliver(req, &w, false, &.{});
    }

    fn get(l: *HttpListener, req: *std.http.Server.Request, hs: validate.Headers) !bool {
        const sid = hs.get("mcp-session-id") orelse return reject(req, .method_not_allowed, errors.invalid_request, "Method not allowed", &.{});
        const sess = l.acquire(sid) orelse return respondError(req, .not_found, .null, errors.invalid_request, "Unknown or ended session");
        defer sess.release();
        var w: Waiter = .{ .gpa = l.gpa, .io = l.io, .id = null };
        defer w.deinit();
        try sess.setGet(&w);
        defer sess.clearGet(&w);
        return l.deliver(req, &w, true, &.{});
    }

    fn delete(l: *HttpListener, req: *std.http.Server.Request, hs: validate.Headers) !bool {
        const sid = hs.get("mcp-session-id") orelse return reject(req, .method_not_allowed, errors.invalid_request, "Method not allowed", &.{});
        l.mutex.lockUncancelable(l.io);
        const sess: ?*Session = for (l.sessions.items, 0..) |x, i| {
            if (std.mem.eql(u8, &x.id, sid)) break l.sessions.swapRemove(i);
        } else null;
        l.mutex.unlock(l.io);
        const s = sess orelse return respondError(req, .not_found, .null, errors.invalid_request, "Unknown or ended session");
        s.end();
        try req.respond("", .{});
        return true;
    }

    fn acquire(l: *HttpListener, sid: []const u8) ?*Session {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        for (l.sessions.items) |x| if (std.mem.eql(u8, &x.id, sid)) {
            _ = x.refs.fetchAdd(1, .monotonic);
            return x;
        };
        return null;
    }

    /// Delivers `w`'s messages: JSON when the answer comes first, else SSE.
    /// Returns false when the client went away.
    fn deliver(l: *HttpListener, req: *std.http.Server.Request, w: *Waiter, eager: bool, extra: []const std.http.Header) bool {
        var buf: [8 * 1024]u8 = undefined;
        var bw: ?std.http.BodyWriter = null;
        var hdrs: [8]std.http.Header = undefined;
        var n: usize = 0;
        for ([_]std.http.Header{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
            .{ .name = "x-accel-buffering", .value = "no" },
        }) |h| {
            hdrs[n] = h;
            n += 1;
        }
        for (extra) |h| {
            hdrs[n] = h;
            n += 1;
        }
        const started = Io.Timestamp.now(l.io, .awake);
        var last_write = started;
        while (true) {
            var items: std.ArrayList([]u8) = .empty;
            var final: ?[]u8 = null;
            var ended = false;
            {
                w.mutex.lockUncancelable(l.io);
                defer w.mutex.unlock(l.io);
                items = w.msgs;
                w.msgs = .empty;
                final = w.final;
                w.final = null;
                ended = w.ended;
            }
            defer {
                for (items.items) |m| l.gpa.free(m);
                items.deinit(l.gpa);
                if (final) |f| l.gpa.free(f);
            }
            const now = Io.Timestamp.now(l.io, .awake);
            const slow = started.durationTo(now).nanoseconds >= l.opts.keepalive_interval.nanoseconds;
            if (bw == null and (items.items.len > 0 or eager or slow or (ended and final == null))) {
                bw = req.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = hdrs[0..n] } }) catch return false;
                if (eager or slow) {
                    // Commit the head now so the client sees the stream open.
                    bw.?.writer.writeAll(": stream\n\n") catch return false;
                    flush(&bw.?) catch return false;
                }
                last_write = now;
            }
            if (bw) |*b| {
                for (items.items) |m| {
                    b.writer.print("event: message\ndata: {s}\n\n", .{m}) catch return false;
                }
                if (items.items.len > 0) {
                    flush(b) catch return false;
                    last_write = now;
                }
            }
            if (final) |f| {
                if (bw) |*b| {
                    b.writer.print("event: message\ndata: {s}\n\n", .{f}) catch return false;
                    b.end() catch return false;
                } else {
                    var jh: [4]std.http.Header = undefined;
                    jh[0] = .{ .name = "content-type", .value = "application/json" };
                    const jn = @min(extra.len, jh.len - 1);
                    @memcpy(jh[1..][0..jn], extra[0..jn]);
                    req.respond(f, .{ .extra_headers = jh[0 .. 1 + jn] }) catch return false;
                }
                return true;
            }
            if (ended) {
                if (bw) |*b| b.end() catch return false;
                return true;
            }
            if (bw) |*b| if (last_write.durationTo(now).nanoseconds >= l.opts.keepalive_interval.nanoseconds) {
                b.writer.writeAll(": keepalive\n\n") catch return false;
                flush(b) catch return false;
                last_write = now;
            };
            l.io.sleep(.fromMilliseconds(1), .awake) catch return false;
        }
    }
};

fn flush(b: *std.http.BodyWriter) !void {
    try b.writer.flush();
    try b.flush();
}

/// Binds and starts serving `s`. The default bind is loopback.
pub fn listenHttp(s: *Server, opts: HttpServerOptions) !*HttpListener {
    const loopback = switch (opts.address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &(Io.net.Ip6Address.loopback(0).bytes)),
    };
    if (!loopback) {
        if (!opts.allow_remote) return error.RemoteNotAllowed;
        log.warn("MCP HTTP server listening on a non-loopback address; remote clients can connect", .{});
    } else if (opts.allow_remote) log.warn("MCP HTTP server accepts any Host header (allow_remote)", .{});
    const l = try s.gpa.create(HttpListener);
    errdefer s.gpa.destroy(l);
    var net = try opts.address.listen(s.io, .{ .reuse_address = true });
    errdefer net.deinit(s.io);
    l.* = .{ .server = s, .gpa = s.gpa, .io = s.io, .opts = opts, .net = net, .port = net.socket.address.getPort() };
    l.accept_future = try s.io.concurrent(HttpListener.acceptLoop, .{l});
    return l;
}

/// Answers with a JSON-RPC error body and closes the connection (the body
/// was not read).
fn reject(req: *std.http.Server.Request, status: std.http.Status, code: i32, msg: []const u8, extra: []const std.http.Header) bool {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    message.writeError(&w, .null, code, msg, null) catch {};
    var hdrs: [4]std.http.Header = undefined;
    hdrs[0] = .{ .name = "content-type", .value = "application/json" };
    const n = @min(extra.len, 3);
    @memcpy(hdrs[1..][0..n], extra[0..n]);
    req.respond(w.buffered(), .{ .status = status, .keep_alive = false, .extra_headers = hdrs[0 .. 1 + n] }) catch {};
    return false;
}

fn respondError(req: *std.http.Server.Request, status: std.http.Status, id: protocol.RequestId, code: i32, msg: []const u8) bool {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    message.writeError(&w, id, code, msg, null) catch {};
    req.respond(w.buffered(), .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} }) catch return false;
    return true;
}

/// Messages for one HTTP response: the answer to request `id` (or, for a
/// GET stream, `id == null`) and whatever comes before it.
const Waiter = struct {
    gpa: Allocator,
    io: Io,
    id: ?protocol.RequestId,
    mutex: Io.Mutex = .init,
    msgs: std.ArrayList([]u8) = .empty,
    final: ?[]u8 = null,
    /// The session ended (GET streams).
    ended: bool = false,

    fn deinit(w: *Waiter) void {
        for (w.msgs.items) |m| w.gpa.free(m);
        w.msgs.deinit(w.gpa);
        if (w.final) |f| w.gpa.free(f);
    }

    fn sendThunk(ctx: ?*anyopaque, body: []const u8) void {
        const w: *Waiter = @ptrCast(@alignCast(ctx.?));
        w.push(body, w.isFinal(body));
    }

    /// Whether `body` answers this waiter's request.
    fn isFinal(w: *Waiter, body: []const u8) bool {
        const id = w.id orelse return false;
        var scratch: std.heap.ArenaAllocator = .init(w.gpa);
        defer scratch.deinit();
        return switch (message.parse(scratch.allocator(), body)) {
            .single => |m| m == .response and m.response.id.eql(id),
            else => false,
        };
    }

    fn push(w: *Waiter, body: []const u8, final: bool) void {
        const copy = w.gpa.dupe(u8, body) catch return;
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        if (final) {
            if (w.final) |old| w.gpa.free(old);
            w.final = copy;
        } else w.msgs.append(w.gpa, copy) catch w.gpa.free(copy);
    }
};

/// A legacy session: its server connection, the POSTs waiting on it and
/// its GET stream. Refcounted: the listener's list holds one reference.
const Session = struct {
    l: *HttpListener,
    id: [32]u8,
    conn: *Server.Conn,
    mutex: Io.Mutex = .init,
    posts: std.ArrayList(*Waiter) = .empty,
    get_stream: ?*Waiter = null,
    refs: std.atomic.Value(u32) = .init(1),
    ended: bool = false,

    fn create(l: *HttpListener) !*Session {
        const sess = try l.gpa.create(Session);
        errdefer l.gpa.destroy(sess);
        var raw: [16]u8 = undefined;
        l.io.randomSecure(&raw) catch l.io.random(&raw);
        sess.* = .{ .l = l, .id = std.fmt.bytesToHex(raw, .lower), .conn = undefined };
        sess.conn = try l.server.connect(.{ .ctx = sess, .send = route }, null);
        return sess;
    }

    fn revision(sess: *Session) ?protocol.Revision {
        const s = sess.l.server;
        sess.conn.mutex.lockUncancelable(s.io);
        defer sess.conn.mutex.unlock(s.io);
        return if (sess.conn.state.legacy) |lg| lg.revision else null;
    }

    fn add(sess: *Session, w: *Waiter) !void {
        sess.mutex.lockUncancelable(sess.l.io);
        defer sess.mutex.unlock(sess.l.io);
        try sess.posts.append(sess.l.gpa, w);
    }

    fn remove(sess: *Session, w: *Waiter) void {
        sess.mutex.lockUncancelable(sess.l.io);
        defer sess.mutex.unlock(sess.l.io);
        for (sess.posts.items, 0..) |x, i| if (x == w) {
            _ = sess.posts.orderedRemove(i);
            return;
        };
    }

    fn setGet(sess: *Session, w: *Waiter) !void {
        sess.mutex.lockUncancelable(sess.l.io);
        defer sess.mutex.unlock(sess.l.io);
        if (sess.get_stream) |old| {
            old.mutex.lockUncancelable(sess.l.io);
            old.ended = true;
            old.mutex.unlock(sess.l.io);
        }
        sess.get_stream = w;
    }

    fn clearGet(sess: *Session, w: *Waiter) void {
        sess.mutex.lockUncancelable(sess.l.io);
        defer sess.mutex.unlock(sess.l.io);
        if (sess.get_stream == w) sess.get_stream = null;
    }

    /// Server output: answers go to their POST, the rest to the newest
    /// POST still open, else the GET stream, else nowhere.
    fn route(ctx: ?*anyopaque, body: []const u8) void {
        const sess: *Session = @ptrCast(@alignCast(ctx.?));
        sess.mutex.lockUncancelable(sess.l.io);
        defer sess.mutex.unlock(sess.l.io);
        for (sess.posts.items) |w| if (w.isFinal(body)) return w.push(body, true);
        if (sess.posts.items.len > 0) return sess.posts.items[sess.posts.items.len - 1].push(body, false);
        if (sess.get_stream) |g| g.push(body, false);
    }

    /// Ends the session: no more routing, the GET stream closes, and the
    /// listener's reference is dropped.
    fn end(sess: *Session) void {
        {
            sess.mutex.lockUncancelable(sess.l.io);
            defer sess.mutex.unlock(sess.l.io);
            sess.ended = true;
            if (sess.get_stream) |g| {
                g.mutex.lockUncancelable(sess.l.io);
                g.ended = true;
                g.mutex.unlock(sess.l.io);
            }
        }
        sess.release();
    }

    fn release(sess: *Session) void {
        if (sess.refs.fetchSub(1, .acq_rel) != 1) return;
        sess.l.server.disconnect(sess.conn);
        sess.posts.deinit(sess.l.gpa);
        sess.l.gpa.destroy(sess);
    }
};
