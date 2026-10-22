//! Fallback structure: what every language gets without a tier-2 parser.
//! Folds come from bracket pairs (or indentation, for languages that
//! declare `fold_by_indent`), runs of comment lines, region markers and
//! Markdown headings; scopes and the outline come from bracket pairs (or
//! indented blocks) whose header line starts with a declaration keyword.

const std = @import("std");
const structure = @import("structure.zig");
const language = @import("../language.zig");
const bracket_tree = @import("../brackets/bracket_tree.zig");

const Allocator = std.mem.Allocator;
const Builder = structure.Builder;
const ByteRange = structure.ByteRange;
const Structure = structure.Structure;
const SymbolKind = structure.SymbolKind;
const ScopeKind = structure.ScopeKind;
const Language = language.Language;
const BracketTree = bracket_tree.BracketTree;
const BracketPairInfo = bracket_tree.BracketPairInfo;

/// Per-line facts from the lexer, when a highlighter is at hand. Without
/// them, comment lines are recognized by their prefix.
pub const LineHints = struct {
    ctx: *const anyopaque,
    /// Whether `line` holds only comments and blanks (and some comment).
    commentFn: *const fn (ctx: *const anyopaque, line: u64) bool,
};

pub const Options = struct {
    tab_size: u8 = 4,
    hints: ?LineHints = null,
};

/// Runs of comment lines shorter than this do not fold (block comments
/// fold from two lines).
const min_comment_lines = 3;

/// Words that may come before a declaration keyword.
const modifiers = [_][]const u8{
    "pub",        "export",     "async",    "static", "public", "private",  "protected", "internal",
    "inline",     "extern",     "abstract", "final",  "unsafe", "const",    "default",   "override",
    "virtual",    "sealed",     "partial",  "open",   "data",   "noinline", "comptime",  "declare",
    "pub(crate)", "pub(super)",
};

/// Line starts of a text.
const Lines = struct {
    starts: []u32,
    text: []const u8,

    fn init(gpa: Allocator, text: []const u8) Allocator.Error!Lines {
        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(gpa);
        try list.append(gpa, 0);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, i, '\n')) |nl| {
            try list.append(gpa, @intCast(nl + 1));
            i = nl + 1;
        }
        return .{ .starts = try list.toOwnedSlice(gpa), .text = text };
    }

    fn deinit(l: *Lines, gpa: Allocator) void {
        gpa.free(l.starts);
    }

    fn count(l: Lines) u32 {
        return @intCast(l.starts.len);
    }

    fn of(l: Lines, pos: u64) u32 {
        var lo: usize = 0;
        var hi: usize = l.starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (l.starts[mid] <= pos) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo - 1);
    }

    /// `of(pos)` for `pos` at or after the start of line `from`: gallops
    /// forward from there, for positions that come in near order.
    fn ofFrom(l: Lines, from: u32, pos: u64) u32 {
        var lo: usize = from;
        var step: usize = 1;
        var hi: usize = lo + 1;
        while (hi < l.starts.len and l.starts[hi] <= pos) {
            lo = hi;
            hi += step;
            step *= 2;
        }
        hi = @min(hi, l.starts.len);
        // The answer is in [lo, hi).
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (l.starts[mid] <= pos) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// Line `i` without its EOL.
    fn get(l: Lines, i: u32) []const u8 {
        const a = l.starts[i];
        var b: usize = if (i + 1 < l.starts.len) l.starts[i + 1] - 1 else l.text.len;
        if (b > a and l.text[b - 1] == '\r') b -= 1;
        return l.text[a..b];
    }

    /// End of line `i`'s content (before its EOL).
    fn end(l: Lines, i: u32) u32 {
        return l.starts[i] + @as(u32, @intCast(l.get(i).len));
    }
};

fn trimLeft(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t");
}

fn isBlank(s: []const u8) bool {
    return trimLeft(s).len == 0;
}

