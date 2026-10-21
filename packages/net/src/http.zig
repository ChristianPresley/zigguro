//! The repository's single HTTP entry point, wrapping `std.http.Client`
//! with what std leaves to applications:
//!
//! - Lazy CA roots: nothing is scanned at `init`; the first `https` request
//!   (or a prewarm) calls `ensureCaLoaded`, which also adds `extra_ca_files`,
//!   `$SSL_CERT_FILE` and `$SSL_CERT_DIR`.
//! - Proxies from the environment with `NO_PROXY` (`proxy.zig`): bypassed
//!   hosts go through a second, proxy-less `std.http.Client` sharing the
//!   same CA bundle.
//! - Connect and request timeouts, and retries with full-jitter backoff that
//!   honour `Retry-After` (`retry.zig`). A stream never retries once body
//!   bytes have reached the sink.
//! - `Authorization` is sent as a privileged header, which std drops on
//!   redirects to another host. It is never logged.
//!
//! Every call blocks: never call on the UI thread (`Runtime.assertNotUi`).
//! Long streams run under the caller's `Subsystem` so they can be cancelled.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const StdClient = std.http.Client;
const zg_core = @import("zg_core");
const proxy = @import("proxy.zig");
const retry = @import("retry.zig");

pub const ProxyConfig = proxy.ProxyConfig;
pub const RetryPolicy = retry.RetryPolicy;

pub const Config = struct {
    user_agent: []const u8 = "zigguro/" ++ @import("zg_options").version,
    /// Absolute paths of extra PEM bundles, added to the system roots.
    extra_ca_files: []const []const u8 = &.{},
    proxy: ProxyConfig = .from_env,
    connect_timeout: Io.Duration = .fromSeconds(10),
    /// Whole-request limit for `send` (not `stream`).
    request_timeout: ?Io.Duration = null,
    max_retries: u8 = 3,
    backoff: retry.Backoff = .{},
    /// Upper bound on a server's `Retry-After`.
    max_retry_after_ms: u64 = 60_000,
    environ_map: *const std.process.Environ.Map,
};

pub const Request = struct {
    method: std.http.Method = .GET,
    url: []const u8,
    headers: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
    retry: RetryPolicy = .idempotent_only,
    accept_encoding_gzip: bool = true,
};

