//! The provider interface: a vtable plus identity and capabilities.
//! `stream` runs on a worker thread and calls `sink.emit` synchronously in
//! arrival order. For every provider, `Response.message` equals the fold
//! of the emitted events through `MessageAssembler` (tested per provider).

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("request.zig");
const events = @import("events.zig");

const Provider = @This();

/// Failures of a model call. Details travel in a `provider_error` event.
pub const StreamError = error{
    Canceled,
    OutOfMemory,
    Network,
    Timeout,
    /// 429.
    RateLimited,
    /// 529 / overloaded_error.
    Overloaded,
    /// 401 / 403.
    Auth,
    /// 400 / 404 / 422 other than context overflow.
    InvalidRequest,
    /// Prompt too long for the model.
    ContextOverflow,
    /// 5xx.
    ServerError,
    /// Unparseable stream or response.
    Protocol,
    /// Operation not supported by this provider.
    Unsupported,
    /// The connection ended before the final event.
    StreamTruncated,
    /// No bytes arrived within the idle timeout.
    StreamStalled,
};

/// Failures of `count_tokens`.
pub const CountError = StreamError;

/// A model as listed by a provider.
pub const ModelInfo = struct {
    id: []const u8,
    display_name: ?[]const u8 = null,
    context_window: ?u32 = null,
    max_output: ?u32 = null,
    /// Unix seconds.
    created: ?i64 = null,
};

ptr: *anyopaque,
vtable: *const VTable,
id: proto.ProviderId,
caps: @import("capabilities.zig").Capabilities,

/// Implementation hooks. `arena` owns everything in the returned values.
pub const VTable = struct {
    stream: *const fn (ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator, req: *const request.Request, sink: events.EventSink) StreamError!request.Response,
    count_tokens: ?*const fn (ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator, req: *const request.Request) CountError!u64 = null,
    list_models: ?*const fn (ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator) StreamError![]ModelInfo = null,
    deinit: *const fn (ptr: *anyopaque) void,
};

/// Streams one model call.
pub fn stream(p: Provider, io: std.Io, arena: std.mem.Allocator, req: *const request.Request, sink: events.EventSink) StreamError!request.Response {
    return p.vtable.stream(p.ptr, io, arena, req, sink);
}

/// Exact input token count, or `error.Unsupported`.
pub fn countTokens(p: Provider, io: std.Io, arena: std.mem.Allocator, req: *const request.Request) CountError!u64 {
    const f = p.vtable.count_tokens orelse return error.Unsupported;
    return f(p.ptr, io, arena, req);
}

/// Models offered by the provider, or `error.Unsupported`.
pub fn listModels(p: Provider, io: std.Io, arena: std.mem.Allocator) StreamError![]ModelInfo {
    const f = p.vtable.list_models orelse return error.Unsupported;
    return f(p.ptr, io, arena);
}

/// Releases the provider.
pub fn deinit(p: Provider) void {
    p.vtable.deinit(p.ptr);
}

/// Maps an HTTP status (and provider error type) to a `StreamError`.
pub fn classifyStatus(status: u16, kind: []const u8, message: []const u8) StreamError {
    if (std.mem.indexOf(u8, kind, "overloaded") != null) return error.Overloaded;
    if (std.mem.indexOf(u8, kind, "rate_limit") != null) return error.RateLimited;
    if (isContextOverflow(message) or std.mem.indexOf(u8, kind, "context_length") != null) return error.ContextOverflow;
    return switch (status) {
        401, 403 => error.Auth,
        408 => error.Timeout,
        429 => error.RateLimited,
        529 => error.Overloaded,
        400, 404, 409, 413, 422 => if (status == 413) error.ContextOverflow else error.InvalidRequest,
        500...528, 530...599 => error.ServerError,
        else => error.Protocol,
    };
}

/// Heuristic for "prompt too long" messages across providers.
pub fn isContextOverflow(message: []const u8) bool {
    const needles = [_][]const u8{ "prompt is too long", "context_length_exceeded", "maximum context length", "context window", "too many tokens", "input is too long" };
    for (needles) |n| if (std.ascii.indexOfIgnoreCase(message, n) != null) return true;
    return false;
}

/// True for failures worth retrying (by `RetryPolicy`).
pub fn retryable(e: StreamError) bool {
    return switch (e) {
        error.Network, error.Timeout, error.RateLimited, error.Overloaded, error.ServerError, error.StreamTruncated, error.StreamStalled => true,
        else => false,
    };
}

test "classify statuses" {
    try std.testing.expectEqual(error.Overloaded, classifyStatus(529, "", ""));
    try std.testing.expectEqual(error.Overloaded, classifyStatus(500, "overloaded_error", ""));
    try std.testing.expectEqual(error.RateLimited, classifyStatus(429, "", ""));
    try std.testing.expectEqual(error.ContextOverflow, classifyStatus(400, "invalid_request_error", "prompt is too long: 210000 tokens > 200000 maximum"));
    try std.testing.expectEqual(error.InvalidRequest, classifyStatus(400, "invalid_request_error", "bad"));
    try std.testing.expectEqual(error.Auth, classifyStatus(401, "", ""));
    try std.testing.expectEqual(error.ServerError, classifyStatus(503, "", ""));
    try std.testing.expect(retryable(error.Overloaded) and !retryable(error.Auth));
}
