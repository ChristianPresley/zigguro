//! Note frontmatter (E08.F06.S01.T03): the YAML 1.2.2 subset Obsidian
//! properties use, parsed into a value tree whose nodes keep their source
//! byte ranges so `fm_writer` can splice edits without touching anything
//! else. Pure: no I/O and no Markdown parser.
//!
//! Supported (section numbers from YAML 1.2.2):
//! - block mappings (§8.2.2), nested up to depth 4, and block sequences
//!   (§8.2.1) whose items are scalars or flow collections;
//! - flow sequences `[a, "b", 3]` (§7.4.1) and flow mappings `{a: 1}`
//!   (§7.4.2), one level, which may span lines;
//! - plain scalars (§7.3.3), multi-line ones folded with spaces;
//!   single-quoted scalars (`''` escape); double-quoted scalars with the
//!   `\0 \a \b \t \n \v \f \r \e \" \/ \\ \N \_ \L \P \xXX \uXXXX
//!   \UXXXXXXXX` escapes;
//! - literal `|` and folded `>` block scalars with `-`/`+` chomping and an
//!   explicit indentation digit (§8.1);
//! - `#` comments (at line start or after whitespace), empty values (null).
//!
//! Typing follows the core schema (§10.3.2): `null`/`Null`/`NULL`/`~`/empty,
//! `true`/`True`/`TRUE` and the `false` spellings, decimal, `0o` and `0x`
//! ints, floats with `.inf`/`.nan`. `YYYY-MM-DD` is a date and
//! `YYYY-MM-DDThh:mm[:ss][Z|±hh:mm]` (a space may replace `T`) a
//! datetime: an Obsidian convention, not core YAML. Only plain scalars
//! are typed; quoted ones are always strings.
//!
//! Anything else (anchors `&`, aliases `*`, tags `!`, complex `?` keys,
//! sequences of mappings or of sequences, deeper nesting) becomes a
//! `.raw` node holding its source text, with a diagnostic. The parser
//! never fails a note for its content; it fails only on allocation.
//!
//! Plain and single-quoted scalars without escapes and on one line are
//! slices of the source; nothing is allocated for them.

const std = @import("std");
const zg_core = @import("zg_core");

const Allocator = std.mem.Allocator;
const Diagnostics = zg_core.report.Diagnostics;

pub const Date = struct {
    y: i32,
    m: u4,
    d: u5,

    pub fn eql(a: Date, b: Date) bool {
        return a.y == b.y and a.m == b.m and a.d == b.d;
    }
};

pub const DateTime = struct {
    date: Date,
    h: u5,
    min: u6,
    s: u6,
    /// Null when the text had no zone (local time).
    utc_offset_s: ?i32,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    date: Date,
    datetime: DateTime,
    list: []const Node,
    map: []const Pair,
    /// An unsupported construct, kept as its source text.
    raw: []const u8,
};

pub const Style = enum { plain, single_quoted, double_quoted, literal, folded, flow_seq, flow_map, block_seq, block_map };

pub const Node = struct {
    value: Value,
    /// The value's bytes: a scalar token with its quotes, a flow
    /// collection with its brackets, a block scalar from its `|`/`>`
    /// header to its last content line, a block collection from its first
    /// child line's start to its last line's end. Never includes the
    /// final EOL. Empty (just after the colon) for an empty value.
    src: [2]u32,
    style: Style,
};

pub const Pair = struct {
    key: []const u8,
    key_src: [2]u32,
    node: Node,
    /// Whole lines of the entry, from the key line's start to past the
    /// EOL of the value's last line. `fm_writer` removes exactly this.
    span: [2]u32,
};

/// Where the frontmatter of a note is: `body` is the YAML text between
/// the fences, `block` everything from the opening fence (after a BOM) to
/// past the closing fence line's EOL.
pub const Location = struct { body: [2]u32, block: [2]u32 };

pub const max_bytes = 64 * 1024;
pub const max_keys = 1000;
pub const max_depth = 4;

/// Finds the frontmatter: the first line is exactly `---` (trailing spaces
/// allowed, after an optional UTF-8 BOM) and the block ends at the next
/// line that is `---` or `...`. No closing fence means no frontmatter.
pub fn findFrontmatter(note: []const u8) ?Location {
    var i: usize = 0;
    if (std.mem.startsWith(u8, note, "\xEF\xBB\xBF")) i = 3;
    const start = i;
    const first = lineAt(note, i);
    if (!isFence(note[first.start..first.end], false)) return null;
    i = first.next;
    const body_start = i;
    while (i < note.len) {
        const l = lineAt(note, i);
        if (isFence(note[l.start..l.end], true)) {
            return .{ .body = .{ @intCast(body_start), @intCast(l.start) }, .block = .{ @intCast(start), @intCast(l.next) } };
        }
        i = l.next;
    }
    return null;
}

fn isFence(line: []const u8, closing: bool) bool {
    const t = std.mem.trimEnd(u8, line, " \t");
    return std.mem.eql(u8, t, "---") or (closing and std.mem.eql(u8, t, "..."));
}

const LineRef = struct { start: usize, end: usize, next: usize };

