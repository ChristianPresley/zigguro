//! Raw HTML recognition (CommonMark 0.31.2 §4.6 HTML blocks, §6.6 raw
//! HTML). zigguro never renders raw HTML: blocks and inlines it finds
//! become `html_literal` nodes the view draws escaped.

const std = @import("std");

const block_tags = [_][]const u8{
    "address",  "article",  "aside",   "base",     "basefont", "blockquote", "body",   "caption", "center",   "col",
    "colgroup", "dd",       "details", "dialog",   "dir",      "div",        "dl",     "dt",      "fieldset", "figcaption",
    "figure",   "footer",   "form",    "frame",    "frameset", "h1",         "h2",     "h3",      "h4",       "h5",
    "h6",       "head",     "header",  "hr",       "html",     "iframe",     "legend", "li",      "link",     "main",
    "menu",     "menuitem", "nav",     "noframes", "ol",       "optgroup",   "option", "p",       "param",    "search",
    "section",  "summary",  "table",   "tbody",    "td",       "tfoot",      "th",     "thead",   "title",    "tr",
    "track",    "ul",
};

fn startsWithIgnoreCase(s: []const u8, p: []const u8) bool {
    return s.len >= p.len and std.ascii.eqlIgnoreCase(s[0..p.len], p);
}

fn containsIgnoreCase(s: []const u8, needle: []const u8) bool {
    if (needle.len > s.len) return false;
    var i: usize = 0;
    while (i + needle.len <= s.len) : (i += 1) if (std.ascii.eqlIgnoreCase(s[i .. i + needle.len], needle)) return true;
    return false;
}

/// The HTML block start condition (1-7) of a line starting at `<`, or 0.
/// Condition 7 is reported even when it may not interrupt a paragraph;
/// the caller checks that.
pub fn blockStart(line: []const u8) u8 {
    if (line.len < 2 or line[0] != '<') return 0;
    const raw = [_][]const u8{ "pre", "script", "style", "textarea" };
    for (raw) |t| if (startsWithIgnoreCase(line[1..], t)) {
        const k = 1 + t.len;
        if (k == line.len or line[k] == ' ' or line[k] == '\t' or line[k] == '>') return 1;
    };
    if (std.mem.startsWith(u8, line, "<!--")) return 2;
    if (std.mem.startsWith(u8, line, "<?")) return 3;
    if (line.len >= 3 and line[1] == '!' and std.ascii.isAlphabetic(line[2])) return 4;
    if (std.mem.startsWith(u8, line, "<![CDATA[")) return 5;
    var i: usize = 1;
    if (i < line.len and line[i] == '/') i += 1;
    const name_start = i;
    while (i < line.len and std.ascii.isAlphanumeric(line[i])) i += 1;
    if (i > name_start) {
        const name = line[name_start..i];
        for (block_tags) |t| if (std.ascii.eqlIgnoreCase(name, t)) {
            if (i == line.len or line[i] == ' ' or line[i] == '\t' or line[i] == '>' or std.mem.startsWith(u8, line[i..], "/>")) return 6;
            break;
        };
    }
    // 7: a complete open or closing tag alone on the line.
    const end = scanOpenTag(line, 0) orelse scanClosingTag(line, 0) orelse return 0;
    const t = line[1..];
    for (raw) |r| if (startsWithIgnoreCase(t, r) and (t.len == r.len or !std.ascii.isAlphanumeric(t[r.len]) and t[r.len] != '-')) return 0;
    for (line[end..]) |c| if (c != ' ' and c != '\t') return 0;
    return 7;
}

/// Whether `line` ends an HTML block of start condition `kind` (1-5).
pub fn blockEnds(kind: u8, line: []const u8) bool {
    return switch (kind) {
        1 => containsIgnoreCase(line, "</pre>") or containsIgnoreCase(line, "</script>") or containsIgnoreCase(line, "</style>") or containsIgnoreCase(line, "</textarea>"),
        2 => std.mem.indexOf(u8, line, "-->") != null,
        3 => std.mem.indexOf(u8, line, "?>") != null,
        4 => std.mem.indexOfScalar(u8, line, '>') != null,
        5 => std.mem.indexOf(u8, line, "]]>") != null,
        else => false,
    };
}

