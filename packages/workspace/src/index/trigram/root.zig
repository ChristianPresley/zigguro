//! The trigram index: segments, queries and the workspace index.

/// LEB128 varints for posting lists.
pub const varint = @import("varint.zig");
/// Segment format, builder and reader.
pub const segment = @import("segment.zig");
/// Queries, literal planning and execution.
pub const query = @import("query.zig");
/// The workspace trigram index.
pub const index = @import("index.zig");
/// See `index.TrigramIndex`.
pub const TrigramIndex = index.TrigramIndex;
/// See `segment.Trigram`.
pub const Trigram = segment.Trigram;
/// See `query.Query`.
pub const Query = query.Query;
/// See `query.planLiteral`.
pub const planLiteral = query.planLiteral;