/// The line at `i`: `end` excludes `\r\n`/`\n`, `next` is past it.
fn lineAt(s: []const u8, i: usize) LineRef {
    const nl = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse return .{ .start = i, .end = s.len, .next = s.len };
    const end = if (nl > i and s[nl - 1] == '\r') nl - 1 else nl;
    return .{ .start = i, .end = end, .next = nl + 1 };
}

/// Parses YAML text; node ranges are relative to `fm_text`.
pub fn parseFrontmatter(arena: Allocator, fm_text: []const u8, diag: ?*Diagnostics) !Node {
    return parseRange(arena, fm_text, .{ 0, @intCast(fm_text.len) }, diag);
}

/// Parses `note[body[0]..body[1]]`; node ranges are relative to `note`.
pub fn parseRange(arena: Allocator, note: []const u8, body: [2]u32, diag: ?*Diagnostics) !Node {
    if (body[1] - body[0] > max_bytes) {
        report(diag, body[0], "frontmatter is larger than {d} KB; kept as raw text", .{max_bytes / 1024});
        return .{ .value = .{ .raw = note[body[0]..body[1]] }, .src = body, .style = .block_map };
    }
    var p: Parser = .{ .arena = arena, .src = note[0..body[1]], .pos = body[0], .diag = diag };
    try p.buildLines(body[0]);
    const pairs = try p.blockMap(0, 1, true);
    return .{ .value = .{ .map = pairs }, .src = body, .style = .block_map };
}

/// The value of top-level key `name` (exact match), if present.
pub fn get(root: *const Node, name: []const u8) ?*const Node {
    if (root.value != .map) return null;
    for (root.value.map) |*p| if (std.mem.eql(u8, p.key, name)) return &p.node;
    return null;
}

fn report(diag: ?*Diagnostics, offset: u32, comptime fmt: []const u8, args: anytype) void {
    if (diag) |d| d.addDetailed(.warn, "frontmatter", offset, fmt, args);
}

const LineCache = struct {
    start: u32,
    end: u32,
    next: u32,
    indent: u32 = 0,
    blank: bool = false,

    fn fill(c: *LineCache, src: []const u8) void {
        var i = c.start;
        while (i < c.end and src[i] == ' ') i += 1;
        c.indent = i - c.start;
        while (i < c.end and (src[i] == '\t' or src[i] == ' ')) i += 1;
        c.blank = i == c.end or src[i] == '#';
    }
};

