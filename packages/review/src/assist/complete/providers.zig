//! FIM providers (E12.F07.S01.T03): where ghost-text completions come
//! from. A `FimProvider` streams the middle for a `CompletionRequest`; it
//! blocks, so the engine runs it on a worker task and cancels that task to
//! stop it (`error.Canceled` closes the connection: llama.cpp and Ollama
//! stop generating when the client goes away, and a half-read connection
//! never returns to the pool).
//!
//! - `HttpFim`: llama.cpp `/infill`, Ollama `/api/generate` with `suffix`,
//!   and OpenAI-compatible `/v1/completions` with a template rendered
//!   here. The request bodies and stream decoders live in
//!   `provider_llamacpp.zig`, `provider_ollama.zig` and
//!   `provider_oai_completions.zig`.
//! - `ChatFim` (`provider_chat.zig`): any chat model through a `ChatPort`
//!   the app binds to an E10 Provider, with a `<CURSOR>` marker prompt.
//!
//! A failed completion is not retried (a fast fail beats a late answer).
//! Three failures in a row make a provider unhealthy for 30 s. Remote
//! endpoints need HTTPS unless insecure HTTP is allowed for LAN servers;
//! loopback is always allowed. Prompts and keys are never logged.

const std = @import("std");
const zg_net = @import("zg_net");
const context = @import("context.zig");
const llamacpp = @import("provider_llamacpp.zig");
const ollama = @import("provider_ollama.zig");
const oai = @import("provider_oai_completions.zig");
const fim = @import("fim.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const CompletionRequest = context.CompletionRequest;

pub const Caps = struct {
    /// The provider fills the middle itself (server-side FIM or a chat
    /// prompt), so mid-line requests make sense.
    server_side_template: bool,
};

/// Receives the completion's text as it streams.
pub const Sink = struct {
    ctx: ?*anyopaque,
    text: *const fn (ctx: ?*anyopaque, bytes: []const u8) anyerror!void,
};

pub const FimProvider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    caps: Caps,

    pub const VTable = struct {
        /// Streams the middle for `req` into `sink`; returns when it ends.
        complete: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, req: *const CompletionRequest, sink: Sink) anyerror!void,
        /// A cheap request that opens a connection (editor focus).
        warm: ?*const fn (ctx: *anyopaque, io: Io) void = null,
    };

    pub fn complete(p: FimProvider, io: Io, arena: Allocator, req: *const CompletionRequest, sink: Sink) !void {
        return p.vtable.complete(p.ctx, io, arena, req, sink);
    }

    pub fn warm(p: FimProvider, io: Io) void {
        if (p.vtable.warm) |w| w(p.ctx, io);
    }
};

/// Milliseconds on a monotonic clock; tests pass a virtual one.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_ms: *const fn (ctx: ?*anyopaque, io: Io) u64,

    pub const awake: Clock = .{ .now_ms = struct {
        fn f(_: ?*anyopaque, io: Io) u64 {
            const ns = Io.Clock.awake.now(io).nanoseconds;
            return @intCast(@divTrunc(@max(ns, 0), std.time.ns_per_ms));
        }
    }.f };

    pub fn now(c: Clock, io: Io) u64 {
        return c.now_ms(c.ctx, io);
    }
};

/// Three failures in a row: unhealthy for 30 s (the status bar shows it).
pub const Health = struct {
    failures: u8 = 0,
    until_ms: ?u64 = null,

    pub const max_failures = 3;
    pub const cooldown_ms = 30_000;

    pub fn available(h: *Health, now: u64) bool {
        const until = h.until_ms orelse return true;
        if (now < until) return false;
        h.* = .{};
        return true;
    }

    pub fn healthy(h: *const Health, now: u64) bool {
        return if (h.until_ms) |u| now >= u else true;
    }

    pub fn succeeded(h: *Health) void {
        h.* = .{};
    }

    pub fn failed(h: *Health, now: u64) void {
        h.failures +|= 1;
        if (h.failures >= max_failures) h.until_ms = now + cooldown_ms;
    }
};

