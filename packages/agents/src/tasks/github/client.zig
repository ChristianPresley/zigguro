//! A small GitHub REST client for issues (E13.F03.S03.T01), used by the
//! task sync engine: list (skipping pull requests), get, create and
//! update, with `Link` pagination, ETag conditional requests, a single
//! serial request queue and rate-limit handling (`pacing.zig`).
//!
//! Requests go through a `zg_ai.Transport`: `zg_ai.transport.ZgNet` over
//! `zg_net` in the app, a cassette or fake in tests. The token comes from
//! a `TokenProvider` on every request and never appears in the log or in
//! `lastError`: both are scrubbed of it.
//!
//! Results live in the allocator passed to each call (use an arena).

const std = @import("std");
const zg_ai = @import("zg_ai");
const types = @import("types.zig");
const pacing = @import("pacing.zig");
const link_header = @import("link_header.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const tp = zg_ai.transport;
const Header = tp.Header;

pub const Repo = types.Repo;
pub const Issue = types.Issue;
pub const IssueWrite = types.IssueWrite;
pub const ListQuery = types.ListQuery;
pub const parseLinkHeader = link_header.parseLinkHeader;

/// Supplies the API token (E09's GitHub device flow or the E16 secret
/// store). Called for each request; the string lives in `arena`.
pub const TokenProvider = struct {
    ctx: ?*const anyopaque = null,
    get: *const fn (ctx: ?*const anyopaque, arena: Allocator) anyerror![]const u8,

    /// A provider returning `token.*`.
    pub fn fixed(token: *const []const u8) TokenProvider {
        return .{ .ctx = @ptrCast(token), .get = fixedGet };
    }

    fn fixedGet(ctx: ?*const anyopaque, _: Allocator) anyerror![]const u8 {
        const t: *const []const u8 = @ptrCast(@alignCast(ctx.?));
        return t.*;
    }
};

/// Receives one line per request (`GET /repos/o/r/issues?... -> 200`).
pub const LogPort = struct {
    ctx: ?*anyopaque = null,
    line: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

pub const Options = struct {
    api_base: []const u8 = "https://api.github.com",
    api_version: []const u8 = "2026-03-10",
    user_agent: []const u8 = "zigguro/" ++ @import("zg_options").version,
    clock: pacing.Clock = .real,
    policy: pacing.Policy = .{},
    /// Larger response bodies fail with `error.ResponseTooLarge`.
    max_body: usize = 32 << 20,
    log: ?LogPort = null,
};

pub const Error = error{
    InvalidRepo,
    /// A `next_url` outside `api_base` (the token never leaves it).
    ForeignUrl,
    NoToken,
    Unauthorized,
    Forbidden,
    NotFound,
    /// The issue was deleted or transferred.
    Gone,
    /// 422: GitHub refused the fields (see `lastError`).
    Invalid,
    /// Still rate limited after `max_attempts` tries.
    RateLimited,
    HttpStatus,
    ResponseTooLarge,
    InvalidResponse,
    Network,
    Timeout,
    Canceled,
    OutOfMemory,
};

pub const Page = struct {
    /// Issues only: pull requests are skipped.
    items: []const Issue,
    /// The `Link` header's `rel="next"`, followed verbatim by `nextPage`.
    next_url: ?[]const u8,
    etag: ?[]const u8,
    last_modified: ?[]const u8,
    skipped_pull_requests: u32 = 0,
};

pub const ListResult = union(enum) {
    /// 304: nothing changed since `etag`.
    not_modified,
    page: Page,
};

pub const GetResult = union(enum) {
    not_modified,
    found: struct { issue: Issue, etag: ?[]const u8, last_modified: ?[]const u8 },
};

pub const GitHubClient = struct {
    io: Io,
    transport: tp.Transport,
    token: TokenProvider,
    o: Options,
    pacer: pacing.Pacer,
    /// The request queue: held for a whole exchange, retries and waits
    /// included, so at most one request is ever in flight.
    queue: Io.Mutex = .init,
    in_flight: std.atomic.Value(u32) = .init(0),
    /// Requests sent (tests and budgets).
    requests: std.atomic.Value(u32) = .init(0),
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,

    pub fn init(io: Io, transport: tp.Transport, token: TokenProvider, o: Options) GitHubClient {
        return .{ .io = io, .transport = transport, .token = token, .o = o, .pacer = .{ .clock = o.clock, .policy = o.policy } };
    }

    /// Why the last call failed, for people (never holds the token).
    pub fn lastError(c: *const GitHubClient) []const u8 {
        return c.err_buf[0..c.err_len];
    }

    /// The first page of `repo`'s issues matching `q`, oldest update first.
    /// With `etag` from an earlier first page, an unchanged list costs one
    /// 304 that does not count against the rate limit.
    pub fn listIssues(c: *GitHubClient, a: Allocator, repo: Repo, q: ListQuery, etag: ?[]const u8) Error!ListResult {
        if (!repo.isValid()) return error.InvalidRepo;
        var url: std.Io.Writer.Allocating = .init(a);
        const w = &url.writer;
        w.print("{s}/repos/{s}/{s}/issues?state={s}&per_page={d}&sort=updated&direction=asc", .{
            trimBase(c.o.api_base), repo.owner, repo.name, @tagName(q.state), @min(@max(q.per_page, 1), 100),
        }) catch return error.OutOfMemory;
        if (q.since) |s| writeParam(w, "since", s) catch return error.OutOfMemory;
        if (q.labels) |l| writeParam(w, "labels", l) catch return error.OutOfMemory;
        return c.list(a, url.written(), etag);
    }

    /// The page at `next_url` (a `Page.next_url`).
    pub fn nextPage(c: *GitHubClient, a: Allocator, next_url: []const u8) Error!ListResult {
        const base = trimBase(c.o.api_base);
        if (!(std.mem.startsWith(u8, next_url, base) and next_url.len > base.len and next_url[base.len] == '/')) return error.ForeignUrl;
        return c.list(a, next_url, null);
    }

    pub fn getIssue(c: *GitHubClient, a: Allocator, repo: Repo, n: u32, etag: ?[]const u8) Error!GetResult {
        const url = try c.issueUrl(a, repo, n);
        const r = try c.exchange(a, .GET, url, "", etag);
        if (r.status == 304) return .not_modified;
        try c.check(a, r, 200);
        return .{ .found = .{ .issue = try c.decode(Issue, types.decodeIssue, a, r.body), .etag = r.get("etag"), .last_modified = r.get("last-modified") } };
    }

    pub fn createIssue(c: *GitHubClient, a: Allocator, repo: Repo, body: IssueWrite) Error!Issue {
        if (!repo.isValid()) return error.InvalidRepo;
        const url = std.fmt.allocPrint(a, "{s}/repos/{s}/{s}/issues", .{ trimBase(c.o.api_base), repo.owner, repo.name }) catch return error.OutOfMemory;
        const r = try c.exchange(a, .POST, url, try body.encode(a), null);
        try c.check(a, r, 201);
        return c.decode(Issue, types.decodeIssue, a, r.body);
    }

    pub fn updateIssue(c: *GitHubClient, a: Allocator, repo: Repo, n: u32, body: IssueWrite) Error!Issue {
        const url = try c.issueUrl(a, repo, n);
        const r = try c.exchange(a, .PATCH, url, try body.encode(a), null);
        try c.check(a, r, 200);
        return c.decode(Issue, types.decodeIssue, a, r.body);
    }

    fn issueUrl(c: *GitHubClient, a: Allocator, repo: Repo, n: u32) Error![]const u8 {
        if (!repo.isValid()) return error.InvalidRepo;
        return std.fmt.allocPrint(a, "{s}/repos/{s}/{s}/issues/{d}", .{ trimBase(c.o.api_base), repo.owner, repo.name, n }) catch error.OutOfMemory;
    }

    fn list(c: *GitHubClient, a: Allocator, url: []const u8, etag: ?[]const u8) Error!ListResult {
        const r = try c.exchange(a, .GET, url, "", etag);
        if (r.status == 304) return .not_modified;
        try c.check(a, r, 200);
        const all = try c.decode([]Issue, types.decodeIssues, a, r.body);
        var kept: usize = 0;
        for (all) |it| if (!it.is_pull_request) {
            all[kept] = it;
            kept += 1;
        };
        const next = if (r.get("link")) |l| parseLinkHeader(l, "next") else null;
        return .{ .page = .{
            .items = all[0..kept],
            .next_url = next,
            .etag = r.get("etag"),
            .last_modified = r.get("last-modified"),
            .skipped_pull_requests = @intCast(all.len - kept),
        } };
    }

    fn decode(c: *GitHubClient, comptime T: type, comptime f: fn (Allocator, []const u8) types.DecodeError!T, a: Allocator, body: []const u8) Error!T {
        return f(a, body) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidResponse => {
                c.setError("GitHub sent a response that is not the expected JSON", .{});
                return error.InvalidResponse;
            },
        };
    }

    const Reply = struct {
        status: u16,
        headers: []const Header,
        body: []const u8,

        fn get(r: Reply, name: []const u8) ?[]const u8 {
            return pacing.get(r.headers, name);
        }
    };

    /// Maps a non-`want` status to an error, keeping GitHub's message.
    fn check(c: *GitHubClient, a: Allocator, r: Reply, want: u16) Error!void {
        if (r.status == want or (want == 200 and r.status == 201)) return;
        const msg = types.errorMessage(a, r.body) orelse "";
        c.setError("GitHub answered {d}{s}{s}", .{ r.status, if (msg.len > 0) ": " else "", msg });
        return switch (r.status) {
            401 => error.Unauthorized,
            403 => error.Forbidden,
            404 => error.NotFound,
            410 => error.Gone,
            422 => error.Invalid,
            else => error.HttpStatus,
        };
    }

    /// Sends one request through the queue, waiting out pacing and rate
    /// limits. Returns any status; the caller interprets it.
    fn exchange(c: *GitHubClient, a: Allocator, method: tp.Method, url: []const u8, body: []const u8, etag: ?[]const u8) Error!Reply {
        c.queue.lock(c.io) catch return error.Canceled;
        defer c.queue.unlock(c.io);
        c.err_len = 0;
        const mutation = method != .GET;
        var attempt: u8 = 1;
        while (true) : (attempt += 1) {
            c.pacer.wait(c.io, mutation) catch return error.Canceled;
            const token = c.token.get(c.token.ctx, a) catch {
                c.setError("no GitHub token: sign in to GitHub first", .{});
                return error.NoToken;
            };
            if (token.len == 0) {
                c.setError("no GitHub token: sign in to GitHub first", .{});
                return error.NoToken;
            }
            var hs: std.ArrayList(Header) = .empty;
            hs.appendSlice(a, &.{
                .{ .name = "Accept", .value = "application/vnd.github+json" },
                .{ .name = "X-GitHub-Api-Version", .value = c.o.api_version },
                .{ .name = "User-Agent", .value = c.o.user_agent },
                .{ .name = "Authorization", .value = std.fmt.allocPrint(a, "Bearer {s}", .{token}) catch return error.OutOfMemory },
            }) catch return error.OutOfMemory;
            if (etag) |e| hs.append(a, .{ .name = "If-None-Match", .value = e }) catch return error.OutOfMemory;
            if (mutation) hs.append(a, .{ .name = "Content-Type", .value = "application/json" }) catch return error.OutOfMemory;

            var sink: Bounded = .{ .a = a, .max = c.o.max_body };
            const n_in = c.in_flight.fetchAdd(1, .acq_rel);
            std.debug.assert(n_in == 0);
            _ = c.requests.fetchAdd(1, .monotonic);
            const sent = c.transport.send(c.io, a, .{ .method = method, .url = url, .headers = hs.items, .body = body }, .{ .ctx = &sink, .on_chunk = Bounded.onChunk });
            _ = c.in_flight.fetchSub(1, .acq_rel);
            const head = sent catch |e| {
                c.logLine(a, method, url, 0, @errorName(e));
                return switch (e) {
                    error.Canceled => error.Canceled,
                    error.OutOfMemory => error.OutOfMemory,
                    error.Timeout => error.Timeout,
                    error.Aborted => if (sink.over) blk: {
                        c.setError("GitHub's response is larger than {d} bytes", .{c.o.max_body});
                        break :blk error.ResponseTooLarge;
                    } else error.Network,
                    error.Network => blk: {
                        c.setError("could not reach GitHub", .{});
                        break :blk error.Network;
                    },
                };
            };
            c.pacer.observe(c.io, mutation, head.headers);
            c.logLine(a, method, url, head.status, null);
            const reply: Reply = .{ .status = head.status, .headers = head.headers, .body = sink.list.items };
            const msg = if (head.status == 403 or head.status == 429) types.errorMessage(a, reply.body) else null;
            const wait_ms = c.pacer.limitWait(head.status, head.headers, msg, c.o.clock.now(c.io), attempt) orelse return reply;
            if (attempt >= c.o.policy.max_attempts) {
                c.setError("GitHub rate limit: gave up after {d} attempts", .{attempt});
                return error.RateLimited;
            }
            c.pacer.delay(c.o.clock.now(c.io), wait_ms);
        }
    }

    fn logLine(c: *GitHubClient, a: Allocator, method: tp.Method, url: []const u8, status: u16, err: ?[]const u8) void {
        const log = c.o.log orelse return;
        const path = url[@min(trimBase(c.o.api_base).len, url.len)..];
        const text = if (err) |e|
            std.fmt.allocPrint(a, "{s} {s} -> {s}", .{ @tagName(method), path, e })
        else
            std.fmt.allocPrint(a, "{s} {s} -> {d}", .{ @tagName(method), path, status });
        const t = text catch return;
        log.line(log.ctx, c.scrub(a, t) catch return);
    }

    /// `text` without the token.
    fn scrub(c: *GitHubClient, a: Allocator, text: []const u8) Allocator.Error![]const u8 {
        const token = c.token.get(c.token.ctx, a) catch return text;
        if (token.len < 4 or std.mem.indexOf(u8, text, token) == null) return text;
        return std.mem.replaceOwned(u8, a, text, token, "<redacted>");
    }

    fn setError(c: *GitHubClient, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, fmt, args) catch tmp[0..];
        var fba_buf: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
        const clean = c.scrub(fba.allocator(), text) catch "GitHub request failed";
        c.err_len = @min(clean.len, c.err_buf.len);
        @memcpy(c.err_buf[0..c.err_len], clean[0..c.err_len]);
    }
};

/// Collects a body, refusing more than `max` bytes.
const Bounded = struct {
    a: Allocator,
    max: usize,
    list: std.ArrayList(u8) = .empty,
    over: bool = false,

    fn onChunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        if (b.list.items.len + bytes.len > b.max) {
            b.over = true;
            return error.Aborted;
        }
        try b.list.appendSlice(b.a, bytes);
    }
};

fn trimBase(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

/// `&name=value`, percent-encoding the value.
fn writeParam(w: *std.Io.Writer, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try w.print("&{s}=", .{name});
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else try w.print("%{X:0>2}", .{ch});
    }
}
