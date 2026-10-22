//! Vim patterns (pattern.txt) in zg_regex syntax, for `/`, `?`, `:s` and
//! `:g`, and Vim `:s` replacements as replace-engine templates.
//!
//! Covers the magic levels (`\v`, `\m`, `\M`, `\V`), `\c`/`\C`, groups,
//! alternation, the multis (`*`, `\+`, `\=`, `\?`, `\{n,m}`, lazy `\{-}`),
//! word bounds, character classes (`\s`, `\d`, `\w`, `\a`, `\l`, `\u`, `\x`,
//! `\o`, `\h` and their `\_` forms), collections and character codes.
//! Vim's classes and negated collections never match a line break unless
//! written with `\_`, so they become explicit ASCII sets here. Look-around
//! (`\@`), `\zs`/`\ze`, back references and the position atoms (`\%23l`,
//! `\%V`) have no zg_regex equivalent and are reported with their span.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TranslateError = error{ Unsupported, Syntax } || Allocator.Error;

/// Where and why a pattern could not be translated.
pub const Diag = struct {
    start: usize = 0,
    end: usize = 0,
    msg: []const u8 = "",
};

pub const Flags = struct {
    ignorecase: bool = false,
    smartcase: bool = false,
    diag: ?*Diag = null,
};

const Magic = enum { very, magic, nomagic, very_nomagic };

/// Translates Vim pattern `vim_pat` to zg_regex syntax (caller frees).
pub fn translatePattern(gpa: Allocator, vim_pat: []const u8, flags: Flags) TranslateError![]u8 {
    var t: Translator = .{ .gpa = gpa, .src = vim_pat, .diag = flags.diag };
    defer t.out.deinit(gpa);
    try t.run();
    const insensitive = t.force_case orelse (flags.ignorecase and !(flags.smartcase and hasUpper(vim_pat)));
    var res: std.ArrayList(u8) = .empty;
    errdefer res.deinit(gpa);
    if (insensitive) try res.appendSlice(gpa, "(?i)");
    try res.appendSlice(gpa, t.out.items);
    return res.toOwnedSlice(gpa);
}

/// Whether the pattern has an upper-case letter outside escapes (for
/// 'smartcase').
fn hasUpper(p: []const u8) bool {
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] == '\\') {
            i += 1;
            continue;
        }
        if (std.ascii.isUpper(p[i])) return true;
    }
    return false;
}

