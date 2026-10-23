//! A conservative HTML/SVG sanitizer for exported documents
//! (E13.F04.S01.T03): what an exported file may contain from the
//! document's raw HTML, from SVG images and from rendered diagrams.
//!
//! Script-capable elements go with their content (`script`, `style`,
//! `iframe`, `object`, `foreignObject`, SVG `animate`/`set`, ...),
//! comments, doctypes and processing instructions go, and so does every
//! `on*` attribute, any URL attribute whose value is not plainly safe
//! (a `javascript:`/`vbscript:`/`data:` scheme, or anything with
//! entities or control characters that could hide one), and inline
//! styles that could load or run something. Text between tags is copied
//! as is. Input whose tags do not close is refused, so the caller can
//! fall back to a link or an escaped listing.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{Malformed};

/// Dropped together with their content.
const banned_with_content = [_][]const u8{
    "script",   "style",  "iframe", "object",  "applet",        "foreignobject",    "noscript", "template", "frameset",
    "noembed",  "xmp",    "title",  "animate", "animatemotion", "animatetransform", "set",      "handler",  "listener",
    "textarea", "select", "option", "frame",   "svg:script",
};

/// Dropped (no content of their own).
const banned_void = [_][]const u8{ "base", "link", "meta", "embed", "param", "input", "button", "form", "keygen" };

/// Attributes holding a URL.
const url_attrs = [_][]const u8{ "href", "xlink:href", "src", "action", "formaction", "data", "poster", "background", "srcset", "cite", "longdesc", "lowsrc", "dynsrc", "ping", "codebase", "manifest" };

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, name)) return true;
    return false;
}

/// The scheme of `url`, lowercased into `buf`, after dropping the ASCII
/// whitespace and controls browsers ignore; "" for a relative URL; null
/// when `url` hides characters a scheme check cannot see through.
pub fn schemeOf(url: []const u8, buf: *[16]u8) ?[]const u8 {
    var n: usize = 0;
    for (url) |c| {
        if (c <= ' ' or c == 0x7f) continue;
        // An entity could spell a scheme once the browser decodes it.
        if (c == '&') return null;
        if (c == ':') return buf[0..n];
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return "";
        if (n == buf.len) return "";
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return "";
}

/// A link target safe to keep: relative, a fragment, or http(s)/mailto.
pub fn safeLink(url: []const u8) bool {
    var buf: [16]u8 = undefined;
    const s = schemeOf(url, &buf) orelse return false;
    return s.len == 0 or eqlAny(s, &.{ "http", "https", "mailto" });
}

fn eqlAny(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// An embedded raster image: `data:image/png|jpeg|gif|webp`.
pub fn safeImageData(url: []const u8) bool {
    const prefixes = [_][]const u8{ "data:image/png;", "data:image/jpeg;", "data:image/gif;", "data:image/webp;" };
    for (prefixes) |p| if (url.len >= p.len and std.ascii.eqlIgnoreCase(url[0..p.len], p)) return true;
    return false;
}

fn safeUrlAttr(tag: []const u8, name: []const u8, value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, '&') != null) return false;
    const lname = name;
    // Inside SVG, references stay within the document.
    if ((std.ascii.eqlIgnoreCase(lname, "href") or std.ascii.eqlIgnoreCase(lname, "xlink:href")) and !std.ascii.eqlIgnoreCase(tag, "a")) {
        if (std.ascii.eqlIgnoreCase(tag, "img") or std.ascii.eqlIgnoreCase(tag, "image")) return safeImageData(value) or safeLink(value);
        return value.len > 0 and value[0] == '#';
    }
    if (std.ascii.eqlIgnoreCase(lname, "src")) return safeImageData(value) or safeLink(value);
    if (std.ascii.eqlIgnoreCase(lname, "href")) return safeLink(value);
    return false;
}

fn safeStyle(value: []const u8) bool {
    const bad = [_][]const u8{ "url(", "expression", "javascript", "@import", "behavior", "-moz-binding", "&", "\\" };
    for (bad) |b| if (std.ascii.indexOfIgnoreCase(value, b) != null) return false;
    return true;
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == ':' or c == '_' or c == '.';
}

fn skipSpace(s: []const u8, i: usize) usize {
    var k = i;
    while (k < s.len and std.ascii.isWhitespace(s[k])) k += 1;
    return k;
}

