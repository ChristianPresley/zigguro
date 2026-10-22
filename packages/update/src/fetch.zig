//! Feed fetching (E17.F04.S01.T02): the channel manifest and its
//! `.minisig` from the first feed URL that answers, with a conditional GET
//! on the stored ETag, hard size caps enforced while reading (endless
//! data), and redirects followed here so that every hop must be https.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_net = @import("zg_net");
const manifest = @import("manifest.zig");

/// Cap on the `.minisig` text.
pub const max_sig_bytes = 4 * 1024;
/// Redirect hops followed per request.
pub const max_redirects = 5;

pub const Options = struct {
    /// Accept `http://127.0.0.1` (loopback test servers); only tests set it.
    allow_http: bool = false,
    /// Tests only: send every request to this origin, keeping the path
    /// (manifests may name only https URLs).
    test_origin: ?[]const u8 = null,
};

/// A fetched manifest and signature (arena-owned).
pub const Fetched = struct {
    manifest: []u8,
    sig: []u8,
    etag: ?[]const u8,
    /// The server answered 304 to `If-None-Match`; `manifest` and `sig`
    /// are empty.
    not_modified: bool,
    /// The expanded URL that answered.
    url: []const u8,
};

pub const Error = error{
    /// A URL or a redirect was not https.
    InsecureUrl,
    TooManyRedirects,
    BadStatus,
    TooLarge,
    Canceled,
    /// No feed URL configured.
    NoFeedUrl,
} || Allocator.Error;

/// `template` with every `{channel}` replaced.
pub fn expandUrl(arena: Allocator, template: []const u8, channel: []const u8) Allocator.Error![]u8 {
    return std.mem.replaceOwned(u8, arena, template, "{channel}", channel);
}

/// Tries `urls` (templates) in order and returns the first manifest and
/// signature fetched completely. Network failures, bad statuses, caps and
/// insecure redirects move on to the next URL; the last error is returned
/// when none answers.
pub fn fetchFeed(
    arena: Allocator,
    http: *zg_net.http.Client,
    urls: []const []const u8,
    channel: []const u8,
    etag: ?[]const u8,
    cancel: *const std.atomic.Value(bool),
    opts: Options,
) anyerror!Fetched {
    var last: anyerror = error.NoFeedUrl;
    for (urls) |template| {
        if (cancel.load(.acquire)) return error.Canceled;
        const url = try expandUrl(arena, template, channel);
        if (fetchOne(arena, http, url, etag, cancel, opts)) |f| return f else |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => last = err,
        }
    }
    return last;
}

fn fetchOne(
    arena: Allocator,
    http: *zg_net.http.Client,
    url: []const u8,
    etag: ?[]const u8,
    cancel: *const std.atomic.Value(bool),
    opts: Options,
) anyerror!Fetched {
    var cond: [1]std.http.Header = undefined;
    const headers: []const std.http.Header = if (etag) |e| blk: {
        cond[0] = .{ .name = "If-None-Match", .value = e };
        break :blk &cond;
    } else &.{};
    const m = try getCapped(arena, http, url, headers, manifest.max_manifest_bytes, cancel, opts);
    if (m.status == .not_modified) return .{ .manifest = &.{}, .sig = &.{}, .etag = etag, .not_modified = true, .url = url };
    if (m.status != .ok) return error.BadStatus;
    const sig_url = try std.mem.concat(arena, u8, &.{ url, ".minisig" });
    const s = try getCapped(arena, http, sig_url, &.{}, max_sig_bytes, cancel, opts);
    if (s.status != .ok) return error.BadStatus;
    return .{ .manifest = m.body, .sig = s.body, .etag = m.etag, .not_modified = false, .url = url };
}

const Got = struct { status: std.http.Status, body: []u8, etag: ?[]const u8 };

/// GETs `url` into the arena, following up to `max_redirects` https
/// redirects, failing with `error.TooLarge` once more than `cap` bytes
/// arrive.
pub fn getCapped(
    arena: Allocator,
    http: *zg_net.http.Client,
    url: []const u8,
    headers: []const std.http.Header,
    cap: usize,
    cancel: *const std.atomic.Value(bool),
    opts: Options,
) anyerror!Got {
    var sink: CapSink = .{ .arena = arena, .cap = cap, .cancel = cancel };
    const f = try streamHttps(arena, http, url, headers, sink.bodySink(), opts);
    return .{ .status = f.status, .body = sink.list.items, .etag = f.etag };
}

