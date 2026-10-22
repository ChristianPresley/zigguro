//! Link pieces shared by the block parser (link reference definitions)
//! and the inline parser: labels, destinations, titles, label
//! normalization, backslash-escape and entity decoding, and the unsafe
//! destination check (CommonMark 0.31.2 §4.7, §6.3).

const std = @import("std");
const zg_text = @import("zg_text");
const entities = @import("entities.zig");

const Allocator = std.mem.Allocator;

/// ASCII punctuation (backslash-escapable).
pub fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

pub fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Whitespace for link syntax: space, tab, newline, line tabulation,
/// form feed, carriage return.
pub fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0B or c == 0x0C or c == '\r';
}

/// Skips spaces and tabs and at most one line ending.
pub fn skipSpacesNl(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and isSpaceOrTab(s[i])) i += 1;
    if (i < s.len and s[i] == '\n') {
        i += 1;
        while (i < s.len and isSpaceOrTab(s[i])) i += 1;
    }
    return i;
}

/// A link label at `s[start] == '['`: the index after `]`, or null.
/// No unescaped brackets inside, at most 999 characters, not blank.
pub fn scanLabel(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '[') return null;
    var i = start + 1;
    var nonblank = false;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            nonblank = true;
            i += 2;
        } else if (c == '[') {
            return null;
        } else if (c == ']') {
            if (!nonblank or i - start - 1 > 999) return null;
            return i + 1;
        } else {
            if (!isWs(c)) nonblank = true;
            i += 1;
        }
        if (i - start > 1001) return null;
    }
    return null;
}

pub const Span = struct { start: usize, end: usize, next: usize };

/// A link destination at `start`: `<...>` or a run without spaces or
/// controls with balanced parentheses. `start..end` is the raw text
/// (without the angle brackets); `next` is the index after it.
pub fn scanDestination(s: []const u8, start: usize) ?Span {
    if (start < s.len and s[start] == '<') {
        var i = start + 1;
        while (i < s.len) {
            const c = s[i];
            if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
                i += 2;
                continue;
            }
            if (c == '>') return .{ .start = start + 1, .end = i, .next = i + 1 };
            if (c == '<' or c == '\n' or c == '\r') return null;
            i += 1;
        }
        return null;
    }
    var i = start;
    var depth: u32 = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            i += 2;
            continue;
        }
        if (c == '(') {
            depth += 1;
            if (depth > 32) return null;
        } else if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        } else if (c <= 0x20 or c == 0x7f) break;
        i += 1;
    }
    if (i == start or depth != 0) return null;
    return .{ .start = start, .end = i, .next = i };
}

/// A link title at `start`: `"..."`, `'...'` or `(...)`; the raw text
/// without delimiters.
pub fn scanTitle(s: []const u8, start: usize) ?Span {
    if (start >= s.len) return null;
    const open = s[start];
    const close: u8 = switch (open) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var i = start + 1;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            i += 2;
            continue;
        }
        if (c == close) return .{ .start = start + 1, .end = i, .next = i + 1 };
        if (open == '(' and c == '(') return null;
        // A blank line ends the attempt.
        if (c == '\n') {
            var j = i + 1;
            while (j < s.len and isSpaceOrTab(s[j])) j += 1;
            if (j < s.len and s[j] == '\n') return null;
        }
        i += 1;
    }
    return null;
}

/// Appends `raw` with backslash escapes and entity references decoded.
pub fn unescape(out: *std.ArrayList(u8), gpa: Allocator, raw: []const u8) Allocator.Error!void {
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len and isAsciiPunct(raw[i + 1])) {
            try out.append(gpa, raw[i + 1]);
            i += 2;
        } else if (c == '&') {
            if (entities.match(raw[i..], &buf)) |m| {
                try out.appendSlice(gpa, m.utf8);
                i += m.len;
            } else {
                try out.append(gpa, c);
                i += 1;
            }
        } else {
            try out.append(gpa, c);
            i += 1;
        }
    }
}

