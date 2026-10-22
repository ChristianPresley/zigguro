//! Tokens, the token sink and the `Scanner` helper that hand-written
//! lexers use to walk a line.

const std = @import("std");
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Allocator = std.mem.Allocator;

/// A highlight token. It runs from `start` to the next token's start (or the
/// end of the line), so a line's tokens cover it without gaps.
pub const Token = packed struct(u64) {
    /// Byte offset in the line.
    start: u32,
    /// Language-defined token kind; see `atomic_bit` and `injected_bit`.
    kind: u16,
    hl: HighlightId,

    /// Set on kinds that must stay separate tokens even when a neighbour
    /// has the same kind and highlight (brackets, keywords).
    pub const atomic_bit: u16 = 0x4000;
    /// Set by the framework on tokens of an injected (guest) language.
    pub const injected_bit: u16 = 0x8000;
};

/// Collects one line's tokens. Lexers never fail: the sink reserves room
/// for one token per byte before a line is lexed.
pub const TokenSink = struct {
    toks: std.ArrayList(Token) = .empty,
    /// Or-ed into every kind (the framework sets `injected_bit` for guests).
    kind_or: u16 = 0,

    /// Frees the buffer.
    pub fn deinit(sink: *TokenSink, gpa: Allocator) void {
        sink.toks.deinit(gpa);
    }

    /// Empties the sink and reserves room for a line of `len` bytes.
    pub fn begin(sink: *TokenSink, gpa: Allocator, len: usize) Allocator.Error!void {
        sink.toks.clearRetainingCapacity();
        try sink.toks.ensureTotalCapacity(gpa, len + 1);
        sink.kind_or = 0;
    }

    /// The tokens so far.
    pub fn tokens(sink: *const TokenSink) []const Token {
        return sink.toks.items;
    }

    /// Appends a token. A token at the same start as the previous one
    /// replaces it; one with the same kind and highlight as the previous
    /// one (and no `atomic_bit`) extends it.
    pub fn push(sink: *TokenSink, t_in: Token) void {
        var t = t_in;
        t.kind |= sink.kind_or;
        const items = sink.toks.items;
        if (items.len > 0) {
            const last = &items[items.len - 1];
            if (last.start >= t.start) {
                last.* = t;
                sink.mergeTail();
                return;
            }
            if (last.kind == t.kind and last.hl == t.hl and t.kind & Token.atomic_bit == 0) return;
        }
        sink.toks.appendAssumeCapacity(t);
    }

    fn mergeTail(sink: *TokenSink) void {
        const items = sink.toks.items;
        if (items.len < 2) return;
        const a = items[items.len - 2];
        const b = items[items.len - 1];
        if (a.kind == b.kind and a.hl == b.hl and b.kind & Token.atomic_bit == 0) sink.toks.items.len -= 1;
    }
};

