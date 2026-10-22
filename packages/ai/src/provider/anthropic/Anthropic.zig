//! The Anthropic Messages API provider (E10.F02): request encoding, SSE
//! decoding, `count_tokens` and `list_models` over a `Transport`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("../Provider.zig");
const request = @import("../request.zig");
const events = @import("../events.zig");
const tp = @import("../transport.zig");
const translate = @import("../translate.zig");
const sse_stream = @import("../sse_stream.zig");
const Capabilities = @import("../capabilities.zig").Capabilities;
const encode = @import("encode.zig");
const decode = @import("decode.zig");

const Allocator = std.mem.Allocator;
const Anthropic = @This();

/// Provider settings.
pub const Config = struct {
    base_url: []const u8 = "https://api.anthropic.com",
    api_version: []const u8 = "2023-06-01",
    betas: []const []const u8 = &.{},
    timeout_connect_ms: u32 = 10_000,
    idle_timeout_ms: u32 = 120_000,
    /// Fallback key when a request carries none (resolved by ProviderHub).
    api_key: []const u8 = "",
    /// Capabilities; the model registry overrides per model.
    caps: Capabilities = default_caps,
    auto_cache: ?request.CacheTtl = null,
};

/// Capabilities of current Claude models.
pub const default_caps: Capabilities = .{
    .tools = true,
    .parallel_tools = true,
    .forced_tool_choice = true,
    .streaming = true,
    .thinking_budget = true,
    .thinking_adaptive = true,
    .thinking_signed = true,
    .cache_explicit = true,
    .cache_auto = true,
    .token_counting = true,
    .image_input = true,
    .pdf_input = true,
    .structured_output = true,
    .strict_tools = true,
    .server_web_search = true,
    .server_web_fetch = true,
};

gpa: Allocator,
transport: tp.Transport,
cfg: Config,

/// Creates a provider; free with `provider().deinit()`.
pub fn create(gpa: Allocator, t: tp.Transport, cfg: Config) !*Anthropic {
    const a = try gpa.create(Anthropic);
    a.* = .{ .gpa = gpa, .transport = t, .cfg = cfg };
    return a;
}

/// The `Provider` view.
pub fn provider(a: *Anthropic) Provider {
    return .{ .ptr = a, .vtable = &vtable, .id = .anthropic, .caps = a.cfg.caps };
}

const vtable: Provider.VTable = .{ .stream = stream, .count_tokens = countTokensErased, .list_models = listModelsErased, .deinit = deinitErased };

fn deinitErased(ptr: *anyopaque) void {
    const a: *Anthropic = @ptrCast(@alignCast(ptr));
    a.gpa.destroy(a);
}

/// Prepares `req` for encoding: foreign blocks dropped, roles merged.
fn prepare(arena: Allocator, req: *const request.Request) !request.Request {
    var r = req.*;
    r.messages = try encode.normalizeMessages(arena, try translate.translateForProvider(arena, req.messages, .anthropic));
    return r;
}

fn url(a: *const Anthropic, arena: Allocator, path: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, a.cfg.base_url, "/"), path });
}

fn stream(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request, sink: events.EventSink) Provider.StreamError!request.Response {
    const a: *Anthropic = @ptrCast(@alignCast(ptr));
    const r = prepare(arena, req) catch return error.OutOfMemory;
    const body = encode.bodyAlloc(arena, &r, .{ .strict_tools = a.cfg.caps.strict_tools, .auto_cache = a.cfg.auto_cache }) catch |e| return switch (e) {
        error.TooManyCacheBreakpoints => error.InvalidRequest,
        else => error.OutOfMemory,
    };
    const hs = encode.headers(arena, a.cfg.api_version, a.cfg.betas, req.api_key orelse a.cfg.api_key, req) catch return error.OutOfMemory;
    var dec: decode.Decoder = .init(arena, sink);
    const out = try sse_stream.run(io, arena, a.transport, .{
        .url = url(a, arena, "/v1/messages") catch return error.OutOfMemory,
        .headers = hs,
        .body = body,
        .timeout_connect_ms = a.cfg.timeout_connect_ms,
        .idle_timeout_ms = a.cfg.idle_timeout_ms,
    }, &dec);
    const rl = decode.rateLimitFrom(out.head.headers);
    if (rl) |x| sink.send(.{ .rate_limit = x });
    if (out.head.status / 100 != 2) return httpFailure(arena, out, sink);
    var resp = try dec.finish();
    resp.request_id = out.head.request_id;
    resp.rate_limit = rl;
    resp.message.meta.model = resp.message.meta.model orelse req.model;
    return resp;
}

