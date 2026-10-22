//! The editor view (E05.F05): per-view state and editing operations, the
//! zg_gui widget that paints it and routes input to it, and token colours.

const std = @import("std");

/// `EditorView` and its editing operations.
pub const editor_view = @import("editor_view.zig");
/// The editor widget.
pub const widget = @import("widget.zig");
/// Token colours until E15 themes supply them.
pub const syntax_colors = @import("syntax_colors.zig");
/// zg_syntax colours for zg_gui.markdown code blocks.
pub const markdown_highlighter = @import("markdown_highlighter.zig");

/// See `editor_view.EditorView`.
pub const EditorView = editor_view.EditorView;
/// See `editor_view.Options`.
pub const Options = editor_view.Options;
/// See `widget.Editor`.
pub const Editor = widget.Editor;
/// See `widget.editor`.
pub const editor = widget.editor;
/// See `markdown_highlighter.MarkdownHighlighter`.
pub const MarkdownHighlighter = markdown_highlighter.MarkdownHighlighter;

test {
    std.testing.refAllDecls(@This());
    _ = syntax_colors;
    _ = @import("editor_view_test.zig");
    _ = @import("markdown_highlighter_test.zig");
}