/// A cursor over one line (without its EOL) for hand-written lexers.
pub const Scanner = struct {
    line: []const u8,
    pos: u32 = 0,

    /// The byte at the cursor, or null at the end.
    pub fn peek(s: *const Scanner) ?u8 {
        return if (s.pos < s.line.len) s.line[s.pos] else null;
    }

    /// The byte `off` bytes past the cursor, or null.
    pub fn peekAt(s: *const Scanner, off: u32) ?u8 {
        const i = @as(usize, s.pos) + off;
        return if (i < s.line.len) s.line[i] else null;
    }

    /// The code point at the cursor (U+FFFD for invalid UTF-8), or null.
    pub fn peekCp(s: *const Scanner) ?u21 {
        if (s.pos >= s.line.len) return null;
        const b = s.line[s.pos];
        if (b < 0x80) return b;
        const n = std.unicode.utf8ByteSequenceLength(b) catch return 0xFFFD;
        if (s.pos + n > s.line.len) return 0xFFFD;
        return std.unicode.utf8Decode(s.line[s.pos..][0..n]) catch 0xFFFD;
    }

    /// Whether the cursor is at the end of the line.
    pub fn atEnd(s: *const Scanner) bool {
        return s.pos >= s.line.len;
    }

    /// The bytes from the cursor to the end.
    pub fn rest(s: *const Scanner) []const u8 {
        return s.line[s.pos..];
    }

    /// Moves past one byte (no-op at the end).
    pub fn advance(s: *Scanner) void {
        if (s.pos < s.line.len) s.pos += 1;
    }

    /// Moves past `n` bytes, clamped to the end.
    pub fn advanceBy(s: *Scanner, n: usize) void {
        s.pos = @intCast(@min(s.line.len, s.pos + n));
    }

    /// Moves to the end of the line.
    pub fn skipToEnd(s: *Scanner) void {
        s.pos = @intCast(s.line.len);
    }

    /// Consumes `lit` if the line continues with it.
    pub fn eat(s: *Scanner, lit: []const u8) bool {
        if (!std.mem.startsWith(u8, s.rest(), lit)) return false;
        s.pos += @intCast(lit.len);
        return true;
    }

    /// Consumes the byte `b` if it is next.
    pub fn eatByte(s: *Scanner, b: u8) bool {
        if (s.peek() != b) return false;
        s.pos += 1;
        return true;
    }

    /// Consumes bytes while `pred` holds; returns how many.
    pub fn eatWhile(s: *Scanner, comptime pred: fn (u8) bool) u32 {
        // Locals, not fields: stores to the token sink may alias `s`, which
        // would force a reload per byte.
        const line = s.line;
        const start: usize = s.pos;
        var i = start;
        while (i < line.len and pred(line[i])) i += 1;
        s.pos = @intCast(i);
        return @intCast(i - start);
    }

    /// Consumes an identifier tail: ASCII letters, digits, `_`, and any
    /// non-ASCII byte (so Unicode identifiers stay one token).
    pub fn eatIdent(s: *Scanner) u32 {
        return s.eatWhile(isIdentByte);
    }

    /// Consumes bytes up to (not including) the first byte in `set`.
    pub fn eatUntilAny(s: *Scanner, comptime set: []const u8) u32 {
        const start = s.pos;
        const i = std.mem.indexOfAnyPos(u8, s.line, s.pos, set) orelse s.line.len;
        s.pos = @intCast(i);
        return s.pos - start;
    }

    /// Emits a token starting at `start`.
    pub fn emit(_: *const Scanner, sink: *TokenSink, start: u32, kind: u16, hl: HighlightId) void {
        sink.push(.{ .start = start, .kind = kind, .hl = hl });
    }
};

/// ASCII letters, digits, `_`, and non-ASCII bytes.
pub fn isIdentByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// ASCII letters, `_`, and non-ASCII bytes.
pub fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_' or b >= 0x80;
}

/// Space or tab.
pub fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t';
}

test "scanner: cursor helpers" {
    var s: Scanner = .{ .line = "foo_1 é(\"x\")" };
    try std.testing.expectEqual(@as(u32, 5), s.eatIdent());
    try std.testing.expect(!s.eat("x"));
    try std.testing.expectEqual(@as(u32, 1), s.eatWhile(isBlank));
    try std.testing.expectEqual(@as(?u21, 0xE9), s.peekCp());
    try std.testing.expectEqual(@as(u32, 2), s.eatIdent());
    try std.testing.expect(s.eat("(\""));
    try std.testing.expectEqual(@as(u32, 1), s.eatUntilAny("\""));
    try std.testing.expectEqual(@as(?u8, '"'), s.peek());
    try std.testing.expectEqual(@as(?u8, ')'), s.peekAt(1));
    s.advanceBy(10);
    try std.testing.expect(s.atEnd());
    try std.testing.expectEqual(@as(?u8, null), s.peek());
}

test "token sink: merging and replacement" {
    const gpa = std.testing.allocator;
    var sink: TokenSink = .{};
    defer sink.deinit(gpa);
    try sink.begin(gpa, 16);
    sink.push(.{ .start = 0, .kind = 1, .hl = .comment });
    sink.push(.{ .start = 3, .kind = 1, .hl = .comment }); // merged
    sink.push(.{ .start = 5, .kind = 2 | Token.atomic_bit, .hl = .punctuation_bracket });
    sink.push(.{ .start = 6, .kind = 2 | Token.atomic_bit, .hl = .punctuation_bracket }); // kept
    sink.push(.{ .start = 7, .kind = 3, .hl = .none });
    sink.push(.{ .start = 7, .kind = 4, .hl = .string }); // replaces
    try std.testing.expectEqual(@as(usize, 4), sink.tokens().len);
    try std.testing.expectEqual(HighlightId.string, sink.tokens()[3].hl);
    // A replacement that matches its predecessor merges into it.
    sink.push(.{ .start = 9, .kind = 5, .hl = .none });
    sink.push(.{ .start = 9, .kind = 4, .hl = .string });
    try std.testing.expectEqual(@as(usize, 4), sink.tokens().len);
}
