//! The GitHub issues client against cassettes and scripted fakes, with a
//! fake clock: no network, no real waits.

const std = @import("std");
const zg_ai = @import("zg_ai");
const gh = @import("client.zig");

const testing = std.testing;
const io = testing.io;
const tp = zg_ai.transport;
const fake = zg_ai.fake_server;
const FakeClock = zg_ai.ratelimit.FakeClock;
const Cassette = zg_ai.testing.cassette.Cassette;

const repo: gh.Repo = .{ .owner = "octo", .name = "demo" };
const t0: i64 = 1_792_000_000_000;
const token: []const u8 = "ghp_s3cr3tTOKENvalue42";

/// Records each request (and the fake time it went out) before passing it on.
const Spy = struct {
    inner: tp.Transport,
    clock: ?*FakeClock = null,
    arena: std.heap.ArenaAllocator,
    seen: std.ArrayList(Seen) = .empty,

    const Seen = struct { method: tp.Method, url: []const u8, if_none_match: ?[]const u8, auth: ?[]const u8, at_ms: i64 };

    fn init(inner: tp.Transport, clock: ?*FakeClock) Spy {
        return .{ .inner = inner, .clock = clock, .arena = .init(testing.allocator) };
    }

    fn deinit(s: *Spy) void {
        s.arena.deinit();
    }

    fn transport(s: *Spy) tp.Transport {
        return .{ .ptr = s, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, i: std.Io, arena: std.mem.Allocator, req: tp.HttpRequest, sink: tp.ChunkSink) tp.TransportError!tp.Head {
        const s: *Spy = @ptrCast(@alignCast(ptr));
        const a = s.arena.allocator();
        const head: tp.Head = .{ .status = 0, .headers = req.headers };
        s.seen.append(a, .{
            .method = req.method,
            .url = a.dupe(u8, req.url) catch return error.OutOfMemory,
            .if_none_match = if (head.get("if-none-match")) |v| a.dupe(u8, v) catch return error.OutOfMemory else null,
            .auth = if (head.get("authorization")) |v| a.dupe(u8, v) catch return error.OutOfMemory else null,
            .at_ms = if (s.clock) |c| c.now_ms.load(.acquire) else 0,
        }) catch return error.OutOfMemory;
        return s.inner.send(i, arena, req, sink);
    }
};

const Tmp = struct {
    dir: testing.TmpDir,
    buf: [128]u8 = undefined,

    fn init() Tmp {
        return .{ .dir = testing.tmpDir(.{}) };
    }

    fn path(t: *Tmp, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&t.buf, ".zig-cache/tmp/{s}/{s}", .{ &t.dir.sub_path, name }) catch unreachable;
    }
};

fn client(t: tp.Transport, clock: *FakeClock, extra: gh.Options) gh.GitHubClient {
    var o = extra;
    o.clock = clock.clock();
    return .init(io, t, .fixed(&token), o);
}

/// The cassette `name` from testdata, opened for replay.
fn replay(tmp: *Tmp, comptime name: []const u8) !*Cassette {
    try tmp.dir.dir.writeFile(io, .{ .sub_path = name, .data = @embedFile("testdata/" ++ name) });
    return Cassette.open(io, testing.allocator, tmp.path(name), .replay, .{});
}

test "list_skips_pull_requests" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const cas = try replay(&tmp, "list_two_pages.cassette");
    defer cas.deinit();
    var clock: FakeClock = .init(t0);
    var c = client(cas.transport(null), &clock, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const r = try c.listIssues(arena.allocator(), repo, .{ .per_page = 3 }, null);
    const page = r.page;
    try testing.expectEqual(2, page.items.len);
    try testing.expectEqual(1, page.skipped_pull_requests);
    try testing.expectEqual(1, page.items[0].number);
    try testing.expectEqual(3, page.items[1].number);
    try testing.expectEqualStrings("bug", page.items[0].labels[0]);
    try testing.expectEqualStrings("W/\"page-1\"", page.etag.?);
    for (page.items) |it| try testing.expect(!it.is_pull_request);
}

