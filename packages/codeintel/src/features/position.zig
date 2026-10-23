//! LSP positions <-> byte offsets in a document, in the server's column
//! units. Lines past the end clamp to the last line, columns past the end
//! of a line to its end (before the line break).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");

const Allocator = std.mem.Allocator;
const PieceTree = zg_editor.model.buffer.piece_tree.PieceTree;
const Position = zg_lsp.protocol.Position;
pub const Encoding = zg_core.utf8.Encoding;

pub fn encodingOf(e: zg_lsp.position.PositionEncoding) Encoding {
    return switch (e) {
        .utf8 => .utf8,
        .utf16 => .utf16,
        .utf32 => .utf32,
    };
}

/// Converts positions of one tree; reuses a line buffer.
pub const Mapper = struct {
    gpa: Allocator,
    tree: *const PieceTree,
    enc: Encoding,
    scratch: std.ArrayList(u8) = .empty,

    pub fn deinit(m: *Mapper) void {
        m.scratch.deinit(m.gpa);
    }

    fn line(m: *Mapper, l: u64) Allocator.Error![]const u8 {
        return zg_editor.model.syntax.lineSource(m.tree).get(l, &m.scratch, m.gpa);
    }

    /// The byte offset of `p`.
    pub fn byteOf(m: *Mapper, p: Position) Allocator.Error!u64 {
        const l = @min(@as(u64, p.line), m.tree.lineCount() - 1);
        const text = try m.line(l);
        return m.tree.lineStart(l) + zg_core.utf8.columnToByte(text, p.character, m.enc);
    }

    /// The position of byte `off`.
    pub fn positionOf(m: *Mapper, off: u64) Allocator.Error!Position {
        const l = m.tree.lineOf(@min(off, m.tree.len()));
        const start = m.tree.lineStart(l);
        const text = try m.line(l);
        const in_line: usize = @intCast(@min(off - start, text.len));
        return .{ .line = @intCast(l), .character = zg_core.utf8.byteToColumn(text, in_line, m.enc) };
    }
};
