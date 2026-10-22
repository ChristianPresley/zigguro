//! Shared plumbing for SSE-speaking HTTP providers: sends a request through
//! a `Transport`, feeds the body to `zg_net.sse.Parser` and hands each event
//! to a provider decoder (`onSse(name, data)`). Keeps the first bytes of the
//! body so non-2xx responses can be classified.

const std = @import("std");
const zg_net = @import("zg_net");
const transport = @import("transport.zig");
const Provider = @import("Provider.zig");

/// Bytes of body kept for error classification.
pub const keep_bytes = 64 * 1024;

/// Result of `run`.
pub const Outcome = struct {
    head: transport.Head,
    /// Up to `keep_bytes` of the raw body (always kept for non-SSE bodies).
    prefix: []const u8,
};

/// Maps a transport failure to a stream error.
pub fn mapTransport(e: transport.TransportError) Provider.StreamError {
    return switch (e) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout => error.Timeout,
        error.Network => error.Network,
        error.Aborted => error.Protocol,
    };
}

/// Streams `req` and feeds SSE events to `decoder.onSse`. Decoder errors
/// abort the read and are returned as is. SSE events are only decoded
/// while the body looks like a stream (callers check the status after).
pub fn run(io: std.Io, arena: std.mem.Allocator, t: transport.Transport, req: transport.HttpRequest, decoder: anytype) Provider.StreamError!Outcome {
    const D = @TypeOf(decoder);
    const Ctx = struct {
        parser: zg_net.sse.Parser,
        decoder: D,
        prefix: std.ArrayList(u8) = .empty,
        arena: std.mem.Allocator,
        failure: ?Provider.StreamError = null,

        fn onChunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            if (c.prefix.items.len < keep_bytes) {
                const n = @min(bytes.len, keep_bytes - c.prefix.items.len);
                try c.prefix.appendSlice(c.arena, bytes[0..n]);
            }
            c.parser.feed(bytes, c) catch |e| {
                if (c.failure == null) c.failure = switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Protocol,
                };
                return error.DecoderFailed;
            };
        }

        pub fn onEvent(c: *@This(), ev: zg_net.sse.Event) !void {
            c.decoder.onSse(ev.type, ev.data) catch |e| {
                c.failure = e;
                return error.DecoderFailed;
            };
        }
    };
    var ctx: Ctx = .{ .parser = .init(arena, .{}), .decoder = decoder, .arena = arena };
    const head = t.send(io, arena, req, .{ .ctx = &ctx, .on_chunk = Ctx.onChunk }) catch |e| {
        if (ctx.failure) |f| return f;
        return mapTransport(e);
    };
    ctx.parser.finish();
    if (ctx.failure) |f| if (head.status / 100 == 2) return f;
    return .{ .head = head, .prefix = ctx.prefix.items };
}
