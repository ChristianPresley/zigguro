//! Chat Completions server dialects and their quirks.
//!
//! - Ollama ignores `tool_choice` and supports `stream_options.include_usage`
//!   (https://docs.ollama.com/api/openai-compatibility). Its `/v1/responses`
//!   is stateless only; we use chat for uniformity.
//! - llama.cpp `llama-server` streams `reasoning_content` and supports usage;
//!   tool calling depends on the model's chat template
//!   (https://github.com/ggml-org/llama.cpp/tree/master/tools/server).
//! - LM Studio supports `tool_choice` and usage; it also offers
//!   `/v1/responses`, but chat keeps every local server uniform
//!   (https://lmstudio.ai/docs/app/api/endpoints/openai).
//! - generic: the OpenAI Chat Completions reference behaviour.

const std = @import("std");

/// How one server family speaks Chat Completions.
pub const Dialect = struct {
    name: []const u8,
    include_usage: bool = true,
    tool_choice: bool = true,
    /// Field carrying reasoning text in deltas, if any.
    reasoning_field: ?[]const u8 = null,
    /// Remote image URLs are rejected; send data URLs only.
    data_urls_only: bool = false,
    /// Default local base URL probed by discovery.
    default_url: ?[]const u8 = null,
};

/// The built-in dialects.
pub const builtin_dialects = [_]Dialect{
    .{ .name = "ollama", .tool_choice = false, .reasoning_field = "reasoning", .data_urls_only = true, .default_url = "http://127.0.0.1:11434/v1" },
    .{ .name = "llamacpp", .reasoning_field = "reasoning_content", .default_url = "http://127.0.0.1:8080/v1" },
    .{ .name = "lmstudio", .reasoning_field = "reasoning_content", .default_url = "http://127.0.0.1:1234/v1" },
    .{ .name = "generic" },
};

/// The dialect named `name` ("auto" and unknown names map to generic).
pub fn byName(name: []const u8) Dialect {
    for (builtin_dialects) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return builtin_dialects[builtin_dialects.len - 1];
}

/// Picks a dialect from a `/models` response body and the `Server` header.
pub fn identify(base_url: []const u8, models_body: []const u8, server_header: ?[]const u8) Dialect {
    if (server_header) |s| {
        if (std.ascii.indexOfIgnoreCase(s, "llama") != null) return byName("llamacpp");
        if (std.ascii.indexOfIgnoreCase(s, "ollama") != null) return byName("ollama");
    }
    if (std.mem.indexOf(u8, models_body, "\"owned_by\":\"library\"") != null or std.mem.indexOf(u8, models_body, "\"owned_by\": \"library\"") != null) return byName("ollama");
    if (std.mem.indexOf(u8, models_body, "llamacpp") != null) return byName("llamacpp");
    if (std.mem.indexOf(u8, base_url, ":11434") != null) return byName("ollama");
    if (std.mem.indexOf(u8, base_url, ":1234") != null) return byName("lmstudio");
    if (std.mem.indexOf(u8, base_url, ":8080") != null) return byName("llamacpp");
    return byName("generic");
}

test "dialect identification" {
    try std.testing.expectEqualStrings("ollama", identify("http://h:1/v1", "{\"data\":[{\"id\":\"qwen3\",\"owned_by\":\"library\"}]}", null).name);
    try std.testing.expectEqualStrings("llamacpp", identify("http://h:1/v1", "{}", "llama.cpp").name);
    try std.testing.expectEqualStrings("lmstudio", identify("http://127.0.0.1:1234/v1", "{}", null).name);
    try std.testing.expectEqualStrings("generic", byName("auto").name);
}