const Parser = struct {
    arena: Allocator,
    /// Ends at the body's end.
    src: []const u8,
    pos: u32,
    diag: ?*Diagnostics,
    keys: u32 = 0,
    lines: []LineCache = &.{},
    last: usize = 0,
    /// Returned past the last line.
    end_line: LineCache = .{ .start = 0, .end = 0, .next = 0, .blank = true },

    fn buildLines(p: *Parser, from: u32) !void {
        var list: std.ArrayList(LineCache) = try .initCapacity(p.arena, 16);
        var i: usize = from;
        while (i < p.src.len) {
            const l = lineAt(p.src, i);
            var c: LineCache = .{ .start = @intCast(l.start), .end = @intCast(l.end), .next = @intCast(l.next) };
            c.fill(p.src);
            try list.append(p.arena, c);
            i = l.next;
        }
        p.lines = list.items;
        const e: u32 = @intCast(p.src.len);
        p.end_line = .{ .start = e, .end = e, .next = e, .blank = true };
    }

    fn atEnd(p: *const Parser) bool {
        return p.pos >= p.src.len;
    }

    /// The line containing `at`, from the table built up front; the
    /// parser mostly moves forward, so the last hit is checked first.
    fn lineOf(p: *Parser, at: u32) *const LineCache {
        const ls = p.lines;
        if (p.last < ls.len) {
            const c = &ls[p.last];
            if (at >= c.start and at < c.next) return c;
            if (p.last + 1 < ls.len) {
                const n = &ls[p.last + 1];
                if (at >= n.start and at < n.next) {
                    p.last += 1;
                    return n;
                }
            }
        }
        var lo: usize = 0;
        var hi: usize = ls.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (ls[mid].next <= at) lo = mid + 1 else hi = mid;
        }
        if (lo >= ls.len) return &p.end_line;
        p.last = lo;
        return &ls[lo];
    }

    fn lineEnd(p: *Parser, at: u32) u32 {
        return p.lineOf(at).end;
    }

    fn lineNext(p: *Parser, at: u32) u32 {
        return @min(p.lineOf(at).next, @as(u32, @intCast(p.src.len)));
    }

    fn lineStart(p: *const Parser, at: u32) u32 {
        var i = at;
        while (i > 0 and p.src[i - 1] != '\n') i -= 1;
        return i;
    }

    fn indentAt(p: *Parser, line_start: u32) u32 {
        const c = p.lineOf(line_start);
        if (c.start == line_start) return c.indent;
        var i = line_start;
        while (i < p.src.len and p.src[i] == ' ') i += 1;
        return i - line_start;
    }

    /// Whether the line at `line_start` is empty, blank or a comment.
    fn isBlankLine(p: *Parser, line_start: u32) bool {
        const c = p.lineOf(line_start);
        if (c.start == line_start) return c.blank;
        const t = std.mem.trimStart(u8, p.src[line_start..c.end], " \t");
        return t.len == 0 or t[0] == '#';
    }

    /// The start of the next non-blank line at or after `from` (a line
    /// start), or null.
    fn peekContentLine(p: *Parser, from: u32) ?u32 {
        var i = from;
        while (i < p.src.len) {
            if (!p.isBlankLine(i)) return i;
            i = p.lineNext(i);
        }
        return null;
    }

    /// Moves to the next line start (past the rest of the current line).
    fn finishLine(p: *Parser) void {
        const e = p.lineEnd(p.pos);
        const rest = std.mem.trim(u8, p.src[p.pos..e], " \t");
        if (rest.len > 0 and rest[0] != '#') report(p.diag, p.pos, "unexpected text after a value: {s}", .{rest});
        p.pos = p.lineNext(p.pos);
    }

    /// Skips the lines that belong to a value indented deeper than
    /// `indent` (blank lines in between count, trailing ones do not).
    /// Returns the end (excluding EOL) of the last one, or null.
    fn skipDeeper(p: *Parser, indent: u32) ?u32 {
        var last: ?u32 = null;
        var i = p.pos;
        while (i < p.src.len) {
            if (p.isBlankLine(i)) {
                i = p.lineNext(i);
                continue;
            }
            if (p.indentAt(i) <= indent) break;
            last = p.lineEnd(i);
            i = p.lineNext(i);
            p.pos = i;
        }
        return last;
    }

    fn blockMap(p: *Parser, indent: u32, depth: u32, top: bool) error{OutOfMemory}![]const Pair {
        var pairs: std.ArrayList(Pair) = .empty;
        while (p.peekContentLine(p.pos)) |ls| {
            const ind = p.indentAt(ls);
            if (ind != indent) {
                if (ind > indent and top) {
                    report(p.diag, ls, "unexpected indentation; line kept as is", .{});
                    p.pos = p.lineNext(ls);
                    continue;
                }
                break;
            }
            const c_start = ls + ind;
            const c = p.src[c_start..p.lineEnd(ls)];
            const key_tok = scanKey(c) orelse {
                if (!top) break;
                report(p.diag, ls, "expected `key: value`; line kept as is", .{});
                p.pos = p.lineNext(ls);
                _ = p.skipDeeper(indent);
                continue;
            };
            const key_src: [2]u32 = .{ c_start + key_tok.key[0], c_start + key_tok.key[1] };
            const key = try p.keyText(p.src[key_src[0]..key_src[1]], key_tok.quoted);
            p.pos = c_start + key_tok.colon + 1;
            const node = try p.value(indent, depth, true);
            p.keys += 1;
            if (p.keys > max_keys) {
                if (p.keys == max_keys + 1) report(p.diag, ls, "more than {d} keys; the rest are kept but not read", .{max_keys});
                continue;
            }
            try pairs.append(p.arena, .{ .key = key, .key_src = key_src, .node = node, .span = .{ ls, p.pos } });
        }
        return pairs.items;
    }

    fn keyText(p: *Parser, tok: []const u8, is_quoted: bool) ![]const u8 {
        if (!is_quoted) return tok;
        if (tok[0] == '\'') return try singleQuoted(p.arena, tok[1 .. tok.len - 1]);
        return (try doubleQuoted(p.arena, tok[1 .. tok.len - 1])) orelse tok;
    }

    /// Parses the value at `pos` (just after a key's colon or an item's
    /// dash). On return `pos` is at the start of the line after the
    /// value. `parent_indent` is the column of the key or dash.
    fn value(p: *Parser, parent_indent: u32, depth: u32, in_map: bool) error{OutOfMemory}!Node {
        const after = p.pos;
        const e = p.lineEnd(p.pos);
        while (p.pos < e and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t')) p.pos += 1;
        if (p.pos >= e or (p.src[p.pos] == '#' and p.pos > after)) {
            // Nothing on this line: a nested collection, a scalar on the
            // next line, or null.
            p.pos = p.lineNext(p.pos);
            const empty: Node = .{ .value = .null, .src = .{ after, after }, .style = .plain };
            const ls = p.peekContentLine(p.pos) orelse return empty;
            const ind = p.indentAt(ls);
            const c = p.src[ls + ind .. p.lineEnd(ls)];
            const seq = isSeqItem(c);
            if (!(ind > parent_indent or (in_map and seq and ind == parent_indent))) return empty;
            if (depth >= max_depth) return p.raw(ls, parent_indent, seq, "nesting deeper than 4 levels");
            if (seq) {
                p.pos = ls;
                return p.blockSeq(ind, depth + 1);
            }
            if (scanKey(c) != null) {
                if (!in_map) return p.raw(ls, parent_indent, false, "sequences of mappings are not supported");
                p.pos = ls;
                const pairs = try p.blockMap(ind, depth + 1, false);
                return .{ .value = .{ .map = pairs }, .src = .{ ls, p.lastEnd() }, .style = .block_map };
            }
            p.pos = ls + ind;
            return p.scalarAt(parent_indent);
        }
        const c = p.src[p.pos..e];
        switch (c[0]) {
            '&', '*', '!' => return p.rawFrom(p.pos, parent_indent, "anchors, aliases and tags are not supported"),
            '?' => if (c.len == 1 or c[1] == ' ') return p.rawFrom(p.pos, parent_indent, "complex keys are not supported"),
            '-' => if (!in_map and isSeqItem(c)) return p.rawFrom(p.pos, parent_indent, "nested sequences are not supported"),
            else => {},
        }
        if (!in_map and scanKey(c) != null) return p.rawFrom(p.pos, parent_indent, "sequences of mappings are not supported");
        return p.scalarAt(parent_indent);
    }

    /// A scalar or flow collection starting at `pos`.
    fn scalarAt(p: *Parser, parent_indent: u32) error{OutOfMemory}!Node {
        return switch (p.src[p.pos]) {
            '|', '>' => p.blockScalar(parent_indent),
            '[' => p.flowSeq(parent_indent),
            '{' => p.flowMap(parent_indent),
            '"', '\'' => blk: {
                const n = try p.quoted(parent_indent);
                p.finishLine();
                break :blk n;
            },
            else => p.plain(parent_indent),
        };
    }

    /// The end (excluding EOL) of the line before `pos`.
    fn lastEnd(p: *const Parser) u32 {
        if (p.pos == 0) return 0;
        var i = p.pos - 1;
        if (p.src[i] != '\n') return p.pos;
        if (i > 0 and p.src[i - 1] == '\r') i -= 1;
        return i;
    }

    /// Lines from `ls` that belong to the current value, as raw text.
    fn raw(p: *Parser, ls: u32, parent_indent: u32, same_level_seq: bool, why: []const u8) Node {
        report(p.diag, ls, "{s}; value kept as raw text", .{why});
        const start = ls + p.indentAt(ls);
        p.pos = ls;
        var end = start;
        while (p.peekContentLine(p.pos)) |l| {
            const ind = p.indentAt(l);
            const deeper = ind > parent_indent or (same_level_seq and ind == parent_indent and isSeqItem(p.src[l + ind .. p.lineEnd(l)]));
            if (!deeper) break;
            end = p.lineEnd(l);
            p.pos = p.lineNext(l);
        }
        return .{ .value = .{ .raw = p.src[start..end] }, .src = .{ start, end }, .style = .plain };
    }

    /// From `start` on the current line to the end of the value's lines.
    fn rawFrom(p: *Parser, start: u32, parent_indent: u32, why: []const u8) Node {
        report(p.diag, start, "{s}; value kept as raw text", .{why});
        var end = trimEndWs(p.src, start, p.lineEnd(start));
        p.pos = p.lineNext(start);
        if (p.skipDeeper(parent_indent)) |e| end = e;
        return .{ .value = .{ .raw = p.src[start..end] }, .src = .{ start, end }, .style = .plain };
    }

    fn blockSeq(p: *Parser, indent: u32, depth: u32) error{OutOfMemory}!Node {
        var items: std.ArrayList(Node) = .empty;
        const first = p.pos;
        while (p.peekContentLine(p.pos)) |ls| {
            const ind = p.indentAt(ls);
            if (ind != indent or !isSeqItem(p.src[ls + ind .. p.lineEnd(ls)])) break;
            p.pos = ls + ind + 1;
            try items.append(p.arena, try p.value(indent, depth, false));
        }
        return .{ .value = .{ .list = items.items }, .src = .{ first, p.lastEnd() }, .style = .block_seq };
    }

    fn plain(p: *Parser, parent_indent: u32) error{OutOfMemory}!Node {
        const s = p.pos;
        const l = p.lineOf(s);
        const le = l.end;
        const cm = stripComment(p.src, s, le);
        var end = trimEndWs(p.src, s, cm);
        p.pos = @min(l.next, @as(u32, @intCast(p.src.len)));
        var folded: ?std.ArrayList(u8) = null;
        // Continuation lines: deeper, not blank, not comments; a comment
        // ends the scalar.
        while (cm == le and p.pos < p.src.len and !p.isBlankLine(p.pos) and p.indentAt(p.pos) > parent_indent) {
            const cs = p.pos + p.indentAt(p.pos);
            const ce = trimEndWs(p.src, cs, stripComment(p.src, cs, p.lineEnd(p.pos)));
            if (folded == null) {
                folded = .empty;
                try folded.?.appendSlice(p.arena, p.src[s..end]);
            }
            try folded.?.append(p.arena, ' ');
            try folded.?.appendSlice(p.arena, p.src[cs..ce]);
            end = ce;
            p.pos = p.lineNext(p.pos);
        }
        if (folded) |f| return .{ .value = .{ .string = f.items }, .src = .{ s, end }, .style = .plain };
        return .{ .value = typePlain(p.src[s..end]), .src = .{ s, end }, .style = .plain };
    }

    /// A quoted scalar at `pos`; leaves `pos` just past the closing quote.
    /// Line breaks inside fold to spaces (§7.3.1 flow folding).
    fn quoted(p: *Parser, parent_indent: u32) error{OutOfMemory}!Node {
        _ = parent_indent;
        const s = p.pos;
        const q = p.src[s];
        var i: u32 = s + 1;
        while (i < p.src.len) : (i += 1) {
            const c = p.src[i];
            if (q == '"' and c == '\\') {
                i += 1;
                continue;
            }
            if (c == q) {
                if (q == '\'' and i + 1 < p.src.len and p.src[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                break;
            }
        }
        if (i >= p.src.len) {
            report(p.diag, s, "unterminated quoted string; value kept as raw text", .{});
            const e = trimEndWs(p.src, s, p.lineEnd(s));
            p.pos = e;
            return .{ .value = .{ .raw = p.src[s..e] }, .src = .{ s, e }, .style = .plain };
        }
        const inner = p.src[s + 1 .. i];
        p.pos = i + 1;
        const multi = std.mem.indexOfScalar(u8, inner, '\n') != null;
        const text = if (multi) try foldFlowLines(p.arena, inner) else inner;
        if (q == '\'') return .{ .value = .{ .string = try singleQuoted(p.arena, text) }, .src = .{ s, i + 1 }, .style = .single_quoted };
        const v = (try doubleQuoted(p.arena, text)) orelse {
            report(p.diag, s, "invalid escape in double-quoted string; value kept as raw text", .{});
            return .{ .value = .{ .raw = p.src[s .. i + 1] }, .src = .{ s, i + 1 }, .style = .double_quoted };
        };
        return .{ .value = .{ .string = v }, .src = .{ s, i + 1 }, .style = .double_quoted };
    }

    /// Skips spaces, tabs, line breaks and comments inside a flow
    /// collection.
    fn skipFlowWs(p: *Parser) void {
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                p.pos += 1;
            } else if (c == '#' and (p.pos == 0 or isWs(p.src[p.pos - 1]))) {
                p.pos = p.lineEnd(p.pos);
            } else break;
        }
    }

    /// One flow element (scalar, or a nested collection kept raw).
    fn flowItem(p: *Parser, stops: []const u8, parent_indent: u32) error{ OutOfMemory, Unterminated }!Node {
        const c = p.src[p.pos];
        if (c == '"' or c == '\'') return p.quoted(parent_indent);
        if (c == '[' or c == '{') {
            const s = p.pos;
            const close = matchBracket(p.src, s) orelse return error.Unterminated;
            report(p.diag, s, "nested flow collections are not supported; kept as raw text", .{});
            p.pos = close + 1;
            return .{ .value = .{ .raw = p.src[s .. close + 1] }, .src = .{ s, close + 1 }, .style = if (c == '[') .flow_seq else .flow_map };
        }
        const s = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) {
            const ch = p.src[p.pos];
            if (ch == '\n' or ch == '\r') break;
            if (std.mem.indexOfScalar(u8, stops, ch) != null) {
                // `:` ends a flow-map key only before whitespace or a stop.
                if (ch == ':' and p.pos + 1 < p.src.len and !isWs(p.src[p.pos + 1]) and std.mem.indexOfScalar(u8, ",]}", p.src[p.pos + 1]) == null) continue;
                break;
            }
            if (ch == '#' and p.pos > s and isWs(p.src[p.pos - 1])) break;
        }
        const e = trimEndWs(p.src, s, p.pos);
        return .{ .value = typePlain(p.src[s..e]), .src = .{ s, e }, .style = .plain };
    }

    fn flowSeq(p: *Parser, parent_indent: u32) error{OutOfMemory}!Node {
        const s = p.pos;
        return p.flowSeqInner(parent_indent) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unterminated => p.flowFallback(s, parent_indent),
        };
    }

    fn flowSeqInner(p: *Parser, parent_indent: u32) error{ OutOfMemory, Unterminated }!Node {
        const s = p.pos;
        p.pos += 1;
        var items: std.ArrayList(Node) = .empty;
        while (true) {
            p.skipFlowWs();
            if (p.pos >= p.src.len) return error.Unterminated;
            if (p.src[p.pos] == ']') break;
            try items.append(p.arena, try p.flowItem(",]", parent_indent));
            p.skipFlowWs();
            if (p.pos >= p.src.len) return error.Unterminated;
            if (p.src[p.pos] == ',') {
                p.pos += 1;
                continue;
            }
            if (p.src[p.pos] == ']') break;
            return error.Unterminated;
        }
        p.pos += 1;
        const end = p.pos;
        p.finishLine();
        return .{ .value = .{ .list = items.items }, .src = .{ s, end }, .style = .flow_seq };
    }

    fn flowMap(p: *Parser, parent_indent: u32) error{OutOfMemory}!Node {
        const s = p.pos;
        return p.flowMapInner(parent_indent) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unterminated => p.flowFallback(s, parent_indent),
        };
    }

    fn flowMapInner(p: *Parser, parent_indent: u32) error{ OutOfMemory, Unterminated }!Node {
        const s = p.pos;
        p.pos += 1;
        var pairs: std.ArrayList(Pair) = .empty;
        while (true) {
            p.skipFlowWs();
            if (p.pos >= p.src.len) return error.Unterminated;
            if (p.src[p.pos] == '}') break;
            const ks = p.pos;
            const k = try p.flowItem(":,}", parent_indent);
            const key: []const u8 = switch (k.value) {
                .string => |str| str,
                .raw => |r| r,
                else => p.src[k.src[0]..k.src[1]],
            };
            p.skipFlowWs();
            var node: Node = .{ .value = .null, .src = .{ p.pos, p.pos }, .style = .plain };
            if (p.pos < p.src.len and p.src[p.pos] == ':') {
                p.pos += 1;
                p.skipFlowWs();
                if (p.pos >= p.src.len) return error.Unterminated;
                if (p.src[p.pos] != ',' and p.src[p.pos] != '}') node = try p.flowItem(",}", parent_indent);
                p.skipFlowWs();
            }
            try pairs.append(p.arena, .{ .key = key, .key_src = k.src, .node = node, .span = .{ ks, node.src[1] } });
            if (p.pos >= p.src.len) return error.Unterminated;
            if (p.src[p.pos] == ',') {
                p.pos += 1;
                continue;
            }
            if (p.src[p.pos] == '}') break;
            return error.Unterminated;
        }
        p.pos += 1;
        const end = p.pos;
        p.finishLine();
        return .{ .value = .{ .map = pairs.items }, .src = .{ s, end }, .style = .flow_map };
    }

    fn flowFallback(p: *Parser, s: u32, parent_indent: u32) Node {
        p.pos = s;
        return p.rawFrom(s, parent_indent, "unterminated or malformed flow collection");
    }

    fn blockScalar(p: *Parser, parent_indent: u32) error{OutOfMemory}!Node {
        const s = p.pos;
        const literal = p.src[s] == '|';
        var chomp: enum { clip, strip, keep } = .clip;
        var explicit: ?u32 = null;
        var i = s + 1;
        const le = p.lineEnd(s);
        while (i < le) : (i += 1) switch (p.src[i]) {
            '-' => chomp = .strip,
            '+' => chomp = .keep,
            '1'...'9' => explicit = p.src[i] - '0',
            else => break,
        };
        const header_rest = std.mem.trim(u8, p.src[i..le], " \t");
        if (header_rest.len > 0 and header_rest[0] != '#') return p.rawFrom(s, parent_indent, "malformed block scalar header");
        p.pos = p.lineNext(s);
        // Content indentation: explicit, or the first non-empty line's.
        var content_indent: u32 = 0;
        if (explicit) |n| {
            content_indent = parent_indent + n;
        } else {
            var j = p.pos;
            while (j < p.src.len) : (j = p.lineNext(j)) {
                const l = lineAt(p.src, j);
                if (std.mem.trim(u8, p.src[l.start..l.end], " ").len != 0) {
                    content_indent = p.indentAt(j);
                    break;
                }
            }
        }
        var out: std.ArrayList(u8) = .empty;
        var end = trimEndWs(p.src, s, le);
        var trailing_breaks: u32 = 0;
        var prev_more_indented = false;
        var have_line = false;
        if (content_indent > parent_indent) {
            while (p.pos < p.src.len) {
                const l = lineAt(p.src, p.pos);
                const line = p.src[l.start..l.end];
                const ind = p.indentAt(p.pos);
                const empty = std.mem.trim(u8, line, " ").len == 0;
                if (!empty and ind < content_indent) break;
                if (empty) {
                    trailing_breaks += 1;
                    p.pos = @intCast(l.next);
                    continue;
                }
                const text = line[content_indent..];
                const more = text.len > 0 and (text[0] == ' ' or text[0] == '\t');
                if (have_line) {
                    if (literal or more or prev_more_indented) {
                        try out.appendNTimes(p.arena, '\n', trailing_breaks + 1);
                    } else if (trailing_breaks > 0) {
                        try out.appendNTimes(p.arena, '\n', trailing_breaks);
                    } else {
                        try out.append(p.arena, ' ');
                    }
                } else {
                    try out.appendNTimes(p.arena, '\n', trailing_breaks);
                }
                trailing_breaks = 0;
                try out.appendSlice(p.arena, text);
                have_line = true;
                prev_more_indented = more;
                end = @intCast(l.end);
                p.pos = @intCast(l.next);
            }
        }
        // Trailing blank lines belong to the next entry unless kept.
        if (chomp != .keep) p.pos = if (have_line) p.lineNext(end) else p.lineNext(s);
        switch (chomp) {
            .strip => {},
            .clip => if (have_line) try out.append(p.arena, '\n'),
            .keep => if (have_line or trailing_breaks > 0) try out.appendNTimes(p.arena, '\n', trailing_breaks + @intFromBool(have_line)),
        }
        return .{ .value = .{ .string = out.items }, .src = .{ s, end }, .style = if (literal) .literal else .folded };
    }
};

