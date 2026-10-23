//! Ollama `POST /api/generate` with `suffix` (docs.ollama.com/openapi.yaml,
//! GenerateRequest): `model`, `prompt` (the prefix), `suffix`, `stream`,
//! `raw: false` so the server applies the model's FIM template,
//! `keep_alive` to keep the model loaded, and `options.num_predict`,
//! `options.stop` and `options.temperature`. Ollama has no field for extra
//! files, so the neighbour snippets go before the prefix as comments. The
//! reply streams NDJSON objects with `response` and `done`.

const std = @import("std");
const context = @import("context.zig");
const providers = @import("providers.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    base_url: []const u8 = "http://127.0.0.1:11434",
    model: []const u8,
    keep_alive: []const u8 = "30m",
};

const Body = struct {
    model: []const u8,
    prompt: []const u8,
    suffix: []const u8,
    stream: bool = true,
    raw: bool = false,
    keep_alive: []const u8,
    options: struct {
        num_predict: u32,
        stop: []const []const u8,
        temperature: f64 = 0.2,
    },
};

/// The JSON request body for `req`.
pub fn body(arena: Allocator, req: *const context.CompletionRequest, o: Options) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, Body{
        .model = o.model,
        .prompt = try withSnippets(arena, req),
        .suffix = req.suffix,
        .keep_alive = o.keep_alive,
        .options = .{ .num_predict = req.max_tokens, .stop = req.stop },
    }, .{});
}

/// The snippets as comments (already budgeted by `buildRequest`), then the
/// prefix.
fn withSnippets(arena: Allocator, req: *const context.CompletionRequest) ![]const u8 {
    if (req.extras.len == 0) return req.prefix;
    const mark = context.commentFor(req.language);
    var out: std.ArrayList(u8) = .empty;
    for (req.extras) |s| {
        try out.print(arena, "{s} {s}\n", .{ mark, s.path });
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s.text, "\n"), '\n');
        while (lines.next()) |l| try out.print(arena, "{s} {s}\n", .{ mark, l });
    }
    try out.appendSlice(arena, req.prefix);
    return out.items;
}

const Chunk = struct {
    response: []const u8 = "",
    done: bool = false,
    @"error": ?[]const u8 = null,
};

/// One NDJSON line.
pub fn decode(arena: Allocator, line: []const u8) !providers.Piece {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0) return .{};
    const c = std.json.parseFromSliceLeaky(Chunk, arena, t, .{ .ignore_unknown_fields = true }) catch return error.BadStream;
    if (c.@"error" != null) return error.BadStream;
    return .{ .text = c.response, .done = c.done };
}
