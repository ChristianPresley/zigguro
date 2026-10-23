//! The headless host's local IPC (E13.F01.S01.T03): one host per
//! workspace (`runs/host.lock`), a JSON-RPC 2.0 server on a Unix socket,
//! token authentication and run event subscriptions that replay what a
//! reconnecting client missed.
//!
//! Files under `.zigguro/runs`: `host.lock` (held exclusively by the host;
//! the OS drops the lock when the process dies; holds its pid),
//! `host.token` (64 hex chars, owner-only), `host.addr` (the socket path
//! actually used) and `host.sock` when that path fits `UnixAddress`.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const run = @import("run.zig");
const protocol = @import("protocol.zig");
const RunRegistry = @import("registry.zig");
const RunHost = @import("host.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;
const Endpoint = zg_jsonrpc.Endpoint;
const RawJson = zg_jsonrpc.message.RawJson;
const RunId = run.RunId;

pub const lock_name = RunRegistry.host_lock_name;
pub const token_name = "host.token";
pub const addr_name = "host.addr";
pub const sock_name = "host.sock";

pub fn currentPid() i64 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => 0,
    };
}

// ---- the single-host lock ----

pub const HostLock = struct {
    file: Io.File,

    /// Takes `host.lock` in `runs` and writes our pid into it; null when
    /// another process holds it.
    pub fn acquire(io: Io, runs: Io.Dir) !?HostLock {
        const f = try runs.createFile(io, lock_name, .{ .truncate = false, .read = true });
        errdefer f.close(io);
        if (!try f.tryLock(io, .exclusive)) {
            f.close(io);
            return null;
        }
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}\n", .{currentPid()}) catch unreachable;
        try f.setLength(io, 0);
        try f.writePositionalAll(io, s, 0);
        return .{ .file = f };
    }

    pub fn release(l: HostLock, io: Io) void {
        l.file.unlock(io);
        l.file.close(io);
    }

    /// The pid written by the lock holder, if readable.
    pub fn holderPid(io: Io, runs: Io.Dir) ?i64 {
        var buf: [32]u8 = undefined;
        const f = runs.openFile(io, lock_name, .{}) catch return null;
        defer f.close(io);
        const n = f.readPositional(io, &.{&buf}, 0) catch return null;
        return std.fmt.parseInt(i64, std.mem.trim(u8, buf[0..n], " \r\n"), 10) catch null;
    }
};

// ---- token ----

pub const Token = [32]u8;

/// The workspace's host token, created (owner-only) when missing.
pub fn ensureToken(io: Io, runs: Io.Dir) !Token {
    if (readToken(io, runs)) |t| return t;
    var t: Token = undefined;
    try io.randomSecure(&t);
    const hex = std.fmt.bytesToHex(t, .lower);
    const perms: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    runs.writeFile(io, .{ .sub_path = token_name, .data = &hex, .flags = .{ .exclusive = true, .permissions = perms } }) catch |e| switch (e) {
        // Lost a race with another process: use theirs.
        error.PathAlreadyExists => return readToken(io, runs) orelse error.InvalidToken,
        else => return e,
    };
    return t;
}

pub fn readToken(io: Io, runs: Io.Dir) ?Token {
    var buf: [64]u8 = undefined;
    const f = runs.openFile(io, token_name, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositional(io, &.{&buf}, 0) catch return null;
    if (n != 64) return null;
    var t: Token = undefined;
    _ = std.fmt.hexToBytes(&t, &buf) catch return null;
    return t;
}

// ---- socket paths ----

/// First 16 hex chars of BLAKE3(root): names runtime-dir sockets.
pub fn workspaceKey(root: []const u8) [16]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(root, &h, .{});
    return std.fmt.bytesToHex(h[0..8].*, .lower);
}

