//! Trace capture and export on top of zg_core.trace (E14.F02).

/// Trace categories.
pub const categories = @import("trace/categories.zig");
/// The async span taxonomy.
pub const taxonomy = @import("trace/taxonomy.zig");
/// Async spans and flows.
pub const async_span = @import("trace/async_span.zig");

/// See `categories.Category`.
pub const Category = categories.Category;