/// Response headers copied out of the connection buffer.
pub const OwnedHeaders = struct {
    bytes: []u8,
    list: []std.http.Header,

    fn fromHead(gpa: Allocator, head: []const u8) !OwnedHeaders {
        const bytes = try gpa.dupe(u8, head);
        errdefer gpa.free(bytes);
        var n: usize = 0;
        var it: std.http.HeaderIterator = .init(bytes);
        while (it.next()) |_| n += 1;
        const list = try gpa.alloc(std.http.Header, n);
        it = .init(bytes);
        var i: usize = 0;
        while (it.next()) |h| : (i += 1) list[i] = h;
        return .{ .bytes = bytes, .list = list };
    }

    /// The first value of header `name` (case-insensitive).
    pub fn get(self: OwnedHeaders, name: []const u8) ?[]const u8 {
        for (self.list) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn deinit(self: OwnedHeaders, gpa: Allocator) void {
        gpa.free(self.list);
        gpa.free(self.bytes);
    }
};

pub const Response = struct {
    status: std.http.Status,
    headers: OwnedHeaders,
    body: []u8,

    pub fn deinit(self: *Response, gpa: Allocator) void {
        self.headers.deinit(gpa);
        gpa.free(self.body);
    }
};

pub const Head = struct {
    status: std.http.Status,
    headers: OwnedHeaders,

    pub fn deinit(self: *Head, gpa: Allocator) void {
        self.headers.deinit(gpa);
    }
};

/// Receives body bytes as they arrive.
pub const BodySink = struct {
    ctx: ?*anyopaque,
    onChunk: *const fn (?*anyopaque, []const u8) anyerror!void,
};

pub const Client = struct {
    rt: *zg_core.Runtime,
    gpa: Allocator,
    io: Io,
    cfg: Config,
    arena: std.heap.ArenaAllocator,
    proxied: StdClient,
    direct: StdClient,
    no_proxy: []const u8 = "",
    ca_mutex: Io.Mutex = .init,
    ca_loaded: std.atomic.Value(bool) = .init(false),
    /// Number of CA scans performed (tests assert `init` does none).
    ca_scans: std.atomic.Value(u32) = .init(0),

    /// Cheap: reads proxy settings, opens nothing and scans no certificates.
    pub fn init(rt: *zg_core.Runtime, cfg: Config) !*Client {
        const gpa = rt.gpa;
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{
            .rt = rt,
            .gpa = gpa,
            .io = rt.io,
            .cfg = cfg,
            .arena = .init(gpa),
            .proxied = .{ .allocator = gpa, .io = rt.io },
            .direct = .{ .allocator = gpa, .io = rt.io },
        };
        errdefer c.arena.deinit();
        const arena = c.arena.allocator();
        switch (cfg.proxy) {
            .none => {},
            .from_env => {
                try c.proxied.initDefaultProxies(arena, cfg.environ_map);
                c.no_proxy = try arena.dupe(u8, proxy.noProxyFromEnv(cfg.environ_map));
            },
            .explicit => |e| {
                var env: std.process.Environ.Map = .init(arena);
                if (e.http) |v| try env.put("http_proxy", v);
                if (e.https) |v| try env.put("https_proxy", v);
                try c.proxied.initDefaultProxies(arena, &env);
                c.no_proxy = try arena.dupe(u8, e.no_proxy);
            },
        }
        return c;
    }

    pub fn deinit(self: *Client) void {
        // `direct` borrows `proxied`'s CA bundle.
        if (self.ca_loaded.load(.acquire)) self.direct.ca_bundle = .empty;
        self.direct.deinit();
        self.proxied.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Loads system roots plus configured extras. Idempotent and thread-safe;
    /// called lazily by the first `https` request.
    pub fn ensureCaLoaded(self: *Client) !void {
        if (self.ca_loaded.load(.acquire)) return;
        try self.ca_mutex.lock(self.io);
        defer self.ca_mutex.unlock(self.io);
        if (self.ca_loaded.load(.acquire)) return;
        _ = self.ca_scans.fetchAdd(1, .monotonic);
        const gpa = self.gpa;
        const io = self.io;
        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(gpa);
        const now = Io.Clock.real.now(io);
        bundle.rescan(gpa, io, now) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.CertificateBundleLoadFailure,
        };
        for (self.cfg.extra_ca_files) |path| {
            bundle.addCertsFromFilePathAbsolute(gpa, io, now, path) catch return error.CertificateBundleLoadFailure;
        }
        if (self.cfg.environ_map.get("SSL_CERT_FILE")) |path| {
            if (std.fs.path.isAbsolute(path)) bundle.addCertsFromFilePathAbsolute(gpa, io, now, path) catch {};
        }
        if (self.cfg.environ_map.get("SSL_CERT_DIR")) |dir| {
            if (std.fs.path.isAbsolute(dir)) bundle.addCertsFromDirPathAbsolute(gpa, io, now, dir) catch {};
        }
        try self.proxied.ca_bundle_lock.lock(io);
        std.mem.swap(std.crypto.Certificate.Bundle, &self.proxied.ca_bundle, &bundle);
        self.proxied.now = now;
        self.proxied.ca_bundle_lock.unlock(io);
        bundle.deinit(gpa);
        bundle = .empty;
        try self.direct.ca_bundle_lock.lock(io);
        self.direct.ca_bundle = self.proxied.ca_bundle;
        self.direct.now = now;
        self.direct.ca_bundle_lock.unlock(io);
        self.ca_loaded.store(true, .release);
    }

    /// Loads the CA bundle in the background (off the startup path).
    pub fn prewarm(self: *Client, sub: *zg_core.runtime.Subsystem) void {
        sub.spawn(prewarmTask, .{self});
    }

    fn prewarmTask(self: *Client) void {
        self.ensureCaLoaded() catch {};
    }

    /// Performs `req` and returns the whole response.
    pub fn send(self: *Client, gpa: Allocator, req: Request) !Response {
        return self.perform(gpa, req, null);
    }

    /// Performs `req`, delivering the body to `sink` as it arrives; returns
    /// after the body ends. The caller frees `Head` with `deinit(gpa)` using
    /// the client's allocator.
    pub fn stream(self: *Client, req: Request, sink: BodySink) !Head {
        const r = try self.perform(self.gpa, req, sink);
        self.gpa.free(r.body);
        return .{ .status = r.status, .headers = r.headers };
    }

    /// GETs `url` and parses a JSON body into `T` (unknown fields ignored).
    pub fn getJson(self: *Client, comptime T: type, gpa: Allocator, url: []const u8, headers: []const std.http.Header) !std.json.Parsed(T) {
        var all: [16]std.http.Header = undefined;
        const hs = withHeader(&all, headers, .{ .name = "accept", .value = "application/json" });
        var r = try self.send(gpa, .{ .url = url, .headers = hs });
        defer r.deinit(gpa);
        if (@intFromEnum(r.status) / 100 != 2) return error.HttpStatus;
        return std.json.parseFromSlice(T, gpa, r.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    fn perform(self: *Client, gpa: Allocator, req: Request, sink: ?BodySink) !Response {
        self.rt.assertNotUi();
        const uri = try std.Uri.parse(req.url);
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const can_retry = attempt < self.cfg.max_retries and retry.methodAllowed(req.retry, req.method);
            var streamed = false;
            const result = if (sink == null and self.cfg.request_timeout != null)
                zg_core.runtime.withDeadline(self.io, .after(self.io, self.cfg.request_timeout.?), attemptOnce, .{ self, gpa, uri, req, sink, can_retry, &streamed })
            else
                self.attemptOnce(gpa, uri, req, sink, can_retry, &streamed);
            if (result) |resp| {
                var r = resp;
                if (can_retry and !streamed and retry.retryableStatus(r.status)) {
                    const delay = self.retryDelay(r.headers.get("retry-after"), attempt);
                    r.deinit(gpa);
                    try self.io.sleep(.fromMilliseconds(@intCast(delay)), .awake);
                    continue;
                }
                return r;
            } else |err| {
                if (can_retry and !streamed and isConnectError(err)) {
                    try self.io.sleep(.fromMilliseconds(@intCast(self.retryDelay(null, attempt))), .awake);
                    continue;
                }
                return err;
            }
        }
    }

    fn retryDelay(self: *Client, retry_after: ?[]const u8, attempt: u32) u64 {
        if (retry_after) |v| {
            const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
            if (retry.parseRetryAfter(v, now_s)) |ms| return @min(ms, self.cfg.max_retry_after_ms);
        }
        var r: [8]u8 = undefined;
        self.io.random(&r);
        return self.cfg.backoff.delayMs(attempt, std.mem.readInt(u64, &r, .little));
    }

    fn attemptOnce(self: *Client, gpa: Allocator, uri: std.Uri, req: Request, sink: ?BodySink, can_retry: bool, streamed: *bool) !Response {
        const io = self.io;
        const protocol = StdClient.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
        if (protocol == .tls) try self.ensureCaLoaded();
        var host_buf: [Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        const port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80);
        const c = if (proxy.shouldBypass(self.no_proxy, host.bytes, port)) &self.direct else &self.proxied;
        const has_proxy = switch (protocol) {
            .plain => c.http_proxy,
            .tls => c.https_proxy,
        } != null;

        // Authorization rides as a privileged header (dropped on cross-host redirects).
        const split = try gpa.alloc(std.http.Header, req.headers.len);
        defer gpa.free(split);
        var n_extra: usize = 0;
        var n_priv: usize = req.headers.len;
        for (req.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization") or std.ascii.eqlIgnoreCase(h.name, "x-api-key")) {
                n_priv -= 1;
                split[n_priv] = h;
            } else {
                split[n_extra] = h;
                n_extra += 1;
            }
        }

        const conn: ?*StdClient.Connection = if (has_proxy) null else try c.connectTcpOptions(.{
            .host = host,
            .port = port,
            .protocol = protocol,
            .timeout = .{ .duration = .{ .raw = self.cfg.connect_timeout, .clock = .awake } },
        });
        var r = c.request(req.method, uri, .{
            .keep_alive = true,
            .connection = conn,
            .headers = .{
                .user_agent = .{ .override = self.cfg.user_agent },
                .accept_encoding = if (req.accept_encoding_gzip) .{ .override = "gzip, deflate" } else .omit,
            },
            .extra_headers = split[0..n_extra],
            .privileged_headers = split[n_priv..],
        }) catch |err| {
            if (conn) |cn| c.connection_pool.release(cn, io);
            return err;
        };
        defer r.deinit();

        if (req.body) |b| {
            if (!req.method.requestHasBody()) return error.BodyNotAllowed;
            const copy = try gpa.dupe(u8, b);
            defer gpa.free(copy);
            try r.sendBodyComplete(copy);
        } else if (req.method.requestHasBody()) {
            try r.sendBodyComplete(&.{});
        } else {
            try r.sendBodiless();
        }

        var redirect_buf: [8 * 1024]u8 = undefined;
        var resp = try r.receiveHead(&redirect_buf);
        var headers = try OwnedHeaders.fromHead(gpa, resp.head.bytes);
        errdefer headers.deinit(gpa);
        const status = resp.head.status;
        const encoding = resp.head.content_encoding;

        var transfer_buf: [16 * 1024]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buf: []u8 = &.{};
        defer gpa.free(decompress_buf);
        const body: *Io.Reader = switch (encoding) {
            .identity => resp.reader(&transfer_buf),
            .gzip, .deflate => blk: {
                decompress_buf = try gpa.alloc(u8, std.compress.flate.max_window_len);
                break :blk resp.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
            },
            else => return error.HttpContentEncodingUnsupported,
        };

        if (sink) |s| {
            if (can_retry and retry.retryableStatus(status)) {
                _ = body.discardRemaining() catch {};
                return .{ .status = status, .headers = headers, .body = &.{} };
            }
            while (true) {
                const avail = body.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return readError(&resp),
                };
                streamed.* = true;
                try s.onChunk(s.ctx, avail);
                body.toss(avail.len);
            }
            return .{ .status = status, .headers = headers, .body = &.{} };
        }
        const bytes = body.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return readError(&resp),
            else => |e| return e,
        };
        return .{ .status = status, .headers = headers, .body = bytes };
    }
};

