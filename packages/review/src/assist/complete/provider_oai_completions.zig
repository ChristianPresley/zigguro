//! OpenAI-compatible `POST /v1/completions` (vLLM, LM Studio, llama.cpp's
//! OpenAI endpoint, hosted FIM models) with the FIM template rendered here
//! (`fim.render`): `model`, `prompt`, `max_tokens`, `stop` (the request's
//! plus the template's end tokens), `temperature` and `stream`. The reply
//! streams SSE `data:` objects with `choices[0].text`, then `[DONE]`. Some
//! servers leave end or template tokens in the text, so the output ends at
//! the first one.

const std = @import("std");
const context = @import("context.zig");
const fim = @import("fim.zig");
const providers = @import("providers.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    base_url: []const u8,
    model: []const u8,
    /// The E16 secret that holds the API key (resolved by the caller).
    api_key_ref: ?[]const u8 = null,
    template: *const fim.FimTemplate,
    /// For repository-level templates; empty: none.
    repo_name: []const u8 = "",
};

const Body = struct {
    model: []const u8,
    prompt: []const u8,
    max_tokens: u32,
    stop: []const []const u8,
    temperature: f64 = 0.2,
    stream: bool = true,
};

/// OpenAI-style servers take at most four stops.
const max_stops = 4;

/// The JSON request body for `req`.
pub fn body(arena: Allocator, req: *const context.CompletionRequest, o: Options) ![]const u8 {
    const all = try fim.stops(arena, o.template, req);
    return std.json.Stringify.valueAlloc(arena, Body{
        .model = o.model,
        .prompt = try fim.render(arena, o.template, req, o.repo_name),
        .max_tokens = req.max_tokens,
        .stop = all[0..@min(all.len, max_stops)],
    }, .{});
}

/// The tokens that end the shown text: the template's end tokens and its
/// FIM markers.
pub fn filterTokens(arena: Allocator, t: *const fim.FimTemplate) ![]const []const u8 {
    const ws = " \t";
    const marks = [_][]const u8{
        std.mem.trim(u8, t.prefix_tok, ws),
        std.mem.trim(u8, t.suffix_tok, ws),
        std.mem.trim(u8, t.middle_tok, ws),
    };
    return std.mem.concat(arena, []const u8, &.{ t.eot, &marks });
}

const Choice = struct { text: []const u8 = "", finish_reason: ?[]const u8 = null };
const Chunk = struct { choices: []const Choice = &.{} };

/// One SSE `data:` payload.
pub fn decode(arena: Allocator, data: []const u8) !providers.Piece {
    const t = std.mem.trim(u8, data, " \t\r\n");
    if (std.mem.eql(u8, t, "[DONE]")) return .{ .done = true };
    const c = std.json.parseFromSliceLeaky(Chunk, arena, t, .{ .ignore_unknown_fields = true }) catch return error.BadStream;
    if (c.choices.len == 0) return .{};
    return .{ .text = c.choices[0].text, .done = c.choices[0].finish_reason != null };
}
