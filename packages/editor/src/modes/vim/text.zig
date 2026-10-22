//! Reading the buffer the way Vim's motions do: by character, with the
//! end of a line's content (where Vim has its NUL) as a position of its
//! own, and character classes for words (`iskeyword` defaults).

const std = @import("std");
const pt = @import("../../model/buffer/piece_tree.zig");

const PieceTree = pt.PieceTree;

pub const Text = struct {
    t: *const PieceTree,
    len: u64,

    pub fn init(t: *const PieceTree) Text {
        return .{ .t = t, .len = t.len() };
    }

    pub fn byte(x: Text, pos: u64) u8 {
        return if (pos < x.len) x.t.byteAt(pos) else 0;
    }

    pub fn lineCount(x: Text) u64 {
        return x.t.lineCount();
    }

    pub fn lineOf(x: Text, pos: u64) u64 {
        return x.t.lineOf(@min(pos, x.len));
    }

    pub fn lineStart(x: Text, line: u64) u64 {
        return x.t.lineStart(line);
    }

    /// End of the line's content (before its terminator).
    pub fn lineEnd(x: Text, line: u64) u64 {
        return x.t.lineRange(line).end;
    }

    /// Start of the next line (after the terminator), or the end of text.
    pub fn nextLineStart(x: Text, line: u64) u64 {
        return if (line + 1 < x.lineCount()) x.lineStart(line + 1) else x.len;
    }

    pub fn isLastLine(x: Text, line: u64) bool {
        return line + 1 >= x.lineCount();
    }

    pub fn lineIsEmpty(x: Text, line: u64) bool {
        return x.lineStart(line) == x.lineEnd(line);
    }

    /// Whether `pos` is a line's content end (Vim's NUL).
    pub fn atEol(x: Text, pos: u64) bool {
        if (pos >= x.len) return true;
        const b = x.byte(pos);
        return b == '\n' or b == '\r';
    }

    /// The code point at `pos` (0 at a line end) and its byte length.
    pub fn charAt(x: Text, pos: u64) struct { cp: u21, len: u3 } {
        if (x.atEol(pos)) return .{ .cp = 0, .len = 0 };
        const b0 = x.byte(pos);
        const n = std.unicode.utf8ByteSequenceLength(b0) catch return .{ .cp = b0, .len = 1 };
        if (pos + n > x.len) return .{ .cp = b0, .len = 1 };
        var buf: [4]u8 = undefined;
        for (0..n) |i| buf[i] = x.byte(pos + i);
        const code = std.unicode.utf8Decode(buf[0..n]) catch return .{ .cp = b0, .len = 1 };
        return .{ .cp = code, .len = n };
    }

    pub fn cp(x: Text, pos: u64) u21 {
        return x.charAt(pos).cp;
    }

    /// The position after the character at `pos` (`pos` at a line end).
    pub fn after(x: Text, pos: u64) u64 {
        return pos + x.charAt(pos).len;
    }

    /// The start of the character before `pos` within its line, or `pos`
    /// at a line start.
    pub fn before(x: Text, pos: u64) u64 {
        const ls = x.lineStart(x.lineOf(pos));
        if (pos <= ls) return pos;
        var p = pos - 1;
        var k: u8 = 0;
        while (p > ls and k < 3 and (x.byte(p) & 0xC0) == 0x80) : (k += 1) p -= 1;
        return p;
    }

    /// The last character of `line`, or its start when empty.
    pub fn lastChar(x: Text, line: u64) u64 {
        return x.before(x.lineEnd(line));
    }

    /// Clamps a normal-mode cursor onto a character of its line.
    pub fn clampNormal(x: Text, pos: u64) u64 {
        const p = @min(pos, x.len);
        const line = x.lineOf(p);
        const last = x.lastChar(line);
        if (p > last) return last;
        // Onto the start of the character.
        var q = p;
        const ls = x.lineStart(line);
        while (q > ls and (x.byte(q) & 0xC0) == 0x80) q -= 1;
        return q;
    }

    /// The first non-blank of `line`, or its end.
    pub fn firstNonBlank(x: Text, line: u64) u64 {
        var p = x.lineStart(line);
        const e = x.lineEnd(line);
        while (p < e and isBlank(x.byte(p))) p += 1;
        return p;
    }

    /// The character index of `pos` in its line.
    pub fn column(x: Text, pos: u64) u32 {
        var p = x.lineStart(x.lineOf(pos));
        var c: u32 = 0;
        while (p < pos) : (c += 1) {
            const n = x.charAt(p).len;
            if (n == 0) break;
            p += n;
        }
        return c;
    }

    /// The position of character index `col` in `line`, clamped to the
    /// line's last character (or its end when `past_end`).
    pub fn atColumn(x: Text, line: u64, col: u32, past_end: bool) u64 {
        var p = x.lineStart(line);
        const e = x.lineEnd(line);
        var c: u32 = 0;
        while (c < col and p < e) : (c += 1) p = x.after(p);
        if (!past_end and p >= e) return x.lastChar(line);
        return p;
    }

    /// Steps to the next position (Vim `inc`): 0 within the line, 2 when
    /// landing on the line end, 1 when moving to the next line, -1 at the
    /// end of the text.
    pub fn inc(x: Text, pos: *u64) i8 {
        if (!x.atEol(pos.*)) {
            pos.* = x.after(pos.*);
            return if (x.atEol(pos.*)) 2 else 0;
        }
        const line = x.lineOf(pos.*);
        if (x.isLastLine(line)) return -1;
        pos.* = x.lineStart(line + 1);
        return 1;
    }

    /// Steps to the previous position (Vim `dec`): 0 within the line, 1
    /// when moving to the previous line's end, -1 at the start.
    pub fn dec(x: Text, pos: *u64) i8 {
        const line = x.lineOf(pos.*);
        const ls = x.lineStart(line);
        if (pos.* > ls) {
            pos.* = x.before(@min(pos.*, x.lineEnd(line)));
            return 0;
        }
        if (line == 0) return -1;
        pos.* = x.lineEnd(line - 1);
        return 1;
    }

    /// Vim's character class at `pos`: 0 blank (or line end), 1
    /// punctuation, 2 keyword, others for CJK and emoji; with `big` every
    /// non-blank is 1.
    pub fn class(x: Text, pos: u64, big: bool) u8 {
        const c = classOf(x.cp(pos));
        return if (big and c != 0) 1 else c;
    }
};

pub fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// The class of a code point (`iskeyword` `@,48-57,_,192-255`).
pub fn classOf(c: u21) u8 {
    if (c == 0 or c == ' ' or c == '\t' or c == 0xA0 or c == 0x3000 or (c >= 0x2000 and c <= 0x200A)) return 0;
    if (c < 0x100) {
        if (std.ascii.isAlphanumeric(@intCast(c)) or c == '_' or c >= 192) return 2;
        return 1;
    }
    if ((c >= 0x3040 and c <= 0x30FF) or (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0xAC00 and c <= 0xD7AF)) return 3;
    if (c >= 0x1F000) return 4;
    if (c >= 0x2000 and c <= 0x206F) return 1; // general punctuation
    return 2;
}