test "pagination_follows_link_next" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const cas = try replay(&tmp, "list_two_pages.cassette");
    defer cas.deinit();
    var clock: FakeClock = .init(t0);
    var spy: Spy = .init(cas.transport(null), null);
    defer spy.deinit();
    var c = client(spy.transport(), &clock, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var numbers: std.ArrayList(u32) = .empty;
    var r = try c.listIssues(a, repo, .{ .per_page = 3 }, null);
    while (true) {
        for (r.page.items) |it| try numbers.append(a, it.number);
        const next = r.page.next_url orelse break;
        r = try c.nextPage(a, next);
    }
    try testing.expectEqualSlices(u32, &.{ 1, 3, 4 }, numbers.items);
    try testing.expectEqual(2, spy.seen.items.len);
    try testing.expectEqualStrings("https://api.github.com/repos/octo/demo/issues?state=all&per_page=3&sort=updated&direction=asc", spy.seen.items[0].url);
    // The second URL is the header's, verbatim (GitHub's own path shape).
    try testing.expectEqualStrings("https://api.github.com/repositories/4242/issues?state=all&per_page=3&sort=updated&direction=asc&page=2", spy.seen.items[1].url);
    try testing.expectEqual(2, cas.replays);
    // A next URL on another host is refused: the token stays at GitHub.
    try testing.expectError(error.ForeignUrl, c.nextPage(a, "https://evil.example/repos/octo/demo/issues?page=2"));
    try testing.expectError(error.ForeignUrl, c.nextPage(a, "https://api.github.com.evil.example/x"));
}

