//! The 8-byte `Cell` and 8-byte `Row` records stored in pages.

const std = @import("std");

/// What `Cell.content` holds.
pub const Tag = enum(u2) {
    /// A single code point (0 = empty cell).
    codepoint,
    /// The base code point of a grapheme cluster; the rest is in the page's
    /// grapheme map.
    grapheme,
    /// An empty cell with a palette background (erase with BCE).
    bg_palette,
    /// An empty cell with an RGB background (erase with BCE).
    bg_rgb,
};

/// How a cell participates in a wide character.
pub const Wide = enum(u2) {
    /// An ordinary one-column cell.
    narrow,
    /// The first column of a two-column character.
    wide,
    /// The second column of a two-column character (no content of its own).
    spacer_tail,
    /// A filler in the last column when a wide character wrapped to the next row.
    spacer_head,
};

/// Shell-integration semantic zone of a cell (OSC 133).
pub const Semantic = enum(u2) { output, input, prompt, none };

/// One grid cell.
pub const Cell = packed struct(u64) {
    /// Code point (tag .codepoint/.grapheme), palette index or packed RGB.
    content: u24 = 0,
    tag: Tag = .codepoint,
    wide: Wide = .narrow,
    /// Page-local style id; 0 is the default style.
    style: u16 = 0,
    /// The cell has an entry in the page's hyperlink map.
    hyperlink: bool = false,
    /// Protected from selective erase (DECSCA).
    protected: bool = false,
    semantic: Semantic = .output,
    /// Reserved for image placeholders (F08) and future flags.
    _reserved: u16 = 0,

    /// The blank cell.
    pub const blank: Cell = .{};

    /// The code point of a text cell, or 0 for empty and background cells.
    pub fn codepoint(c: Cell) u21 {
        return switch (c.tag) {
            .codepoint, .grapheme => @intCast(c.content),
            else => 0,
        };
    }

    /// Whether the cell shows no text.
    pub fn isEmpty(c: Cell) bool {
        return c.codepoint() == 0;
    }
};

/// The shell-integration mark on a row.
pub const Mark = enum(u3) { none, prompt, input, output_start, output_end, bookmark };

/// Per-row metadata.
pub const Row = packed struct(u64) {
    /// Offset of this row's cells from the page base.
    cells_off: u32 = 0,
    /// The row soft-wraps into the next one.
    wrap: bool = false,
    /// The row is the continuation of a soft-wrapped row.
    wrap_continuation: bool = false,
    /// Some cell has a grapheme map entry.
    has_grapheme: bool = false,
    /// Some cell has a hyperlink map entry.
    has_hyperlink: bool = false,
    /// Some cell has a non-default style.
    styled: bool = false,
    /// Changed since the renderer last snapshot it.
    dirty: bool = false,
    /// Inserted by reflow rather than written by the application.
    synthetic: bool = false,
    mark: Mark = .none,
    _p: u22 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Cell) == 8);
    std.debug.assert(@sizeOf(Row) == 8);
}

test "Cell is 8 bytes, Row is 8 bytes" {
    try std.testing.expectEqual(8, @sizeOf(Cell));
    try std.testing.expectEqual(8, @sizeOf(Row));
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(Cell.blank)));
}