/// Appends the normalized form of a label's inner text: trimmed, inner
/// whitespace runs collapsed to one space, Unicode case folded.
pub fn normalizeLabel(out: *std.ArrayList(u8), gpa: Allocator, inner: []const u8) Allocator.Error!void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, inner, " \t\n\r\x0b\x0c");
    var first = true;
    while (it.next()) |w| {
        if (!first) try tmp.append(gpa, ' ');
        first = false;
        try tmp.appendSlice(gpa, w);
    }
    try zg_text.unicode.casefold.foldAppend(out, gpa, tmp.items, .full);
}

/// A link reference definition at the start of `s` (a paragraph's
/// text): the bytes it spans (through its line end) and its parts.
pub const RefMatch = struct {
    len: usize,
    label: [2]usize,
    dest: [2]usize,
    title: ?[2]usize,
};

pub fn scanReference(s: []const u8) ?RefMatch {
    const label_end = scanLabel(s, 0) orelse return null;
    if (label_end >= s.len or s[label_end] != ':') return null;
    var i = skipSpacesNl(s, label_end + 1);
    const d = scanDestination(s, i) orelse return null;
    // `<>` is an empty destination; a bare one cannot be empty.
    i = d.next;
    const before_title = i;
    var j = skipSpacesNl(s, i);
    var title: ?[2]usize = null;
    var end: usize = undefined;
    if (j != before_title) {
        if (scanTitle(s, j)) |t| {
            var k = t.next;
            while (k < s.len and isSpaceOrTab(s[k])) k += 1;
            if (k == s.len or s[k] == '\n') {
                title = .{ t.start, t.end };
                end = if (k < s.len) k + 1 else k;
            }
        }
    }
    if (title == null) {
        // No (valid) title: the definition ends with the destination's line.
        j = before_title;
        while (j < s.len and isSpaceOrTab(s[j])) j += 1;
        if (j < s.len and s[j] != '\n') return null;
        end = if (j < s.len) j + 1 else j;
    }
    return .{ .len = end, .label = .{ 1, label_end - 1 }, .dest = .{ d.start, d.end }, .title = title };
}

/// Destinations rendered as text with a warning: `javascript:`,
/// `vbscript:`, `file:` and `data:` except PNG, GIF, JPEG and WebP images.
pub fn isUnsafeDestination(dest: []const u8) bool {
    const t = std.mem.trim(u8, dest, " \t\n");
    const schemes = [_][]const u8{ "javascript:", "vbscript:", "file:" };
    for (schemes) |sc| if (t.len >= sc.len and std.ascii.eqlIgnoreCase(t[0..sc.len], sc)) return true;
    if (t.len >= 5 and std.ascii.eqlIgnoreCase(t[0..5], "data:")) {
        const ok = [_][]const u8{ "data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp" };
        for (ok) |o| if (t.len >= o.len and std.ascii.eqlIgnoreCase(t[0..o.len], o)) return false;
        return true;
    }
    return false;
}

test "reference definitions" {
    const r = scanReference("[Foo bar]:\n<my url> 'title'\nrest").?;
    try std.testing.expectEqual(@as(usize, 28), r.len);
    try std.testing.expect(scanReference("[foo]: /url \"title\" ok") == null);
    const r2 = scanReference("[foo]: /url\n\"title\" ok").?;
    try std.testing.expectEqual(@as(usize, 12), r2.len);
    try std.testing.expect(r2.title == null);
}

test "unsafe destinations flagged" {
    try std.testing.expect(isUnsafeDestination("javascript:alert(1)"));
    try std.testing.expect(isUnsafeDestination("JAVASCRIPT:x"));
    try std.testing.expect(isUnsafeDestination("data:text/html,x"));
    try std.testing.expect(!isUnsafeDestination("data:image/png;base64,AAA"));
    try std.testing.expect(!isUnsafeDestination("https://example.com"));
}

test "label normalization folds case and whitespace" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try normalizeLabel(&out, std.testing.allocator, "  Foo \n  BAR ẞ ");
    try std.testing.expectEqualStrings("foo bar ss", out.items);
}