/// `<runs>/host.sock` when it fits `UnixAddress.max_len`, else
/// `<runtime_dir>/zigguro/<key>.sock`. `runs_abs` is absolute.
pub fn socketPath(gpa: Allocator, runs_abs: []const u8, runtime_dir: ?[]const u8) ![]u8 {
    const direct = try std.fs.path.join(gpa, &.{ runs_abs, sock_name });
    if (direct.len <= net.UnixAddress.max_len) return direct;
    gpa.free(direct);
    const key = workspaceKey(runs_abs);
    const base = runtime_dir orelse "/tmp";
    const p = try std.fmt.allocPrint(gpa, "{s}{c}zigguro{c}{s}.sock", .{ base, std.fs.path.sep, std.fs.path.sep, &key });
    if (p.len > net.UnixAddress.max_len) {
        gpa.free(p);
        return error.NameTooLong;
    }
    return p;
}

// ---- server ----

const max_log = 4096;

pub const ServerOptions = struct {
    /// `$XDG_RUNTIME_DIR` (fallback directory for long paths).
    runtime_dir: ?[]const u8 = null,
};

/// Serves one workspace's `RunHost` and `RunRegistry` to clients.
pub const HostServer = struct {
    gpa: Allocator,
    io: Io,
    rt: *zg_core.Runtime,
    host: *RunHost,
    reg: *RunRegistry,
    token: Token,
    sock_path: []u8,
    server: net.Server,
    accept: Io.Group = .init,
    listener: RunRegistry.ListenerId = 0,

    mutex: Io.Mutex = .init,
    conns: std.ArrayList(*Conn) = .empty,
    /// The last `max_log` events, for `runs.subscribe{since}`.
    log: std.ArrayList(protocol.EventNote) = .empty,
    seq: u64 = 0,
    /// Set by `host.shutdown`.
    shutdown_requested: std.atomic.Value(bool) = .init(false),

    const Conn = struct {
        server: *HostServer,
        stream: net.Stream,
        ep: *Endpoint,
        reader: net.Stream.Reader,
        writer: net.Stream.Writer,
        rbuf: [16 * 1024]u8 = undefined,
        wbuf: [16 * 1024]u8 = undefined,
        authed: std.atomic.Value(bool) = .init(false),
        subscribed: bool = false,
        closed: std.atomic.Value(bool) = .init(false),
    };

    /// Listens on the workspace socket (`runs_abs` is the absolute path of
    /// `runs`) and records it in `host.addr`. The caller holds the
    /// `HostLock`.
    pub fn listen(rt: *zg_core.Runtime, host: *RunHost, reg: *RunRegistry, runs: Io.Dir, runs_abs: []const u8, opts: ServerOptions) !*HostServer {
        const gpa = rt.gpa;
        const io = rt.io;
        const s = try gpa.create(HostServer);
        errdefer gpa.destroy(s);
        const path = try socketPath(gpa, runs_abs, opts.runtime_dir);
        errdefer gpa.free(path);
        if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
        // A stale socket from a dead host.
        Io.Dir.cwd().deleteFile(io, path) catch {};
        const addr = try net.UnixAddress.init(path);
        var server = try addr.listen(io, .{});
        errdefer server.deinit(io);
        try runs.writeFile(io, .{ .sub_path = addr_name, .data = path });
        s.* = .{
            .gpa = gpa,
            .io = io,
            .rt = rt,
            .host = host,
            .reg = reg,
            .token = try ensureToken(io, runs),
            .sock_path = path,
            .server = server,
        };
        s.listener = try reg.subscribe(.{ .ctx = s, .on_event = onRunEvent });
        errdefer reg.unsubscribe(s.listener);
        try s.accept.concurrent(io, acceptLoop, .{s});
        return s;
    }

    pub fn deinit(s: *HostServer) void {
        s.reg.unsubscribe(s.listener);
        s.accept.cancel(s.io);
        s.server.deinit(s.io);
        for (s.conns.items) |c| s.closeConn(c);
        s.conns.deinit(s.gpa);
        s.log.deinit(s.gpa);
        Io.Dir.cwd().deleteFile(s.io, s.sock_path) catch {};
        s.gpa.free(s.sock_path);
        s.gpa.destroy(s);
    }

    /// Clients currently connected.
    pub fn clients(s: *HostServer) usize {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var n: usize = 0;
        for (s.conns.items) |c| {
            if (!c.closed.load(.acquire)) n += 1;
        }
        return n;
    }

    fn closeConn(s: *HostServer, c: *Conn) void {
        c.stream.shutdown(s.io, .both) catch {};
        c.ep.deinit();
        c.stream.close(s.io);
        s.gpa.destroy(c);
    }

    fn acceptLoop(s: *HostServer) void {
        while (true) {
            const stream = s.server.accept(s.io) catch return;
            s.addConn(stream) catch stream.close(s.io);
        }
    }

    fn addConn(s: *HostServer, stream: net.Stream) !void {
        const c = try s.gpa.create(Conn);
        errdefer s.gpa.destroy(c);
        c.* = .{ .server = s, .stream = stream, .ep = undefined, .reader = undefined, .writer = undefined };
        c.reader = stream.reader(s.io, &c.rbuf);
        c.writer = stream.writer(s.io, &c.wbuf);
        c.ep = try Endpoint.init(s.rt, .{ .framing = .ndjson, .dialect = .mcp }, &c.reader.interface, &c.writer.interface);
        errdefer c.ep.deinit();
        inline for (.{
            .{ protocol.methods.hello, onHello },
            .{ protocol.methods.list, onList },
            .{ protocol.methods.show, onShow },
            .{ protocol.methods.start, onStart },
            .{ protocol.methods.stop, onStop },
            .{ protocol.methods.pause, onPause },
            .{ protocol.methods.resume_, onResume },
            .{ protocol.methods.reply, onReply },
            .{ protocol.methods.adopt, onAdopt },
            .{ protocol.methods.subscribe, onSubscribe },
            .{ protocol.methods.shutdown, onShutdown },
        }) |m| try c.ep.onRequest(m[0], .{ .ctx = c, .func = guard(m[1]) });
        c.ep.onClose(.{ .ctx = c, .func = struct {
            fn f(ctx: ?*anyopaque, _: Endpoint.Result) void {
                const cc: *Conn = @ptrCast(@alignCast(ctx.?));
                cc.closed.store(true, .release);
            }
        }.f });
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try s.conns.append(s.gpa, c);
        try c.ep.start();
    }

    const Fn = fn (c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) anyerror!RawJson;

    /// Wraps a handler: unauthenticated connections may only say hello;
    /// errors become JSON-RPC errors.
    fn guard(comptime f: Fn) *const fn (?*anyopaque, *Endpoint, zg_jsonrpc.message.Request, Allocator) Endpoint.HandlerResult {
        return struct {
            fn h(ctx: ?*anyopaque, _: *Endpoint, req: zg_jsonrpc.message.Request, arena: Allocator) Endpoint.HandlerResult {
                const c: *Conn = @ptrCast(@alignCast(ctx.?));
                if (f != onHello and !c.authed.load(.acquire))
                    return .{ .err = .{ .code = protocol.codes.unauthorized, .message = "say host.hello with the workspace token first" } };
                const r = f(c, req, arena) catch |e| return .{ .err = .{ .code = codeOf(e), .message = @errorName(e) } };
                return .{ .result = r };
            }
        }.h;
    }

    fn codeOf(e: anyerror) i32 {
        return switch (e) {
            error.Unauthorized => protocol.codes.unauthorized,
            error.UnknownRun => protocol.codes.unknown_run,
            error.InvalidTransition, error.NotWaiting, error.NotResumable, error.NotLive, error.NotTerminal => protocol.codes.bad_state,
            error.MissingParams, error.SyntaxError, error.UnexpectedToken, error.MissingField, error.UnknownField => -32602,
            else => protocol.codes.failed,
        };
    }

    fn params(comptime T: type, req: zg_jsonrpc.message.Request, arena: Allocator) !T {
        const p = req.params orelse return error.MissingParams;
        return std.json.parseFromSliceLeaky(T, arena, p.bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    fn ok(arena: Allocator) !RawJson {
        return Endpoint.raw(arena, protocol.Ok{});
    }

    fn onHello(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = try params(protocol.Hello, req, arena);
        var got: Token = undefined;
        const good = p.token.len == 64 and if (std.fmt.hexToBytes(&got, p.token)) |_| true else |_| false;
        if (!good or !std.crypto.timing_safe.eql(Token, got, c.server.token)) {
            // Drop the connection: the peer gets no further service.
            c.stream.shutdown(c.server.io, .both) catch {};
            return error.Unauthorized;
        }
        c.authed.store(true, .release);
        return Endpoint.raw(arena, protocol.HelloResult{ .pid = currentPid() });
    }

    fn onList(c: *Conn, _: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const v = c.server.reg.snapshot();
        defer c.server.reg.release(v);
        const rows = try arena.alloc(protocol.RunSummary, v.runs.len);
        for (v.runs, rows) |r, *row| row.* = .of(r);
        return Endpoint.raw(arena, rows);
    }

    fn onShow(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = try params(protocol.IdParams, req, arena);
        c.server.reg.loadDetail(p.id) catch {};
        const v = c.server.reg.snapshot();
        defer c.server.reg.release(v);
        const r = v.get(p.id) orelse return error.UnknownRun;
        return Endpoint.raw(arena, r.*);
    }

    fn onStart(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = try params(protocol.StartParams, req, arena);
        const id = try c.server.host.start(p.spec);
        return Endpoint.raw(arena, protocol.IdParams{ .id = id });
    }

    fn onStop(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = try params(protocol.StopParams, req, arena);
        c.server.host.stop(p.id, switch (p.how) {
            .graceful => .graceful,
            .now => .now,
        });
        return ok(arena);
    }

    fn onPause(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = try params(protocol.IdParams, req, arena);
        c.server.host.pause(p.id);
        return ok(arena);
    }

    fn onResume(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = try params(protocol.IdParams, req, arena);
        try c.server.host.resumeRun(p.id);
        return ok(arena);
    }

    fn onReply(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = try params(protocol.ReplyParams, req, arena);
        try c.server.host.reply(p.id, p.text);
        return ok(arena);
    }

    fn onAdopt(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = try params(protocol.AdoptParams, req, arena);
        var res: protocol.AdoptResult = .{ .adopted = 0, .failed = 0 };
        for (p.ids) |id| {
            c.server.host.adopt(id) catch {
                res.failed += 1;
                continue;
            };
            res.adopted += 1;
        }
        return Endpoint.raw(arena, res);
    }

    fn onSubscribe(c: *Conn, req: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        const p = params(protocol.SubscribeParams, req, arena) catch protocol.SubscribeParams{};
        const s = c.server;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.log.items) |e| if (e.seq > p.since) try c.ep.notify(protocol.methods.event, e);
        c.subscribed = true;
        return Endpoint.raw(arena, protocol.SubscribeResult{ .seq = s.seq });
    }

    fn onShutdown(c: *Conn, _: zg_jsonrpc.message.Request, arena: Allocator) !RawJson {
        c.server.shutdown_requested.store(true, .release);
        return ok(arena);
    }

    fn onRunEvent(ctx: *anyopaque, e: run.RunEvent) void {
        const s: *HostServer = @ptrCast(@alignCast(ctx));
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.seq += 1;
        const note: protocol.EventNote = .{ .seq = s.seq, .id = e.run, .revision = e.revision, .kind = e.kind };
        if (s.log.items.len == max_log) _ = s.log.orderedRemove(0);
        s.log.append(s.gpa, note) catch {};
        for (s.conns.items) |c| {
            if (c.subscribed and !c.closed.load(.acquire)) c.ep.notify(protocol.methods.event, note) catch {};
        }
    }
};

// ---- client ----

pub const EventSink = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, e: protocol.EventNote) void,
};

