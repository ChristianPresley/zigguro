//! Trace capture and export on top of zg_core.trace (E14.F02).

/// Trace categories.
pub const categories = @import("trace/categories.zig");
/// The async span taxonomy.
pub const taxonomy = @import("trace/taxonomy.zig");
/// Async spans and flows.
pub const async_span = @import("trace/async_span.zig");

/// The chunked event store.
pub const store = @import("trace/store.zig");
/// The trace ring drain.
pub const drain = @import("trace/drain.zig");
/// Capture sessions, `ZG_TRACE` and the trace folder.
pub const session = @import("trace/session.zig");

/// The flight recorder.
pub const flight_recorder = @import("trace/flight_recorder.zig");

/// See `flight_recorder.FlightRecorder`.
pub const FlightRecorder = flight_recorder.FlightRecorder;
/// See `store.Store`.
pub const Store = store.Store;
/// See `drain.Drain`.
pub const Drain = drain.Drain;
/// See `session.TraceSession`.
pub const TraceSession = session.TraceSession;
/// See `categories.Category`.
pub const Category = categories.Category;