/// The specific error behind a body `ReadFailed` (e.g. `error.Canceled`).
fn readError(resp: *const StdClient.Response) anyerror {
    if (resp.bodyErr()) |e| return e;
    if (resp.request.connection) |c| if (c.stream_reader.err) |e| return e;
    return error.ReadFailed;
}

fn withHeader(buf: []std.http.Header, headers: []const std.http.Header, extra: std.http.Header) []const std.http.Header {
    if (headers.len + 1 > buf.len) return headers;
    @memcpy(buf[0..headers.len], headers);
    buf[headers.len] = extra;
    return buf[0 .. headers.len + 1];
}

fn isConnectError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.Timeout,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A plain-HTTP loopback server answering `handler` for up to `max` requests.
const TestServer = struct {
    server: Io.net.Server,
    port: u16,
    served: std.atomic.Value(u32) = .init(0),
    handler: *const fn (*TestServer, *std.http.Server.Request) anyerror!void,
    ctx: ?*anyopaque = null,
    max: u32,
    future: Io.Future(Io.Cancelable!void) = undefined,

    fn start(self: *TestServer, io: Io) !void {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.future = try io.concurrent(run, .{ self, io });
    }

    fn stop(self: *TestServer, io: Io) void {
        self.future.cancel(io) catch {};
        self.server.deinit(io);
    }

    fn run(self: *TestServer, io: Io) Io.Cancelable!void {
        while (self.served.load(.monotonic) < self.max) {
            const conn = self.server.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            defer conn.close(io);
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var sr = conn.reader(io, &rbuf);
            var sw = conn.writer(io, &wbuf);
            var http: std.http.Server = .init(&sr.interface, &sw.interface);
            while (self.served.load(.monotonic) < self.max) {
                var req = http.receiveHead() catch break;
                _ = self.served.fetchAdd(1, .monotonic);
                self.handler(self, &req) catch break;
            }
        }
    }

    fn url(self: *TestServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }
};

