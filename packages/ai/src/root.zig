//! zg_ai: the headless AI harness core (E10). Providers, the model
//! registry, cost accounting, the agent loop, context assembly, sessions
//! and the cassette/eval tooling. Never imports `zg_gui`.

const std = @import("std");

/// Canonical types (re-exported leaf module).
pub const proto = @import("zg_ai_proto");

pub const capabilities = @import("provider/capabilities.zig");
pub const events = @import("provider/events.zig");
pub const request = @import("provider/request.zig");
pub const assembler = @import("provider/assembler.zig");
pub const transport = @import("provider/transport.zig");
pub const translate = @import("provider/translate.zig");
pub const scripted = @import("provider/scripted.zig");
pub const fake_server = @import("provider/fake_server.zig");
pub const conformance = @import("provider/conformance.zig");
pub const sse_stream = @import("provider/sse_stream.zig");
/// The Anthropic Messages API provider (E10.F02).
pub const anthropic = struct {
    pub const Anthropic = @import("provider/anthropic/Anthropic.zig");
    pub const encode = @import("provider/anthropic/encode.zig");
    pub const decode = @import("provider/anthropic/decode.zig");
    pub const cache = @import("provider/anthropic/cache.zig");
    pub const recovery = @import("provider/anthropic/recovery.zig");
    test {
        _ = @import("provider/anthropic/anthropic_test.zig");
    }
};
/// OpenAI Responses and Chat Completions providers (E10.F03).
pub const openai = struct {
    pub const Responses = @import("provider/openai/Responses.zig");
    pub const Chat = @import("provider/openai/Chat.zig");
    pub const dialects = @import("provider/openai/dialects.zig");
    test {
        _ = @import("provider/openai/responses_test.zig");
        _ = @import("provider/openai/chat_test.zig");
    }
};
/// Gemini provider (E10.F03.S02.T02).
pub const gemini = struct {
    pub const Gemini = @import("provider/gemini/Gemini.zig");
    test {
        _ = @import("provider/gemini/gemini_test.zig");
    }
};
pub const wire = @import("provider/wire.zig");
pub const schema = struct {
    pub const validate = @import("schema/validate.zig");
    pub const strict = @import("schema/strict.zig");
    pub const errors = @import("schema/errors.zig");
};

/// See `provider/Provider.zig`.
pub const Provider = @import("provider/Provider.zig");
/// See `capabilities.Capabilities`.
pub const Capabilities = capabilities.Capabilities;
/// See `request.Request`.
pub const Request = request.Request;
/// See `request.Response`.
pub const Response = request.Response;
/// See `events.StreamEvent`.
pub const StreamEvent = events.StreamEvent;
/// See `events.EventSink`.
pub const EventSink = events.EventSink;
/// See `assembler.MessageAssembler`.
pub const MessageAssembler = assembler.MessageAssembler;
/// See `transport.Transport`.
pub const Transport = transport.Transport;
/// See `scripted.ScriptedProvider`.
pub const ScriptedProvider = scripted.ScriptedProvider;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(schema);
    std.testing.refAllDecls(anthropic);
    std.testing.refAllDecls(openai);
    std.testing.refAllDecls(gemini);
}