test "not_modified_uses_etag" {
    const routes = [_]fake.Route{
        .{ .url_contains = "/issues?", .once = true, .body = "[]", .headers = &.{ .{ .name = "ETag", .value = "W/\"v1\"" }, .{ .name = "Last-Modified", .value = "Thu, 22 Oct 2026 10:00:00 GMT" } } },
        .{ .url_contains = "/issues?", .status = 304 },
        .{ .url_contains = "/issues/9", .once = true, .body = "{\"number\":9,\"title\":\"Nine\",\"state\":\"open\"}", .headers = &.{.{ .name = "ETag", .value = "\"i9\"" }} },
        .{ .url_contains = "/issues/9", .status = 304 },
    };
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var clock: FakeClock = .init(t0);
    var spy: Spy = .init(f.transport(), null);
    defer spy.deinit();
    var c = client(spy.transport(), &clock, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try c.listIssues(a, repo, .{ .since = "2026-10-01T00:00:00Z" }, null);
    try testing.expectEqualStrings("W/\"v1\"", first.page.etag.?);
    try testing.expectEqualStrings("Thu, 22 Oct 2026 10:00:00 GMT", first.page.last_modified.?);
    try testing.expect(std.mem.endsWith(u8, spy.seen.items[0].url, "&since=2026-10-01T00%3A00%3A00Z"));
    try testing.expect(spy.seen.items[0].if_none_match == null);
    const again = try c.listIssues(a, repo, .{ .since = "2026-10-01T00:00:00Z" }, first.page.etag);
    try testing.expect(again == .not_modified);
    try testing.expectEqualStrings("W/\"v1\"", spy.seen.items[1].if_none_match.?);

    const got = try c.getIssue(a, repo, 9, null);
    try testing.expectEqualStrings("Nine", got.found.issue.title);
    try testing.expect((try c.getIssue(a, repo, 9, got.found.etag)) == .not_modified);
    try testing.expectEqualStrings("\"i9\"", spy.seen.items[3].if_none_match.?);
    try testing.expectEqual(4, c.requests.load(.monotonic));
}

test "rate_limit_reset_wait" {
    const reset_s = @divTrunc(t0, 1000) + 90;
    var reset_buf: [24]u8 = undefined;
    const reset = try std.fmt.bufPrint(&reset_buf, "{d}", .{reset_s});
    const routes = [_]fake.Route{
        .{ .once = true, .status = 403, .body = "{\"message\":\"API rate limit exceeded\"}", .headers = &.{ .{ .name = "x-ratelimit-remaining", .value = "0" }, .{ .name = "x-ratelimit-reset", .value = reset } } },
        // Allowed, but the last request of the window: the next one waits too.
        .{ .once = true, .body = "{\"number\":1,\"state\":\"open\"}", .headers = &.{ .{ .name = "x-ratelimit-remaining", .value = "0" }, .{ .name = "x-ratelimit-reset", .value = "1792000200" } } },
        .{ .body = "{\"number\":1,\"state\":\"open\"}" },
    };
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var clock: FakeClock = .init(t0);
    var spy: Spy = .init(f.transport(), &clock);
    defer spy.deinit();
    var c = client(spy.transport(), &clock, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    _ = try c.getIssue(arena.allocator(), repo, 1, null);
    try testing.expectEqual(2, spy.seen.items.len);
    try testing.expectEqual(reset_s * 1000, spy.seen.items[1].at_ms);
    _ = try c.getIssue(arena.allocator(), repo, 1, null);
    try testing.expectEqual(1_792_000_200_000, spy.seen.items[2].at_ms);
}

test "retry_after_honoured" {
    const routes = [_]fake.Route{
        .{ .once = true, .status = 429, .headers = &.{.{ .name = "Retry-After", .value = "7" }} },
        .{ .once = true, .status = 403, .body = "{\"message\":\"You have exceeded a secondary rate limit.\"}", .headers = &.{.{ .name = "retry-after", .value = "3" }} },
        .{ .status = 201, .body = "{\"number\":12,\"title\":\"New\",\"state\":\"open\"}" },
    };
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var clock: FakeClock = .init(t0);
    var spy: Spy = .init(f.transport(), &clock);
    defer spy.deinit();
    var c = client(spy.transport(), &clock, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const made = try c.createIssue(arena.allocator(), repo, .{ .title = "New", .labels = &.{"zigguro"} });
    try testing.expectEqual(12, made.number);
    try testing.expectEqual(3, spy.seen.items.len);
    try testing.expectEqual(t0 + 7_000, spy.seen.items[1].at_ms);
    try testing.expectEqual(t0 + 10_000, spy.seen.items[2].at_ms);
    try testing.expectEqual(tp.Method.POST, spy.seen.items[0].method);
    try testing.expectEqualStrings("{\"title\":\"New\",\"labels\":[\"zigguro\"]}", f.requests()[0].body);

    // A 403 that is not a rate limit fails at once.
    const denied = [_]fake.Route{.{ .status = 403, .body = "{\"message\":\"Resource not accessible by integration\"}" }};
    var f2: fake.FakeTransport = try .init(testing.allocator, &denied);
    defer f2.deinit();
    var c2 = client(f2.transport(), &clock, .{});
    try testing.expectError(error.Forbidden, c2.getIssue(arena.allocator(), repo, 1, null));
    try testing.expectEqual(1, f2.requests().len);
    try testing.expectEqualStrings("GitHub answered 403: Resource not accessible by integration", c2.lastError());
}

test "mutations_paced_1s" {
    const routes = [_]fake.Route{.{ .body = "{\"number\":5,\"state\":\"closed\"}" }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var clock: FakeClock = .init(t0);
    var spy: Spy = .init(f.transport(), &clock);
    defer spy.deinit();
    var c = client(spy.transport(), &clock, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try c.updateIssue(a, repo, 5, .{ .state = "closed", .state_reason = "completed" });
    _ = try c.getIssue(a, repo, 5, null); // reads are not paced
    _ = try c.updateIssue(a, repo, 5, .{ .title = "x" });
    clock.advance(400);
    _ = try c.updateIssue(a, repo, 5, .{ .body = "y" });
    const s = spy.seen.items;
    try testing.expectEqual(tp.Method.PATCH, s[0].method);
    try testing.expectEqualStrings("https://api.github.com/repos/octo/demo/issues/5", s[0].url);
    try testing.expectEqualStrings("{\"state\":\"closed\",\"state_reason\":\"completed\"}", f.requests()[0].body);
    try testing.expectEqual(t0, s[1].at_ms);
    try testing.expectEqual(t0 + 1000, s[2].at_ms);
    try testing.expectEqual(t0 + 2000, s[3].at_ms);
    try testing.expectEqual(2, clock.sleeps.load(.monotonic));
}

/// Counts concurrent sends.
const Gate = struct {
    now: std.atomic.Value(u32) = .init(0),
    max: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),

    fn transport(g: *Gate) tp.Transport {
        return .{ .ptr = g, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, i: std.Io, arena: std.mem.Allocator, req: tp.HttpRequest, sink: tp.ChunkSink) tp.TransportError!tp.Head {
        _ = arena;
        _ = req;
        const g: *Gate = @ptrCast(@alignCast(ptr));
        const n = g.now.fetchAdd(1, .acq_rel) + 1;
        _ = g.max.fetchMax(n, .acq_rel);
        _ = g.total.fetchAdd(1, .monotonic);
        i.sleep(.fromMilliseconds(2), .awake) catch {};
        _ = g.now.fetchSub(1, .acq_rel);
        sink.on_chunk(sink.ctx, "{\"number\":1,\"state\":\"open\"}") catch return error.Aborted;
        return .{ .status = 200 };
    }
};

fn worker(c: *gh.GitHubClient, fails: *std.atomic.Value(u32)) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    for (0..3) |n| {
        _ = c.getIssue(arena.allocator(), repo, @intCast(n + 1), null) catch {
            _ = fails.fetchAdd(1, .monotonic);
        };
    }
}

test "single_request_in_flight" {
    var gate: Gate = .{};
    var clock: FakeClock = .init(t0);
    var c = client(gate.transport(), &clock, .{});
    var fails: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{ &c, &fails });
    for (threads) |t| t.join();
    try testing.expectEqual(0, fails.load(.monotonic));
    try testing.expectEqual(12, gate.total.load(.monotonic));
    try testing.expectEqual(1, gate.max.load(.monotonic));
    try testing.expectEqual(0, c.in_flight.load(.monotonic));
}

test "backoff_gives_up_after_5" {
    const routes = [_]fake.Route{.{ .status = 403, .body = "{\"message\":\"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.\"}" }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var clock: FakeClock = .init(t0);
    var spy: Spy = .init(f.transport(), &clock);
    defer spy.deinit();
    var c = client(spy.transport(), &clock, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.RateLimited, c.updateIssue(arena.allocator(), repo, 3, .{ .title = "t" }));
    try testing.expectEqual(5, spy.seen.items.len);
    // 60 s, then doubling.
    const want = [_]i64{ 0, 60_000, 180_000, 420_000, 900_000 };
    for (spy.seen.items, want) |s, w| try testing.expectEqual(t0 + w, s.at_ms);
    try testing.expectEqualStrings("GitHub rate limit: gave up after 5 attempts", c.lastError());
}

const Log = struct {
    lines: std.ArrayList(u8) = .empty,

    fn line(ctx: ?*anyopaque, text: []const u8) void {
        const l: *Log = @ptrCast(@alignCast(ctx.?));
        l.lines.appendSlice(testing.allocator, text) catch {};
        l.lines.append(testing.allocator, '\n') catch {};
    }
};

test "token_never_logged" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const routes = [_]fake.Route{
        // A server echoing the credential back must not leak it either.
        .{ .url_contains = "/issues/1", .status = 401, .body = "{\"message\":\"Bad credentials: ghp_s3cr3tTOKENvalue42\"}" },
        .{ .url_contains = "/issues?", .body = "[]" },
    };
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    // Through the E10 recorder, which redacts credential headers.
    const cas = try Cassette.open(io, testing.allocator, tmp.path("rec.cassette"), .record, .{});
    var finished = false;
    defer if (!finished) cas.deinit();
    var log: Log = .{};
    defer log.lines.deinit(testing.allocator);
    var clock: FakeClock = .init(t0);
    var c = client(cas.transport(f.transport()), &clock, .{ .log = .{ .ctx = &log, .line = Log.line } });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.Unauthorized, c.getIssue(arena.allocator(), repo, 1, null));
    try testing.expectEqualStrings("GitHub answered 401: Bad credentials: <redacted>", c.lastError());
    _ = try c.listIssues(arena.allocator(), repo, .{}, null);
    try testing.expectEqualStrings("Bearer " ++ token, pacingHeader(f.requests()[0].headers, "authorization").?);
    try cas.finish();
    finished = true;
    cas.deinit();

    try testing.expect(std.mem.indexOf(u8, log.lines.items, "GET /repos/octo/demo/issues/1 -> 401") != null);
    try testing.expect(std.mem.indexOf(u8, log.lines.items, token) == null);
    const recorded = try tmp.dir.dir.readFileAlloc(io, "rec.cassette", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(recorded);
    try testing.expect(std.mem.indexOf(u8, recorded, "Bearer " ++ token) == null);
}

fn pacingHeader(hs: []const tp.Header, name: []const u8) ?[]const u8 {
    for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Serves `total` issues, 100 a page, with `Link` next and a stable ETag.
const Repo2k = struct {
    total: u32,
    served: u32 = 0,

    fn transport(r: *Repo2k) tp.Transport {
        return .{ .ptr = r, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, _: std.Io, arena: std.mem.Allocator, req: tp.HttpRequest, sink: tp.ChunkSink) tp.TransportError!tp.Head {
        const r: *Repo2k = @ptrCast(@alignCast(ptr));
        r.served += 1;
        const etag = "W/\"all-2000\"";
        if (pacingHeader(req.headers, "if-none-match")) |v| if (std.mem.eql(u8, v, etag)) return .{ .status = 304 };
        const page: u32 = if (std.mem.indexOf(u8, req.url, "&page=")) |k| std.fmt.parseInt(u32, req.url[k + 6 ..], 10) catch return error.Network else 1;
        var body: std.Io.Writer.Allocating = .init(arena);
        const w = &body.writer;
        w.writeByte('[') catch return error.OutOfMemory;
        var n = (page - 1) * 100 + 1;
        const last = @min(page * 100, r.total);
        while (n <= last) : (n += 1) w.print("{s}{{\"number\":{d},\"title\":\"Issue {d}\",\"state\":\"open\",\"labels\":[],\"pull_request\":null}}", .{ if (n % 100 == 1) "" else ",", n, n }) catch return error.OutOfMemory;
        w.writeByte(']') catch return error.OutOfMemory;
        sink.on_chunk(sink.ctx, body.written()) catch return error.Aborted;
        var hs: std.ArrayList(tp.Header) = .empty;
        hs.append(arena, .{ .name = "ETag", .value = etag }) catch return error.OutOfMemory;
        if (last < r.total) hs.append(arena, .{
            .name = "Link",
            .value = std.fmt.allocPrint(arena, "<https://api.github.com/repositories/7/issues?state=all&per_page=100&page={d}>; rel=\"next\"", .{page + 1}) catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;
        return .{ .status = 200, .headers = hs.items };
    }
};

test "2,000 issues take 20 requests and an unchanged poll one 304" {
    var src: Repo2k = .{ .total = 2000 };
    var clock: FakeClock = .init(t0);
    var c = client(src.transport(), &clock, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var count: usize = 0;
    var r = try c.listIssues(a, repo, .{}, null);
    const first_etag = r.page.etag.?;
    while (true) {
        count += r.page.items.len;
        r = try c.nextPage(a, r.page.next_url orelse break);
    }
    try testing.expectEqual(2000, count);
    try testing.expectEqual(20, src.served);
    try testing.expect((try c.listIssues(a, repo, .{}, first_etag)) == .not_modified);
    try testing.expectEqual(21, src.served);
    try testing.expectEqual(0, clock.sleeps.load(.monotonic));
}

test "bad input and oversized bodies" {
    const routes = [_]fake.Route{.{ .body = "[" ++ "\"x\"," ** 40 ++ "]" }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var clock: FakeClock = .init(t0);
    var c = client(f.transport(), &clock, .{ .max_body = 64 });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidRepo, c.listIssues(a, .{ .owner = "octo", .name = "../x" }, .{}, null));
    try testing.expectError(error.InvalidRepo, c.getIssue(a, .{ .owner = "a/b", .name = "x" }, 1, null));
    try testing.expectEqual(0, f.requests().len);
    try testing.expectError(error.ResponseTooLarge, c.listIssues(a, repo, .{}, null));

    const empty: []const u8 = "";
    var c2: gh.GitHubClient = .init(io, f.transport(), .fixed(&empty), .{ .clock = clock.clock() });
    try testing.expectError(error.NoToken, c2.getIssue(a, repo, 1, null));
    try testing.expectEqualStrings("no GitHub token: sign in to GitHub first", c2.lastError());
}