/// The final response of `streamHttps`.
pub const Final = struct {
    status: std.http.Status,
    /// Arena-owned.
    etag: ?[]const u8,
    /// The URL that answered (after redirects).
    url: []const u8,
};

/// GETs `url0` into `sink`, following up to `max_redirects` redirects
/// that stay https. The sink sees only the final response (its `onHead`,
/// then its chunks); 304 is final.
pub fn streamHttps(
    arena: Allocator,
    http: *zg_net.http.Client,
    url0: []const u8,
    headers: []const std.http.Header,
    sink: zg_net.http.BodySink,
    opts: Options,
) anyerror!Final {
    var url = url0;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        const target = if (opts.test_origin) |o| try rebase(arena, url, o) else url;
        try checkScheme(target, opts);
        var head = try http.stream(.{ .url = target, .headers = headers, .follow_redirects = false, .accept_encoding_gzip = false }, sink);
        defer head.deinit(http.gpa);
        const status = head.status;
        if (status.class() == .redirect and status != .not_modified) {
            if (hops >= max_redirects) return error.TooManyRedirects;
            const loc = head.headers.get("location") orelse return error.BadStatus;
            url = try resolve(arena, url, loc);
            continue;
        }
        const etag = if (head.headers.get("etag")) |e| try arena.dupe(u8, e) else null;
        return .{ .status = status, .etag = etag, .url = url };
    }
}

/// `url`'s path and query on `origin`.
fn rebase(arena: Allocator, url: []const u8, origin: []const u8) ![]const u8 {
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    const path = std.mem.indexOfScalarPos(u8, url, scheme_end, '/') orelse url.len;
    return std.mem.concat(arena, u8, &.{ origin, url[path..] });
}

fn checkScheme(url: []const u8, opts: Options) Error!void {
    if (std.ascii.startsWithIgnoreCase(url, "https://")) return;
    if (opts.allow_http and std.mem.startsWith(u8, url, "http://127.0.0.1:")) return;
    return error.InsecureUrl;
}

/// `loc` resolved against `base`.
fn resolve(arena: Allocator, base: []const u8, loc: []const u8) ![]const u8 {
    const uri = std.Uri.parse(base) catch return error.BadStatus;
    const aux = try arena.alloc(u8, loc.len + base.len + 64);
    @memcpy(aux[0..loc.len], loc);
    var rest = aux;
    const next = uri.resolveInPlace(loc.len, &rest) catch return error.BadStatus;
    return std.fmt.allocPrint(arena, "{f}", .{next.fmt(.all)});
}

/// Collects a body up to `cap` bytes.
const CapSink = struct {
    arena: Allocator,
    cap: usize,
    cancel: *const std.atomic.Value(bool),
    list: std.ArrayList(u8) = .empty,

    fn bodySink(s: *CapSink) zg_net.http.BodySink {
        return .{ .ctx = s, .onChunk = onChunk };
    }

    fn onChunk(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const s: *CapSink = @ptrCast(@alignCast(ctx.?));
        if (s.cancel.load(.acquire)) return error.Canceled;
        if (bytes.len > s.cap - s.list.items.len) return error.TooLarge;
        try s.list.appendSlice(s.arena, bytes);
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const zg_core = @import("zg_core");
const TestServer = zg_net.test_server.TestServer;

/// A zg_net client for loopback tests.
pub const TestClient = struct {
    rt: zg_core.Runtime,
    env: std.process.Environ.Map,
    client: *zg_net.http.Client,

    pub fn init(t: *TestClient) !void {
        t.rt.initTesting();
        t.env = .init(testing.allocator);
        t.client = try zg_net.http.Client.init(&t.rt, .{
            .proxy = .none,
            .environ_map = &t.env,
            .backoff = .{ .base_ms = 1, .cap_ms = 5 },
            .max_retry_after_ms = 5,
            .max_retries = 0,
        });
    }

    pub fn deinit(t: *TestClient) void {
        t.client.deinit();
        t.env.deinit();
        _ = t.rt.deinit();
    }
};

fn header(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

const Feed = struct {
    fn h(_: *TestServer, req: *std.http.Server.Request) !void {
        const t = req.head.target;
        if (std.mem.eql(u8, t, "/down/update-stable.json")) return req.respond("down", .{ .status = .service_unavailable, .keep_alive = false });
        if (std.mem.eql(u8, t, "/feed/update-stable.json")) {
            if (header(req, "if-none-match")) |e| if (std.mem.eql(u8, e, "\"v1\"")) return req.respond("", .{ .status = .not_modified, .keep_alive = false });
            return req.respond("{\"m\":1}", .{ .extra_headers = &.{.{ .name = "etag", .value = "\"v1\"" }}, .keep_alive = false });
        }
        if (std.mem.eql(u8, t, "/feed/update-stable.json.minisig")) return req.respond("sig", .{ .keep_alive = false });
        if (std.mem.eql(u8, t, "/big/update-stable.json")) {
            const big: [manifest.max_manifest_bytes + 1]u8 = @splat('x');
            return req.respond(&big, .{ .keep_alive = false });
        }
        if (std.mem.eql(u8, t, "/moved/update-stable.json")) return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = "/feed/update-stable.json" }}, .keep_alive = false });
        if (std.mem.eql(u8, t, "/moved/update-stable.json.minisig")) return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = "/feed/update-stable.json.minisig" }}, .keep_alive = false });
        if (std.mem.eql(u8, t, "/insecure/update-stable.json")) return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = "http://example.invalid/x" }}, .keep_alive = false });
        return req.respond("nope", .{ .status = .not_found, .keep_alive = false });
    }
};

