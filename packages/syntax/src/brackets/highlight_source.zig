//! A `BracketSource` over a highlighter's tokens: bracket tokens are the
//! tokens highlighted as brackets whose text is one of the language's
//! bracket pairs, so brackets in strings and comments never count.

const std = @import("std");
const bracket_tree = @import("bracket_tree.zig");
const highlighter = @import("../highlight/highlighter.zig");
const language = @import("../language.zig");

const Allocator = std.mem.Allocator;
const Highlighter = highlighter.Highlighter;
const LineSource = highlighter.LineSource;
const BracketToken = bracket_tree.BracketToken;
const BracketSource = bracket_tree.BracketSource;

/// Byte offsets of lines.
pub const LineIndex = struct {
    ctx: *const anyopaque,
    /// Length of the text.
    len: u64,
    /// Offset of the first byte of `line`.
    startFn: *const fn (ctx: *const anyopaque, line: u64) u64,
    /// The line holding offset `pos`.
    lineOfFn: *const fn (ctx: *const anyopaque, pos: u64) u64,
};

pub const HighlightBrackets = struct {
    gpa: Allocator,
    h: *const Highlighter,
    lines: LineSource,
    index: LineIndex,
    pairs: []const language.BracketPair,
    scratch: std.ArrayList(u8) = .empty,

    /// A source for `h`'s document, whose lines and offsets `lines` and
    /// `index` serve. Brackets are `h`'s language's pairs.
    pub fn init(gpa: Allocator, h: *const Highlighter, lines: LineSource, index: LineIndex) HighlightBrackets {
        return .{ .gpa = gpa, .h = h, .lines = lines, .index = index, .pairs = h.lang.brackets[0..@min(h.lang.brackets.len, bracket_tree.max_pairs)] };
    }

    pub fn deinit(s: *HighlightBrackets) void {
        s.scratch.deinit(s.gpa);
    }

    pub fn source(s: *HighlightBrackets) BracketSource {
        return .{ .ctx = s, .len = s.index.len, .nextFn = next };
    }

    fn next(ctx: *anyopaque, from: u64) Allocator.Error!?BracketToken {
        const s: *HighlightBrackets = @ptrCast(@alignCast(ctx));
        if (from >= s.index.len) return null;
        const n = s.h.lineCount();
        var line = s.index.lineOfFn(s.index.ctx, from);
        while (line < n) : (line += 1) {
            const start = s.index.startFn(s.index.ctx, line);
            const col: u64 = if (from > start) from - start else 0;
            const text = try s.lines.get(line, &s.scratch, s.gpa);
            const toks = s.h.tokens(line);
            for (toks, 0..) |t, i| {
                if (t.start < col or t.hl != .punctuation_bracket) continue;
                const end = if (i + 1 < toks.len) toks[i + 1].start else text.len;
                if (end > text.len or end <= t.start) continue;
                const word = text[t.start..end];
                for (s.pairs, 0..) |p, k| {
                    const open = std.mem.eql(u8, word, p.open);
                    if (!open and !std.mem.eql(u8, word, p.close)) continue;
                    if (word.len > std.math.maxInt(u8)) break;
                    return .{ .offset = start + t.start, .len = @intCast(word.len), .pair = @intCast(k), .open = open };
                }
            }
        }
        return null;
    }
};
