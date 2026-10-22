//! Markdown (E04.F06.S01): a pure parser (no GUI dependency) for
//! CommonMark 0.31.2 with GFM tables, task lists, strikethrough and
//! extended autolinks, and the zigguro extensions (callouts, front
//! matter, math, wikilinks, embeds). Streaming documents reparse only
//! their unstable tail. The AI panel and E08 notes consume it.

const std = @import("std");

/// The `ast.zig` module.
pub const ast = @import("ast.zig");
/// The `doc.zig` module.
pub const doc = @import("doc.zig");
/// The `block.zig` module.
pub const block = @import("block.zig");
/// The `inline.zig` module.
pub const inlines = @import("inline.zig");
/// The `links.zig` module.
pub const links = @import("links.zig");
/// The `entities.zig` module.
pub const entities = @import("entities.zig");
/// The `html.zig` module.
pub const html = @import("html.zig");
/// The `stream.zig` module.
pub const stream = @import("stream.zig");

/// See `doc.Doc`.
pub const Doc = doc.Doc;
/// See `ast.Options`.
pub const Options = ast.Options;
/// See `stream.parse`.
pub const parse = stream.parse;

test {
    std.testing.refAllDecls(@This());
    _ = @import("html_test_serializer.zig");
    _ = @import("spec_test.zig");
    _ = @import("stream_test.zig");
}