const Translator = struct {
    gpa: Allocator,
    src: []const u8,
    diag: ?*Diag,
    out: std.ArrayList(u8) = .empty,
    i: usize = 0,
    magic: Magic = .magic,
    force_case: ?bool = null,
    /// Something before can take a multi (`*`, `\+`).
    can_repeat: bool = false,
    /// The last thing emitted was a multi (a second one is an error).
    after_multi: bool = false,
    depth: u32 = 0,

    fn fail(t: *Translator, err: TranslateError, start: usize, msg: []const u8) TranslateError {
        if (t.diag) |d| d.* = .{ .start = start, .end = @min(t.i, t.src.len), .msg = msg };
        return err;
    }

    fn emit(t: *Translator, s: []const u8) !void {
        try t.out.appendSlice(t.gpa, s);
    }

    /// Characters that are special without a backslash at this level.
    fn metaBare(t: *const Translator, c: u8) bool {
        return switch (t.magic) {
            .very => std.mem.indexOfScalar(u8, "()|+?={}@<>%.*[~^$&", c) != null,
            .magic => std.mem.indexOfScalar(u8, ".*[~^$", c) != null,
            .nomagic, .very_nomagic => c == '^' or c == '$',
        };
    }

    fn run(t: *Translator) TranslateError!void {
        var branch_start = true;
        while (t.i < t.src.len) {
            const start = t.i;
            var c = t.src[t.i];
            var meta: bool = undefined;
            if (c == '\\') {
                if (t.i + 1 >= t.src.len) return t.fail(error.Syntax, start, "trailing backslash");
                c = t.src[t.i + 1];
                t.i += 2;
                meta = if (std.ascii.isAlphanumeric(c) or c == '_') true else !t.metaBare(c);
            } else {
                t.i += 1;
                meta = !std.ascii.isAlphanumeric(c) and c != '_' and t.metaBare(c);
            }
            const was_start = branch_start;
            branch_start = false;
            if (!meta) {
                try t.literal(c);
                continue;
            }
            switch (c) {
                '(' => {
                    try t.emit("(");
                    t.depth += 1;
                    t.can_repeat = false;
                    branch_start = true;
                    t.after_multi = false;
                },
                ')' => {
                    if (t.depth == 0) return t.fail(error.Syntax, start, "unmatched \\)");
                    t.depth -= 1;
                    try t.emit(")");
                    t.can_repeat = true;
                    t.after_multi = false;
                },
                '|' => {
                    try t.emit("|");
                    t.can_repeat = false;
                    branch_start = true;
                    t.after_multi = false;
                },
                '&' => return t.fail(error.Unsupported, start, "\\& (concat) is not supported"),
                '*', '+', '=', '?' => {
                    if (!t.can_repeat) {
                        if (t.after_multi) return t.fail(error.Syntax, start, "nested multi");
                        try t.literal(c);
                        continue;
                    }
                    try t.emit(switch (c) {
                        '*' => "*",
                        '+' => "+",
                        else => "?",
                    });
                    t.multiDone();
                },
                '{' => try t.brace(start),
                '@' => return t.fail(error.Unsupported, t.lookEnd(start), "look-around (\\@) is not supported"),
                '<' => try t.atom("\\b{start}", false),
                '>' => try t.atom("\\b{end}", false),
                '%' => try t.percent(start),
                '.' => try t.atom(".", true),
                '[' => try t.collection(start, false),
                '~' => return t.fail(error.Unsupported, start, "~ (last substitute string) is not supported"),
                '^' => {
                    if (was_start) try t.atom("^", false) else try t.literal('^');
                },
                '$' => {
                    if (t.atBranchEnd()) try t.atom("$", false) else try t.literal('$');
                },
                '_' => try t.underscore(start),
                'z' => {
                    if (t.i < t.src.len) t.i += 1;
                    return t.fail(error.Unsupported, start, "\\z atoms (\\zs, \\ze) are not supported");
                },
                '1'...'9' => return t.fail(error.Unsupported, start, "back references are not supported"),
                'c' => t.force_case = true,
                'C' => t.force_case = false,
                'v' => t.magic = .very,
                'm' => t.magic = .magic,
                'M' => t.magic = .nomagic,
                'V' => t.magic = .very_nomagic,
                'n' => try t.atom("\\n", true),
                't' => try t.atom("\\t", true),
                'e' => try t.atom("\\x1B", true),
                'r' => try t.atom("\\r", true),
                'b' => try t.atom("\\x08", true),
                else => {
                    // An escaped character with no meaning stands for itself.
                    if (!std.ascii.isAlphanumeric(c)) {
                        try t.literal(c);
                        continue;
                    }
                    const cls = classBody(c) orelse return t.fail(error.Unsupported, start, "unknown escape");
                    try t.class(cls, false);
                },
            }
            switch (c) {
                'c', 'C', 'v', 'm', 'M', 'V' => branch_start = was_start,
                else => {},
            }
        }
        if (t.depth != 0) return t.fail(error.Syntax, t.src.len, "unmatched \\(");
    }

    fn multiDone(t: *Translator) void {
        t.can_repeat = false;
        t.after_multi = true;
    }

    fn atom(t: *Translator, s: []const u8, repeatable: bool) !void {
        try t.emit(s);
        t.can_repeat = repeatable;
        t.after_multi = false;
    }

    fn literal(t: *Translator, c: u8) !void {
        if (std.mem.indexOfScalar(u8, "\\.+*?()|[]{}^$", c) != null) {
            try t.out.append(t.gpa, '\\');
        }
        try t.out.append(t.gpa, c);
        t.can_repeat = true;
        t.after_multi = false;
    }

    /// `$` is an anchor only before `\|`, `\)`, a newline or the end.
    fn atBranchEnd(t: *const Translator) bool {
        const rest = t.src[t.i..];
        if (rest.len == 0) return true;
        if (t.magic == .very) return rest[0] == '|' or rest[0] == ')';
        return std.mem.startsWith(u8, rest, "\\|") or std.mem.startsWith(u8, rest, "\\)") or std.mem.startsWith(u8, rest, "\\n");
    }

    /// The end of a `\@` atom (`\@=`, `\@!`, `\@<=`, `\@<!`, `\@>`, with an
    /// optional count) for the error span.
    fn lookEnd(t: *Translator, start: usize) usize {
        while (t.i < t.src.len and std.ascii.isDigit(t.src[t.i])) t.i += 1;
        if (t.i < t.src.len and t.src[t.i] == '<') t.i += 1;
        if (t.i < t.src.len and std.mem.indexOfScalar(u8, "=!>", t.src[t.i]) != null) t.i += 1;
        return start;
    }

    /// `\{n,m}`, `\{-n,m}` and friends.
    fn brace(t: *Translator, start: usize) !void {
        const close = std.mem.indexOfScalarPos(u8, t.src, t.i, '}') orelse return t.fail(error.Syntax, start, "missing } after \\{");
        var body = t.src[t.i..close];
        t.i = close + 1;
        if (std.mem.endsWith(u8, body, "\\")) body = body[0 .. body.len - 1];
        var lazy = false;
        if (body.len > 0 and body[0] == '-') {
            lazy = true;
            body = body[1..];
        }
        for (body) |b| if (!std.ascii.isDigit(b) and b != ',') return t.fail(error.Syntax, start, "bad \\{} count");
        if (!t.can_repeat) {
            if (t.after_multi) return t.fail(error.Syntax, start, "nested multi");
            return t.fail(error.Syntax, start, "\\{ follows nothing");
        }
        const comma = std.mem.indexOfScalar(u8, body, ',');
        if (body.len == 0 or (comma != null and body.len == 1)) {
            try t.emit("*");
        } else if (comma) |cm| {
            const lo = body[0..cm];
            const hi = body[cm + 1 ..];
            try t.out.print(t.gpa, "{{{s},{s}}}", .{ if (lo.len == 0) "0" else lo, hi });
        } else try t.out.print(t.gpa, "{{{s}}}", .{body});
        if (lazy) try t.emit("?");
        t.multiDone();
    }

    /// `\%(`, `\%d123`, `\%x2a`, `\%u20AC`, `\%U...`, `\%o40`, `\%^`, `\%$`.
    fn percent(t: *Translator, start: usize) !void {
        if (t.i >= t.src.len) return t.fail(error.Syntax, start, "trailing \\%");
        const c = t.src[t.i];
        t.i += 1;
        switch (c) {
            '(' => {
                try t.emit("(?:");
                t.depth += 1;
                t.can_repeat = false;
                t.after_multi = false;
            },
            '^' => try t.atom("\\A", false),
            '$' => try t.atom("\\z", false),
            'd', 'x', 'u', 'U', 'o' => {
                const base: u8 = switch (c) {
                    'd' => 10,
                    'o' => 8,
                    else => 16,
                };
                const max_digits: usize = switch (c) {
                    'x' => 2,
                    'u' => 4,
                    'U' => 8,
                    else => 10,
                };
                const s = t.i;
                while (t.i < t.src.len and t.i - s < max_digits and std.fmt.charToDigit(t.src[t.i], base) != error.InvalidCharacter) t.i += 1;
                if (t.i == s) return t.fail(error.Syntax, start, "missing character code");
                const v = std.fmt.parseInt(u21, t.src[s..t.i], base) catch return t.fail(error.Syntax, start, "bad character code");
                try t.out.print(t.gpa, "\\x{{{X}}}", .{v});
                t.can_repeat = true;
                t.after_multi = false;
            },
            else => {
                // \%23l, \%V, \%#, \%[...] and the rest.
                while (t.i < t.src.len and (std.ascii.isDigit(t.src[t.i]) or t.src[t.i] == '<' or t.src[t.i] == '>')) t.i += 1;
                if (std.ascii.isDigit(c) and t.i < t.src.len) t.i += 1;
                return t.fail(error.Unsupported, start, "this \\% atom is not supported");
            },
        }
    }

    /// `\_x`: the class `x` plus a line break, `\_.`, `\_[`, `\_^`, `\_$`.
    fn underscore(t: *Translator, start: usize) !void {
        if (t.i >= t.src.len) return t.fail(error.Syntax, start, "trailing \\_");
        const c = t.src[t.i];
        t.i += 1;
        switch (c) {
            '.' => try t.atom("(?s:.)", true),
            '^' => try t.atom("^", false),
            '$' => try t.atom("$", false),
            '[' => try t.collection(start, true),
            else => {
                const cls = classBody(c) orelse return t.fail(error.Unsupported, start, "unknown \\_ class");
                try t.class(cls, true);
            },
        }
    }

    /// A class from `classBody`: `[^...]` sets never take a line break
    /// unless `nl` (a `\_` class) adds one.
    fn class(t: *Translator, cls: Class, nl: bool) !void {
        try t.emit(if (cls.negated) "[^" else "[");
        try t.emit(cls.body);
        if (cls.negated and !nl) try t.emit("\\n");
        if (!cls.negated and nl) try t.emit("\\n");
        try t.emit("]");
        t.can_repeat = true;
        t.after_multi = false;
    }

    /// `[...]`; a `[` without its `]` is a literal.
    fn collection(t: *Translator, start: usize, nl: bool) !void {
        var j = t.i;
        var negated = false;
        if (j < t.src.len and t.src[j] == '^') {
            negated = true;
            j += 1;
        }
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(t.gpa);
        var first = true;
        var closed = false;
        while (j < t.src.len) {
            const c = t.src[j];
            if (c == ']' and !first) {
                closed = true;
                j += 1;
                break;
            }
            first = false;
            if (c == '[' and j + 1 < t.src.len and (t.src[j + 1] == ':' or t.src[j + 1] == '=' or t.src[j + 1] == '.')) {
                const kind = t.src[j + 1];
                const end = std.mem.indexOfPos(u8, t.src, j + 2, &.{ kind, ']' }) orelse {
                    try body.appendSlice(t.gpa, "\\[");
                    j += 1;
                    continue;
                };
                if (kind != ':') {
                    t.i = end + 2;
                    return t.fail(error.Unsupported, j, "equivalence and collating classes are not supported");
                }
                try body.appendSlice(t.gpa, t.src[j .. end + 2]);
                j = end + 2;
                continue;
            }
            if (c == '\\' and j + 1 < t.src.len) {
                const e = t.src[j + 1];
                j += 2;
                switch (e) {
                    'e' => try body.appendSlice(t.gpa, "\\x1B"),
                    't' => try body.appendSlice(t.gpa, "\\t"),
                    'r' => try body.appendSlice(t.gpa, "\\r"),
                    'n' => try body.appendSlice(t.gpa, "\\n"),
                    'b' => try body.appendSlice(t.gpa, "\\x08"),
                    '\\', ']', '^', '-' => {
                        try body.append(t.gpa, '\\');
                        try body.append(t.gpa, e);
                    },
                    'd', 'o', 'x', 'u', 'U' => {
                        const base: u8 = switch (e) {
                            'd' => 10,
                            'o' => 8,
                            else => 16,
                        };
                        const s = j;
                        while (j < t.src.len and j - s < 8 and std.fmt.charToDigit(t.src[j], base) != error.InvalidCharacter) j += 1;
                        const v = std.fmt.parseInt(u21, t.src[s..j], base) catch {
                            t.i = j;
                            return t.fail(error.Syntax, start, "bad character code");
                        };
                        try body.print(t.gpa, "\\x{{{X}}}", .{v});
                    },
                    else => {
                        try body.appendSlice(t.gpa, "\\\\");
                        try escapeInClass(&body, t.gpa, e);
                    },
                }
                continue;
            }
            if (c == '-' and body.items.len > 0 and j + 1 < t.src.len and t.src[j + 1] != ']') {
                try body.append(t.gpa, '-');
            } else try escapeInClass(&body, t.gpa, c);
            j += 1;
        }
        if (!closed) {
            if (nl) return t.fail(error.Syntax, start, "missing ] after \\_[");
            try t.literal('[');
            return;
        }
        t.i = j;
        try t.emit(if (negated) "[^" else "[");
        try t.emit(body.items);
        if (negated != nl) try t.emit("\\n");
        try t.emit("]");
        t.can_repeat = true;
        t.after_multi = false;
    }
};