/// At most one warm-up per interval.
pub const WarmLimiter = struct {
    last_ms: ?u64 = null,
    interval_ms: u64 = 60_000,

    pub fn take(w: *WarmLimiter, now: u64) bool {
        if (w.last_ms) |l| if (now -| l < w.interval_ms) return false;
        w.last_ms = now;
        return true;
    }
};

pub const EndpointError = error{ InvalidUrl, InsecureEndpoint };

/// Loopback and HTTPS endpoints are fine; plain HTTP to anything else needs
/// `allow_insecure_http` (`completions.allowInsecureHttp`, for LAN servers).
pub fn checkEndpoint(base_url: []const u8, allow_insecure_http: bool) EndpointError!void {
    const uri = std.Uri.parse(base_url) catch return error.InvalidUrl;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidUrl;
    var buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&buf) catch return error.InvalidUrl;
    if (isLoopback(host.bytes) or allow_insecure_http) return;
    return error.InsecureEndpoint;
}

fn isLoopback(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.startsWith(u8, host, "127.") or
        std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "[::1]");
}

/// Ends the output at the first of `tokens` (template tokens a model
/// echoes or end tokens a server leaves in), holding back a tail that may
/// be the start of one until the next chunk shows it is not.
pub const TokenFilter = struct {
    tokens: []const []const u8,
    held: [64]u8 = undefined,
    held_len: u8 = 0,
    ended: bool = false,

    /// Feeds `chunk`; the text to show goes to `sink`.
    pub fn feed(f: *TokenFilter, chunk: []const u8, sink: Sink) !void {
        if (f.ended) return;
        var buf: [4096]u8 = undefined;
        var rest = chunk;
        while (rest.len > 0 and !f.ended) {
            // The held tail plus as much of the chunk as fits.
            const room = buf.len - f.held_len;
            const take = @min(room, rest.len);
            @memcpy(buf[0..f.held_len], f.held[0..f.held_len]);
            @memcpy(buf[f.held_len..][0..take], rest[0..take]);
            rest = rest[take..];
            const text = buf[0 .. f.held_len + take];
            f.held_len = 0;
            if (firstToken(f.tokens, text)) |at| {
                f.ended = true;
                if (at > 0) try sink.text(sink.ctx, text[0..at]);
                return;
            }
            const keep = partialTail(f.tokens, text);
            if (text.len > keep) try sink.text(sink.ctx, text[0 .. text.len - keep]);
            @memcpy(f.held[0..keep], text[text.len - keep ..]);
            f.held_len = @intCast(keep);
        }
    }

    /// The stream ended: shows a held tail that was no token after all.
    pub fn finish(f: *TokenFilter, sink: Sink) !void {
        if (f.ended or f.held_len == 0) return;
        try sink.text(sink.ctx, f.held[0..f.held_len]);
        f.held_len = 0;
    }

    fn firstToken(tokens: []const []const u8, text: []const u8) ?usize {
        var best: ?usize = null;
        for (tokens) |t| {
            if (t.len == 0) continue;
            if (std.mem.indexOf(u8, text, t)) |i| if (best == null or i < best.?) {
                best = i;
            };
        }
        return best;
    }

    /// The longest tail of `text` that starts some token (at most 63 bytes).
    fn partialTail(tokens: []const []const u8, text: []const u8) usize {
        var keep: usize = 0;
        for (tokens) |t| {
            var n = @min(t.len -| 1, text.len, 63);
            while (n > keep) : (n -= 1) {
                if (std.mem.eql(u8, text[text.len - n ..], t[0..n])) {
                    keep = n;
                    break;
                }
            }
        }
        return keep;
    }
};

pub const Kind = enum { llamacpp, ollama, oai_completions };

pub const LlamaCppOptions = llamacpp.Options;
pub const OllamaOptions = ollama.Options;
pub const OaiCompletionsOptions = oai.Options;

pub const HttpOptions = union(Kind) {
    llamacpp: LlamaCppOptions,
    ollama: OllamaOptions,
    oai_completions: OaiCompletionsOptions,

    fn baseUrl(o: HttpOptions) []const u8 {
        return switch (o) {
            inline else => |v| v.base_url,
        };
    }
};

