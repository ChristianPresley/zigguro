//! The flowchart scanner (E13.F07.S02.T01): a cursor over the source
//! with the token scanners the parser needs — words, node ids, shape
//! brackets and links. Flowchart syntax is context dependent (`o` is an
//! id or a circle end, `--` a link or the start of link text), so the
//! parser asks for the token it expects instead of reading a token
//! stream.

const std = @import("std");
const ast = @import("ast.zig");

const Span = ast.Span;

pub const Cursor = struct {
    src: []const u8,
    pos: u32 = 0,

    pub fn init(src: []const u8) Cursor {
        return .{ .src = src };
    }

    pub fn eof(c: *const Cursor) bool {
        return c.pos >= c.src.len;
    }

    /// The byte `k` ahead, or 0 past the end.
    pub fn at(c: *const Cursor, k: u32) u8 {
        const i = @as(usize, c.pos) + k;
        return if (i < c.src.len) c.src[i] else 0;
    }

    pub fn rest(c: *const Cursor) []const u8 {
        return c.src[@min(c.pos, c.src.len)..];
    }

    pub fn startsWith(c: *const Cursor, s: []const u8) bool {
        return std.mem.startsWith(u8, c.rest(), s);
    }

    /// Skips spaces, tabs and carriage returns.
    pub fn skipBlanks(c: *Cursor) void {
        while (!c.eof() and isBlank(c.src[c.pos])) c.pos += 1;
    }

    /// At the end of a statement: the end, a newline or `;`.
    pub fn atEnd(c: *const Cursor) bool {
        return c.eof() or c.src[c.pos] == '\n' or c.src[c.pos] == ';';
    }

    /// Past the end of the line (error recovery and comments).
    pub fn skipLine(c: *Cursor) void {
        while (!c.eof() and c.src[c.pos] != '\n') c.pos += 1;
        if (!c.eof()) c.pos += 1;
    }

    /// The rest of the line, without its newline.
    pub fn lineRest(c: *const Cursor) []const u8 {
        const r = c.rest();
        return r[0 .. std.mem.indexOfScalar(u8, r, '\n') orelse r.len];
    }

    /// A word of letters, digits, `_` and `-` (keywords, directions,
    /// class names), or null.
    pub fn word(c: *Cursor) ?[]const u8 {
        const s = c.pos;
        while (!c.eof() and (std.ascii.isAlphanumeric(c.src[c.pos]) or c.src[c.pos] == '_' or c.src[c.pos] == '-')) c.pos += 1;
        return if (c.pos == s) null else c.src[s..c.pos];
    }

    /// The word at the cursor without moving.
    pub fn peekWord(c: *const Cursor) []const u8 {
        var t = c.*;
        return t.word() orelse "";
    }

    /// A node id: letters, digits, `_`, non-ASCII bytes, and `-` or `.`
    /// inside the id (not starting a link).
    pub fn ident(c: *Cursor) ?[]const u8 {
        const s = c.pos;
        while (!c.eof()) {
            const b = c.src[c.pos];
            if (isIdByte(b)) {
                c.pos += 1;
            } else if ((b == '-' or b == '.') and c.pos > s and isIdByte(c.at(1)) and !(b == '-' and isEndMark(c.at(1)) and !isIdByte(c.at(2)))) {
                c.pos += 1;
            } else break;
        }
        return if (c.pos == s) null else c.src[s..c.pos];
    }
};

pub fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r';
}

pub fn isIdByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

fn isEndMark(b: u8) bool {
    return b == 'o' or b == 'x';
}

// -- shapes --------------------------------------------------------------------

pub const Close = struct { text: []const u8, shape: ast.Shape };

/// A shape's opening bracket and the closings it accepts (two for the
/// slanted shapes: `[/…/]` is a parallelogram, `[/…\]` a trapezoid).
pub const Open = struct { text: []const u8, closes: []const Close };