const KeyTok = struct { key: [2]u32, colon: u32, quoted: bool };

/// Finds `key:` at the start of `c` (a line without its indentation): a
/// quoted key, or a plain key ending at the first `:` followed by a space
/// or the line end.
fn scanKey(c: []const u8) ?KeyTok {
    if (c.len == 0) return null;
    switch (c[0]) {
        '#', '-', '[', '{', '&', '*', '!', '|', '>', '%', '@', '`', ',', ']', '}' => {
            if (c[0] == '-' and !(c.len == 1 or c[1] == ' ' or c[1] == '\t')) {} else return null;
        },
        '?' => if (c.len == 1 or c[1] == ' ') return null,
        '"', '\'' => {
            const q = c[0];
            var i: usize = 1;
            while (i < c.len) : (i += 1) {
                if (q == '"' and c[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (c[i] == q) {
                    if (q == '\'' and i + 1 < c.len and c[i + 1] == '\'') {
                        i += 1;
                        continue;
                    }
                    break;
                }
            }
            if (i >= c.len) return null;
            var j = i + 1;
            while (j < c.len and (c[j] == ' ' or c[j] == '\t')) j += 1;
            if (j >= c.len or c[j] != ':') return null;
            if (j + 1 < c.len and !isWs(c[j + 1])) return null;
            return .{ .key = .{ 0, @intCast(i + 1) }, .colon = @intCast(j), .quoted = true };
        },
        else => {},
    }
    var i: usize = 0;
    while (i < c.len) : (i += 1) {
        if (c[i] == '#' and i > 0 and isWs(c[i - 1])) return null;
        if (c[i] == ':' and (i + 1 == c.len or isWs(c[i + 1]))) {
            const k = std.mem.trimEnd(u8, c[0..i], " \t");
            if (k.len == 0) return null;
            return .{ .key = .{ 0, @intCast(k.len) }, .colon = @intCast(i), .quoted = false };
        }
    }
    return null;
}

fn isSeqItem(c: []const u8) bool {
    return c.len > 0 and c[0] == '-' and (c.len == 1 or c[1] == ' ' or c[1] == '\t');
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// The offset of a ` #` comment between `s` and `e`, or `e`. Quotes are
/// not tracked: callers pass plain-scalar text only.
fn stripComment(src: []const u8, s: u32, e: u32) u32 {
    var i: u32 = s;
    while (std.mem.indexOfScalarPos(u8, src[0..e], i, '#')) |h| {
        if (h == s or src[h - 1] == ' ' or src[h - 1] == '\t') return @intCast(h);
        i = @intCast(h + 1);
    }
    return e;
}

fn trimEndWs(src: []const u8, s: u32, e: u32) u32 {
    var x = e;
    while (x > s and (src[x - 1] == ' ' or src[x - 1] == '\t')) x -= 1;
    return x;
}

/// The index of the bracket closing the one at `s`, skipping quotes.
fn matchBracket(src: []const u8, s: u32) ?u32 {
    var depth: u32 = 0;
    var i = s;
    var q: u8 = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (q != 0) {
            if (q == '"' and c == '\\') {
                i += 1;
            } else if (c == q) q = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => q = c,
            '[', '{' => depth += 1,
            ']', '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Folds the line breaks of a multi-line quoted scalar: one break becomes
/// a space, n breaks become n-1 newlines; indentation is dropped.
fn foldFlowLines(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    var empties: u32 = 0;
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (first) {
            try out.appendSlice(arena, std.mem.trimEnd(u8, raw_line, " \t\r"));
            first = false;
            continue;
        }
        if (line.len == 0) {
            empties += 1;
            continue;
        }
        if (empties == 0) try out.append(arena, ' ') else try out.appendNTimes(arena, '\n', empties);
        empties = 0;
        try out.appendSlice(arena, line);
    }
    if (empties > 0) try out.appendNTimes(arena, '\n', empties);
    return out.items;
}

/// Unescapes `''`. Returns `s` itself when there is nothing to unescape.
pub fn singleQuoted(arena: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "''") == null) return s;
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        out.appendAssumeCapacity(s[i]);
        if (s[i] == '\'' and i + 1 < s.len and s[i + 1] == '\'') i += 1;
    }
    return out.items;
}

/// Unescapes a double-quoted body; null on an invalid escape.
pub fn doubleQuoted(arena: Allocator, s: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\') {
            try out.append(arena, s[i]);
            continue;
        }
        i += 1;
        if (i >= s.len) return null;
        const c = s[i];
        const simple: ?u8 = switch (c) {
            '0' => 0,
            'a' => 7,
            'b' => 8,
            't', '\t' => '\t',
            'n' => '\n',
            'v' => 11,
            'f' => 12,
            'r' => '\r',
            'e' => 0x1b,
            ' ' => ' ',
            '"' => '"',
            '/' => '/',
            '\\' => '\\',
            else => null,
        };
        if (simple) |b| {
            try out.append(arena, b);
            continue;
        }
        const n: usize = switch (c) {
            'x' => 2,
            'u' => 4,
            'U' => 8,
            'N' => {
                try out.appendSlice(arena, "\u{85}");
                continue;
            },
            '_' => {
                try out.appendSlice(arena, "\u{a0}");
                continue;
            },
            'L' => {
                try out.appendSlice(arena, "\u{2028}");
                continue;
            },
            'P' => {
                try out.appendSlice(arena, "\u{2029}");
                continue;
            },
            else => return null,
        };
        if (i + 1 + n > s.len) return null;
        const cp = std.fmt.parseInt(u21, s[i + 1 .. i + 1 + n], 16) catch return null;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return null;
        try out.appendSlice(arena, buf[0..len]);
        i += n;
    }
    return out.items;
}