fn httpFailure(arena: Allocator, out: sse_stream.Outcome, sink: events.EventSink) Provider.StreamError {
    const e = decode.parseHttpError(arena, out.prefix);
    const retry_after = out.head.get("retry-after");
    const ra_ms: ?u64 = if (retry_after) |v| (std.fmt.parseInt(u64, std.mem.trim(u8, v, " "), 10) catch 0) * 1000 else null;
    sink.send(.{ .provider_error = .{ .status = out.head.status, .kind = e.kind, .message = e.message, .retry_after_ms = ra_ms, .request_id = out.head.request_id orelse e.request_id } });
    return decode.classifyHttp(out.head.status, e, retry_after != null);
}

fn countTokensErased(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request) Provider.CountError!u64 {
    return countTokens(@ptrCast(@alignCast(ptr)), io, arena, req);
}

/// `POST /v1/messages/count_tokens`; treat the result as an estimate.
/// Server tools are stripped (the endpoint rejects them).
pub fn countTokens(a: *Anthropic, io: std.Io, arena: Allocator, req: *const request.Request) Provider.CountError!u64 {
    const r = prepare(arena, req) catch return error.OutOfMemory;
    const body = encode.bodyAlloc(arena, &r, .{ .count_tokens = true }) catch |e| return switch (e) {
        error.TooManyCacheBreakpoints => error.InvalidRequest,
        else => error.OutOfMemory,
    };
    var hs = encode.headers(arena, a.cfg.api_version, a.cfg.betas, req.api_key orelse a.cfg.api_key, req) catch return error.OutOfMemory;
    hs = setAccept(arena, hs, "application/json") catch return error.OutOfMemory;
    const res = a.transport.sendCollect(io, arena, .{ .url = url(a, arena, "/v1/messages/count_tokens") catch return error.OutOfMemory, .headers = hs, .body = body }) catch |e| return sse_stream.mapTransport(e);
    if (res.head.status / 100 != 2) return httpFailure(arena, .{ .head = res.head, .prefix = res.body }, .discard);
    const v = proto.json.parseValue(arena, res.body) catch return error.Protocol;
    const o = proto.json.asObject(v) orelse return error.Protocol;
    return proto.json.int(u64, o, "input_tokens") orelse error.Protocol;
}

fn setAccept(arena: Allocator, hs: []const request.Header, value: []const u8) ![]const request.Header {
    const out = try arena.dupe(request.Header, hs);
    for (out) |*h| if (std.ascii.eqlIgnoreCase(h.name, "accept")) {
        h.value = value;
    };
    return out;
}

fn listModelsErased(ptr: *anyopaque, io: std.Io, arena: Allocator) Provider.StreamError![]Provider.ModelInfo {
    return listModels(@ptrCast(@alignCast(ptr)), io, arena);
}

/// `GET /v1/models`, following `has_more`/`last_id`.
pub fn listModels(a: *Anthropic, io: std.Io, arena: Allocator) Provider.StreamError![]Provider.ModelInfo {
    var out: std.ArrayList(Provider.ModelInfo) = .empty;
    var after: ?[]const u8 = null;
    var pages: u32 = 0;
    while (pages < 100) : (pages += 1) {
        const u = (if (after) |id|
            std.fmt.allocPrint(arena, "{s}/v1/models?limit=1000&after_id={s}", .{ std.mem.trimEnd(u8, a.cfg.base_url, "/"), id })
        else
            std.fmt.allocPrint(arena, "{s}/v1/models?limit=1000", .{std.mem.trimEnd(u8, a.cfg.base_url, "/")})) catch return error.OutOfMemory;
        const empty: request.Request = .{ .model = "", .messages = &.{} };
        var hs = encode.headers(arena, a.cfg.api_version, a.cfg.betas, a.cfg.api_key, &empty) catch return error.OutOfMemory;
        hs = setAccept(arena, hs[1..], "application/json") catch return error.OutOfMemory;
        const res = a.transport.sendCollect(io, arena, .{ .method = .GET, .url = u, .headers = hs }) catch |e| return sse_stream.mapTransport(e);
        if (res.head.status / 100 != 2) return httpFailure(arena, .{ .head = res.head, .prefix = res.body }, .discard);
        const v = proto.json.parseValue(arena, res.body) catch return error.Protocol;
        const o = proto.json.asObject(v) orelse return error.Protocol;
        const data = o.get("data") orelse return error.Protocol;
        if (data != .array) return error.Protocol;
        for (data.array.items) |item| {
            const m = proto.json.asObject(item) orelse continue;
            out.append(arena, .{
                .id = proto.json.str(m, "id") orelse continue,
                .display_name = proto.json.str(m, "display_name"),
                .context_window = proto.json.int(u32, m, "max_input_tokens"),
                .max_output = proto.json.int(u32, m, "max_tokens"),
            }) catch return error.OutOfMemory;
        }
        if (!proto.json.boolean(o, "has_more")) break;
        after = proto.json.str(o, "last_id") orelse break;
    }
    return out.items;
}
