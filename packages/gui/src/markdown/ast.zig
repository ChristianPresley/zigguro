//! The Markdown AST (E04.F06.S01.T01): blocks and inlines in flat arrays
//! with u32 indices, no per-node allocation.
//!
//! Blocks form a tree through `parent`, `first_child`, `last_child` and
//! `next`; index 0 is the document. Leaf blocks keep their text in
//! `Doc.content` (`Block.content`): the lines after container prefixes
//! were stripped, joined with `\n`, so the inline parser sees one
//! contiguous string. Inline text ranges (`Inline.text`) point into
//! `Doc.content` or, for decoded escapes and entities, into
//! `Doc.text_pool` (`Inline.pooled`).
//!
//! Inlines form a tree the same way (`first_child`, `next`); a leaf
//! block's inlines start at `Block.first_inline`.

const std = @import("std");

/// "No node".
pub const none: u32 = std.math.maxInt(u32);

pub const BlockKind = enum(u8) {
    document,
    paragraph,
    heading,
    thematic_break,
    code_fenced,
    code_indented,
    html_literal,
    block_quote,
    list,
    list_item,
    table,
    table_row,
    table_cell,
    callout,
    front_matter,
    math_block,
    footnote_def,
    link_ref_def,

    /// Holds text lines (as opposed to child blocks).
    pub fn isLeaf(k: BlockKind) bool {
        return switch (k) {
            .paragraph, .heading, .thematic_break, .code_fenced, .code_indented, .html_literal, .front_matter, .math_block, .table_cell, .link_ref_def => true,
            else => false,
        };
    }

    /// Its text is parsed for inlines.
    pub fn hasInlines(k: BlockKind) bool {
        return k == .paragraph or k == .heading or k == .table_cell;
    }
};

pub const Task = enum(u2) { none, unchecked, checked };

pub const Align = enum(u2) { none, left, center, right };

/// List marker data (lists and list items).
pub const ListData = struct {
    ordered: bool = false,
    /// `-`, `+`, `*` for bullets; `.` or `)` for ordered lists.
    marker: u8 = 0,
    start: u32 = 1,
    /// Loose lists wrap item paragraphs in `<p>`.
    tight: bool = true,
    /// Columns from the item's start to its content.
    padding: u16 = 0,
    marker_offset: u16 = 0,
};

pub const Block = struct {
    kind: BlockKind,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next: u32 = none,
    /// Source byte range (start of the first line to the end of the last).
    src: [2]u32 = .{ 0, 0 },
    /// Heading level (1-6); fence length for fenced code.
    level: u8 = 0,
    /// Fenced code info string, callout kind (`note`, `warning`, ...) or
    /// link reference label: a range in `Doc.content`.
    info: [2]u32 = .{ 0, 0 },
    /// Callout title (after `[!kind]`), in `Doc.content`.
    title: [2]u32 = .{ 0, 0 },
    task: Task = .none,
    align_: Align = .none,
    /// Leaf text in `Doc.content`.
    content: [2]u32 = .{ 0, 0 },
    /// The first top-level inline of a leaf (`none` if not parsed).
    first_inline: u32 = none,
    list: ListData = .{},
    /// No more lines can be added.
    closed: bool = false,
    /// `Doc.content.items.len` when the block was created (streaming).
    content_mark: u32 = 0,
    /// The last line added to this block was blank (list tightness).
    last_line_blank: bool = false,
    /// A fenced code block's fence character and indent.
    fence_char: u8 = 0,
    fence_offset: u8 = 0,
    /// HTML block start condition (1-7).
    html_type: u8 = 0,
    /// First and last line numbers within one parse (list tightness).
    line: [2]u32 = .{ 0, 0 },
    /// Source offsets of the starts of the first and last lines.
    line_src: [2]u32 = .{ 0, 0 },
};

pub const InlineKind = enum(u8) {
    text,
    softbreak,
    hardbreak,
    code,
    emph,
    strong,
    strike,
    link,
    image,
    autolink,
    wikilink,
    embed,
    math,
    footnote_ref,
    html_literal,
};

pub const Inline = struct {
    kind: InlineKind,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next: u32 = none,
    prev: u32 = none,
    /// Text of `text`, `code`, `math`, `html_literal`; the target of
    /// `wikilink`/`embed` (its alias, if any, is the children).
    text: [2]u32 = .{ 0, 0 },
    /// Link/image/autolink destination.
    dest: [2]u32 = .{ 0, 0 },
    title: [2]u32 = .{ 0, 0 },
    /// `text` is in `Doc.text_pool` instead of `Doc.content`.
    pooled: bool = false,
    /// `dest` and `title` are in `Doc.text_pool`.
    dest_pooled: bool = false,
    /// The destination is unsafe (`javascript:` and the like): render as
    /// text with a warning.
    unsafe: bool = false,
};

pub const Options = struct {
    gfm: bool = true,
    wikilinks: bool = true,
    callouts: bool = true,
    front_matter: bool = true,
    math: bool = true,
    footnotes: bool = false,
    /// Deeper block quotes and lists become paragraph text.
    max_nesting: u16 = 128,
    max_bytes: u32 = 64 << 20,
};

/// Which top-level blocks an `append` replaced.
pub const Delta = struct {
    first_changed_block: u32,
    removed: u32,
    added: u32,
};

/// A link reference definition.
pub const RefDef = struct {
    /// Normalized label, destination and title, in `Doc.ref_pool`.
    label: [2]u32,
    dest: [2]u32,
    title: [2]u32,
    /// The block that defined it (streaming truncation).
    block: u32,
};

test {
    std.testing.refAllDecls(@This());
}
