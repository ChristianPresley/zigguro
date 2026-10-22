//! Helpers shared by the hand-written C-family lexers: a keyword table
//! with one probe per identifier, a longest-match operator table and the
//! character classes.

const std = @import("std");
const HighlightId = @import("../highlight_names.zig").HighlightId;

/// A reserved word and its highlight.
pub const Word = struct { []const u8, HighlightId };

/// Words in an open-addressing table keyed by a cheap hash of the length
/// and three bytes, so an identifier costs about one probe and at most
/// one comparison.
pub fn WordTable(comptime words: []const Word) type {
    return struct {
        const Entry = struct { word: []const u8 = "", hl: HighlightId = .none };
        const size = std.math.ceilPowerOfTwoAssert(usize, words.len * 4 + 1);
        const max_len = blk: {
            var m: usize = 0;
            for (words) |w| m = @max(m, w[0].len);
            break :blk m;
        };

        fn hash(w: []const u8) usize {
            return ((@as(usize, w[0]) * 31 + w[w.len - 1]) * 31 + w.len * 7 + @as(usize, w[w.len / 2])) & (size - 1);
        }

        const table: [size]Entry = blk: {
            @setEvalBranchQuota(200_000);
            var t: [size]Entry = @splat(.{});
            for (words) |w| {
                var i = hash(w[0]);
                while (t[i].word.len != 0) {
                    if (std.mem.eql(u8, t[i].word, w[0])) @compileError("duplicate word " ++ w[0]);
                    i = (i + 1) & (size - 1);
                }
                t[i] = .{ .word = w[0], .hl = w[1] };
            }
            break :blk t;
        };

        /// The highlight of `w`, or null when it is not in the table.
        pub fn get(w: []const u8) ?HighlightId {
            if (w.len == 0 or w.len > max_len) return null;
            var i = hash(w);
            while (true) : (i = (i + 1) & (size - 1)) {
                const e = &table[i];
                if (e.word.len == 0) return null;
                if (e.word.len == w.len and std.mem.eql(u8, e.word, w)) return e.hl;
            }
        }
    };
}

/// Operators by first byte, longest first, for longest-match lexing.
pub fn OpTable(comptime ops: []const []const u8) type {
    return struct {
        const by_first: [256][]const []const u8 = blk: {
            @setEvalBranchQuota(100_000);
            var t: [256][]const []const u8 = @splat(&.{});
            for (0..256) |c| {
                var list: []const []const u8 = &.{};
                var n: usize = 4;
                while (n > 0) : (n -= 1) {
                    for (ops) |op| if (op.len == n and op[0] == c) {
                        list = list ++ .{op};
                    };
                }
                t[c] = list;
            }
            break :blk t;
        };

        /// Length of the longest operator at the start of `r`, or null.
        pub fn len(r: []const u8) ?usize {
            for (by_first[r[0]]) |op| {
                if (op.len <= r.len and std.mem.eql(u8, op, r[0..op.len])) return op.len;
            }
            return null;
        }
    };
}

/// ASCII letters, `_`, and non-ASCII bytes.
pub fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_' or b >= 0x80;
}

/// ASCII letters, digits, `_`, and non-ASCII bytes.
pub fn isIdent(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Space, tab, carriage return, vertical tab and form feed.
pub fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == 0x0b or b == 0x0c;
}

/// Whether `w` is in SCREAMING_CASE with at least two letters (a macro
/// or a constant by convention).
pub fn isAllCaps(w: []const u8) bool {
    var letters: usize = 0;
    for (w) |c| {
        if (std.ascii.isLower(c) or c >= 0x80) return false;
        if (std.ascii.isUpper(c)) letters += 1;
    }
    return letters >= 2;
}

/// The highlight of an ordinary identifier by convention: a call, a
/// constant, a type (capitalized), or a variable.
pub fn identHl(word: []const u8, next: ?u8) HighlightId {
    if (next == '(') return .function;
    if (isAllCaps(word)) return .constant;
    if (std.ascii.isUpper(word[0])) return .type;
    return .variable;
}

/// The line without a trailing carriage return.
pub fn trimCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// Whether a line resynchronizes the lexer: it starts a declaration or a
/// closing brace at column 0 (a heuristic for far viewports).
pub fn resyncAtColumn0(line: []const u8) bool {
    if (line.len == 0) return false;
    return isIdentStart(line[0]) or line[0] == '}' or line[0] == '#';
}

test "common: word and operator tables" {
    const T = WordTable(&.{ .{ "if", .keyword_control }, .{ "int", .type_builtin }, .{ "return", .keyword_control } });
    try std.testing.expectEqual(HighlightId.type_builtin, T.get("int").?);
    try std.testing.expectEqual(@as(?HighlightId, null), T.get("in"));
    try std.testing.expectEqual(@as(?HighlightId, null), T.get("returning"));
    const O = OpTable(&.{ "<", "<<", "<<=", "<=", "<=>", "-", "->" });
    try std.testing.expectEqual(@as(?usize, 3), O.len("<<=x"));
    try std.testing.expectEqual(@as(?usize, 3), O.len("<=>"));
    try std.testing.expectEqual(@as(?usize, 2), O.len("<="));
    try std.testing.expectEqual(@as(?usize, 1), O.len("<"));
    try std.testing.expectEqual(@as(?usize, null), O.len("+"));
    try std.testing.expect(isAllCaps("MAX_LEN") and !isAllCaps("X") and !isAllCaps("Max"));
}