/// A connection to a workspace's host.
pub const HostClient = struct {
    gpa: Allocator,
    io: Io,
    stream: net.Stream,
    ep: *Endpoint,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    rbuf: [16 * 1024]u8 = undefined,
    wbuf: [16 * 1024]u8 = undefined,
    sink: ?EventSink = null,
    /// The highest event seq received (pass to `subscribe` after a
    /// reconnect).
    last_seq: std.atomic.Value(u64) = .init(0),

    /// Connects to the host of `runs` (via `host.addr`) and says hello with
    /// the workspace token. Null when no host holds the lock.
    pub fn connect(rt: *zg_core.Runtime, runs: Io.Dir) !?*HostClient {
        const io = rt.io;
        if (!hostAlive(io, runs)) return null;
        const token = readToken(io, runs) orelse return error.InvalidToken;
        var buf: [net.UnixAddress.max_len + 1]u8 = undefined;
        const f = try runs.openFile(io, addr_name, .{});
        const n = blk: {
            defer f.close(io);
            break :blk try f.readPositional(io, &.{&buf}, 0);
        };
        return try connectPath(rt, buf[0..n], token);
    }

    /// Connects to `path` and authenticates with `token`.
    pub fn connectPath(rt: *zg_core.Runtime, path: []const u8, token: Token) !*HostClient {
        const gpa = rt.gpa;
        const io = rt.io;
        const addr = try net.UnixAddress.init(path);
        const stream = try addr.connect(io);
        errdefer stream.close(io);
        const c = try gpa.create(HostClient);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .stream = stream, .ep = undefined, .reader = undefined, .writer = undefined };
        c.reader = stream.reader(io, &c.rbuf);
        c.writer = stream.writer(io, &c.wbuf);
        c.ep = try Endpoint.init(rt, .{ .framing = .ndjson, .dialect = .mcp, .default_timeout = .fromSeconds(30) }, &c.reader.interface, &c.writer.interface);
        errdefer c.ep.deinit();
        try c.ep.onNotification(protocol.methods.event, .{ .ctx = c, .func = onEvent });
        try c.ep.start();
        const hex = std.fmt.bytesToHex(token, .lower);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        // A host drops connections with a bad token without replying.
        _ = c.call(protocol.methods.hello, protocol.Hello{ .token = &hex }, protocol.HelloResult, arena.allocator()) catch |e| switch (e) {
            error.ConnectionClosed => return error.Unauthorized,
            else => return e,
        };
        return c;
    }

    pub fn deinit(c: *HostClient) void {
        c.stream.shutdown(c.io, .both) catch {};
        c.ep.deinit();
        c.stream.close(c.io);
        c.gpa.destroy(c);
    }

    pub const CallError = error{ RemoteError, ConnectionClosed } || anyerror;

    /// Calls `method` and parses the result as `T` into `arena`.
    pub fn call(c: *HostClient, method: []const u8, p: anytype, comptime T: type, arena: Allocator) !T {
        const resp = try c.ep.request(method, p, .{});
        defer resp.deinit();
        if (resp.response.err) |e| {
            std.log.scoped(.agents_ipc).debug("{s}: {s}", .{ method, e.message });
            return if (e.code == protocol.codes.unauthorized) error.Unauthorized else error.RemoteError;
        }
        const r = resp.response.result orelse return error.RemoteError;
        return std.json.parseFromSliceLeaky(T, arena, r.bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// Subscribes to run events after `since`; missed events are replayed
    /// first (up to the host's log size).
    pub fn subscribe(c: *HostClient, since: u64, sink: EventSink) !u64 {
        c.sink = sink;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const r = try c.call(protocol.methods.subscribe, protocol.SubscribeParams{ .since = since }, protocol.SubscribeResult, arena.allocator());
        return r.seq;
    }

    fn onEvent(ctx: ?*anyopaque, _: *Endpoint, n: zg_jsonrpc.message.Notification, arena: Allocator) void {
        const c: *HostClient = @ptrCast(@alignCast(ctx.?));
        const p = n.params orelse return;
        const e = std.json.parseFromSliceLeaky(protocol.EventNote, arena, p.bytes, .{ .ignore_unknown_fields = true }) catch return;
        c.last_seq.store(e.seq, .release);
        if (c.sink) |s| s.f(s.ctx, e);
    }
};

/// Whether another process holds `host.lock`.
pub fn hostAlive(io: Io, runs: Io.Dir) bool {
    const f = runs.openFile(io, lock_name, .{ .mode = .read_write }) catch return false;
    defer f.close(io);
    const got = f.tryLock(io, .exclusive) catch return false;
    if (got) f.unlock(io);
    return !got;
}

test {
    _ = @import("ipc_test.zig");
}