const Fixture = struct {
    rt: zg_core.Runtime,
    env: std.process.Environ.Map,
    client: *Client,

    fn init(f: *Fixture, cfg_in: Config) !void {
        f.rt.initTesting();
        f.env = .init(testing.allocator);
        var cfg = cfg_in;
        cfg.environ_map = &f.env;
        f.client = try Client.init(&f.rt, cfg);
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.env.deinit();
        _ = f.rt.deinit();
    }
};

const test_cfg: Config = .{
    .proxy = .none,
    .environ_map = undefined,
    .backoff = .{ .base_ms = 1, .cap_ms = 5 },
    .max_retry_after_ms = 5,
};

test "http: init scans no certificates" {
    var f: Fixture = undefined;
    try f.init(test_cfg);
    defer f.deinit();
    try testing.expectEqual(@as(u32, 0), f.client.ca_scans.load(.monotonic));
}

test "http: send 200 with headers and body" {
    const io = testing.io;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 1, .handler = struct {
        fn h(_: *TestServer, req: *std.http.Server.Request) !void {
            var saw_ua = false;
            var it = req.iterateHeaders();
            while (it.next()) |hd| {
                if (std.ascii.eqlIgnoreCase(hd.name, "user-agent")) saw_ua = std.mem.startsWith(u8, hd.value, "zigguro/");
            }
            try req.respond(if (saw_ua) "hello" else "no ua", .{ .extra_headers = &.{.{ .name = "x-test", .value = "1" }} });
        }
    }.h };
    try srv.start(io);
    defer srv.stop(io);
    var f: Fixture = undefined;
    try f.init(test_cfg);
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var r = try f.client.send(testing.allocator, .{ .url = srv.url(&buf, "/") });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(std.http.Status.ok, r.status);
    try testing.expectEqualStrings("hello", r.body);
    try testing.expectEqualStrings("1", r.headers.get("X-Test").?);
}