const opens = [_]Open{
    .{ .text = "(((", .closes = &.{.{ .text = ")))", .shape = .double_circle }} },
    .{ .text = "((", .closes = &.{.{ .text = "))", .shape = .circle }} },
    .{ .text = "([", .closes = &.{.{ .text = "])", .shape = .stadium }} },
    .{ .text = "(", .closes = &.{.{ .text = ")", .shape = .round }} },
    .{ .text = "[[", .closes = &.{.{ .text = "]]", .shape = .subroutine }} },
    .{ .text = "[(", .closes = &.{.{ .text = ")]", .shape = .cylinder }} },
    .{ .text = "[/", .closes = &.{ .{ .text = "/]", .shape = .parallelogram }, .{ .text = "\\]", .shape = .trapezoid } } },
    .{ .text = "[\\", .closes = &.{ .{ .text = "\\]", .shape = .parallelogram_alt }, .{ .text = "/]", .shape = .trapezoid_alt } } },
    .{ .text = "[", .closes = &.{.{ .text = "]", .shape = .rect }} },
    .{ .text = ">", .closes = &.{.{ .text = "]", .shape = .asymmetric }} },
    .{ .text = "{{", .closes = &.{.{ .text = "}}", .shape = .hexagon }} },
    .{ .text = "{", .closes = &.{.{ .text = "}", .shape = .rhombus }} },
};

/// The shape bracket at the cursor (consumed), or null.
pub fn shapeOpen(c: *Cursor) ?Open {
    for (opens) |o| if (c.startsWith(o.text)) {
        c.pos += @intCast(o.text.len);
        return o;
    };
    return null;
}

pub const Bracketed = struct {
    /// The raw label text (quotes kept, for `parser.label`).
    text: Span,
    shape: ast.Shape,
};

pub const ScanError = struct { span: Span, message: []const u8 };

/// Reads a label up to one of `o`'s closings (consumed). A quoted label
/// may hold the closing characters; a Markdown string (`"` + backtick)
/// may span lines.
pub fn bracketBody(c: *Cursor, o: Open) union(enum) { ok: Bracketed, err: ScanError } {
    const open_at = c.pos - @as(u32, @intCast(o.text.len));
    const start = c.pos;
    c.skipBlanks();
    if (c.at(0) == '"') {
        const md = c.at(1) == '`';
        var i = c.pos + 1;
        while (i < c.src.len and c.src[i] != '"' and (md or c.src[i] != '\n')) i += 1;
        if (i >= c.src.len or c.src[i] != '"') return .{ .err = .{ .span = .{ .start = c.pos, .end = i }, .message = "unterminated quoted label" } };
        c.pos = i + 1;
        const end = c.pos;
        c.skipBlanks();
        for (o.closes) |cl| if (c.startsWith(cl.text)) {
            c.pos += @intCast(cl.text.len);
            return .{ .ok = .{ .text = .{ .start = start, .end = end }, .shape = cl.shape } };
        };
        return .{ .err = .{ .span = .{ .start = open_at, .end = c.pos }, .message = "expected the shape's closing bracket after the quoted label" } };
    }
    c.pos = start;
    while (!c.eof() and c.src[c.pos] != '\n') : (c.pos += 1) {
        for (o.closes) |cl| if (c.startsWith(cl.text)) {
            const end = c.pos;
            c.pos += @intCast(cl.text.len);
            return .{ .ok = .{ .text = .{ .start = start, .end = end }, .shape = cl.shape } };
        };
    }
    return .{ .err = .{ .span = .{ .start = open_at, .end = c.pos }, .message = "unclosed shape bracket" } };
}

// -- links ---------------------------------------------------------------------

pub const Link = struct {
    style: ast.EdgeStyle,
    head: ast.EdgeEnd,
    tail: ast.EdgeEnd,
    min_len: u8,
    /// Raw label text: `-- text -->` or `-->|text|`.
    label: ?Span,
    span: Span,
};

pub const LinkScan = union(enum) { none, link: Link, err: ScanError };

