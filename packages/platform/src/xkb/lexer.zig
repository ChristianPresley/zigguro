//! Tokens of the XKB keymap text format: identifiers, strings, key names
//! (`<AE01>`), integers and floats, and punctuation. Comments start with
//! `//` or `#` and run to the end of the line, or are `/* ... */`.

const std = @import("std");

/// Token kinds.
pub const Tag = enum {
    eof,
    ident,
    /// `text` excludes the quotes; escapes are left as written.
    string,
    /// `text` includes the angle brackets, e.g. `<AE01>`.
    keyname,
    int,
    float,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    lparen,
    rparen,
    semi,
    comma,
    equals,
    plus,
    minus,
    bang,
    tilde,
    dot,
    star,
    slash,
};

/// One token and where it starts (1-based).
pub const Token = struct {
    tag: Tag,
    text: []const u8,
    line: u32,
    col: u32,
};

/// Errors from tokenising.
pub const Error = error{Syntax};

/// Splits keymap text into tokens. A NUL byte ends the input, as the
/// Wayland protocol NUL-terminates keymaps.
pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    /// Where the last error happened.
    err_line: u32 = 0,
    err_col: u32 = 0,

    /// A lexer over `src`, cut at its first NUL.
    pub fn init(src: []const u8) Lexer {
        const end = std.mem.indexOfScalar(u8, src, 0) orelse src.len;
        return .{ .src = src[0..end] };
    }

    fn col(l: *const Lexer, at: usize) u32 {
        return @intCast(at - l.line_start + 1);
    }

    fn fail(l: *Lexer, at: usize) Error {
        l.err_line = l.line;
        l.err_col = l.col(at);
        return error.Syntax;
    }

    fn skipSpace(l: *Lexer) Error!void {
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == '\n') {
                l.pos += 1;
                l.line += 1;
                l.line_start = l.pos;
            } else if (c == ' ' or c == '\t' or c == '\r' or c == '\x0c' or c == '\x0b') {
                l.pos += 1;
            } else if (c == '#' or (c == '/' and l.peekAt(1) == '/')) {
                while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
            } else if (c == '/' and l.peekAt(1) == '*') {
                const start = l.pos;
                l.pos += 2;
                while (true) {
                    if (l.pos + 1 >= l.src.len) return l.fail(start);
                    if (l.src[l.pos] == '*' and l.src[l.pos + 1] == '/') {
                        l.pos += 2;
                        break;
                    }
                    if (l.src[l.pos] == '\n') {
                        l.line += 1;
                        l.line_start = l.pos + 1;
                    }
                    l.pos += 1;
                }
            } else break;
        }
    }

    fn peekAt(l: *const Lexer, off: usize) u8 {
        return if (l.pos + off < l.src.len) l.src[l.pos + off] else 0;
    }

    /// The next token; `.eof` at the end.
    pub fn next(l: *Lexer) Error!Token {
        try l.skipSpace();
        const start = l.pos;
        var t: Token = .{ .tag = .eof, .text = "", .line = l.line, .col = l.col(start) };
        if (start >= l.src.len) return t;
        const c = l.src[start];
        if (std.ascii.isAlphabetic(c) or c == '_') {
            l.pos += 1;
            while (l.pos < l.src.len and (std.ascii.isAlphanumeric(l.src[l.pos]) or l.src[l.pos] == '_')) l.pos += 1;
            t.tag = .ident;
        } else if (std.ascii.isDigit(c)) {
            t.tag = .int;
            if (c == '0' and (l.peekAt(1) == 'x' or l.peekAt(1) == 'X')) {
                l.pos += 2;
                while (l.pos < l.src.len and std.ascii.isHex(l.src[l.pos])) l.pos += 1;
                if (l.pos == start + 2) return l.fail(start);
            } else {
                while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '.') {
                    l.pos += 1;
                    while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
                    t.tag = .float;
                }
            }
        } else if (c == '"') {
            l.pos += 1;
            while (true) {
                if (l.pos >= l.src.len or l.src[l.pos] == '\n') return l.fail(start);
                if (l.src[l.pos] == '\\' and l.pos + 1 < l.src.len) {
                    l.pos += 2;
                    continue;
                }
                if (l.src[l.pos] == '"') break;
                l.pos += 1;
            }
            l.pos += 1;
            t.tag = .string;
            t.text = l.src[start + 1 .. l.pos - 1];
            return t;
        } else if (c == '<') {
            l.pos += 1;
            while (l.pos < l.src.len and l.src[l.pos] != '>') {
                const k = l.src[l.pos];
                if (k <= ' ' or k == '<' or k >= 0x7f) return l.fail(start);
                l.pos += 1;
            }
            if (l.pos >= l.src.len or l.pos == start + 1) return l.fail(start);
            l.pos += 1;
            t.tag = .keyname;
        } else {
            t.tag = switch (c) {
                '{' => .lbrace,
                '}' => .rbrace,
                '[' => .lbracket,
                ']' => .rbracket,
                '(' => .lparen,
                ')' => .rparen,
                ';' => .semi,
                ',' => .comma,
                '=' => .equals,
                '+' => .plus,
                '-' => .minus,
                '!' => .bang,
                '~' => .tilde,
                '.' => .dot,
                '*' => .star,
                '/' => .slash,
                else => return l.fail(start),
            };
            l.pos += 1;
        }
        t.text = l.src[start..l.pos];
        return t;
    }
};

const testing = std.testing;

test "tokens, comments and positions" {
    var l: Lexer = .init(
        \\xkb_keymap { // comment
        \\  <AE01> = 10; # another
        \\  /* block
        \\  */ type "TWO_LEVEL" { map[Shift]= Level2; };
        \\  x = 0x1f, 1.5, -2;
    ++ "\x00 ignored after NUL @@@");
    const want = [_]struct { Tag, []const u8 }{
        .{ .ident, "xkb_keymap" }, .{ .lbrace, "{" },  .{ .keyname, "<AE01>" }, .{ .equals, "=" },
        .{ .int, "10" },           .{ .semi, ";" },    .{ .ident, "type" },     .{ .string, "TWO_LEVEL" },
        .{ .lbrace, "{" },         .{ .ident, "map" }, .{ .lbracket, "[" },     .{ .ident, "Shift" },
        .{ .rbracket, "]" },       .{ .equals, "=" },  .{ .ident, "Level2" },   .{ .semi, ";" },
        .{ .rbrace, "}" },         .{ .semi, ";" },    .{ .ident, "x" },        .{ .equals, "=" },
        .{ .int, "0x1f" },         .{ .comma, "," },   .{ .float, "1.5" },      .{ .comma, "," },
        .{ .minus, "-" },          .{ .int, "2" },     .{ .semi, ";" },         .{ .eof, "" },
    };
    for (want, 0..) |w, i| {
        const t = try l.next();
        testing.expectEqual(w[0], t.tag) catch |e| {
            std.debug.print("token {d}: {s}\n", .{ i, t.text });
            return e;
        };
        try testing.expectEqualStrings(w[1], t.text);
        if (i == 2) {
            try testing.expectEqual(2, t.line);
            try testing.expectEqual(3, t.col);
        }
    }
}

test "errors carry line and column" {
    var l: Lexer = .init("a\n  \"unterminated\n");
    _ = try l.next();
    try testing.expectError(error.Syntax, l.next());
    try testing.expectEqual(2, l.err_line);
    try testing.expectEqual(3, l.err_col);
    var l2: Lexer = .init("<>");
    try testing.expectError(error.Syntax, l2.next());
    var l3: Lexer = .init("/* open");
    try testing.expectError(error.Syntax, l3.next());
}