fn indentOf(s: []const u8, tab: u8) u32 {
    var col: u32 = 0;
    for (s) |c| switch (c) {
        ' ' => col += 1,
        '\t' => col += tab - col % tab,
        else => break,
    };
    return col;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

/// The structure of `text` (at `version`) from its bracket tree (null for
/// languages without brackets) and lines.
pub fn fallbackStructure(gpa: Allocator, text: []const u8, version: u64, bt: ?*const BracketTree, lang: *const Language, o: Options) structure.ParseError!Structure {
    if (text.len > std.math.maxInt(u32)) return error.TooLarge;
    var lines: Lines = try .init(gpa, text);
    defer lines.deinit(gpa);
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    var fb: Fallback = .{ .gpa = gpa, .b = &b, .lines = lines, .lang = lang, .o = o };
    defer fb.deinit();

    const by_indent = lang.fold_by_indent or bt == null;
    if (lang.id == .markdown) {
        try fb.markdown();
    } else {
        if (bt) |t| try fb.brackets(t, !by_indent);
        if (by_indent) try fb.indentation();
        try fb.comments();
    }
    try fb.regions();
    return b.finish(version);
}

const Fallback = struct {
    gpa: Allocator,
    b: *Builder,
    lines: Lines,
    lang: *const Language,
    o: Options,
    /// Open symbols: index and end offset, for parent links.
    sym_stack: std.ArrayList(struct { idx: u32, end: u32 }) = .empty,

    fn deinit(f: *Fallback) void {
        f.sym_stack.deinit(f.gpa);
    }

    // Declarations.

    const Decl = struct { kind: SymbolKind, name: ByteRange };

    /// The declaration that line `i` starts, if any: modifiers, a
    /// declaration keyword, then the name.
    fn declOf(f: *const Fallback, i: u32) ?Decl {
        const line = f.lines.get(i);
        const base = f.lines.starts[i];
        var pos: usize = line.len - trimLeft(line).len;
        while (true) {
            const w = word(line, pos) orelse return null;
            const text = line[w.start..w.end];
            if (isModifier(line, w)) {
                pos = skipModifier(line, w);
                continue;
            }
            for (f.lang.decl_keywords) |k| {
                if (!std.mem.eql(u8, k.word, text)) continue;
                // The name: the next word; for `impl X for Y`, the first.
                const n = word(line, w.end) orelse return .{ .kind = k.kind, .name = .{ .start = base + @as(u32, @intCast(w.start)), .end = base + @as(u32, @intCast(w.end)) } };
                return .{ .kind = k.kind, .name = .{ .start = base + @as(u32, @intCast(n.start)), .end = base + @as(u32, @intCast(n.end)) } };
            }
            return null;
        }
    }

    const Word = struct { start: usize, end: usize };

    /// The next word at or after `from`, skipping blanks and, for names,
    /// a quote (`test "name"`).
    fn word(line: []const u8, from: usize) ?Word {
        var i = from;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i < line.len and line[i] == '"') {
            const close = std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse return null;
            return .{ .start = i + 1, .end = close };
        }
        const start = i;
        while (i < line.len and isWordByte(line[i])) i += 1;
        if (i == start) return null;
        return .{ .start = start, .end = i };
    }

    fn isModifier(line: []const u8, w: Word) bool {
        const text = line[w.start..w.end];
        for (modifiers) |m| if (std.mem.eql(u8, m, text)) return true;
        return false;
    }

    /// Skips a modifier, with its suffix for `pub(crate)` and the like.
    fn skipModifier(line: []const u8, w: Word) usize {
        for (modifiers) |m| if (m.len > w.end - w.start and std.mem.startsWith(u8, line[w.start..], m)) return w.start + m.len;
        return w.end;
    }

    fn scopeKind(k: SymbolKind) ScopeKind {
        return switch (k) {
            .function, .method => .function,
            .test_decl => .test_decl,
            else => .container,
        };
    }

    /// Adds a scope and an outline symbol for a declaration spanning
    /// `range`, with its header on `header_line`.
    fn declare(f: *Fallback, d: Decl, header_line: u32, range: ByteRange, header_end: u32) Allocator.Error!void {
        const name = f.lines.text[d.name.start..d.name.end];
        try f.b.scope(.{ .kind = scopeKind(d.kind), .range = range, .header = .{ .start = f.lines.starts[header_line], .end = header_end }, .name = name });
        while (f.sym_stack.items.len > 0 and f.sym_stack.items[f.sym_stack.items.len - 1].end <= range.start) _ = f.sym_stack.pop();
        const parent: ?u32 = if (f.sym_stack.items.len > 0) f.sym_stack.items[f.sym_stack.items.len - 1].idx else null;
        const idx = try f.b.symbol(.{ .name = name, .kind = d.kind, .range = range, .selection = d.name, .parent = parent });
        try f.sym_stack.append(f.gpa, .{ .idx = idx, .end = range.end });
    }

    // Brackets.

    /// Folds for multi-line pairs and, when `scopes`, scopes and symbols
    /// for pairs that follow a declaration header.
    fn brackets(f: *Fallback, bt: *const BracketTree, scopes: bool) Allocator.Error!void {
        var pairs: std.ArrayList(BracketPairInfo) = .empty;
        defer pairs.deinit(f.gpa);
        try bt.pairsInRange(f.gpa, .{ .start = 0, .end = f.lines.text.len + 1 }, &pairs);
        // Candidate bodies: a header line and a pair.
        const Cand = struct { line: u32, pair: BracketPairInfo };
        var cands: std.ArrayList(Cand) = .empty;
        defer cands.deinit(f.gpa);
        var ol: u32 = 0;
        for (pairs.items) |p| {
            const close = p.close orelse continue;
            // Pairs come in order of their opening brackets.
            ol = f.lines.ofFrom(ol, p.open);
            const cl = f.lines.ofFrom(ol, close);
            if (cl == ol) continue;
            const close_first = isBlank(f.lines.text[f.lines.starts[cl]..close]);
            try f.b.fold(ol, if (close_first) cl - 1 else cl, .block);
            if (!scopes) continue;
            const hl = f.headerLine(bt, ol);
            if (f.declOf(hl) != null) try cands.append(f.gpa, .{ .line = hl, .pair = p });
        }
        if (!scopes) return;
        // Per header line, the pair that ends last is the body; by line, so
        // parents come first.
        std.sort.pdq(Cand, cands.items, {}, struct {
            fn lt(_: void, a: Cand, b: Cand) bool {
                return a.line < b.line or (a.line == b.line and a.pair.close.? > b.pair.close.?);
            }
        }.lt);
        var prev: ?u32 = null;
        for (cands.items) |c| {
            if (prev == c.line) continue;
            prev = c.line;
            const p = c.pair;
            const end: u32 = @intCast(p.close.? + p.close_len);
            try f.declare(f.declOf(c.line).?, c.line, .{ .start = f.lines.starts[c.line], .end = end }, @intCast(p.open + p.open_len));
        }
    }

    /// The line a pair opened on `line` belongs to: lines that start with
    /// a closing bracket continue the line of its opening bracket
    /// (`) -> T {` after a multi-line parameter list).
    fn headerLine(f: *const Fallback, bt: *const BracketTree, line: u32) u32 {
        var l = line;
        var guard: u32 = 0;
        while (guard < 8) : (guard += 1) {
            const text = f.lines.get(l);
            const lead = text.len - trimLeft(text).len;
            if (lead == text.len or !f.closesBracket(text[lead])) return l;
            const pos = f.lines.starts[l] + lead;
            const m = bt.matching(pos) orelse return l;
            if (m.close == null or m.close.? != pos) return l;
            const ol = f.lines.of(m.open);
            if (ol == l) return l;
            l = ol;
        }
        return l;
    }

    fn closesBracket(f: *const Fallback, c: u8) bool {
        for (f.lang.brackets) |p| if (p.close.len > 0 and p.close[0] == c) return true;
        return false;
    }

    // Indentation.

    /// Folds (and declaration scopes) for runs of lines indented deeper
    /// than the line before them; blank lines inside count.
    fn indentation(f: *Fallback) Allocator.Error!void {
        const Open = struct { line: u32, indent: u32 };
        var stack: std.ArrayList(Open) = .empty;
        defer stack.deinit(f.gpa);
        const Block = struct { line: u32, last: u32 };
        var blocks: std.ArrayList(Block) = .empty;
        defer blocks.deinit(f.gpa);
        var last_nonblank: ?u32 = null;
        var i: u32 = 0;
        const n = f.lines.count();
        while (i <= n) : (i += 1) {
            const at_end = i == n;
            const line = if (at_end) "" else f.lines.get(i);
            if (!at_end and isBlank(line)) continue;
            const ind = if (at_end) 0 else indentOf(line, f.o.tab_size);
            while (stack.items.len > 0 and (at_end or stack.items[stack.items.len - 1].indent >= ind)) {
                const h = stack.pop().?;
                const last = last_nonblank.?;
                if (last <= h.line) continue;
                try f.b.fold(h.line, last, .block);
                if (f.declOf(h.line) != null) try blocks.append(f.gpa, .{ .line = h.line, .last = last });
            }
            if (at_end) break;
            try stack.append(f.gpa, .{ .line = i, .indent = ind });
            last_nonblank = i;
        }
        // Blocks close inner first; declare outer first.
        std.sort.pdq(Block, blocks.items, {}, struct {
            fn lt(_: void, a: Block, b: Block) bool {
                return a.line < b.line;
            }
        }.lt);
        for (blocks.items) |blk| {
            const d = f.declOf(blk.line).?;
            try f.declare(d, blk.line, .{ .start = f.lines.starts[blk.line], .end = f.lines.end(blk.last) }, f.lines.end(blk.line));
        }
    }

    // Comments.

    fn isCommentLine(f: *const Fallback, i: u32, in_block: *bool) bool {
        const t = trimLeft(f.lines.get(i));
        const rules = f.lang.edit_rules;
        if (f.o.hints) |h| {
            if (t.len == 0) return false;
            return h.commentFn(h.ctx, i);
        }
        if (in_block.*) {
            if (rules.block_comment) |bc| if (std.mem.indexOf(u8, t, bc.close) != null) {
                in_block.* = false;
            };
            return true;
        }
        if (rules.line_comment) |lc| if (lc.len > 0 and std.mem.startsWith(u8, t, lc)) return true;
        if (rules.block_comment) |bc| if (std.mem.startsWith(u8, t, bc.open)) {
            if (std.mem.indexOfPos(u8, t, bc.open.len, bc.close) == null) in_block.* = true;
            return true;
        };
        return false;
    }

    fn startsBlockComment(f: *const Fallback, i: u32) bool {
        const bc = f.lang.edit_rules.block_comment orelse return false;
        return std.mem.startsWith(u8, trimLeft(f.lines.get(i)), bc.open);
    }

    /// Folds for runs of comment-only lines; region markers break runs.
    fn comments(f: *Fallback) Allocator.Error!void {
        var in_block = false;
        var run_start: ?u32 = null;
        var i: u32 = 0;
        const n = f.lines.count();
        while (i <= n) : (i += 1) {
            const c = i < n and !isMarker(f.lines.get(i)) and f.isCommentLine(i, &in_block);
            if (c) {
                if (run_start == null) run_start = i;
                continue;
            }
            if (run_start) |s| {
                const len = i - s;
                if (len >= min_comment_lines or (len >= 2 and f.startsBlockComment(s))) try f.b.fold(s, i - 1, .comment);
            }
            run_start = null;
        }
    }

    // Regions.

    const Marker = enum { start, end };

    /// Whether `line` is a region marker: a comment opener, then
    /// `#region`/`region` or `#endregion`/`endregion` (`#pragma region` in
    /// C and C++).
    fn marker(line: []const u8) ?Marker {
        var t = trimLeft(line);
        if (std.mem.startsWith(u8, t, "#pragma ")) {
            t = trimLeft(t["#pragma ".len..]);
        } else {
            const openers = [_][]const u8{ "<!--", "//", "/*", "--", "#", ";", "%", "'" };
            var found = false;
            for (openers) |op| if (std.mem.startsWith(u8, t, op)) {
                t = trimLeft(t[op.len..]);
                found = true;
                break;
            };
            if (!found) return null;
        }
        if (t.len > 0 and t[0] == '#') t = t[1..];
        const kinds = [_]struct { []const u8, Marker }{ .{ "endregion", .end }, .{ "region", .start } };
        for (kinds) |k| if (std.mem.startsWith(u8, t, k[0])) {
            const rest = t[k[0].len..];
            if (rest.len == 0 or !isWordByte(rest[0])) return k[1];
        };
        return null;
    }

    fn isMarker(line: []const u8) bool {
        return marker(line) != null;
    }

    fn regions(f: *Fallback) Allocator.Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(f.gpa);
        // Visit only lines that mention "region".
        var pos: usize = 0;
        var last_line: ?u32 = null;
        while (std.mem.indexOfPos(u8, f.lines.text, pos, "region")) |hit| {
            pos = hit + 1;
            const i = f.lines.of(hit);
            if (last_line == i) continue;
            last_line = i;
            switch (marker(f.lines.get(i)) orelse continue) {
                .start => try stack.append(f.gpa, i),
                .end => if (stack.pop()) |s| try f.b.fold(s, i, .region),
            }
        }
    }

    // Markdown.

    /// Section folds and an outline from headings, and folds for fenced
    /// code blocks.
    fn markdown(f: *Fallback) Allocator.Error!void {
        const Open = struct { line: u32, level: u8, sym: u32 };
        var stack: std.ArrayList(Open) = .empty;
        defer stack.deinit(f.gpa);
        var fence: ?struct { line: u32, char: u8, len: usize } = null;
        var last_nonblank: u32 = 0;
        const n = f.lines.count();
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            var level: u8 = 0;
            var name: ByteRange = undefined;
            if (i < n) {
                const line = f.lines.get(i);
                const t = trimLeft(line);
                const lead = line.len - t.len;
                // Fenced code: headings inside do not count.
                if (lead < 4 and t.len >= 3 and (t[0] == '`' or t[0] == '~')) {
                    const run = std.mem.indexOfNone(u8, t, t[0..1]) orelse t.len;
                    if (run >= 3) {
                        if (fence) |fc| {
                            if (fc.char == t[0] and run >= fc.len and isBlank(t[run..])) {
                                try f.b.fold(fc.line, i, .block);
                                fence = null;
                                last_nonblank = i;
                                continue;
                            }
                        } else {
                            fence = .{ .line = i, .char = t[0], .len = run };
                            last_nonblank = i;
                            continue;
                        }
                    }
                }
                if (fence != null) {
                    if (!isBlank(line)) last_nonblank = i;
                    continue;
                }
                if (atx(line)) |h| {
                    level = h.level;
                    const base = f.lines.starts[i];
                    name = .{ .start = base + @as(u32, @intCast(h.start)), .end = base + @as(u32, @intCast(h.end)) };
                } else if (i + 1 < n and !isBlank(line) and lead < 4 and setext(f.lines.get(i + 1)) != 0 and atx(line) == null) {
                    level = setext(f.lines.get(i + 1));
                    const base = f.lines.starts[i];
                    const trimmed = std.mem.trimEnd(u8, t, " \t");
                    name = .{ .start = base + @as(u32, @intCast(lead)), .end = base + @as(u32, @intCast(lead + trimmed.len)) };
                }
                if (level == 0) {
                    if (!isBlank(line)) last_nonblank = i;
                    continue;
                }
            }
            // A heading (or the end) closes sections of its level or deeper.
            while (stack.items.len > 0 and (i == n or stack.items[stack.items.len - 1].level >= level)) {
                const s = stack.pop().?;
                try f.b.fold(s.line, last_nonblank, .block);
                f.b.symbols.items[s.sym].range.end = f.lines.end(@max(last_nonblank, s.line));
            }
            if (i == n) break;
            const parent: ?u32 = if (stack.items.len > 0) stack.items[stack.items.len - 1].sym else null;
            const sym = try f.b.symbol(.{
                .name = f.lines.text[name.start..name.end],
                .kind = .heading,
                .range = .{ .start = f.lines.starts[i], .end = f.lines.end(i) },
                .selection = name,
                .parent = parent,
            });
            try stack.append(f.gpa, .{ .line = i, .level = level, .sym = sym });
            last_nonblank = i;
            // A setext underline belongs to the heading.
            if (setext(if (i + 1 < n) f.lines.get(i + 1) else "") != 0 and atx(f.lines.get(i)) == null) {
                i += 1;
                last_nonblank = i;
            }
        }
    }

    /// An ATX heading: 1-6 `#`, then a blank or the end of the line. The
    /// name drops the closing `#`s.
    fn atx(line: []const u8) ?struct { level: u8, start: usize, end: usize } {
        const t = trimLeft(line);
        const lead = line.len - t.len;
        if (lead >= 4) return null;
        const hashes = std.mem.indexOfNone(u8, t, "#") orelse t.len;
        if (hashes == 0 or hashes > 6) return null;
        if (hashes < t.len and t[hashes] != ' ' and t[hashes] != '\t') return null;
        var body = std.mem.trim(u8, t[hashes..], " \t");
        const closing = std.mem.trimEnd(u8, body, "#");
        if (closing.len == 0 or closing[closing.len - 1] == ' ' or closing[closing.len - 1] == '\t') body = std.mem.trimEnd(u8, closing, " \t");
        const start = lead + hashes + (std.mem.indexOfNone(u8, t[hashes..], " \t") orelse 0);
        return .{ .level = @intCast(hashes), .start = @min(start, line.len), .end = @min(start + body.len, line.len) };
    }

    /// The level of a setext underline (`===` 1, `---` 2), else 0.
    fn setext(line: []const u8) u8 {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or line.len - trimLeft(line).len >= 4) return 0;
        if (std.mem.indexOfNone(u8, t, "=") == null) return 1;
        if (std.mem.indexOfNone(u8, t, "-") == null) return 2;
        return 0;
    }
};
