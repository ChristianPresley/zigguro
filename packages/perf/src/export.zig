//! Trace export (E14.F02.S02.T01): Perfetto protobuf and Chrome JSON
//! writers over zg_core.trace events, with optional path redaction.

/// Minimal protobuf wire encoder.
pub const protobuf = @import("export/protobuf.zig");
/// Path redaction for exported strings.
pub const redact = @import("export/redact.zig");
/// Perfetto TracePacket writer.
pub const perfetto = @import("export/perfetto.zig");
/// Chrome trace-event JSON writer.
pub const chrome = @import("export/chrome.zig");

/// See `redact.Redact`.
pub const Redact = redact.Redact;
