//! Auto-closing pairs: when to auto-close an opener, which closers were
//! auto-inserted in the current typing session (so only those are typed
//! over, and Backspace between such a pair deletes both), and the token
//! context (`TokenQuery`) that keeps pairs out of strings and comments.

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const document = @import("../document.zig");

const Document = document.Document;
const BracketPair = zg_syntax.language.BracketPair;

/// What kind of token covers a position.
pub const TokenKind = enum { code, string, comment, regex, char };

/// Token context at a position (tier-1 tokens; E05.F04).
pub const TokenQuery = struct {
    ptr: *anyopaque,
    kindAtFn: *const fn (ptr: *anyopaque, pos: u64) TokenKind,

    pub fn kindAt(q: TokenQuery, pos: u64) TokenKind {
        return q.kindAtFn(q.ptr, pos);
    }
};

/// The token kind of a highlight.
pub fn kindOf(hl: zg_syntax.HighlightId) TokenKind {
    return switch (hl) {
        .comment, .comment_doc => .comment,
        .string, .string_escape, .string_special => .string,
        .character => .char,
        else => .code,
    };
}

/// When to auto-close (VS Code `editor.autoClosingBrackets`).
pub const AutoClose = enum { always, language_defined, before_whitespace, never };

/// Characters before which an opener auto-closes (besides end of line).
pub const autoclose_before = ";:.,=}])> \t";

/// Whether a quote-like pair (open == close).
pub fn isQuote(p: BracketPair) bool {
    return std.mem.eql(u8, p.open, p.close);
}

/// The pair `cp` opens, if any.
pub fn openerOf(pairs: []const BracketPair, cp: u21) ?BracketPair {
    for (pairs) |p| if (singleCp(p.open) == cp) return p;
    return null;
}

/// The pair `cp` closes, if any.
pub fn closerOf(pairs: []const BracketPair, cp: u21) ?BracketPair {
    for (pairs) |p| if (singleCp(p.close) == cp) return p;
    return null;
}

fn singleCp(s: []const u8) ?u21 {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (n != s.len) return null;
    return std.unicode.utf8Decode(s) catch null;
}

/// Whether to auto-close `p` typed at a caret with `next` (the byte after
/// it, null at end of line), `prev` (the byte before it) and `kind` (the
/// token around it).
pub fn shouldAutoClose(p: BracketPair, mode: AutoClose, next: ?u8, prev: ?u8, kind: TokenKind) bool {
    if (mode == .never) return false;
    if (kind == .comment) return false;
    // Inside a string only the string's own quote may be typed; brackets
    // there are text.
    if (kind == .string or kind == .char) return false;
    if (isQuote(p)) {
        // Not after a word character (it's an apostrophe or a suffix).
        if (prev) |b| if (std.ascii.isAlphanumeric(b) or b == '_') return false;
    }
    const n = next orelse return true;
    if (mode == .before_whitespace) return n == ' ' or n == '\t';
    if (mode == .always) return true;
    return std.mem.indexOfScalar(u8, autoclose_before, n) != null;
}

/// Closers auto-inserted in the current typing session, as positions
/// tagged with the document version they were recorded at (mapped
/// forward when asked). Callers clear it when the caret jumps.
pub const AutoPairs = struct {
    gpa: std.mem.Allocator,
    closers: std.ArrayList(Entry) = .empty,

    const Entry = struct { pos: u64, version: u64 };

    pub fn deinit(a: *AutoPairs) void {
        a.closers.deinit(a.gpa);
    }

    /// Forgets every closer (cursor jump, focus change).
    pub fn clear(a: *AutoPairs) void {
        a.closers.clearRetainingCapacity();
    }

    /// Records a closer at `pos` in the document's current version.
    pub fn add(a: *AutoPairs, doc: *const Document, pos: u64) std.mem.Allocator.Error!void {
        try a.closers.append(a.gpa, .{ .pos = pos, .version = doc.version });
    }

    /// Brings every closer to the current version, dropping those whose
    /// history was evicted or that were deleted.
    pub fn sync(a: *AutoPairs, doc: *const Document) void {
        var out: usize = 0;
        for (a.closers.items) |e| {
            var x = e;
            if (e.version != doc.version) {
                // The closer survives when its byte does: its start moves
                // past insertions before it, its end stays before
                // insertions after it.
                const s = doc.mapForward(e.version, .{ .start = e.pos, .end = e.pos }, .right) orelse continue;
                const t = doc.mapForward(e.version, .{ .start = e.pos + 1, .end = e.pos + 1 }, .left) orelse continue;
                if (t.start != s.start + 1) continue;
                x = .{ .pos = s.start, .version = doc.version };
            }
            a.closers.items[out] = x;
            out += 1;
        }
        a.closers.shrinkRetainingCapacity(out);
    }

    /// Whether an auto-inserted closer sits at `pos` (after `sync`).
    pub fn has(a: *const AutoPairs, pos: u64) bool {
        for (a.closers.items) |e| if (e.pos == pos) return true;
        return false;
    }

    /// Forgets the closer at `pos`.
    pub fn remove(a: *AutoPairs, pos: u64) void {
        for (a.closers.items, 0..) |e, i| if (e.pos == pos) {
            _ = a.closers.swapRemove(i);
            return;
        };
    }
};