fn escapeInClass(body: *std.ArrayList(u8), gpa: Allocator, c: u8) !void {
    if (std.mem.indexOfScalar(u8, "\\[]^-&~", c) != null) try body.append(gpa, '\\');
    try body.append(gpa, c);
}

const Class = struct { body: []const u8, negated: bool };

/// The ASCII set of Vim class letter `c` (`\s`, `\d`, ...).
fn classBody(c: u8) ?Class {
    const pos: []const u8 = switch (std.ascii.toLower(c)) {
        's' => " \\t",
        'd' => "0-9",
        'w' => "0-9A-Za-z_",
        'a' => "A-Za-z",
        'l' => "a-z",
        'u' => "A-Z",
        'x' => "0-9A-Fa-f",
        'o' => "0-7",
        'h' => "A-Za-z_",
        'i', 'k' => "0-9A-Za-z_\\x{C0}-\\x{10FFFF}",
        else => return null,
    };
    // \l and \u are not negations of each other: \L and \U are.
    return .{ .body = pos, .negated = std.ascii.isUpper(c) };
}

/// Translates a Vim `:s` replacement (`&`, `\0`-`\9`, `\r`/`\n` for a line
/// break, `\u`/`\l`/`\U`/`\L`/`\E`, `~` for the previous replacement) to a
/// replace-engine template (caller frees).
pub fn translateReplacement(gpa: Allocator, rep: []const u8, previous: []const u8, diag: ?*Diag) TranslateError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        const c = rep[i];
        switch (c) {
            '&' => try out.appendSlice(gpa, "$&"),
            '$' => try out.appendSlice(gpa, "$$"),
            '~' => try out.appendSlice(gpa, previous),
            '\\' => {
                if (i + 1 >= rep.len) {
                    try out.appendSlice(gpa, "\\\\");
                    continue;
                }
                i += 1;
                const e = rep[i];
                switch (e) {
                    '0'...'9' => try out.print(gpa, "${{{c}}}", .{e}),
                    'r', 'n' => try out.appendSlice(gpa, "\\n"),
                    't' => try out.appendSlice(gpa, "\\t"),
                    'u', 'l', 'U', 'L', 'E' => {
                        try out.append(gpa, '\\');
                        try out.append(gpa, e);
                    },
                    'e' => try out.appendSlice(gpa, "\\E"),
                    '\\' => try out.appendSlice(gpa, "\\\\"),
                    '&', '~' => try out.append(gpa, e),
                    '=' => {
                        if (diag) |d| d.* = .{ .start = i - 1, .end = i + 1, .msg = "\\= expressions are not supported" };
                        return error.Unsupported;
                    },
                    else => try out.append(gpa, e),
                }
            },
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

// -- tests ---------------------------------------------------------------------

const Case = struct { vim: []const u8, re: []const u8 };

test "vim: pattern translation table" {
    const gpa = std.testing.allocator;
    const cases = [_]Case{
        .{ .vim = "foo", .re = "foo" },
        .{ .vim = "a.c", .re = "a.c" },
        .{ .vim = "a*", .re = "a*" },
        .{ .vim = "*a", .re = "\\*a" },
        .{ .vim = "a\\+", .re = "a+" },
        .{ .vim = "a\\=", .re = "a?" },
        .{ .vim = "a\\?", .re = "a?" },
        .{ .vim = "a+b", .re = "a\\+b" },
        .{ .vim = "a?b", .re = "a\\?b" },
        .{ .vim = "(x)", .re = "\\(x\\)" },
        .{ .vim = "a|b", .re = "a\\|b" },
        .{ .vim = "a{2}", .re = "a\\{2\\}" },
        .{ .vim = "\\(ab\\)\\+", .re = "(ab)+" },
        .{ .vim = "\\%(ab\\)", .re = "(?:ab)" },
        .{ .vim = "a\\|b", .re = "a|b" },
        .{ .vim = "a\\{2,3}", .re = "a{2,3}" },
        .{ .vim = "a\\{2}", .re = "a{2}" },
        .{ .vim = "a\\{,3}", .re = "a{0,3}" },
        .{ .vim = "a\\{2,}", .re = "a{2,}" },
        .{ .vim = "a\\{}", .re = "a*" },
        .{ .vim = "a\\{-}", .re = "a*?" },
        .{ .vim = "a\\{-1,}", .re = "a{1,}?" },
        .{ .vim = "a\\{2,3\\}", .re = "a{2,3}" },
        .{ .vim = "\\<word\\>", .re = "\\b{start}word\\b{end}" },
        .{ .vim = "^foo$", .re = "^foo$" },
        .{ .vim = "a^b$c", .re = "a\\^b\\$c" },
        .{ .vim = "\\(^a\\|b$\\)", .re = "(^a|b$)" },
        .{ .vim = "\\s\\+", .re = "[ \\t]+" },
        .{ .vim = "\\S", .re = "[^ \\t\\n]" },
        .{ .vim = "\\d\\D", .re = "[0-9][^0-9\\n]" },
        .{ .vim = "\\w", .re = "[0-9A-Za-z_]" },
        .{ .vim = "\\a\\l\\u", .re = "[A-Za-z][a-z][A-Z]" },
        .{ .vim = "\\x\\o\\h", .re = "[0-9A-Fa-f][0-7][A-Za-z_]" },
        .{ .vim = "\\_s", .re = "[ \\t\\n]" },
        .{ .vim = "a\\_.b", .re = "a(?s:.)b" },
        .{ .vim = "\\n\\t\\e", .re = "\\n\\t\\x1B" },
        .{ .vim = "[abc]", .re = "[abc]" },
        .{ .vim = "[^abc]", .re = "[^abc\\n]" },
        .{ .vim = "\\_[^abc]", .re = "[^abc]" },
        .{ .vim = "\\_[abc]", .re = "[abc\\n]" },
        .{ .vim = "[a-z0-9]", .re = "[a-z0-9]" },
        .{ .vim = "[]a]", .re = "[\\]a]" },
        .{ .vim = "[-a]", .re = "[\\-a]" },
        .{ .vim = "[[:alpha:]]", .re = "[[:alpha:]]" },
        .{ .vim = "[\\t\\]]", .re = "[\\t\\]]" },
        .{ .vim = "a[b", .re = "a\\[b" },
        .{ .vim = "\\.\\*\\[\\/\\\\", .re = "\\.\\*\\[/\\\\" },
        .{ .vim = "\\%d65\\%x42\\%u0043", .re = "\\x{41}\\x{42}\\x{43}" },
        .{ .vim = "\\%^a\\%$", .re = "\\Aa\\z" },
        .{ .vim = "\\v(a|b)+c{2}", .re = "(a|b)+c{2}" },
        .{ .vim = "\\v<w>", .re = "\\b{start}w\\b{end}" },
        .{ .vim = "\\v\\(x\\)", .re = "\\(x\\)" },
        .{ .vim = "\\Ma*\\*", .re = "a\\**" },
        .{ .vim = "\\Va.b*", .re = "a\\.b\\*" },
        .{ .vim = "\\V\\.", .re = "." },
        .{ .vim = "x\\cy", .re = "(?i)xy" },
        .{ .vim = "a.b c", .re = "a.b c" },
        .{ .vim = "a$\\|b", .re = "a$|b" },
    };
    var failed = false;
    for (cases) |cs| {
        const got = translatePattern(gpa, cs.vim, .{}) catch |e| {
            std.debug.print("pattern {s}: {t}\n", .{ cs.vim, e });
            failed = true;
            continue;
        };
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, cs.re)) {
            std.debug.print("pattern {s}: want {s} got {s}\n", .{ cs.vim, cs.re, got });
            failed = true;
        }
    }
    try std.testing.expect(!failed);

    // Case options.
    const ci = try translatePattern(gpa, "foo", .{ .ignorecase = true });
    defer gpa.free(ci);
    try std.testing.expectEqualStrings("(?i)foo", ci);
    const sc = try translatePattern(gpa, "Foo", .{ .ignorecase = true, .smartcase = true });
    defer gpa.free(sc);
    try std.testing.expectEqualStrings("Foo", sc);
    const sc2 = try translatePattern(gpa, "\\Sfoo", .{ .ignorecase = true, .smartcase = true });
    defer gpa.free(sc2);
    try std.testing.expectEqualStrings("(?i)[^ \\t\\n]foo", sc2);
    const cs_ = try translatePattern(gpa, "\\Cfoo", .{ .ignorecase = true });
    defer gpa.free(cs_);
    try std.testing.expectEqualStrings("foo", cs_);

    // Unsupported atoms and syntax errors report their span.
    const bad = [_]struct { vim: []const u8, err: TranslateError, start: usize, end: usize }{
        .{ .vim = "foo\\zsbar", .err = error.Unsupported, .start = 3, .end = 6 },
        .{ .vim = "a\\zeb", .err = error.Unsupported, .start = 1, .end = 4 },
        .{ .vim = "\\(a\\)\\@<=b", .err = error.Unsupported, .start = 5, .end = 9 },
        .{ .vim = "a\\@=", .err = error.Unsupported, .start = 1, .end = 4 },
        .{ .vim = "x\\@!y", .err = error.Unsupported, .start = 1, .end = 4 },
        .{ .vim = "\\(a\\)\\1", .err = error.Unsupported, .start = 5, .end = 7 },
        .{ .vim = "\\%23l", .err = error.Unsupported, .start = 0, .end = 5 },
        .{ .vim = "\\%V", .err = error.Unsupported, .start = 0, .end = 3 },
        .{ .vim = "a~", .err = error.Unsupported, .start = 1, .end = 2 },
        .{ .vim = "a\\&b", .err = error.Unsupported, .start = 1, .end = 3 },
        .{ .vim = "\\(a", .err = error.Syntax, .start = 3, .end = 3 },
        .{ .vim = "a\\)", .err = error.Syntax, .start = 1, .end = 3 },
        .{ .vim = "a\\{x}", .err = error.Syntax, .start = 1, .end = 5 },
        .{ .vim = "a**", .err = error.Syntax, .start = 2, .end = 3 },
        .{ .vim = "[[=a=]]", .err = error.Unsupported, .start = 1, .end = 6 },
    };
    for (bad) |b| {
        var d: Diag = .{};
        try std.testing.expectError(b.err, translatePattern(gpa, b.vim, .{ .diag = &d }));
        std.testing.expectEqual(b.start, d.start) catch |e| {
            std.debug.print("{s}: span {d}..{d} ({s})\n", .{ b.vim, d.start, d.end, d.msg });
            return e;
        };
        std.testing.expectEqual(b.end, d.end) catch |e| {
            std.debug.print("{s}: span {d}..{d} ({s})\n", .{ b.vim, d.start, d.end, d.msg });
            return e;
        };
        try std.testing.expect(d.msg.len > 0);
    }
}