pub const Error = error{ Unhealthy, BadStatus } || EndpointError;

/// An HTTP FIM endpoint on `zg_net`. One per configured completion model;
/// `complete` may run on several workers at once.
pub const HttpFim = struct {
    gpa: Allocator,
    client: *zg_net.http.Client,
    opts: HttpOptions,
    /// The API key, read from E16 secrets by the caller (sent as a bearer
    /// token, never logged).
    api_key: ?[]const u8,
    clock: Clock,
    mutex: Io.Mutex = .init,
    health: Health = .{},
    warm_limit: WarmLimiter = .{},

    pub const Init = struct {
        api_key: ?[]const u8 = null,
        allow_insecure_http: bool = false,
        clock: Clock = .awake,
    };

    pub fn init(gpa: Allocator, client: *zg_net.http.Client, opts: HttpOptions, in: Init) Error!HttpFim {
        try checkEndpoint(opts.baseUrl(), in.allow_insecure_http);
        return .{ .gpa = gpa, .client = client, .opts = opts, .api_key = in.api_key, .clock = in.clock };
    }

    pub fn provider(h: *HttpFim) FimProvider {
        return .{ .ctx = h, .vtable = &vtable, .caps = .{ .server_side_template = h.opts != .oai_completions } };
    }

    /// False while the provider is cooling down after failures.
    pub fn healthy(h: *HttpFim, io: Io) bool {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        return h.health.healthy(h.clock.now(io));
    }

    const vtable: FimProvider.VTable = .{ .complete = completeFn, .warm = warmFn };

    fn from(ctx: *anyopaque) *HttpFim {
        return @ptrCast(@alignCast(ctx));
    }

    fn completeFn(ctx: *anyopaque, io: Io, arena: Allocator, req: *const CompletionRequest, sink: Sink) anyerror!void {
        const h = from(ctx);
        {
            h.mutex.lockUncancelable(io);
            defer h.mutex.unlock(io);
            if (!h.health.available(h.clock.now(io))) return error.Unhealthy;
        }
        h.run(io, arena, req, sink) catch |err| {
            if (err != error.Canceled) {
                h.mutex.lockUncancelable(io);
                defer h.mutex.unlock(io);
                h.health.failed(h.clock.now(io));
            }
            return err;
        };
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        h.health.succeeded();
    }

    fn run(h: *HttpFim, io: Io, arena: Allocator, req: *const CompletionRequest, sink: Sink) !void {
        _ = io;
        const path, const body = switch (h.opts) {
            .llamacpp => |o| .{ "/infill", try llamacpp.body(arena, req, o) },
            .ollama => |o| .{ "/api/generate", try ollama.body(arena, req, o) },
            .oai_completions => |o| .{ "/v1/completions", try oai.body(arena, req, o) },
        };
        const url = try joinUrl(arena, h.opts.baseUrl(), path);
        var hdr_buf: [3]std.http.Header = undefined;
        const hdrs = try h.headers(arena, &hdr_buf);

        var dec: Decoder = try .init(arena, h.opts, sink);
        defer dec.deinit();
        var head = h.client.stream(.{
            .method = .POST,
            .url = url,
            .headers = hdrs,
            .body = body,
            .retry = .never,
        }, .{ .ctx = &dec, .onChunk = Decoder.onChunk, .onHead = Decoder.onHead }) catch |err| switch (err) {
            // The filter saw an end token: the rest is not wanted.
            error.StreamEnded => return dec.finish(),
            else => return err,
        };
        head.deinit(h.client.gpa);
        try dec.finish();
    }

    fn headers(h: *HttpFim, arena: Allocator, buf: *[3]std.http.Header) ![]const std.http.Header {
        var n: usize = 0;
        buf[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;
        buf[n] = .{ .name = "accept", .value = if (h.opts == .ollama) "application/x-ndjson" else "text/event-stream" };
        n += 1;
        if (h.api_key) |k| {
            buf[n] = .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{k}) };
            n += 1;
        }
        return buf[0..n];
    }

    fn warmFn(ctx: *anyopaque, io: Io) void {
        const h = from(ctx);
        {
            h.mutex.lockUncancelable(io);
            defer h.mutex.unlock(io);
            if (!h.warm_limit.take(h.clock.now(io))) return;
        }
        const path = switch (h.opts) {
            .llamacpp => "/health",
            .ollama => "/api/version",
            .oai_completions => "/v1/models",
        };
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const url = joinUrl(fba.allocator(), h.opts.baseUrl(), path) catch return;
        var hdr_buf: [3]std.http.Header = undefined;
        const hdrs = h.headers(fba.allocator(), &hdr_buf) catch return;
        var r = h.client.send(h.gpa, .{ .url = url, .headers = hdrs[2..], .retry = .never }) catch return;
        r.deinit(h.gpa);
    }
};

