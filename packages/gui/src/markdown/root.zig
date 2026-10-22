//! Markdown (E04.F06.S01): a pure parser (no GUI dependency) for
//! CommonMark 0.31.2 with GFM tables, task lists, strikethrough and
//! extended autolinks, and the zigguro extensions (callouts, front
//! matter, math, wikilinks, embeds). Streaming documents reparse only
//! their unstable tail. `view` renders a document as native UI. The AI
//! panel and E08 notes consume it.

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
/// The `rich.zig` module.
pub const rich = @import("rich.zig");
/// The `selection.zig` module.
pub const selection = @import("selection.zig");
/// The `view.zig` module.
pub const view_mod = @import("view.zig");
/// The `rich_text.zig` module.
pub const rich_text = @import("rich_text.zig");
/// The `code_view.zig` module.
pub const code_view = @import("code_view.zig");
/// The `table_view.zig` module.
pub const table_view = @import("table_view.zig");
/// The `image_view.zig` module.
pub const image_view = @import("image_view.zig");

/// See `doc.Doc`.
pub const Doc = doc.Doc;
/// See `ast.Options`.
pub const Options = ast.Options;
/// See `stream.parse`.
pub const parse = stream.parse;
/// See `view.view`.
pub const view = view_mod.view;
/// See `view.MdViewState`.
pub const MdViewState = view_mod.MdViewState;
/// See `view.MdViewProps`.
pub const MdViewProps = view_mod.MdViewProps;

test {
    std.testing.refAllDecls(@This());
    _ = @import("html_test_serializer.zig");
    _ = @import("spec_test.zig");
    _ = @import("stream_test.zig");
    _ = @import("view_test.zig");
}
