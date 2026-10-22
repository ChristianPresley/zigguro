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
}