/// Core-schema typing of a plain scalar (§10.3.2) plus Obsidian dates.
pub fn typePlain(s: []const u8) Value {
    if (s.len == 0) return .null;
    switch (s[0]) {
        '0'...'9', '-', '+', '.', 'n', 'N', 't', 'T', 'f', 'F', '~' => {},
        else => return .{ .string = s },
    }
    const nulls = [_][]const u8{ "null", "Null", "NULL", "~" };
    for (nulls) |n| if (std.mem.eql(u8, s, n)) return .null;
    const trues = [_][]const u8{ "true", "True", "TRUE" };
    for (trues) |t| if (std.mem.eql(u8, s, t)) return .{ .bool = true };
    const falses = [_][]const u8{ "false", "False", "FALSE" };
    for (falses) |f| if (std.mem.eql(u8, s, f)) return .{ .bool = false };
    if (parseIntCore(s)) |v| return .{ .int = v };
    if (parseFloatCore(s)) |v| return .{ .float = v };
    if (parseDate(s)) |d| return .{ .date = d };
    if (parseDateTime(s)) |dt| return .{ .datetime = dt };
    return .{ .string = s };
}

fn allDigits(s: []const u8, comptime pred: fn (u8) bool) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!pred(c)) return false;
    return true;
}

fn isOct(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn parseIntCore(s: []const u8) ?i64 {
    if (std.mem.startsWith(u8, s, "0o")) {
        if (!allDigits(s[2..], isOct)) return null;
        return std.fmt.parseInt(i64, s[2..], 8) catch null;
    }
    if (std.mem.startsWith(u8, s, "0x")) {
        if (!allDigits(s[2..], std.ascii.isHex)) return null;
        return std.fmt.parseInt(i64, s[2..], 16) catch null;
    }
    const body = if (s[0] == '-' or s[0] == '+') s[1..] else s;
    if (!allDigits(body, std.ascii.isDigit)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn parseFloatCore(s: []const u8) ?f64 {
    const body = if (s[0] == '-' or s[0] == '+') s[1..] else s;
    const neg = s[0] == '-';
    const infs = [_][]const u8{ ".inf", ".Inf", ".INF" };
    for (infs) |n| if (std.mem.eql(u8, body, n)) return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    const nans = [_][]const u8{ ".nan", ".NaN", ".NAN" };
    for (nans) |n| if (std.mem.eql(u8, s, n)) return std.math.nan(f64);
    // [-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?
    var i: usize = 0;
    var mant_digits: usize = 0;
    while (i < body.len and std.ascii.isDigit(body[i])) : (i += 1) mant_digits += 1;
    if (i < body.len and body[i] == '.') {
        i += 1;
        while (i < body.len and std.ascii.isDigit(body[i])) : (i += 1) mant_digits += 1;
    }
    if (mant_digits == 0) return null;
    if (i < body.len and (body[i] == 'e' or body[i] == 'E')) {
        i += 1;
        if (i < body.len and (body[i] == '-' or body[i] == '+')) i += 1;
        const es = i;
        while (i < body.len and std.ascii.isDigit(body[i])) i += 1;
        if (i == es) return null;
    }
    if (i != body.len) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

fn num(s: []const u8) ?u32 {
    if (!allDigits(s, std.ascii.isDigit)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// `YYYY-MM-DD` with a valid month and day.
pub fn parseDate(s: []const u8) ?Date {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const y = num(s[0..4]) orelse return null;
    const m = num(s[5..7]) orelse return null;
    const d = num(s[8..10]) orelse return null;
    if (m < 1 or m > 12 or d < 1 or d > daysInMonth(@intCast(y), @intCast(m))) return null;
    return .{ .y = @intCast(y), .m = @intCast(m), .d = @intCast(d) };
}

pub fn daysInMonth(y: i32, m: u4) u5 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        else => 0,
    };
}

/// `YYYY-MM-DD[T ]hh:mm[:ss[.frac]][Z|±hh[:]mm]`.
pub fn parseDateTime(s: []const u8) ?DateTime {
    if (s.len < 16 or (s[10] != 'T' and s[10] != 't' and s[10] != ' ')) return null;
    const date = parseDate(s[0..10]) orelse return null;
    if (s[13] != ':') return null;
    const h = num(s[11..13]) orelse return null;
    const mi = num(s[14..16]) orelse return null;
    var i: usize = 16;
    var sec: u32 = 0;
    if (i < s.len and s[i] == ':') {
        if (i + 3 > s.len) return null;
        sec = num(s[i + 1 .. i + 3]) orelse return null;
        i += 3;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const fs = i;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            if (i == fs) return null;
        }
    }
    var off: ?i32 = null;
    if (i < s.len) {
        if (s[i] == 'Z' or s[i] == 'z') {
            off = 0;
            i += 1;
        } else if (s[i] == '+' or s[i] == '-') {
            const sign: i32 = if (s[i] == '-') -1 else 1;
            const rest = s[i + 1 ..];
            var oh: u32 = 0;
            var om: u32 = 0;
            if (rest.len == 5 and rest[2] == ':') {
                oh = num(rest[0..2]) orelse return null;
                om = num(rest[3..5]) orelse return null;
            } else if (rest.len == 4) {
                oh = num(rest[0..2]) orelse return null;
                om = num(rest[2..4]) orelse return null;
            } else if (rest.len == 2) {
                oh = num(rest[0..2]) orelse return null;
            } else return null;
            off = sign * @as(i32, @intCast(oh * 3600 + om * 60));
            i = s.len;
        }
    }
    if (i != s.len) return null;
    if (h > 23 or mi > 59 or sec > 60) return null;
    return .{ .date = date, .h = @intCast(h), .min = @intCast(mi), .s = @intCast(@min(sec, 59)), .utc_offset_s = off };
}