test "http: POST body and chunked stream to sink" {
    const io = testing.io;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 1, .handler = struct {
        fn h(_: *TestServer, req: *std.http.Server.Request) !void {
            var body_buf: [256]u8 = undefined;
            const rd = try req.readerExpectContinue(&body_buf);
            var got: [64]u8 = undefined;
            const n = try rd.readSliceShort(&got);
            var out: [256]u8 = undefined;
            var bw = try req.respondStreaming(&out, .{});
            try bw.writer.print("echo:{s};", .{got[0..n]});
            try bw.writer.flush();
            try bw.flush();
            try bw.writer.writeAll("part2");
            try bw.end();
        }
    }.h };
    try srv.start(io);
    defer srv.stop(io);
    var f: Fixture = undefined;
    try f.init(test_cfg);
    defer f.deinit();
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(testing.allocator);
    const Sink = struct {
        fn on(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
            const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
            try l.appendSlice(testing.allocator, bytes);
        }
    };
    var buf: [64]u8 = undefined;
    var head = try f.client.stream(.{ .method = .POST, .url = srv.url(&buf, "/s"), .body = "ping" }, .{ .ctx = &collected, .onChunk = Sink.on });
    defer head.deinit(f.client.gpa);
    try testing.expectEqual(std.http.Status.ok, head.status);
    try testing.expectEqualStrings("echo:ping;part2", collected.items);
}

