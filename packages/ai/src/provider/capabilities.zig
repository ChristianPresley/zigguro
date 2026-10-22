//! Provider capability flags. The agent loop and `request.adaptForCaps`
//! degrade gracefully when a flag is off.

/// What a provider (or a specific model behind it) supports.
pub const Capabilities = packed struct(u32) {
    tools: bool = false,
    parallel_tools: bool = false,
    forced_tool_choice: bool = false,
    streaming: bool = false,
    thinking_budget: bool = false,
    thinking_adaptive: bool = false,
    thinking_signed: bool = false,
    cache_explicit: bool = false,
    cache_auto: bool = false,
    token_counting: bool = false,
    image_input: bool = false,
    pdf_input: bool = false,
    structured_output: bool = false,
    strict_tools: bool = false,
    server_web_search: bool = false,
    server_web_fetch: bool = false,
    /// Server keeps conversation state (OpenAI `previous_response_id`).
    stateful: bool = false,
    /// System text may change between turns without breaking the cache.
    mid_conversation_system: bool = false,
    _pad: u14 = 0,

    /// Everything on; used by the scripted provider in tests.
    pub const all: Capabilities = .{
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
        .stateful = false,
        .mid_conversation_system = true,
    };
};