test "vim: replacement translation" {
    const gpa = std.testing.allocator;
    const cases = [_]Case{
        .{ .vim = "x&y", .re = "x$&y" },
        .{ .vim = "\\1-\\0", .re = "${1}-${0}" },
        .{ .vim = "a\\rb\\nc", .re = "a\\nb\\nc" },
        .{ .vim = "\\u&\\U\\1\\E", .re = "\\u$&\\U${1}\\E" },
        .{ .vim = "\\&\\~$5", .re = "&~$$5" },
        .{ .vim = "<~>", .re = "<old>" },
        .{ .vim = "a\\\\b", .re = "a\\\\b" },
    };
    for (cases) |cs| {
        const got = try translateReplacement(gpa, cs.vim, "old", null);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(cs.re, got);
    }
    var d: Diag = .{};
    try std.testing.expectError(error.Unsupported, translateReplacement(gpa, "\\=x", "", &d));
    try std.testing.expectEqual(@as(usize, 0), d.start);
}

test "vim: translated patterns compile and match like Vim" {
    const zg_regex = @import("zg_regex");
    const gpa = std.testing.allocator;
    const M = struct { vim: []const u8, hay: []const u8, at: ?[2]usize };
    const cases = [_]M{
        .{ .vim = "\\<is\\>", .hay = "this is", .at = .{ 5, 7 } },
        .{ .vim = "[^a]\\+", .hay = "aab\nc", .at = .{ 2, 3 } },
        .{ .vim = "\\s\\+", .hay = "a\n  b", .at = .{ 2, 4 } },
        .{ .vim = "\\_s\\+", .hay = "a\n  b", .at = .{ 1, 4 } },
        .{ .vim = "\\v(ab)+", .hay = "xababy", .at = .{ 1, 5 } },
        .{ .vim = "a\\{-1,}", .hay = "aaa", .at = .{ 0, 1 } },
        .{ .vim = "^b", .hay = "a\nb", .at = .{ 2, 3 } },
        .{ .vim = "x$", .hay = "x\nx", .at = .{ 0, 1 } },
    };
    for (cases) |c| {
        const p = try translatePattern(gpa, c.vim, .{});
        defer gpa.free(p);
        var re = try zg_regex.Regex.compile(gpa, p, .{ .multi_line = true });
        defer re.deinit(gpa);
        var cache = try re.newCache(gpa);
        defer cache.deinit();
        const m = re.find(&cache, zg_regex.Input.fromSlice(c.hay));
        if (c.at) |at| {
            try std.testing.expect(m != null);
            try std.testing.expectEqual(@as(u64, at[0]), m.?.start);
            try std.testing.expectEqual(@as(u64, at[1]), m.?.end);
        } else try std.testing.expect(m == null);
    }
}