test "http: 429 retry honours Retry-After" {
    const io = testing.io;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 2, .handler = struct {
        fn h(s: *TestServer, req: *std.http.Server.Request) !void {
            if (s.served.load(.monotonic) == 1) {
                try req.respond("slow down", .{ .status = .too_many_requests, .extra_headers = &.{.{ .name = "retry-after", .value = "1" }} });
            } else {
                try req.respond("ok", .{});
            }
        }
    }.h };
    try srv.start(io);
    defer srv.stop(io);
    var f: Fixture = undefined;
    try f.init(test_cfg);
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    var r = try f.client.send(testing.allocator, .{ .url = srv.url(&buf, "/") });
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", r.body);
    try testing.expectEqual(@as(u32, 2), srv.served.load(.monotonic));
    // Retry-After: 1 s, capped to 5 ms by the config.
    try testing.expect(t0.untilNow(io).raw.toMilliseconds() < 900);
}

test "http: POST is not retried by default" {
    const io = testing.io;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 2, .handler = struct {
        fn h(_: *TestServer, req: *std.http.Server.Request) !void {
            try req.respond("busy", .{ .status = .service_unavailable });
        }
    }.h };
    try srv.start(io);
    defer srv.stop(io);
    var f: Fixture = undefined;
    try f.init(test_cfg);
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var r = try f.client.send(testing.allocator, .{ .method = .POST, .url = srv.url(&buf, "/"), .body = "{}" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(std.http.Status.service_unavailable, r.status);
    try testing.expectEqual(@as(u32, 1), srv.served.load(.monotonic));
}

test "http: redirect to another host drops Authorization" {
    const io = testing.io;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 2, .handler = struct {
        fn h(s: *TestServer, req: *std.http.Server.Request) !void {
            var auth = false;
            var it = req.iterateHeaders();
            while (it.next()) |hd| {
                if (std.ascii.eqlIgnoreCase(hd.name, "authorization")) auth = true;
            }
            if (std.mem.eql(u8, req.head.target, "/start")) {
                var loc: [64]u8 = undefined;
                const l = try std.fmt.bufPrint(&loc, "http://localhost:{d}/next", .{s.port});
                try req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = l }}, .keep_alive = false });
            } else {
                try req.respond(if (auth) "leaked" else "clean", .{});
            }
        }
    }.h };
    try srv.start(io);
    defer srv.stop(io);
    var f: Fixture = undefined;
    try f.init(test_cfg);
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var r = try f.client.send(testing.allocator, .{
        .url = srv.url(&buf, "/start"),
        .headers = &.{.{ .name = "Authorization", .value = "Bearer secret" }},
    });
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("clean", r.body);
}

test "http: cancellation mid-stream" {
    const io = testing.io;
    const Gate = struct {
        var release: Io.Event = .unset;
    };
    Gate.release = .unset;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 1, .handler = struct {
        fn h(_: *TestServer, req: *std.http.Server.Request) !void {
            var out: [256]u8 = undefined;
            var bw = try req.respondStreaming(&out, .{});
            try bw.writer.writeAll("first");
            try bw.writer.flush();
            try bw.flush();
            Gate.release.waitUncancelable(testing.io);
        }
    }.h };
    try srv.start(io);
    defer srv.stop(io);
    defer Gate.release.set(io);
    var f: Fixture = undefined;
    try f.init(test_cfg);
    defer f.deinit();
    var got_first: Io.Event = .unset;
    const Run = struct {
        fn sinkFn(ctx: ?*anyopaque, _: []const u8) anyerror!void {
            const e: *Io.Event = @ptrCast(@alignCast(ctx.?));
            e.set(testing.io);
        }
        fn run(c: *Client, u: []const u8, e: *Io.Event) anyerror!void {
            var head = try c.stream(.{ .url = u }, .{ .ctx = e, .onChunk = sinkFn });
            head.deinit(c.gpa);
        }
    };
    var buf: [64]u8 = undefined;
    var fut = try io.concurrent(Run.run, .{ f.client, srv.url(&buf, "/"), &got_first });
    try got_first.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectError(error.Canceled, fut.cancel(io));
}

test "http: GET over TLS with system roots (network)" {
    if (!@import("zg_options").network_tests) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .environ_map = undefined });
    defer f.deinit();
    var r = try f.client.send(testing.allocator, .{ .url = "https://ziglang.org/download/index.json" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(std.http.Status.ok, r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "\"master\"") != null);
    try testing.expectEqual(@as(u32, 1), f.client.ca_scans.load(.monotonic));
}