fn joinUrl(arena: Allocator, base: []const u8, path: []const u8) ![]const u8 {
    const b = std.mem.trimEnd(u8, base, "/");
    // An OpenAI-style base often already ends in /v1.
    const p = if (std.mem.endsWith(u8, b, "/v1") and std.mem.startsWith(u8, path, "/v1/")) path[3..] else path;
    return std.mem.concat(arena, u8, &.{ b, p });
}

/// Turns the response body into text: SSE for llama.cpp and OpenAI-style
/// servers, NDJSON for Ollama.
const Decoder = struct {
    arena: Allocator,
    kind: Kind,
    sse: zg_net.sse.Parser,
    line: std.ArrayList(u8) = .empty,
    filter: TokenFilter,
    sink: Sink,
    done: bool = false,

    fn init(arena: Allocator, opts: HttpOptions, sink: Sink) !Decoder {
        const tokens: []const []const u8 = switch (opts) {
            .oai_completions => |o| try oai.filterTokens(arena, o.template),
            else => &.{},
        };
        return .{
            .arena = arena,
            .kind = opts,
            .sse = .init(arena, .{ .max_event_bytes = 1 << 20 }),
            .filter = .{ .tokens = tokens },
            .sink = sink,
        };
    }

    fn deinit(d: *Decoder) void {
        d.sse.deinit();
    }

    fn onHead(ctx: ?*anyopaque, status: std.http.Status, _: *const zg_net.http.OwnedHeaders) anyerror!void {
        _ = ctx;
        if (status.class() != .success) return error.BadStatus;
    }

    fn onChunk(ctx: ?*anyopaque, chunk: []const u8) anyerror!void {
        const d: *Decoder = @ptrCast(@alignCast(ctx.?));
        switch (d.kind) {
            .llamacpp, .oai_completions => try d.sse.feed(chunk, d),
            .ollama => {
                var rest = chunk;
                while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                    try d.line.appendSlice(d.arena, rest[0..nl]);
                    try d.onLine(d.line.items);
                    d.line.clearRetainingCapacity();
                    rest = rest[nl + 1 ..];
                }
                try d.line.appendSlice(d.arena, rest);
            },
        }
        if (d.done or d.filter.ended) return error.StreamEnded;
    }

    pub fn onEvent(d: *Decoder, ev: zg_net.sse.Event) !void {
        if (d.done) return;
        try d.onLine(ev.data);
    }

    fn onLine(d: *Decoder, line: []const u8) !void {
        if (d.done) return;
        const piece = switch (d.kind) {
            .llamacpp => try llamacpp.decode(d.arena, line),
            .ollama => try ollama.decode(d.arena, line),
            .oai_completions => try oai.decode(d.arena, line),
        };
        if (piece.text.len > 0) try d.filter.feed(piece.text, d.sink);
        if (piece.done) d.done = true;
    }

    fn finish(d: *Decoder) !void {
        if (d.kind == .ollama and d.line.items.len > 0 and !d.done) {
            try d.onLine(d.line.items);
            d.line.clearRetainingCapacity();
        }
        try d.filter.finish(d.sink);
    }
};

/// One decoded stream line.
pub const Piece = struct {
    text: []const u8 = "",
    done: bool = false,
};

test {
    _ = llamacpp;
    _ = ollama;
    _ = oai;
    _ = fim;
}
