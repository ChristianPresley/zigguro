//! Emacs regexps (GNU Emacs manual, "Syntax of Regexps") translated to
//! zg_regex syntax, for `C-M-s`, `C-M-r` and `C-M-%`.
//!
//! In Emacs `\( \) \| \{ \}` are the operators and `( ) | { }` are
//! literal; `* + ?` (and the lazy `*? +? ??`) are operators except where
//! nothing precedes them; `^` and `$` are anchors only at the start or end
//! of the pattern or of a group or alternative; a backslash inside `[...]`
//! is literal. `\w \W \b \B \< \> \_< \_> \` \' \s- \S-` map to their
//! zg_regex forms. Back references and `\=` are reported as unsupported.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ Unsupported, Syntax } || Allocator.Error;

pub fn translate(gpa: Allocator, src: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    // Whether an atom precedes (so `*` is an operator).
    var have_atom = false;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '\\' => {
                if (i + 1 >= src.len) return error.Syntax;
                const e = src[i + 1];
                i += 2;
                switch (e) {
                    '(' => {
                        if (std.mem.startsWith(u8, src[i..], "?:")) {
                            try out.appendSlice(gpa, "(?:");
                            i += 2;
                        } else try out.append(gpa, '(');
                        have_atom = false;
                        continue;
                    },
                    ')' => {
                        try out.append(gpa, ')');
                        have_atom = true;
                        continue;
                    },
                    '|' => {
                        try out.append(gpa, '|');
                        have_atom = false;
                        continue;
                    },
                    '{' => {
                        const close = std.mem.indexOfPos(u8, src, i, "\\}") orelse return error.Syntax;
                        const body = src[i..close];
                        for (body) |b| if (!std.ascii.isDigit(b) and b != ',') return error.Syntax;
                        try out.print(gpa, "{{{s}}}", .{if (body.len == 0) "0" else body});
                        i = close + 2;
                        continue;
                    },
                    'w', 'W', 'b', 'B' => try out.appendSlice(gpa, &.{ '\\', e }),
                    '<' => try out.appendSlice(gpa, "\\b{start}"),
                    '>' => try out.appendSlice(gpa, "\\b{end}"),
                    '_' => {
                        if (i >= src.len) return error.Syntax;
                        const s = src[i];
                        i += 1;
                        try out.appendSlice(gpa, switch (s) {
                            '<' => "\\b{start}",
                            '>' => "\\b{end}",
                            else => return error.Syntax,
                        });
                    },
                    '`' => try out.appendSlice(gpa, "\\A"),
                    '\'' => try out.appendSlice(gpa, "\\z"),
                    's', 'S' => {
                        if (i >= src.len) return error.Syntax;
                        const class = src[i];
                        i += 1;
                        if (class != '-' and class != ' ') return error.Unsupported;
                        try out.appendSlice(gpa, if (e == 's') "\\s" else "\\S");
                    },
                    '1'...'9', '=', 'c', 'C' => return error.Unsupported,
                    else => try literal(gpa, &out, e),
                }
                have_atom = true;
                continue;
            },
            '*', '+', '?' => {
                if (!have_atom) {
                    try literal(gpa, &out, c);
                    have_atom = true;
                } else {
                    try out.append(gpa, c);
                    if (i + 1 < src.len and src[i + 1] == '?') {
                        try out.append(gpa, '?');
                        i += 1;
                    }
                    have_atom = false;
                }
                i += 1;
                continue;
            },
            '^' => {
                if (atStart(src, i)) try out.append(gpa, '^') else try out.appendSlice(gpa, "\\^");
                i += 1;
                have_atom = true;
                continue;
            },
            '$' => {
                if (atEnd(src, i)) try out.append(gpa, '$') else try out.appendSlice(gpa, "\\$");
                i += 1;
                have_atom = true;
                continue;
            },
            '[' => {
                i = try bracket(gpa, src, i, &out);
                have_atom = true;
                continue;
            },
            '.' => try out.append(gpa, '.'),
            else => {
                const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const end = @min(i + n, src.len);
                if (n == 1) try literal(gpa, &out, c) else try out.appendSlice(gpa, src[i..end]);
                i = end;
                have_atom = true;
                continue;
            },
        }
        i += 1;
        have_atom = true;
    }
    return out.toOwnedSlice(gpa);
}

