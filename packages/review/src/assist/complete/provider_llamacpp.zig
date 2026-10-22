//! llama.cpp server `POST /infill` (tools/server/README.md, "POST
//! /infill: For code infilling"). The server applies the model's FIM
//! tokens, including the repository-level layout when the model has
//! `<|repo_name|>`/`<|file_sep|>`, so the request carries structured
//! fields: `input_prefix`, `input_suffix`, `input_extra` (`[{filename,
//! text}]`), `n_predict`, `stop`, `stream` and `cache_prompt`, which reuses
//! the KV cache for the shared prefix. `id_slot` pins one slot per editor.
//! The reply streams SSE `data:` objects with `content` and `stop`.

const std = @import("std");
const context = @import("context.zig");
const providers = @import("providers.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    base_url: []const u8,
    /// Caps the request's own token limit.
    n_predict: u16 = 256,
    cache_prompt: bool = true,
    id_slot: ?i32 = null,
};

const Extra = struct { filename: []const u8, text: []const u8 };

const Body = struct {
    input_prefix: []const u8,
    input_suffix: []const u8,
    input_extra: []const Extra,
    prompt: []const u8 = "",
    n_predict: u32,
    stop: []const []const u8,
    stream: bool = true,
    cache_prompt: bool,
    id_slot: ?i32,
};

/// The JSON request body for `req`.
pub fn body(arena: Allocator, req: *const context.CompletionRequest, o: Options) ![]const u8 {
    const extra = try arena.alloc(Extra, req.extras.len);
    for (req.extras, extra) |s, *e| e.* = .{ .filename = s.path, .text = s.text };
    return std.json.Stringify.valueAlloc(arena, Body{
        .input_prefix = req.prefix,
        .input_suffix = req.suffix,
        .input_extra = extra,
        .n_predict = @min(req.max_tokens, o.n_predict),
        .stop = req.stop,
        .cache_prompt = o.cache_prompt,
        .id_slot = o.id_slot,
    }, .{ .emit_null_optional_fields = false });
}

const Chunk = struct {
    content: []const u8 = "",
    stop: bool = false,
};

/// One SSE `data:` payload.
pub fn decode(arena: Allocator, data: []const u8) !providers.Piece {
    const c = std.json.parseFromSliceLeaky(Chunk, arena, data, .{ .ignore_unknown_fields = true }) catch return error.BadStream;
    return .{ .text = c.content, .done = c.stop };
}
