//! LSP positions and ranges <-> byte offsets in a document version
//! (E07.F01.S01.T02), in the server's column units, and server results
//! mapped from the version they were computed at to the current one.
//!
//! `\n`, `\r\n` and a lone `\r` end lines, as in LSP. Lines past the end
//! clamp to the end of the text, columns past the end of a line to its end
//! (before the line break), and a column inside a character (between the
//! halves of a UTF-16 surrogate pair, inside a UTF-8 sequence) to the
//! start of that character.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");

const Allocator = std.mem.Allocator;
const PieceTree = zg_editor.model.buffer.piece_tree.PieceTree;
const Document = zg_editor.model.document.Document;
const Position = zg_lsp.protocol.Position;
pub const Encoding = zg_core.utf8.Encoding;
pub const ByteRange = zg_editor.model.buffer.piece_tree.Range;

const log = std.log.scoped(.codeintel);

pub fn encodingOf(e: zg_lsp.position.PositionEncoding) Encoding {
    return switch (e) {
        .utf8 => .utf8,
        .utf16 => .utf16,
        .utf32 => .utf32,
    };
}

/// Converts positions of one tree. Lines are found from the last one
/// looked up when they are near it (results usually come in document
/// order), so a run of conversions does not pay a lookup each.
pub const Mapper = struct {
    gpa: Allocator,
    tree: *const PieceTree,
    enc: Encoding,
    scratch: std.ArrayList(u8) = .empty,
    cursor: LineCursor = .{},
    /// The text of line `text_line` (in the tree or `scratch`).
    text_line: u64 = std.math.maxInt(u64),
    text: []const u8 = "",

    pub fn deinit(m: *Mapper) void {
        m.scratch.deinit(m.gpa);
    }

    fn lineText(m: *Mapper) Allocator.Error![]const u8 {
        if (m.text_line != m.cursor.line) {
            m.text = try m.cursor.text(m.tree, m.gpa, &m.scratch);
            m.text_line = m.cursor.line;
        }
        return m.text;
    }

    /// The byte offset of `p`.
    pub fn byteOf(m: *Mapper, p: Position) Allocator.Error!u64 {
        if (p.line >= m.tree.lineCount()) return m.tree.len();
        const start = m.cursor.seek(m.tree, p.line);
        const text = try m.lineText();
        return start + charStart(text, zg_core.utf8.columnToByte(text, p.character, m.enc));
    }

    /// The position of byte `off`.
    pub fn positionOf(m: *Mapper, off_in: u64) Allocator.Error!Position {
        const off = @min(off_in, m.tree.len());
        const start = m.cursor.seekOffset(m.tree, off);
        const text = try m.lineText();
        const in_line: usize = @intCast(@min(off - start, text.len));
        return .{ .line = @intCast(m.cursor.line), .character = zg_core.utf8.byteToColumn(text, charStart(text, in_line), m.enc) };
    }

    /// `r` in bytes; a range whose end comes before its start is swapped.
    pub fn toRange(m: *Mapper, r: zg_lsp.protocol.Range) Allocator.Error!ByteRange {
        const a = try m.byteOf(r.start);
        const b = try m.byteOf(r.end);
        if (b < a) {
            log.debug("inverted range {d}:{d}-{d}:{d}", .{ r.start.line, r.start.character, r.end.line, r.end.character });
            return .{ .start = b, .end = a };
        }
        return .{ .start = a, .end = b };
    }

    pub fn fromRange(m: *Mapper, r: ByteRange) Allocator.Error!zg_lsp.protocol.Range {
        return .{ .start = try m.positionOf(r.start), .end = try m.positionOf(r.end) };
    }
};