fn literal(gpa: Allocator, out: *std.ArrayList(u8), c: u8) !void {
    if (std.mem.indexOfScalar(u8, "\\.+*?()|[]{}^$", c) != null) try out.append(gpa, '\\');
    try out.append(gpa, c);
}

/// `^` at the start of the pattern, a group or an alternative.
fn atStart(src: []const u8, i: usize) bool {
    if (i == 0) return true;
    return i >= 2 and src[i - 2] == '\\' and (src[i - 1] == '(' or src[i - 1] == '|');
}

/// `$` at the end of the pattern, a group or an alternative.
fn atEnd(src: []const u8, i: usize) bool {
    if (i + 1 == src.len) return true;
    return i + 2 < src.len and src[i + 1] == '\\' and (src[i + 2] == ')' or src[i + 2] == '|');
}

/// Copies `[...]` starting at `start`; returns the index after it. In
/// Emacs a `]` first in the set is literal and `\` is always literal.
fn bracket(gpa: Allocator, src: []const u8, start: usize, out: *std.ArrayList(u8)) !usize {
    var i = start + 1;
    try out.append(gpa, '[');
    if (i < src.len and src[i] == '^') {
        try out.append(gpa, '^');
        i += 1;
    }
    var first = true;
    while (i < src.len) {
        const c = src[i];
        if (c == ']' and !first) {
            try out.append(gpa, ']');
            return i + 1;
        }
        first = false;
        if (c == '[' and i + 1 < src.len and src[i + 1] == ':') {
            const close = std.mem.indexOfPos(u8, src, i + 2, ":]") orelse return error.Syntax;
            try out.appendSlice(gpa, src[i .. close + 2]);
            i = close + 2;
            continue;
        }
        switch (c) {
            '\\', '[', ']', '&', '~' => {
                try out.append(gpa, '\\');
                try out.append(gpa, c);
            },
            else => try out.append(gpa, c),
        }
        i += 1;
    }
    return error.Syntax;
}

test "emacs: regexp translation" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "foo", "foo" },
        .{ "a\\(b\\|c\\)d", "a(b|c)d" },
        .{ "(x)|{y}", "\\(x\\)\\|\\{y\\}" },
        .{ "a*b+c?", "a*b+c?" },
        .{ "a*?b+?", "a*?b+?" },
        .{ "*a", "\\*a" },
        .{ "\\(*a\\)", "(\\*a)" },
        .{ "^a$", "^a$" },
        .{ "a^b$c", "a\\^b\\$c" },
        .{ "\\(^a\\|b$\\)", "(^a|b$)" },
        .{ "x\\{2,3\\}", "x{2,3}" },
        .{ "\\<foo\\>", "\\b{start}foo\\b{end}" },
        .{ "\\_<x\\_>", "\\b{start}x\\b{end}" },
        .{ "\\w+\\W", "\\w+\\W" },
        .{ "\\s-*", "\\s*" },
        .{ "[]a]", "[\\]a]" },
        .{ "[^a-z\\]", "[^a-z\\\\]" },
        .{ "[[:alpha:]_]", "[[:alpha:]_]" },
        .{ "\\`a\\'", "\\Aa\\z" },
        .{ "a.b", "a.b" },
        .{ "\\.", "\\." },
        .{ "é+", "é+" },
        .{ "\\(?:ab\\)", "(?:ab)" },
    };
    for (cases) |c| {
        const got = try translate(gpa, c[0]);
        defer gpa.free(got);
        std.testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("pattern {s}\n", .{c[0]});
            return e;
        };
        // Every translation is valid zg_regex syntax.
        var re = try @import("zg_regex").Regex.compile(gpa, got, .{});
        re.deinit(gpa);
    }
    try std.testing.expectError(error.Unsupported, translate(gpa, "\\(a\\)\\1"));
    try std.testing.expectError(error.Syntax, translate(gpa, "[ab"));
    try std.testing.expectError(error.Syntax, translate(gpa, "a\\"));
}