fn isTagNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}

fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n' or s[j] == '\r' or s[j] == 0x0C)) j += 1;
    return j;
}

/// An open tag at `s[i] == '<'`: the index after `>`.
pub fn scanOpenTag(s: []const u8, start: usize) ?usize {
    var i = start;
    if (i + 1 >= s.len or s[i] != '<' or !isTagNameStart(s[i + 1])) return null;
    i += 2;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    while (true) {
        const ws_end = skipWs(s, i);
        if (ws_end >= s.len) return null;
        if (s[ws_end] == '>') return ws_end + 1;
        if (s[ws_end] == '/' and ws_end + 1 < s.len and s[ws_end + 1] == '>') return ws_end + 2;
        // An attribute needs whitespace before it.
        if (ws_end == i) return null;
        i = ws_end;
        const c = s[i];
        if (!(std.ascii.isAlphabetic(c) or c == '_' or c == ':')) return null;
        i += 1;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '.' or s[i] == ':' or s[i] == '-')) i += 1;
        // Optional value.
        const before_eq = skipWs(s, i);
        if (before_eq < s.len and s[before_eq] == '=') {
            var v = skipWs(s, before_eq + 1);
            if (v >= s.len) return null;
            const q = s[v];
            if (q == '"' or q == '\'') {
                const close = std.mem.indexOfScalarPos(u8, s, v + 1, q) orelse return null;
                v = close + 1;
            } else {
                const vs = v;
                while (v < s.len) : (v += 1) switch (s[v]) {
                    ' ', '\t', '\n', '\r', 0x0C, '"', '\'', '=', '<', '>', '`' => break,
                    else => {},
                };
                if (v == vs) return null;
            }
            i = v;
        }
    }
}

/// A closing tag at `s[i] == '<'`: the index after `>`.
pub fn scanClosingTag(s: []const u8, start: usize) ?usize {
    var i = start;
    if (i + 2 >= s.len or s[i] != '<' or s[i + 1] != '/' or !isTagNameStart(s[i + 2])) return null;
    i += 3;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    i = skipWs(s, i);
    if (i < s.len and s[i] == '>') return i + 1;
    return null;
}

/// Any raw HTML at `s[i] == '<'` (tags, comments, processing
/// instructions, declarations, CDATA): the index after it.
pub fn scanInline(s: []const u8, start: usize) ?usize {
    if (start + 1 >= s.len or s[start] != '<') return null;
    const rest = s[start..];
    if (scanOpenTag(s, start)) |e| return e;
    if (scanClosingTag(s, start)) |e| return e;
    if (std.mem.startsWith(u8, rest, "<!--")) {
        // `<!-->` and `<!--->` are complete comments.
        if (std.mem.startsWith(u8, rest, "<!-->")) return start + 5;
        if (std.mem.startsWith(u8, rest, "<!--->")) return start + 6;
        const e = std.mem.indexOfPos(u8, s, start + 4, "-->") orelse return null;
        return e + 3;
    }
    if (std.mem.startsWith(u8, rest, "<?")) {
        const e = std.mem.indexOfPos(u8, s, start + 2, "?>") orelse return null;
        return e + 2;
    }
    if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
        const e = std.mem.indexOfPos(u8, s, start + 9, "]]>") orelse return null;
        return e + 3;
    }
    if (rest.len > 2 and rest[1] == '!' and std.ascii.isAlphabetic(rest[2])) {
        const e = std.mem.indexOfScalarPos(u8, s, start + 2, '>') orelse return null;
        return e + 1;
    }
    return null;
}

test "html block starts" {
    try std.testing.expectEqual(@as(u8, 1), blockStart("<pre class=\"x\">"));
    try std.testing.expectEqual(@as(u8, 2), blockStart("<!-- c"));
    try std.testing.expectEqual(@as(u8, 6), blockStart("<div>"));
    try std.testing.expectEqual(@as(u8, 6), blockStart("</TABLE>"));
    try std.testing.expectEqual(@as(u8, 7), blockStart("<a href=\"x\">  "));
    try std.testing.expectEqual(@as(u8, 0), blockStart("<a href=\"x\"> text"));
    try std.testing.expectEqual(@as(?usize, 12), scanInline("<a  /><b2 x> y", 6));
}