/// Writes `s` as a double-quoted attribute value.
fn attrValue(out: *std.ArrayList(u8), a: Allocator, s: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "&quot;"),
        '<' => try out.appendSlice(a, "&lt;"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

/// `html` with everything that could run, load or hide something removed.
pub fn sanitize(a: Allocator, html: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < html.len) {
        const lt = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
        try out.appendSlice(a, html[i..lt]);
        i = lt;
        if (i >= html.len) break;
        const rest = html[i..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse return error.Malformed;
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            const end = std.mem.indexOfPos(u8, html, i + 9, "]]>") orelse return error.Malformed;
            // As text.
            for (html[i + 9 .. end]) |c| switch (c) {
                '<' => try out.appendSlice(a, "&lt;"),
                '&' => try out.appendSlice(a, "&amp;"),
                else => try out.append(a, c),
            };
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<!") or std.mem.startsWith(u8, rest, "<?")) {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse return error.Malformed;
            i = end + 1;
            continue;
        }
        const closing = rest.len > 1 and rest[1] == '/';
        var k: usize = i + 1 + @intFromBool(closing);
        if (k >= html.len or !isNameStart(html[k])) {
            try out.appendSlice(a, "&lt;");
            i += 1;
            continue;
        }
        const name_start = k;
        while (k < html.len and isNameChar(html[k])) k += 1;
        const name = html[name_start..k];
        if (closing) {
            const end = std.mem.indexOfScalarPos(u8, html, k, '>') orelse return error.Malformed;
            i = end + 1;
            if (inList(&banned_with_content, name) or inList(&banned_void, name)) continue;
            try out.appendSlice(a, "</");
            try out.appendSlice(a, name);
            try out.append(a, '>');
            continue;
        }
        // Attributes.
        const tag_mark = out.items.len;
        try out.append(a, '<');
        try out.appendSlice(a, name);
        var self_close = false;
        while (true) {
            k = skipSpace(html, k);
            if (k >= html.len) return error.Malformed;
            if (html[k] == '>') {
                k += 1;
                break;
            }
            if (html[k] == '/') {
                if (k + 1 < html.len and html[k + 1] == '>') {
                    self_close = true;
                    k += 2;
                    break;
                }
                k += 1;
                continue;
            }
            const an_start = k;
            while (k < html.len and !std.ascii.isWhitespace(html[k]) and html[k] != '=' and html[k] != '>' and html[k] != '/' and html[k] != '"' and html[k] != '\'') k += 1;
            if (k == an_start) return error.Malformed;
            const an = html[an_start..k];
            k = skipSpace(html, k);
            var value: ?[]const u8 = null;
            if (k < html.len and html[k] == '=') {
                k = skipSpace(html, k + 1);
                if (k >= html.len) return error.Malformed;
                if (html[k] == '"' or html[k] == '\'') {
                    const q = html[k];
                    const end = std.mem.indexOfScalarPos(u8, html, k + 1, q) orelse return error.Malformed;
                    value = html[k + 1 .. end];
                    k = end + 1;
                } else {
                    const vs = k;
                    while (k < html.len and !std.ascii.isWhitespace(html[k]) and html[k] != '>') k += 1;
                    value = html[vs..k];
                }
            }
            if (an.len >= 2 and std.ascii.eqlIgnoreCase(an[0..2], "on")) continue;
            if (!isAttrName(an)) continue;
            if (inList(&url_attrs, an)) {
                if (value == null or !safeUrlAttr(name, an, value.?)) continue;
            }
            if (std.ascii.eqlIgnoreCase(an, "style") and value != null and !safeStyle(value.?)) continue;
            // `attributeName` could retarget animations at href (dropped anyway).
            if (std.ascii.eqlIgnoreCase(an, "attributename")) continue;
            try out.append(a, ' ');
            try out.appendSlice(a, an);
            if (value) |v| {
                try out.append(a, '=');
                try attrValue(&out, a, v);
            }
        }
        if (inList(&banned_void, name)) {
            out.shrinkRetainingCapacity(tag_mark);
            i = k;
            continue;
        }
        if (inList(&banned_with_content, name)) {
            out.shrinkRetainingCapacity(tag_mark);
            i = if (self_close) k else skipPastClose(html, k, name);
            continue;
        }
        try out.appendSlice(a, if (self_close) " />" else ">");
        i = k;
    }
    return out.toOwnedSlice(a);
}

fn isAttrName(s: []const u8) bool {
    for (s) |c| if (!isNameChar(c)) return false;
    return s.len > 0;
}

/// After `</name ...>` (case-insensitive), or the end of the input.
fn skipPastClose(html: []const u8, from: usize, name: []const u8) usize {
    var k = from;
    while (std.mem.indexOfPos(u8, html, k, "</")) |p| {
        const n = p + 2;
        if (n + name.len <= html.len and std.ascii.eqlIgnoreCase(html[n .. n + name.len], name) and (n + name.len == html.len or !isNameChar(html[n + name.len]))) {
            const end = std.mem.indexOfScalarPos(u8, html, n, '>') orelse return html.len;
            return end + 1;
        }
        k = n;
    }
    return html.len;
}