fn feedUrl(srv: *TestServer, arena: Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ srv.port, path });
}

test "fetch: manifest, signature and 304 not modified" {
    const io = testing.io;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 16, .handler = Feed.h };
    try srv.start(io);
    defer srv.stop(io);
    var tc: TestClient = undefined;
    try tc.init();
    defer tc.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: std.atomic.Value(bool) = .init(false);
    const url = try feedUrl(&srv, a, "/feed/update-{channel}.json");
    const f = try fetchFeed(a, tc.client, &.{url}, "stable", null, &cancel, .{ .allow_http = true });
    try testing.expect(!f.not_modified);
    try testing.expectEqualStrings("{\"m\":1}", f.manifest);
    try testing.expectEqualStrings("sig", f.sig);
    try testing.expectEqualStrings("\"v1\"", f.etag.?);
    try testing.expect(std.mem.endsWith(u8, f.url, "/feed/update-stable.json"));
    const g = try fetchFeed(a, tc.client, &.{url}, "stable", "\"v1\"", &cancel, .{ .allow_http = true });
    try testing.expect(g.not_modified);
    try testing.expectEqual(@as(usize, 0), g.manifest.len);
}

test "fetch: fallback to second url on 503, redirects, caps, https only" {
    const io = testing.io;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 32, .handler = Feed.h };
    try srv.start(io);
    defer srv.stop(io);
    var tc: TestClient = undefined;
    try tc.init();
    defer tc.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: std.atomic.Value(bool) = .init(false);
    const t: Options = .{ .allow_http = true };

    const down = try feedUrl(&srv, a, "/down/update-{channel}.json");
    const good = try feedUrl(&srv, a, "/feed/update-{channel}.json");
    const f = try fetchFeed(a, tc.client, &.{ down, good }, "stable", null, &cancel, t);
    try testing.expectEqualStrings("{\"m\":1}", f.manifest);
    try testing.expectError(error.BadStatus, fetchFeed(a, tc.client, &.{down}, "stable", null, &cancel, t));

    // A relative redirect is followed for both files.
    const moved = try feedUrl(&srv, a, "/moved/update-{channel}.json");
    try testing.expectEqualStrings("sig", (try fetchFeed(a, tc.client, &.{moved}, "stable", null, &cancel, t)).sig);

    // 64 KiB + 1 is refused while reading.
    const big = try feedUrl(&srv, a, "/big/update-{channel}.json");
    try testing.expectError(error.TooLarge, fetchFeed(a, tc.client, &.{big}, "stable", null, &cancel, t));

    // A redirect to http is refused before any request to it.
    const insecure = try feedUrl(&srv, a, "/insecure/update-{channel}.json");
    try testing.expectError(error.InsecureUrl, fetchFeed(a, tc.client, &.{insecure}, "stable", null, &cancel, t));
    try testing.expectError(error.InsecureUrl, checkScheme(good, .{}));

    try testing.expectError(error.NoFeedUrl, fetchFeed(a, tc.client, &.{}, "stable", null, &cancel, t));
    cancel.store(true, .release);
    try testing.expectError(error.Canceled, fetchFeed(a, tc.client, &.{good}, "stable", null, &cancel, t));
}

test "fetch: url templates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("https://x/update-insiders.json", try expandUrl(arena.allocator(), "https://x/update-{channel}.json", "insiders"));
}