/// The link at the cursor (consumed; its `|label|` too), or `.none`
/// with the cursor unmoved.
pub fn scanLink(c: *Cursor) LinkScan {
    const start = c.pos;
    var l: Link = .{ .style = .solid, .head = .none, .tail = .none, .min_len = 0, .label = null, .span = undefined };
    // A tail end: `<-->`, `o--o`, `x==x`.
    const b0 = c.at(0);
    if ((b0 == '<' or isEndMark(b0)) and isLinkPair(c.at(1), c.at(2))) {
        l.tail = if (b0 == '<') .arrow else if (b0 == 'o') .circle else .cross;
        c.pos += 1;
    }
    switch (c.at(0)) {
        '~' => {
            const n = run(c, '~');
            if (n < 3 or l.tail != .none) return reset(c, start);
            l.style = .invisible;
            l.min_len = sat(n - 3);
        },
        '-', '=' => |ch| {
            l.style = if (ch == '=') .thick else .solid;
            if (ch == '-' and c.at(1) == '.') {
                l.style = .dotted;
                c.pos += 1;
                const dots = run(c, '.');
                if (c.at(0) == '-') {
                    c.pos += 1;
                    l.min_len = sat(dots - 1);
                    l.head = head(c);
                } else {
                    // `-. text .->`
                    const r = linkText(c, start, .dotted, &l);
                    if (r != .none) return r;
                }
            } else {
                const n = run(c, ch);
                if (n < 2) return reset(c, start);
                l.head = head(c);
                if (l.head != .none) {
                    l.min_len = sat(n - 2);
                } else if (n >= 3) {
                    l.min_len = sat(n - 3);
                } else {
                    // `-- text -->`, `== text ==>`
                    const r = linkText(c, start, l.style, &l);
                    if (r != .none) return r;
                }
            }
        },
        else => return reset(c, start),
    }
    if (l.tail != .none and l.head == .none) return .{ .err = .{ .span = .{ .start = start, .end = c.pos }, .message = "a link with an end at its start needs one at its end too" } };
    l.span = .{ .start = start, .end = c.pos };
    // `-->|label|`
    var t = c.*;
    t.skipBlanks();
    if (t.at(0) == '|') {
        const ls = t.pos + 1;
        var i = ls;
        while (i < c.src.len and c.src[i] != '|' and c.src[i] != '\n') i += 1;
        if (i >= c.src.len or c.src[i] != '|') return .{ .err = .{ .span = .{ .start = t.pos, .end = i }, .message = "unclosed '|' link label" } };
        l.label = .{ .start = ls, .end = i };
        c.pos = i + 1;
    }
    return .{ .link = l };
}

fn reset(c: *Cursor, start: u32) LinkScan {
    c.pos = start;
    return .none;
}

fn isLinkPair(a: u8, b: u8) bool {
    return (a == '-' and (b == '-' or b == '.')) or (a == '=' and b == '=');
}

fn run(c: *Cursor, ch: u8) u32 {
    const s = c.pos;
    while (!c.eof() and c.src[c.pos] == ch) c.pos += 1;
    return c.pos - s;
}

fn sat(n: u32) u8 {
    return @intCast(@min(n, 255));
}

/// An arrow, circle or cross end (consumed), or `.none`. `o` and `x`
/// count only when no id continues after them (`--oB` is ambiguous;
/// write `--o B`).
fn head(c: *Cursor) ast.EdgeEnd {
    const b = c.at(0);
    if (b == '>') {
        c.pos += 1;
        return .arrow;
    }
    if (isEndMark(b) and !isIdByte(c.at(1))) {
        c.pos += 1;
        return if (b == 'o') .circle else .cross;
    }
    return .none;
}

/// The text of `-- text -->` (the cursor after the opening `--`, `==` or
/// `-.`) up to its closing link, which sets `l`'s head and length.
fn linkText(c: *Cursor, start: u32, style: ast.EdgeStyle, l: *Link) LinkScan {
    const text_start = c.pos;
    var i = c.pos;
    while (i < c.src.len and c.src[i] != '\n') : (i += 1) {
        var t: Cursor = .{ .src = c.src, .pos = i };
        switch (style) {
            .dotted => {
                if (c.src[i] != '.') continue;
                const dots = run(&t, '.');
                if (t.at(0) != '-') continue;
                t.pos += 1;
                l.min_len = sat(dots - 1);
                l.head = head(&t);
            },
            .solid, .thick => {
                const ch: u8 = if (style == .thick) '=' else '-';
                if (c.src[i] != ch) continue;
                const n = run(&t, ch);
                if (n < 2) continue;
                l.head = head(&t);
                if (l.head == .none and n < 3) continue;
                l.min_len = sat(if (l.head != .none) n - 2 else n - 3);
            },
            .invisible => unreachable,
        }
        l.label = .{ .start = text_start, .end = i };
        c.pos = t.pos;
        return .none;
    }
    return .{ .err = .{ .span = .{ .start = start, .end = i }, .message = switch (style) {
        .dotted => "link text needs a closing '.->' or '.-'",
        .thick => "link text needs a closing '==>' or '==='",
        else => "link text needs a closing '-->' or '---'",
    } } };
}

test {
    std.testing.refAllDecls(@This());
}