/// The start of the character holding byte `i` of `text`.
fn charStart(text: []const u8, i_in: usize) usize {
    var i = @min(i_in, text.len);
    while (i > 0 and i < text.len and text[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

/// How a result range follows edits made since it was computed.
pub const MapStick = enum {
    /// Dropped when an edit touched its text (diagnostics, inlay hints).
    drop,
    /// Each end moves on its own; dropped only when nothing is left
    /// (references, highlights).
    shrink,
};

/// `r`, computed against version `at_version` of `doc`, in the current
/// version; null when it was edited away (or the version is too old to
/// map).
pub fn mapResultRange(doc: *const Document, at_version: u64, r: ByteRange, stick: MapStick) ?ByteRange {
    if (at_version == doc.version) return r;
    const entries = doc.change_log.since(at_version) orelse return null;
    var cur = r;
    for (entries) |*e| {
        const cs = &e.changes;
        if (stick == .drop) for (cs.replaces) |rep| {
            // Overlapping text, or an insertion strictly inside.
            if (rep.range.start < cur.end and rep.range.end > cur.start) return null;
            if (rep.range.start == rep.range.end and rep.range.start > cur.start and rep.range.start < cur.end) return null;
        };
        const empty = cur.start == cur.end;
        const s = cs.mapPos(cur.start, .right);
        const end = cs.mapPos(cur.end, if (empty) .right else .left);
        if (end < s or (!empty and end == s)) return null;
        cur = .{ .start = s, .end = end };
    }
    return cur;
}

/// Finds line starts in a tree from the last line found: forward by
/// scanning the text when the target is near, otherwise by the tree's
/// own lookup (which scans its piece from the start).
pub const LineCursor = struct {
    line: u64 = 0,
    start: u64 = 0,

    /// Scanning ahead beats a lookup up to this many lines.
    const near = 256;

    /// The start of `target` (or of the last line, when past it).
    pub fn seek(c: *LineCursor, tree: *const PieceTree, target_in: u64) u64 {
        const target = @min(target_in, tree.lineCount() - 1);
        if (target == c.line) return c.start;
        if (target < c.line or target - c.line > near) {
            c.line = target;
            c.start = tree.lineStart(target);
            return c.start;
        }
        const len = tree.len();
        var it = tree.slice(.{ .start = c.start, .end = len });
        var off = c.start;
        while (it.next()) |chunk| {
            var i: usize = 0;
            while (std.mem.indexOfAnyPos(u8, chunk, i, "\r\n")) |j| {
                i = j + 1;
                // The CR of a CRLF: the LF ends the line.
                if (chunk[j] == '\r' and off + j + 1 < len and (if (j + 1 < chunk.len) chunk[j + 1] else tree.byteAt(off + j + 1)) == '\n') continue;
                c.line += 1;
                c.start = off + j + 1;
                if (c.line == target) return c.start;
            }
            off += chunk.len;
        }
        return c.start;
    }

    /// The start of the line holding byte `off` (a CRLF's LF belongs to
    /// the line it ends).
    pub fn seekOffset(c: *LineCursor, tree: *const PieceTree, off: u64) u64 {
        if (off < c.start or off - c.start > near_bytes) return c.seek(tree, tree.lineOf(off));
        const len = tree.len();
        var it = tree.slice(.{ .start = c.start, .end = @min(len, off + 1) });
        var at = c.start;
        while (it.next()) |chunk| {
            var i: usize = 0;
            while (std.mem.indexOfAnyPos(u8, chunk, i, "\r\n")) |j| {
                i = j + 1;
                if (chunk[j] == '\r' and at + j + 1 < len and (if (j + 1 < chunk.len) chunk[j + 1] else tree.byteAt(at + j + 1)) == '\n') continue;
                const next = at + j + 1;
                if (next > off) return c.start;
                c.line += 1;
                c.start = next;
            }
            at += chunk.len;
        }
        return c.start;
    }

    /// Scanning ahead for an offset beats a lookup up to this far.
    const near_bytes = 16 << 10;

    /// The current line without its terminator (in `scratch` when it
    /// spans pieces).
    pub fn text(c: *const LineCursor, tree: *const PieceTree, gpa: Allocator, scratch: *std.ArrayList(u8)) Allocator.Error![]const u8 {
        var it = tree.slice(.{ .start = c.start, .end = tree.len() });
        const first = it.next() orelse return "";
        if (std.mem.indexOfAny(u8, first, "\r\n")) |j| return first[0..j];
        scratch.clearRetainingCapacity();
        try scratch.appendSlice(gpa, first);
        while (it.next()) |chunk| {
            const j = std.mem.indexOfAny(u8, chunk, "\r\n") orelse {
                try scratch.appendSlice(gpa, chunk);
                continue;
            };
            try scratch.appendSlice(gpa, chunk[0..j]);
            break;
        }
        return scratch.items;
    }
};
